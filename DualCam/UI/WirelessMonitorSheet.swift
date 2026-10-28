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

    // Track the receiver's UI state and forward only changed fields. Sending deltas instead of
    // the entire local config prevents untouched defaults (especially resolution/FPS) from
    // overwriting the sending device's active stream preset.
    private var lastObservedConfig: Config?
    private var lastObservedSlotStates: [SlotState]?
    private var lastObservedCaptureMode: CaptureMode?
    private var lastObservedTimerSeconds: Int?
    private var lastObservedFlashEnabled: Bool?
    private var lastObservedComboIndex: Int?
    private var lastObservedParamTarget: Int?
    private var pendingRemoteControlPayload: [String: String] = [:]
    private var pendingRemoteControlWorkItem: DispatchWorkItem?

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

        lastObservedConfig = cameraManager.cfg
        lastObservedSlotStates = cameraManager.slotStates
        lastObservedCaptureMode = cameraManager.captureMode
        lastObservedTimerSeconds = cameraManager.timerSeconds
        lastObservedFlashEnabled = cameraManager.flashEnabled
        lastObservedComboIndex = cameraManager.comboIndex
        lastObservedParamTarget = cameraManager.paramTarget

        cameraManager.$cfg.dropFirst()
            .sink { [weak self] value in self?.observeRemoteConfig(value) }
            .store(in: &cancellables)
        cameraManager.$slotStates.dropFirst()
            .sink { [weak self] value in self?.observeRemoteSlotStates(value) }
            .store(in: &cancellables)
        cameraManager.$captureMode.dropFirst()
            .sink { [weak self] value in self?.observeRemoteCaptureMode(value) }
            .store(in: &cancellables)
        cameraManager.$timerSeconds.dropFirst()
            .sink { [weak self] value in self?.observeRemoteTimer(value) }
            .store(in: &cancellables)
        cameraManager.$flashEnabled.dropFirst()
            .sink { [weak self] value in self?.observeRemoteFlash(value) }
            .store(in: &cancellables)
        cameraManager.$comboIndex.dropFirst()
            .sink { [weak self] value in self?.observeRemoteCombo(value) }
            .store(in: &cancellables)
        cameraManager.$paramTarget.dropFirst()
            .sink { [weak self] value in self?.observeRemoteParameterTarget(value) }
            .store(in: &cancellables)

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
        transport.onRemoteCommand = { [weak self] command, payload in
            guard let self else { return }
            DispatchQueue.main.async {
                switch self.mode {
                case .sending:
                    switch command {
                    case "shutter":
                        self.cameraManager?.shutterTapped()
                    case "burst-start":
                        if self.cameraManager?.canStartBurstCapture == true {
                            self.cameraManager?.startBurstCapture()
                        }
                    case "burst-stop":
                        self.cameraManager?.stopBurstCapture()
                    case "focus":
                        guard let values = payload,
                              let x = Double(values["x"] ?? ""),
                              let y = Double(values["y"] ?? ""),
                              x.isFinite, y.isFinite else { return }
                        self.cameraManager?.focus(atNormalized: CGPoint(
                            x: min(max(x, 0), 1),
                            y: min(max(y, 0), 1)
                        ))
                    case "state":
                        if let payload { self.applyRemoteCameraState(payload) }
                    default:
                        break
                    }
                case .receiving, .idle:
                    break
                }
            }
        }
    }

    func startDiscovery() {
        network.start()
    }

    func restartDiscovery() {
        network.restartDiscovery()
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
        // Clear any toast left over from the previous camera action before sharing starts.
        cameraManager.toast = nil
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
        // Keep the local camera alive so the receiving device retains its full camera controls.
        cameraManager.setLocalCameraCaptureSuspended(false)
        rtc.startReceiving()
    }

    func requestRemoteShutter() {
        guard mode == .receiving, isSecurelyPaired else { return }
        rtc.sendRemoteCommand("shutter")
    }

    @discardableResult
    func requestRemoteBurstStart() -> Bool {
        guard mode == .receiving, isSecurelyPaired else { return false }
        rtc.sendRemoteCommand("burst-start")
        return true
    }

    func requestRemoteBurstStop() {
        guard mode == .receiving, isSecurelyPaired else { return }
        rtc.sendRemoteCommand("burst-stop")
    }

    func requestRemoteFocus(atNormalized point: CGPoint) {
        guard mode == .receiving, isSecurelyPaired else { return }
        rtc.sendRemoteCommand("focus", payload: [
            "x": String(Double(min(max(point.x, 0), 1))),
            "y": String(Double(min(max(point.y, 0), 1)))
        ])
    }

    private func observeRemoteConfig(_ value: Config) {
        let previous = lastObservedConfig
        lastObservedConfig = value
        guard mode == .receiving, let previous else { return }
        enqueueRemoteControlDelta(configDelta(from: previous, to: value))
    }

    private func observeRemoteSlotStates(_ value: [SlotState]) {
        let previous = lastObservedSlotStates
        lastObservedSlotStates = value
        guard mode == .receiving, let previous else { return }
        enqueueRemoteControlDelta(slotStateDelta(from: previous, to: value))
    }

    private func observeRemoteCaptureMode(_ value: CaptureMode) {
        let previous = lastObservedCaptureMode
        lastObservedCaptureMode = value
        guard mode == .receiving, let previous, previous != value else { return }
        enqueueRemoteControlDelta(["captureMode": value.rawValue])
    }

    private func observeRemoteTimer(_ value: Int) {
        let previous = lastObservedTimerSeconds
        lastObservedTimerSeconds = value
        guard mode == .receiving, let previous, previous != value else { return }
        enqueueRemoteControlDelta(["timerSeconds": String(min(max(value, 0), 60))])
    }

    private func observeRemoteFlash(_ value: Bool) {
        let previous = lastObservedFlashEnabled
        lastObservedFlashEnabled = value
        guard mode == .receiving, let previous, previous != value else { return }
        enqueueRemoteControlDelta(["flashEnabled": String(value)])
    }

    private func observeRemoteCombo(_ value: Int) {
        let previous = lastObservedComboIndex
        lastObservedComboIndex = value
        guard mode == .receiving, let previous, previous != value,
              let cameraManager, cameraManager.combos.indices.contains(value) else { return }
        let combo = cameraManager.combos[value]
        enqueueRemoteControlDelta([
            "combo.a": combo.a.rawValue,
            "combo.b": combo.b.rawValue
        ])
    }

    private func observeRemoteParameterTarget(_ value: Int) {
        let previous = lastObservedParamTarget
        lastObservedParamTarget = value
        guard mode == .receiving, let previous, previous != value else { return }
        enqueueRemoteControlDelta(["paramTarget": String(value == 1 ? 1 : 0)])
    }

    private func enqueueRemoteControlDelta(_ delta: [String: String]) {
        guard mode == .receiving, isSecurelyPaired, !delta.isEmpty else { return }
        for (key, value) in delta { pendingRemoteControlPayload[key] = value }
        pendingRemoteControlWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .receiving, self.isSecurelyPaired else {
                self?.pendingRemoteControlPayload.removeAll()
                return
            }
            let payload = self.pendingRemoteControlPayload
            self.pendingRemoteControlPayload.removeAll()
            guard !payload.isEmpty else { return }
            self.rtc.sendRemoteCommand("state", payload: payload)
        }
        pendingRemoteControlWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    private func configDelta(from old: Config, to new: Config) -> [String: String] {
        var delta: [String: String] = [:]
        if old.layout != new.layout { delta["cfg.layout"] = new.layout.rawValue }
        if old.swapped != new.swapped { delta["cfg.swapped"] = String(new.swapped) }
        if old.aspect != new.aspect { delta["cfg.aspect"] = new.aspect.rawValue }
        if old.freeAspect != new.freeAspect { delta["cfg.freeAspect"] = String(Double(new.freeAspect)) }
        if old.pipCenter != new.pipCenter {
            delta["cfg.pipX"] = String(Double(new.pipCenter.x))
            delta["cfg.pipY"] = String(Double(new.pipCenter.y))
        }
        if old.pipWidth != new.pipWidth { delta["cfg.pipWidth"] = String(Double(new.pipWidth)) }
        if old.pipRatio != new.pipRatio { delta["cfg.pipRatio"] = new.pipRatio.rawValue }
        if old.pipShape != new.pipShape { delta["cfg.pipShape"] = new.pipShape.rawValue }
        if old.pipCorner != new.pipCorner { delta["cfg.pipCorner"] = String(Double(new.pipCorner)) }
        if old.pipBorder != new.pipBorder { delta["cfg.pipBorder"] = String(Double(new.pipBorder)) }
        if old.pipOpacity != new.pipOpacity { delta["cfg.pipOpacity"] = String(Double(new.pipOpacity)) }
        if old.pipSnap != new.pipSnap { delta["cfg.pipSnap"] = String(new.pipSnap) }
        if old.splitRatio != new.splitRatio { delta["cfg.splitRatio"] = String(Double(new.splitRatio)) }
        if old.mirrorFront != new.mirrorFront { delta["cfg.mirrorFront"] = String(new.mirrorFront) }
        if old.filter != new.filter { delta["cfg.filter"] = new.filter.rawValue }
        if old.filterIntensity != new.filterIntensity { delta["cfg.filterIntensity"] = String(Double(new.filterIntensity)) }
        if old.resolution != new.resolution { delta["cfg.resolution"] = new.resolution.rawValue }
        if old.fps != new.fps { delta["cfg.fps"] = String(new.fps) }
        if old.outputMode != new.outputMode { delta["cfg.outputMode"] = new.outputMode.rawValue }
        if old.livePhoto != new.livePhoto { delta["cfg.livePhoto"] = String(new.livePhoto) }
        if old.liveMotion != new.liveMotion { delta["cfg.liveMotion"] = new.liveMotion.rawValue }
        if old.lowLight != new.lowLight { delta["cfg.lowLight"] = String(new.lowLight) }
        if old.stabilization != new.stabilization { delta["cfg.stabilization"] = String(new.stabilization) }
        if old.showGrid != new.showGrid { delta["cfg.showGrid"] = String(new.showGrid) }
        return delta
    }

    private func slotStateDelta(from old: [SlotState], to new: [SlotState]) -> [String: String] {
        var delta: [String: String] = [:]
        for slot in 0..<min(min(old.count, new.count), 2) {
            let a = old[slot]
            let b = new[slot]
            let prefix = "slot.\(slot)."
            if a.zoom != b.zoom { delta[prefix + "zoom"] = String(Double(b.zoom)) }
            if a.exposureBias != b.exposureBias { delta[prefix + "exposureBias"] = String(b.exposureBias) }
            if a.manualExposure != b.manualExposure { delta[prefix + "manualExposure"] = String(b.manualExposure) }
            if a.iso != b.iso { delta[prefix + "iso"] = String(b.iso) }
            if a.shutter != b.shutter { delta[prefix + "shutter"] = String(b.shutter) }
            if a.manualWB != b.manualWB { delta[prefix + "manualWB"] = String(b.manualWB) }
            if a.temperature != b.temperature { delta[prefix + "temperature"] = String(b.temperature) }
            if a.tint != b.tint { delta[prefix + "tint"] = String(b.tint) }
            if a.manualFocus != b.manualFocus { delta[prefix + "manualFocus"] = String(b.manualFocus) }
            if a.lensPosition != b.lensPosition { delta[prefix + "lensPosition"] = String(b.lensPosition) }
            if a.locked != b.locked { delta[prefix + "locked"] = String(b.locked) }
        }
        return delta
    }

    private func applyRemoteCameraState(_ payload: [String: String]) {
        guard mode == .sending, let cameraManager else { return }

        // Match a lens combination by hardware identity rather than assuming both devices have
        // the same menu index. Unsupported combinations are safely ignored by the receiver.
        if let rawA = payload["combo.a"], let rawB = payload["combo.b"],
           let a = LensSpec(rawValue: rawA), let b = LensSpec(rawValue: rawB),
           let index = cameraManager.combos.firstIndex(where: { $0.a == a && $0.b == b }),
           index != cameraManager.comboIndex {
            cameraManager.selectCombo(index)
        }

        var config = cameraManager.cfg
        var configChanged = false
        if let raw = payload["cfg.layout"], let value = LayoutMode(rawValue: raw) { config.layout = value; configChanged = true }
        if let raw = payload["cfg.swapped"], let value = Bool(raw) { config.swapped = value; configChanged = true }
        if let raw = payload["cfg.aspect"], let value = CanvasAspect(rawValue: raw) { config.aspect = value; configChanged = true }
        if let raw = payload["cfg.freeAspect"], let value = Double(raw), value.isFinite { config.freeAspect = CGFloat(min(max(value, 0.2), 4.0)); configChanged = true }
        if let raw = payload["cfg.pipX"], let value = Double(raw), value.isFinite {
            config.pipCenter.x = CGFloat(min(max(value, 0.0), 1.0)); configChanged = true
        }
        if let raw = payload["cfg.pipY"], let value = Double(raw), value.isFinite {
            config.pipCenter.y = CGFloat(min(max(value, 0.0), 1.0)); configChanged = true
        }
        if let raw = payload["cfg.pipWidth"], let value = Double(raw), value.isFinite { config.pipWidth = CGFloat(min(max(value, 0.16), 0.9)); configChanged = true }
        if let raw = payload["cfg.pipRatio"], let value = PiPRatio(rawValue: raw) { config.pipRatio = value; configChanged = true }
        if let raw = payload["cfg.pipShape"], let value = PiPShape(rawValue: raw) { config.pipShape = value; configChanged = true }
        if let raw = payload["cfg.pipCorner"], let value = Double(raw), value.isFinite { config.pipCorner = CGFloat(min(max(value, 0.0), 0.5)); configChanged = true }
        if let raw = payload["cfg.pipBorder"], let value = Double(raw), value.isFinite { config.pipBorder = CGFloat(min(max(value, 0.0), 8.0)); configChanged = true }
        if let raw = payload["cfg.pipOpacity"], let value = Double(raw), value.isFinite { config.pipOpacity = CGFloat(min(max(value, 0.0), 1.0)); configChanged = true }
        if let raw = payload["cfg.pipSnap"], let value = Bool(raw) { config.pipSnap = value; configChanged = true }
        if let raw = payload["cfg.splitRatio"], let value = Double(raw), value.isFinite { config.splitRatio = CGFloat(min(max(value, 0.05), 0.95)); configChanged = true }
        if let raw = payload["cfg.mirrorFront"], let value = Bool(raw) { config.mirrorFront = value; configChanged = true }
        if let raw = payload["cfg.filter"], let value = FilterKind(rawValue: raw) { config.filter = value; configChanged = true }
        if let raw = payload["cfg.filterIntensity"], let value = Double(raw), value.isFinite { config.filterIntensity = CGFloat(min(max(value, 0.0), 1.0)); configChanged = true }
        if let raw = payload["cfg.resolution"], let value = ResolutionOption(rawValue: raw) { config.resolution = value; configChanged = true }
        if let raw = payload["cfg.fps"], let value = Int(raw) { config.fps = min(max(value, 15), 60); configChanged = true }
        if let raw = payload["cfg.outputMode"], let value = OutputMode(rawValue: raw) { config.outputMode = value; configChanged = true }
        if let raw = payload["cfg.livePhoto"], let value = Bool(raw) { config.livePhoto = value; configChanged = true }
        if let raw = payload["cfg.liveMotion"], let value = LiveMotionSource(rawValue: raw) { config.liveMotion = value; configChanged = true }
        if let raw = payload["cfg.lowLight"], let value = Bool(raw) { config.lowLight = value; configChanged = true }
        if let raw = payload["cfg.stabilization"], let value = Bool(raw) { config.stabilization = value; configChanged = true }
        if let raw = payload["cfg.showGrid"], let value = Bool(raw) { config.showGrid = value; configChanged = true }
        if configChanged, config != cameraManager.cfg { cameraManager.cfg = config }

        if let raw = payload["captureMode"], let value = CaptureMode(rawValue: raw) {
            cameraManager.captureMode = value
        }
        if let raw = payload["timerSeconds"], let value = Int(raw) {
            cameraManager.timerSeconds = min(max(value, 0), 60)
        }
        if let raw = payload["flashEnabled"], let value = Bool(raw) {
            cameraManager.flashEnabled = value
        }
        if let raw = payload["paramTarget"], let value = Int(raw) {
            cameraManager.paramTarget = value == 1 ? 1 : 0
        }

        var states = cameraManager.slotStates
        var changedSlots = Set<Int>()
        for slot in 0..<min(states.count, 2) {
            let prefix = "slot.\(slot)."
            var state = states[slot]
            if let raw = payload[prefix + "zoom"], let value = Double(raw), value.isFinite { state.zoom = CGFloat(max(value, 1)); changedSlots.insert(slot) }
            if let raw = payload[prefix + "exposureBias"], let value = Float(raw), value.isFinite { state.exposureBias = value; changedSlots.insert(slot) }
            if let raw = payload[prefix + "manualExposure"], let value = Bool(raw) { state.manualExposure = value; changedSlots.insert(slot) }
            if let raw = payload[prefix + "iso"], let value = Float(raw), value.isFinite { state.iso = min(max(value, 25), 6400); changedSlots.insert(slot) }
            if let raw = payload[prefix + "shutter"], let value = Double(raw), value.isFinite { state.shutter = min(max(value, 0), 1); changedSlots.insert(slot) }
            if let raw = payload[prefix + "manualWB"], let value = Bool(raw) { state.manualWB = value; changedSlots.insert(slot) }
            if let raw = payload[prefix + "temperature"], let value = Float(raw), value.isFinite { state.temperature = min(max(value, 2000), 12000); changedSlots.insert(slot) }
            if let raw = payload[prefix + "tint"], let value = Float(raw), value.isFinite { state.tint = min(max(value, -150), 150); changedSlots.insert(slot) }
            if let raw = payload[prefix + "manualFocus"], let value = Bool(raw) { state.manualFocus = value; changedSlots.insert(slot) }
            if let raw = payload[prefix + "lensPosition"], let value = Float(raw), value.isFinite { state.lensPosition = min(max(value, 0), 1); changedSlots.insert(slot) }
            if let raw = payload[prefix + "locked"], let value = Bool(raw) { state.locked = value; changedSlots.insert(slot) }
            states[slot] = state
        }
        if !changedSlots.isEmpty {
            cameraManager.slotStates = states
            for slot in changedSlots.sorted() {
                cameraManager.setZoom(slot: slot, factor: states[slot].zoom)
                cameraManager.applyFocus(slot)
                cameraManager.applyExposure(slot)
                cameraManager.applyWhiteBalance(slot)
            }
        }
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
        if wasSending {
            // Do not let any transient sharing message reappear after the session stops.
            cameraManager?.toast = nil
        }
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
        if mode == .sending {
            cameraManager?.toast = nil
            restoreWirelessStreamPreset()
        }
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
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: searchStatus.contains("失败") || searchStatus.contains("等待网络") ? "exclamationmark.triangle" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(searchStatus.contains("失败") ? Color.orange : Color.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(searchStatus)
                                        .foregroundStyle(.primary)
                                    Text("两台设备请同时打开 DualCam 并连接同一 Wi‑Fi；首次使用时请允许“本地网络”访问。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
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
                            session.restartDiscovery()
                        } label: {
                            Label("重新搜索", systemImage: "arrow.clockwise")
                        }
                        .disabled(session.isSecurelyPaired)
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

/// Shown only after the device-search and safety-match sheet has closed.
struct WirelessMonitorRolePickerSheet: View {
    let onReceive: () -> Void
    let onShare: () -> Void
    let onDisconnect: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("共享方式") {
                    Button(action: onReceive) {
                        Label("接收画面", systemImage: "rectangle.inset.filled.and.person.filled")
                            .foregroundStyle(Color(uiColor: .systemBlue))
                    }

                    Button(action: onShare) {
                        Label("共享本机画面", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(Color(uiColor: .systemBlue))
                    }
                }

                Section {
                    Button(role: .destructive, action: onDisconnect) {
                        Label("断开连接", systemImage: "xmark.circle")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("选择共享方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .tint(Color(uiColor: .systemBlue))
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
