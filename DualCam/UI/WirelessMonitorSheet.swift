import SwiftUI
import WebRTC

struct WirelessMonitorSheet: View {
    @StateObject private var network = NetworkMonitorService()
    @StateObject private var rtc = LiveMonitorRTCService()
    @EnvironmentObject private var cam: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var mode: MonitorMode = .idle

    var body: some View {
        NavigationStack {
            List {
                Section("连接状态") {
                    Label(network.statusText,
                          systemImage: network.isSecurelyPaired ? "checkmark.shield.fill" : "dot.radiowaves.left.and.right")
                    Label(rtc.statusText, systemImage: mode == .idle ? "video.slash" : "video")
                        .foregroundStyle(.secondary)
                    Text("本机：\(network.localDeviceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("附近的设备") {
                    if network.nearbyDevices.isEmpty {
                        ContentUnavailableView(
                            "正在搜索 DualCam",
                            systemImage: "dot.radiowaves.left.and.right",
                            description: Text("请在两台设备上打开无线监看，并允许 DualCam 访问本地网络。连接优先使用局域网或点对点 Wi-Fi。")
                        )
                    } else {
                        ForEach(network.nearbyDevices) { device in
                            HStack(spacing: 12) {
                                Image(systemName: "iphone.gen3")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name).font(.body)
                                    Text("DualCam · 附近连接")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("连接") {
                                    HapticFeedback.play(.button)
                                    network.connect(to: device)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(network.isSecurelyPaired)
                            }
                        }
                    }
                }

                if let code = network.pairingCode, !network.isSecurelyPaired {
                    Section("安全配对验证码") {
                        VStack(spacing: 8) {
                            Text(code)
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .tracking(5)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            Text("请亲自核对两台设备显示的六位数字，必须完全一致。若不一致，立即拒绝连接。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 10) {
                                Button {
                                    HapticFeedback.play(.success)
                                    network.confirmPairing()
                                } label: {
                                    Label("验证码一致，确认", systemImage: "checkmark.shield.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(network.isSecurelyPaired)
                                Button(role: .destructive) {
                                    HapticFeedback.play(.button)
                                    network.rejectPairing()
                                } label: {
                                    Label("拒绝", systemImage: "xmark")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                if network.isSecurelyPaired {
                    Section("安全连接已建立") {
                        Label("信令已加密并完成双端确认", systemImage: "lock.fill")
                        Text("视频使用 WebRTC 的 DTLS-SRTP 加密。此版本不配置 STUN/TURN 云中继，只尝试直接连接可达的局域网候选地址。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("实时画面") {
                        Text("发送端传输的就是 DualCam 已合成的预览，包括双摄、画中画 / 分屏、滤镜和画幅。接收端不重新合成，也不发送麦克风音频。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button {
                                HapticFeedback.play(.button)
                                startSending()
                            } label: {
                                Label("发送合成画面", systemImage: "dot.radiowaves.left.and.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(mode != .idle || !network.isSecurelyPaired)

                            Button {
                                HapticFeedback.play(.button)
                                startReceiving()
                            } label: {
                                Label("接收画面", systemImage: "play.rectangle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(mode != .idle || !network.isSecurelyPaired)
                        }

                        if mode == .receiving {
                            ZStack {
                                Color.black
                                if rtc.remoteVideoTrack == nil {
                                    VStack(spacing: 8) {
                                        ProgressView().tint(.white)
                                        Text("等待相机端发送画面…")
                                            .font(.callout)
                                            .foregroundStyle(.white.opacity(0.8))
                                    }
                                } else {
                                    RemoteMonitorVideoSurface(track: rtc.remoteVideoTrack)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
                        }

                        if mode != .idle {
                            Button(role: .destructive) {
                                HapticFeedback.play(.button)
                                stopVideo()
                            } label: {
                                Label("停止视频", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            cleanup()
                        } label: {
                            Label("断开安全配对", systemImage: "lock.slash")
                        }
                    }
                }

                Section("连接方式说明") {
                    Text("Wi-Fi / Network.framework 负责发现附近设备；首次连接通过临时密钥交换和双方验证码确认建立安全信令；WebRTC 负责实时视频。蓝牙可由系统网络路径用于附近连接，但不是高清视频的主要传输方式。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("AirDrop 适合分享已经录制的照片或视频文件，不适合持续同步实时相机画面。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("无线画面同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        HapticFeedback.play(.button)
                        cleanup()
                        dismiss()
                    }
                }
            }
            .onAppear { configureAndStart() }
            .onDisappear { cleanup() }
            .onChange(of: network.pairingCode) { _, code in
                // A safety code to compare on both screens just appeared; get the user's attention.
                if code != nil { HapticFeedback.play(.focus) }
            }
            .onChange(of: network.isSecurelyPaired) { wasPaired, paired in
                if paired {
                    HapticFeedback.play(.success)
                } else if wasPaired, mode != .idle {
                    // The peer vanished mid-stream (no "stop" message ever arrives). Without this the
                    // receiver stays on a black screen with its own camera suspended, and the sender
                    // keeps pushing frames into a dead connection.
                    HapticFeedback.play(.error)
                    stopVideoAfterPeerLoss()
                }
            }
        }
    }

    private func configureAndStart() {
        let transport = rtc
        let peerService = network
        peerService.onSignalReceived = { [weak transport] data in
            transport?.handleSignal(data)
        }
        transport.onSignal = { [weak peerService, weak transport] data in
            guard let peerService else {
                transport?.reportSignallingFailure("安全连接已关闭")
                return
            }
            peerService.sendSignal(data)
        }

        let cameraManager = cam
        let frameSource = cameraManager.compositedFrameSource
        let modeBinding = $mode
        transport.onPeerStopped = {
            HapticFeedback.play(.button)
            frameSource.setSink(nil)
            cameraManager.setLocalCameraCaptureSuspended(false)
            DispatchQueue.main.async { modeBinding.wrappedValue = .idle }
        }
        network.start()
    }

    private func startSending() {
        guard network.isSecurelyPaired, mode == .idle else { return }
        mode = .sending
        let transport = rtc
        cam.compositedFrameSource.setSink { [weak transport] frame in
            transport?.push(frame)
        }
        rtc.startSending()
    }

    private func startReceiving() {
        guard network.isSecurelyPaired, mode == .idle else { return }
        mode = .receiving
        cam.compositedFrameSource.setSink(nil)
        cam.setLocalCameraCaptureSuspended(true)
        rtc.startReceiving()
    }

    private func stopVideo() {
        cam.compositedFrameSource.setSink(nil)
        cam.setLocalCameraCaptureSuspended(false)
        rtc.stopAndNotifyPeer()
        mode = .idle
    }

    /// The secure link dropped underneath a running video session: there is nobody to notify.
    private func stopVideoAfterPeerLoss() {
        cam.compositedFrameSource.setSink(nil)
        cam.setLocalCameraCaptureSuspended(false)
        rtc.stop()
        mode = .idle
    }

    private func cleanup() {
        cam.compositedFrameSource.setSink(nil)
        cam.setLocalCameraCaptureSuspended(false)
        rtc.onSignal = nil
        rtc.onPeerStopped = nil
        network.onSignalReceived = nil
        rtc.stop()
        network.stop()
        mode = .idle
    }
}

private enum MonitorMode {
    case idle
    case sending
    case receiving
}

private struct RemoteMonitorVideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .black
        context.coordinator.update(track: track, renderer: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.update(track: track, renderer: uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.update(track: nil, renderer: uiView)
    }

    final class Coordinator {
        private weak var currentTrack: RTCVideoTrack?

        func update(track: RTCVideoTrack?, renderer: RTCMTLVideoView) {
            if currentTrack === track { return }
            currentTrack?.remove(renderer)
            currentTrack = track
            track?.add(renderer)
        }
    }
}
