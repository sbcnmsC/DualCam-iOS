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
    let onPairingSucceeded: () -> Void
    @EnvironmentObject private var cam: CameraManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let code = session.pairingCode, !session.isSecurelyPaired {
                    Section("安全匹配") {
                        VStack(spacing: 14) {
                            Text(code)
                                .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                                .tracking(8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .accessibilityLabel("安全配对验证码 \(code)")

                            Text("确认两台设备显示的验证码一致")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Button {
                                HapticFeedback.play(.success)
                                session.network.confirmPairing()
                            } label: {
                                Text("确认连接")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.isSecurelyPaired)

                            Button("拒绝连接", role: .destructive) {
                                HapticFeedback.play(.button)
                                session.network.rejectPairing()
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section("附近设备") {
                        if session.nearbyDevices.isEmpty {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(searchStatus)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                        } else {
                            ForEach(session.nearbyDevices) { device in
                                Button {
                                    HapticFeedback.play(.button)
                                    session.network.connect(to: device)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad.gen2" : "iphone.gen3")
                                            .font(.system(size: 22))
                                            .foregroundStyle(Color(uiColor: .systemBlue))
                                            .frame(width: 32, height: 32)

                                        Text(device.name)
                                            .foregroundStyle(.primary)

                                        Spacer(minLength: 0)

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(session.isSecurelyPaired)
                            }
                        }

                        Button {
                            HapticFeedback.play(.selection)
                            session.startDiscovery()
                        } label: {
                            Label("重新搜索", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("连接设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") {
                        session.pairingSheetDidClose()
                        dismiss()
                    }
                }
            }
            .tint(Color(uiColor: .systemBlue))
        }
        .presentationDragIndicator(.visible)
        .onAppear {
            session.configure(cameraManager: cam)
            if session.isSecurelyPaired {
                onPairingSucceeded()
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
                onPairingSucceeded()
                dismiss()
            }
        }
    }

    private var searchStatus: String {
        let value = session.networkStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "准备搜索附近设备" {
            return "正在搜索…"
        }
        return value
    }
}

/// A dedicated wireless-control screen shown after pairing. Tapping a mode changes the
/// active peer role; the shortcut's long-press menu offers the same choices directly.
struct WirelessMonitorRolePickerSheet: View {
    let onWirelessReceiveTap: () -> Void
    let onWirelessShareTap: () -> Void
    let onDisconnect: () -> Void

    @Environment(\\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("选择工作模式")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("点击任一模式即可切换。长按顶部无线快捷按钮，也可以直接选择模式。")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)

                Button(action: onWirelessReceiveTap) {
                    modeRow(
                        title: "接收画面",
                        subtitle: "在这台设备上查看对端的合成画面",
                        icon: "rectangle.inset.filled.and.person.filled"
                    )
                }
                .buttonStyle(.plain)

                Button(action: onWirelessShareTap) {
                    modeRow(
                        title: "共享本机画面",
                        subtitle: "将本机双摄合成画面发送到另一台设备",
                        icon: "airplayvideo"
                    )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 6)

                Button(role: .destructive, action: onDisconnect) {
                    Label("断开设备连接", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("无线互联")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func modeRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemBlue))
                .frame(width: 48, height: 48)
                .background(Color(uiColor: .systemBlue).opacity(0.1), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
