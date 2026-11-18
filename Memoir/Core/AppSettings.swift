import Foundation
import Observation

@Observable
final class AppSettings {
    private enum Key {
        static let autoSummarize = "autoSummarize"
        static let detectMicrophoneApps = "detectMicrophoneApps"
        static let detectCalendar = "detectCalendar"
        static let detectCamera = "detectCamera"
        static let suggestStopping = "suggestStopping"
        static let mutedBundleIDs = "mutedBundleIDs"
        static let localeIdentifier = "localeIdentifier"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any detection-related setting changed.
    @ObservationIgnored var detectionChanged: (() -> Void)?

    var autoSummarize: Bool { didSet { defaults.set(autoSummarize, forKey: Key.autoSummarize) } }
    var detectMicrophoneApps: Bool {
        didSet { defaults.set(detectMicrophoneApps, forKey: Key.detectMicrophoneApps); detectionChanged?() }
    }
    var detectCalendar: Bool {
        didSet { defaults.set(detectCalendar, forKey: Key.detectCalendar); detectionChanged?() }
    }
    var detectCamera: Bool {
        didSet { defaults.set(detectCamera, forKey: Key.detectCamera); detectionChanged?() }
    }
    /// Offer to stop when the meeting app releases the microphone.
    var suggestStopping: Bool { didSet { defaults.set(suggestStopping, forKey: Key.suggestStopping) } }
    /// Apps the user chose "Don't ask for this app" for.
    var mutedBundleIDs: Set<String> {
        didSet { defaults.set(mutedBundleIDs.sorted(), forKey: Key.mutedBundleIDs); detectionChanged?() }
    }
    /// Transcription language. Empty means "follow the system language".
    var localeIdentifier: String { didSet { defaults.set(localeIdentifier, forKey: Key.localeIdentifier) } }
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoSummarize: true,
            Key.detectMicrophoneApps: true,
            Key.detectCalendar: true,
            Key.detectCamera: true,
            Key.suggestStopping: true,
        ])
        autoSummarize = defaults.bool(forKey: Key.autoSummarize)
        detectMicrophoneApps = defaults.bool(forKey: Key.detectMicrophoneApps)
        detectCalendar = defaults.bool(forKey: Key.detectCalendar)
        detectCamera = defaults.bool(forKey: Key.detectCamera)
        suggestStopping = defaults.bool(forKey: Key.suggestStopping)
        mutedBundleIDs = Set(defaults.stringArray(forKey: Key.mutedBundleIDs) ?? [])
        localeIdentifier = defaults.string(forKey: Key.localeIdentifier) ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    var transcriptionLocale: Locale {
        localeIdentifier.isEmpty ? .current : Locale(identifier: localeIdentifier)
    }

    var detectionOptions: DetectionOptions {
        DetectionOptions(
            microphoneApps: detectMicrophoneApps,
            calendar: detectCalendar,
            camera: detectCamera,
            mutedBundleIDs: mutedBundleIDs
        )
    }
}
