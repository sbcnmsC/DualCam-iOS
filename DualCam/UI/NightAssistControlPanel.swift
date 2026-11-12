import SwiftUI

/// Independent hardware/screen illumination controls; image enhancement remains a separate filter.
struct NightAssistControlPanel: View {
    @Binding var rearTorchEnabled: Bool
    @Binding var screenFillEnabled: Bool
    @Binding var screenFillIntensity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("夜间补光")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Toggle(isOn: $rearTorchEnabled) {
                Label("后置 LED 持续补光", systemImage: "flashlight.on.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .tint(.green)

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

            Text("补光是可见光照明；夜视增强滤镜仍需环境中存在可见光。")
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
