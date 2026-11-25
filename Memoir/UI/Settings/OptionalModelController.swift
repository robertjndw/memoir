import Foundation
import Observation

/// Install state of one optional model for its row in Settings.
///
/// Never trusts a download to have worked: whatever the install stream did, the state is read
/// back from the manager afterwards. Every start, cancel and removal bumps `generation`, so a
/// task that was superseded can't write its outcome over a newer state.
@Observable
final class OptionalModelController {
    let model: OptionalModel
    private(set) var availability: ModelAvailability = .checking
    private(set) var failure: String?
    private(set) var isRemoving = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(model: OptionalModel) {
        self.model = model
    }

    var isDownloading: Bool { task != nil }

    var isInstalled: Bool {
        if case .installed = availability { true } else { false }
    }

    func refresh(using models: any OptionalModelManaging) async {
        guard task == nil, !isRemoving else { return }
        let started = generation
        let state = await Self.state(of: model, in: models)
        guard started == generation, task == nil else { return }
        availability = state
    }

    /// Does nothing when the model is installed or already downloading, so it is safe to call
    /// whenever the user turns the feature on.
    func install(using models: any OptionalModelManaging) {
        guard task == nil, !isInstalled, !isRemoving else { return }
        generation += 1
        let started = generation
        let model = model
        failure = nil
        availability = .downloading(nil)
        task = Task {
            var failed: String?
            do {
                // It may have been installed since the row last looked, from another window.
                if await !models.isInstalled(model) {
                    for try await fraction in models.install(model) {
                        guard started == generation else { break }
                        availability = .downloading(min(max(fraction, 0), 1))
                    }
                }
            } catch {
                failed = error.localizedDescription
            }
            // Cancelled: `cancel` already reset the state and must not be overruled.
            guard started == generation else { return }
            let state = await Self.state(of: model, in: models)
            guard started == generation else { return }
            task = nil
            availability = state
            if failed == nil, state == .notInstalled {
                failed = String(localized: "The download didn't finish. Check your internet connection and try again.")
            }
            failure = failed
        }
    }

    /// Stops a running download. Cancelling the task ends its iteration of the install stream,
    /// which is how the manager learns to stop.
    func cancel(using models: any OptionalModelManaging) async {
        guard let task else { return }
        generation += 1
        task.cancel()
        self.task = nil
        failure = nil
        availability = .checking
        await refresh(using: models)
    }

    func remove(using models: any OptionalModelManaging) async {
        guard task == nil, !isRemoving else { return }
        generation += 1
        let started = generation
        isRemoving = true
        failure = nil
        do {
            try await models.remove(model)
        } catch {
            failure = error.localizedDescription
        }
        let state = await Self.state(of: model, in: models)
        isRemoving = false
        guard started == generation else { return }
        availability = state
    }

    /// A failure only means something while the feature is on, so turning it off forgets it.
    func clearFailure() {
        failure = nil
    }

    private static func state(of model: OptionalModel, in models: any OptionalModelManaging) async -> ModelAvailability {
        guard await models.isInstalled(model) else { return .notInstalled }
        return .installed(size: await models.installedSize(of: model))
    }
}
