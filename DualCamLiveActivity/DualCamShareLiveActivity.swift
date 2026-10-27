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
            // Lock Screen / banner presentation.
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)

                VStack(alignment: .leading, spacing: 3) {
                    Text("DualCam 正在共享")
                        .font(.headline)
                    Text("双摄画面传输中")
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
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text("REC")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(.red)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DualCam 正在共享")
                            .font(.headline)
                        Text("双摄画面传输中")
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
                    Label(
                        "双摄合成 · \(context.state.resolution) · \(context.state.targetFPS) fps",
                        systemImage: "video.fill"
                    )
                    .font(.caption)
                }
            } compactLeading: {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
            } minimal: {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }
            .keylineTint(.red)
        }
    }
}
