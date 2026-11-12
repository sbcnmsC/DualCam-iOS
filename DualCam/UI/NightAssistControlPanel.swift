import SwiftUI

/// Independent hardware/screen illumination controls; image enhancement remains a separate filter.
struct NightAssistControlPanel: View {
    @Binding var rearTorchEnabled: Bool
    @Binding var screenFillEnabled: Bool
    @Binding var screenFillIntensity: Double
    @Binding var rearTorchLevel: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("辅助补光")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Toggle(isOn: $rearTorchEnabled) {
                Label("后置 LED 持续补光", systemImage: "flashlight.on.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .tint(.green)

            if rearTorchEnabled {
                HStack {
                    Text("LED 亮度")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                    Slider(value: $rearTorchLevel, in: 0.15...1.0)
                        .tint(.green)
                }
            }

            Divider().overlay(Color.white.opacity(0.16))

            Toggle(isOn: $screenFillEnabled) {
                Label("前置屏幕环形补光", systemImage: "sun.max.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .tint(.green)

            if screenFillEnabled {
                HStack {
                    Text("屏幕亮度")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                    Slider(value: $screenFillIntensity, in: 0.55...1.0)
                        .tint(.white)
                }
            }

            Text("此处仅控制 LED 和屏幕补光，不是 iPhone 原生相机的 Night mode。iOS 未向第三方 App 开放系统相机夜间模式的直接控制接口。")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 248)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}
