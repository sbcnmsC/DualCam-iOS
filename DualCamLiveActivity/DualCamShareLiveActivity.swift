import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DualCamLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DualCamShareLiveActivity()
        DualCamForegroundShareLiveActivity()
    }
}

struct DualCamShareLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MonitorShareAttributes.self) { context in
            // Lock Screen / banner presentation.
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
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            "合成画面 · \(context.state.resolution) / \(context.state.targetFPS) fps",
                            systemImage: "video.fill"
                        )
                        .font(.caption)

                        HStack {
                            Text("无线共享仍在运行")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button(intent: StopWirelessShareIntent()) {
                                Label("关闭共享", systemImage: "stop.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .accessibilityLabel("关闭无线共享")
                        }
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
