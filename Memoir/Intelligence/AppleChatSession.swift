import Foundation
import FoundationModels

/// A conversation about one meeting or the whole library.
///
/// Every question runs in a fresh `LanguageModelSession` whose instructions carry a condensed
/// copy of the recent conversation. Tool results from earlier questions would otherwise pile
/// up in the session transcript and overflow the small context within a few turns.
actor AppleChatSession: ChatSessioning {
    private let scope: ChatScope
    private let index: RetrievalIndex
    private let model: SystemLanguageModel
    private var turns: [ChatTurn]
    private var budget: ContextBudget?

    init(scope: ChatScope, index: RetrievalIndex, model: SystemLanguageModel, history: [ChatTurn]) {
        self.scope = scope
        self.index = index
        self.model = model
        self.turns = history
    }

    nonisolated func respond(to question: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.answer(question) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: IntelligenceError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func answer(_ question: String, yield: @Sendable (String) -> Void) async throws {
        guard model.availability == .available else {
            throw IntelligenceError.unavailable(IntelligenceAvailability(model.availability))
        }
        let budget = await currentBudget()
        var answer = ""
        do {
            answer = try await stream(question, compact: false, budget: budget, yield: yield)
        } catch where IntelligenceError.isContextOverflow(error) {
            // Rebuild with a much shorter history and smaller retrieval results, once.
            answer = try await stream(question, compact: true, budget: budget, yield: yield)
        } catch where IntelligenceError.isTransient(error) {
            try await Task.sleep(for: .seconds(2))
            answer = try await stream(question, compact: false, budget: budget, yield: yield)
        }
        turns.append(ChatTurn(role: .user, text: question))
        turns.append(ChatTurn(role: .assistant, text: answer))
    }

    private func stream(
        _ question: String,
        compact: Bool,
        budget: ContextBudget,
        yield: @Sendable (String) -> Void
    ) async throws -> String {
        let session = try await makeSession(compact: compact, budget: budget)
        let stream = session.streamResponse(
            to: question,
            options: GenerationOptions(temperature: 0.3, maximumResponseTokens: budget.chatAnswer)
        )
        var text = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            text = TranscriptFormat.normalizeCitations(snapshot.content)
            yield(text)
        }
        if case .meeting(let id) = scope {
            let repaired = CitationRepair.repair(text, lines: await index.lines(of: id))
            if repaired != text {
                text = repaired
                yield(text)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentBudget() async -> ContextBudget {
        if let budget { return budget }
        var sample = ""
        if case .meeting(let id) = scope {
            sample = TranscriptFormat.render(await index.lines(of: id).prefix(100))
        }
        let made = await ContextBudget.make(model: model, sample: sample)
        budget = made
        return made
    }

    private func makeSession(compact: Bool, budget: ContextBudget) async throws -> LanguageModelSession {
        let history = Self.historyText(turns, budget: budget.chatHistory(compact: compact), estimator: budget.estimator)
        let estimator = budget.estimator
        switch scope {
        case .meeting(let id):
            guard let digest = await index.digest(id) else { throw IntelligenceError.meetingNotFound }
            let summary = digest.summary
                .map(Prompts.summaryText)
                .flatMap { $0.isEmpty ? nil : estimator.truncate($0, toTokens: budget.meetingSummary(compact: compact)) }
            let header = Prompts.meetingHeader(digest)
            let lines = await index.lines(of: id)
            let transcript = TranscriptFormat.render(lines)
            let withoutTranscript = Prompts.meetingChatInstructions(
                meeting: header, summary: summary, transcript: nil, history: history, today: .now
            )
            if !compact, !lines.isEmpty, budget.canInlineTranscript(
                transcriptTokens: estimator.tokens(transcript),
                otherInstructionTokens: estimator.tokens(withoutTranscript)
            ) {
                let instructions = Prompts.meetingChatInstructions(
                    meeting: header, summary: summary, transcript: transcript, history: history, today: .now
                )
                return LanguageModelSession(model: model, instructions: instructions)
            }
            let tool = SearchTranscriptTool(
                index: index, meetingID: id, budget: budget.toolOutput(compact: compact), estimator: estimator
            )
            return LanguageModelSession(model: model, tools: [tool], instructions: withoutTranscript)

        case .library:
            let digests = await index.digests()
            let recent = digests.prefix(compact ? 3 : 8).map { "- " + RetrievalIndex.meetingLine($0) }
            let instructions = Prompts.libraryChatInstructions(
                meetingCount: digests.count,
                recentMeetings: recent.joined(separator: "\n"),
                history: history,
                today: .now
            )
            let toolBudget = budget.toolOutput(compact: compact)
            let tools: [any Tool] = [
                SearchMeetingsTool(index: index, budget: toolBudget, estimator: estimator),
                ListMeetingsTool(index: index, budget: toolBudget, estimator: estimator),
            ]
            return LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
    }

    /// The most recent turns that fit `budget`, oldest first. Long answers are cut, since the
    /// gist is enough to resolve follow-ups like "and who owns that?".
    static func historyText(_ turns: [ChatTurn], budget: Int, estimator: TokenEstimator) -> String? {
        guard budget > 0 else { return nil }
        let perTurn = max(40, budget / 4)
        var kept: [String] = []
        var used = 0
        for turn in turns.reversed() {
            let text = estimator.truncate(TranscriptFormat.collapseWhitespace(turn.text), toTokens: perTurn)
            guard !text.isEmpty else { continue }
            let line = (turn.role == .user ? "User: " : "Assistant: ") + text
            let cost = estimator.tokens(line) + 1
            guard used + cost <= budget else { break }
            used += cost
            kept.append(line)
        }
        return kept.isEmpty ? nil : kept.reversed().joined(separator: "\n")
    }
}
