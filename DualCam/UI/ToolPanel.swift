import SwiftUI

private struct ToolPanelIconRotationKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var toolPanelIconRotationDegrees: CGFloat {
        get { self[ToolPanelIconRotationKey.self] }
        set { self[ToolPanelIconRotationKey.self] = newValue }
    }
}

/// Rotate the symbol independently; labels, values and controls remain readable in landscape.
private struct RotatingSymbolLabelStyle: LabelStyle {
    let degrees: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.rotationEffect(.degrees(degrees))
            configuration.title
        }
    }
}

struct ToolPanel: View {
    @Binding var tab: PanelTab
    var isLandscape: Bool = false
    var rotationDegrees: CGFloat = 90

    private var selectedContent: some View {
        Group {
            switch tab {
            case .pip: PiPTab()
            case .filter: FilterTab()
            case .params: QuickParamsTab(isLandscape: isLandscape, rotationDegrees: rotationDegrees)
            case .settings: SettingsTab()
            }
        }
    }

    private func tabButton(_ item: PanelTab, vertical: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { tab = item }
        } label: {
            Group {
                if vertical {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .rotationEffect(.degrees(vertical ? rotationDegrees : 0))
                            .animation(.smooth(duration: 0.28), value: rotationDegrees)
                            .font(.system(size: 15, weight: .semibold))
                        Text(item.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .rotationEffect(.degrees(rotationDegrees))
                            .animation(.smooth(duration: 0.28), value: rotationDegrees)
                            .font(.system(size: 16, weight: .semibold))
                        if tab == item {
                            Text(item.rawValue).font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .foregroundStyle(tab == item ? Color.yellow : Color.white.opacity(0.7))
            .background {
                if tab == item {
                    RoundedRectangle(cornerRadius: vertical ? 8 : 14)
                        .fill(Color.white.opacity(0.16))
                }
            }
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Group {
            if isLandscape {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 4) {
                        ForEach(PanelTab.allCases) { item in
                            tabButton(item, vertical: true)
                        }
                    }
                    .frame(width: 54)

                    ScrollView {
                        selectedContent
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(PanelTab.allCases) { item in
                            tabButton(item, vertical: false)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                    ScrollView {
                        selectedContent
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }
                    .frame(height: 230)
                }
            }
        }
        .environment(\.toolPanelIconRotationDegrees, isLandscape ? rotationDegrees : 0)
        .labelStyle(RotatingSymbolLabelStyle(degrees: isLandscape ? rotationDegrees : 0))
        .foregroundStyle(Color.white)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .padding(.horizontal, isLandscape ? 4 : 8)
        .padding(.bottom, 4)
    }
}

struct LabeledSlider: View {
    @Environment(\.toolPanelIconRotationDegrees) private var iconRotationDegrees
    var icon: String? = nil
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String
    var disabled = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .rotationEffect(.degrees(iconRotationDegrees))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: icon == nil ? 64 : 84, alignment: .leading)
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
            Text(valueText)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
        }
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
    }
}

// MARK: - 小窗

struct PiPTab: View {
    @EnvironmentObject private var cam: CameraManager

    var body: some View {
        let isPiP = cam.cfg.layout == .pip
        VStack(alignment: .leading, spacing: 12) {
            if !isPiP {
                LabeledSlider(title: "上下比例",
                              value: cfgBinding(\.splitRatio),
                              range: 0.25...0.75,
                              valueText: "\(Int(cam.cfg.splitRatio * 100))%")
            }

            Group {
                HStack {
                    Text("形状").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                    Picker("", selection: $cam.cfg.pipShape) {
                        ForEach(PiPShape.allCases) { s in Text(s.rawValue).tag(s) }
                    }
                    .pickerStyle(.segmented)
                }
                HStack {
                    Text("比例").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                    Picker("", selection: $cam.cfg.pipRatio) {
                        ForEach(PiPRatio.allCases) { r in Text(r.rawValue).tag(r) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(cam.cfg.pipShape == .circle)
                    .opacity(cam.cfg.pipShape == .circle ? 0.4 : 1)
                }
                LabeledSlider(title: "大小",
                              value: cfgBinding(\.pipWidth),
                              range: 0.16...0.9,
                              valueText: "\(Int(cam.cfg.pipWidth * 100))%")
                LabeledSlider(title: "圆角",
                              value: cfgBinding(\.pipCorner),
                              range: 0...0.5,
                              valueText: "\(Int(cam.cfg.pipCorner * 100))%",
                              disabled: cam.cfg.pipShape == .circle)
                LabeledSlider(title: "边框",
                              value: cfgBinding(\.pipBorder),
                              range: 0...8,
                              valueText: String(format: "%.1f", Double(cam.cfg.pipBorder)))
                LabeledSlider(title: "透明度",
                              value: cfgBinding(\.pipOpacity),
                              range: 0.3...1,
                              valueText: "\(Int(cam.cfg.pipOpacity * 100))%")
                Toggle("松手自动吸附边缘 / 中线", isOn: $cam.cfg.pipSnap)
                    .font(.system(size: 13))
                Button {
                    cam.resetPiP()
                } label: {
                    Text("复位位置")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
            .disabled(!isPiP)
            .opacity(isPiP ? 1 : 0.4)
        }
    }

    private func cfgBinding(_ keyPath: WritableKeyPath<Config, CGFloat>) -> Binding<Double> {
        return Binding(
            get: { Double(cam.cfg[keyPath: keyPath]) },
            set: { cam.cfg[keyPath: keyPath] = CGFloat($0) }
        )
    }
}

// MARK: - 滤镜

struct FilterTab: View {
    @EnvironmentObject private var cam: CameraManager
    @Environment(\.toolPanelIconRotationDegrees) private var iconRotationDegrees
    @State private var pendingFilter: FilterKind = .original
    @State private var pendingIntensity: Double = 1

    private var hasPendingChanges: Bool {
        pendingFilter != cam.cfg.filter || abs(pendingIntensity - Double(cam.cfg.filterIntensity)) > 0.005
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterKind.allCases) { kind in cell(kind) }
                }
                .padding(.vertical, 2)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pendingFilter.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                    Text("先选择风格和强度，再点击应用；调整过程中不会改变实时画面。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text("\(Int(pendingIntensity * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.82))
            }

            LabeledSlider(title: "强度",
                          value: $pendingIntensity,
                          range: 0...1,
                          valueText: "\(Int(pendingIntensity * 100))%",
                          disabled: pendingFilter == .original)

            HStack(spacing: 8) {
                Button {
                    pendingFilter = cam.cfg.filter
                    pendingIntensity = Double(cam.cfg.filterIntensity)
                } label: {
                    Label("还原", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(!hasPendingChanges)

                Button {
                    cam.applyFilter(pendingFilter, intensity: CGFloat(pendingIntensity))
                } label: {
                    Label("应用到画面", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hasPendingChanges ? Color.black : Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Capsule().fill(hasPendingChanges ? Color.yellow : Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(!hasPendingChanges)
            }
        }
        .onAppear {
            pendingFilter = cam.cfg.filter
            pendingIntensity = Double(cam.cfg.filterIntensity)
            cam.thumbsActive = true
        }
        .onDisappear { cam.thumbsActive = false }
    }

    private func cell(_ kind: FilterKind) -> some View {
        let selected = pendingFilter == kind
        return Button {
            pendingFilter = kind
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if let img = cam.filterThumbs[kind.rawValue] {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 62, height: 82)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .overlay {
                                Image(systemName: "camera.aperture")
                                    .rotationEffect(.degrees(iconRotationDegrees))
                                    .font(.system(size: 17))
                                    .foregroundStyle(Color.white.opacity(0.35))
                            }
                            .frame(width: 62, height: 82)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.yellow : Color.clear, lineWidth: 2)
                )
                Text(kind.rawValue)
                    .font(.system(size: 12, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? Color.yellow : Color.white)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 参数

struct ParamsTab: View {
    @EnvironmentObject private var cam: CameraManager

    var body: some View {
        let i = min(max(cam.paramTarget, 0), 1)
        let info = cam.slotInfos[i]
        let st = cam.slotStates[i]
        let base = max(info.baseMultiplier, 0.01)

        VStack(alignment: .leading, spacing: 12) {
            Picker("当前镜头", selection: $cam.paramTarget) {
                Text(cam.slotInfos[0].name).tag(0)
                Text(cam.slotInfos[1].name).tag(1)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("曝光与测光", systemImage: "sun.max")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("归零") { cam.resetExposureBias(i) }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                        .disabled(st.manualExposure || st.locked)
                        .opacity(st.manualExposure || st.locked ? 0.4 : 1)
                }

                LabeledSlider(icon: "plusminus.circle", title: "曝光补偿",
                              value: dbl(i, \.exposureBias) { cam.applyExposure($0) },
                              range: Double(info.minBias)...Double(max(info.maxBias, info.minBias + 0.1)),
                              valueText: String(format: "%+.1f EV", Double(st.exposureBias)),
                              disabled: st.manualExposure || st.locked)

                Text("预览画面上下滑动也可以调曝光；点按画面会重新测光与对焦。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.58))

                Toggle("手动 ISO / 快门", isOn: flag(i, \.manualExposure) { cam.applyExposure($0) })
                    .font(.system(size: 12))
                if st.manualExposure {
                    LabeledSlider(icon: "camera.aperture", title: "ISO",
                                  value: dbl(i, \.iso) { cam.applyExposure($0) },
                                  range: Double(info.minISO)...Double(max(info.maxISO, info.minISO + 1)),
                                  valueText: "\(Int(st.iso))")
                    LabeledSlider(icon: "timer", title: "快门",
                                  value: dbl(i, \.shutter) { cam.applyExposure($0) },
                                  range: 0...1,
                                  valueText: shutterText(info: info, t: st.shutter))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("对焦", systemImage: "scope")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("自动对焦") { cam.setAutoFocus(i) }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                }

                Toggle("手动对焦", isOn: flag(i, \.manualFocus) { cam.applyFocus($0) })
                    .font(.system(size: 12))
                    .disabled(!info.supportsManualFocus)
                    .opacity(info.supportsManualFocus ? 1 : 0.4)
                if st.manualFocus {
                    LabeledSlider(icon: "scope", title: "对焦距离",
                                  value: dbl(i, \.lensPosition) { cam.applyFocus($0) },
                                  range: 0...1,
                                  valueText: String(format: "%.2f", Double(st.lensPosition)))
                        .disabled(!info.supportsManualFocus)
                }

                Toggle("锁定对焦 / 曝光", isOn: Binding(
                    get: { cam.slotStates[i].locked },
                    set: { newValue in
                        if cam.slotStates[i].locked != newValue { cam.toggleLock(i) }
                    }))
                    .font(.system(size: 12))

                Text("轻点预览对焦，黄色框旁显示当前曝光值。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.58))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))

            VStack(alignment: .leading, spacing: 9) {
                Label("白平衡", systemImage: "thermometer.medium")
                    .font(.system(size: 12, weight: .semibold))
                Toggle("手动白平衡", isOn: flag(i, \.manualWB) { cam.applyWhiteBalance($0) })
                    .font(.system(size: 12))
                if st.manualWB {
                    LabeledSlider(icon: "thermometer", title: "色温",
                                  value: dbl(i, \.temperature) { cam.applyWhiteBalance($0) },
                                  range: 2500...9000,
                                  valueText: "\(Int(st.temperature))K")
                    LabeledSlider(icon: "circle.lefthalf.filled", title: "色调",
                                  value: dbl(i, \.tint) { cam.applyWhiteBalance($0) },
                                  range: -150...150,
                                  valueText: "\(Int(st.tint))")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))

            LabeledSlider(icon: "plus.magnifyingglass", title: "变焦",
                          value: Binding(
                            get: { Double(cam.displayZoom(slot: i)) },
                            set: { cam.setZoom(slot: i, factor: CGFloat($0) / base) }),
                          range: Double(base)...Double(max(base * info.maxZoom, base + 0.01)),
                          valueText: String(format: "%.1f×", Double(cam.displayZoom(slot: i))))
        }
    }

    private func shutterText(info: SlotInfo, t: Double) -> String {
        let ratio = max(info.maxShutter / max(info.minShutter, 0.000001), 1)
        let seconds = info.minShutter * pow(ratio, t)
        if seconds >= 0.5 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / max(seconds, 0.000001)).rounded()))"
    }

    private func dbl<T: BinaryFloatingPoint>(_ i: Int, _ keyPath: WritableKeyPath<SlotState, T>,
                                             apply: @escaping (Int) -> Void) -> Binding<Double> {
        return Binding(
            get: { Double(cam.slotStates[i][keyPath: keyPath]) },
            set: {
                cam.slotStates[i][keyPath: keyPath] = T($0)
                apply(i)
            }
        )
    }

    private func flag(_ i: Int, _ keyPath: WritableKeyPath<SlotState, Bool>,
                      apply: @escaping (Int) -> Void) -> Binding<Bool> {
        return Binding(
            get: { cam.slotStates[i][keyPath: keyPath] },
            set: {
                cam.slotStates[i][keyPath: keyPath] = $0
                apply(i)
            }
        )
    }
}

// MARK: - 设置

struct SettingsTab: View {
    @EnvironmentObject private var cam: CameraManager
    @Environment(\.toolPanelIconRotationDegrees) private var iconRotationDegrees

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("画幅").font(.system(size: 13, weight: .medium))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(CanvasAspect.allCases) { aspect in
                        let selected = cam.cfg.aspect == aspect
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                cam.cfg.aspect = aspect
                            }
                        } label: {
                            Text(aspect.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selected ? Color.yellow : Color.white.opacity(0.86))
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .background(Capsule().fill(selected ? Color.yellow.opacity(0.15) : Color.white.opacity(0.07)))
                                .overlay(Capsule().stroke(selected ? Color.yellow.opacity(0.55) : Color.clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if cam.cfg.aspect == .free {
                    Text("全屏自由会覆盖当前预览区域，并随屏幕方向与可用尺寸自动调整输出比例。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text("分辨率").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                Picker("", selection: $cam.cfg.resolution) {
                    ForEach(ResolutionOption.allCases) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
                .disabled(cam.isRecording)
            }
            HStack {
                Text("帧率").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                Picker("", selection: $cam.cfg.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                .disabled(cam.isRecording)
            }
            Text(cam.cfg.resolution == .maximum
                 ? "录像与实时预览优先使用设备支持的最高双摄兼容格式；关闭实况照片时，静态照片会单独切换至单摄高清格式。"
                 : "此选项控制双摄预览和录像规格。关闭实况照片时，静态照片另走独立单摄高清通道；60 帧会增加性能负担。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("保存").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                Picker("", selection: $cam.cfg.outputMode) {
                    ForEach(OutputMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                .disabled(cam.isRecording)
            }
            Text(cam.cfg.livePhoto
                 ? "实况照片已开启：为保持静态图与动态片段配对，照片使用双摄兼容采集帧。关闭实况后，会暂时切换到单摄静态拍摄，再自动恢复双摄预览。"
                 : "高像素模式：原图模式分别拍摄两路静态原片；合成模式以主镜头高清照片为底图，副画面使用双摄实时流，因此副画面细节受视频规格限制。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)

            Toggle("实况照片（开启时使用兼容分辨率）", isOn: $cam.cfg.livePhoto).font(.system(size: 13))
            HStack {
                Text("定时器").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                Picker("", selection: $cam.timerSeconds) {
                    Text("关").tag(0)
                    Text("3 秒").tag(3)
                    Text("10 秒").tag(10)
                }
                .pickerStyle(.segmented)
            }
            if cam.combos.count > 1 {
                HStack {
                    Text("镜头组合").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                    Picker("", selection: Binding(get: { cam.comboIndex }, set: { cam.selectCombo($0) })) {
                        ForEach(cam.combos.indices, id: \.self) { i in
                            Text(cam.combos[i].title).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(cam.isRecording)
                    Spacer()
                }
            }
            Toggle("弱光增亮", isOn: $cam.cfg.lowLight).font(.system(size: 13))
            Toggle("视频防抖（开启会增加预览延迟）", isOn: $cam.cfg.stabilization).font(.system(size: 13))
            Toggle("前置镜像", isOn: $cam.cfg.mirrorFront).font(.system(size: 13))
            Toggle("三分参考线", isOn: $cam.cfg.showGrid).font(.system(size: 13))

            Divider().overlay(Color.white.opacity(0.12))
            QuickParameterPreferencesSection()
        }
    }
}

// MARK: - 快捷参数栏（选择参数类型后即时显示调节器）

private enum QuickParameter: String, CaseIterable, Identifiable {
    case exposure = "曝光"
    case iso = "ISO"
    case shutter = "快门"
    case focus = "对焦"
    case whiteBalance = "白平衡"
    case zoom = "变焦"
    case resolution = "分辨率"
    case frameRate = "帧率"
    case timer = "定时器"
    case stabilization = "防抖"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .exposure: return "sun.max"
        case .iso: return "camera.aperture"
        case .shutter: return "timer"
        case .focus: return "scope"
        case .whiteBalance: return "thermometer.medium"
        case .zoom: return "plus.magnifyingglass"
        case .resolution: return "viewfinder"
        case .frameRate: return "speedometer"
        case .timer: return "hourglass"
        case .stabilization: return "viewfinder.circle"
        }
    }
}

struct QuickParamsTab: View {
    @EnvironmentObject private var cam: CameraManager
    var isLandscape: Bool = false
    var rotationDegrees: CGFloat = 90
    @State private var selected: QuickParameter = .exposure
    @AppStorage("dualcam.quickParameterOrder") private var parameterOrder = "曝光,ISO,快门,对焦,白平衡,变焦,分辨率,帧率,定时器,防抖"
    @AppStorage("dualcam.quickParameterVisible") private var visibleParameters = "曝光,ISO,快门,对焦,白平衡,变焦,分辨率,帧率,定时器,防抖"

    private var orderedParameters: [QuickParameter] {
        let stored = parameterOrder.split(separator: ",").compactMap { QuickParameter(rawValue: String($0)) }
        return stored + QuickParameter.allCases.filter { !stored.contains($0) }
    }

    private var visibleItems: [QuickParameter] {
        let visible = Set(visibleParameters.split(separator: ",").map(String.init))
        return orderedParameters.filter { visible.contains($0.rawValue) }
    }

    var body: some View {
        let i = min(max(cam.paramTarget, 0), 1)
        let activeSelection = visibleItems.contains(selected) ? selected : (visibleItems.first ?? .exposure)

        Group {
            if isLandscape {
                HStack(alignment: .top, spacing: 8) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(visibleItems) { item in
                                Button {
                                    withAnimation(.easeOut(duration: 0.18)) { selected = item }
                                } label: {
                                    VStack(spacing: 3) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 14, weight: .semibold))
                                            .rotationEffect(.degrees(rotationDegrees))
                                            .animation(.smooth(duration: 0.28), value: rotationDegrees)
                                        Text(item.rawValue)
                                            .font(.system(size: 9, weight: .medium))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.75)
                                    }
                                    .foregroundStyle(activeSelection == item ? Color.yellow : Color.white.opacity(0.8))
                                    .frame(width: 58, height: 43)
                                    .background(RoundedRectangle(cornerRadius: 9)
                                        .fill(activeSelection == item ? Color.yellow.opacity(0.14) : Color.white.opacity(0.06)))
                                    .overlay(RoundedRectangle(cornerRadius: 9)
                                        .stroke(activeSelection == item ? Color.yellow.opacity(0.7) : Color.clear, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(width: 62)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 5) {
                                Text("快捷控制")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.65))
                                Spacer(minLength: 2)
                                Picker("镜头", selection: $cam.paramTarget) {
                                    Text(cam.slotInfos[0].name).tag(0)
                                    Text(cam.slotInfos[1].name).tag(1)
                                }
                                .pickerStyle(.menu)
                                .tint(.yellow)
                                .frame(maxWidth: 118)
                            }

                            if visibleItems.isEmpty {
                                Text("没有启用的快捷参数，请到设置中开启。")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.white.opacity(0.65))
                            } else {
                                controlBody(slot: i, parameter: activeSelection)
                            }
                        }
                        .padding(.trailing, 2)
                        .padding(.vertical, 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Text("快捷控制").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.65))
                        Spacer()
                        Picker("镜头", selection: $cam.paramTarget) {
                            Text(cam.slotInfos[0].name).tag(0)
                            Text(cam.slotInfos[1].name).tag(1)
                        }
                        .pickerStyle(.menu)
                        .tint(.yellow)
                        .frame(maxWidth: 150)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(visibleItems) { item in
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) { selected = item }
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: item.icon)
                                            .rotationEffect(.degrees(rotationDegrees))
                                            .animation(.smooth(duration: 0.28), value: rotationDegrees)
                                            .font(.system(size: 16, weight: .semibold))
                                        Text(item.rawValue).font(.system(size: 10, weight: .medium))
                                    }
                                    .foregroundStyle(activeSelection == item ? Color.yellow : Color.white.opacity(0.8))
                                    .frame(width: 59, height: 49)
                                    .background(RoundedRectangle(cornerRadius: 10)
                                        .fill(activeSelection == item ? Color.yellow.opacity(0.14) : Color.white.opacity(0.065)))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(activeSelection == item ? Color.yellow.opacity(0.75) : Color.clear, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if visibleItems.isEmpty {
                        Text("没有启用的快捷参数。请在「设置 → 快捷栏优先显示」中开启至少一项。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.65))
                    } else {
                        controlBody(slot: i, parameter: activeSelection)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func controlBody(slot i: Int, parameter: QuickParameter) -> some View {
        let st = cam.slotStates[i]
        let info = cam.slotInfos[i]
        let base = max(info.baseMultiplier, 0.01)

        switch parameter {
        case .exposure:
            HStack {
                Label("曝光补偿", systemImage: "sun.max").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "%+.1f EV", Double(st.exposureBias)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.yellow)
                Button("归零") { cam.resetExposureBias(i) }
                    .font(.system(size: 11, weight: .semibold)).tint(.yellow)
            }
            LabeledSlider(title: "EV", value: numberBinding(i, \.exposureBias) { cam.applyExposure($0) },
                          range: Double(info.minBias)...Double(max(info.maxBias, info.minBias + 0.1)),
                          valueText: String(format: "%+.1f", Double(st.exposureBias)),
                          disabled: st.manualExposure || st.locked)
        case .iso:
            if !st.manualExposure {
                Button {
                    cam.slotStates[i].manualExposure = true
                    cam.applyExposure(i)
                } label: {
                    Label("启用手动曝光以调节 ISO", systemImage: "lock.open")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(Capsule().fill(Color.yellow.opacity(0.16)))
                }.buttonStyle(.plain)
            } else {
                LabeledSlider(icon: "camera.aperture", title: "ISO",
                              value: numberBinding(i, \.iso) { cam.applyExposure($0) },
                              range: Double(info.minISO)...Double(max(info.maxISO, info.minISO + 1)),
                              valueText: "\(Int(st.iso))")
            }
        case .shutter:
            if !st.manualExposure {
                Button {
                    cam.slotStates[i].manualExposure = true
                    cam.applyExposure(i)
                } label: {
                    Label("启用手动曝光以调节快门", systemImage: "lock.open")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(Capsule().fill(Color.yellow.opacity(0.16)))
                }.buttonStyle(.plain)
            } else {
                LabeledSlider(icon: "timer", title: "快门",
                              value: numberBinding(i, \.shutter) { cam.applyExposure($0) },
                              range: 0...1, valueText: shutterText(info: info, t: st.shutter))
            }
        case .focus:
            HStack {
                Toggle("手动对焦", isOn: boolBinding(i, \.manualFocus) { cam.applyFocus($0) })
                    .font(.system(size: 12))
                Spacer()
                Button("自动对焦") { cam.setAutoFocus(i) }
                    .font(.system(size: 11, weight: .semibold)).tint(.yellow)
            }
            if st.manualFocus {
                LabeledSlider(icon: "scope", title: "对焦距离",
                              value: numberBinding(i, \.lensPosition) { cam.applyFocus($0) },
                              range: 0...1, valueText: String(format: "%.2f", Double(st.lensPosition)),
                              disabled: !info.supportsManualFocus)
            } else {
                Text("点按预览对焦；焦点框右侧太阳滑杆可调节曝光。")
                    .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.62))
            }
        case .whiteBalance:
            Toggle("手动白平衡", isOn: boolBinding(i, \.manualWB) { cam.applyWhiteBalance($0) })
                .font(.system(size: 12))
            if st.manualWB {
                LabeledSlider(icon: "thermometer", title: "色温",
                              value: numberBinding(i, \.temperature) { cam.applyWhiteBalance($0) },
                              range: 2500...9000, valueText: "\(Int(st.temperature))K")
                LabeledSlider(icon: "circle.lefthalf.filled", title: "色调",
                              value: numberBinding(i, \.tint) { cam.applyWhiteBalance($0) },
                              range: -150...150, valueText: "\(Int(st.tint))")
            }
            Button {
                cam.slotStates[i].manualWB = false
                cam.applyWhiteBalance(i)
            } label: {
                Label("恢复自动白平衡", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
        case .zoom:
            LabeledSlider(icon: "plus.magnifyingglass", title: "变焦",
                          value: Binding(
                            get: { Double(cam.displayZoom(slot: i)) },
                            set: { cam.setZoom(slot: i, factor: CGFloat($0) / base) }),
                          range: Double(base)...Double(max(base * info.maxZoom, base + 0.01)),
                          valueText: String(format: "%.1f×", Double(cam.displayZoom(slot: i))))
        case .resolution:
            HStack {
                Text("分辨率").font(.system(size: 12, weight: .semibold))
                Picker("分辨率", selection: $cam.cfg.resolution) {
                    ForEach(ResolutionOption.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.segmented).disabled(cam.isRecording)
            }
        case .frameRate:
            HStack {
                Text("帧率").font(.system(size: 12, weight: .semibold))
                Picker("帧率", selection: $cam.cfg.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented).disabled(cam.isRecording)
            }
            Text("当前双摄格式不支持所选帧率时，会自动退到可用档位。")
                .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.6))
        case .timer:
            HStack {
                Text("定时器").font(.system(size: 12, weight: .semibold))
                Picker("定时器", selection: $cam.timerSeconds) {
                    Text("关闭").tag(0)
                    Text("3 秒").tag(3)
                    Text("10 秒").tag(10)
                }
                .pickerStyle(.segmented)
            }
        case .stabilization:
            Toggle("系统视频防抖", isOn: $cam.cfg.stabilization)
                .font(.system(size: 12)).disabled(cam.isRecording)
            Text("只在设备和当前双摄连接支持时生效。")
                .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private func numberBinding<T: BinaryFloatingPoint>(
        _ i: Int, _ keyPath: WritableKeyPath<SlotState, T>,
        apply: @escaping (Int) -> Void
    ) -> Binding<Double> {
        Binding(
            get: { Double(cam.slotStates[i][keyPath: keyPath]) },
            set: {
                cam.slotStates[i][keyPath: keyPath] = T($0)
                apply(i)
            }
        )
    }

    private func boolBinding(
        _ i: Int, _ keyPath: WritableKeyPath<SlotState, Bool>,
        apply: @escaping (Int) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { cam.slotStates[i][keyPath: keyPath] },
            set: {
                cam.slotStates[i][keyPath: keyPath] = $0
                apply(i)
            }
        )
    }

    private func shutterText(info: SlotInfo, t: Double) -> String {
        let ratio = max(info.maxShutter / max(info.minShutter, 0.000001), 1)
        let seconds = info.minShutter * pow(ratio, t)
        if seconds >= 0.5 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / max(seconds, 0.000001)).rounded()))"
    }
}


// MARK: - 快捷栏优先显示（持久化）

private struct QuickParameterPreferencesSection: View {
    @Environment(\.toolPanelIconRotationDegrees) private var iconRotationDegrees
    @AppStorage("dualcam.quickParameterOrder") private var parameterOrder = "曝光,ISO,快门,对焦,白平衡,变焦,分辨率,帧率,定时器,防抖"
    @AppStorage("dualcam.quickParameterVisible") private var visibleParameters = "曝光,ISO,快门,对焦,白平衡,变焦,分辨率,帧率,定时器,防抖"

    private var orderedItems: [QuickParameter] {
        let stored = parameterOrder.split(separator: ",").compactMap { QuickParameter(rawValue: String($0)) }
        return stored + QuickParameter.allCases.filter { !stored.contains($0) }
    }

    private var visibleSet: Set<String> {
        Set(visibleParameters.split(separator: ",").map(String.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("快捷栏优先显示", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(visibleSet.count)/\(QuickParameter.allCases.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Text("开关控制显示；↑↓调整快捷栏从左到右的优先顺序。设置会自动保存。")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(orderedItems.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .rotationEffect(.degrees(iconRotationDegrees))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                        .frame(width: 22)
                    Text(item.rawValue)
                        .font(.system(size: 12))
                    Spacer()
                    Toggle("显示", isOn: Binding(
                        get: { visibleSet.contains(item.rawValue) },
                        set: { setVisible(item, enabled: $0) }
                    ))
                    .labelsHidden()
                    .tint(.yellow)
                    .scaleEffect(0.85)

                    Button { move(item, offset: -1) } label: {
                        Image(systemName: "arrow.up")
                            .rotationEffect(.degrees(iconRotationDegrees))
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 28)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.25 : 1)
                    .accessibilityLabel("将\(item.rawValue)提前")

                    Button { move(item, offset: 1) } label: {
                        Image(systemName: "arrow.down")
                            .rotationEffect(.degrees(iconRotationDegrees))
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 28)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == orderedItems.count - 1)
                    .opacity(index == orderedItems.count - 1 ? 0.25 : 1)
                    .accessibilityLabel("将\(item.rawValue)后移")
                }
                .padding(.vertical, 2)
            }

            Button {
                parameterOrder = QuickParameter.allCases.map(\.rawValue).joined(separator: ",")
                visibleParameters = QuickParameter.allCases.map(\.rawValue).joined(separator: ",")
            } label: {
                Label("恢复默认快捷栏", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
    }

    private func setVisible(_ item: QuickParameter, enabled: Bool) {
        var selected = visibleSet
        if enabled { selected.insert(item.rawValue) }
        else { selected.remove(item.rawValue) }
        visibleParameters = orderedItems.filter { selected.contains($0.rawValue) }
            .map(\.rawValue).joined(separator: ",")
    }

    private func move(_ item: QuickParameter, offset: Int) {
        var items = orderedItems
        guard let index = items.firstIndex(of: item) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
        parameterOrder = items.map(\.rawValue).joined(separator: ",")
    }
}
