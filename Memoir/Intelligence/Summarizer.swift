import Foundation
import FoundationModels

/// Summarizes one transcript. Short transcripts go straight into the structured summary call;
/// long ones are condensed part by part into notes first (map), and the notes are summarized
/// (reduce), repeating the condensing step while the notes still do not fit.
nonisolated struct Summarizer: Sendable {
    let model: SystemLanguageModel
    let request: SummaryRequest
    let emit: @Sendable (SummaryProgress) -> Void
    /// Tests use this to force the map-reduce path regardless of the device's context size.
    var contextSizeOverride: Int?

    /// Each context overflow shrinks the budgets by this factor and tries again.
    private static let overflowShrink = 0.7
    private static let minimumScale = 0.25
    /// Beyond this, condensing is not converging, so the notes are cut to fit instead.
    private static let maximumLevels = 4
    /// A level is abandoned once more than this share of its parts failed: the notes would
    /// cover too little of the meeting to present the result as a summary of it.
    private static let maximumFailedShare = 1.0 / 3.0
    /// Pauses before each retry of a transient error, so a busy model has time to recover.
    static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]

    func run() async throws -> MeetingSummary {
        let lines = request.lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !lines.isEmpty else { throw IntelligenceError.emptyTranscript }

        let language = Prompts.languageName(for: request.locale)
        let summaryInstructions = Prompts.summaryInstructions(language: language)
        let condenseInstructions = Prompts.condenseInstructions(language: language)
        let context = Prompts.meetingContext(date: request.date, attendees: request.attendees)

        let othersName = Prompts.otherSpeakerName(attendees: request.attendees)
        let rendered = lines.map { TranscriptFormat.render($0, othersName: othersName) }
        var budget = await ContextBudget.make(model: model, sample: String(rendered.prefix(150).joined(separator: "\n").prefix(6000)))
        if let contextSizeOverride { budget.contextSize = contextSizeOverride }
        let summaryOverhead = await budget.overhead(
            model: model,
            instructions: summaryInstructions + context,
            schema: GeneratedSummary.generationSchema
        )
        let condenseOverhead = await budget.overhead(model: model, instructions: condenseInstructions, schema: nil)
        let estimator = budget.estimator

        var pieces = rendered
        var isNotes = false
        var scale = 1.0
        var level = 0
        var progress = ProgressTracker(emit: emit)

        while true {
            try Task.checkCancellation()
            let material = pieces.joined(separator: "\n")
            let inputBudget = budget.summaryInput(overhead: summaryOverhead, scale: scale)

            if estimator.tokens(material) <= inputBudget || level >= Self.maximumLevels {
                let fitted = estimator.truncate(material, toTokens: inputBudget)
                do {
                    progress.finish()
                    return try await summarize(
                        material: fitted,
                        isNotes: isNotes,
                        context: context,
                        instructions: summaryInstructions,
                        maximumTokens: budget.summaryOutput
                    )
                } catch where IntelligenceError.isContextOverflow(error) && scale > Self.minimumScale {
                    scale *= Self.overflowShrink
                    continue
                }
            }

            let chunkBudget = budget.condenseInput(overhead: condenseOverhead, scale: scale)
            let sized = pieces.map { estimator.truncate($0, toTokens: chunkBudget) }
            let groups = TranscriptChunker.pack(sized.map(estimator.tokens), budget: chunkBudget)
                .map { sized[$0].joined(separator: "\n") }
            progress.plan(groups.count)

            let notes = try await Self.mapParts(groups, progress: &progress) { group, part in
                try await condense(
                    group,
                    part: part,
                    of: groups.count,
                    isNotes: isNotes,
                    instructions: condenseInstructions,
                    maximumTokens: budget.condenseOutput,
                    estimator: estimator
                )
            }
            pieces = notes.isEmpty ? [estimator.truncate(material, toTokens: chunkBudget)] : notes
            isNotes = true
            level += 1
        }
    }

    // MARK: Steps

    private func summarize(
        material: String,
        isNotes: Bool,
        context: String,
        instructions: String,
        maximumTokens: Int
    ) async throws -> MeetingSummary {
        try await Self.withTransientRetry {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let prompt = Prompts.summaryPrompt(material: material, isNotes: isNotes, context: context)
            let stream = session.streamResponse(
                to: prompt,
                generating: GeneratedSummary.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumTokens)
            )
            var latest: MeetingSummary?
            var lastRaw: GeneratedContent?
            for try await snapshot in stream {
                try Task.checkCancellation()
                lastRaw = snapshot.rawContent
                let partial = MeetingSummary(snapshot.content)
                if partial != latest {
                    latest = partial
                    emit(.partial(partial))
                }
            }
            if let lastRaw, let complete = try? GeneratedSummary(lastRaw) {
                return MeetingSummary(complete)
            }
            guard let latest else { throw IntelligenceError.failed("") }
            return latest
        }
    }

    /// Condenses one part into note lines. A part that overflows the context is split in half
    /// and both halves are condensed, so one dense stretch cannot sink the whole summary.
    private func condense(
        _ text: String,
        part: Int,
        of total: Int,
        isNotes: Bool,
        instructions: String,
        maximumTokens: Int,
        estimator: TokenEstimator
    ) async throws -> [String] {
        do {
            let response = try await Self.withTransientRetry {
                let session = LanguageModelSession(model: model, instructions: instructions)
                return try await session.respond(
                    to: Prompts.condensePrompt(material: text, part: part, of: total, isNotes: isNotes),
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumTokens)
                )
            }
            return response.content
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } catch where IntelligenceError.isContextOverflow(error) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.count > 1 else {
                let shorter = estimator.truncate(text, toTokens: estimator.tokens(text) / 2)
                guard shorter.count < text.count, shorter.count > 20 else { throw error }
                return try await condense(shorter, part: part, of: total, isNotes: isNotes,
                                          instructions: instructions, maximumTokens: maximumTokens, estimator: estimator)
            }
            let middle = lines.count / 2
            var notes: [String] = []
            for half in [lines[..<middle], lines[middle...]] {
                notes += try await condense(half.joined(separator: "\n"), part: part, of: total, isNotes: isNotes,
                                            instructions: instructions, maximumTokens: maximumTokens, estimator: estimator)
            }
            return notes
        }
    }

    /// Condenses every part, skipping one that keeps failing so a single guardrail hit or
    /// refusal does not discard the notes of all the others. Cancellation always propagates.
    static func mapParts(
        _ groups: [String],
        progress: inout ProgressTracker,
        condense: (String, Int) async throws -> [String]
    ) async throws -> [String] {
        var notes: [String] = []
        var failed = 0
        for (offset, group) in groups.enumerated() {
            try Task.checkCancellation()
            do {
                notes += try await condense(group, offset + 1)
            } catch {
                // The framework can surface a stopped task as its own error type.
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                let mapped = IntelligenceError.from(error)
                // Not specific to this part, so the remaining parts would fail the same way.
                if let mapped = mapped as? IntelligenceError, mapped == .unsupportedLanguage || mapped == .assetsUnavailable {
                    throw mapped
                }
                failed += 1
                if Double(failed) > Double(groups.count) * maximumFailedShare { throw mapped }
            }
            progress.complete()
        }
        return notes
    }

    static func withTransientRetry<T>(
        delays: [Duration] = retryDelays,
        _ operation: () async throws -> T
    ) async throws -> T {
        var remaining = delays[...]
        while true {
            do {
                return try await operation()
            } catch where IntelligenceError.isTransient(error) {
                guard let delay = remaining.popFirst() else { throw error }
                try await Task.sleep(for: delay)
            }
        }
    }
}

/// Keeps `.condensing` monotonic while the total amount of work is still being discovered.
nonisolated struct ProgressTracker {
    let emit: @Sendable (SummaryProgress) -> Void
    private var planned = 0
    private var done = 0
    private var lastReported = 0.0

    init(emit: @escaping @Sendable (SummaryProgress) -> Void) {
        self.emit = emit
    }

    mutating func plan(_ steps: Int) {
        planned += steps
        report()
    }

    mutating func complete() {
        done += 1
        report()
    }

    /// The direct path never reports condensing at all.
    mutating func finish() {
        guard planned > 0, lastReported < 1 else { return }
        lastReported = 1
        emit(.condensing(1))
    }

    private mutating func report() {
        // One step is held back for the final summary, so condensing never claims 100% early.
        let fraction = min(Double(done) / Double(planned + 1), 0.99)
        guard fraction >= lastReported else { return }
        lastReported = fraction
        emit(.condensing(fraction))
    }
}
