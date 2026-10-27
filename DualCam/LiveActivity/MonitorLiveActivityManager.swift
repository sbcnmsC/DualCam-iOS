import ActivityKit
import Foundation
import OSLog
import UIKit

/// Coordinates two distinct system-owned activities:
/// 1) a transient foreground "REC" Dynamic Island presentation,
/// 2) the older standard Live Activity that remains after leaving the camera screen.
@MainActor
final class MonitorLiveActivityManager {
    static let shared = MonitorLiveActivityManager()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dualcam.app",
        category: "MonitorLiveActivity"
    )

    private var lifecycleToken: UInt64 = 0
    private var persistentActivity: Activity<MonitorShareAttributes>?
    private var foregroundActivity: Activity<MonitorForegroundShareAttributes>?

    /// Start the standard persistent activity and then request a transient foreground activity.
    /// Both requests happen before any awaited cleanup so the transient request is made promptly.
    func start() async -> String? {
        lifecycleToken &+= 1
        let token = lifecycleToken

        guard (Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool) == true else {
            logger.error("NSSupportsLiveActivities is missing or false in the installed app bundle.")
            return "当前安装包未启用实时活动，请检查安装包配置"
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.error("Live Activities are disabled by system/user settings.")
            return "iOS 未允许实时活动；请检查设置中的实时活动开关"
        }

        let oldPersistentActivities = Activity<MonitorShareAttributes>.activities
        let oldForegroundActivities = Activity<MonitorForegroundShareAttributes>.activities
        let now = Date()
        let deviceName = UIDevice.current.name
        var failures: [String] = []

        // First create the standard activity. This is the non-recording-style fallback that
        // persists when the foreground transient activity ends on app exit.
        do {
            let persistent = try Activity.request(
                attributes: MonitorShareAttributes(deviceName: deviceName, startedAt: now),
                content: ActivityContent(
                    state: MonitorShareAttributes.ContentState(
                        status: "正在共享",
                        resolution: "1080p",
                        targetFPS: 60
                    ),
                    staleDate: nil,
                    relevanceScore: 70
                ),
                pushType: nil
            )
            persistentActivity = persistent
            logger.info("Persistent Live Activity accepted. id=\(persistent.id, privacy: .public)")
        } catch {
            let message = error.localizedDescription
            failures.append("后台共享状态启动失败：\(message)")
            logger.error("Persistent Live Activity request failed: \(message, privacy: .public)")
        }

        // The transient activity is the foreground design. On iOS 18+, it expands in the real
        // Dynamic Island and automatically ends when the user leaves the app.
        if #available(iOS 18.0, *) {
            do {
                let foreground = try Activity.request(
                    attributes: MonitorForegroundShareAttributes(deviceName: deviceName, startedAt: now),
                    content: ActivityContent(
                        state: MonitorForegroundShareAttributes.ContentState(
                            status: "正在共享",
                            resolution: "1080p",
                            targetFPS: 60
                        ),
                        staleDate: nil,
                        relevanceScore: 100
                    ),
                    pushType: nil,
                    style: .transient
                )
                foregroundActivity = foreground
                logger.info("Foreground transient Live Activity accepted. id=\(foreground.id, privacy: .public)")
            } catch {
                let message = error.localizedDescription
                failures.append("前台录制式灵动岛启动失败：\(message)")
                logger.error("Foreground transient Live Activity request failed: \(message, privacy: .public)")
            }
        } else {
            failures.append("前台录制式灵动岛需要 iOS 18 或更新版本；后台普通共享状态仍可使用")
        }

        guard token == lifecycleToken else {
            await endActivities(for: token)
            return nil
        }

        // Remove old activities only after both new requests have been attempted.
        let persistentID = persistentActivity?.id
        let foregroundID = foregroundActivity?.id
        Task { @MainActor in
            for activity in oldPersistentActivities where activity.id != persistentID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            for activity in oldForegroundActivities where activity.id != foregroundID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        return failures.isEmpty ? nil : failures.joined(separator: "；")
    }

    func stop() async {
        lifecycleToken &+= 1
        let token = lifecycleToken
        persistentActivity = nil
        foregroundActivity = nil
        await endActivities(for: token)
    }

    private func endActivities(for token: UInt64) async {
        for activity in Activity<MonitorForegroundShareAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            guard token == lifecycleToken else { return }
        }
        for activity in Activity<MonitorShareAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            guard token == lifecycleToken else { return }
        }
        if token == lifecycleToken {
            persistentActivity = nil
            foregroundActivity = nil
            logger.info("Both foreground and persistent Live Activities ended for monitor share.")
        }
    }
}
