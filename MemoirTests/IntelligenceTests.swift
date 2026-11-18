import Foundation
import FoundationModels
import Testing
@testable import Memoir

@Suite struct IntelligenceFormatTests {
    @Test func timestampsUseMinutesBelowAnHour() {
        #expect(TranscriptFormat.timestamp(0) == "00:00")
        #expect(TranscriptFormat.timestamp(9.9) == "00:09")
        #expect(TranscriptFormat.timestamp(754) == "12:34")
        #expect(TranscriptFormat.timestamp(3599) == "59:59")
    }

    @Test func timestampsUseHoursFromAnHourOn() {
        #expect(TranscriptFormat.timestamp(3600) == "1:00:00")
        #expect(TranscriptFormat.timestamp(3600 + 62) == "1:01:02")
        #expect(TranscriptFormat.citation(10 * 3600 + 5) == "[10:00:05]")
    }

    @Test func timestampsClampInvalidValues() {
        #expect(TranscriptFormat.timestamp(-5) == "00:00")
        #expect(TranscriptFormat.timestamp(.nan) == "00:00")
    }

    @Test func rendersCompactLinesWithSpeakerLabels() {
        let line = TranscriptLine(speaker: .me, start: 65, end: 70, text: "  Ship it\n on   Friday ")
        #expect(TranscriptFormat.render(line) == "[01:05] You: Ship it on Friday")
        let other = TranscriptLine(speaker: .others, start: 3725, end: 3730, text: "Okay")
        #expect(TranscriptFormat.render(other) == "[1:02:05] Others: Okay")
        #expect(TranscriptFormat.render(other, othersName: "Priya") == "[1:02:05] Priya: Okay")
        #expect(TranscriptFormat.render(line, othersName: "Priya") == "[01:05] You: Ship it on Friday")
    }

    @Test func parsesCitationsRoundTrip() {
        let text = "Launch moved [12:04], confirmed later [1:02:05]. Not a citation: [99] or [ab:cd]."
        #expect(TranscriptFormat.citations(in: text) == [724, 3725])
        for seconds in [0.0, 59, 61, 3599, 3600, 7322] {
            #expect(TranscriptFormat.citations(in: TranscriptFormat.citation(seconds)) == [seconds])
        }
    }

    @Test func rejectsOutOfRangeFields() {
        #expect(TranscriptFormat.seconds(fromTimestamp: "12:60") == nil)
        #expect(TranscriptFormat.seconds(fromTimestamp: "1:60:00") == nil)
        #expect(TranscriptFormat.seconds(fromTimestamp: "75:10") == 4510)
    }

    @Test func normalizesGroupedCitations() {
        #expect(TranscriptFormat.normalizeCitations("As said [01:10, 02:30].") == "As said [01:10] [02:30].")
        #expect(TranscriptFormat.normalizeCitations("Agreed (at 12:04).") == "Agreed [12:04].")
        #expect(TranscriptFormat.normalizeCitations("Already fine [12:04].") == "Already fine [12:04].")
        #expect(TranscriptFormat.normalizeCitations("Ratio (3:1) stays") == "Ratio (3:1) stays")
        #expect(TranscriptFormat.normalizeCitations("(see notes)") == "(see notes)")
    }
}

@Suite struct IntelligenceCitationRepairTests {
    private let lines = [
        TranscriptLine(speaker: .me, start: 663, end: 670, text: "So we make Aiko an offer at 140,000, and I check the signing bonus with HR."),
        TranscriptLine(speaker: .others, start: 675, end: 680, text: "I will tell Tomasz we went with someone else."),
        TranscriptLine(speaker: .others, start: 699, end: 705, text: "Should we also restart the search for the designer role?"),
    ]

    @Test func repointsCitationOfAnUnrelatedLine() {
        let answer = "We are offering Aiko 140,000 [11:39]."
        #expect(CitationRepair.repair(answer, lines: lines) == "We are offering Aiko 140,000 [11:03].")
    }

    @Test func keepsCorrectCitations() {
        let answer = "Aiko gets an offer at 140,000 [11:03]. Tomasz will be told [11:15]."
        #expect(CitationRepair.repair(answer, lines: lines) == answer)
    }

    @Test func treatsShortMinuteFormAsTheSamePosition() {
        let line = TranscriptLine(speaker: .me, start: 65, end: 70, text: "Aiko gets an offer at 140,000")
        let repaired = CitationRepair.repair("Aiko gets an offer at 140,000 [1:05].", lines: [line] + lines)
        #expect(repaired == "Aiko gets an offer at 140,000 [01:05].")
    }

    @Test func keepsCitationsWhenNothingMatchesClearly() {
        let answer = "The weather was nice [11:39]."
        #expect(CitationRepair.repair(answer, lines: lines) == answer)
    }

    @Test func adjacentCitationsShareTheirClaim() {
        let answer = "The designer role search may restart [11:39][11:03]."
        let repaired = CitationRepair.repair(answer, lines: lines)
        #expect(repaired == "The designer role search may restart [11:39].")
    }

    @Test func handlesDecimalsAndHourStamps() {
        let long = [TranscriptLine(speaker: .me, start: 3725, end: 3730, text: "Budget is 4.5 million for the tablet study")]
        let answer = "The tablet study budget is 4.5 million [1:02:05]."
        #expect(CitationRepair.repair(answer, lines: long) == answer)
        #expect(CitationRepair.repair("No citations here.", lines: long) == "No citations here.")
    }
}

@Suite struct IntelligenceChunkerTests {
    private func line(_ index: Int, words: Int = 10, speaker: Speaker = .others) -> TranscriptLine {
        TranscriptLine(
            speaker: speaker,
            start: TimeInterval(index * 10),
            end: TimeInterval(index * 10 + 8),
            text: Array(repeating: "word\(index)", count: words).joined(separator: " ")
        )
    }

    @Test func emptyInputGivesNoChunks() {
        #expect(TranscriptChunker.chunks([], budget: 100).isEmpty)
    }

    @Test func everythingFitsInOneChunk() {
        let lines = (0..<5).map { line($0) }
        let chunks = TranscriptChunker.chunks(lines, budget: 10_000)
        #expect(chunks.count == 1)
        #expect(chunks[0].lines == 0..<5)
        #expect(chunks[0].text == TranscriptFormat.render(lines))
        #expect(chunks[0].start == 0)
        #expect(chunks[0].end == 48)
    }

    @Test func chunksCoverAllLinesInOrderWithoutSplitting() {
        let lines = (0..<200).map { line($0, words: 3 + $0 % 17, speaker: $0.isMultiple(of: 2) ? .me : .others) }
        let estimator = TokenEstimator()
        let budget = 300
        let chunks = TranscriptChunker.chunks(lines, budget: budget, estimator: estimator)

        #expect(chunks.count > 1)
        #expect(chunks.first?.lines.lowerBound == 0)
        #expect(chunks.last?.lines.upperBound == lines.count)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(previous.lines.upperBound == next.lines.lowerBound)
        }
        for chunk in chunks {
            #expect(chunk.tokens <= budget)
            // Each rendered line appears whole in exactly its chunk.
            let expected = lines[chunk.lines].map { TranscriptFormat.render($0) }
            #expect(chunk.text.components(separatedBy: "\n") == expected)
        }
    }

    @Test func chunksAreBalanced() {
        let lines = (0..<100).map { line($0) }
        let chunks = TranscriptChunker.chunks(lines, budget: 400)
        let sizes = chunks.map(\.tokens)
        let smallest = sizes.min() ?? 0
        let largest = sizes.max() ?? 0
        #expect(Double(smallest) >= Double(largest) * 0.6, "sizes: \(sizes)")
    }

    @Test func oversizedLineGetsOwnTruncatedChunk() {
        let lines = [line(0), line(1, words: 2000), line(2)]
        let chunks = TranscriptChunker.chunks(lines, budget: 200)
        #expect(chunks.map(\.lines) == [0..<1, 1..<2, 2..<3])
        #expect(chunks[1].tokens <= 200)
        #expect(chunks[1].text.hasPrefix("[00:10] Others: word1"))
        #expect(chunks[1].text.hasSuffix("..."))
    }

    @Test func packHandlesEdgeCases() {
        #expect(TranscriptChunker.pack([], budget: 10).isEmpty)
        #expect(TranscriptChunker.pack([50], budget: 10) == [0..<1])
        #expect(TranscriptChunker.pack([4, 4, 4], budget: 10) == [0..<2, 2..<3])
        let ranges = TranscriptChunker.pack(Array(repeating: 9, count: 10), budget: 30)
        #expect(ranges.count == 4)
        #expect(ranges.allSatisfy { $0.count * 10 <= 30 })
    }

    @Test func estimatorIsPessimisticForAsciiAndNonAscii() {
        let estimator = TokenEstimator()
        #expect(estimator.tokens("") == 0)
        #expect(estimator.tokens(String(repeating: "abcd ", count: 100)) >= 125)
        #expect(estimator.tokens("会議の議事録") >= 5)
    }

    @Test func calibrationScalesAndClamps() {
        let sample = String(repeating: "hello world ", count: 50)
        let raw = TokenEstimator().tokens(sample)
        let calibrated = TokenEstimator.calibrated(sample: sample, actualTokens: raw / 2)
        #expect(calibrated.tokens(sample) < raw)
        #expect(calibrated.tokens(sample) >= raw / 2)
        #expect(TokenEstimator.calibrated(sample: sample, actualTokens: raw * 100).scale == 2)
        #expect(TokenEstimator.calibrated(sample: "short", actualTokens: 3) == TokenEstimator())
    }

    @Test func truncateRespectsLimit() {
        let estimator = TokenEstimator()
        let text = String(repeating: "lorem ipsum dolor ", count: 200)
        let cut = estimator.truncate(text, toTokens: 50)
        #expect(estimator.tokens(cut) <= 50)
        #expect(cut.hasSuffix("..."))
        #expect(estimator.truncate("short", toTokens: 50) == "short")
    }
}

@Suite struct IntelligenceRankingTests {
    @Test func termsFoldCaseDiacriticsAndDropStopwords() {
        #expect(PassageRanker.terms("What did they say about the Budget?") == ["budget"])
        #expect(PassageRanker.terms("Über die Kosten: 4,500 Euro") == ["kosten", "4", "500", "euro"])
        #expect(PassageRanker.terms("a b 7") == ["7"])
    }

    @Test func keywordRankingPrefersRareMatchingTerms() {
        let passages = [
            "We talked about the weather and the weekend.",
            "The launch date moves to May 13th because of the Android crash.",
            "The crash happens on older Samsung phones.",
            "Lunch is at noon.",
        ]
        let hits = PassageRanker.rank(query: "When is the launch date?", passages: passages)
        #expect(hits.first?.index == 1)
        #expect(hits.last?.score == 0)
    }

    @Test func stemPrefixMatchesWordForms() {
        #expect(PassageRanker.sharesStem("deployment", "deploying"))
        #expect(PassageRanker.sharesStem("estimates", "estimate"))
        #expect(!PassageRanker.sharesStem("cat", "category"))
        let hits = PassageRanker.rank(query: "deployment", passages: ["Jonas is deploying tomorrow", "Nothing here"])
        #expect(hits.first?.index == 0)
        #expect((hits.first?.score ?? 0) > 0)
    }

    @Test func semanticScoreCanOutrankMissingKeywords() {
        let passages = ["revenue went up", "the cat sat"]
        let query = "income growth"
        let hits = PassageRanker.rank(
            query: query,
            passages: passages,
            queryVector: [1, 0],
            passageVectors: [[0.9, 0.1], [0, 1]]
        )
        #expect(hits.first?.index == 0)
        #expect((hits.first?.score ?? 0) > 0.5)
    }

    @Test func missingVectorsFallBackToKeywords() {
        let hits = PassageRanker.rank(
            query: "budget",
            passages: ["the budget is 4,500", "nothing"],
            queryVector: [1, 0],
            passageVectors: [nil, nil]
        )
        #expect(hits.first?.index == 0)
        #expect(hits.first?.score == 1)
    }

    @Test func cosineHandlesDegenerateVectors() {
        #expect(PassageRanker.cosine([1, 0], [1, 0]) == 1)
        #expect(abs(PassageRanker.cosine([1, 0], [0, 1])) < 1e-9)
        #expect(PassageRanker.cosine([], []) == 0)
        #expect(PassageRanker.cosine([0, 0], [1, 1]) == 0)
        #expect(PassageRanker.cosine([1], [1, 2]) == 0)
    }

    @Test func contextWindowsMergeAndClamp() {
        #expect(PassageRanker.contextWindows(around: [0], radius: 1, count: 10) == [0...1])
        #expect(PassageRanker.contextWindows(around: [9], radius: 2, count: 10) == [7...9])
        #expect(PassageRanker.contextWindows(around: [5, 2, 3], radius: 1, count: 10) == [1...6])
        #expect(PassageRanker.contextWindows(around: [1, 8], radius: 1, count: 10) == [0...2, 7...9])
        #expect(PassageRanker.contextWindows(around: [20], radius: 1, count: 10).isEmpty)
        #expect(PassageRanker.contextWindows(around: [0], radius: 1, count: 0).isEmpty)
    }

    @Test func stopwordListWithDuplicatesDoesNotTrap() {
        #expect(PassageRanker.stopwords.contains("so"))
        #expect(PassageRanker.stopwords.contains("was"))
    }
}

@Suite struct IntelligenceRetrievalTests {
    @Test func meetingSearchReturnsCitedPassagesWithinBudget() async {
        let corpus = IntelligenceFixtures.corpus()
        let index = RetrievalIndex(corpus: corpus)
        let estimator = TokenEstimator()
        let result = await index.searchMeeting(
            IntelligenceFixtures.releaseID, query: "release notes draft", budget: 400, estimator: estimator
        )
        #expect(result.contains("release notes"))
        #expect(!TranscriptFormat.citations(in: result).isEmpty)
        #expect(estimator.tokens(result) <= 420)
    }

    @Test func librarySearchNamesTheMatchingMeeting() async {
        let index = RetrievalIndex(corpus: IntelligenceFixtures.corpus())
        let result = await index.searchLibrary(
            query: "Aiko salary offer", from: nil, to: nil, budget: 800, estimator: TokenEstimator()
        )
        #expect(result.hasPrefix("\"Android hiring sync\""))
        #expect(result.contains("140,000"))
    }

    @Test func listMeetingsFiltersByDate() async {
        let now = Date.now
        let index = RetrievalIndex(corpus: IntelligenceFixtures.corpus(now: now))
        let lastWeek = await index.listMeetings(
            from: now.addingTimeInterval(-7 * 86_400), to: now, budget: 500, estimator: TokenEstimator()
        )
        #expect(lastWeek.contains("Fieldnote 2.3 release planning"))
        #expect(!lastWeek.contains("Android hiring sync"))
        let none = await index.listMeetings(
            from: now.addingTimeInterval(86_400), to: nil, budget: 500, estimator: TokenEstimator()
        )
        #expect(none.contains("no recorded meetings"))
    }

    @Test func dayParserAcceptsIsoDaysOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let start = DayParser.start(of: "2026-05-13", calendar: calendar)
        let end = DayParser.end(of: "2026-05-13", calendar: calendar)
        #expect(start != nil && end != nil)
        if let start, let end {
            #expect(end.timeIntervalSince(start) == 86_399)
        }
        #expect(DayParser.start(of: "May 13", calendar: calendar) == nil)
        #expect(DayParser.start(of: "2026-13-01", calendar: calendar) == nil)
        #expect(DayParser.start(of: nil, calendar: calendar) == nil)
    }

    @Test func historyKeepsMostRecentTurnsWithinBudget() {
        let turns = (0..<20).map { ChatTurn(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "turn \($0) " + String(repeating: "x ", count: 50)) }
        let estimator = TokenEstimator()
        let text = AppleChatSession.historyText(turns, budget: 200, estimator: estimator)
        #expect(text != nil)
        #expect(estimator.tokens(text ?? "") <= 210)
        #expect(text?.contains("turn 19") == true)
        #expect(text?.contains("turn 0 ") == false)
        #expect(AppleChatSession.historyText([], budget: 200, estimator: estimator) == nil)
    }
}

@Suite struct IntelligenceErrorTests {
    @Test func cancellationPassesThrough() {
        #expect(IntelligenceError.from(CancellationError()) is CancellationError)
    }

    @Test func unknownErrorsBecomeFailedWithMessage() {
        let error = IntelligenceError.from(URLError(.timedOut))
        guard case .failed(let message) = error as? IntelligenceError else {
            Issue.record("Expected .failed, got \(error)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func frameworkErrorsMapToAppErrors() throws {
        guard #available(macOS 27.0, *) else { return }
        let overflow = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 4096, tokenCount: 5000, debugDescription: "too long")
        )
        #expect(IntelligenceError.from(overflow) as? IntelligenceError == .contextTooLarge)
        #expect(IntelligenceError.isContextOverflow(overflow))

        let guardrail = LanguageModelError.guardrailViolation(.init(debugDescription: "nope"))
        #expect(IntelligenceError.from(guardrail) as? IntelligenceError == .guardrailViolation)

        let rate = LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "slow down"))
        #expect(IntelligenceError.isTransient(rate))

        #expect(IntelligenceError.from(LanguageModelSession.Error.concurrentRequests) as? IntelligenceError == .busy)
    }

    @Test func everyErrorHasAReadableMessage() {
        let errors: [IntelligenceError] = [
            .unavailable(.deviceNotEligible), .unavailable(.appleIntelligenceNotEnabled),
            .unavailable(.modelNotReady), .emptyTranscript, .meetingNotFound, .contextTooLarge,
            .guardrailViolation, .refusal, .unsupportedLanguage, .rateLimited, .timeout,
            .assetsUnavailable, .busy, .failed(""),
        ]
        for error in errors {
            let message = error.errorDescription ?? ""
            #expect(!message.isEmpty)
            #expect(!message.contains("\u{2014}") && !message.contains("\u{2013}"))
        }
    }

    @Test func summaryCleanupDropsPlaceholdersAndDuplicates() throws {
        let generated = try GeneratedSummary(GeneratedContent(json: """
            {"overview": "  We met. ", "title": "\\"Launch review\\"",
             "keyPoints": ["A", "a", "B"], "decisions": ["None."],
             "actionItems": [{"task": "Write notes", "owner": "unknown"}, {"task": " ", "owner": "Priya"}]}
            """))
        let summary = MeetingSummary(generated)
        #expect(summary.title == "Launch review")
        #expect(summary.overview == "We met.")
        #expect(summary.keyPoints == ["A", "B"])
        #expect(summary.decisions.isEmpty)
        #expect(summary.actionItems == [.init(task: "Write notes", owner: nil)])
    }
}
