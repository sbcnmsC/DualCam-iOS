import ActivityKit
import Foundation
import OSLog
import UIKit

/// Starts the system-owned Dynamic Island activity immediately when wireless sharing begins.
@MainActor
final class MonitorLiveActivityManager {
    static let shared = MonitorLiveActivityManager()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dualcam.app",
        category: "MonitorLiveActivity"
    )

    private var lifecycleToken: UInt64 = 0
    private var currentActivity: Activity<MonitorShareAttributes>?

    /// Requests a foreground Live Activity before any asynchronous cleanup work.
    /// There is deliberately no await before Activity.request on iOS 18+.
    func start() async -> String? {
        lifecycleToken &+= 1
        let token = lifecycleToken

        guard (Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool) == true else {
            logger.error("NSSupportsLiveActivities is missing or false in the installed app bundle.")
            return "当前安装包未启用实时活动，请确认安装的是 Build 7"
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.error("Live Activities are disabled by system/user settings.")
            return "iOS 未允许实时活动；请检查设置中的实时活动开关"
        }

        // Snapshot stale activities now, but do not await ending them before the new request.
        let oldActivities = Activity<MonitorShareAttributes>.activities
        let attributes = MonitorShareAttributes(
            deviceName: UIDevice.current.name,
            startedAt: Date()
        )
        let state = MonitorShareAttributes.ContentState(
            status: "正在共享",
            resolution: "1080p",
            targetFPS: 60
        )

        do {
            let activity: Activity<MonitorShareAttributes>
            if #available(iOS 18.0, *) {
                // Apple documents .transient as the foreground, expanded Dynamic Island style.
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil, relevanceScore: 100),
                    pushType: nil,
                    style: .transient
                )
            } else {
                // Older system fallback; it cannot guarantee the foreground expanded presentation.
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil, relevanceScore: 100),
                    pushType: nil
                )
            }

            guard token == lifecycleToken else {
                Task { @MainActor in
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                return nil
            }

            currentActivity = activity
            logger.info("Foreground Live Activity request accepted. id=\(activity.id, privacy: .public)")

            // Remove stale activities only after the foreground transient request has been accepted.
            Task { @MainActor in
                for old in oldActivities where old.id != activity.id {
                    await old.end(nil, dismissalPolicy: .immediate)
                }
            }
            return nil
        } catch {
            let message = error.localizedDescription
            logger.error("Live Activity request failed: \(message, privacy: .public)")
            return message
        }
    }

    func stop() async {
        lifecycleToken &+= 1
        let token = lifecycleToken
        currentActivity = nil
        await endActivities(for: token)
    }

    private func endActivities(for token: UInt64) async {
        for activity in Activity<MonitorShareAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            guard token == lifecycleToken else { return }
        }
        if token == lifecycleToken {
            currentActivity = nil
            logger.info("Live Activity ended for monitor share.")
        }
    }
}
