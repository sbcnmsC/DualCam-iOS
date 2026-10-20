import SwiftUI

struct CameraScreen: View {
    @EnvironmentObject private var cam: CameraManager
    @State private var showPanel = false
    @State private var panelTab: PanelTab = .pip

    private let topBarHeight: CGFloat = 52

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
                    TopBar().frame(height: topBarHeight)
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
                FocusMarkerView()
                    .position(x: marker.point.x * size.width, y: marker.point.y * size.height)
                    .allowsHitTesting(false)
                    .id(marker.id)
                    .transition(.opacity)
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
                    cam.exposureDragChanged(dy: v.translation.height)
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

struct FocusMarkerView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 72, height: 72)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.yellow)
                .offset(x: 46, y: 0)
        }
        .scaleEffect(appeared ? 1 : 1.35)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { appeared = true }
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

// MARK: - 顶部栏

struct TopBar: View {
    @EnvironmentObject private var cam: CameraManager

    var body: some View {
        HStack(spacing: 8) {
            barButton(icon: cam.flashEnabled ? "bolt.fill" : "bolt.slash",
                      tint: cam.flashEnabled ? .yellow : .white) {
                cam.flashEnabled.toggle()
            }

            Button { cam.cycleTimer() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                    Text(cam.timerSeconds == 0 ? "关" : "\(cam.timerSeconds)秒")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(cam.timerSeconds == 0 ? Color.white : Color.yellow)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)

            barButton(icon: cam.cfg.layout == .pip ? "rectangle.on.rectangle" : "rectangle.split.1x2",
                      tint: .white) {
                cam.toggleLayout()
            }

            Spacer(minLength: 4)

            Group {
                if cam.isRecording {
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(timeString(cam.recordSeconds))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                } else {
                    Text("\(cam.outputLabel) · \(cam.effectiveFPS)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Spacer(minLength: 4)

            Button { cam.cycleCombo() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "camera.rotate")
                    Text(comboTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(cam.isRecording || cam.combos.count < 2)
            .opacity(cam.isRecording ? 0.4 : 1)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 12)
    }

    private var comboTitle: String {
        guard cam.comboIndex < cam.combos.count else { return "镜头" }
        return cam.combos[cam.comboIndex].title
    }

    private func barButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
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
        VStack(spacing: 12) {
            ZoomChips()

            HStack(spacing: 26) {
                modeButton(.photo)
                modeButton(.video)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { v in
                        guard !cam.isRecording else { return }
                        if v.translation.width < -24 { cam.captureMode = .video }
                        if v.translation.width > 24 { cam.captureMode = .photo }
                    }
            )

            HStack {
                Button { showPanel.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20))
                        .foregroundStyle(showPanel ? Color.yellow : Color.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)

                Spacer()
                ShutterButton()
                Spacer()

                Button { cam.swapCameras() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32)
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func modeButton(_ mode: CaptureMode) -> some View {
        Button {
            if !cam.isRecording { cam.captureMode = mode }
        } label: {
            Text(mode.rawValue)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(cam.captureMode == mode ? Color.yellow : Color.white.opacity(0.8))
                .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}

struct ZoomChips: View {
    @EnvironmentObject private var cam: CameraManager

    var body: some View {
        let slot = cam.mainSlot
        let info = cam.slotInfos[slot]
        let current = cam.displayZoom(slot: slot)
        HStack(spacing: 8) {
            Text(zoomText(current))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.yellow)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(Color.black.opacity(0.5)))

            ForEach(cam.zoomPresets(slot: slot), id: \.self) { preset in
                Button {
                    cam.setZoom(slot: slot, factor: preset / max(info.baseMultiplier, 0.01))
                } label: {
                    Text(zoomText(preset))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 30)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func zoomText(_ v: CGFloat) -> String {
        if abs(v - v.rounded()) < 0.05 { return "\(Int(v.rounded()))×" }
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
        .opacity(cam.ready ? 1 : 0.4)
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
