import Foundation
import Testing
@testable import Memoir

struct IntelligenceUITests {
    @Test func parsesCitations() {
        let segments = CitationParser.segments(in: "Agreed [12:34] and later [1:02:03].")
        #expect(segments == [
            .text("Agreed "),
            .timestamp(label: "12:34", seconds: 754),
            .text(" and later "),
            .timestamp(label: "1:02:03", seconds: 3723),
            .text("."),
        ])
    }

    @Test func ignoresMalformedCitations() {
        for text in ["[99:99:99]", "[abc]", "[12:5]", "[1:2:3]", "[]", "[12:60]", "[12:34", "[1:99:00]"] {
            #expect(CitationParser.segments(in: text) == [.text(text)], "\(text)")
        }
    }

    @Test func keepsPlainTextAndEmptyInput() {
        #expect(CitationParser.segments(in: "").isEmpty)
        #expect(CitationParser.segments(in: "no [links] here") == [.text("no [links] here")])
    }

    @Test func adjacentCitations() {
        #expect(CitationParser.segments(in: "[0:05][0:10]") == [
            .timestamp(label: "0:05", seconds: 5),
            .timestamp(label: "0:10", seconds: 10),
        ])
    }

    @MainActor @Test func summaryMarkdownOmitsEmptySections() {
        let summary = MeetingSummary(
            overview: "Short.", decisions: ["Ship it."],
            actionItems: [.init(task: "Write docs", owner: "Sam")]
        )
        #expect(summary.markdown == "Short.\n\n## Decisions\n- Ship it.\n\n## Action Items\n- [ ] Write docs (Sam)")
    }
}
