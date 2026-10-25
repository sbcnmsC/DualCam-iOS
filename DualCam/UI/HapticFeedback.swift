import UIKit

/// Central Taptic Engine feedback used by camera UI and hardware capture actions.
/// Feedback is enabled by default and can be disabled in Settings.
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
        if Thread.isMainThread {
            perform(event)
        } else {
            DispatchQueue.main.async {
                guard isEnabled else { return }
                perform(event)
            }
        }
    }

    private static func perform(_ event: Event) {
        switch event {
        case .button:
            impact(.light, intensity: 0.60)
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .focus:
            impact(.light, intensity: 0.80)
        case .shutter:
            impact(.medium, intensity: 1.0)
        case .zoom:
            impact(.soft, intensity: 0.55)
        case .snap:
            impact(.rigid, intensity: 0.90)
        case .recordingStart:
            // Notification haptics can feel too subtle as a camera-recording confirmation.
            // Use a strong impact when the writer has actually started successfully.
            impact(.heavy, intensity: 1.0)
        case .recordingStop:
            // Distinct, firm confirmation at the moment recording is stopped.
            impact(.heavy, intensity: 0.9)
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .countdownTick:
            impact(.soft, intensity: 0.40)
        }
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }
}
