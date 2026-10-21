import SwiftUI
import UIKit

struct CameraScreen: View {
    @EnvironmentObject private var cam: CameraManager
    @State private var showPanel = false
    @State private var panelTab: PanelTab = .pip

    private let topBarHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let previewSize = fitSize(in: geo.size)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Color.clear.frame(height: topBarHeight)
                    PreviewStage(size: previewSize)
                        .frame(width: previewSize.width, height: previewSize.height)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 0) {
                    TopBar()
                        .frame(height: topBarHeight)
                    Spacer(minLength: 0)
                    if showPanel {
                        ToolPanel(tab: $panelTab)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    BottomBar(showPanel: $showPanel, panelTab: $panelTab)
                }

                OverlayLayer()
            }
            .onAppear { updateFreeAspect(for: geo.size) }
            .onChange(of: geo.size) { _, newSize in updateFreeAspect(for: newSize) }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.22), value: showPanel)
    }

    private func fitSize(in size: CGSize) -> CGSize {
        let availableHeight = max(size.height - topBarHeight, 100)
        if cam.cfg.aspect == .free {
            // Fill the available preview area, adapting to rotation and window size.
            return CGSize(width: size.width, height: availableHeight)
        }
        let aspect = cam.cfg.aspectRatio
        let w = min(size.width, availableHeight * aspect)
        return CGSize(width: w, height: w / aspect)
    }

    private func updateFreeAspect(for size: CGSize) {
        cam.updateFreeAspect(width: size.width, height: max(size.height - topBarHeight, 100))
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
                    Text(cam.statusText).multilineTextAlignment(.center).font(.callout)
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
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { cam.swapCameras() }
                .gesture(moveGesture)
                .simultaneousGesture(pinchGesture)

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
                    dragOriginCenter = cam.cfg.pipCenter
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                guard let origin = dragOriginCenter else { return }
                let next = CGPoint(
                    x: origin.x + value.translation.width / max(size.width, 1),
                    y: origin.y + value.translation.height / max(size.height, 1)
                )
                // The render thread follows the live center; Config and parent view stay stable.
                dragCenter = next
                cam.updatePiPDragPreview(center: next)
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

// MARK: - 顶部栏（闪光灯 / 实况 / 参数）

struct TopBar: View {
    @EnvironmentObject private var cam: CameraManager

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
                               label: cam.timerSeconds == 0 ? "定时器：关闭" : "定时器：\(cam.timerSeconds) 秒",
                               badge: cam.timerSeconds == 0 ? nil : "\(cam.timerSeconds)") {
                        cam.cycleTimer()
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

struct BottomBar: View {
    @EnvironmentObject private var cam: CameraManager
    @Binding var showPanel: Bool
    @Binding var panelTab: PanelTab

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer(minLength: 0)
                ZoomChips()
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            // 快门行：左 = 布局，右 = Build 39 的快捷参数入口
            HStack {
                Button { cam.toggleLayout() } label: {
                    Image(systemName: cam.cfg.layout == .pip ? "rectangle.on.rectangle" : "rectangle.split.1x2")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.black))
                        .overlay(Circle().stroke(Color.yellow, lineWidth: 2.5))
                }
                .buttonStyle(.plain)

                Spacer()
                ShutterButton()
                Spacer()

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
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(showPanel && panelTab == .params ? Color.yellow : Color.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .overlay(Circle().stroke(
                            showPanel && panelTab == .params ? Color.yellow.opacity(0.7) : Color.clear,
                            lineWidth: 1.2
                        ))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("快捷参数")
            }
            .padding(.horizontal, 28)

            // 模式行：缩略图 / 视频·照片 / 换主副画面
            HStack {
                ThumbnailButton()
                Spacer()
                ModePill()
                Spacer()
                Button { cam.swapCameras() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color.black)
    }
}

struct ThumbnailButton: View {
    @EnvironmentObject private var cam: CameraManager

    var body: some View {
        Button {
            if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
        } label: {
            ZStack {
                if let img = cam.lastThumb {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.12)
                    Image(systemName: "photo").foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 「视频 / 照片」胶囊切换，选中项为黄字高亮，支持左右滑动。
struct ModePill: View {
    @EnvironmentObject private var cam: CameraManager

    var body: some View {
        HStack(spacing: 0) {
            item(.video)
            item(.photo)
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { v in
                    guard !cam.isRecording else { return }
                    if v.translation.width < -20 { cam.captureMode = .photo }
                    if v.translation.width > 20 { cam.captureMode = .video }
                }
        )
    }

    private func item(_ mode: CaptureMode) -> some View {
        let selected = cam.captureMode == mode
        return Button {
            if !cam.isRecording { cam.captureMode = mode }
        } label: {
            Text(mode == .video ? "视频" : "照片")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? Color.yellow : Color.white.opacity(0.9))
                .frame(width: 84, height: 40)
                .background(Capsule().fill(selected ? Color.white.opacity(0.16) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

/// 焦段条：.5  1×  2  5。选中那一档是黄色数字 + 深色圆底；捏合变焦到两档之间时，选中档显示当前倍率。
struct ZoomChips: View {
    @EnvironmentObject private var cam: CameraManager
    private let targets: [CGFloat] = [0.5, 1, 2, 5]

    var body: some View {
        let stops = cam.zoomStops
        let current = cam.displayZoom(slot: 0)
        let activeTarget = targets.min(by: { abs($0 - current) < abs($1 - current) }) ?? 1

        HStack(spacing: 3) {
            ForEach(targets, id: \.self) { target in
                let stop = stops.first(where: { abs($0.value - target) < 0.01 })
                let selected = abs(activeTarget - target) < 0.01
                Button {
                    guard let stop else { return }
                    cam.selectStop(stop)
                } label: {
                    Text(target < 1 ? "0.5×" : "\(Int(target))×")
                        .font(.system(size: 12, weight: selected ? .bold : .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.yellow : Color.white.opacity(stop == nil ? 0.32 : 0.84))
                        .frame(width: 44, height: 36)
                        .background(Capsule().fill(selected ? Color.yellow.opacity(0.15) : Color.clear))
                        .overlay(Capsule().stroke(selected ? Color.yellow.opacity(0.48) : Color.white.opacity(0.06), lineWidth: 0.8))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(stop == nil || cam.isRecording)
                .accessibilityLabel(stop == nil ? "\(target) 倍镜头暂不可用" : "切换到 \(target) 倍")
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.7))
        // Fixed-width buttons prevent the row from shifting as the selected stop changes.
        .animation(.easeOut(duration: 0.12), value: activeTarget)
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

    var body: some View {
        ZStack {
            if cam.screenFlash {
                Color.white.opacity(0.92).ignoresSafeArea().allowsHitTesting(false)
            }
            if let n = cam.countdown {
                Text("\(n)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .shadow(radius: 8)
                    .allowsHitTesting(false)
            }
            if let text = cam.toast {
                VStack {
                    Text(text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .padding(.top, 64)
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
