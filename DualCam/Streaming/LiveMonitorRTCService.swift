import AVFoundation
import Combine
import CoreVideo
import Foundation
import WebRTC

/// WebRTC media plane. Only the already-composited DualCam preview is sent.
/// ICE servers intentionally remain empty: this version attempts direct host-candidate LAN paths only.
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
    private let frameLock = NSLock()
    private var latestFrame: CompositedFrameSource.Frame?
    private var isDrainingFrames = false
    private var lastQueuedPTS = CMTime.invalid

    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var frameCapturer: CompositedVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var hasRemoteDescription = false
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var isSending = false
    private var isReceivingEnabled = false
    private var pendingOffer: Signal?
    private var lastAdaptedSize = CGSize.zero

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

        isSending = true
        let source = Self.factory.videoSource()
        let capturer = CompositedVideoCapturer(delegate: source)
        let track = Self.factory.videoTrack(with: source, trackId: "dualcam-composite")
        pc.add(track, streamIds: ["dualcam-stream"])
        videoSource = source
        frameCapturer = capturer
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
        guard isSending else { return }
        if frame.presentationTime.isValid, lastQueuedPTS.isValid {
            let delta = CMTimeGetSeconds(CMTimeSubtract(frame.presentationTime, lastQueuedPTS))
            if delta >= 0, delta < (1.0 / 30.0) { return }
        }
        if frame.presentationTime.isValid { lastQueuedPTS = frame.presentationTime }

        frameLock.lock()
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
        frameLock.unlock()

        if let frame, isSending, let source = videoSource, let capturer = frameCapturer {
            let size = CGSize(width: frame.width, height: frame.height)
            if size != lastAdaptedSize {
                lastAdaptedSize = size
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
            pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.updateStatus("接收连接响应失败：\(error.localizedDescription)")
                    return
                }
                self.hasRemoteDescription = true
                self.drainRemoteCandidates()
                self.updateStatus("正在接收实时视频…")
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

    func stopAndNotifyPeer() {
        send(Signal(type: "stop"))
        stop()
    }

    func stop() {
        isSending = false
        isReceivingEnabled = false
        pendingOffer = nil
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        videoSource = nil
        frameCapturer = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        pendingRemoteCandidates.removeAll()
        hasRemoteDescription = false
        lastAdaptedSize = .zero
        lastQueuedPTS = .invalid
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
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
        let transceiver = RTCRtpTransceiverInit()
        transceiver.direction = .recvOnly
        _ = pc.addTransceiver(of: .video, init: transceiver)

        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
            guard let self else { return }
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

    private func makePeerConnection() -> RTCPeerConnection? {
        let configuration = RTCConfiguration()
        configuration.iceServers = []
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
            DispatchQueue.main.async { self.remoteVideoTrack = track }
        }
    }

    private func send(_ signal: Signal) {
        guard let data = try? JSONEncoder().encode(signal) else { return }
        onSignal?(data)
    }

    private func updateStatus(_ value: String) {
        DispatchQueue.main.async { self.statusText = value }
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
            DispatchQueue.main.async { self.remoteVideoTrack = track }
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
        case .checking:
            updateStatus("正在连接设备…")
        case .disconnected:
            updateStatus("视频连接暂时中断")
        case .failed:
            updateStatus("局域网直连失败；请确认两台设备在同一 Wi-Fi，且路由器未隔离客户端")
        case .closed:
            updateStatus("视频连接已关闭")
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
            DispatchQueue.main.async { self.remoteVideoTrack = track }
        }
    }
}
