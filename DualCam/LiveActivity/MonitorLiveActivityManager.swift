import ActivityKit
import Foundation
import UIKit

/// Owns the complete ActivityKit lifecycle for the local share session.
/// Lifecycle tokens prevent an older asynchronous start from resurrecting
/// the Dynamic Island after the user has already stopped sharing.
@MainActor
final class MonitorLiveActivityManager {
    static let shared = MonitorLiveActivityManager()

    private var lifecycleToken: UInt64 = 0
    private var currentActivity: Activity<MonitorShareAttributes>?

    /// Call on the main actor when the local device begins sharing.
    /// The public method changes the token synchronously so a rapid stop
    /// invalidates this start before any asynchronous cleanup can finish.
    func start() {
        lifecycleToken &+= 1
        let token = lifecycleToken
        Task { @MainActor in
            await createActivity(for: token)
        }
    }

    /// Call on the main actor for every local-share stop/disconnect path.
    func stop() {
        lifecycleToken &+= 1
        let token = lifecycleToken
        currentActivity = nil
        Task { @MainActor in
            await endActivities(for: token)
        }
    }

    private func createActivity(for token: UInt64) async {
        // Remove stale activities from an interrupted prior session first.
        for activity in Activity<MonitorShareAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            guard token == lifecycleToken else { return }
        }

        guard token == lifecycleToken else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
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
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )

            // Activity.request is synchronous, but retain this guard so a
            // future implementation that suspends here stays lifecycle-safe.
            guard token == lifecycleToken else {
                await activity.end(nil, dismissalPolicy: .immediate)
                return
            }
            currentActivity = activity
        } catch {
            // The camera sharing session still works when Live Activities
            // are disabled or ActivityKit rejects the request.
            currentActivity = nil
        }
    }

    private func endActivities(for token: UInt64) async {
        for activity in Activity<MonitorShareAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            guard token == lifecycleToken else { return }
        }
        if token == lifecycleToken {
            currentActivity = nil
        }
    }
}
