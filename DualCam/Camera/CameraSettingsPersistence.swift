import Foundation

/// Versioned, on-device storage for the user's camera preferences.
/// Transient activity (recording, countdowns, wireless sessions) is deliberately excluded.
enum CameraSettingsPersistence {
    struct Snapshot: Codable {
        let version: Int
        var config: Config
        var slotStates: [SlotState]
        var flashEnabled: Bool
        var timerSeconds: Int
        var paramTarget: Int
    }

    private static let key = "dualcam.cameraSettings.snapshot"
    static let launchSettings: Snapshot? = load()

    static func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else {
            return nil
        }
        return snapshot
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
