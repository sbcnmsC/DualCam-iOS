import ActivityKit
import Foundation
import UIKit

@MainActor
final class MonitorLiveActivityManager {
    static let shared = MonitorLiveActivityManager()
    private var currentActivity: Activity<MonitorShareAttributes>?

    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        Task {
            // Avoid duplicate Dynamic Island indicators after a previous interrupted session.
            for activity in Activity<MonitorShareAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            let attributes = MonitorShareAttributes(
                deviceName: UIDevice.current.name,
                startedAt: Date()
            )
            let state = MonitorShareAttributes.ContentState(
                status: "正在共享",
                resolution: "最高 1440p",
                targetFPS: 60
            )
            do {
                currentActivity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
            } catch {
                // The in-app sharing indicator remains available if Live Activities are disabled.
                currentActivity = nil
            }
        }
    }

    func stop() {
        Task {
            for activity in Activity<MonitorShareAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            currentActivity = nil
        }
    }
}
