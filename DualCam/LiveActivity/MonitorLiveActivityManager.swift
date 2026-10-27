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
    func start() async {
        lifecycleToken &+= 1
        let token = lifecycleToken
        await createActivity(for: token)
    }

    /// Ends every activity belonging to this app's monitor-share type.
    func stop() async {
        lifecycleToken &+= 1
        let token = lifecycleToken
        currentActivity = nil
        await endActivities(for: token)
    }

    private func createActivity(for token: UInt64) async {
        for activity in Activity<MonitorShareAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            guard token == lifecycleToken else { return }
        }

        guard token == lifecycleToken else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.error("Live Activities are disabled by system/user settings; cannot show Dynamic Island share status.")
            currentActivity = nil
            return
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
                return
            }
            currentActivity = activity
            logger.info("Live Activity started successfully. id=\(activity.id, privacy: .public)")
        } catch {
            currentActivity = nil
            logger.error("Live Activity request failed: \(String(describing: error), privacy: .public)")
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
