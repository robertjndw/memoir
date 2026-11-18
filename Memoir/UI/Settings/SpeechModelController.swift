import Foundation
import Observation

/// Status and download of the speech model for one locale, shared by Settings and onboarding.
@Observable
final class SpeechModelController {
    private(set) var status: SpeechModelStatus?
    private(set) var progress: Double?
    private(set) var failure: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    var isDownloading: Bool { task != nil }

    func refresh(locale: Locale, using models: any SpeechModelManaging) async {
        guard !isDownloading else { return }
        failure = nil
        status = nil
        let result = await models.status(for: locale)
        guard !Task.isCancelled else { return }
        status = result
    }

    func download(locale: Locale, using models: any SpeechModelManaging) {
        guard task == nil else { return }
        failure = nil
        progress = 0
        status = .downloading
        task = Task {
            do {
                for try await value in models.install(locale: locale) {
                    progress = value
                }
                status = .installed
            } catch {
                failure = error.localizedDescription
                status = await models.status(for: locale)
                if status == .downloading { status = .notInstalled }
            }
            progress = nil
            task = nil
        }
    }
}

/// Display name for a locale in the user's language, falling back to the identifier.
func localizedName(of locale: Locale) -> String {
    // The system locale can carry keywords ("en_US@rg=dezzzz" for English with German region
    // formats) that have no display name and would be shown raw.
    let identifier = locale.identifier.split(separator: "@").first.map(String.init) ?? locale.identifier
    return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
}
