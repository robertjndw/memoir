import Foundation

nonisolated enum CitationSegment: Equatable, Sendable {
    case text(String)
    /// `label` is the text between the brackets, as the model wrote it.
    case timestamp(label: String, seconds: TimeInterval)
}

/// Splits an answer into plain text and `[mm:ss]` / `[h:mm:ss]` citations.
nonisolated enum CitationParser {
    static func segments(in text: String) -> [CitationSegment] {
        let characters = Array(text)
        var result: [CitationSegment] = []
        var pending = ""
        var index = 0

        while index < characters.count {
            if characters[index] == "[",
               let close = closingBracket(in: characters, after: index),
               let seconds = seconds(from: String(characters[(index + 1)..<close])) {
                if !pending.isEmpty {
                    result.append(.text(pending))
                    pending = ""
                }
                result.append(.timestamp(label: String(characters[(index + 1)..<close]), seconds: seconds))
                index = close + 1
            } else {
                pending.append(characters[index])
                index += 1
            }
        }
        if !pending.isEmpty { result.append(.text(pending)) }
        return result
    }

    /// Seconds for `m:ss`, `mm:ss` or `h:mm:ss`. Nil for anything else, including out-of-range
    /// minutes or seconds.
    static func seconds(from label: String) -> TimeInterval? {
        let parts = label.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }

        if parts.count == 2 {
            guard parts[0].count <= 3, parts[1].count == 2, numbers[1] < 60 else { return nil }
            return TimeInterval(numbers[0] * 60 + numbers[1])
        }
        guard parts[0].count <= 2, parts[1].count == 2, parts[2].count == 2,
              numbers[1] < 60, numbers[2] < 60
        else { return nil }
        return TimeInterval(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
    }

    private static func closingBracket(in characters: [Character], after open: Int) -> Int? {
        // The longest valid label is "999:59" or "99:59:59", so never scan further than that.
        let limit = min(characters.count, open + 11)
        var index = open + 1
        while index < limit {
            if characters[index] == "]" { return index }
            index += 1
        }
        return nil
    }
}
