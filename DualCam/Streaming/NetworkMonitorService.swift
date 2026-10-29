import Combine
import CryptoKit
import Foundation
import Network
import UIKit

struct NearbyMonitorDevice: Identifiable {
    let id: String
    let name: String
    fileprivate let endpoint: NWEndpoint
}

/// Bonjour discovery uses Network.framework (rather than deprecated Multipeer Connectivity).
/// First pairing uses ephemeral Curve25519 + a six-digit safety code which users compare on BOTH
/// screens. Signalling is then protected with directional AES-GCM keys derived from ECDH + HKDF.
/// The video itself is carried by WebRTC DTLS-SRTP; this service never transports video frames.
///
/// Handshake (v3), initiator I -> responder R:
///   1. I -> R  commit  = SHA256(I.publicKey || I.nonce)      (I is now bound to its key)
///   2. R -> I  hello   = R.publicKey, R.nonce                 (R chose these after the commit)
///   3. I -> R  hello   = I.publicKey, I.nonce                 (R checks it against the commit)
/// A six-digit code is a weak check, so neither side may be able to pick its key after seeing the
/// other's: without the commit, a man-in-the-middle could generate keys until both codes matched.
final class NetworkMonitorService: ObservableObject {
    @Published private(set) var nearbyDevices: [NearbyMonitorDevice] = []
    @Published private(set) var statusText = "准备搜索附近设备"
    @Published private(set) var pairingCode: String?
    @Published private(set) var isSecurelyPaired = false
    @Published private(set) var localDeviceName: String

    var onSignalReceived: ((Data) -> Void)?

    private static let serviceType = "_dualcam-monitor._tcp"
    // v2: packets are length-prefixed (TCP is a byte stream, not a message stream).
    // v3: commit-then-reveal key exchange, per-direction sequence numbers, handshake timeout.
    private static let protocolVersion = "DualCamMonitor/3"
    private static let maxPacketSize = 1_000_000
    /// An unpaired connection (including one that never speaks) is dropped after this long, so a
    /// stranger on the Wi-Fi cannot hold the only connection slot and block real pairing.
    private static let handshakeTimeout: TimeInterval = 120
    private static let maxDeviceNameLength = 40
    private let queue = DispatchQueue(label: "com.dualcam.monitor.network", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var activeConnection: NWConnection?
    private var serviceName = ""
    private var isInitiator = false
    private var didStartHandshake = false
    private var handshakeTimer: DispatchWorkItem?

    private var localPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var localNonce: Data?
    private var remoteNonce: Data?
    /// Responder only: the initiator's commitment, received before we reveal our own key.
    private var peerCommitment: Data?
    private var remoteDeviceName = ""
    /// Strictly increasing per direction and bound into the AES-GCM associated data, so a recorded
    /// packet cannot be replayed (or reordered) later in the same session.
    private var sendSequence: UInt64 = 0
    private var lastReceivedSequence: UInt64?
    private var masterKey: SymmetricKey?
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var localConfirmed = false
    private var remoteConfirmed = false
    private var pairedOnQueue = false
    private var receiveBuffer = Data()

    private struct Packet: Codable {
        let type: String
        var deviceName: String? = nil
        var publicKey: Data? = nil
        var nonce: Data? = nil
        var payload: Data? = nil
        var version: String? = nil
        var commitment: Data? = nil
        var seq: UInt64? = nil
    }

    init() {
        let rawName = UIDevice.current.name
        self.localDeviceName = rawName
        let safeName = rawName
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        serviceName = "DualCam-\(String(safeName.prefix(28)))-\(String(UUID().uuidString.prefix(4)))"
    }

    func start() {
        queue.async {
            guard self.listener == nil, self.browser == nil else { return }
            self.startListener()
            self.startBrowser()
            self.publishStatus("正在搜索附近的 DualCam 设备…")
        }
    }

    func stop() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
            self.listener?.cancel()
            self.listener = nil
            self.activeConnection?.cancel()
            self.activeConnection = nil
            self.resetHandshake(publishCode: nil)
            self.publishDevices([])
            self.publishStatus("无线监看已关闭")
        }
    }

    /// Force a fresh Bonjour browser/listener after a failed or stale search.
    /// start() intentionally does not duplicate a live browser, so the UI's retry button
    /// must explicitly cancel the existing pair and recreate them.
    func restartDiscovery() {
        queue.async {
            guard !self.pairedOnQueue, self.activeConnection == nil else {
                self.publishStatus("已有安全连接，不能重新搜索；请先断开设备")
                return
            }

            self.browser?.cancel()
            self.browser = nil
            self.listener?.cancel()
            self.listener = nil
            self.publishDevices([])
            self.publishStatus("正在重新启动设备搜索…")

            self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                // start() may have run in the meantime; never stack a second listener/browser.
                guard let self, !self.pairedOnQueue, self.activeConnection == nil,
                      self.listener == nil, self.browser == nil else { return }
                self.startListener()
                self.startBrowser()
                self.publishStatus("正在搜索附近的 DualCam 设备…")
            }
        }
    }

    func connect(to device: NearbyMonitorDevice) {
        queue.async {
            guard self.activeConnection == nil else {
                self.publishStatus("已有连接正在进行；请先断开当前设备")
                return
            }
            self.resetHandshake(publishCode: nil)
            self.isInitiator = true
            let connection = NWConnection(to: device.endpoint, using: Self.makeParameters())
            self.install(connection)
            self.publishStatus("正在连接 \(device.name)…")
        }
    }

    /// Called only after the displayed six-digit codes were checked and match on both devices.
    func confirmPairing() {
        queue.async {
            guard self.masterKey != nil, self.pairingCode != nil, !self.localConfirmed else { return }
            self.localConfirmed = true
            guard let key = self.sendKey else {
                self.publishStatus("无法建立安全会话")
                return
            }
            let sequence = self.nextSendSequence()
            guard let payload = self.seal(Data("confirmed".utf8), key: key, purpose: "pair-confirm", sequence: sequence) else {
                self.publishStatus("无法建立安全会话")
                return
            }
            self.send(Packet(type: "confirm", payload: payload, seq: sequence))
            self.publishStatus(self.remoteConfirmed
                ? "正在完成安全配对…"
                : "本机已确认，等待另一台设备确认验证码…")
            self.updatePairedStateIfReady()
        }
    }

    func rejectPairing() {
        queue.async {
            self.dropActiveConnection(status: "已取消配对")
        }
    }

    func sendSignal(_ data: Data) {
        queue.async {
            guard self.pairedOnQueue, let key = self.sendKey else {
                self.publishStatus("信令尚未安全配对，已拒绝发送")
                return
            }
            let sequence = self.nextSendSequence()
            guard let payload = self.seal(data, key: key, purpose: "webrtc-signal", sequence: sequence) else {
                self.publishStatus("加密视频信令失败")
                return
            }
            self.send(Packet(type: "signal", payload: payload, seq: sequence))
        }
    }

    private static func makeParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        // Signalling packets are tiny and latency-sensitive; don't let Nagle batch them.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            // A peer that vanishes without a FIN (Wi-Fi dropped, device asleep) would otherwise
            // leave the sender "sharing" forever. Probe after 5 s idle, every 5 s, give up after 3.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
        }
        return parameters
    }

    private func startListener() {
        do {
            let newListener = try NWListener(using: Self.makeParameters())
            newListener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.publishStatus("正在广播本机，等待安全连接")
                case .failed(let error):
                    // Drop the dead listener so start()/restartDiscovery() can create a new one.
                    if let newListener, self.listener === newListener {
                        self.listener = nil
                    }
                    newListener?.cancel()
                    self.publishStatus("本地监听失败：\(error.localizedDescription)")
                case .waiting(let error):
                    self.publishStatus("等待网络：\(error.localizedDescription)")
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.acceptIncoming(connection)
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            publishStatus("无法启动附近设备监听：\(error.localizedDescription)")
        }
    }

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: Self.makeParameters())
        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.publishStatus("正在搜索附近的 DualCam 设备…")
            case .waiting(let error):
                self.publishStatus("设备搜索等待网络：\(error.localizedDescription)")
            case .failed(let error):
                if let newBrowser, self.browser === newBrowser {
                    self.browser = nil
                }
                self.publishStatus("设备发现失败：\(error.localizedDescription)；请检查本地网络权限后重新搜索")
            case .cancelled, .setup:
                break
            @unknown default:
                break
            }
        }
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let devices = results.compactMap { result -> NearbyMonitorDevice? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                guard name != self.serviceName else { return nil }
                let identifier = String(describing: result.endpoint)
                let displayName = name.hasPrefix("DualCam-")
                    ? String(name.dropFirst("DualCam-".count))
                    : name
                return NearbyMonitorDevice(id: identifier, name: displayName, endpoint: result.endpoint)
            }
            self.publishDevices(devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
        browser = newBrowser
        newBrowser.start(queue: queue)
    }

    private func acceptIncoming(_ connection: NWConnection) {
        guard activeConnection == nil else {
            connection.cancel()
            return
        }
        resetHandshake(publishCode: nil)
        isInitiator = false
        install(connection)
        publishStatus("发现连接请求，正在协商安全验证码…")
    }

    private func install(_ connection: NWConnection) {
        activeConnection = connection
        localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        localNonce = Self.randomBytes(count: 32)
        remoteNonce = nil
        peerCommitment = nil
        didStartHandshake = false
        localConfirmed = false
        remoteConfirmed = false
        pairedOnQueue = false
        sendSequence = 0
        lastReceivedSequence = nil
        receiveBuffer.removeAll()
        armHandshakeTimer(for: connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.activeConnection === connection else { return }
            switch state {
            case .ready:
                if !self.didStartHandshake {
                    self.didStartHandshake = true
                    // Only the initiator speaks first, and only with a hash of its key + nonce.
                    if self.isInitiator { self.sendCommit() }
                    self.receiveNext(from: connection)
                }
            case .waiting(let error):
                self.publishStatus("正在等待网络路径：\(error.localizedDescription)")
            case .failed(let error):
                self.dropActiveConnection(status: "连接失败：\(error.localizedDescription)")
            case .cancelled:
                if self.activeConnection === connection {
                    self.activeConnection = nil
                    self.resetHandshake(publishCode: nil)
                    self.publishStatus("设备已断开")
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendCommit() {
        guard let privateKey = localPrivateKey, let nonce = localNonce else { return }
        send(Packet(
            type: "commit",
            version: Self.protocolVersion,
            commitment: Self.commitment(publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce)
        ))
    }

    private func sendHello() {
        guard let privateKey = localPrivateKey, let nonce = localNonce else { return }
        send(Packet(
            type: "hello",
            deviceName: localDeviceName,
            publicKey: privateKey.publicKey.rawRepresentation,
            nonce: nonce,
            version: Self.protocolVersion
        ))
    }

    private static func commitment(publicKey: Data, nonce: Data) -> Data {
        var input = Data("DualCam.Monitor.Commit.v3".utf8)
        input.append(publicKey)
        input.append(nonce)
        return Data(SHA256.hash(data: input))
    }

    /// Drops the unpaired connection if it is still unpaired after `handshakeTimeout`.
    private func armHandshakeTimer(for connection: NWConnection) {
        handshakeTimer?.cancel()
        let work = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection,
                  self.activeConnection === connection, !self.pairedOnQueue else { return }
            self.dropActiveConnection(status: "配对超时，请重新连接")
        }
        handshakeTimer = work
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: work)
    }

    /// Single teardown path: cancel the socket, forget all handshake state, and say why.
    /// `activeConnection` is cleared first so the connection's own `.cancelled` callback is
    /// ignored and cannot overwrite `status`.
    private func dropActiveConnection(status: String) {
        let connection = activeConnection
        activeConnection = nil
        connection?.cancel()
        resetHandshake(publishCode: nil)
        publishStatus(status)
    }

    private func receiveNext(from connection: NWConnection) {
        // TCP is a byte stream: one read can hold half a packet or several packets, so packets are
        // length-prefixed and reassembled here instead of assuming one read equals one message.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.activeConnection === connection else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainReceiveBuffer()
                // A packet handler may have torn the connection down.
                guard self.activeConnection === connection else { return }
            }
            if let error {
                self.dropActiveConnection(status: "连接中断：\(error.localizedDescription)")
                return
            }
            if isComplete {
                self.dropActiveConnection(status: "对端已关闭连接")
                return
            }
            self.receiveNext(from: connection)
        }
    }

    /// Split the receive buffer into complete `[4-byte big-endian length][JSON packet]` frames.
    private func drainReceiveBuffer() {
        while receiveBuffer.count >= 4 {
            let length = receiveBuffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maxPacketSize else {
                dropActiveConnection(status: "收到无法识别的配对消息")
                return
            }
            guard receiveBuffer.count >= 4 + length else { return }
            let body = receiveBuffer.subdata(in: 4..<(4 + length))
            receiveBuffer.removeSubrange(0..<(4 + length))
            handlePacket(body)
            if activeConnection == nil {
                receiveBuffer.removeAll()
                return
            }
        }
    }

    private func handlePacket(_ data: Data) {
        guard data.count <= Self.maxPacketSize,
              let packet = try? JSONDecoder().decode(Packet.self, from: data) else {
            publishStatus("收到无法识别的配对消息")
            return
        }

        switch packet.type {
        case "commit":
            // Responder only, exactly once, and strictly before any hello.
            guard !isInitiator, packet.version == Self.protocolVersion,
                  peerCommitment == nil, remoteNonce == nil,
                  let commitment = packet.commitment, commitment.count == 32 else {
                dropActiveConnection(status: "对端版本不兼容或配对数据无效")
                return
            }
            peerCommitment = commitment
            sendHello()

        case "hello":
            // At most one hello per connection: a second one would silently re-key a live session.
            guard packet.version == Self.protocolVersion,
                  remoteNonce == nil,
                  let publicKeyData = packet.publicKey,
                  let nonce = packet.nonce, nonce.count == 32 else {
                dropActiveConnection(status: "对端版本不兼容或配对数据无效")
                return
            }
            if !isInitiator {
                // Reveal step: it must open the commitment that arrived before we disclosed our key.
                guard let expected = peerCommitment,
                      Self.commitment(publicKey: publicKeyData, nonce: nonce) == expected else {
                    dropActiveConnection(status: "配对校验失败：对端密钥与此前的承诺不一致")
                    return
                }
            }
            guard establishSession(remotePublicKey: publicKeyData, remoteNonce: nonce, remoteName: packet.deviceName) else {
                dropActiveConnection(status: "建立安全密钥失败")
                return
            }
            // The responder has fixed its key by now; only then does the initiator reveal its own.
            if isInitiator { sendHello() }

        case "confirm":
            guard let plaintext = openSequenced(packet, purpose: "pair-confirm"),
                  String(data: plaintext, encoding: .utf8) == "confirmed" else {
                dropActiveConnection(status: "安全配对确认校验失败")
                return
            }
            remoteConfirmed = true
            publishStatus(localConfirmed ? "正在完成安全配对…" : "对端已确认；请核对本机验证码后确认")
            updatePairedStateIfReady()

        case "signal":
            guard pairedOnQueue,
                  let plain = openSequenced(packet, purpose: "webrtc-signal") else {
                publishStatus("拒绝未经安全配对、校验失败或重放的视频信令")
                return
            }
            DispatchQueue.main.async { self.onSignalReceived?(plain) }

        case "disconnect":
            dropActiveConnection(status: "对端结束了安全连接")

        default:
            publishStatus("忽略未知的配对消息")
        }
    }

    /// Derives the session keys and the six-digit safety code from our private key and the peer's
    /// public key + nonce. Returns false if the peer's key material is unusable.
    private func establishSession(remotePublicKey publicKeyData: Data, remoteNonce nonce: Data, remoteName: String?) -> Bool {
        guard let privateKey = localPrivateKey, let ownNonce = localNonce else { return false }
        do {
            let remotePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
            // A low-order point yields an all-zero secret that an attacker could predict.
            let isDegenerate = sharedSecret.withUnsafeBytes { bytes in bytes.allSatisfy { $0 == 0 } }
            guard !isDegenerate else { return false }

            remoteNonce = nonce
            remoteDeviceName = Self.sanitizedDeviceName(remoteName)
            let salt = isInitiator ? ownNonce + nonce : nonce + ownNonce
            let master = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("DualCam.Monitor.Pairing.v1".utf8),
                outputByteCount: 32
            )
            masterKey = master
            let i2r = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: master,
                salt: salt,
                info: Data("DualCam.Monitor.InitiatorToResponder.v1".utf8),
                outputByteCount: 32
            )
            let r2i = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: master,
                salt: salt,
                info: Data("DualCam.Monitor.ResponderToInitiator.v1".utf8),
                outputByteCount: 32
            )
            sendKey = isInitiator ? i2r : r2i
            receiveKey = isInitiator ? r2i : i2r

            let codeMAC = HMAC<SHA256>.authenticationCode(for: Data("DualCam.Monitor.SafetyCode.v1".utf8), using: master)
            let codeValue = codeMAC.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let code = String(format: "%06u", codeValue % 1_000_000)
            DispatchQueue.main.async {
                self.pairingCode = code
                self.statusText = "请在两台设备上核对相同的安全验证码"
            }
            return true
        } catch {
            return false
        }
    }

    /// The peer's name arrives before it is authenticated and is shown in the UI, so strip control
    /// characters and newlines and cap the length.
    private static func sanitizedDeviceName(_ raw: String?) -> String {
        let printable = (raw ?? "").filter { character in
            guard !character.isNewline else { return false }
            guard let ascii = character.asciiValue else { return true }
            return ascii >= 32 && ascii != 127
        }
        let name = String(printable.prefix(maxDeviceNameLength)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "DualCam 设备" : name
    }

    private func updatePairedStateIfReady() {
        guard localConfirmed, remoteConfirmed, masterKey != nil else { return }
        handshakeTimer?.cancel()
        handshakeTimer = nil
        pairedOnQueue = true
        DispatchQueue.main.async {
            self.isSecurelyPaired = true
            self.statusText = "安全配对成功：\(self.remoteDeviceName)"
        }
    }

    private func nextSendSequence() -> UInt64 {
        defer { sendSequence &+= 1 }
        return sendSequence
    }

    /// Purpose and sequence number are authenticated (not encrypted) alongside the payload, so a
    /// packet can neither be reinterpreted as another message type nor replayed under a new number.
    private func authenticatedData(purpose: String, sequence: UInt64) -> Data {
        Data("\(Self.protocolVersion)/\(purpose)/\(sequence)".utf8)
    }

    private func seal(_ data: Data, key: SymmetricKey, purpose: String, sequence: UInt64) -> Data? {
        do {
            let box = try AES.GCM.seal(data, using: key, authenticating: authenticatedData(purpose: purpose, sequence: sequence))
            return box.combined
        } catch {
            return nil
        }
    }

    private func open(_ data: Data, key: SymmetricKey, purpose: String, sequence: UInt64) -> Data? {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key, authenticating: authenticatedData(purpose: purpose, sequence: sequence))
        } catch {
            return nil
        }
    }

    /// Opens a sealed packet only if its sequence number is higher than every one accepted so far.
    /// TCP delivers in order, so anything else is a replay or an injected packet.
    private func openSequenced(_ packet: Packet, purpose: String) -> Data? {
        guard let payload = packet.payload, let key = receiveKey, let sequence = packet.seq else { return nil }
        if let last = lastReceivedSequence, sequence <= last { return nil }
        guard let plaintext = open(payload, key: key, purpose: purpose, sequence: sequence) else { return nil }
        lastReceivedSequence = sequence
        return plaintext
    }

    private func send(_ packet: Packet) {
        guard let connection = activeConnection,
              let body = try? JSONEncoder().encode(packet),
              body.count <= Self.maxPacketSize else { return }
        var lengthPrefix = UInt32(body.count).bigEndian
        var data = withUnsafeBytes(of: &lengthPrefix) { Data($0) }
        data.append(body)
        connection.send(content: data, contentContext: .defaultMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.publishStatus("发送配对消息失败：\(error.localizedDescription)")
        })
    }

    private func resetHandshake(publishCode: String?) {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        localPrivateKey = nil
        localNonce = nil
        remoteNonce = nil
        peerCommitment = nil
        remoteDeviceName = ""
        masterKey = nil
        sendKey = nil
        receiveKey = nil
        sendSequence = 0
        lastReceivedSequence = nil
        localConfirmed = false
        remoteConfirmed = false
        pairedOnQueue = false
        didStartHandshake = false
        receiveBuffer.removeAll()
        DispatchQueue.main.async {
            self.pairingCode = publishCode
            self.isSecurelyPaired = false
        }
    }

    private func publishStatus(_ text: String) {
        DispatchQueue.main.async { self.statusText = text }
    }

    private func publishDevices(_ devices: [NearbyMonitorDevice]) {
        DispatchQueue.main.async { self.nearbyDevices = devices }
    }

    private static func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}
