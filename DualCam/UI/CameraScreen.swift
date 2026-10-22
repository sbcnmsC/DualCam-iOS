import SwiftUI
import UIKit

struct CameraScreen: View {
    @EnvironmentObject private var cam: CameraManager
    @State private var showPanel = false
    @State private var panelTab: PanelTab = .pip
    @State private var showTimerSettings = false
    @State private var timerDraft = 5
    @State private var bottomBarHeight: CGFloat = 222

    private let topBarHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            // This reader now represents the entire physical display, not the area between
            // the Dynamic Island and home indicator. On iPhone 16 Pro that is 402 × 874 pt.
            let canvasSize = geo.size
            let safeTop = max(geo.safeAreaInsets.top, 62)
            let safeBottom = max(geo.safeAreaInsets.bottom, 34)

            // Fixed aspect presets use only the free area between controls. Full-screen free
            // aspect uses the complete device canvas, with no letterbox/black bars.
            let topControlsBottom = safeTop + topBarHeight
            let dockTop = canvasSize.height - safeBottom - bottomBarHeight
            let previewTopLimit = topControlsBottom + 14
            let previewBottomLimit = dockTop - 12
            let availablePreviewHeight = max(100, previewBottomLimit - previewTopLimit)
            let previewSize = cam.cfg.aspect == .free
                ? fitSize(in: canvasSize)
                : fitSize(in: CGSize(width: canvasSize.width, height: availablePreviewHeight))
            let previewTop = cam.cfg.aspect == .free ? 0 : previewBottomLimit - previewSize.height

            ZStack(alignment: .topLeading) {
                Color.black

                // The preview and compositor use exactly the full-screen bounds and ratio.
                // Controls are a separate overlay and do not reserve canvas space.
                PreviewStage(size: previewSize)
                    .frame(width: previewSize.width, height: previewSize.height)
                    .frame(width: canvasSize.width, height: canvasSize.height, alignment: .top)
                    .offset(y: previewTop)

                VStack(spacing: 0) {
                    TopBar(onTimerTap: {
                        timerDraft = cam.timerSeconds > 0 ? cam.timerSeconds : 5
                        showTimerSettings = true
                    })
                    .frame(height: topBarHeight)

                    Spacer(minLength: 0)

                    if showPanel {
                        ToolPanel(tab: $panelTab)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    BottomBar(
                        showPanel: $showPanel,
                        panelTab: $panelTab,
                        onAlbumTap: { openNativePhotos() },
                        bottomDockPadding: max(safeBottom + 44, 80)
                    )
                }
                .padding(.top, safeTop)
                .padding(.bottom, safeBottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(5)

                OverlayLayer(topSafeAreaInset: safeTop)
                    .frame(width: canvasSize.width, height: canvasSize.height)

                if showTimerSettings {
                    TimerSettingsOverlay(timerDraft: $timerDraft, isPresented: $showTimerSettings)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .zIndex(20)
                }
            }
            .onAppear { updateFreeAspect(for: canvasSize) }
            .onChange(of: canvasSize) { _, newSize in updateFreeAspect(for: newSize) }
            .onPreferenceChange(CameraBottomBarHeightPreferenceKey.self) { height in
                guard height > 0, abs(bottomBarHeight - height) > 1 else { return }
                bottomBarHeight = height
            }
        }
        // Critical: expand the GeometryReader itself, not only its background.
        // This makes both preview dimensions and the free canvas ratio match the device screen.
        .ignoresSafeArea(.container, edges: .all)
        .background(Color.black)
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.22), value: showPanel)
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
            // Full device canvas; user can crop the saved image later.
            return CGSize(width: size.width, height: availableHeight)
        }
        let aspect = cam.cfg.aspectRatio
        let w = min(size.width, availableHeight * aspect)
        return CGSize(width: w, height: w / aspect)
    }

    private func updateFreeAspect(for size: CGSize) {
        cam.updateFreeAspect(width: size.width, height: max(size.height, 100))
    }
}

// MARK: - 预览区域与手势

struct PreviewStage: View {
    @EnvironmentObject private var cam: CameraManager
    let size: CGSize

    @State private var pressing = false
    @State private var adjusting = false
    @State private var pinching = false
    @State private var zoomStart: CGFloat? = nil

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
                PiPOverlay(size: size)
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
                    onExposureChanged: { cam.adjustExposureBias(slot: slot, value: $0) }
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

            if !cam.ready {
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
                zoomStart = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pinching = false }
            }
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        return CGPoint(x: min(max(p.x / max(size.width, 1), 0), 1),
                       y: min(max(p.y / max(size.height, 1), 0), 1))
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
            Text("EV")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))

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

                Circle()
                    .fill(Color.black.opacity(0.8))
                    .frame(width: 25, height: 25)
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.7))
                    .overlay {
                        Circle()
                            .fill(disabledTint)
                            .frame(width: 11, height: 11)
                    }
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.2)
                        .frame(width: 25, height: 25))
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .offset(y: handleOffset)
                    .allowsHitTesting(false)
            }
            .frame(width: railWidth, height: trackHeight + 16)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard !isDisabled else { return }
                        if !isDragging {
                            isDragging = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        let y = min(max(value.location.y - 8, 0), trackHeight)
                        let fraction = 1 - Float(y / max(trackHeight, 1))
                        let next = minBias + fraction * (maxBias - minBias)
                        dragBias = next
                        onExposureChanged(next)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragBias = nil
                    }
            )
            .accessibilityLabel("曝光补偿")
            .accessibilityValue(String(format: "%+.1f EV", Double(displayedBias)))
            .accessibilityHint(isDisabled ? "先关闭手动曝光或锁定状态" : "上下滑动调节曝光，双击数值可归零")

            Text(String(format: "%+.1f", Double(displayedBias)))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isDisabled ? Color.white.opacity(0.45) : Color.yellow)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard !isDisabled else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dragBias = 0
                    onExposureChanged(0)
                }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.58)))
        .overlay(Capsule().stroke(Color.white.opacity(isDragging ? 0.36 : 0.13), lineWidth: 0.8))
        .opacity(isDisabled ? 0.72 : 1)
        .frame(width: railWidth, height: max(reticleSize, trackHeight + 50))
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
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 18)).foregroundStyle(.white.opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.35), lineWidth: 1))
            } else {
                Color.clear.contentShape(Rectangle()).onTapGesture { cam.swapCameras() }
            }
            Color.clear.contentShape(Rectangle()).gesture(moveGesture).simultaneousGesture(pinchGesture)

            Image(systemName: "arrow.up.left.and.arrow.down.right")
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
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if dragOriginCenter == nil {
                    guard !cam.isRecording && !cam.isCapturingPhoto else { return }
                    dragOriginCenter = cam.cfg.pipCenter
                    isDraggingPiP = true
                    cam.setPiPDragPreviewActive(true)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            .onEnded { _ in pinchStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if resizeStart == nil { resizeStart = cam.cfg.pipWidth }
                let delta = v.translation.width / max(size.width, 1)
                cam.cfg.pipWidth = min(max((resizeStart ?? 0.32) + delta, 0.16), 0.9)
            }
            .onEnded { _ in resizeStart = nil }
    }
}

struct SplitDivider: View {
    @EnvironmentObject private var cam: CameraManager
    let size: CGSize
    @State private var start: CGFloat? = nil

    var body: some View {
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "timer").foregroundStyle(Color.yellow)
                    Text("拍摄倒计时").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.65))
                    }
                }
                HStack(spacing: 14) {
                    Button { timerDraft = max(1, timerDraft - 1) } label: {
                        Image(systemName: "minus").frame(width: 40, height: 40)
                    }
                    Text("\(timerDraft) 秒")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit().frame(minWidth: 90)
                    Button { timerDraft = min(60, timerDraft + 1) } label: {
                        Image(systemName: "plus").frame(width: 40, height: 40)
                    }
                }
                Slider(value: Binding(get: { Double(timerDraft) }, set: { timerDraft = Int($0.rounded()) }), in: 1...60, step: 1)
                HStack(spacing: 10) {
                    Button("关闭") {
                        cam.timerSeconds = 0
                        isPresented = false
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    Button("确定") {
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

// MARK: - 顶部栏（闪光灯 / 实况 / 参数）

struct TopBar: View {
    @EnvironmentObject private var cam: CameraManager
    let onTimerTap: () -> Void

    var body: some View {
        ZStack {
            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(timeString(cam.recordSeconds))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color.red.opacity(0.85)))
            } else {
                HStack(spacing: 22) {
                    iconButton(cam.flashEnabled ? "bolt.fill" : "bolt.slash",
                               active: cam.flashEnabled,
                               label: cam.flashEnabled ? "关闭闪光灯" : "开启闪光灯") {
                        cam.flashEnabled.toggle()
                    }
                    iconButton(cam.cfg.livePhoto ? "livephoto" : "livephoto.slash",
                               active: cam.cfg.livePhoto && cam.captureMode == .photo,
                               dimmed: cam.captureMode == .video,
                               label: "实况照片") {
                        cam.cfg.livePhoto.toggle()
                    }
                    iconButton(cam.timerSeconds == 0 ? "timer" : "timer.circle.fill",
                               active: cam.timerSeconds > 0,
                               label: cam.timerSeconds == 0 ? "设置倒计时" : "倒计时：\(cam.timerSeconds) 秒",
                               badge: cam.timerSeconds == 0 ? nil : "\(cam.timerSeconds)") {
                        onTimerTap()
                    }
                    iconButton("arrow.triangle.2.circlepath",
                               active: false,
                               label: "切换主副摄像头") {
                        cam.swapCameras()
                    }
                }
            }

            // Resolution and FPS readout intentionally omitted; keep the top edge visually clean.
        }

    }

    private func iconButton(_ icon: String, active: Bool, dimmed: Bool = false,
                            label: String, badge: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? Color.yellow : Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(active ? Color.yellow.opacity(0.14) : Color.white.opacity(0.07)))
                .overlay(Circle().stroke(Color.white.opacity(active ? 0.2 : 0.1), lineWidth: 0.6))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Circle().fill(Color.yellow))
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .opacity(dimmed ? 0.4 : 1)
    }

    private func timeString(_ s: Int) -> String {
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - 底部栏

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
    let bottomDockPadding: CGFloat

    // Match the visible circles and tap targets on both sides of the shutter.
    private let sideButtonSize: CGFloat = 48

    private var zoomRow: some View {
        HStack {
            Spacer(minLength: 0)
            ZoomChips()
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var splitButton: some View {
        Button { cam.toggleLayout() } label: {
            Image(systemName: cam.cfg.layout == .pip ? "rectangle.on.rectangle" : "rectangle.split.1x2")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.yellow)
                .frame(width: sideButtonSize, height: sideButtonSize)
                .background(Circle().fill(Color.black))
                .overlay(Circle().stroke(Color.yellow, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cam.cfg.layout == .pip ? "切换上下分屏" : "切换画中画")
    }

    private var paramsButton: some View {
        Button {
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
            withAnimation(.easeInOut(duration: 0.15)) {
                cam.captureMode = cam.captureMode == .photo ? .video : .photo
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: cam.captureMode == .photo ? "video.fill" : "camera.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: sideButtonSize, height: sideButtonSize)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                Image(systemName: "arrow.left.arrow.right")
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
        VStack(spacing: 12) {
            // 倍率条固定在快门上方。
            zoomRow

            // 同一行：左侧相册，中央快门，右侧依次为模式切换、分屏和参数。
            ZStack {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ShutterButton()
                    Spacer(minLength: 0)
                }
                HStack(alignment: .center, spacing: 8) {
                    // Left cluster: gallery then photo/video mode toggle.
                    ThumbnailButton(action: onAlbumTap)
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
        .padding(.top, 8)
        .padding(.bottom, 8)
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

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let img = cam.lastThumb {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.white.opacity(0.12)
                                .overlay {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 19, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.7))
                                }
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))

                    Image(systemName: "square.stack")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 19, height: 19)
                        .background(Color.black.opacity(0.78), in: Circle())
                        .offset(x: 3, y: 1)
                }

            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开相册")
        .accessibilityHint("在应用内查看已保存的照片和视频")
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
struct ShutterButton: View {
    @EnvironmentObject private var cam: CameraManager

    var body: some View {
        Button { cam.shutterTapped() } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                if cam.captureMode == .photo {
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                } else {
                    RoundedRectangle(cornerRadius: cam.isRecording ? 8 : 31)
                        .fill(Color.red)
                        .frame(width: cam.isRecording ? 30 : 62, height: cam.isRecording ? 30 : 62)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
        }
        .buttonStyle(.plain)
        .disabled(!cam.ready || cam.isCapturingPhoto)
        .opacity(cam.ready && !cam.isCapturingPhoto ? 1 : 0.4)
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
