import Foundation
import Speech

nonisolated struct SpeechModelManager: SpeechModelManaging {
    init() {}

    func supportedLocales() async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    func status(for locale: Locale) async -> SpeechModelStatus {
        guard let resolved = try? await SpeechAssets.resolve(locale) else { return .unsupported }
        let transcriber = SpeechAssets.makeTranscriber(locale: resolved, volatileResults: true)
        return Self.status(from: await AssetInventory.status(forModules: [transcriber]))
    }

    func install(locale: Locale) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let resolved = try await SpeechAssets.resolve(locale)
                    let transcriber = SpeechAssets.makeTranscriber(locale: resolved, volatileResults: true)
                    try await SpeechAssets.install(for: transcriber, locale: resolved) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func status(from status: AssetInventory.Status) -> SpeechModelStatus {
        switch status {
        case .unsupported: .unsupported
        case .supported: .notInstalled
        case .downloading: .downloading
        case .installed: .installed
        @unknown default: .unsupported
        }
    }
}
