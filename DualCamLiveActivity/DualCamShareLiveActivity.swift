import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DualCamLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DualCamShareLiveActivity()
        DualCamForegroundShareLiveActivity()
    }
}

/// Persistent, non-recording-style activity shown after the user leaves DualCam.
/// This retains the older presentation rather than reusing the foreground REC design.
struct DualCamShareLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MonitorShareAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 3) {
                    Text("DualCam \(context.state.status)")
                        .font(.headline)
                    Text(context.attributes.deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

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
                        Text("DualCam \(context.state.status)")
                            .font(.headline)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "合成画面 · \(context.state.resolution) / \(context.state.targetFPS) fps",
                            systemImage: "video.fill"
                        )
                        .font(.caption)
                        Text("实际帧率取决于摄像头、网络和设备负载")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
