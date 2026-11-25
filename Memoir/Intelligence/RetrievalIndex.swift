import Foundation
import NaturalLanguage

/// Retrieval over the corpus for chat tools. Caches transcripts and sentence embeddings for
/// the lifetime of one chat session, since a conversation tends to ask several questions
/// about the same meetings.
actor RetrievalIndex {
    /// Lines are scored in overlapping windows: single transcript lines are often too short
    /// ("Yes, Friday works") to match a question on their own.
    nonisolated static let windowSize = 3
    nonisolated static let windowStride = 2
    /// Embedding every window of a large library would stall the first answer, so library
    /// search embeds only the most promising candidates.
    private static let libraryEmbeddingCandidates = 80

    private struct Window {
        var lines: Range<Int>
        var text: String
    }

    private let corpus: any TranscriptCorpus
    private var cachedDigests: [MeetingDigest]?
    private var cachedLines: [UUID: [TranscriptLine]] = [:]
    private var cachedWindows: [UUID: [Window]] = [:]
    private var cachedVectors: [UUID: [Int: [Double]]] = [:]
    private var embeddings: [NLLanguage: NLEmbedding] = [:]
    private var missingEmbeddings: Set<NLLanguage> = []
    private var language: NLLanguage?

    init(corpus: any TranscriptCorpus) {
        self.corpus = corpus
    }

    func digests() async -> [MeetingDigest] {
        if let cachedDigests { return cachedDigests }
        let digests = await corpus.meetings().sorted { $0.date > $1.date }
        cachedDigests = digests
        return digests
    }

    func digest(_ id: UUID) async -> MeetingDigest? {
        await digests().first { $0.id == id }
    }

    func lines(of id: UUID) async -> [TranscriptLine] {
        if let lines = cachedLines[id] { return lines }
        let lines = await corpus.lines(of: id).sorted { $0.start < $1.start }
        cachedLines[id] = lines
        return lines
    }

    // MARK: Meeting search

    /// The best matching passages of one meeting, rendered as `[mm:ss] Speaker: text` with a
    /// line of context on each side, in chronological order and within `budget` tokens.
    func searchMeeting(_ id: UUID, query: String, budget: Int, estimator: TokenEstimator) async -> String {
        let lines = await lines(of: id)
        guard !lines.isEmpty else { return "The transcript of this meeting is empty." }
        let windows = await windows(of: id)
        let queryVector = vector(for: query, sampleText: windows.first?.text ?? query)
        let vectors = queryVector == nil ? [] : vectors(meeting: id, windows: windows, only: nil)
        let hits = PassageRanker.rank(
            query: query,
            passages: windows.map(\.text),
            queryVector: queryVector,
            passageVectors: vectors
        )
        guard let best = hits.first, best.score >= 0.05 else {
            return "No passages in the transcript match \"\(query)\"."
        }
        let passages = Self.selectPassages(
            hits: hits.prefix(8).filter { $0.score >= best.score * 0.5 }.map { windows[$0.index].lines },
            lines: lines,
            budget: budget - 20,
            estimator: estimator
        )
        let body = passages.joined(separator: "\n...\n")
        return "Passages from the transcript, in order:\n\(body)"
    }

    // MARK: Library search

    /// `includeIDs` adds each meeting's id to its heading, for callers that look meetings up
    /// afterwards. The on-device chat leaves it off: ids only cost it tokens.
    func searchLibrary(
        query: String,
        from: Date?,
        to: Date?,
        budget: Int,
        estimator: TokenEstimator,
        maxMeetings: Int = 4,
        passagesPerMeeting: Int = 3,
        includeIDs: Bool = false
    ) async -> String {
        let meetings = await digests().filter { Self.isInRange($0.date, from: from, to: to) }
        guard !meetings.isEmpty else { return "There are no recorded meetings in that date range." }

        // Meeting-level text: what the meeting was about.
        let meetingTexts = meetings.map { meeting in
            [meeting.title, meeting.attendees.joined(separator: " "), meeting.summary.map(Prompts.summaryText) ?? ""]
                .joined(separator: "\n")
        }
        let queryVector = vector(for: query, sampleText: meetingTexts.joined(separator: " "))
        let meetingVectors = queryVector == nil ? [] : meetingTexts.map { embedding(for: $0)?.vector(for: $0) }
        let meetingHits = PassageRanker.rank(
            query: query, passages: meetingTexts, queryVector: queryVector, passageVectors: meetingVectors
        )
        var meetingScores = Dictionary(uniqueKeysWithValues: meetingHits.map { (meetings[$0.index].id, $0.score) })

        // Line-level windows across all meetings: keywords first (cheap), then embeddings for
        // the windows of the best meetings and the best keyword windows.
        var candidates: [(meeting: UUID, window: Int, text: String)] = []
        for meeting in meetings {
            for (index, window) in await windows(of: meeting.id).enumerated() {
                candidates.append((meeting.id, index, window.text))
            }
        }
        let keywordHits = PassageRanker.rank(query: query, passages: candidates.map(\.text))
        var bestWindows: [UUID: [(window: Int, score: Double)]] = [:]
        if let queryVector {
            let topMeetings = Set(meetingHits.prefix(3).map { meetings[$0.index].id })
            var chosen = keywordHits.prefix(Self.libraryEmbeddingCandidates / 2).filter { $0.score > 0 }.map(\.index)
            for (index, candidate) in candidates.enumerated() where topMeetings.contains(candidate.meeting) {
                guard chosen.count < Self.libraryEmbeddingCandidates else { break }
                if !chosen.contains(index) { chosen.append(index) }
            }
            let keywordScores = Dictionary(uniqueKeysWithValues: keywordHits.map { ($0.index, $0.score) })
            for index in chosen {
                let candidate = candidates[index]
                let windowVector = vectors(meeting: candidate.meeting, windows: await windows(of: candidate.meeting), only: [candidate.window])[candidate.window]
                let semantic = windowVector.map { PassageRanker.cosine(queryVector, $0) }
                let score = PassageRanker.combinedScore(keyword: keywordScores[index] ?? 0, semantic: semantic)
                bestWindows[candidate.meeting, default: []].append((candidate.window, score))
            }
        } else {
            for hit in keywordHits where hit.score > 0 {
                let candidate = candidates[hit.index]
                bestWindows[candidate.meeting, default: []].append((candidate.window, hit.score))
            }
        }

        for (meeting, windows) in bestWindows {
            let top = windows.map(\.score).max() ?? 0
            meetingScores[meeting] = max(meetingScores[meeting] ?? 0, top)
        }
        // With embeddings every text scores somewhat; keyword-only scores are 0 when unrelated.
        let threshold = queryVector == nil ? 0.05 : 0.35
        let ranked = meetings
            .filter { (meetingScores[$0.id] ?? 0) >= threshold }
            .sorted { (meetingScores[$0.id] ?? 0) > (meetingScores[$1.id] ?? 0) }
            .prefix(maxMeetings)
        guard !ranked.isEmpty else {
            return "No recorded meetings mention \"\(query)\"."
        }

        var sections: [String] = []
        var remaining = budget - 20
        let perMeeting = max(120, remaining / ranked.count)
        for meeting in ranked {
            var section = Self.meetingLine(meeting, includeID: includeIDs)
            if let overview = meeting.summary?.overview, !overview.isEmpty {
                section += "\nSummary: " + estimator.truncate(overview, toTokens: perMeeting / 3)
            }
            let lines = await lines(of: meeting.id)
            let windows = await windows(of: meeting.id)
            let hitWindows = (bestWindows[meeting.id] ?? [])
                .sorted { $0.score > $1.score }
                .prefix(passagesPerMeeting)
                .map { windows[$0.window].lines }
            let passages = Self.selectPassages(
                hits: hitWindows,
                lines: lines,
                budget: perMeeting - estimator.tokens(section),
                estimator: estimator
            )
            if !passages.isEmpty {
                section += "\nPassages:\n" + passages.joined(separator: "\n...\n")
            }
            let cost = estimator.tokens(section)
            guard cost <= remaining else { break }
            remaining -= cost
            sections.append(section)
        }
        // An empty string would read to the model as a tool failure rather than as no match.
        guard !sections.isEmpty else { return "No recorded meetings mention \"\(query)\"." }
        return sections.joined(separator: "\n\n")
    }

    func listMeetings(from: Date?, to: Date?, budget: Int, estimator: TokenEstimator) async -> String {
        let meetings = await digests().filter { Self.isInRange($0.date, from: from, to: to) }
        guard !meetings.isEmpty else { return "There are no recorded meetings in that date range." }
        var lines: [String] = []
        var used = 0
        for meeting in meetings {
            var line = "- " + Self.meetingLine(meeting)
            if let overview = meeting.summary?.overview, !overview.isEmpty {
                line += ": " + estimator.truncate(overview, toTokens: 60)
            }
            let cost = estimator.tokens(line) + 1
            guard used + cost <= budget else {
                lines.append("(\(meetings.count - lines.count) more not shown)")
                break
            }
            used += cost
            lines.append(line)
        }
        return "\(meetings.count) meeting\(meetings.count == 1 ? "" : "s"), newest first:\n" + lines.joined(separator: "\n")
    }

    nonisolated static func meetingLine(_ meeting: MeetingDigest, includeID: Bool = false) -> String {
        let line = "\"\(meeting.title)\" (\(Prompts.shortDate(meeting.date)), \(Prompts.durationText(meeting.duration)))"
        return includeID ? line + ", id \(meeting.id.uuidString)" : line
    }

    nonisolated static func isInRange(_ date: Date, from: Date?, to: Date?) -> Bool {
        if let from, date < from { return false }
        if let to, date > to { return false }
        return true
    }

    // MARK: Helpers

    /// Takes hit windows in rank order, widens each by one line on both sides, and keeps
    /// adding until the rendered passages would exceed `budget`. Returns each passage rendered.
    nonisolated static func selectPassages(
        hits: [Range<Int>],
        lines: [TranscriptLine],
        budget: Int,
        estimator: TokenEstimator
    ) -> [String] {
        var positions: [Int] = []
        var accepted: [ClosedRange<Int>] = []
        for hit in hits {
            let candidate = PassageRanker.contextWindows(around: positions + Array(hit), radius: 1, count: lines.count)
            let cost = candidate.reduce(0) { total, range in
                total + estimator.tokens(TranscriptFormat.render(lines[range])) + 2
            }
            if cost > budget {
                if accepted.isEmpty, let first = candidate.first, !hit.isEmpty {
                    // Even one passage is too long: keep the matched lines, cut the rest to fit.
                    let matched = hit.lowerBound...(hit.upperBound - 1)
                    return [trim(first, keeping: matched, toFit: budget, lines: lines, estimator: estimator)]
                }
                break
            }
            positions += Array(hit)
            accepted = candidate
        }
        return accepted.map { TranscriptFormat.render(lines[$0]) }
    }

    /// Context lines go first, since the matched lines are what the caller asked about. Only
    /// when the matched lines alone are too long are they cut from the end, and a single line
    /// that still does not fit is truncated (after its timestamp and speaker, which citations need).
    private nonisolated static func trim(
        _ range: ClosedRange<Int>,
        keeping matched: ClosedRange<Int>,
        toFit budget: Int,
        lines: [TranscriptLine],
        estimator: TokenEstimator
    ) -> String {
        func fits(_ candidate: ClosedRange<Int>) -> Bool {
            estimator.tokens(TranscriptFormat.render(lines[candidate])) <= budget
        }
        let matched = max(matched.lowerBound, range.lowerBound)...min(matched.upperBound, range.upperBound)
        let attempts = [
            range,
            matched.lowerBound...range.upperBound,
            range.lowerBound...matched.upperBound,
            matched,
        ]
        if let fitting = attempts.first(where: fits) {
            return TranscriptFormat.render(lines[fitting])
        }
        var upper = matched.upperBound
        while upper > matched.lowerBound, !fits(matched.lowerBound...upper) {
            upper -= 1
        }
        let kept = matched.lowerBound...upper
        guard fits(kept) else {
            return estimator.truncate(TranscriptFormat.render(lines[matched.lowerBound]), toTokens: budget)
        }
        return TranscriptFormat.render(lines[kept])
    }

    private func windows(of id: UUID) async -> [Window] {
        if let windows = cachedWindows[id] { return windows }
        let lines = await lines(of: id)
        var windows: [Window] = []
        var start = 0
        while start < lines.count {
            let end = min(start + Self.windowSize, lines.count)
            let text = lines[start..<end].map { TranscriptFormat.collapseWhitespace($0.text) }.joined(separator: " ")
            windows.append(Window(lines: start..<end, text: text))
            if end == lines.count { break }
            start += Self.windowStride
        }
        cachedWindows[id] = windows
        return windows
    }

    /// Vectors for the given window indices (all when nil), computed once per window.
    private func vectors(meeting: UUID, windows: [Window], only indices: [Int]?) -> [[Double]?] {
        guard let embedding = language.flatMap(loadEmbedding) else {
            return Array(repeating: nil, count: windows.count)
        }
        var cache = cachedVectors[meeting] ?? [:]
        for index in indices ?? Array(windows.indices) where cache[index] == nil {
            if let vector = embedding.vector(for: windows[index].text) {
                cache[index] = vector
            }
        }
        cachedVectors[meeting] = cache
        return windows.indices.map { cache[$0] }
    }

    /// Embeds the query in the language of the corpus. Returns nil when no sentence
    /// embedding exists for that language, which turns ranking into pure keyword matching.
    private func vector(for query: String, sampleText: String) -> [Double]? {
        if language == nil {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(String(sampleText.prefix(2000)) + " " + query)
            language = recognizer.dominantLanguage ?? .english
        }
        guard let language, let embedding = loadEmbedding(language) else { return nil }
        return embedding.vector(for: query)
    }

    private func embedding(for text: String) -> NLEmbedding? {
        language.flatMap(loadEmbedding)
    }

    private func loadEmbedding(_ language: NLLanguage) -> NLEmbedding? {
        if let embedding = embeddings[language] { return embedding }
        guard !missingEmbeddings.contains(language) else { return nil }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            missingEmbeddings.insert(language)
            return nil
        }
        embeddings[language] = embedding
        return embedding
    }
}
