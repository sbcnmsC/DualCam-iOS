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

        switch snapshot.version {
        case 1:
            // Repair the legacy width once while preserving every other preference.
            snapshot.config.pipWidth = 0.32
            snapshot.version = 2
            fallthrough
        case 2:
            // Version 2 may already contain a bad width/center written by an earlier
            // preview build. Repair only invalid/out-of-range PiP values; retain valid
            // user-customized geometry and all unrelated camera settings.
            repairPiPValues(in: &snapshot.config)
            snapshot.version = 3
            save(snapshot)
            return snapshot
        case 3:
            return snapshot
        default:
            return nil
        }
    }

    private static func repairPiPValues(in config: inout Config) {
        if !config.pipWidth.isFinite || config.pipWidth < 0.16 || config.pipWidth > 0.9 {
            config.pipWidth = 0.32
        }

        if !config.pipCenter.x.isFinite || !config.pipCenter.y.isFinite {
            config.pipCenter = CGPoint(x: 0.76, y: 0.20)
        } else {
            config.pipCenter = CGPoint(
                x: min(max(config.pipCenter.x, 0), 1),
                y: min(max(config.pipCenter.y, 0), 1)
            )
        }
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
