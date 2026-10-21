import SwiftUI

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
                    TopBar(paramsActive: showPanel && panelTab == .params) {
                        if showPanel && panelTab == .params {
                            showPanel = false
                        } else {
                            panelTab = .params
                            showPanel = true
                        }
                    }
                    .frame(height: topBarHeight)
                    Spacer(minLength: 0)
                    if showPanel {
                        ToolPanel(tab: $panelTab)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    BottomBar(showPanel: $showPanel)
                }

                OverlayLayer()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.22), value: showPanel)
    }

    private func fitSize(in size: CGSize) -> CGSize {
        let aspect = cam.cfg.aspect.value
        let availableHeight = max(size.height - topBarHeight, 100)
        let w = min(size.width, availableHeight * aspect)
        return CGSize(width: w, height: w / aspect)
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
                FocusMarkerView(exposureBias: marker.exposureBias)
                    .position(x: marker.point.x * size.width, y: marker.point.y * size.height)
                    .allowsHitTesting(false)
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
                ZoomChips().padding(.bottom, 14)
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

struct FocusMarkerView: View {
    let exposureBias: Float?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                Image(systemName: exposureBias == nil ? "scope" : "sun.max.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.yellow)
                    .offset(x: 36, y: -36)
            }
            if let exposureBias {
                Text(String(format: "EV %+.1f", Double(exposureBias)))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.yellow)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
            }
        }
        .scaleEffect(appeared ? 1 : 1.12)
        .onAppear {
            withAnimation(.easeOut(duration: 0.16)) { appeared = true }
        }
    }
}

struct PiPOverlay: View {
    @EnvironmentObject private var cam: CameraManager
    let size: CGSize

    @State private var dragStart: CGPoint? = nil
    @State private var pinchStart: CGFloat? = nil
    @State private var resizeStart: CGFloat? = nil

    var body: some View {
        let n = Compositor.pipRectNormalized(cfg: cam.cfg)
        let rect = CGRect(x: n.minX * size.width, y: n.minY * size.height,
                          width: n.width * size.width, height: n.height * size.height)
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { cam.swapCameras() }
                .gesture(moveGesture(current: CGPoint(x: n.midX, y: n.midY)))
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

    private func moveGesture(current: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if dragStart == nil { dragStart = current }
                let s = dragStart ?? current
                cam.cfg.pipCenter = CGPoint(x: s.x + v.translation.width / max(size.width, 1),
                                            y: s.y + v.translation.height / max(size.height, 1))
            }
            .onEnded { _ in
                cam.snapPiP()
                dragStart = nil
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
    var paramsActive = false
    var onParams: () -> Void = {}

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
                    iconButton("slider.horizontal.3", active: paramsActive, label: "相机参数设置") {
                        onParams()
                    }
                }
            }

            HStack {
                Spacer()
                Text(cam.outputLabel.isEmpty ? "\(cam.effectiveFPS) fps" : "\(cam.outputLabel) · \(cam.effectiveFPS) fps")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.11), lineWidth: 0.6))
                    .padding(.trailing, 12)
            }
        }
    }

    private func iconButton(_ icon: String, active: Bool, dimmed: Bool = false,
                            label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? Color.yellow : Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(active ? Color.yellow.opacity(0.14) : Color.white.opacity(0.07)))
                .overlay(Circle().stroke(Color.white.opacity(active ? 0.2 : 0.1), lineWidth: 0.6))
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

    var body: some View {
        VStack(spacing: 16) {
            // 快门行：左 = 布局（对应原生的微距键位置），右 = 更多
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

                Button { showPanel.toggle() } label: {
                    Image(systemName: "circle.grid.2x3.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(showPanel ? Color.yellow : Color.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
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
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(stops.isEmpty ? 0 : 0.28)))
    }

    private func activeIndex(stops: [ZoomStop], current: CGFloat) -> Int? {
        guard !stops.isEmpty else { return nil }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, s) in stops.enumerated() {
            let d = abs(s.value - current)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    private func plainText(_ v: CGFloat) -> String {
        return v < 1 ? ".5" : "\(Int(v))"
    }

    private func selectedText(stop: ZoomStop, current: CGFloat) -> String {
        let v = abs(stop.value - current) < 0.05 ? stop.value : current
        if abs(v - v.rounded()) < 0.05 { return "\(Int(v.rounded()))×" }
        if v < 1 { return ".5×" }
        return String(format: "%.1f×", Double(v))
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
