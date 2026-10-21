import SwiftUI

struct ToolPanel: View {
    @Binding var tab: PanelTab

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) {
                ForEach(PanelTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView {
                Group {
                    switch tab {
                    case .pip: PiPTab()
                    case .filter: FilterTab()
                    case .params: ParamsTab()
                    case .settings: SettingsTab()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .frame(height: 230)
        }
        .foregroundStyle(Color.white)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String
    var disabled = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range)
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
    @State private var group: FilterGroup = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(FilterGroup.allCases) { item in
                        let selected = group == item
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                group = item
                                if !item.filters.contains(cam.cfg.filter) {
                                    cam.cfg.filter = item.filters.first(where: { $0 != .original }) ?? .original
                                }
                            }
                        } label: {
                            Text(item.rawValue)
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(Capsule().fill(selected ? Color.yellow : Color.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.filters) { kind in
                        cell(kind)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(cam.cfg.filter.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                    Text(cam.cfg.filter.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text("\(Int(cam.cfg.filterIntensity * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.8))
            }

            LabeledSlider(title: "强度",
                          value: Binding(get: { Double(cam.cfg.filterIntensity) },
                                         set: { cam.cfg.filterIntensity = CGFloat($0) }),
                          range: 0...1,
                          valueText: "\(Int(cam.cfg.filterIntensity * 100))%",
                          disabled: cam.cfg.filter == .original)
        }
        .onAppear { cam.thumbsActive = true }
        .onDisappear { cam.thumbsActive = false }
    }

    private func cell(_ kind: FilterKind) -> some View {
        let selected = cam.cfg.filter == kind
        return Button {
            cam.cfg.filter = kind
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

private enum ParameterSection: String, CaseIterable, Identifiable {
    case lens = "镜头"
    case exposure = "曝光"
    case color = "色彩"
    case focus = "对焦"
    var id: String { rawValue }
}

struct ParamsTab: View {
    @EnvironmentObject private var cam: CameraManager
    @State private var section: ParameterSection = .exposure

    var body: some View {
        let i = min(max(cam.paramTarget, 0), 1)
        let info = cam.slotInfos[i]
        let st = cam.slotStates[i]
        let base = max(info.baseMultiplier, 0.01)
        let maxZoom = max(base * info.maxZoom, base + 0.01)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "camera.aperture")
                    .foregroundStyle(Color.yellow)
                Text("控制镜头")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("独立参数")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            Picker("镜头", selection: $cam.paramTarget) {
                Text(cam.slotInfos[0].name).tag(0)
                Text(cam.slotInfos[1].name).tag(1)
            }
            .pickerStyle(.segmented)

            ParameterChart(
                zoom: Double(cam.displayZoom(slot: i)),
                maxZoom: Double(maxZoom),
                exposureBias: Double(st.exposureBias),
                minBias: Double(info.minBias),
                maxBias: Double(info.maxBias),
                iso: Double(st.iso),
                minISO: Double(info.minISO),
                maxISO: Double(info.maxISO),
                shutterLabel: shutterText(info: info, t: st.shutter),
                temperature: Double(st.temperature),
                tint: Double(st.tint),
                focus: Double(st.lensPosition),
                manualExposure: st.manualExposure,
                manualWB: st.manualWB,
                manualFocus: st.manualFocus
            )

            Picker("参数分类", selection: $section) {
                ForEach(ParameterSection.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                switch section {
                case .lens:
                    sectionHeading("镜头与变焦", subtitle: "控制当前镜头的视角")
                    LabeledSlider(
                        title: "变焦",
                        value: Binding(
                            get: { Double(cam.displayZoom(slot: i)) },
                            set: { cam.setZoom(slot: i, factor: CGFloat($0) / base) }
                        ),
                        range: Double(base)...Double(maxZoom),
                        valueText: String(format: "%.1f×", Double(cam.displayZoom(slot: i)))
                    )

                case .exposure:
                    sectionHeading("明暗与快门", subtitle: "自动曝光与手动曝光二选一")
                    LabeledSlider(
                        title: "曝光补偿",
                        value: dbl(i, \.exposureBias) { cam.applyExposure($0) },
                        range: Double(info.minBias)...Double(max(info.maxBias, info.minBias + 0.1)),
                        valueText: String(format: "%+.1f EV", Double(st.exposureBias)),
                        disabled: st.manualExposure || st.locked
                    )
                    Toggle("手动 ISO / 快门", isOn: flag(i, \.manualExposure) { cam.applyExposure($0) })
                        .font(.system(size: 12))
                    if st.manualExposure {
                        LabeledSlider(
                            title: "ISO",
                            value: dbl(i, \.iso) { cam.applyExposure($0) },
                            range: Double(info.minISO)...Double(max(info.maxISO, info.minISO + 1)),
                            valueText: "\(Int(st.iso))"
                        )
                        LabeledSlider(
                            title: "快门",
                            value: dbl(i, \.shutter) { cam.applyExposure($0) },
                            range: 0...1,
                            valueText: shutterText(info: info, t: st.shutter)
                        )
                    }

                case .color:
                    sectionHeading("白平衡", subtitle: "调整画面的冷暖与色偏")
                    Toggle("手动白平衡", isOn: flag(i, \.manualWB) { cam.applyWhiteBalance($0) })
                        .font(.system(size: 12))
                    if st.manualWB {
                        LabeledSlider(
                            title: "色温",
                            value: dbl(i, \.temperature) { cam.applyWhiteBalance($0) },
                            range: 2500...9000,
                            valueText: "\(Int(st.temperature))K"
                        )
                        LabeledSlider(
                            title: "色调",
                            value: dbl(i, \.tint) { cam.applyWhiteBalance($0) },
                            range: -150...150,
                            valueText: "\(Int(st.tint))"
                        )
                    }

                case .focus:
                    sectionHeading("焦点与锁定", subtitle: "精确对焦，避免自动参数变化")
                    Toggle("手动对焦", isOn: flag(i, \.manualFocus) { cam.applyFocus($0) })
                        .font(.system(size: 12))
                        .disabled(!info.supportsManualFocus)
                        .opacity(info.supportsManualFocus ? 1 : 0.4)
                    if st.manualFocus {
                        LabeledSlider(
                            title: "对焦距离",
                            value: dbl(i, \.lensPosition) { cam.applyFocus($0) },
                            range: 0...1,
                            valueText: String(format: "%.2f", Double(st.lensPosition))
                        )
                        .disabled(!info.supportsManualFocus)
                    }
                    Toggle("锁定对焦 / 曝光", isOn: Binding(
                        get: { cam.slotStates[i].locked },
                        set: { newValue in
                            if cam.slotStates[i].locked != newValue { cam.toggleLock(i) }
                        }
                    ))
                    .font(.system(size: 12))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.20)))
        }
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.55))
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

/// At-a-glance parameter chart in two columns to keep controls visible in the compact panel.
private struct ParameterChart: View {
    let zoom: Double
    let maxZoom: Double
    let exposureBias: Double
    let minBias: Double
    let maxBias: Double
    let iso: Double
    let minISO: Double
    let maxISO: Double
    let shutterLabel: String
    let temperature: Double
    let tint: Double
    let focus: Double
    let manualExposure: Bool
    let manualWB: Bool
    let manualFocus: Bool

    private var rows: [(String, String, Double)] {
        [
            ("变焦", String(format: "%.1f×", zoom), normalize(zoom, 1, maxZoom)),
            ("曝光", String(format: "%+.1f EV", exposureBias), normalize(exposureBias, minBias, maxBias)),
            ("ISO", manualExposure ? String(Int(iso)) : "自动", manualExposure ? normalize(iso, minISO, maxISO) : 0.45),
            ("快门", manualExposure ? shutterLabel : "自动", manualExposure ? 0.65 : 0.45),
            ("色温", manualWB ? "\(Int(temperature))K" : "自动", manualWB ? normalize(temperature, 2500, 9000) : 0.45),
            ("色调", manualWB ? String(format: "%+.0f", tint) : "自动", manualWB ? normalize(tint, -150, 150) : 0.45),
            ("对焦", manualFocus ? String(format: "%.2f", focus) : "自动", manualFocus ? min(max(focus, 0), 1) : 0.45)
        ]
    }

    private func normalize(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("参数概览")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Circle().fill(Color.green).frame(width: 5, height: 5)
                Text("当前状态")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      alignment: .leading, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { item in
                    let row = item.element
                    HStack(spacing: 5) {
                        Text(row.0)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .frame(width: 26, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.10))
                                Capsule().fill(Color.yellow.opacity(0.9))
                                    .frame(width: geo.size.width * row.2)
                            }
                        }
                        .frame(height: 4)
                        Text(row.1)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.90))
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                    .frame(height: 12)
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.22)))
    }
}

// MARK: - 设置

struct SettingsTab: View {
    @EnvironmentObject private var cam: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("画幅").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                Picker("", selection: $cam.cfg.aspect) {
                    ForEach(CanvasAspect.allCases) { a in Text(a.rawValue).tag(a) }
                }
                .pickerStyle(.segmented)
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
            Text("最高分辨率不会超过摄像头实际像素；60 帧更吃性能，部分镜头组合会自动退回 30 帧。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.6))

            HStack {
                Text("保存").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                Picker("", selection: $cam.cfg.outputMode) {
                    ForEach(OutputMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                .disabled(cam.isRecording)
            }
            Text("原图直出：每颗镜头各存一份，不合成、不加滤镜、不镜像、不裁切；合成画面是预览里看到的样子。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.6))

            Toggle("实况照片", isOn: $cam.cfg.livePhoto).font(.system(size: 13))
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
            Toggle("视频防抖", isOn: $cam.cfg.stabilization).font(.system(size: 13))
            Toggle("前置镜像", isOn: $cam.cfg.mirrorFront).font(.system(size: 13))
            Toggle("三分参考线", isOn: $cam.cfg.showGrid).font(.system(size: 13))

        }
    }
}
