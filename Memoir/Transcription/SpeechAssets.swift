import Foundation
import OSLog
import Speech

nonisolated enum TranscriptionError: LocalizedError {
    case speechUnavailable
    case unsupportedLocale(Locale)
    case modelUnavailable(Locale)

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            "Speech recognition is not available on this Mac."
        case .unsupportedLocale(let locale):
            "Transcription does not support \(Self.name(of: locale))."
        case .modelUnavailable(let locale):
            "The speech model for \(Self.name(of: locale)) could not be installed."
        }
    }

    private static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

/// Locale resolution and model asset management shared by the pipeline and the model manager.
nonisolated enum SpeechAssets {
    static let log = Logger(subsystem: "de.jandow.Memoir", category: "Transcription")

    /// Live transcribers need `.fastResults`: without it, volatile results arrive in bursts
    /// roughly every four seconds of audio instead of about once per second.
    static func makeTranscriber(locale: Locale, volatileResults: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: volatileResults ? [.volatileResults, .fastResults] : [],
            attributeOptions: [.audioTimeRange]
        )
    }

    static func resolve(_ locale: Locale) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.speechUnavailable }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale)
        }
        return resolved
    }

    /// Downloads the model if needed. Returns once it is installed.
    static func install(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            progress(1)
            return
        case .unsupported:
            throw TranscriptionError.unsupportedLocale(locale)
        case .supported, .downloading:
            break
        @unknown default:
            break
        }

        try await reserve(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            // Progress is KVO-only; polling keeps this free of Objective-C observation and
            // its Sendable headaches, and a few updates per second is plenty for a UI bar.
            let poller = Task {
                while !Task.isCancelled {
                    progress(min(max(request.progress.fractionCompleted, 0), 1))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poller.cancel() }
            try await request.downloadAndInstall()
        }

        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscriptionError.modelUnavailable(locale)
        }
        progress(1)
    }

    /// Reserving keeps the system from purging our model. The number of reservations per app
    /// is capped, so the oldest one is released to make room.
    static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        let key = locale.identifier(.bcp47)
        guard !reserved.contains(where: { $0.identifier(.bcp47) == key }) else { return }
        // The order of `reservedLocales` is not documented; it is treated as oldest first.
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            log.info("Releasing reserved locale \(oldest.identifier, privacy: .public)")
            await AssetInventory.release(reservedLocale: oldest)
        }
        try await AssetInventory.reserve(locale: locale)
    }
}
