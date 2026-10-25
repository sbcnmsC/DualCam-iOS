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
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
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
            notificationGenerator.notificationOccurred(.success)
            notificationGenerator.prepare()
        case .error:
            notificationGenerator.notificationOccurred(.error)
            notificationGenerator.prepare()
        case .countdownTick:
            impact(.soft, intensity: 0.40)
        }
    }

    // Generators are kept alive and re-prepared after every event. Creating a new generator and
    // firing it immediately (the old behaviour) gives the Taptic Engine no time to spin up, which
    // adds noticeable latency to the shutter tick and can drop the event entirely.
    // Only ever touched from the main thread (see play(_:)).
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static var impactGenerators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        let generator: UIImpactFeedbackGenerator
        if let existing = impactGenerators[style] {
            generator = existing
        } else {
            generator = UIImpactFeedbackGenerator(style: style)
            impactGenerators[style] = generator
        }
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }

    /// Spin the Taptic Engine up ahead of a likely shutter press (e.g. when a countdown starts).
    static func prepareShutter() {
        guard isEnabled else { return }
        DispatchQueue.main.async {
            let style = UIImpactFeedbackGenerator.FeedbackStyle.medium
            let generator = impactGenerators[style] ?? UIImpactFeedbackGenerator(style: style)
            impactGenerators[style] = generator
            generator.prepare()
        }
    }
}
