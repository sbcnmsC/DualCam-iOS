import Combine
import SwiftUI
import WebRTC

enum MonitorMode: Equatable {
    case idle
    case sending
    case receiving
}

/// Lives with the camera screen, not the pairing sheet. Dismissing the sheet must not
/// stop the secure signalling connection or detach the active video session.
final class WirelessMonitorSession: ObservableObject {
    let network = NetworkMonitorService()
    let rtc = LiveMonitorRTCService()

    @Published private(set) var mode: MonitorMode = .idle
    @Published private(set) var isSecurelyPaired = false
    @Published private(set) var nearbyDevices: [NearbyMonitorDevice] = []
    @Published private(set) var networkStatusText = "准备搜索附近设备"
    @Published private(set) var pairingCode: String?
    @Published private(set) var localDeviceName = "DualCam"
    @Published private(set) var rtcStatusText = "等待安全配对"
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var remoteVideoFrameReceived = false

    private var cancellables = Set<AnyCancellable>()
    private weak var cameraManager: CameraManager?
    private var didConfigure = false
    private var preShareResolution: ResolutionOption?
    private var preShareFPS: Int?

    init() {
        network.$nearbyDevices.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.nearbyDevices = $0 }
            .store(in: &cancellables)
        network.$statusText.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.networkStatusText = $0 }
            .store(in: &cancellables)
        network.$pairingCode.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.pairingCode = $0 }
            .store(in: &cancellables)
        network.$localDeviceName.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.localDeviceName = $0 }
            .store(in: &cancellables)
        network.$isSecurelyPaired.receive(on: DispatchQueue.main)
            .sink { [weak self] paired in
                guard let self else { return }
                let wasPaired = self.isSecurelyPaired
                self.isSecurelyPaired = paired
                if wasPaired && !paired {
                    self.stopVideo(notifyPeer: false)
                }
            }
            .store(in: &cancellables)
        rtc.$statusText.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rtcStatusText = $0 }
            .store(in: &cancellables)
        rtc.$remoteVideoTrack.receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                self?.remoteVideoTrack = track
                if track == nil { self?.remoteVideoFrameReceived = false }
            }
            .store(in: &cancellables)
    }

    func configure(cameraManager: CameraManager) {
        self.cameraManager = cameraManager
        guard !didConfigure else { return }
        didConfigure = true

        let peerService = network
        let transport = rtc
        // NetworkMonitorService delivers decrypted signalling on its private serial queue.
        // WebRTC peer-connection state is main-thread confined in LiveMonitorRTCService.
        peerService.onSignalReceived = { [weak transport] data in
            DispatchQueue.main.async {
                transport?.handleSignal(data)
            }
        }
        transport.onSignal = { [weak peerService, weak transport] data in
            guard let peerService else {
                transport?.reportSignallingFailure("安全连接已关闭")
                return
            }
            peerService.sendSignal(data)
        }
        transport.onPeerStopped = { [weak self] in
            DispatchQueue.main.async { self?.peerStopped() }
        }
    }

    func startDiscovery() {
        network.start()
    }

    /// A dismissed pairing sheet only closes discovery when pairing never completed.
    func pairingSheetDidClose() {
        if !isSecurelyPaired && mode == .idle {
            network.stop()
        }
    }

    func startSending() {
        guard isSecurelyPaired, mode == .idle, let cameraManager else { return }
        applyWirelessStreamPreset(to: cameraManager)
        mode = .sending
        remoteVideoFrameReceived = false
        let transport = rtc
        cameraManager.compositedFrameSource.setSink { [weak transport] frame in
            transport?.push(frame)
        }
        // Request the foreground Dynamic Island presentation first; only then start WebRTC
        // so the activity request isn't deferred behind video connection setup.
        Task { @MainActor [weak self] in
            guard let self, self.mode == .sending else { return }
            if let failure = await MonitorLiveActivityManager.shared.start() {
                self.cameraManager?.showToast("灵动岛未启动：\(failure)")
            }
            guard self.mode == .sending else {
                await MonitorLiveActivityManager.shared.stop()
                return
            }
            self.rtc.startSending()
        }
    }

    /// During wireless sharing use a bounded 1080p/60fps capture preset instead of encoding a
    /// large still-oriented preview at the camera's usual 30fps setting. Preserve the user's
    /// choices and restore them when sharing ends.
    private func applyWirelessStreamPreset(to cameraManager: CameraManager) {
        guard preShareResolution == nil, preShareFPS == nil else { return }
        preShareResolution = cameraManager.cfg.resolution
        preShareFPS = cameraManager.cfg.fps
        var streamConfig = cameraManager.cfg
        streamConfig.resolution = .p1080
        streamConfig.fps = 60
        if streamConfig != cameraManager.cfg {
            cameraManager.cfg = streamConfig
        }
    }

    private func restoreWirelessStreamPreset() {
        guard let cameraManager, let oldResolution = preShareResolution, let oldFPS = preShareFPS else { return }
        preShareResolution = nil
        preShareFPS = nil
        var restored = cameraManager.cfg
        // Restore only fields still carrying our temporary stream values, so later user changes
        // aren't overwritten if the parameter panel was used during a share session.
        if restored.resolution == .p1080 { restored.resolution = oldResolution }
        if restored.fps == 60 { restored.fps = oldFPS }
        if restored != cameraManager.cfg {
            cameraManager.cfg = restored
        }
    }

    func startReceiving() {
        guard isSecurelyPaired, mode == .idle, let cameraManager else { return }
        mode = .receiving
        remoteVideoFrameReceived = false
        cameraManager.compositedFrameSource.setSink(nil)
        cameraManager.setLocalCameraCaptureSuspended(true)
        rtc.startReceiving()
    }

    func stopVideo(notifyPeer: Bool = true) {
        // Always end any local Live Activity, even if the camera mode already
        // returned to idle after an interrupted/disconnected share.
        Task { @MainActor in await MonitorLiveActivityManager.shared.stop() }
        guard mode != .idle || rtc.remoteVideoTrack != nil else { return }
        let wasReceiving = mode == .receiving
        let wasSending = mode == .sending
        cameraManager?.compositedFrameSource.setSink(nil)
        if wasReceiving {
            cameraManager?.setLocalCameraCaptureSuspended(false)
        }
        if notifyPeer {
            rtc.stopAndNotifyPeer()
        } else {
            rtc.stop()
        }
        if wasSending { restoreWirelessStreamPreset() }
        mode = .idle
        remoteVideoFrameReceived = false
    }

    func disconnectPairing() {
        stopVideo(notifyPeer: false)
        network.stop()
    }

    func remoteFrameDidArrive() {
        if !remoteVideoFrameReceived {
            remoteVideoFrameReceived = true
        }
    }

    private func peerStopped() {
        // A peer stop is a terminal share-state transition as well.
        Task { @MainActor in await MonitorLiveActivityManager.shared.stop() }
        cameraManager?.compositedFrameSource.setSink(nil)
        if mode == .receiving {
            cameraManager?.setLocalCameraCaptureSuspended(false)
        }
        if mode == .sending { restoreWirelessStreamPreset() }
        mode = .idle
        remoteVideoFrameReceived = false
    }
}

struct WirelessMonitorSheet: View {
    @ObservedObject var session: WirelessMonitorSession
    @EnvironmentObject private var cam: CameraManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("连接状态") {
                    Label(
                        session.networkStatusText,
                        systemImage: session.isSecurelyPaired ? "checkmark.shield.fill" : "dot.radiowaves.left.and.right"
                    )
                    Label(session.rtcStatusText, systemImage: "video")
                        .foregroundStyle(.secondary)
                    Text("本机：\(session.localDeviceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("附近的设备") {
                    if session.nearbyDevices.isEmpty {
                        ContentUnavailableView(
                            "正在搜索 DualCam",
                            systemImage: "dot.radiowaves.left.and.right",
                            description: Text("请在两台设备上打开无线监看，并允许 DualCam 访问本地网络。")
                        )
                    } else {
                        ForEach(session.nearbyDevices) { device in
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
                                    session.network.connect(to: device)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(session.isSecurelyPaired)
                            }
                        }
                    }
                }

                if let code = session.pairingCode, !session.isSecurelyPaired {
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
                                    session.network.confirmPairing()
                                } label: {
                                    Label("验证码一致，确认", systemImage: "checkmark.shield.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(session.isSecurelyPaired)

                                Button(role: .destructive) {
                                    HapticFeedback.play(.button)
                                    session.network.rejectPairing()
                                } label: {
                                    Label("拒绝", systemImage: "xmark")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Section("配对完成后") {
                    Label("配对成功会自动返回主界面", systemImage: "arrow.uturn.backward")
                    Text("主界面可选择“全屏接收画面”或“共享本机合成画面”。关闭配对窗口不会结束安全连接；只有主动断开才会关闭会话。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("实时画面说明") {
                    Text("发送端共享 DualCam 已合成的预览，包含双摄、画中画 / 分屏、滤镜和画幅。接收端全屏展示远端画面，不启用麦克风音频。视频通过 WebRTC DTLS-SRTP 加密传输。")
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
                        session.pairingSheetDidClose()
                        dismiss()
                    }
                }
            }
            .onAppear {
                session.configure(cameraManager: cam)
                if session.isSecurelyPaired {
                    dismiss()
                } else {
                    session.startDiscovery()
                }
            }
            .onDisappear {
                session.pairingSheetDidClose()
            }
            .onChange(of: session.pairingCode) { _, code in
                if code != nil { HapticFeedback.play(.focus) }
            }
            .onChange(of: session.isSecurelyPaired) { _, paired in
                if paired {
                    HapticFeedback.play(.success)
                    dismiss()
                }
            }
        }
    }
}

struct RemoteMonitorVideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack?
    let onFirstFrame: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        // Fit the complete remote frame on iPad and iPhone; avoid cropping edges in landscape or split layouts.
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .black
        context.coordinator.update(track: track, renderer: view, onFirstFrame: onFirstFrame)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.update(track: track, renderer: uiView, onFirstFrame: onFirstFrame)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.update(track: nil, renderer: uiView, onFirstFrame: {})
    }

    final class Coordinator {
        private var currentTrack: RTCVideoTrack?
        private weak var currentRenderer: RTCMTLVideoView?
        private var frameProbe: IncomingFrameProbe?

        func update(track: RTCVideoTrack?, renderer: RTCMTLVideoView, onFirstFrame: @escaping () -> Void) {
            if currentTrack === track && currentRenderer === renderer { return }
            detach()
            currentTrack = track
            currentRenderer = renderer
            guard let track else { return }

            let probe = IncomingFrameProbe(onFirstFrame: onFirstFrame)
            frameProbe = probe
            track.add(renderer)
            track.add(probe)
        }

        private func detach() {
            if let currentTrack, let currentRenderer {
                currentTrack.remove(currentRenderer)
            }
            if let currentTrack, let frameProbe {
                currentTrack.remove(frameProbe)
            }
            currentTrack = nil
            currentRenderer = nil
            frameProbe = nil
        }
    }
}

private final class IncomingFrameProbe: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private let onFirstFrame: () -> Void
    private var hasReported = false

    init(onFirstFrame: @escaping () -> Void) {
        self.onFirstFrame = onFirstFrame
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        let shouldReport = !hasReported
        hasReported = true
        lock.unlock()
        if shouldReport {
            DispatchQueue.main.async { [onFirstFrame] in onFirstFrame() }
        }
    }
}
