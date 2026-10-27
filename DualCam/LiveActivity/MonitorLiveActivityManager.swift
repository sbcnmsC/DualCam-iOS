import ActivityKit
import Foundation
import OSLog
import UIKit

/// Owns the ActivityKit lifecycle for the local share session.
@MainActor
final class MonitorLiveActivityManager {
    static let shared = MonitorLiveActivityManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dualcam.app", category: "MonitorLiveActivity")

    private var lifecycleToken: UInt64 = 0
    private var currentActivity: Activity<MonitorShareAttributes>?

    /// Call from a single MainActor task when local sharing begins.
    /// The token changes before the first suspension point, so a queued stop
    /// invalidates this request rather than allowing a stale activity to reappear.
    /// Returns nil only when ActivityKit accepted the request; failures are surfaced to the
    /// app UI instead of leaving an in-app badge to masquerade as a system Live Activity.
    func start() async -> String? {
        lifecycleToken &+= 1
        let token = lifecycleToken
        return await createActivity(for: token)
    }

    /// Ends every activity belonging to this app's monitor-share type.
    func stop() async {
        lifecycleToken &+= 1
        let token = lifecycleToken
        currentActivity = nil
        await endActivities(for: token)
    }

    private func createActivity(for token: UInt64) async -> String? {
        for activity in Activity<MonitorShareAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            guard token == lifecycleToken else { return nil }
        }

        guard token == lifecycleToken else { return nil }
        guard (Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool) == true else {
            logger.error("NSSupportsLiveActivities is missing or false in the installed app bundle.")
            currentActivity = nil
            return "当前安装包未正确启用实时活动，请重新安装 Build 5"
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.error("Live Activities are disabled by system/user settings; cannot show Dynamic Island share status.")
            currentActivity = nil
            return "iOS 未允许实时活动；请检查设置中的实时活动开关"
        }

        let attributes = MonitorShareAttributes(
            deviceName: UIDevice.current.name,
            startedAt: Date()
        )
        let state = MonitorShareAttributes.ContentState(
            status: "正在共享",
            resolution: "目标 1440p",
            targetFPS: 60
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil, relevanceScore: 100),
                pushType: nil
            )

            guard token == lifecycleToken else {
                await activity.end(nil, dismissalPolicy: .immediate)
                return nil
            }
            currentActivity = activity
            logger.info("Live Activity started successfully. id=\(activity.id, privacy: .public)")
            return nil
        } catch {
            currentActivity = nil
            let message = error.localizedDescription
            logger.error("Live Activity request failed: \(message, privacy: .public)")
            return message
        }
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
