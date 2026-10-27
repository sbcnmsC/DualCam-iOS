import Combine
import SwiftUI
import UIKit
import WebRTC

enum MonitorMode: Equatable {
    case idle
    case sending
    case receiving
}

/// Lives with the camera screen, not the pairing sheet. Dismissing the sheet must not
/// stop the secure signalling connection or detach the active video session.
final class WirelessMonitorSession: ObservableObject {
    /// Shared with LiveActivityIntent so the Dynamic Island's Stop action can end the active
    /// WebRTC session instead of merely dismissing the activity UI.
    static let shared = WirelessMonitorSession()

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
                self.cameraManager?.showToast(failure)
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

    func stopVideo(notifyPeer: Bool = true, endActivity: Bool = true) {
        // Always end any local Live Activity, even if the camera mode already
        // returned to idle after an interrupted/disconnected share.
        if endActivity {
            Task { @MainActor in await MonitorLiveActivityManager.shared.stop() }
        }
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

    /// Runs from the Live Activity's app-process intent. Stop the actual sender/receiver first,
    /// then await ActivityKit cleanup so tapping "关闭共享" cannot leave a live stream behind.
    @MainActor
    func stopFromLiveActivity() async {
        stopVideo(endActivity: false)
        await MonitorLiveActivityManager.shared.stop()
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
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    headerCard
                    connectionStatusCard
                    nearbyDevicesCard
                    if let code = session.pairingCode, !session.isSecurelyPaired {
                        pairingCodeCard(code)
                    }
                    privacyCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("无线互联")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        HapticFeedback.play(.button)
                        session.pairingSheetDidClose()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .tint(Color(uiColor: .systemBlue))
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(uiColor: .systemBlue),
                                Color(uiColor: .systemIndigo)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 5) {
                    Text("让两台设备协同取景")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("同步 DualCam 实时合成画面")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("双摄 · 画中画 · 滤镜")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(uiColor: .systemBlue))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(session.isSecurelyPaired ? Color(uiColor: .systemGreen) : Color(uiColor: .systemOrange))
                    .frame(width: 8, height: 8)
                Text(session.isSecurelyPaired ? "安全配对已建立" : "等待设备连接")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(session.localDeviceName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.76),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 1)
        )
    }

    private var connectionStatusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeading("连接状态", subtitle: "网络发现与实时视频链路")

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: session.isSecurelyPaired ? "checkmark.shield.fill" : "wifi")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(session.isSecurelyPaired ? Color(uiColor: .systemGreen) : Color(uiColor: .systemBlue))
                    .frame(width: 38, height: 38)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地网络")
                        .font(.subheadline.weight(.semibold))
                    Text(session.networkStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "video.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemIndigo))
                    .frame(width: 38, height: 38)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时画面")
                        .font(.subheadline.weight(.semibold))
                    Text(session.rtcStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 1)
        )
    }

    private var nearbyDevicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                cardHeading("附近的设备", subtitle: "选择另一台 DualCam 设备")
                Spacer()
                Button {
                    HapticFeedback.play(.selection)
                    session.startDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .systemBlue))
                        .frame(width: 34, height: 34)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重新搜索设备")
            }

            if session.nearbyDevices.isEmpty {
                VStack(spacing: 11) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(Color(uiColor: .systemBlue))
                        .frame(width: 62, height: 62)
                        .background(Color(uiColor: .systemBlue).opacity(0.09), in: Circle())
                    Text("正在寻找附近设备")
                        .font(.subheadline.weight(.semibold))
                    Text("请让另一台设备也打开无线互联，并允许 DualCam 访问本地网络。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300)
                    ProgressView()
                        .tint(Color(uiColor: .systemBlue))
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(session.nearbyDevices.enumerated()), id: \.element.id) { index, device in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.gen3")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Color(uiColor: .systemBlue))
                                .frame(width: 46, height: 46)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("DualCam · 附近可用")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button {
                                HapticFeedback.play(.button)
                                session.network.connect(to: device)
                            } label: {
                                Text("连接")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(session.isSecurelyPaired)
                        }
                        .padding(.vertical, 10)

                        if index < session.nearbyDevices.count - 1 {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 1)
        )
    }

    private func pairingCodeCard(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBlue))
                VStack(alignment: .leading, spacing: 3) {
                    Text("验证安全连接")
                        .font(.headline)
                    Text("两台设备都要显示相同验证码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(code)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(8)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .accessibilityLabel("安全配对验证码 \(code)")

            Text("请亲自核对两台设备上的数字。只有完全一致时才确认；不一致就拒绝连接。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                HapticFeedback.play(.success)
                session.network.confirmPairing()
            } label: {
                Label("验证码一致，确认连接", systemImage: "checkmark.shield.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.isSecurelyPaired)

            Button(role: .destructive) {
                HapticFeedback.play(.button)
                session.network.rejectPairing()
            } label: {
                Text("拒绝此次连接")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(uiColor: .systemBlue).opacity(0.22), lineWidth: 1)
        )
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fingers.spread.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(uiColor: .systemGreen))
                .frame(width: 36, height: 36)
                .background(Color(uiColor: .systemGreen).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("端到端保护你的画面")
                    .font(.subheadline.weight(.semibold))
                Text("确认配对后，选择共享本机合成画面或全屏接收画面。视频使用 WebRTC DTLS-SRTP 加密传输，不启用麦克风音频。关闭此窗口不会结束已建立的会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.70),
                    in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private func cardHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
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
