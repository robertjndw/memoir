import Foundation
import Observation

/// Status and download of the speech model for the selected locale, shared by Settings and onboarding.
@Observable
final class SpeechModelController {
    private(set) var status: SpeechModelStatus?
    private(set) var failure: String?

    /// Progress of the running download, or nil when it is for another locale than the selected
    /// one, since that bar would describe a different language.
    var progress: Double? { downloadLocale == selectedLocale ? downloadProgress : nil }

    @ObservationIgnored private var task: Task<Void, Never>?
    private var downloadProgress: Double?
    private var downloadLocale: Locale?
    private var selectedLocale: Locale?

    var isDownloading: Bool { task != nil }

    /// Re-reads the status for `locale`, which becomes the selected one. A download for the same
    /// locale already says all there is to know, but one for another locale must not block this.
    func refresh(locale: Locale, using models: any SpeechModelManaging) async {
        selectedLocale = locale
        failure = nil
        if isDownloading, downloadLocale == locale {
            status = .downloading
            return
        }
        status = nil
        let result = await models.status(for: locale)
        guard !Task.isCancelled, selectedLocale == locale else { return }
        // The model being fetched for another locale doesn't make this one downloading.
        if isDownloading, downloadLocale == locale { return }
        status = result
    }

    func download(locale: Locale, using models: any SpeechModelManaging) {
        guard task == nil else { return }
        selectedLocale = locale
        downloadLocale = locale
        failure = nil
        downloadProgress = 0
        status = .downloading
        task = Task {
            var failed: String?
            do {
                for try await value in models.install(locale: locale) {
                    downloadProgress = value
                }
            } catch {
                failed = error.localizedDescription
            }
            downloadProgress = nil
            downloadLocale = nil
            task = nil
            // The picker may have moved on while this ran, so what was just installed says
            // nothing about the locale that is selected now.
            guard let selected = selectedLocale else { return }
            if selected == locale {
                failure = failed
                if failed == nil {
                    status = .installed
                    return
                }
            }
            let result = await models.status(for: selected)
            guard selectedLocale == selected, !isDownloading else { return }
            status = (selected == locale && result == .downloading) ? .notInstalled : result
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
