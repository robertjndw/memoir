import Foundation

nonisolated struct TranscriptBlock: Identifiable, Equatable {
    var id: UUID { lines[0].id }
    var speaker: Speaker
    var lines: [TranscriptLine]
    var start: TimeInterval { lines[0].start }
}

/// One row of the rendered transcript: a line, or a marker where the user muted their
/// microphone. Rows are flat rather than nested in blocks so every line is a direct child of the
/// lazy stack, which keeps scroll-to-line reliable for lines that have not been materialized yet.
nonisolated struct TranscriptRow: Identifiable, Equatable {
    enum Content: Equatable {
        case line(TranscriptLine)
        case muted(MutedRange)
    }

    let content: Content
    /// A line that opens a speaker turn shows the speaker and timestamp header. Markers are
    /// always set apart like a new turn.
    let startsBlock: Bool
    /// A line row has the line's ID, so scrolling to a line ID finds its row.
    let id: UUID

    var line: TranscriptLine? {
        if case .line(let line) = content { line } else { nil }
    }

    init(line: TranscriptLine, startsBlock: Bool) {
        content = .line(line)
        self.startsBlock = startsBlock
        id = line.id
    }

    init(marker range: MutedRange) {
        content = .muted(range)
        startsBlock = true
        id = Self.markerID(for: range)
    }

    /// Built from the range instead of random so the row keeps its identity when the rows are
    /// rebuilt.
    private static func markerID(for range: MutedRange) -> UUID {
        let b = withUnsafeBytes(of: range.start.bitPattern) { Array($0) }
            + withUnsafeBytes(of: range.end.bitPattern) { Array($0) }
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }
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

    /// `lines` must be sorted by start. Each muted range gets a marker before the first line
    /// that starts at or after it, and the line after a marker opens a new speaker turn.
    static func rows(_ lines: [TranscriptLine], mutedRanges: [MutedRange] = []) -> [TranscriptRow] {
        let markers = Set(mutedRanges).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(lines.count + markers.count)
        var nextMarker = 0
        for line in lines {
            while nextMarker < markers.count, markers[nextMarker].start <= line.start {
                rows.append(TranscriptRow(marker: markers[nextMarker]))
                nextMarker += 1
            }
            rows.append(TranscriptRow(line: line, startsBlock: rows.last?.line?.speaker != line.speaker))
        }
        for marker in markers[nextMarker...] {
            rows.append(TranscriptRow(marker: marker))
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
