import Foundation

nonisolated struct TranscriptBlock: Identifiable, Equatable {
    var id: UUID { lines[0].id }
    var speaker: Speaker
    var lines: [TranscriptLine]
    var start: TimeInterval { lines[0].start }
}

/// One line of the rendered transcript. Rows are flat rather than nested in blocks so every line
/// is a direct child of the lazy stack, which keeps scroll-to-line reliable for lines that have
/// not been materialized yet.
nonisolated struct TranscriptRow: Identifiable, Equatable {
    var line: TranscriptLine
    /// The first line of a speaker turn, which carries the speaker and timestamp header.
    var startsBlock: Bool
    var id: UUID { line.id }
}

nonisolated enum TranscriptGrouping {
    /// How far ahead of the playhead a line counts as current. Highlighting a hair early reads as
    /// in sync, while highlighting late always reads as lagging.
    static let highlightLead: TimeInterval = 0.1

    /// Consecutive lines of the same speaker become one block.
    static func blocks(_ lines: [TranscriptLine]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for line in lines {
            if let last = blocks.last, last.speaker == line.speaker {
                blocks[blocks.count - 1].lines.append(line)
            } else {
                blocks.append(TranscriptBlock(speaker: line.speaker, lines: [line]))
            }
        }
        return blocks
    }

    static func rows(_ lines: [TranscriptLine]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(lines.count)
        for line in lines {
            rows.append(TranscriptRow(line: line, startsBlock: rows.last?.line.speaker != line.speaker))
        }
        return rows
    }

    /// The line being spoken at `time`: the last one that has started. `lines` must be sorted by start.
    ///
    /// A line stays current through the silence after it ends, so the highlight never blinks off
    /// between sentences. With overlapping speakers the one who started last wins. Before the
    /// first line starts there is no current line.
    static func currentLineID(in lines: [TranscriptLine], at time: TimeInterval) -> UUID? {
        currentLineIndex(in: lines, at: time).map { lines[$0].id }
    }

    static func currentLineIndex(in lines: [TranscriptLine], at time: TimeInterval) -> Int? {
        // Binary search for the first line that starts after the playhead. This runs on every
        // playback tick, so it has to stay cheap for multi-hour transcripts.
        let threshold = time + highlightLead
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= threshold {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? low - 1 : nil
    }

    static func matchingIDs(in lines: [TranscriptLine], query: String) -> [UUID] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return lines.filter { $0.text.localizedStandardContains(query) }.map(\.id)
    }
}
