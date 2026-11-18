import Foundation
import FoundationModels

/// Token budgets derived from the model's context size. Every budget scales with
/// `contextSize`, which is 4096 before macOS 27 and the real (possibly larger) value after.
nonisolated struct ContextBudget: Sendable, Equatable {
    var contextSize: Int
    var estimator: TokenEstimator

    // MARK: Summaries

    /// Room for the generated summary. A full summary with eight key points and several action
    /// items runs to roughly 600-900 tokens.
    var summaryOutput: Int { min(1000, contextSize / 4) }

    /// Transcript or notes that a single summary call can take, after instructions, schema
    /// and output. `overhead` is measured when token counting is available.
    func summaryInput(overhead: Int, scale: Double = 1) -> Int {
        max(256, Int(Double(contextSize - summaryOutput - overhead) * scale))
    }

    var condenseOutput: Int { min(700, contextSize / 6) }

    /// Far smaller than the context allows. The model writes notes at roughly a third of the
    /// input length, and notes cut off by `condenseOutput` silently lose the end of a part,
    /// so parts must stay small enough that their notes always fit.
    func condenseInput(overhead: Int, scale: Double = 1) -> Int {
        let available = contextSize - condenseOutput - overhead
        return max(256, Int(Double(min(available, 1500)) * scale))
    }

    // MARK: Chat

    var chatAnswer: Int { min(800, contextSize / 5) }

    func chatHistory(compact: Bool) -> Int {
        Int(Double(contextSize) * (compact ? 0.05 : 0.12))
    }

    /// Per tool call. The model may call a tool more than once per question, which is why
    /// this stays well below what is left after instructions.
    func toolOutput(compact: Bool) -> Int {
        Int(Double(contextSize) * (compact ? 0.15 : 0.22))
    }

    func meetingSummary(compact: Bool) -> Int {
        Int(Double(contextSize) * (compact ? 0.08 : 0.15))
    }

    /// The whole transcript goes into the instructions only when it leaves comfortable room
    /// for the answer and some history. Otherwise the model retrieves through a tool.
    func canInlineTranscript(transcriptTokens: Int, otherInstructionTokens: Int) -> Bool {
        transcriptTokens + otherInstructionTokens + chatAnswer + 150 <= Int(Double(contextSize) * 0.85)
    }

    /// Measures the real tokenizer once when available so the character heuristic is
    /// calibrated for the language at hand.
    static func make(model: SystemLanguageModel, sample: String) async -> ContextBudget {
        var estimator = TokenEstimator()
        if #available(macOS 26.4, *), !sample.isEmpty {
            if let actual = try? await model.tokenCount(for: sample) {
                estimator = .calibrated(sample: sample, actualTokens: actual)
            }
        }
        return ContextBudget(contextSize: model.contextSize, estimator: estimator)
    }

    /// Tokens for instructions plus a generation schema, measured when possible.
    func overhead(model: SystemLanguageModel, instructions: String, schema: GenerationSchema?) async -> Int {
        let fallback = estimator.tokens(instructions) + (schema == nil ? 0 : 350) + 80
        guard #available(macOS 26.4, *) else { return fallback }
        do {
            var total = try await model.tokenCount(for: Instructions(instructions))
            if let schema { total += try await model.tokenCount(for: schema) }
            return total + 80
        } catch {
            return fallback
        }
    }
}
