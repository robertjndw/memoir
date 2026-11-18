import Foundation

/// The on-device model often copies the timestamp of a neighboring context line instead of
/// the line that supports its claim. This re-points a citation, but only when the cited line
/// shares (almost) nothing with the claim and another line of the meeting clearly matches,
/// so a correct citation is never moved.
nonisolated enum CitationRepair {
    static let citedCeiling = 0.2
    static let bestFloor = 0.45

    static func repair(_ answer: String, lines: [TranscriptLine]) -> String {
        guard !lines.isEmpty else { return answer }
        let lineTerms = lines.map { PassageRanker.terms($0.text) }
        let idf = PassageRanker.inverseDocumentFrequency(lineTerms)
        let stamps = lines.map { TranscriptFormat.timestamp($0.start) }

        var result = ""
        var cursor = answer.startIndex
        var previousClaim: [String] = []
        var lastStamp: String?
        for match in answer.matches(of: citation) {
            var claim = PassageRanker.terms(String(claimText(before: match.range.lowerBound, in: answer)))
            if claim.isEmpty { claim = previousClaim }
            previousClaim = claim
            let gap = answer[cursor..<match.range.lowerBound]
            result += gap
            cursor = match.range.upperBound

            // "[1:05]" and "[01:05]" are the same position; compare in canonical form.
            let raw = String(match.output.1)
            let cited = TranscriptFormat.seconds(fromTimestamp: raw).map(TranscriptFormat.timestamp) ?? raw
            var stamp = cited
            if claim.count >= 2 {
                let scores = lineTerms.map { PassageRanker.keywordScore(query: claim, passage: $0, idf: idf) }
                let citedScore = stamps.indices.filter { stamps[$0] == cited }.map { scores[$0] }.max() ?? 0
                if let best = scores.indices.max(by: { scores[$0] < scores[$1] }),
                   citedScore < citedCeiling, scores[best] >= bestFloor {
                    stamp = stamps[best]
                }
            }
            // Repairing can turn "[a][b]" into "[a][a]".
            if gap.isEmpty, stamp == lastStamp { continue }
            lastStamp = stamp
            result += "[\(stamp)]"
        }
        result += answer[cursor...]
        return result
    }

    /// The sentence a citation belongs to: from the previous sentence end (or citation) up to
    /// the citation. A period counts only when followed by whitespace, so "4.5" stays intact.
    private static func claimText(before index: String.Index, in text: String) -> Substring {
        var start = text.startIndex
        var position = index
        while position > text.startIndex {
            let previous = text.index(before: position)
            let character = text[previous]
            if character == "\n" || character == "]" {
                start = position
                break
            }
            if ".!?".contains(character), position < index, text[position].isWhitespace {
                start = position
                break
            }
            position = previous
        }
        return text[start..<index]
    }

    nonisolated(unsafe) private static let citation = /\[(\d{1,2}(?::\d{2}){1,2})\]/
}
