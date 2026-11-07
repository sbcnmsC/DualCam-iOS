import Foundation

/// Versioned, on-device storage for the user's camera preferences.
/// Transient activity (recording, countdowns, wireless sessions) is deliberately excluded.
enum CameraSettingsPersistence {
    struct Snapshot: Codable {
        var version: Int
        var config: Config
        var slotStates: [SlotState]
        var flashEnabled: Bool
        var timerSeconds: Int
        var paramTarget: Int
        var selectedComboTitle: String?
    }

    private static let key = "dualcam.cameraSettings.snapshot"
    static let launchSettings: Snapshot? = load()

    static func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }

        var didMigrate = false
        switch snapshot.version {
        case 1:
            // Version 1 could contain the invalid PiP dimensions seen in early builds.
            snapshot.config.pipWidth = 0.32
            didMigrate = true
        case 2, 3:
            break
        default:
            return nil
        }

        // Sanitize corrupted values once, without resetting valid user-customized size/position.
        let width = snapshot.config.pipWidth
        if !width.isFinite || width < 0.16 || width > 0.90 {
            snapshot.config.pipWidth = 0.32
            didMigrate = true
        }

        let center = snapshot.config.pipCenter
        if !center.x.isFinite || !center.y.isFinite {
            snapshot.config.pipCenter = CGPoint(x: 0.76, y: 0.20)
            didMigrate = true
        } else {
            let clamped = CGPoint(
                x: min(max(center.x, 0), 1),
                y: min(max(center.y, 0), 1)
            )
            if clamped != center {
                snapshot.config.pipCenter = clamped
                didMigrate = true
            }
        }

        if snapshot.version != 3 {
            snapshot.version = 3
            didMigrate = true
        }
        if didMigrate { save(snapshot) }
        return snapshot
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
