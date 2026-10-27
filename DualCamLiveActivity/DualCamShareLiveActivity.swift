import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DualCamLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DualCamShareLiveActivity()
    }
}

struct DualCamShareLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MonitorShareAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DualCam 正在共享").font(.headline)
                    Text(context.attributes.deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
            .activityBackgroundTint(Color.black.opacity(0.9))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DualCam 正在共享").font(.headline)
                        Text(context.attributes.deviceName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Label("合成画面 · 最高 1440p / 60 fps*", systemImage: "video.fill")
                        Text("*实际帧率取决于摄像头帧率、网络和设备负载")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }
}
