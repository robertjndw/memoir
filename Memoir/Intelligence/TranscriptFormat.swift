import Foundation

/// Rendering of transcript lines and timestamp citations. The `[mm:ss]` form is shared with the
/// UI, which turns citations in chat answers into seek links, so render and parse must agree.
nonisolated enum TranscriptFormat {
    /// `mm:ss` below one hour, `h:mm:ss` from one hour on.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(twoDigits(minutes)):\(twoDigits(secs))"
    }

    static func citation(_ seconds: TimeInterval) -> String {
        "[\(timestamp(seconds))]"
    }

    /// One compact line: `[mm:ss] Speaker: text`, with whitespace collapsed. `othersName`
    /// replaces the "Others" label when the other side is known to be one person.
    static func render(_ line: TranscriptLine, othersName: String? = nil) -> String {
        let label = line.speaker == .others ? (othersName ?? line.speaker.label) : line.speaker.label
        return "\(citation(line.start)) \(label): \(collapseWhitespace(line.text))"
    }

    static func render(_ lines: some Sequence<TranscriptLine>) -> String {
        lines.map { render($0) }.joined(separator: "\n")
    }

    /// Seconds for every `[mm:ss]` or `[h:mm:ss]` citation in `text`, in order of appearance.
    static func citations(in text: String) -> [TimeInterval] {
        text.matches(of: citationPattern).compactMap { match in
            seconds(fromTimestamp: String(match.output.1))
        }
    }

    /// Parses `mm:ss` or `h:mm:ss`. Minutes and seconds must be below 60 except for the leading
    /// field, so `75:10` (how some models write long offsets) still parses.
    static func seconds(fromTimestamp timestamp: String) -> TimeInterval? {
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        switch values.count {
        case 2:
            guard values[1] < 60 else { return nil }
            return TimeInterval(values[0] * 60 + values[1])
        case 3:
            guard values[1] < 60, values[2] < 60 else { return nil }
            return TimeInterval(values[0] * 3600 + values[1] * 60 + values[2])
        default:
            return nil
        }
    }

    /// Models sometimes cite several positions in one bracket (`[01:10, 02:30]`) or use
    /// parentheses. Rewrites those into separate `[mm:ss]` citations so the UI can link them.
    static func normalizeCitations(_ text: String) -> String {
        text.replacing(groupedCitationPattern) { match in
            let inner = match.output.1
            let stamps = inner.split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { $0.hasPrefix("at ") ? String($0.dropFirst(3)) : $0 }
            guard !stamps.isEmpty, stamps.allSatisfy({ seconds(fromTimestamp: $0) != nil }) else {
                return String(match.output.0)
            }
            return stamps.map { "[\($0)]" }.joined(separator: " ")
        }
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    nonisolated(unsafe) private static let citationPattern = /\[(\d{1,2}(?::\d{2}){1,2})\]/

    nonisolated(unsafe) private static let groupedCitationPattern =
        /[\[\(]((?:at )?\d{1,2}(?::\d{2}){1,2}(?:\s*[,;]\s*(?:at )?\d{1,2}(?::\d{2}){1,2})*)[\]\)]/
}
