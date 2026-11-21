import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle. Every GitHub release ends up in one appcast: stable releases
/// for everyone, prereleases tagged with the beta channel for those who opt in.
@Observable
final class Updater {
    /// Debug builds carry build number 1, so every release looks newer and Sparkle would offer to
    /// replace the build you are working on.
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    private(set) var canCheckForUpdates = false
    private(set) var lastCheckDate: Date?

    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    var receivesBetaUpdates: Bool {
        didSet {
            UserDefaults.standard.set(receivesBetaUpdates, forKey: UpdaterDelegate.betaKey)
            // Sparkle only reads the allowed channels when it checks, so start the next check now
            // instead of a day from now.
            if Self.isEnabled { controller.updater.resetUpdateCycleAfterShortDelay() }
        }
    }

    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init(model: AppModel) {
        delegate = UpdaterDelegate(model: model)
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: delegate, userDriverDelegate: nil)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        receivesBetaUpdates = UpdaterDelegate.receivesBetaUpdates
        lastCheckDate = controller.updater.lastUpdateCheckDate
        // Background checks move the date too, so read it whenever a cycle ends rather than only
        // after a check from the button.
        delegate.didFinishUpdateCycle = { [weak self] in
            guard let self else { return }
            lastCheckDate = controller.updater.lastUpdateCheckDate
        }
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // KVO closures are always nonisolated, but SPUUpdater only ever changes this on the
            // main thread.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Kept apart from `Updater` and nonisolated because Sparkle calls it as a plain Objective-C delegate.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated static let betaKey = "settings.receivesBetaUpdates"

    var didFinishUpdateCycle: (() -> Void)?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    /// Someone running a beta got it from a prerelease DMG, so they stay on the beta channel until
    /// they turn it off. Everyone else starts on stable.
    nonisolated static var receivesBetaUpdates: Bool {
        if UserDefaults.standard.object(forKey: betaKey) != nil {
            return UserDefaults.standard.bool(forKey: betaKey)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.contains("-")
    }

    /// Items without a channel are stable and always allowed. Beta users still move on to a stable
    /// release once it is newer than their beta.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.receivesBetaUpdates ? ["beta"] : []
    }

    /// A scheduled check would pop the update window up in the middle of a meeting, possibly on a
    /// shared screen. Skipping it is enough, Sparkle tries again on the next cycle. Checks the user
    /// starts from Settings still go through.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }
        // Sparkle calls its delegate on the main thread.
        let busy = MainActor.assumeIsolated { model?.recordingState != .idle }
        if busy {
            throw NSError(domain: "de.jandow.Memoir.Updater", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Memoir is recording, the update check waits for the next cycle.",
            ])
        }
    }

    /// Relaunching mid-recording would drop the audio mix and the transcript tail, so finish the
    /// recording first, the same way Quit does.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // The Objective-C block isn't marked Sendable, but it is only ever called from the main
        // actor below, which is where Sparkle hands it over.
        nonisolated(unsafe) let installHandler = installHandler
        return MainActor.assumeIsolated {
            guard let model, model.recordingState != .idle else { return false }
            Task {
                // stopRecording only acts on a running recording, so one that is still starting
                // is stopped once it runs, and one that is finishing gets to finish.
                while model.recordingState != .idle {
                    await model.stopRecording()
                    try? await Task.sleep(for: .milliseconds(200))
                }
                installHandler()
            }
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { didFinishUpdateCycle?() }
    }
}
