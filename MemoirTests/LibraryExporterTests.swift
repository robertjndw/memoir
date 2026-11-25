import Foundation
import Testing
@testable import Memoir

struct LibraryExporterTests {
    private let locale = Locale(identifier: "en_US")
    private let zone = TimeZone(identifier: "UTC")!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func export(summary: MeetingSummary?, lines: [TranscriptLine], attendees: [String] = ["Maya", "Jonas"]) -> String {
        MeetingExporter.markdown(
            title: "Design Review", date: date, duration: 65 * 60, attendees: attendees,
            summary: summary, lines: lines, locale: locale, timeZone: zone
        )
    }

    @Test func fullMeeting() {
        let summary = MeetingSummary(
            title: "x", overview: "All good.", keyPoints: ["One"], decisions: ["Ship"],
            actionItems: [.init(task: "Write", owner: "Maya"), .init(task: "Review", owner: nil)]
        )
        let lines = [
            TranscriptLine(speaker: .me, start: 5, end: 8, text: "Hello"),
            TranscriptLine(speaker: .others, start: 3725, end: 3730, text: "Bye"),
        ]
        let text = export(summary: summary, lines: lines)
        #expect(text.hasPrefix("# Design Review\n"))
        #expect(text.contains("- **Duration:** 1 hr, 5 min"))
        #expect(text.contains("- **Attendees:** Maya, Jonas"))
        #expect(text.contains("## Summary\n\nAll good."))
        #expect(text.contains("- [ ] Write (Maya)"))
        #expect(text.contains("- [ ] Review\n"))
        #expect(text.contains("[00:05] **You:** Hello"))
        #expect(text.contains("[1:02:05] **Others:** Bye"))
        #expect(!text.contains("\u{2014}"))
    }

    @Test func identifiedAndNamedSpeakersAreExported() {
        let lines = [
            TranscriptLine(speaker: .others, start: 1, end: 2, text: "Hi", voice: 2),
            TranscriptLine(speaker: .others, start: 3, end: 4, text: "Hello", voice: 1, name: "Dana"),
        ]
        let text = export(summary: nil, lines: lines)
        #expect(text.contains("[00:01] **Speaker 2:** Hi"))
        #expect(text.contains("[00:03] **Dana:** Hello"))
        #expect(!text.contains("**Others:**"))
    }

    @Test func withoutSummary() {
        let text = export(summary: nil, lines: [TranscriptLine(speaker: .unknown, start: 0, end: 1, text: "Hi")])
        #expect(!text.contains("## Summary"))
        #expect(text.contains("[00:00] **Speaker:** Hi"))
    }

    @Test func withoutTranscript() {
        let text = export(summary: MeetingSummary(overview: "Short."), lines: [], attendees: [])
        #expect(text.contains("## Summary"))
        #expect(text.contains("_No transcript._"))
        #expect(!text.contains("Attendees"))
    }

    @Test func fileNameIsSanitized() {
        #expect(MeetingExporter.fileName(for: "Q3/Q4: plan") == "Q3-Q4- plan")
        #expect(MeetingExporter.fileName(for: "  ") == "Meeting")
    }

    @Test func formatting() {
        #expect(LibraryFormat.length(42 * 60) == "42 min")
        #expect(LibraryFormat.timecode(65) == "01:05")
        #expect(LibraryFormat.timecode(3600) == "1:00:00")
    }
}
