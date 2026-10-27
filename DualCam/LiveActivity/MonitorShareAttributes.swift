import ActivityKit
import Foundation

struct MonitorShareAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String
        var resolution: String
        var targetFPS: Int
    }

    var deviceName: String
    var startedAt: Date
}
