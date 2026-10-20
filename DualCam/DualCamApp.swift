import SwiftUI

@main
struct DualCamApp: App {
    @StateObject private var camera = CameraManager()
    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environmentObject(camera)
                .preferredColorScheme(.dark)
        }
    }
}