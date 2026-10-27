import SwiftUI
import UIKit

private enum WirelessSetupSheetRoute: String, Identifiable {
    case deviceSearch
    case rolePicker

    var id: String { rawValue }
}

struct CameraScreen: View {
    @EnvironmentObject private var cam: CameraManager
    @State private var showPanel = false
    @State private var panelTab: PanelTab = .pip
    @AppStorage("dualcam.quickParameterSelected") private var selectedQuickParameterName = "曝光补偿"
    @State private var showTimerSettings = false
    @State private var wirelessSheetRoute: WirelessSetupSheetRoute?
    @State private var shouldShowRolePickerAfterPairing = false
    @State private var shouldStartCompositeShareAfterPairing = false
    @State private var pendingWirelessMode: MonitorMode?
    @State private var wirelessRolePickerDetent: PresentationDetent = .large
    @StateObject private var wirelessSession = WirelessMonitorSession.shared
    @State private var showCreativeGallery = false
    @State private var timerDraft = 5
    @State private var bottomBarHeight: CGFloat = 222
    @State private var zoomControlBottom: CGFloat = 0
    @State private var shutterButtonTop: CGFloat = 0
    @State private var currentOrientation: UIInterfaceOrientation = .portrait

    private let topBarHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            // Build 94 baseline: derive the device canvas by restoring the system safe-area insets.
            // Preview size comes from the selected capture aspect, not the smaller gap between controls.
            let insets = geo.safeAreaInsets
            let canvasSize = CGSize(
                width: geo.size.width + insets.leading + insets.trailing,
                height: geo.size.height + insets.top + insets.bottom
            )
            let canvasOffset = CGSize(width: -insets.leading, height: -insets.top)
            // The app window remains portrait-locked. Physical device orientation only selects
            // the parameter panel's presentation; it must never resize the camera canvas or controls.
            let controlCanvasWidth: CGFloat = geo.size.width
            let isParameterPanelLandscape = currentOrientation.isLandscape
            // Keep the floating landscape panel compact in physical landscape coordinates.
            // It is rotated as one unit back onto the portrait-locked window.
            let landscapePanelWidth = min(canvasSize.height * 0.90, 760)
            let landscapePanelHeight = min(canvasSize.width * 0.82, 320)
            let activeOrientation = currentOrientation
            let iconRotationDegrees: CGFloat = activeOrientation == .landscapeLeft
                ? 90
                : (activeOrientation == .landscapeRight ? -90 : 0)
            let topControlsBottom = insets.top + topBarHeight
            let dockTop = canvasSize.height - insets.bottom - bottomBarHeight
            let hasSharingStopControl = wirelessSession.mode == .sending

            // Fit the selected output ratio against the whole device canvas.
            // In free mode this exactly matches the iPhone screen; fixed ratios use the largest
            // possible frame instead of shrinking to the control-free area.
            let fittedPreviewSize = fitSize(in: canvasSize)
            // For 9:16, fit the frame into the measured space from the canvas top
            // to the actual shutter outer-ring top. Keep 9:16 intact instead of letting
            // the frame run behind the shutter when the full-width version is too tall.
            let previewSize: CGSize = {
                guard cam.cfg.aspect == .r916, shutterButtonTop > 0 else {
                    return fittedPreviewSize
                }
                let targetHeight = min(fittedPreviewSize.height, max(shutterButtonTop, 100))
                let targetWidth = min(fittedPreviewSize.width, targetHeight * cam.cfg.aspectRatio)
                return CGSize(width: targetWidth, height: targetWidth / max(cam.cfg.aspectRatio, 0.1))
            }()
            let previewBottomLimit = dockTop - 12
            let previewTop = previewOriginY(
                previewHeight: previewSize.height,
                topLimit: topControlsBottom + 14,
                bottomLimit: previewBottomLimit
            )

            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                PreviewStage(size: previewSize, iconRotationDegrees: iconRotationDegrees)
                    .frame(width: previewSize.width, height: previewSize.height)
                    .frame(width: canvasSize.width, height: canvasSize.height, alignment: .top)
                    .offset(x: canvasOffset.width, y: canvasOffset.height + previewTop)
                    // 切换画幅时取景框平滑伸缩 / 移动，而不是瞬间跳变
                    .animation(.smooth(duration: 0.3), value: cam.cfg.aspect)

                // Top and bottom controls float above the preview and keep their own hit targets.
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        TopBar(
                            onTimerTap: {
                                timerDraft = cam.timerSeconds > 0 ? cam.timerSeconds : 5
                                showTimerSettings = true
                            },
                            onWirelessMonitorTap: {
                                // A single tap opens the wireless feature's own mode screen.
                                if wirelessSession.isSecurelyPaired {
                                    wirelessRolePickerDetent = .large
                                    wirelessSheetRoute = .rolePicker
                                } else {
                                    wirelessSheetRoute = .deviceSearch
                                }
                            },
                            onWirelessReceiveTap: {
                                switchWirelessMode(to: .receiving)
                            },
                            onWirelessShareTap: {
                                switchWirelessMode(to: .sending)
                            },
                            onShareCompositeTap: {
                                switchWirelessMode(to: .sending)
                            },
                            isSharingComposite: wirelessSession.mode == .sending,
                            onParameterTap: { parameterName in
                                selectedQuickParameterName = parameterName
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                    panelTab = .params
                                    showPanel = true
                                }
                                HapticFeedback.play(.selection)
                            },
                            iconRotationDegrees: iconRotationDegrees,
                            compactLayout: false
                        )
                        .frame(width: controlCanvasWidth, height: topBarHeight)
                    }
                    .frame(width: controlCanvasWidth, height: topBarHeight, alignment: .leading)

                    Spacer(minLength: 0)

                    if showPanel && !isParameterPanelLandscape {
                        ToolPanel(tab: $panelTab, isLandscape: false, rotationDegrees: iconRotationDegrees)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    BottomBar(
                        showPanel: $showPanel,
                        panelTab: $panelTab,
                        onAlbumTap: { openNativePhotos() },
                        onAlbumSwipeUp: { showCreativeGallery = true },
                        bottomDockPadding: max(insets.bottom + 44, 80),
                        isLandscape: false,
                        iconRotationDegrees: iconRotationDegrees
                    )
                }
                .frame(width: controlCanvasWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(5)

                // When the device is physically landscape, render a real landscape-sized
                // parameter canvas and rotate that panel as one unit. The camera interface and
                // its preview remain portrait-locked underneath.
                if showPanel && isParameterPanelLandscape {
                    ZStack {
                        Color.clear

                        ToolPanel(
                            tab: $panelTab,
                            isLandscape: true,
                            rotationDegrees: 0,
                            onClose: {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                    showPanel = false
                                }
                            }
                        )
                        .frame(width: landscapePanelWidth, height: landscapePanelHeight)
                        .rotationEffect(.degrees(iconRotationDegrees))
                        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: iconRotationDegrees)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .offset(x: canvasOffset.width, y: canvasOffset.height)
                    .transition(.opacity)
                    .zIndex(15)
                }

                OverlayLayer(topSafeAreaInset: insets.top)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .offset(x: canvasOffset.width, y: canvasOffset.height)

                if showTimerSettings {
                    TimerSettingsOverlay(
                        timerDraft: $timerDraft,
                        isPresented: $showTimerSettings,
                        iconRotationDegrees: iconRotationDegrees
                    )
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .offset(x: canvasOffset.width, y: canvasOffset.height)
                        .zIndex(20)
                }

                // Receiver mode is intentionally distraction-free: show the incoming
                // composited video edge-to-edge, with only a close control on top.
                if wirelessSession.mode == .receiving {
                    ZStack(alignment: .topTrailing) {
                        Color.black.ignoresSafeArea()

                        if let track = wirelessSession.remoteVideoTrack {
                            RemoteMonitorVideoSurface(track: track) {
                                wirelessSession.remoteFrameDidArrive()
                            }
                            .frame(width: canvasSize.width, height: canvasSize.height)
                        }

                        Button {
                            HapticFeedback.play(.button)
                            wirelessSession.stopVideo()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭画面")
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .offset(x: canvasOffset.width, y: canvasOffset.height)
                    .ignoresSafeArea()
                    .zIndex(100)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hasSharingStopControl {
                    Button {
                        HapticFeedback.play(.button)
                        wirelessSession.stopVideo()
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 6, height: 6)
                            Text("结束共享")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .background(Color.red, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("结束无线共享")
                    .padding(.trailing, 8)
                    // Place the stop pill beside the Dynamic Island rather than below it.
                    .offset(y: 20 - insets.top)
                    .zIndex(200)
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.88), value: isParameterPanelLandscape)
            .onAppear {
                wirelessSession.configure(cameraManager: cam)
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                currentOrientation = resolvedInterfaceOrientation(for: canvasSize)
                updateFreeAspect(for: canvasSize)
            }
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
            .onChange(of: canvasSize) { _, newSize in
                let orientation = resolvedInterfaceOrientation(for: newSize)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    currentOrientation = orientation
                }
                updateFreeAspect(for: newSize)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                // Scene orientation distinguishes left- and right-landscape even when bounds stay the same.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    let orientation = resolvedInterfaceOrientation(for: canvasSize)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        currentOrientation = orientation
                    }
                    // Keep capture/composition orientation unchanged; only UI icons follow device rotation.
                }
            }
            .onPreferenceChange(CameraBottomBarHeightPreferenceKey.self) { height in
                guard height > 0, abs(bottomBarHeight - height) > 1 else { return }
                bottomBarHeight = height
            }
            .onPreferenceChange(CameraZoomBottomPreferenceKey.self) { bottom in
                guard bottom > 0, abs(zoomControlBottom - bottom) > 0.5 else { return }
                zoomControlBottom = bottom
            }
            .onPreferenceChange(CameraShutterTopPreferenceKey.self) { top in
                guard top > 0, abs(shutterButtonTop - top) > 0.5 else { return }
                shutterButtonTop = top
            }
        }
        // Preserve Build 94's safe-area measurement and expand the preview canvas explicitly.
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.22), value: showPanel)
        .sheet(item: $wirelessSheetRoute, onDismiss: {
            // Pairing remains separate from mode selection. A mode chosen by long-press
            // is resumed immediately after the safety-code sheet finishes.
            guard wirelessSession.isSecurelyPaired else {
                shouldShowRolePickerAfterPairing = false
                shouldStartCompositeShareAfterPairing = false
                pendingWirelessMode = nil
                return
            }
            if let requestedMode = pendingWirelessMode {
                pendingWirelessMode = nil
                shouldShowRolePickerAfterPairing = false
                shouldStartCompositeShareAfterPairing = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    guard wirelessSheetRoute == nil, wirelessSession.isSecurelyPaired else { return }
                    switchWirelessMode(to: requestedMode)
                }
                return
            }
            guard wirelessSession.mode == .idle else {
                shouldShowRolePickerAfterPairing = false
                shouldStartCompositeShareAfterPairing = false
                return
            }
            if shouldStartCompositeShareAfterPairing {
                shouldStartCompositeShareAfterPairing = false
                shouldShowRolePickerAfterPairing = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    guard wirelessSheetRoute == nil,
                          wirelessSession.isSecurelyPaired,
                          wirelessSession.mode == .idle else { return }
                    wirelessSession.startSending()
                }
                return
            }
            guard shouldShowRolePickerAfterPairing else { return }
            shouldShowRolePickerAfterPairing = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                guard wirelessSheetRoute == nil,
                      wirelessSession.isSecurelyPaired,
                      wirelessSession.mode == .idle else { return }
                wirelessRolePickerDetent = .large
                wirelessSheetRoute = .rolePicker
            }
        }) { route in
            switch route {
            case .deviceSearch:
                WirelessMonitorSheet(
                    session: wirelessSession,
                    onPairingSucceeded: {
                        shouldShowRolePickerAfterPairing = true
                    }
                )
                .environmentObject(cam)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)

            case .rolePicker:
                WirelessMonitorRolePickerSheet(
                    onWirelessReceiveTap: {
                        shouldShowRolePickerAfterPairing = false
                        wirelessSheetRoute = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            switchWirelessMode(to: .receiving)
                        }
                    },
                    onWirelessShareTap: {
                        shouldShowRolePickerAfterPairing = false
                        wirelessSheetRoute = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            switchWirelessMode(to: .sending)
                        }
                    },
                    onDisconnect: {
                        shouldShowRolePickerAfterPairing = false
                        wirelessSheetRoute = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            wirelessSession.disconnectPairing()
                        }
                    }
                )
                .presentationDetents([.medium, .large], selection: $wirelessRolePickerDetent)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
            }
        }
        .fullScreenCover(isPresented: $showCreativeGallery) {
            CreativeGalleryView()
                .environmentObject(cam)
        }
        .modifier(HardwareCameraCaptureModifier())
    }

    /// Switch the paired peer to the requested wireless role. Switching an active session
    /// first tears down its current stream, then starts the newly selected role.
    private func switchWirelessMode(to target: MonitorMode) {
        guard target != .idle else { return }
        guard wirelessSession.isSecurelyPaired else {
            pendingWirelessMode = target
            shouldShowRolePickerAfterPairing = false
            shouldStartCompositeShareAfterPairing = false
            wirelessSheetRoute = .deviceSearch
            return
        }
        guard wirelessSession.mode != target else { return }

        let startTarget: () -> Void = {
            guard wirelessSession.isSecurelyPaired, wirelessSession.mode == .idle else { return }
            switch target {
            case .receiving:
                wirelessSession.startReceiving()
            case .sending:
                wirelessSession.startSending()
            case .idle:
                break
            }
        }

        if wirelessSession.mode != .idle {
            wirelessSession.stopVideo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: startTarget)
        } else {
            startTarget()
        }
    }

    /// Open the native iPhone Photos app from the album shortcut.
    /// These Photos URL schemes are undocumented by Apple, so a fallback is attempted.
    private func openNativePhotos() {
        guard let primaryURL = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(primaryURL, options: [:]) { opened in
            guard !opened, let fallbackURL = URL(string: "photos://") else { return }
            UIApplication.shared.open(fallbackURL, options: [:]) { fallbackOpened in
                if !fallbackOpened {
                    DispatchQueue.main.async {
                        cam.showToast("无法自动打开系统照片，请从桌面打开“照片”")
                    }
                }
            }
        }
    }

    private func fitSize(in size: CGSize) -> CGSize {
        let availableHeight = max(size.height, 100)
        if cam.cfg.aspect == .free {
            // Portrait in portrait; in landscape preserve that same portrait canvas ratio,
            // centered in the wider screen so grid, focus and PiP keep one consistent coordinate space.
            if size.width > size.height {
                let width = min(size.width, availableHeight * cam.cfg.aspectRatio)
                return CGSize(width: width, height: width / max(cam.cfg.aspectRatio, 0.1))
            }
            return CGSize(width: size.width, height: availableHeight)
        }
        let aspect = cam.cfg.aspectRatio
        let w = min(size.width, availableHeight * aspect)
        return CGSize(width: w, height: w / aspect)
    }

    /// 取景框的纵向起点（屏幕坐标）。
    /// - 全屏自由：贴顶铺满。
    /// - 9:16：预览底边与快门按钮外圈上沿相切，按实时测量位置定位。
    /// - 其余比例：在「顶栏下沿 ~ 底栏上沿」之间垂直居中；画面比这块区域还高（如 3:4）时贴着顶栏下沿，
    ///   底部自然压在焦段条下面，和系统相机一致。
    private func previewOriginY(previewHeight: CGFloat, topLimit: CGFloat, bottomLimit: CGFloat) -> CGFloat {
        switch cam.cfg.aspect {
        case .free:
            return 0
        case .r916 where shutterButtonTop > 0:
            return max(0, shutterButtonTop - previewHeight)
        case .r916 where zoomControlBottom > 0:
            // Fallback for the first layout pass before the shutter position is measured.
            return max(0, zoomControlBottom - previewHeight)
        default:
            let free = bottomLimit - topLimit
            guard previewHeight < free else { return topLimit }
            return topLimit + (free - previewHeight) / 2
        }
    }

    private func resolvedInterfaceOrientation(for size: CGSize) -> UIInterfaceOrientation {
        // The app interface is locked to portrait. Read physical device orientation only
        // for rotating the small symbols; never use it to rotate the preview or rearrange controls.
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .portrait, .portraitUpsideDown:
            return .portrait
        default:
            return currentOrientation
        }
    }

    private func updateFreeAspect(for size: CGSize) {
        // The free canvas ratio is defined in portrait and intentionally held during landscape.
        // This keeps the preview/PiP coordinate space stable while only controls reflow.
        guard size.width <= size.height else { return }
        cam.updateFreeAspect(width: size.width, height: max(size.height, 100))
    }
}


/// Route iPhone 16 Pro Camera Control capture events through the same shutter path as the UI.
/// iOS 17 remains supported; Camera Control integration is active on iOS 18 and later.
private struct HardwareCameraCaptureModifier: ViewModifier {
    @EnvironmentObject private var cam: CameraManager

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent(isEnabled: cam.ready, action: { event in
                guard event.phase == .ended, cam.ready else { return }
                cam.shutterTapped()
            })
        } else {
            content
        }
    }
}

// MARK: - 预览区域与手势

struct PreviewStage: View {
    @EnvironmentObject private var cam: CameraManager
    let size: CGSize
    var iconRotationDegrees: CGFloat = 0

    @State private var pressing = false
    @State private var adjusting = false
    @State private var pinching = false
    @State private var zoomStart: CGFloat? = nil
    @State private var blinkOpacity: Double = 0

    var body: some View {
        ZStack {
            PreviewRepresentable()

            if cam.cfg.showGrid {
                GridOverlay()
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }

            // 最底层的手势层：点按对焦、上下滑动调曝光、双指变焦
            Color.clear
                .contentShape(Rectangle())
                .gesture(backgroundGesture)
                .simultaneousGesture(zoomGesture)

            // 小窗 / 分割线盖在手势层之上，各自的手势优先
            if cam.cfg.layout == .pip {
                PiPOverlay(size: size, iconRotationDegrees: iconRotationDegrees)
            } else {
                SplitDivider(size: size)
            }

            if let marker = cam.focusMarker {
                let slot = min(max(marker.slot ?? cam.mainSlot, 0), 1)
                let focusX = min(max(marker.point.x * size.width, 36), max(36, size.width - 36))
                let focusY = min(max(marker.point.y * size.height, 36), max(36, size.height - 36))
                let railOnLeft = focusX > size.width * 0.64
                let railHeight = min(124, max(76, size.height - 64))
                let groupHeight = railHeight + 50
                let groupCenterX = focusX + (railOnLeft ? -26 : 26)
                let groupCenterY = min(max(focusY, groupHeight / 2), max(groupHeight / 2, size.height - groupHeight / 2))
                FocusMarkerView(
                    exposureBias: marker.exposureBias ?? cam.slotStates[slot].exposureBias,
                    minBias: cam.slotInfos[slot].minBias,
                    maxBias: cam.slotInfos[slot].maxBias,
                    isDisabled: cam.slotStates[slot].manualExposure || cam.slotStates[slot].locked,
                    railOnLeft: railOnLeft,
                    trackHeight: railHeight,
                    onExposureChanged: { cam.adjustExposureBias(slot: slot, value: $0) },
                    iconRotationDegrees: iconRotationDegrees
                )
                .position(
                    x: min(max(groupCenterX, 61), max(61, size.width - 61)),
                    y: groupCenterY
                )
                .id(marker.id)
                .transition(.opacity)
            }

            VStack {
                HStack {
                    OutputModePill()
                    Spacer()
                }
                .padding(10)
                Spacer()
            }

            // 拍照处理 / 切换镜头 / 重建会话时的「处理中」遮罩（先于快门黑场，两者叠加）
            CaptureProcessingMask()

            // 快门黑场：按下瞬间闪一下，给出即时反馈，同时遮住随后切换会话的第一下停顿
            Color.black
                .opacity(blinkOpacity)
                .allowsHitTesting(false)

            // 首次启动前 / 没有相机权限：沿用原来的空白图标
            if !cam.ready && (!cam.hasStarted || cam.permissionDenied) {
                VStack(spacing: 10) {
                    Image(systemName: "camera.aperture").font(.system(size: 44))
                    if cam.permissionDenied {
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(24)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onChange(of: cam.shutterPulse) { _, _ in pulseShutterBlink() }
    }

    private func pulseShutterBlink() {
        withAnimation(.easeOut(duration: 0.05)) {
            blinkOpacity = 0.7
        } completion: {
            withAnimation(.easeOut(duration: 0.26)) {
                blinkOpacity = 0
            }
        }
    }

    private var backgroundGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard !pinching else { return }
                if !pressing {
                    pressing = true
                    adjusting = false
                    cam.exposureDragBegan(at: normalized(v.startLocation))
                }
                if abs(v.translation.height) > 10 || adjusting {
                    adjusting = true
                    cam.exposureDragChanged(dy: v.translation.height, at: normalized(v.location))
                }
            }
            .onEnded { v in
                if !adjusting && !pinching && hypot(v.translation.width, v.translation.height) < 12 {
                    cam.focus(atNormalized: normalized(v.startLocation))
                }
                pressing = false
                adjusting = false
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                pinching = true
                let slot = cam.mainSlot
                if zoomStart == nil { zoomStart = cam.slotStates[slot].zoom }
                cam.setZoom(slot: slot, factor: (zoomStart ?? 1) * v.magnification)
            }
            .onEnded { _ in
                HapticFeedback.play(.zoom)
                zoomStart = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pinching = false }
            }
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        return CGPoint(x: min(max(p.x / max(size.width, 1), 0), 1),
                       y: min(max(p.y / max(size.height, 1), 0), 1))
    }
}

/// 拍照处理（切换单摄高清会话、合成、保存）和切换镜头 / 画质重建会话时，预览画面会冻住几百毫秒到数秒。
/// 这里在冻住的最后一帧上盖一层毛玻璃 + 光圈动画 + 阶段提示，让停顿看起来是「处理中」而不是卡死。
struct CaptureProcessingMask: View {
    @EnvironmentObject private var cam: CameraManager
    @State private var shown = false

    private var wants: Bool {
        cam.isCapturingPhoto || (!cam.ready && cam.hasStarted && !cam.permissionDenied)
    }

    private var label: String {
        if let status = cam.captureStatus { return status }
        return cam.isCapturingPhoto ? "高清处理中…" : "正在切换…"
    }

    var body: some View {
        ZStack {
            if shown {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(0.22)
                    VStack(spacing: 14) {
                        ApertureSpinner()
                        Text(label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: label)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: shown)
        .onChange(of: wants, initial: true) { _, now in
            if now {
                shown = true
            } else {
                // 多留一小会儿，等新会话的第一帧上屏，避免遮罩一撤就露出冻住 / 黑屏的画面
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !wants { shown = false }
                }
            }
        }
    }
}

/// 光圈图标外圈的旋转弧线。
struct ApertureSpinner: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
            Image(systemName: "camera.aperture")
                .font(.system(size: 22))
                .foregroundStyle(Color.white.opacity(0.9))
        }
        .frame(width: 58, height: 58)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
    }
}

/// 预览左上角：点一下循环「原图直出 / 合成画面 / 两者都存」。
struct OutputModePill: View {
    @EnvironmentObject private var cam: CameraManager

    var body: some View {
        Button {
            let all = OutputMode.allCases
            let i = all.firstIndex(of: cam.cfg.outputMode) ?? 0
            cam.cfg.outputMode = all[(i + 1) % all.count]
        } label: {
            Text(cam.cfg.outputMode.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.yellow)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.black.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .disabled(cam.isRecording)
        .opacity(cam.isRecording ? 0.5 : 1)
    }
}

/// Touch focus reticle with its own exposure rail. The transparent rail hit area is wider
/// than its artwork, and the rail lives on the side with more free preview space.
struct FocusMarkerView: View {
    let exposureBias: Float
    let minBias: Float
    let maxBias: Float
    let isDisabled: Bool
    let railOnLeft: Bool
    let trackHeight: CGFloat
    let onExposureChanged: (Float) -> Void
    var iconRotationDegrees: CGFloat = 0

    @State private var appeared = false
    @State private var isDragging = false
    @State private var dragBias: Float?

    private let reticleSize: CGFloat = 68
    private let railWidth: CGFloat = 48

    private var displayedBias: Float {
        min(max(dragBias ?? exposureBias, minBias), maxBias)
    }

    private var handleOffset: CGFloat {
        let span = max(maxBias - minBias, 0.1)
        let fraction = CGFloat((maxBias - displayedBias) / span)
        return (fraction - 0.5) * trackHeight
    }

    private var disabledTint: Color {
        isDisabled ? Color.white.opacity(0.38) : Color.yellow
    }

    var body: some View {
        HStack(spacing: 10) {
            if railOnLeft {
                exposureRail
                focusReticle
            } else {
                focusReticle
                exposureRail
            }
        }
        .frame(width: 126, height: max(reticleSize, trackHeight + 50))
        .scaleEffect(appeared ? 1 : 1.04)
        .onAppear { withAnimation(.easeOut(duration: 0.14)) { appeared = true } }
        .accessibilityElement(children: .contain)
    }

    private var focusReticle: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow.opacity(0.98), lineWidth: 1.5)
                .frame(width: reticleSize, height: reticleSize)
                .overlay {
                    FocusReticleCorners()
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: reticleSize, height: reticleSize)
                }
            Image(systemName: isDisabled ? "lock.fill" : "scope")
                .rotationEffect(.degrees(iconRotationDegrees))
                .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.yellow)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.82)))
                .offset(x: 7, y: -7)
        }
        .frame(width: reticleSize, height: reticleSize)
        // Keep the reticle visually present without stealing taps intended to refocus the preview.
        .allowsHitTesting(false)
        .shadow(color: Color.black.opacity(0.25), radius: 3, y: 1)
    }

    private var exposureRail: some View {
        VStack(spacing: 4) {
            exposureRailTitle
            exposureTrack
            exposureValue
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.58)))
        .overlay(Capsule().stroke(Color.white.opacity(isDragging ? 0.36 : 0.13), lineWidth: 0.8))
        .opacity(isDisabled ? 0.72 : 1)
        .frame(width: railWidth, height: max(reticleSize, trackHeight + 50))
    }

    private var exposureRailTitle: some View {
        Text("EV")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.72))
    }

    private var exposureTrack: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(isDisabled ? 0.16 : 0.22))
                .frame(width: 4, height: trackHeight)

            ForEach(0..<5, id: \.self) { tick in
                Capsule()
                    .fill(Color.white.opacity(tick == 2 ? 0.78 : 0.38))
                    .frame(width: tick == 2 ? 13 : 7, height: 1)
                    .offset(y: (CGFloat(tick) / 4 - 0.5) * trackHeight)
            }

            exposureHandle
        }
        .frame(width: railWidth, height: trackHeight + 16)
        .contentShape(Rectangle())
        .highPriorityGesture(exposureDragGesture)
        .accessibilityLabel("曝光补偿")
        .accessibilityValue(String(format: "%+.1f EV", Double(displayedBias)))
        .accessibilityHint(isDisabled ? "先关闭手动曝光或锁定状态" : "上下滑动调节曝光，双击数值可归零")
    }

    private var exposureHandle: some View {
        Circle()
            .fill(Color.black.opacity(0.8))
            .frame(width: 25, height: 25)
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.7))
            .overlay {
                Circle()
                    .fill(disabledTint)
                    .frame(width: 11, height: 11)
            }
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.2)
                    .frame(width: 25, height: 25)
            )
            .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
            .offset(y: handleOffset)
            .allowsHitTesting(false)
    }

    private var exposureValue: some View {
        Text(String(format: "%+.1f", Double(displayedBias)))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(isDisabled ? Color.white.opacity(0.45) : Color.yellow)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: resetExposureToZero)
    }

    private var exposureDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged(handleExposureDragChanged)
            .onEnded { _ in handleExposureDragEnded() }
    }

    private func handleExposureDragChanged(_ value: DragGesture.Value) {
        guard !isDisabled else { return }
        if !isDragging {
            isDragging = true
            HapticFeedback.play(.button)
        }
        let y = min(max(value.location.y - 8, 0), trackHeight)
        let fraction = 1 - Float(y / max(trackHeight, 1))
        let next = minBias + fraction * (maxBias - minBias)
        dragBias = next
        onExposureChanged(next)
    }

    private func handleExposureDragEnded() {
        if isDragging { HapticFeedback.play(.selection) }
        isDragging = false
        dragBias = nil
    }

    private func resetExposureToZero() {
        guard !isDisabled else { return }
        HapticFeedback.play(.selection)
        dragBias = 0
        onExposureChanged(0)
    }
}

private struct FocusReticleCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length: CGFloat = 12
        path.move(to: CGPoint(x: 1, y: length))
        path.addLine(to: CGPoint(x: 1, y: 1))
        path.addLine(to: CGPoint(x: length, y: 1))
        path.move(to: CGPoint(x: rect.maxX - length, y: 1))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: 1))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: length))
        path.move(to: CGPoint(x: 1, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: 1, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: length, y: rect.maxY - 1))
        path.move(to: CGPoint(x: rect.maxX - length, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.maxY - length))
        return path
    }
}

struct PiPOverlay: View {
    @EnvironmentObject private var cam: CameraManager
    let size: CGSize
    var iconRotationDegrees: CGFloat = 0

    @State private var dragOriginCenter: CGPoint? = nil
    @State private var dragCenter: CGPoint? = nil
    @State private var isDraggingPiP = false
    @State private var pinchStart: CGFloat? = nil
    @State private var resizeStart: CGFloat? = nil

    private var displayConfig: Config {
        var config = cam.cfg
        if let dragCenter { config.pipCenter = dragCenter }
        return config
    }

    var body: some View {
        let n = Compositor.pipRectNormalized(cfg: displayConfig)
        let rect = CGRect(x: n.minX * size.width, y: n.minY * size.height,
                          width: n.width * size.width, height: n.height * size.height)
        ZStack(alignment: .bottomTrailing) {
            if isDraggingPiP {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.12)))
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .rotationEffect(.degrees(iconRotationDegrees))
                        .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.35), lineWidth: 1))
            } else {
                Color.clear.contentShape(Rectangle()).onTapGesture { cam.swapCameras() }
            }
            Color.clear.contentShape(Rectangle()).gesture(moveGesture).simultaneousGesture(pinchGesture)

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .rotationEffect(.degrees(iconRotationDegrees))
                .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(0.45)))
                .padding(4)
                .contentShape(Circle())
                .gesture(resizeGesture)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .animation(.smooth(duration: 0.26), value: size)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if dragOriginCenter == nil {
                    guard !cam.isRecording && !cam.isCapturingPhoto else { return }
                    dragOriginCenter = cam.cfg.pipCenter
                    isDraggingPiP = true
                    cam.setPiPDragPreviewActive(true)
                    HapticFeedback.play(.button)
                }
                guard let origin = dragOriginCenter else { return }
                let next = CGPoint(
                    x: origin.x + value.translation.width / max(size.width, 1),
                    y: origin.y + value.translation.height / max(size.height, 1)
                )
                // The render thread follows the live center; Config and parent view stay stable.
                dragCenter = next
                // Only the frosted-glass placeholder moves; the camera render stays still until release.
            }
            .onEnded { _ in
                if let finalCenter = dragCenter {
                    var next = cam.cfg
                    next.pipCenter = finalCenter
                    cam.cfg = next
                    cam.snapPiP()
                }
                cam.clearPiPDragPreview()
                dragCenter = nil
                dragOriginCenter = nil
                isDraggingPiP = false
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil { pinchStart = cam.cfg.pipWidth }
                cam.cfg.pipWidth = min(max((pinchStart ?? 0.32) * v.magnification, 0.16), 0.9)
            }
            .onEnded { _ in
                if pinchStart != nil { HapticFeedback.play(.selection) }
                pinchStart = nil
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if resizeStart == nil { resizeStart = cam.cfg.pipWidth }
                // pipWidth 在宽画幅下以短边为基准，屏幕上的位移要除回这个系数
                let scale = Compositor.pipWidthScale(aspect: cam.cfg.aspectRatio)
                let delta = v.translation.width / max(size.width, 1) / max(scale, 0.1)
                cam.cfg.pipWidth = min(max((resizeStart ?? 0.32) + delta, 0.16), 0.9)
            }
            .onEnded { _ in
                if resizeStart != nil { HapticFeedback.play(.selection) }
                resizeStart = nil
            }
    }
}

struct SplitDivider: View {
    @EnvironmentObject private var cam: CameraManager
    let size: CGSize
    @State private var start: CGFloat? = nil

    var body: some View {
        // 宽画幅（16:9 / 21:9）是左右分屏，分隔线竖着放、横向拖动
        if Compositor.splitIsSideBySide(cfg: cam.cfg) {
            let x = cam.cfg.splitRatio * size.width
            ZStack {
                Rectangle().fill(Color.white.opacity(0.55)).frame(width: 1)
                Capsule().fill(Color.white).frame(width: 5, height: 46)
            }
            .frame(width: 44, height: size.height)
            .contentShape(Rectangle())
            .position(x: x, y: size.height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if start == nil { start = cam.cfg.splitRatio }
                        let r = (start ?? 0.5) + v.translation.width / max(size.width, 1)
                        cam.cfg.splitRatio = min(max(r, 0.25), 0.75)
                    }
                    .onEnded { _ in
                        if let start, abs(cam.cfg.splitRatio - start) > 0.003 {
                            HapticFeedback.play(.selection)
                        }
                        start = nil
                    }
            )
        } else {
            let y = cam.cfg.splitRatio * size.height
            ZStack {
                Rectangle().fill(Color.white.opacity(0.55)).frame(height: 1)
                Capsule().fill(Color.white).frame(width: 46, height: 5)
            }
            .frame(width: size.width, height: 44)
            .contentShape(Rectangle())
            .position(x: size.width / 2, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if start == nil { start = cam.cfg.splitRatio }
                        let r = (start ?? 0.5) + v.translation.height / max(size.height, 1)
                        cam.cfg.splitRatio = min(max(r, 0.25), 0.75)
                    }
                    .onEnded { _ in start = nil }
            )
        }
    }
}
struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = rect.width * CGFloat(i) / 3
            let y = rect.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: rect.height))
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return p
    }
}


/// The timer editor is presented by the full-screen camera canvas, not clipped to the top bar.
struct TimerSettingsOverlay: View {
    @EnvironmentObject private var cam: CameraManager
    @Binding var timerDraft: Int
    @Binding var isPresented: Bool
    @AppStorage("dualcam.dismissOnBlankTap") private var dismissOnBlankTap = true
    var iconRotationDegrees: CGFloat = 0

    var body: some View {
        ZStack {
            // Use a dedicated full-screen button so backdrop taps never fall through
            // to PreviewStage's focus/exposure gesture. When disabled, the backdrop still
            // intercepts touches but leaves this timer panel open.
            Button {
                guard dismissOnBlankTap else { return }
                HapticFeedback.play(.button)
                isPresented = false
            } label: {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭倒计时设置")
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "timer")
                        .rotationEffect(.degrees(iconRotationDegrees))
                        .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                        .foregroundStyle(Color.yellow)
                    Text("拍摄倒计时").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button {
                        HapticFeedback.play(.button)
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .rotationEffect(.degrees(iconRotationDegrees))
                            .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                HStack(spacing: 14) {
                    Button {
                        guard timerDraft > 1 else { HapticFeedback.play(.button); return }
                        HapticFeedback.play(.selection)
                        timerDraft = max(1, timerDraft - 1)
                    } label: {
                        Image(systemName: "minus")
                            .rotationEffect(.degrees(iconRotationDegrees))
                            .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                            .frame(width: 40, height: 40)
                    }
                    Text("\(timerDraft) 秒")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit().frame(minWidth: 90)
                    Button {
                        guard timerDraft < 60 else { HapticFeedback.play(.button); return }
                        HapticFeedback.play(.selection)
                        timerDraft = min(60, timerDraft + 1)
                    } label: {
                        Image(systemName: "plus")
                            .rotationEffect(.degrees(iconRotationDegrees))
                            .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                            .frame(width: 40, height: 40)
                    }
                }
                Slider(
                    value: Binding(get: { Double(timerDraft) }, set: { timerDraft = Int($0.rounded()) }),
                    in: 1...60, step: 1,
                    onEditingChanged: { editing in
                        if !editing { HapticFeedback.play(.selection) }
                    }
                )
                HStack(spacing: 10) {
                    Button("关闭") {
                        HapticFeedback.play(.button)
                        cam.timerSeconds = 0
                        isPresented = false
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    Button("确定") {
                        HapticFeedback.play(.success)
                        cam.timerSeconds = timerDraft
                        isPresented = false
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Color.yellow, in: Capsule())
                    .foregroundStyle(Color.black)
                }
            }
            .padding(20)
            .frame(maxWidth: 310)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.16), lineWidth: 1))
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 顶部栏（长按自定义；参数可逐项添加）
struct TopBar: View {
    @EnvironmentObject private var cam: CameraManager
    @AppStorage("dualcam.topbar.actions")
    private var actionOrderValue = "flash,livePhoto,liveMotion,timer,swapCamera,wireless"
    @State private var isCustomizing = false

    let onTimerTap: () -> Void
    let onWirelessMonitorTap: () -> Void
    let onWirelessReceiveTap: () -> Void
    let onWirelessShareTap: () -> Void
    let onShareCompositeTap: () -> Void
    let isSharingComposite: Bool
    let onParameterTap: (String) -> Void
    var iconRotationDegrees: CGFloat = 90
    var compactLayout = false

    private static let baseActionKeys = ["flash", "livePhoto", "liveMotion", "timer", "swapCamera", "wireless", "shareComposite"]
    private static var allActionKeys: [String] {
        baseActionKeys + QuickParameter.allCases.map { "param.\($0.shortcutKey)" }
    }
    private static func isParameterKey(_ key: String) -> Bool { key.hasPrefix("param.") }

    private var showLiveSource: Bool { cam.cfg.livePhoto && cam.captureMode == .photo }
    private var actionKeys: [String] {
        guard actionOrderValue != "none" else { return [] }
        var seen = Set<String>()
        return actionOrderValue.split(separator: ",").map(String.init).filter { key in
            Self.allActionKeys.contains(key) && seen.insert(key).inserted
        }
    }
    private var availableActionKeys: [String] { Self.allActionKeys.filter { !actionKeys.contains($0) } }
    private var actionSpacing: CGFloat {
        if isCustomizing { return 3 }
        if compactLayout { return 4 }
        return showLiveSource ? 14 : 22
    }
    private var actionIconSize: CGFloat {
        if compactLayout && isCustomizing { return 26 }
        if compactLayout { return 30 }
        if isCustomizing { return 32 }
        return 40
    }

    var body: some View {
        ZStack {
            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(timeString(cam.recordSeconds))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color.red.opacity(0.85)))
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: actionSpacing) {
                            if isCustomizing {
                                Menu {
                                    Section("相机按钮") {
                                        ForEach(availableActionKeys.filter {
                                            !Self.isParameterKey($0) && $0 != "wireless" && $0 != "shareComposite"
                                        }, id: \.self) { key in
                                            Button { addAction(key) } label: {
                                                Label(actionTitle(key), systemImage: actionSystemImage(key))
                                            }
                                        }
                                    }
                                    Section("互联按钮") {
                                        ForEach(availableActionKeys.filter { $0 == "wireless" || $0 == "shareComposite" }, id: \.self) { key in
                                            Button { addAction(key) } label: {
                                                Label(actionTitle(key), systemImage: actionSystemImage(key))
                                            }
                                        }
                                    }
                                    Section("独立参数按钮") {
                                        ForEach(availableActionKeys.filter { Self.isParameterKey($0) }, id: \.self) { key in
                                            Button { addAction(key) } label: {
                                                Label(actionTitle(key), systemImage: actionSystemImage(key))
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: compactLayout ? 23 : 27, weight: .semibold))
                                        .foregroundStyle(Color.green)
                                        .frame(width: compactLayout ? 28 : 32, height: compactLayout ? 28 : 32)
                                        .background(Circle().fill(Color.white.opacity(0.09)))
                                }
                                .disabled(availableActionKeys.isEmpty)
                                .accessibilityLabel("添加按钮或独立参数")

                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                        isCustomizing = false
                                    }
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: compactLayout ? 22 : 25, weight: .semibold))
                                        .foregroundStyle(Color.yellow)
                                        .frame(width: compactLayout ? 28 : 32, height: compactLayout ? 28 : 32)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("完成自定义")
                            }

                            ForEach(actionKeys, id: \.self) { key in
                                actionButton(for: key)
                            }
                        }
                        .padding(.horizontal, 8)
                        // Center the button group whenever it fits; keep its natural width
                        // when actions overflow so horizontal scrolling remains available.
                        .frame(minWidth: geometry.size.width, alignment: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func actionButton(for key: String) -> some View {
        switch key {
        case "flash":
            iconButton(actionKey: key, icon: cam.flashEnabled ? "bolt.fill" : "bolt.slash",
                       active: cam.flashEnabled, label: cam.flashEnabled ? "关闭闪光灯" : "开启闪光灯") {
                HapticFeedback.play(.button)
                cam.flashEnabled.toggle()
            }
        case "livePhoto":
            iconButton(actionKey: key, icon: cam.cfg.livePhoto ? "livephoto" : "livephoto.slash",
                       active: cam.cfg.livePhoto && cam.captureMode == .photo,
                       dimmed: cam.captureMode == .video, label: "实况照片") {
                HapticFeedback.play(.selection)
                cam.cfg.livePhoto.toggle()
            }
        case "liveMotion":
            if showLiveSource {
                iconButton(actionKey: key, icon: cam.cfg.liveMotion.icon,
                           active: cam.cfg.liveMotion != .composite,
                           dimmed: cam.cfg.outputMode == .original,
                           label: "实况动态来源：\(cam.cfg.liveMotion.rawValue)",
                           badge: cam.cfg.liveMotion.badge) {
                    if cam.cfg.outputMode == .original {
                        cam.showToast("「原图直出」没有合成图，动态片段取自各自镜头")
                        return
                    }
                    HapticFeedback.play(.selection)
                    cam.cfg.liveMotion = cam.cfg.liveMotion.next
                }
            } else {
                EmptyView()
            }
        case "timer":
            iconButton(actionKey: key, icon: cam.timerSeconds == 0 ? "timer" : "timer.circle.fill",
                       active: cam.timerSeconds > 0,
                       label: cam.timerSeconds == 0 ? "设置倒计时" : "倒计时：\(cam.timerSeconds) 秒",
                       badge: cam.timerSeconds == 0 ? nil : "\(cam.timerSeconds)") {
                HapticFeedback.play(.button)
                onTimerTap()
            }
        case "swapCamera":
            iconButton(actionKey: key, icon: "arrow.triangle.2.circlepath", active: false,
                       label: "切换主副摄像头") { cam.swapCameras() }
        case "wireless":
            iconButton(actionKey: key, icon: "dot.radiowaves.left.and.right", active: false,
                       label: "无线监看") {
                HapticFeedback.play(.button)
                onWirelessMonitorTap()
            }
        case "shareComposite":
            iconButton(actionKey: key, icon: "airplayvideo", active: isSharingComposite,
                       label: "共享本机合成画面") {
                HapticFeedback.play(.button)
                onShareCompositeTap()
            }
        default:
            if key.hasPrefix("param."),
               let parameter = QuickParameter.fromShortcutKey(String(key.dropFirst("param.".count))) {
                iconButton(actionKey: key, icon: parameter.icon, active: false,
                           label: "打开参数：\(parameter.rawValue)") {
                    onParameterTap(parameter.rawValue)
                }
            } else {
                EmptyView()
            }
        }
    }

    private func iconButton(
        actionKey: String, icon: String, active: Bool, dimmed: Bool = false,
        label: String, badge: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button {
            if isCustomizing { removeAction(actionKey) } else { action() }
        } label: {
            Image(systemName: icon)
                .rotationEffect(.degrees(iconRotationDegrees))
                .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                .font(.system(size: compactLayout ? 16 : 18, weight: .semibold))
                .foregroundStyle(active ? Color.yellow : Color.white)
                .frame(width: actionIconSize, height: actionIconSize)
                .background(Circle().fill(active ? Color.yellow.opacity(0.14) : Color.white.opacity(0.07)))
                .overlay(Circle().stroke(Color.white.opacity(active ? 0.2 : 0.1), lineWidth: 0.6))
                .overlay(alignment: .topTrailing) {
                    if let badge, !isCustomizing {
                        Text(badge).font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.black).frame(minWidth: 13, minHeight: 13)
                            .background(Circle().fill(Color.yellow)).offset(x: 3, y: -2)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isCustomizing {
                        Image(systemName: "minus.circle.fill").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white, Color.red).offset(x: -3, y: -3)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCustomizing ? "删除按钮：\(actionTitle(actionKey))" : label)
        .opacity(dimmed ? 0.4 : 1)
        .contextMenu {
            if actionKey == "wireless" || actionKey == "shareComposite" {
                Button(action: onWirelessReceiveTap) {
                    Label("切换为接收画面", systemImage: "rectangle.inset.filled.and.person.filled")
                }
                Button(action: onWirelessShareTap) {
                    Label("切换为共享画面", systemImage: "airplayvideo")
                }
                Button(action: onWirelessMonitorTap) {
                    Label("打开无线功能界面", systemImage: "slider.horizontal.3")
                }
            }
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { isCustomizing = true }
            } label: {
                Label("自定义顶部导航栏", systemImage: "slider.horizontal.3")
            }
            Button(role: .destructive) { removeAction(actionKey) } label: {
                Label("删除此按钮", systemImage: "minus.circle")
            }
        }
    }

    private func addAction(_ key: String) {
        guard Self.allActionKeys.contains(key), !actionKeys.contains(key) else { return }
        saveActionKeys(actionKeys + [key])
        HapticFeedback.play(.selection)
    }

    private func removeAction(_ key: String) {
        guard actionKeys.contains(key) else { return }
        saveActionKeys(actionKeys.filter { $0 != key })
        HapticFeedback.play(.button)
        isCustomizing = true
    }

    private func saveActionKeys(_ keys: [String]) {
        actionOrderValue = keys.isEmpty ? "none" : keys.joined(separator: ",")
    }

    private func actionTitle(_ key: String) -> String {
        switch key {
        case "flash": return "闪光灯"
        case "livePhoto": return "实况照片"
        case "liveMotion": return "实况动态来源"
        case "timer": return "倒计时"
        case "swapCamera": return "切换摄像头"
        case "wireless": return "无线监看"
        case "shareComposite": return "共享本机合成画面"
        default:
            if key.hasPrefix("param."),
               let parameter = QuickParameter.fromShortcutKey(String(key.dropFirst("param.".count))) {
                return parameter.rawValue
            }
            return key
        }
    }

    private func actionSystemImage(_ key: String) -> String {
        switch key {
        case "flash": return "bolt.fill"
        case "livePhoto": return "livephoto"
        case "liveMotion": return "waveform"
        case "timer": return "timer"
        case "swapCamera": return "arrow.triangle.2.circlepath"
        case "wireless": return "dot.radiowaves.left.and.right"
        case "shareComposite": return "airplayvideo"
        default:
            if key.hasPrefix("param."),
               let parameter = QuickParameter.fromShortcutKey(String(key.dropFirst("param.".count))) {
                return parameter.icon
            }
            return "plus"
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - 底部栏

private struct CameraZoomBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CameraShutterTopPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CameraBottomBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 222
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct BottomBar: View {
    @EnvironmentObject private var cam: CameraManager
    @Binding var showPanel: Bool
    @Binding var panelTab: PanelTab
    let onAlbumTap: () -> Void
    let onAlbumSwipeUp: () -> Void
    let bottomDockPadding: CGFloat
    var isLandscape: Bool = false
    var iconRotationDegrees: CGFloat = 90

    // Match the visible circles and tap targets on both sides of the shutter.
    private let sideButtonSize: CGFloat = 48

    private var zoomRow: some View {
        HStack {
            Spacer(minLength: 0)
            ZoomChips()
            Spacer(minLength: 0)
        }
        .padding(.top, isLandscape ? 0 : 2)
        // Measure the actual zoom control's bottom edge in screen coordinates.
        // The 9:16 preview uses this measurement as its lower alignment edge.
        .background(GeometryReader { proxy in
            Color.clear.preference(
                key: CameraZoomBottomPreferenceKey.self,
                value: proxy.frame(in: .global).maxY
            )
        })
    }

    private var splitButton: some View {
        Button { cam.toggleLayout() } label: {
            Image(systemName: cam.cfg.layout == .pip
                  ? "rectangle.on.rectangle"
                  : (Compositor.splitIsSideBySide(cfg: cam.cfg) ? "rectangle.split.2x1" : "rectangle.split.1x2"))
                .rotationEffect(.degrees(iconRotationDegrees))
                .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.yellow)
                .frame(width: sideButtonSize, height: sideButtonSize)
                .background(Circle().fill(Color.black))
                .overlay(Circle().stroke(Color.yellow, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cam.cfg.layout == .pip
                            ? (Compositor.splitIsSideBySide(cfg: cam.cfg) ? "切换左右分屏" : "切换上下分屏")
                            : "切换画中画")
    }

    private var paramsButton: some View {
        Button {
            HapticFeedback.play(.button)
            withAnimation(.easeInOut(duration: 0.22)) {
                if showPanel && panelTab == .params {
                    showPanel = false
                } else {
                    panelTab = .params
                    showPanel = true
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .rotationEffect(.degrees(iconRotationDegrees))
                .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(showPanel && panelTab == .params ? Color.yellow : Color.white)
                .frame(width: sideButtonSize, height: sideButtonSize)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .overlay(Circle().stroke(
                    showPanel && panelTab == .params ? Color.yellow.opacity(0.7) : Color.clear,
                    lineWidth: 1.2
                ))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("快捷参数")
    }

    /// Toggle still-photo/video capture mode with a single icon.
    private var captureModeSwitchButton: some View {
        Button {
            guard !cam.isRecording else { return }
            HapticFeedback.play(.selection)
            withAnimation(.easeInOut(duration: 0.15)) {
                cam.captureMode = cam.captureMode == .photo ? .video : .photo
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: cam.captureMode == .photo ? "video.fill" : "camera.fill")
                    .rotationEffect(.degrees(iconRotationDegrees))
                    .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: sideButtonSize, height: sideButtonSize)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                Image(systemName: "arrow.left.arrow.right")
                    .rotationEffect(.degrees(iconRotationDegrees))
                    .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                    .font(.system(size: 8, weight: .bold))
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(0.92)))
                    .offset(x: 2, y: 2)
            }
            .foregroundStyle(cam.captureMode == .photo ? Color.white : Color.red.opacity(0.95))
            .frame(width: sideButtonSize, height: sideButtonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(cam.isRecording)
        .opacity(cam.isRecording ? 0.4 : 1)
        .accessibilityLabel(cam.captureMode == .photo ? "切换到录像" : "切换到拍照")
        .accessibilityHint("单击切换拍摄模式")
    }

    var body: some View {
        VStack(spacing: isLandscape ? 4 : 12) {
            // 倍率条固定在快门上方。
            zoomRow

            // 同一行：左侧相册，中央快门，右侧依次为模式切换、分屏和参数。
            ZStack {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ShutterButton()
                        .background(GeometryReader { proxy in
                            Color.clear.preference(
                                key: CameraShutterTopPreferenceKey.self,
                                value: proxy.frame(in: .global).minY
                            )
                        })
                    Spacer(minLength: 0)
                }
                HStack(alignment: .center, spacing: 8) {
                    // Left cluster: gallery then photo/video mode toggle.
                    ThumbnailButton(
                        action: onAlbumTap,
                        onSwipeUp: onAlbumSwipeUp,
                        iconRotationDegrees: iconRotationDegrees
                    )
                    captureModeSwitchButton

                    Spacer(minLength: 4)

                    // Right cluster: split layout and quick parameters stay together.
                    HStack(spacing: 4) {
                        splitButton
                        paramsButton
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 84)
        }
        .padding(.top, isLandscape ? 2 : 8)
        .padding(.bottom, isLandscape ? 4 : 8)
        // Reserve real layout space below the controls so they move up as a group;
        // applying this inside the dock also extends its gradient behind the safe margin.
        .padding(.bottom, bottomDockPadding)
        .background {
            LinearGradient(
                colors: [Color.black.opacity(0.02), Color.black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CameraBottomBarHeightPreferenceKey.self, value: proxy.size.height)
        })
    }
}

struct ThumbnailButton: View {
    @EnvironmentObject private var cam: CameraManager
    let action: () -> Void
    let onSwipeUp: () -> Void
    var iconRotationDegrees: CGFloat = 0
    @State private var bounce = false

    var body: some View {
        Button {
            HapticFeedback.play(.button)
            action()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let img = cam.lastThumb {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.12)
                            .overlay {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .rotationEffect(.degrees(iconRotationDegrees))
                                    .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.7))
                            }
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))

                Image(systemName: "square.stack")
                    .rotationEffect(.degrees(iconRotationDegrees))
                    .animation(.smooth(duration: 0.28), value: iconRotationDegrees)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(Color.black.opacity(0.78), in: Circle())
                    .offset(x: 3, y: 1)
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .onEnded { value in
                    guard value.translation.height < -26,
                          abs(value.translation.width) < 70 else { return }
                    HapticFeedback.play(.button)
                    onSwipeUp()
                }
        )
        .scaleEffect(bounce ? 1.12 : 1)
        .onChange(of: cam.lastThumb) { _, new in
            guard new != nil else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                bounce = true
            } completion: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    bounce = false
                }
            }
        }
        .accessibilityLabel("打开相册")
        .accessibilityHint("点按打开系统照片；向上滑动打开 DualCam 相机相册")
    }
}

/// 焦段条：.5  1×  2  5。选中那一档是黄色数字 + 深色圆底；捏合变焦到两档之间时，选中档显示当前倍率。
struct ZoomChips: View {
    @EnvironmentObject private var cam: CameraManager
    var body: some View {
        let stops = cam.zoomStops
        let current = cam.displayZoom(slot: 0)
        let active = activeIndex(stops: stops, current: current)
        HStack(spacing: 4) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                let selected = index == active
                Button { cam.selectStop(stop) } label: {
                    Text(selected ? selectedText(stop: stop, current: current) : plainText(stop.value))
                        .font(.system(size: selected ? 14 : 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.yellow : Color.white)
                        .frame(width: selected ? 46 : 38, height: selected ? 46 : 38)
                        .background(Circle().fill(Color.black.opacity(selected ? 0.55 : 0)))
                }
                .buttonStyle(.plain)
                .disabled(cam.isRecording)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(stops.isEmpty ? 0 : 0.28)))
    }
    private func activeIndex(stops: [ZoomStop], current: CGFloat) -> Int? {
        guard !stops.isEmpty else { return nil }
        var best = 0, distance = CGFloat.greatestFiniteMagnitude
        for (i, stop) in stops.enumerated() { let d = abs(stop.value - current); if d < distance { distance = d; best = i } }
        return best
    }
    private func plainText(_ value: CGFloat) -> String { value < 1 ? ".5" : "\(Int(value))" }
    private func selectedText(stop: ZoomStop, current: CGFloat) -> String {
        let value = abs(stop.value - current) < 0.05 ? stop.value : current
        if abs(value - value.rounded()) < 0.05 { return "\(Int(value.rounded()))×" }
        if value < 1 { return ".5×" }
        return String(format: "%.1f×", Double(value))
    }
}
/// 按下时快门整体缩一点，松开回弹。
private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ShutterButton: View {
    @EnvironmentObject private var cam: CameraManager

    /// True from the moment a hold turned into a burst until just after the finger lifts, so the
    /// Button's own tap action (fired on touch-up) doesn't also take a normal photo.
    @State private var burstGestureTriggered = false
    @State private var pressActive = false
    @State private var burstArm: DispatchWorkItem?

    private static let burstHoldDelay: TimeInterval = 0.35
    private static let burstMaxMovement: CGFloat = 24

    var body: some View {
        Button {
            if burstGestureTriggered { return }
            cam.shutterTapped()
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                if cam.captureMode == .photo {
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                        // 处理中内圈收小并轻微呼吸，提示「正在拍」而不是整颗快门变灰
                        .scaleEffect(cam.isCapturingPhoto ? 0.78 : 1)
                        .animation(.easeInOut(duration: 0.18), value: cam.isCapturingPhoto)
                } else {
                    RoundedRectangle(cornerRadius: cam.isRecording ? 8 : 31)
                        .fill(Color.red)
                        .frame(width: cam.isRecording ? 30 : 62, height: cam.isRecording ? 30 : 62)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
        }
        .buttonStyle(ShutterPressStyle())
        // A zero-distance drag reports both touch-down and lift. LongPressGesture can't be used for
        // this: its onChanged fires the moment the finger lands (not after the hold time), and its
        // onEnded fires when the hold time is reached rather than when the finger lifts.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pressActive {
                        pressActive = true
                        let arm = DispatchWorkItem {
                            guard pressActive, !burstGestureTriggered, cam.canStartBurstCapture else { return }
                            burstGestureTriggered = true
                            cam.startBurstCapture()
                        }
                        burstArm = arm
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstHoldDelay, execute: arm)
                    }
                    // Dragging away from the button cancels the pending burst.
                    if !burstGestureTriggered,
                       hypot(value.translation.width, value.translation.height) > Self.burstMaxMovement {
                        burstArm?.cancel()
                        burstArm = nil
                    }
                }
                .onEnded { _ in
                    pressActive = false
                    burstArm?.cancel()
                    burstArm = nil
                    guard burstGestureTriggered else { return }
                    cam.stopBurstCapture()
                    // Keep the flag until after the Button's touch-up action has been swallowed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        burstGestureTriggered = false
                    }
                }
        )
        .onChange(of: cam.isBurstCapturing) { _, active in
            // A burst can also end by itself (15 shots, memory cap) while the finger is still down;
            // the flag must stay set until the finger lifts so that release isn't read as a tap.
            if !active, !pressActive { burstGestureTriggered = false }
        }
        .disabled(!cam.ready || (cam.isCapturingPhoto && !cam.isBurstCapturing))
        .opacity(cam.ready ? ((cam.isCapturingPhoto && !cam.isBurstCapturing) ? 0.8 : 1) : 0.4)
        .accessibilityLabel(cam.captureMode == .photo ? "拍照" : (cam.isRecording ? "停止录像" : "开始录像"))
    }
}

// MARK: - 提示层

struct OverlayLayer: View {
    @EnvironmentObject private var cam: CameraManager
    let topSafeAreaInset: CGFloat

    var body: some View {
        ZStack {
            if cam.screenFlash {
                Color.white.opacity(0.92).ignoresSafeArea().allowsHitTesting(false)
            }
            if let n = cam.countdown {
                Color.black.opacity(0.18).ignoresSafeArea()
                Text("\(n)").font(.system(size: 112, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Color.white).shadow(color: .black.opacity(0.6), radius: 18).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false).zIndex(10)
            }
            if let text = cam.toast {
                VStack {
                    Text(text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .padding(.top, topSafeAreaInset + 64)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: cam.toast)
        .allowsHitTesting(false)
    }
}
