import Foundation

nonisolated struct TranscriptBlock: Identifiable, Equatable {
    var id: UUID { lines[0].id }
    var speaker: Speaker
    var lines: [TranscriptLine]
    var start: TimeInterval { lines[0].start }
}

nonisolated enum TranscriptGrouping {
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

    /// The line being spoken at `time`: the last one that has started. `lines` must be sorted.
    static func currentLineID(in lines: [TranscriptLine], at time: TimeInterval) -> UUID? {
        lines.last { $0.start <= time + 0.05 }?.id
    }

    static func matchingIDs(in lines: [TranscriptLine], query: String) -> [UUID] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return lines.filter { $0.text.localizedStandardContains(query) }.map(\.id)
    }
}
