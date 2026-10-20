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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterKind.allCases) { kind in
                        cell(kind)
                    }
                }
                .padding(.vertical, 2)
            }
            LabeledSlider(title: "强度",
                          value: Binding(get: { Double(cam.cfg.filterIntensity) },
                                         set: { cam.cfg.filterIntensity = CGFloat($0) }),
                          range: 0...1,
                          valueText: "\(Int(cam.cfg.filterIntensity * 100))%",
                          disabled: cam.cfg.filter == .original)
            Text("滤镜作用在合成后的照片 / 视频上，「原片」不加滤镜。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.6))
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
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 62, height: 82)
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
            Picker("", selection: $cam.paramTarget) {
                Text(cam.slotInfos[0].name).tag(0)
                Text(cam.slotInfos[1].name).tag(1)
            }
            .pickerStyle(.segmented)

            LabeledSlider(title: "变焦",
                          value: Binding(
                            get: { Double(cam.displayZoom(slot: i)) },
                            set: { cam.setZoom(slot: i, factor: CGFloat($0) / base) }),
                          range: Double(base)...Double(max(base * info.maxZoom, base + 0.01)),
                          valueText: String(format: "%.1f×", Double(cam.displayZoom(slot: i))))

            LabeledSlider(title: "曝光补偿",
                          value: dbl(i, \.exposureBias) { cam.applyExposure($0) },
                          range: Double(info.minBias)...Double(max(info.maxBias, info.minBias + 0.1)),
                          valueText: String(format: "%+.1f EV", Double(st.exposureBias)),
                          disabled: st.manualExposure || st.locked)

            Toggle("手动 ISO / 快门", isOn: flag(i, \.manualExposure) { cam.applyExposure($0) })
                .font(.system(size: 13))
            if st.manualExposure {
                LabeledSlider(title: "ISO",
                              value: dbl(i, \.iso) { cam.applyExposure($0) },
                              range: Double(info.minISO)...Double(max(info.maxISO, info.minISO + 1)),
                              valueText: "\(Int(st.iso))")
                LabeledSlider(title: "快门",
                              value: dbl(i, \.shutter) { cam.applyExposure($0) },
                              range: 0...1,
                              valueText: shutterText(info: info, t: st.shutter))
            }

            Toggle("手动白平衡", isOn: flag(i, \.manualWB) { cam.applyWhiteBalance($0) })
                .font(.system(size: 13))
            if st.manualWB {
                LabeledSlider(title: "色温",
                              value: dbl(i, \.temperature) { cam.applyWhiteBalance($0) },
                              range: 2500...9000,
                              valueText: "\(Int(st.temperature))K")
                LabeledSlider(title: "色调",
                              value: dbl(i, \.tint) { cam.applyWhiteBalance($0) },
                              range: -150...150,
                              valueText: "\(Int(st.tint))")
            }

            Toggle("手动对焦", isOn: flag(i, \.manualFocus) { cam.applyFocus($0) })
                .font(.system(size: 13))
                .disabled(!info.supportsManualFocus)
                .opacity(info.supportsManualFocus ? 1 : 0.4)
            if st.manualFocus {
                LabeledSlider(title: "对焦距离",
                              value: dbl(i, \.lensPosition) { cam.applyFocus($0) },
                              range: 0...1,
                              valueText: String(format: "%.2f", Double(st.lensPosition)))
            }

            Toggle("锁定对焦 / 曝光", isOn: Binding(
                get: { cam.slotStates[i].locked },
                set: { newValue in
                    if cam.slotStates[i].locked != newValue { cam.toggleLock(i) }
                }))
                .font(.system(size: 13))
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

            Toggle("保存两路原片", isOn: $cam.cfg.saveRaw).font(.system(size: 13))
            Toggle("弱光增亮", isOn: $cam.cfg.lowLight).font(.system(size: 13))
            Toggle("视频防抖", isOn: $cam.cfg.stabilization).font(.system(size: 13))
            Toggle("前置镜像", isOn: $cam.cfg.mirrorFront).font(.system(size: 13))
            Toggle("三分参考线", isOn: $cam.cfg.showGrid).font(.system(size: 13))

            Text("实况照片与视频转实况暂未实现。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }
}
