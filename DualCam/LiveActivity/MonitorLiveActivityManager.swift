import ActivityKit
import Foundation
import OSLog
import UIKit

/// Coordinates the foreground recording-style Dynamic Island activity and the persistent
/// legacy-style activity that remains when sharing continues outside the camera screen.
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
    private var foregroundActivityWatchTask: Task<Void, Never>?
    private var isSharing = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSharing, self.foregroundActivity == nil else { return }
                guard #available(iOS 18.0, *) else { return }
                if let failure = self.requestForegroundActivity(
                    deviceName: UIDevice.current.name,
                    startedAt: Date()
                ) {
                    self.logger.error("Could not re-present foreground activity: \(failure, privacy: .public)")
                }
            }
        }
    }

    /// Create the persistent activity first, then request the transient foreground style.
    /// There is no awaited cleanup before the transient request.
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

        isSharing = true
        let oldPersistentActivities = Activity<MonitorShareAttributes>.activities
        let oldForegroundActivities = Activity<MonitorForegroundShareAttributes>.activities
        let now = Date()
        let deviceName = UIDevice.current.name
        var failures: [String] = []

        // Background/exit fallback: standard style with the older green, non-recording UI.
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
            failures.append("后台普通共享状态启动失败：\(message)")
            logger.error("Persistent Live Activity request failed: \(message, privacy: .public)")
        }

        if #available(iOS 18.0, *) {
            if let failure = requestForegroundActivity(deviceName: deviceName, startedAt: now) {
                failures.append("前台录制式灵动岛启动失败：\(failure)")
            }
        } else {
            failures.append("前台录制式灵动岛需要 iOS 18 或更新版本；后台普通共享状态仍可使用")
        }

        guard token == lifecycleToken else {
            await endActivities(for: token)
            return nil
        }

        // Remove older activities after both new requests have been attempted.
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

    @available(iOS 18.0, *)
    @discardableResult
    private func requestForegroundActivity(deviceName: String, startedAt: Date) -> String? {
        guard isSharing else { return nil }
        do {
            let foreground = try Activity.request(
                attributes: MonitorForegroundShareAttributes(deviceName: deviceName, startedAt: startedAt),
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
            watchForegroundActivity(foreground)
            return nil
        } catch {
            let message = error.localizedDescription
            logger.error("Foreground transient Live Activity request failed: \(message, privacy: .public)")
            return message
        }
    }

    /// Transient activities automatically end when the user interacts outside the Island.
    /// If sharing continues and the app remains foregrounded, request the foreground activity
    /// again. If the user leaves the app, do not restart it; the standard activity remains.
    private func watchForegroundActivity(_ activity: Activity<MonitorForegroundShareAttributes>) {
        foregroundActivityWatchTask?.cancel()
        foregroundActivityWatchTask = Task { @MainActor [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self else { return }
                guard self.isSharing, self.foregroundActivity?.id == activity.id else { return }
                guard state == .ended || state == .dismissed else { continue }

                self.foregroundActivity = nil
                guard UIApplication.shared.applicationState == .active else { return }
                guard #available(iOS 18.0, *) else { return }
                if let failure = self.requestForegroundActivity(
                    deviceName: UIDevice.current.name,
                    startedAt: Date()
                ) {
                    self.logger.error("Foreground activity restart failed: \(failure, privacy: .public)")
                }
                return
            }
        }
    }

    func stop() async {
        lifecycleToken &+= 1
        let token = lifecycleToken
        isSharing = false
        foregroundActivityWatchTask?.cancel()
        foregroundActivityWatchTask = nil
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
