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
final class NetworkMonitorService: ObservableObject {
    @Published private(set) var nearbyDevices: [NearbyMonitorDevice] = []
    @Published private(set) var statusText = "准备搜索附近设备"
    @Published private(set) var pairingCode: String?
    @Published private(set) var isSecurelyPaired = false
    @Published private(set) var localDeviceName: String

    var onSignalReceived: ((Data) -> Void)?

    private static let serviceType = "_dualcam-monitor._tcp"
    // v2: packets are length-prefixed (TCP is a byte stream, not a message stream).
    private static let protocolVersion = "DualCamMonitor/2"
    private static let maxPacketSize = 1_000_000
    private let queue = DispatchQueue(label: "com.dualcam.monitor.network", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var activeConnection: NWConnection?
    private var serviceName = ""
    private var isInitiator = false
    private var didSendHello = false

    private var localPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var localNonce: Data?
    private var remoteNonce: Data?
    private var remoteDeviceName = ""
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
            guard let key = self.sendKey,
                  let payload = self.seal(Data("confirmed".utf8), key: key, purpose: "pair-confirm") else {
                self.publishStatus("无法建立安全会话")
                return
            }
            self.send(Packet(type: "confirm", payload: payload))
            self.publishStatus(self.remoteConfirmed
                ? "正在完成安全配对…"
                : "本机已确认，等待另一台设备确认验证码…")
            self.updatePairedStateIfReady()
        }
    }

    func rejectPairing() {
        queue.async {
            self.activeConnection?.cancel()
            self.activeConnection = nil
            self.resetHandshake(publishCode: nil)
            self.publishStatus("已取消配对")
        }
    }

    func sendSignal(_ data: Data) {
        queue.async {
            guard self.pairedOnQueue, let key = self.sendKey else {
                self.publishStatus("信令尚未安全配对，已拒绝发送")
                return
            }
            guard let payload = self.seal(data, key: key, purpose: "webrtc-signal") else {
                self.publishStatus("加密视频信令失败")
                return
            }
            self.send(Packet(type: "signal", payload: payload))
        }
    }

    private static func makeParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        // Signalling packets are tiny and latency-sensitive; don't let Nagle batch them.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        return parameters
    }

    private func startListener() {
        do {
            let newListener = try NWListener(using: Self.makeParameters())
            newListener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.publishStatus("正在广播本机，等待安全连接")
                case .failed(let error):
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
        newBrowser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.publishStatus("设备发现失败：\(error.localizedDescription)")
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
        didSendHello = false
        localConfirmed = false
        remoteConfirmed = false
        pairedOnQueue = false
        receiveBuffer.removeAll()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.activeConnection === connection else { return }
            switch state {
            case .ready:
                if !self.didSendHello {
                    self.didSendHello = true
                    self.sendHello()
                    self.receiveNext(from: connection)
                }
            case .waiting(let error):
                self.publishStatus("正在等待网络路径：\(error.localizedDescription)")
            case .failed(let error):
                self.activeConnection = nil
                self.resetHandshake(publishCode: nil)
                self.publishStatus("连接失败：\(error.localizedDescription)")
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
                self.activeConnection?.cancel()
                self.activeConnection = nil
                self.resetHandshake(publishCode: nil)
                self.publishStatus("连接中断：\(error.localizedDescription)")
                return
            }
            if isComplete {
                self.activeConnection?.cancel()
                self.activeConnection = nil
                self.resetHandshake(publishCode: nil)
                self.publishStatus("对端已关闭连接")
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
                receiveBuffer.removeAll()
                publishStatus("收到无法识别的配对消息")
                activeConnection?.cancel()
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
        guard data.count <= 1_000_000,
              let packet = try? JSONDecoder().decode(Packet.self, from: data) else {
            publishStatus("收到无法识别的配对消息")
            return
        }

        switch packet.type {
        case "hello":
            guard packet.version == Self.protocolVersion,
                  let publicKeyData = packet.publicKey,
                  let nonce = packet.nonce,
                  nonce.count == 32,
                  let localPrivateKey else {
                publishStatus("对端版本不兼容或配对数据无效")
                activeConnection?.cancel()
                return
            }
            do {
                let remotePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
                let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
                remoteNonce = nonce
                remoteDeviceName = packet.deviceName ?? "DualCam 设备"
                let initiatorNonce = isInitiator ? localNonce! : nonce
                let responderNonce = isInitiator ? nonce : localNonce!
                let salt = initiatorNonce + responderNonce
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
            } catch {
                publishStatus("建立安全密钥失败")
                activeConnection?.cancel()
            }

        case "confirm":
            guard let payload = packet.payload,
                  let key = receiveKey,
                  let plaintext = open(payload, key: key, purpose: "pair-confirm"),
                  String(data: plaintext, encoding: .utf8) == "confirmed" else {
                publishStatus("安全配对确认校验失败")
                activeConnection?.cancel()
                return
            }
            remoteConfirmed = true
            publishStatus(localConfirmed ? "正在完成安全配对…" : "对端已确认；请核对本机验证码后确认")
            updatePairedStateIfReady()

        case "signal":
            guard pairedOnQueue, let payload = packet.payload, let key = receiveKey,
                  let plain = open(payload, key: key, purpose: "webrtc-signal") else {
                publishStatus("拒绝未经安全配对或校验失败的视频信令")
                return
            }
            DispatchQueue.main.async { self.onSignalReceived?(plain) }

        case "disconnect":
            activeConnection?.cancel()
            activeConnection = nil
            resetHandshake(publishCode: nil)
            publishStatus("对端结束了安全连接")

        default:
            publishStatus("忽略未知的配对消息")
        }
    }

    private func updatePairedStateIfReady() {
        guard localConfirmed, remoteConfirmed, masterKey != nil else { return }
        pairedOnQueue = true
        DispatchQueue.main.async {
            self.isSecurelyPaired = true
            self.statusText = "安全配对成功：\(self.remoteDeviceName)"
        }
    }

    private func seal(_ data: Data, key: SymmetricKey, purpose: String) -> Data? {
        do {
            let box = try AES.GCM.seal(data, using: key, authenticating: Data("\(Self.protocolVersion)/\(purpose)".utf8))
            return box.combined
        } catch {
            return nil
        }
    }

    private func open(_ data: Data, key: SymmetricKey, purpose: String) -> Data? {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key, authenticating: Data("\(Self.protocolVersion)/\(purpose)".utf8))
        } catch {
            return nil
        }
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
        localPrivateKey = nil
        localNonce = nil
        remoteNonce = nil
        remoteDeviceName = ""
        masterKey = nil
        sendKey = nil
        receiveKey = nil
        localConfirmed = false
        remoteConfirmed = false
        pairedOnQueue = false
        didSendHello = false
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
