import Foundation
import Testing
@testable import Memoir

struct LibraryLogicTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func line(_ speaker: Speaker, _ start: TimeInterval, _ text: String = "t") -> TranscriptLine {
        TranscriptLine(speaker: speaker, start: start, end: start + 1, text: text)
    }

    @Test func blocksGroupConsecutiveSpeakers() {
        let lines = [line(.me, 0), line(.me, 2), line(.others, 4), line(.me, 6)]
        let blocks = TranscriptGrouping.blocks(lines)
        #expect(blocks.map(\.speaker) == [.me, .others, .me])
        #expect(blocks.map { $0.lines.count } == [2, 1, 1])
    }

    @Test func currentLineAndMatches() {
        let lines = [line(.me, 0, "Budget plan"), line(.others, 10, "budget again"), line(.me, 20, "Done")]
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 12) == lines[1].id)
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 0) == lines[0].id)
        #expect(TranscriptGrouping.matchingIDs(in: lines, query: "BUDGET") == [lines[0].id, lines[1].id])
        #expect(TranscriptGrouping.matchingIDs(in: lines, query: " ").isEmpty)
    }

    @Test func monthGridRespectsFirstWeekday() {
        var cal = calendar
        let november = cal.date(from: DateComponents(year: 2026, month: 11, day: 18))!
        cal.firstWeekday = 1
        let sunday = MonthGrid(containing: november, calendar: cal)
        #expect(cal.component(.day, from: sunday.weeks[0][0]) == 1)
        #expect(sunday.weeks.count == 5)
        #expect(MonthGrid.weekdaySymbols(calendar: cal).first == "S")

        cal.firstWeekday = 2
        let monday = MonthGrid(containing: november, calendar: cal)
        #expect(cal.component(.day, from: monday.weeks[0][0]) == 26)
        #expect(monday.weeks.allSatisfy { $0.count == 7 })
        #expect(MonthGrid.weekdayNames(calendar: cal).first == "Monday")
    }

    @Test func dayTitlesAndGroups() {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15))!
        let en = Locale(identifier: "en_US")
        #expect(MeetingGrouping.title(for: cal.startOfDay(for: now), now: now, calendar: cal, locale: en) == "Today")
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        #expect(MeetingGrouping.title(for: yesterday, now: now, calendar: cal, locale: en) == "Yesterday")
        let older = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        #expect(MeetingGrouping.title(for: older, now: now, calendar: cal, locale: en) == "Monday, November 2")

        let a = Meeting(title: "A", startDate: now)
        let b = Meeting(title: "B", startDate: now.addingTimeInterval(-3600))
        let c = Meeting(title: "C", startDate: yesterday)
        let groups = MeetingGrouping.groups([c, b, a], calendar: cal)
        #expect(groups.count == 2)
        #expect(groups[0].meetings.map(\.title) == ["A", "B"])
    }

    @Test func searchMatchesAllFields() {
        let meeting = Meeting(title: "Roadmap")
        meeting.attendees = ["Jonas Weber"]
        meeting.summary = MeetingSummary(overview: "Pricing discussion")
        meeting.segments = [TranscriptSegment(line: line(.me, 0, "the quarterly forecast"))]
        #expect(MeetingGrouping.matches(meeting, query: "roadmap"))
        #expect(MeetingGrouping.matches(meeting, query: "weber"))
        #expect(MeetingGrouping.matches(meeting, query: "pricing"))
        #expect(MeetingGrouping.matches(meeting, query: "forecast"))
        #expect(MeetingGrouping.matches(meeting, query: ""))
        #expect(!MeetingGrouping.matches(meeting, query: "zebra"))
    }
}
