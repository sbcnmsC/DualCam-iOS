import UIKit

/// Centralized Taptic Engine feedback for camera controls.
/// Enabled by default; users can turn it off in DualCam settings.
enum HapticFeedback {
    static let preferenceKey = "dualcam.haptics.enabled"

    enum Event {
        case button
        case selection
        case focus
        case shutter
        case zoom
        case snap
        case recordingStart
        case recordingStop
        case success
        case error
        case countdownTick
    }

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: preferenceKey) as? Bool) ?? true
    }

    static func play(_ event: Event) {
        guard isEnabled else { return }

        switch event {
        case .button:
            impact(.light, intensity: 0.65)
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .focus:
            impact(.light, intensity: 0.85)
        case .shutter:
            impact(.medium, intensity: 1.0)
        case .zoom:
            impact(.soft, intensity: 0.55)
        case .snap:
            impact(.rigid, intensity: 0.9)
        case .recordingStart:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .recordingStop:
            impact(.rigid, intensity: 0.85)
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .countdownTick:
            impact(.soft, intensity: 0.45)
        }
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }
}
