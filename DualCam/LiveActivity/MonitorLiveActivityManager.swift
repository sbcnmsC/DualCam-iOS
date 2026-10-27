import ActivityKit
import Foundation
import OSLog
import UIKit

/// Keeps the recording-style Live Activity in the foreground and the original standard
/// share activity only while the app is inactive/backgrounded.
@MainActor
final class MonitorLiveActivityManager {
    static let shared = MonitorLiveActivityManager()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dualcam.app",
        category: "MonitorLiveActivity"
    )

    private var lifecycleToken: UInt64 = 0
    private var isSharing = false
    private var shareStartedAt: Date?
    private var shareDeviceName = UIDevice.current.name
    private var foregroundActivity: Activity<MonitorForegroundShareAttributes>?
    private var persistentActivity: Activity<MonitorShareAttributes>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.switchToBackgroundPresentation()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.switchToForegroundPresentation()
            }
        }
    }

    /// Starts the foreground-only recording-style Dynamic Island presentation.
    /// The persistent, legacy-style activity is deliberately NOT created here.
    func start() async -> String? {
        lifecycleToken &+= 1
        let token = lifecycleToken

        guard (Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool) == true else {
            logger.error("NSSupportsLiveActivities is missing or false in the installed app bundle.")
            isSharing = false
            return "当前安装包未启用实时活动，请检查安装包配置"
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.error("Live Activities are disabled by system/user settings.")
            isSharing = false
            return "iOS 未允许实时活动；请检查设置中的实时活动开关"
        }

        isSharing = true
        shareStartedAt = Date()
        shareDeviceName = UIDevice.current.name

        let oldPersistentActivities = Activity<MonitorShareAttributes>.activities
        let oldForegroundActivities = Activity<MonitorForegroundShareAttributes>.activities

        var failure: String?
        if #available(iOS 18.0, *) {
            failure = requestForegroundActivity()
        } else {
            // iOS 17 has no transient presentation API; keep the original standard activity.
            failure = requestPersistentActivity()
        }

        guard token == lifecycleToken else {
            await endActivities(for: token)
            return nil
        }

        let keepPersistentID = persistentActivity?.id
        let keepForegroundID = foregroundActivity?.id
        Task { @MainActor in
            for activity in oldForegroundActivities where activity.id != keepForegroundID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            for activity in oldPersistentActivities where activity.id != keepPersistentID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        if let failure {
            logger.error("Initial share activity request failed: \(failure, privacy: .public)")
        }
        return failure
    }

    /// Called synchronously from UIApplication.willResignActiveNotification, while ActivityKit
    /// can still accept a request. Establish the old standard activity before the transient
    /// foreground activity ends automatically as the user leaves the app.
    private func switchToBackgroundPresentation() {
        guard isSharing else { return }

        if persistentActivity == nil {
            if let failure = requestPersistentActivity() {
                logger.error("Could not create background share activity: \(failure, privacy: .public)")
            }
        }

        let leavingForegroundActivity = foregroundActivity
        foregroundActivity = nil
        guard let leavingForegroundActivity else { return }

        Task { @MainActor in
            await leavingForegroundActivity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// On return to DualCam, create the transient recording-style activity first, then remove
    /// the persistent one so the two different presentations never compete for the Island.
    private func switchToForegroundPresentation() {
        guard isSharing else { return }

        if #available(iOS 18.0, *) {
            let existingIsActive = foregroundActivity?.activityState == .active
            if !existingIsActive {
                foregroundActivity = nil
                guard requestForegroundActivity() == nil else {
                    // Leave the standard activity intact as a fallback if ActivityKit refuses
                    // the transient request. Do not claim the recording-style UI is active.
                    return
                }
            }
            let leavingPersistentActivity = persistentActivity
            persistentActivity = nil
            if let leavingPersistentActivity {
                Task { @MainActor in
                    await leavingPersistentActivity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    @available(iOS 18.0, *)
    @discardableResult
    private func requestForegroundActivity() -> String? {
        guard isSharing, let startedAt = shareStartedAt else { return "共享会话已经结束" }
        do {
            let activity = try Activity.request(
                attributes: MonitorForegroundShareAttributes(
                    deviceName: shareDeviceName,
                    startedAt: startedAt
                ),
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
            foregroundActivity = activity
            logger.info("Foreground REC activity requested. id=\(activity.id, privacy: .public)")
            return nil
        } catch {
            let message = error.localizedDescription
            logger.error("Foreground REC activity request failed: \(message, privacy: .public)")
            return message
        }
    }

    @discardableResult
    private func requestPersistentActivity() -> String? {
        guard isSharing, let startedAt = shareStartedAt else { return "共享会话已经结束" }
        guard persistentActivity == nil else { return nil }

        do {
            let activity = try Activity.request(
                attributes: MonitorShareAttributes(
                    deviceName: shareDeviceName,
                    startedAt: startedAt
                ),
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
            persistentActivity = activity
            logger.info("Standard background share activity requested. id=\(activity.id, privacy: .public)")
            return nil
        } catch {
            let message = error.localizedDescription
            logger.error("Standard share activity request failed: \(message, privacy: .public)")
            return message
        }
    }

    func stop() async {
        lifecycleToken &+= 1
        let token = lifecycleToken
        isSharing = false
        shareStartedAt = nil
        foregroundActivity = nil
        persistentActivity = nil
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
            foregroundActivity = nil
            persistentActivity = nil
            logger.info("All share activities ended.")
        }
    }
}
