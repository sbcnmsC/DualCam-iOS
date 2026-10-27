import ActivityKit
import AppIntents

/// The expanded background Live Activity exposes a real stop action. LiveActivityIntent runs
/// in the app process, allowing the existing WirelessMonitorSession to stop WebRTC and notify
/// the paired device instead of merely hiding this status widget.
struct StopWirelessShareIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "关闭共享"
    static var description = IntentDescription("停止 DualCam 无线画面共享并关闭共享状态。")

    func perform() async throws -> some IntentResult {
        #if DUALCAM_WIDGET_EXTENSION
        // The intent is dispatched to the app process by ActivityKit. This extension-side
        // fallback only clears displayed activities if this source is ever run in the extension.
        for activity in Activity<MonitorForegroundShareAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        for activity in Activity<MonitorShareAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #else
        await WirelessMonitorSession.shared.stopFromLiveActivity()
        #endif
        return .result()
    }
}
