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
            // Repair only the persisted PiP width. Preserve all other camera preferences.
            snapshot.config.pipWidth = 0.32
            snapshot.version = 2
            save(snapshot)
            return snapshot
        case 2:
            return snapshot
        default:
            return nil
        }
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
