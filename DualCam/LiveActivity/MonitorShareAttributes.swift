import ActivityKit
import Foundation

/// Persistent activity kept in the background when sharing continues outside the camera screen.
struct MonitorShareAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var resolution: String
        var targetFPS: Int
    }

    var deviceName: String
    var startedAt: Date
}

/// Short-lived foreground activity that asks iOS to expand the Dynamic Island while DualCam
/// remains on the camera screen. A separate type lets the persistent activity keep its older UI.
struct MonitorForegroundShareAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var resolution: String
        var targetFPS: Int
    }

    var deviceName: String
    var startedAt: Date
}
