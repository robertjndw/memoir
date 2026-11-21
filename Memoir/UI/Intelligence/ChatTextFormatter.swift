import SwiftUI

/// Turns assistant text into styled, optionally clickable text.
enum ChatTextFormatter {
    static let seekScheme = "memoir-seek"

    static func attributed(_ text: String, linkCitations: Bool) -> AttributedString {
        let segments = CitationParser.segments(in: bulleted(text))

        var source = ""
        for segment in segments {
            switch segment {
            case .text(let plain):
                source += plain
            case .timestamp(let label, let seconds):
                source += linkCitations
                    ? "[\u{00A0}\(label)\u{00A0}](\(seekScheme)://\(Int(seconds)))"
                    : "[\(label)]"
            }
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var result = try? AttributedString(markdown: source, options: options) else {
            return fallback(segments, linkCitations: linkCitations)
        }
        let ranges = result.runs.filter { $0.link != nil }.map(\.range)
        for range in ranges {
            result[range].backgroundColor = Color.accentColor.opacity(0.14)
        }
        return result
    }

    static func seconds(from url: URL) -> TimeInterval? {
        guard url.scheme == seekScheme, let host = url.host(), let value = Int(host) else { return nil }
        return TimeInterval(value)
    }

    // Inline-only parsing leaves list markers as literal characters, so swap them for bullets.
    private static func bulleted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return "\u{2022} " + trimmed.dropFirst(2)
            }
            return String(line)
        }.joined(separator: "\n")
    }

    private static func fallback(_ segments: [CitationSegment], linkCitations: Bool) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let plain):
                result += AttributedString(plain)
            case .timestamp(let label, let seconds):
                var piece = AttributedString(linkCitations ? "\u{00A0}\(label)\u{00A0}" : "[\(label)]")
                if linkCitations {
                    piece.link = URL(string: "\(seekScheme)://\(Int(seconds))")
                    piece.backgroundColor = Color.accentColor.opacity(0.14)
                }
                result += piece
            }
        }
        return result
    }
}
