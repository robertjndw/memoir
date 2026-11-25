import Foundation

/// A stretch of audio the diarizer gave to one cluster. Seconds on the recording timeline.
nonisolated struct SpeakerTurn: Sendable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var cluster: Int
}

/// Turns timed words and speaker turns into transcript lines. Knows nothing about the models,
/// so all the judgement calls about who said what live here where they can be tested.
nonisolated enum TranscriptAssembler {
    /// How to decide who said a piece of text.
    enum Attribution: Sendable {
        /// Everything belongs to one side and nobody gets a voice.
        case speaker(Speaker)
        /// Each piece goes to the diarized cluster it overlaps. `user` is the cluster that is the
        /// user (mixed files only); every other cluster becomes `others` with a voice.
        case turns([SpeakerTurn], user: Int?, others: Speaker)
        /// Each piece keeps the speaker and voice of the existing line it overlaps, so a mixed
        /// file transcribed again without speaker identification does not lose its sides.
        case lines([TranscriptLine], fallback: Speaker)
    }

    /// Who said something before voices are numbered. `cluster` is set for diarized speakers,
    /// `voice` only for voices carried over from an earlier transcript.
    struct Owner: Sendable, Hashable {
        var speaker: Speaker
        var cluster: Int?
        var voice: Int?
    }

    struct Draft: Sendable, Hashable {
        var id = UUID()
        var owner: Owner
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// A gap this long between two words starts a new line, like a pause does in the live
    /// transcript.
    static let pause: TimeInterval = 1.5
    /// Lines without punctuation or pauses still end eventually so they stay readable.
    static let maxLineDuration: TimeInterval = 30
    /// A single word this short that the diarizer gave to someone else between two words of
    /// the same person is almost always a boundary error, not a one-word interjection.
    static let strayWordDuration: TimeInterval = 0.6

    // MARK: - Lines

    /// New text from a transcription: words are grouped into lines that end at a change of
    /// speaker, at the end of a sentence, at a long pause, or once they get too long.
    static func lines(from words: [TimedWord], attribution: Attribution) -> [Draft] {
        let words = words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        let owners = smoothed(words.map { owner(of: $0.start, $0.end, attribution) }, words: words)

        var drafts: [Draft] = []
        var current: [TimedWord] = []
        var currentOwner: Owner?

        func flush() {
            guard let currentOwner, let first = current.first, let last = current.last else { return }
            drafts.append(Draft(owner: currentOwner, start: first.start, end: max(first.start, last.end), text: join(current, separator: " ")))
            current = []
        }

        for (word, owner) in zip(words, owners) {
            if let last = current.last, let first = current.first {
                let breaks = owner != currentOwner
                    || word.start - last.end > pause
                    || endsSentence(last.text)
                    || word.end - first.start > maxLineDuration
                if breaks { flush() }
            }
            current.append(word)
            currentOwner = owner
        }
        flush()
        return drafts
    }

    /// Kept text: each existing line stays as it is unless its words turn out to belong to more
    /// than one person, in which case it is split where the speaker changes. Lines without word
    /// timings go whole to whoever overlaps them most.
    static func lines(
        keeping lines: [TranscriptLine],
        words: [UUID: [TimedWord]],
        attribution: Attribution
    ) -> [Draft] {
        var drafts: [Draft] = []
        for line in lines where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lineWords = (words[line.id] ?? [])
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.start < $1.start }
            guard !lineWords.isEmpty else {
                drafts.append(Draft(id: line.id, owner: owner(of: line.start, line.end, attribution), start: line.start, end: line.end, text: line.text))
                continue
            }
            let owners = smoothed(lineWords.map { owner(of: $0.start, $0.end, attribution) }, words: lineWords)
            if let first = owners.first, owners.allSatisfy({ $0 == first }) {
                drafts.append(Draft(id: line.id, owner: first, start: line.start, end: line.end, text: line.text))
                continue
            }
            // Languages written without spaces must not get spaces between their words.
            let separator = line.text.contains(" ") ? " " : ""
            var runStart = 0
            for index in 1...owners.count where index == owners.count || owners[index] != owners[runStart] {
                let run = Array(lineWords[runStart..<index])
                drafts.append(Draft(owner: owners[runStart], start: run[0].start, end: max(run[0].start, run[run.count - 1].end), text: join(run, separator: separator)))
                runStart = index
            }
        }
        return drafts
    }

    /// Puts the drafts of all sides in time order and numbers the diarized voices from 1 in the
    /// order they first speak.
    static func finish(_ drafts: [Draft]) -> [TranscriptLine] {
        var voices: [Int: Int] = [:]
        let taken = Set(drafts.compactMap { $0.owner.cluster == nil ? $0.owner.voice : nil })
        var next = 1
        return drafts
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            .map { draft in
                var voice = draft.owner.voice
                if let cluster = draft.owner.cluster {
                    if let known = voices[cluster] {
                        voice = known
                    } else {
                        while taken.contains(next) { next += 1 }
                        voices[cluster] = next
                        voice = next
                        next += 1
                    }
                }
                return TranscriptLine(id: draft.id, speaker: draft.owner.speaker, start: draft.start, end: draft.end, text: draft.text, voice: voice)
            }
    }

    // MARK: - Finding the user

    /// Below this the match is too thin to call a cluster the user.
    static let minimumUserOverlap: TimeInterval = 1
    /// Share of the user's own speech the cluster must cover, and share of the cluster's speech
    /// that must fall on the user's lines. The second keeps someone who talks over everything
    /// from being taken for the user just because they talk the most.
    static let minimumUserShare = 0.25

    /// The cluster that is the user in a mixed file: the one that overlaps the user's live lines
    /// the most, if that overlap is convincing. Uses the word timings where a line has them,
    /// because live lines also span the pauses where someone else may be talking.
    static func userCluster(
        in turns: [SpeakerTurn],
        lines: [TranscriptLine],
        words: [UUID: [TimedWord]] = [:]
    ) -> Int? {
        let userSpeech: [(start: TimeInterval, end: TimeInterval)] = lines
            .filter { $0.speaker == .me }
            .flatMap { line -> [(start: TimeInterval, end: TimeInterval)] in
                if let lineWords = words[line.id], !lineWords.isEmpty {
                    return lineWords.map { ($0.start, $0.end) }
                }
                return [(line.start, line.end)]
            }
            .filter { $0.end > $0.start }
        let userTotal = userSpeech.reduce(0) { $0 + ($1.end - $1.start) }
        guard userTotal > 0, !turns.isEmpty else { return nil }

        var overlap: [Int: TimeInterval] = [:]
        var spoken: [Int: TimeInterval] = [:]
        for turn in turns {
            spoken[turn.cluster, default: 0] += max(0, turn.end - turn.start)
            for range in userSpeech {
                overlap[turn.cluster, default: 0] += max(0, min(turn.end, range.end) - max(turn.start, range.start))
            }
        }
        guard let best = overlap.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) else { return nil }
        let clusterTotal = spoken[best.key] ?? 0
        guard best.value >= minimumUserOverlap,
              best.value / userTotal >= minimumUserShare,
              clusterTotal > 0, best.value / clusterTotal >= minimumUserShare
        else { return nil }
        return best.key
    }

    // MARK: - Attribution

    static func owner(of start: TimeInterval, _ end: TimeInterval, _ attribution: Attribution) -> Owner {
        switch attribution {
        case .speaker(let speaker):
            return Owner(speaker: speaker)
        case .turns(let turns, let user, let others):
            guard let cluster = cluster(of: start, end, in: turns) else { return Owner(speaker: others) }
            if cluster == user { return Owner(speaker: .me) }
            return Owner(speaker: others, cluster: cluster)
        case .lines(let lines, let fallback):
            guard let line = line(of: start, end, in: lines) else { return Owner(speaker: fallback) }
            return Owner(speaker: line.speaker, voice: line.speaker == .me ? nil : line.voice)
        }
    }

    /// The cluster that overlaps the range the most. Speech the diarizer did not cover goes to
    /// the nearest turn instead of being dropped: it is usually a word clipped at a turn edge.
    static func cluster(of start: TimeInterval, _ end: TimeInterval, in turns: [SpeakerTurn]) -> Int? {
        guard !turns.isEmpty else { return nil }
        var overlap: [Int: TimeInterval] = [:]
        for turn in turns where turn.end > start && turn.start < end {
            overlap[turn.cluster, default: 0] += min(turn.end, end) - max(turn.start, start)
        }
        if let best = overlap.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }), best.value > 0 {
            return best.key
        }
        let middle = (start + end) / 2
        return turns.min { distance(middle, to: $0) < distance(middle, to: $1) }?.cluster
    }

    private static func line(of start: TimeInterval, _ end: TimeInterval, in lines: [TranscriptLine]) -> TranscriptLine? {
        let overlapping = lines
            .map { ($0, min($0.end, end) - max($0.start, start)) }
            .filter { $0.1 > 0 }
        if let best = overlapping.max(by: { $0.1 < $1.1 }) { return best.0 }
        let middle = (start + end) / 2
        // Live lines leave gaps between them, but a word far from any line is not theirs.
        guard let nearest = lines.min(by: { distance(middle, to: $0.start, $0.end) < distance(middle, to: $1.start, $1.end) }),
              distance(middle, to: nearest.start, nearest.end) <= pause
        else { return nil }
        return nearest
    }

    private static func distance(_ time: TimeInterval, to turn: SpeakerTurn) -> TimeInterval {
        distance(time, to: turn.start, turn.end)
    }

    private static func distance(_ time: TimeInterval, to start: TimeInterval, _ end: TimeInterval) -> TimeInterval {
        if time < start { return start - time }
        if time > end { return time - end }
        return 0
    }

    private static func smoothed(_ owners: [Owner], words: [TimedWord]) -> [Owner] {
        guard owners.count >= 3 else { return owners }
        var owners = owners
        for index in 1..<(owners.count - 1)
        where owners[index - 1] == owners[index + 1] && owners[index] != owners[index - 1]
            && words[index].end - words[index].start < strayWordDuration
        {
            owners[index] = owners[index - 1]
        }
        return owners
    }

    // MARK: - Text

    static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
        guard let last = trimmed.last else { return false }
        return ".?!…。？！".contains(last)
    }

    private static func join(_ words: [TimedWord], separator: String) -> String {
        words.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: separator)
    }
}
