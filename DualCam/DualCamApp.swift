import SwiftUI

@main
struct DualCamApp: App {
    @StateObject private var camera = CameraManager()

    var body: some Scene {
        WindowGroup {
            CameraHomeScreen()
                .environmentObject(camera)
                .preferredColorScheme(.dark)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
