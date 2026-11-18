import Foundation
import FoundationModels
import Synchronization

/// Summaries and chat on top of the on-device system language model.
nonisolated final class AppleIntelligence: Intelligence {
    /// Permissive guardrails: the input is the user's own meeting, and the default guardrails
    /// refuse ordinary transcripts that merely mention sensitive topics.
    private static func makeModel() -> SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    private let model: SystemLanguageModel
    /// Keeps the prewarmed session alive until the first real request replaces it.
    private let warmSession = Mutex<LanguageModelSession?>(nil)

    init() {
        model = Self.makeModel()
    }

    var availability: IntelligenceAvailability {
        IntelligenceAvailability(model.availability)
    }

    func prewarm() {
        guard model.availability == .available else { return }
        let session = LanguageModelSession(
            model: model,
            instructions: Prompts.summaryInstructions(language: Prompts.languageName(for: .current))
        )
        session.prewarm()
        warmSession.withLock { $0 = session }
    }

    func summarize(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryProgress, Error> {
        let model = model
        warmSession.withLock { $0 = nil }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard model.availability == .available else {
                        throw IntelligenceError.unavailable(IntelligenceAvailability(model.availability))
                    }
                    let summarizer = Summarizer(model: model, request: request) { continuation.yield($0) }
                    let summary = try await summarizer.run()
                    continuation.yield(.finished(summary))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: IntelligenceError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeChatSession(
        scope: ChatScope,
        corpus: any TranscriptCorpus,
        history: [ChatTurn]
    ) async -> any ChatSessioning {
        warmSession.withLock { $0 = nil }
        return AppleChatSession(
            scope: scope,
            index: RetrievalIndex(corpus: corpus),
            model: model,
            history: history
        )
    }
}
