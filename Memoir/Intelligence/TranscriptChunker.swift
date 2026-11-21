import Foundation

/// Approximate token counting. Exact counting (`SystemLanguageModel.tokenCount(for:)`) needs
/// macOS 26.4 and is async, so budgets are planned with this estimate, optionally calibrated
/// once against the real tokenizer.
nonisolated struct TokenEstimator: Sendable, Equatable {
    /// Multiplier applied to the raw character heuristic.
    var scale: Double = 1

    /// Deliberately pessimistic: ASCII text averages about 4 characters per token, other
    /// scripts (accented Latin, CJK) often take a token per character or more.
    func tokens(_ text: String) -> Int {
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        let raw = Double(ascii) / 3.2 + Double(other) * 0.9
        return Int((raw * scale).rounded(.up))
    }

    /// An estimator whose result for `sample` matches `actualTokens`, plus a safety margin.
    /// The scale is clamped so a weird sample cannot make budgets absurd.
    static func calibrated(sample: String, actualTokens: Int) -> TokenEstimator {
        let raw = TokenEstimator().tokens(sample)
        guard raw > 50, actualTokens > 0 else { return TokenEstimator() }
        let scale = (Double(actualTokens) / Double(raw)) * 1.1
        return TokenEstimator(scale: min(max(scale, 0.5), 2))
    }

    /// Cuts `text` so it estimates at or below `tokens`, at a word boundary where possible.
    func truncate(_ text: String, toTokens limit: Int) -> String {
        guard tokens(text) > limit else { return text }
        guard limit > 0 else { return "" }
        var low = 0
        var high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            if tokens(String(text.prefix(mid))) + 1 <= limit { low = mid } else { high = mid - 1 }
        }
        var cut = text.prefix(low)
        if let space = cut.lastIndex(where: \.isWhitespace), cut.distance(from: space, to: cut.endIndex) < 40 {
            cut = cut[..<space]
        }
        return cut.trimmingCharacters(in: .whitespaces) + "..."
    }
}

/// Splits a transcript into pieces that each fit a token budget.
nonisolated enum TranscriptChunker {
    nonisolated struct Chunk: Sendable, Equatable {
        /// Indices into the input lines.
        var lines: Range<Int>
        /// The rendered lines, one per text line.
        var text: String
        var tokens: Int
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Lines are never split across chunks. A single line that alone exceeds the budget gets
    /// a chunk of its own with its text truncated, since the alternative is a chunk the model
    /// cannot accept at all.
    static func chunks(
        _ lines: [TranscriptLine],
        budget: Int,
        estimator: TokenEstimator = TokenEstimator()
    ) -> [Chunk] {
        guard !lines.isEmpty else { return [] }
        var rendered = lines.map { TranscriptFormat.render($0) }
        for index in rendered.indices where estimator.tokens(rendered[index]) > budget {
            rendered[index] = estimator.truncate(rendered[index], toTokens: budget)
        }
        let ranges = pack(rendered.map(estimator.tokens), budget: budget)
        return ranges.map { range in
            let text = rendered[range].joined(separator: "\n")
            return Chunk(
                lines: range,
                text: text,
                tokens: estimator.tokens(text),
                start: lines[range.lowerBound].start,
                end: lines[range.upperBound - 1].end
            )
        }
    }

    /// Groups consecutive items of the given sizes into ranges whose sum (plus one token per
    /// separator) stays within `budget`. Uses the minimal number of groups a greedy fill
    /// needs, then evens them out so the last group is not a tiny remainder.
    static func pack(_ sizes: [Int], budget: Int) -> [Range<Int>] {
        guard !sizes.isEmpty else { return [] }
        let budget = max(budget, 1)
        let greedy = greedyPack(sizes, budget: budget)
        guard greedy.count > 1 else { return greedy }
        let total = sizes.reduce(0) { $0 + $1 + 1 }
        var target = Int((Double(total) / Double(greedy.count)).rounded(.up))
        while target < budget {
            let balanced = greedyPack(sizes, budget: target)
            if balanced.count <= greedy.count { return balanced }
            target += max(1, budget / 50)
        }
        return greedy
    }

    private static func greedyPack(_ sizes: [Int], budget: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var used = 0
        for (index, size) in sizes.enumerated() {
            let cost = size + 1
            if index > start, used + cost > budget {
                ranges.append(start..<index)
                start = index
                used = 0
            }
            used += cost
        }
        ranges.append(start..<sizes.count)
        return ranges
    }
}
