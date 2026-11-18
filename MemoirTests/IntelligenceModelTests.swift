import Foundation
import FoundationModels
import Testing
@testable import Memoir

/// Runs the real on-device model. Skipped where Apple Intelligence is unavailable. These check
/// structure and a few facts that any faithful output must contain; the printed output is
/// meant to be read by a person when prompts change.
@Suite(.serialized, .enabled(if: SystemLanguageModel.default.availability == .available))
struct IntelligenceModelTests {
    private func log(_ title: String, _ text: String) {
        print("INTEL-OUT ===== \(title) =====\n\(text)\nINTEL-OUT ===== end =====")
    }

    private func describe(_ summary: MeetingSummary) -> String {
        var lines = ["Title: \(summary.title)", "Overview: \(summary.overview)", "Key points:"]
        lines += summary.keyPoints.map { "  - \($0)" }
        lines.append("Decisions:")
        lines += summary.decisions.map { "  - \($0)" }
        lines.append("Action items:")
        lines += summary.actionItems.map { "  - \($0.task) [owner: \($0.owner ?? "-")]" }
        return lines.joined(separator: "\n")
    }

    private func request(_ lines: [TranscriptLine]) -> SummaryRequest {
        SummaryRequest(lines: lines, attendees: ["Priya Nair"], date: .now, locale: Locale(identifier: "en_US"))
    }

    private func run(_ summarizer: Summarizer) async throws -> MeetingSummary {
        try await summarizer.run()
    }

    @Test func reportsContextSize() {
        log("context", "contextSize=\(SystemLanguageModel.default.contextSize) supportsEnglish=\(SystemLanguageModel.default.supportsLocale(Locale(identifier: "en_US")))")
    }

    @Test func summarizesTenMinuteMeeting() async throws {
        let lines = IntelligenceFixtures.lines(IntelligenceFixtures.releaseMeeting)
        let engine = AppleIntelligence()
        var partials = 0
        var condensing = 0
        var final: MeetingSummary?
        let started = Date.now
        for try await progress in engine.summarize(request(lines)) {
            switch progress {
            case .condensing: condensing += 1
            case .partial: partials += 1
            case .finished(let summary): final = summary
            }
        }
        let summary = try #require(final)
        log("10 min summary (\(Int(Date.now.timeIntervalSince(started)))s, \(partials) partials, \(condensing) condensing, transcript ends \(TranscriptFormat.timestamp(lines.last?.end ?? 0)))", describe(summary))

        #expect(partials > 1)
        #expect(!summary.title.isEmpty && summary.title.count < 80)
        #expect(!summary.overview.isEmpty)
        #expect(summary.keyPoints.count >= 2)
        #expect(summary.decisions.contains { $0.contains("13") })
        #expect(!summary.actionItems.isEmpty)
        let all = describe(summary)
        #expect(!all.contains("\u{2014}"))
    }

    @Test func summarizesLongMeetingWithMapReduce() async throws {
        let lines = IntelligenceFixtures.longMeeting
        let recorder = ProgressRecorder()
        // 4096 is the macOS 26 context size; forcing it guarantees the map-reduce path here.
        let summarizer = Summarizer(model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
                                    request: request(lines),
                                    emit: { recorder.record($0) },
                                    contextSizeOverride: 4096)
        let started = Date.now
        let summary = try await run(summarizer)
        let fractions = recorder.fractions
        log("long summary (\(Int(Date.now.timeIntervalSince(started)))s, \(lines.count) lines, ends \(TranscriptFormat.timestamp(lines.last?.end ?? 0)), condensing \(fractions.map { String(format: "%.2f", $0) }))", describe(summary))

        #expect(fractions.count >= 3)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        #expect(!summary.title.isEmpty)
        #expect(summary.keyPoints.count >= 3)
        let all = describe(summary).lowercased()
        #expect(all.contains("aiko") || all.contains("acme") || all.contains("roadmap"))
    }

    @Test func realContextOverflowMapsToContextTooLarge() async {
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        let huge = String(repeating: "The quarterly numbers were discussed at length again. ", count: 4000)
        do {
            _ = try await session.respond(to: huge)
            Issue.record("Expected a context overflow")
        } catch {
            log("overflow error", "\(type(of: error)): \(error)")
            #expect(IntelligenceError.from(error) as? IntelligenceError == .contextTooLarge)
        }
    }

    @Test func summarizeStopsWhenConsumerStops() async throws {
        let lines = IntelligenceFixtures.lines(IntelligenceFixtures.releaseMeeting)
        let started = Date.now
        var sawPartial = false
        for try await progress in AppleIntelligence().summarize(request(lines)) {
            if case .partial = progress {
                sawPartial = true
                break
            }
        }
        #expect(sawPartial)
        #expect(Date.now.timeIntervalSince(started) < 30)
    }

    @Test func emptyTranscriptFails() async {
        let engine = AppleIntelligence()
        await #expect(throws: IntelligenceError.emptyTranscript) {
            for try await _ in engine.summarize(request([])) {}
        }
    }

    @Test func meetingChatAnswersWithCitations() async throws {
        let corpus = IntelligenceFixtures.corpus()
        let engine = AppleIntelligence()
        let session = await engine.makeChatSession(scope: .meeting(IntelligenceFixtures.releaseID), corpus: corpus, history: [])

        let answer = try await collect(session.respond(to: "Why was the launch moved, and to when?"))
        log("meeting chat: why moved", answer)
        #expect(answer.contains("13"))
        #expect(!TranscriptFormat.citations(in: answer).isEmpty)

        let followUp = try await collect(session.respond(to: "Who is writing the release notes, and by when?"))
        log("meeting chat: follow-up", followUp)
        #expect(followUp.contains("Priya"))

        let missing = try await collect(session.respond(to: "What did they decide about the Windows desktop app?"))
        log("meeting chat: not in transcript", missing)
    }

    @Test func meetingChatUsesSearchToolForLongTranscripts() async throws {
        let lines = IntelligenceFixtures.longMeeting
        let id = UUID()
        let corpus = IntelligenceFixtures.FakeCorpus(
            digests: [MeetingDigest(id: id, title: "Weekly product sync", date: .now, duration: lines.last?.end ?? 0, attendees: ["Priya Nair"], summary: nil)],
            transcripts: [id: lines]
        )
        let session = await AppleIntelligence().makeChatSession(scope: .meeting(id), corpus: corpus, history: [])
        let answer = try await collect(session.respond(to: "What salary are we offering Aiko?"))
        log("long meeting chat (tool)", answer)
        #expect(answer.contains("140"))
        let cited = TranscriptFormat.citations(in: answer)
        #expect(!cited.isEmpty)
        let citedLines = lines.filter { line in cited.contains(TimeInterval(Int(line.start))) }
        #expect(citedLines.contains { $0.text.contains("140,000") || $0.text.contains("Aiko") })
    }

    @Test func libraryChatNamesTheMeeting() async throws {
        let corpus = IntelligenceFixtures.corpus()
        let session = await AppleIntelligence().makeChatSession(scope: .library, corpus: corpus, history: [])

        let answer = try await collect(session.respond(to: "What did we decide about the Acme sync timeouts?"))
        log("library chat: acme", answer)
        #expect(answer.contains("Acme"))
        #expect(answer.contains("300") || answer.lowercased().contains("timeout"))

        let listing = try await collect(session.respond(to: "Which meetings did I have in the last week?"))
        log("library chat: last week", listing)
        #expect(listing.contains("Fieldnote"))
    }

    @Test func historySeedsFollowUps() async throws {
        let corpus = IntelligenceFixtures.corpus()
        let history = [
            ChatTurn(role: .user, text: "Who are the finalists for the Android role?"),
            ChatTurn(role: .assistant, text: "The finalists are Tomasz and Aiko (Android hiring sync)."),
        ]
        let session = await AppleIntelligence().makeChatSession(scope: .library, corpus: corpus, history: history)
        let answer = try await collect(session.respond(to: "Which of the two did we pick, and at what salary?"))
        log("library chat with history", answer)
        #expect(answer.contains("Aiko"))
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var last = ""
        var snapshots = 0
        for try await text in stream {
            last = text
            snapshots += 1
        }
        #expect(snapshots >= 1)
        return last
    }
}

nonisolated final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ progress: SummaryProgress) {
        guard case .condensing(let fraction) = progress else { return }
        lock.withLock { values.append(fraction) }
    }

    var fractions: [Double] { lock.withLock { values } }
}
