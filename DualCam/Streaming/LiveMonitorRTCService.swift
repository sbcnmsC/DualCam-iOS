import AVFoundation
import Combine
import CoreVideo
import Foundation
import WebRTC

/// WebRTC media plane for sending DualCam's already-composited preview.
/// Signalling is carried only over the encrypted MultipeerConnectivity session.
final class LiveMonitorRTCService: NSObject, ObservableObject {
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var statusText = "等待配对设备"

    var onSignal: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var frameCapturer: CompositedVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var hasRemoteDescription = false
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var isSending = false
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
        guard peerConnection == nil else {
            updateStatus("无线传输已经启动")
            return
        }
        guard let pc = makePeerConnection() else {
            updateStatus("无法创建 WebRTC 连接")
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
        updateStatus("正在建立低延迟视频连接…")

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self, weak pc] description, error in
            guard let self, let pc, let description else {
                self?.updateStatus("生成视频连接请求失败：\(error?.localizedDescription ?? "未知错误")")
                return
            }
            pc.setLocalDescription(description) { [weak self] error in
                guard let self, error == nil else {
                    self?.updateStatus("设置本地视频连接失败：\(error?.localizedDescription ?? "未知错误")")
                    return
                }
                self.send(Signal(type: "offer", sdp: description.sdp, sdpType: "offer"))
            }
        }
    }

    func push(_ frame: CompositedFrameSource.Frame) {
        guard isSending, let source = videoSource, let capturer = frameCapturer else { return }
        let size = CGSize(width: frame.width, height: frame.height)
        if size != lastAdaptedSize {
            lastAdaptedSize = size
            source.adaptOutputFormat(toWidth: Int32(frame.width), height: Int32(frame.height), fps: 30)
        }
        capturer.capture(pixelBuffer: frame.pixelBuffer, presentationTime: frame.presentationTime)
    }

    func handleSignal(_ data: Data) {
        guard let signal = try? JSONDecoder().decode(Signal.self, from: data) else { return }
        switch signal.type {
        case "offer":
            handleOffer(signal)
        case "answer":
            guard let sdp = signal.sdp, let pc = peerConnection else { return }
            let remote = RTCSessionDescription(type: .answer, sdp: sdp)
            pc.setRemoteDescription(remote) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.updateStatus("接收连接响应失败：\(error.localizedDescription)")
                    return
                }
                self.hasRemoteDescription = true
                self.drainRemoteCandidates()
                self.updateStatus("正在接收视频…")
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
        default:
            break
        }
    }

    func stop() {
        isSending = false
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
        updateStatus("视频已停止")
    }

    private func handleOffer(_ signal: Signal) {
        guard let sdp = signal.sdp else { return }
        stop()
        guard let pc = makePeerConnection() else {
            updateStatus("无法创建接收端连接")
            return
        }
        let transceiver = RTCRtpTransceiverInit()
        transceiver.direction = .recvOnly
        _ = pc.addTransceiver(of: .video, init: transceiver)

        let remote = RTCSessionDescription(type: .offer, sdp: sdp)
        pc.setRemoteDescription(remote) { [weak self] error in
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
        configuration.iceServers = [] // LAN-only: do not use STUN/TURN or cloud relay.
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            return nil
        }
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = pc
        pc.delegate = self
        hasRemoteDescription = false
        pendingRemoteCandidates.removeAll()
        remoteVideoTrack = nil
        return pc
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
        DispatchQueue.main.async {
            self.statusText = value
            self.onStatus?(value)
        }
    }
}

private final class CompositedVideoCapturer: RTCVideoCapturer {
    func capture(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let time = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: Int64(time.value)
        )
        delegate.capturer(self, didCapture: frame)
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
            updateStatus("局域网直连失败，请确认两台设备在同一 Wi-Fi")
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
