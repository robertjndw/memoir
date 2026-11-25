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
        #expect(blocks.map(\.speaker.speaker) == [.me, .others, .me])
        #expect(blocks.map { $0.lines.count } == [2, 1, 1])
    }

    @Test func currentLineAndMatches() {
        let lines = [line(.me, 0, "Budget plan"), line(.others, 10, "budget again"), line(.me, 20, "Done")]
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 12) == lines[1].id)
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 0) == lines[0].id)
        #expect(TranscriptGrouping.matchingIDs(in: lines, query: "BUDGET") == [lines[0].id, lines[1].id])
        #expect(TranscriptGrouping.matchingIDs(in: lines, query: " ").isEmpty)
    }

    @Test func mutedRangesRoundTrip() {
        let meeting = Meeting(title: "Standup")
        #expect(meeting.mutedRanges.isEmpty)
        let ranges = [MutedRange(start: 12, end: 40.5), MutedRange(start: 60, end: 75)]
        meeting.mutedRanges = ranges
        #expect(meeting.mutedRanges == ranges)
        meeting.mutedRanges = []
        #expect(meeting.mutedRangesData == nil)
    }

    @Test func mutedMarkersSitAtTheStartOfTheirRange() {
        let lines = [line(.me, 0), line(.me, 10), line(.me, 20), line(.others, 30)]
        // `early` starts at the same time as a line, so its marker goes first. `late` is after
        // every line.
        let early = MutedRange(start: 10, end: 18)
        let late = MutedRange(start: 35, end: 50)
        let rows = TranscriptGrouping.rows(lines, mutedRanges: [late, early])
        #expect(rows.map(\.line?.id) == [lines[0].id, nil, lines[1].id, lines[2].id, lines[3].id, nil])
        #expect(rows[1].content == .muted(early))
        #expect(rows[5].content == .muted(late))
        // The speaker header comes back after a marker even when the speaker did not change.
        #expect(rows.map(\.startsBlock) == [true, true, true, false, true, true])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(TranscriptGrouping.rows(lines, mutedRanges: [early]).map(\.id)
            == TranscriptGrouping.rows(lines, mutedRanges: [early]).map(\.id))
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

    @Test func searchCacheFollowsContentChanges() {
        let meeting = Meeting(title: "Roadmap")
        meeting.segments = [TranscriptSegment(line: line(.me, 0, "first topic"))]
        #expect(MeetingGrouping.matches(meeting, query: "topic"))
        #expect(!MeetingGrouping.matches(meeting, query: "budget"))

        meeting.segments.append(TranscriptSegment(line: line(.others, 5, "the budget")))
        #expect(MeetingGrouping.matches(meeting, query: "budget"))

        meeting.title = "Offsite"
        meeting.attendees = ["Ana Ortiz"]
        meeting.summary = MeetingSummary(overview: "Hiring plan")
        #expect(MeetingGrouping.matches(meeting, query: "offsite"))
        #expect(MeetingGrouping.matches(meeting, query: "ortiz"))
        #expect(MeetingGrouping.matches(meeting, query: "hiring"))
        #expect(!MeetingGrouping.matches(meeting, query: "roadmap"))
    }

    @Test func searchDoesNotMatchAcrossFields() {
        let meeting = Meeting(title: "Road")
        meeting.segments = [TranscriptSegment(line: line(.me, 0, "map"))]
        #expect(!MeetingGrouping.matches(meeting, query: "roadmap"))
        #expect(!MeetingGrouping.matches(meeting, query: "road map"))
    }

    @Test func optionalLengthHidesZero() {
        let en = Locale(identifier: "en_US")
        #expect(LibraryFormat.optionalLength(0, locale: en) == nil)
        #expect(LibraryFormat.optionalLength(0.2, locale: en) == nil)
        #expect(LibraryFormat.optionalLength(-5, locale: en) == nil)
        #expect(LibraryFormat.optionalLength(65, locale: en) == LibraryFormat.length(65, locale: en))
        // A 65 minute meeting must not read like 65 seconds.
        #expect(LibraryFormat.optionalLength(65 * 60, locale: en) != LibraryFormat.optionalLength(65, locale: en))
    }

    #if DEBUG
    @Test func seekingToTheEndDoesNotStartPlayback() {
        let playback = PlaybackController.preview(at: 0, of: 60)
        playback.seek(to: 60, play: true)
        #expect(!playback.isPlaying)
        #expect(playback.currentTime == 60)
        playback.seek(to: 500, play: true)
        #expect(!playback.isPlaying)
        #expect(playback.currentTime == 60)
        playback.seek(to: 30, play: true)
        #expect(playback.isPlaying)
        playback.unload()
    }
    #endif
}

/// Reports whatever it was told and finishes a download only when the test says so.
private final class FakeSpeechModels: SpeechModelManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: SpeechModelStatus]
    private var continuation: AsyncThrowingStream<Double, Error>.Continuation?

    init(statuses: [String: SpeechModelStatus]) { self.statuses = statuses }

    func supportedLocales() async -> [Locale] { [] }

    func status(for locale: Locale) async -> SpeechModelStatus {
        lock.withLock { statuses[locale.identifier] ?? .notInstalled }
    }

    func install(locale: Locale) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    /// The controller starts the install from a task, so it may not have begun yet.
    func finishDownload() async {
        for _ in 0..<200 {
            if let continuation = lock.withLock({ continuation }) {
                continuation.finish()
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

struct SpeechModelControllerTests {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    private func waitUntilIdle(_ controller: SpeechModelController) async {
        for _ in 0..<200 where controller.isDownloading { try? await Task.sleep(for: .milliseconds(10)) }
        // The status is re-read after the download task is cleared.
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func finishedDownloadDoesNotMarkOtherLocaleInstalled() async {
        let models = FakeSpeechModels(statuses: ["en_US": .notInstalled, "de_DE": .notInstalled])
        let controller = SpeechModelController()
        controller.download(locale: english, using: models)
        #expect(controller.status == .downloading)

        await controller.refresh(locale: german, using: models)
        #expect(controller.status == .notInstalled)
        #expect(controller.progress == nil)

        await models.finishDownload()
        await waitUntilIdle(controller)
        #expect(!controller.isDownloading)
        #expect(controller.status == .notInstalled)
    }

    @Test func finishedDownloadMarksSelectedLocaleInstalled() async {
        let models = FakeSpeechModels(statuses: ["en_US": .notInstalled])
        let controller = SpeechModelController()
        controller.download(locale: english, using: models)
        await controller.refresh(locale: english, using: models)
        #expect(controller.status == .downloading)

        await models.finishDownload()
        await waitUntilIdle(controller)
        #expect(controller.status == .installed)
    }
}
