import AVFoundation
import Combine
import CoreVideo
import Foundation
import WebRTC

/// WebRTC media plane. Only the already-composited DualCam preview is sent.
/// Uses direct LAN candidates plus public STUN discovery; no TURN relay or cloud media server is used.
final class LiveMonitorRTCService: NSObject, ObservableObject {
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var statusText = "等待安全配对"

    var onSignal: ((Data) -> Void)?
    var onPeerStopped: (() -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private let frameQueue = DispatchQueue(label: "com.dualcam.monitor.frames", qos: .userInteractive)
    // frameLock guards the frame path shared by the camera queue (push), frameQueue (drain) and the
    // main thread (start/stop): latestFrame, isDrainingFrames, lastQueuedPTS, isSending,
    // videoSource, frameCapturer and lastAdaptedSize.
    private let frameLock = NSLock()
    private var latestFrame: CompositedFrameSource.Frame?
    private var isDrainingFrames = false
    private var lastQueuedPTS = CMTime.invalid
    private var isSending = false
    private var videoSource: RTCVideoSource?
    private var frameCapturer: CompositedVideoCapturer?
    private var lastAdaptedSize = CGSize.zero

    // Everything below is main-thread only. WebRTC completion handlers hop back to main first.
    private var peerConnection: RTCPeerConnection?
    private var localVideoTrack: RTCVideoTrack?
    private var hasRemoteDescription = false
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var isReceivingEnabled = false
    private var pendingOffer: Signal?
    private var announcedConnected = false

    private struct Signal: Codable {
        let type: String
        var sdp: String? = nil
        var sdpType: String? = nil
        var candidate: String? = nil
        var sdpMLineIndex: Int32? = nil
        var sdpMid: String? = nil
    }

    func startSending() {
        guard peerConnection == nil else { return }
        guard let pc = makePeerConnection() else {
            updateStatus("无法创建视频连接")
            return
        }

        let source = Self.factory.videoSource()
        let capturer = CompositedVideoCapturer(delegate: source)
        let track = Self.factory.videoTrack(with: source, trackId: "dualcam-composite")
        pc.add(track, streamIds: ["dualcam-stream"])
        frameLock.lock()
        videoSource = source
        frameCapturer = capturer
        isSending = true
        frameLock.unlock()
        localVideoTrack = track
        updateStatus("正在建立局域网视频连接…")

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self, weak pc] description, error in
            guard let self, let pc, let description else {
                self?.updateStatus("生成视频请求失败：\(error?.localizedDescription ?? "未知错误")")
                return
            }
            pc.setLocalDescription(description) { [weak self] error in
                guard let self, error == nil else {
                    self?.updateStatus("设置本地视频描述失败：\(error?.localizedDescription ?? "未知错误")")
                    return
                }
                self.send(Signal(type: "offer", sdp: description.sdp, sdpType: "offer"))
            }
        }
    }

    func startReceiving() {
        isReceivingEnabled = true
        if let offer = pendingOffer {
            pendingOffer = nil
            handleOffer(offer)
        } else {
            updateStatus("已准备接收画面；请在发送端启动传输")
        }
    }

    /// Called by the camera queue. Keeps only the newest frame, so encoder backpressure never
    /// grows a queue of stale frames or blocks real-time capture/preview.
    func push(_ frame: CompositedFrameSource.Frame) {
        frameLock.lock()
        guard isSending else {
            frameLock.unlock()
            return
        }
        // Cap at ~30 fps for a 60 fps source. The threshold sits below 1/30 s on purpose: camera
        // timestamps jitter by a few ms, and an exact 1/30 s cut-off would also drop roughly every
        // other frame of a plain 30 fps feed.
        if frame.presentationTime.isValid, lastQueuedPTS.isValid {
            let delta = CMTimeGetSeconds(CMTimeSubtract(frame.presentationTime, lastQueuedPTS))
            if delta >= 0, delta < (0.8 / 30.0) {
                frameLock.unlock()
                return
            }
        }
        if frame.presentationTime.isValid { lastQueuedPTS = frame.presentationTime }
        latestFrame = frame
        let shouldStartDrain = !isDrainingFrames
        if shouldStartDrain { isDrainingFrames = true }
        frameLock.unlock()

        if shouldStartDrain {
            frameQueue.async { [weak self] in self?.drainLatestFrame() }
        }
    }

    private func drainLatestFrame() {
        frameLock.lock()
        let frame = latestFrame
        latestFrame = nil
        let sending = isSending
        let source = videoSource
        let capturer = frameCapturer
        var needsAdapt = false
        if let frame {
            let size = CGSize(width: frame.width, height: frame.height)
            if size != lastAdaptedSize {
                lastAdaptedSize = size
                needsAdapt = true
            }
        }
        frameLock.unlock()

        if let frame, sending, let source, let capturer {
            if needsAdapt {
                source.adaptOutputFormat(toWidth: Int32(frame.width), height: Int32(frame.height), fps: 30)
            }
            capturer.capture(pixelBuffer: frame.pixelBuffer, presentationTime: frame.presentationTime)
        }

        frameLock.lock()
        let hasNewerFrame = latestFrame != nil
        if !hasNewerFrame { isDrainingFrames = false }
        frameLock.unlock()
        if hasNewerFrame {
            frameQueue.async { [weak self] in self?.drainLatestFrame() }
        }
    }

    func handleSignal(_ data: Data) {
        guard let signal = try? JSONDecoder().decode(Signal.self, from: data) else { return }
        switch signal.type {
        case "offer":
            guard isReceivingEnabled else {
                pendingOffer = signal
                updateStatus("对端已发起视频请求，点击“接收画面”")
                return
            }
            handleOffer(signal)
        case "answer":
            guard let sdp = signal.sdp, let pc = peerConnection else { return }
            pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self, weak pc] error in
                // WebRTC calls this on its signalling thread; connection state is main-thread only.
                DispatchQueue.main.async {
                    guard let self, let pc, self.peerConnection === pc else { return }
                    if let error {
                        self.updateStatus("接收连接响应失败：\(error.localizedDescription)")
                        return
                    }
                    self.hasRemoteDescription = true
                    self.drainRemoteCandidates()
                    self.updateStatus("正在接收实时视频…")
                }
            }
        case "candidate":
            guard let candidate = signal.candidate, let line = signal.sdpMLineIndex else { return }
            let remote = RTCIceCandidate(sdp: candidate, sdpMLineIndex: line, sdpMid: signal.sdpMid)
            if hasRemoteDescription {
                peerConnection?.add(remote, completionHandler: { [weak self] error in
                    if let error { self?.updateStatus("添加网络候选失败：\(error.localizedDescription)") }
                })
            } else {
                pendingRemoteCandidates.append(remote)
            }
        case "stop":
            stop()
            DispatchQueue.main.async { self.onPeerStopped?() }
        default:
            break
        }
    }

    func reportSignallingFailure(_ message: String) {
        updateStatus("信令发送失败：\(message)")
    }

    func stopAndNotifyPeer() {
        send(Signal(type: "stop"))
        stop()
    }

    func stop() {
        // Stop the frame path first (under the lock the camera/frame queues use), then tear down WebRTC.
        frameLock.lock()
        isSending = false
        videoSource = nil
        frameCapturer = nil
        lastAdaptedSize = .zero
        lastQueuedPTS = .invalid
        latestFrame = nil
        frameLock.unlock()

        isReceivingEnabled = false
        pendingOffer = nil
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        pendingRemoteCandidates.removeAll()
        hasRemoteDescription = false
        announcedConnected = false
        updateStatus("视频已停止")
    }

    private func handleOffer(_ signal: Signal) {
        guard let sdp = signal.sdp else { return }
        let queuedCandidates = pendingRemoteCandidates
        closePeerConnection()
        isReceivingEnabled = true
        pendingRemoteCandidates = queuedCandidates

        guard let pc = makePeerConnection() else {
            updateStatus("无法创建接收端连接")
            return
        }
        pendingRemoteCandidates = queuedCandidates
        // The incoming offer already contains the sender's video m-line.
        // Let setRemoteDescription create/match its receiver transceiver; adding a second
        // recvOnly transceiver here can produce an unmatched m-line and a connected-but-black view.
        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self, weak pc] error in
            // WebRTC calls this on its signalling thread; connection state is main-thread only.
            DispatchQueue.main.async {
                guard let self, let pc, self.peerConnection === pc else { return }
                if let error {
                    self.updateStatus("接收视频请求失败：\(error.localizedDescription)")
                    return
                }
                self.hasRemoteDescription = true
                self.drainRemoteCandidates()
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                pc.answer(for: constraints) { [weak self] answer, error in
                    guard let self, let answer else {
                        self?.updateStatus("生成接收端响应失败：\(error?.localizedDescription ?? "未知错误")")
                        return
                    }
                    pc.setLocalDescription(answer) { [weak self] error in
                        guard let self, error == nil else {
                            self?.updateStatus("设置接收端响应失败：\(error?.localizedDescription ?? "未知错误")")
                            return
                        }
                        self.send(Signal(type: "answer", sdp: answer.sdp, sdpType: "answer"))
                        self.updateStatus("等待接收实时画面…")
                        self.refreshRemoteTrack(from: pc)
                    }
                }
            }
        }
    }

    private func makePeerConnection() -> RTCPeerConnection? {
        let configuration = RTCConfiguration()
        // Keep direct LAN candidates, but also gather server-reflexive candidates.
        // Secure pairing/signalling can succeed even when WebRTC media cannot traverse
        // the network path; STUN helps when local-network paths are insufficient.
        configuration.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
        ]
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            return nil
        }
        closePeerConnection()
        peerConnection = pc
        pc.delegate = self
        hasRemoteDescription = false
        remoteVideoTrack = nil
        return pc
    }

    private func closePeerConnection() {
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
    }

    private func drainRemoteCandidates() {
        guard hasRemoteDescription, let pc = peerConnection else { return }
        let queued = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for candidate in queued {
            pc.add(candidate, completionHandler: { [weak self] error in
                if let error { self?.updateStatus("添加网络候选失败：\(error.localizedDescription)") }
            })
        }
    }

    private func refreshRemoteTrack(from pc: RTCPeerConnection) {
        if let track = pc.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first {
            DispatchQueue.main.async {
                track.isEnabled = true
                self.remoteVideoTrack = track
                self.updateStatus("已建立远端视频轨道，等待画面帧…")
            }
        }
    }

    private func send(_ signal: Signal) {
        guard let data = try? JSONEncoder().encode(signal) else { return }
        onSignal?(data)
    }

    private func updateStatus(_ value: String) {
        DispatchQueue.main.async { self.statusText = value }
    }

    /// Tactile confirmation when the live link comes up or drops. Fires once per transition, so
    /// the repeated `.connected` / `.completed` ICE states don't buzz twice.
    private func announceConnection(connected: Bool, hapticOnLoss: Bool = false) {
        DispatchQueue.main.async {
            if connected {
                guard !self.announcedConnected else { return }
                self.announcedConnected = true
                HapticFeedback.play(.success)
            } else {
                self.announcedConnected = false
                if hapticOnLoss { HapticFeedback.play(.error) }
            }
        }
    }
}

private final class CompositedVideoCapturer: RTCVideoCapturer {
    func capture(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let scaledTime = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        let timestamp = scaledTime.isValid ? Int64(scaledTime.value) : Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: timestamp
        )
        delegate?.capturer(self, didCapture: frame)
    }
}

extension LiveMonitorRTCService: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            DispatchQueue.main.async {
                track.isEnabled = true
                self.remoteVideoTrack = track
                self.updateStatus("收到远端视频轨道，正在显示合成画面…")
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        DispatchQueue.main.async { self.remoteVideoTrack = nil }
    }
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed:
            updateStatus("实时画面已连接")
            announceConnection(connected: true)
        case .checking:
            updateStatus("正在连接设备…")
        case .disconnected:
            updateStatus("视频连接暂时中断")
            announceConnection(connected: false, hapticOnLoss: false)
        case .failed:
            updateStatus("局域网直连失败；请确认两台设备在同一 Wi-Fi，且路由器未隔离客户端")
            announceConnection(connected: false, hapticOnLoss: true)
        case .closed:
            updateStatus("视频连接已关闭")
            announceConnection(connected: false, hapticOnLoss: false)
        default:
            break
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        send(Signal(type: "candidate", candidate: candidate.sdp,
                    sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid))
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? RTCVideoTrack {
            DispatchQueue.main.async {
                track.isEnabled = true
                self.remoteVideoTrack = track
                self.updateStatus("远端开始发送视频帧…")
            }
        }
    }
}
