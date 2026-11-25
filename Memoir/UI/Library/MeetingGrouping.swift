import Foundation

struct MeetingDayGroup: Identifiable {
    var id: Date { day }
    var day: Date
    var meetings: [Meeting]
}

enum MeetingGrouping {
    /// Newest day first, and newest meeting first inside a day.
    static func groups(_ meetings: [Meeting], calendar: Calendar = .current) -> [MeetingDayGroup] {
        let byDay = Dictionary(grouping: meetings) { calendar.startOfDay(for: $0.startDate) }
        return byDay.keys.sorted(by: >).map { day in
            MeetingDayGroup(day: day, meetings: byDay[day, default: []].sorted { $0.startDate > $1.startDate })
        }
    }

    static func title(for day: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar).weekday(.wide).month(.wide).day()
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return day.formatted(style)
    }

    /// Whether the meeting matches a search. Each text the search looks at is kept per meeting
    /// until the meeting's content changes, since collecting them decodes the summary and walks
    /// every transcript segment.
    static func matches(_ meeting: Meeting, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return searchTexts.texts(for: meeting).contains { $0.localizedStandardContains(query) }
    }

    /// Texts are matched one by one, not joined, so a query can't match across two fields.
    static func searchableTexts(of meeting: Meeting) -> [String] {
        var texts = [meeting.title] + meeting.attendees
        if let summary = meeting.summary {
            texts += [summary.title, summary.overview] + summary.keyPoints + summary.decisions
                + summary.actionItems.flatMap { [$0.task, $0.owner ?? ""] }
        }
        texts += meeting.segments.map(\.text)
        return texts
    }

    static let searchTexts = SearchTextCache()
}

/// Search texts per meeting. An entry is reused while the fields that feed it are unchanged.
/// Transcript segments are only ever appended, so their count stands in for their content.
final class SearchTextCache {
    private struct Entry {
        var title: String
        var attendees: [String]
        var summaryData: Data?
        var segmentCount: Int
        var texts: [String]
    }

    private var entries: [UUID: Entry] = [:]

    func texts(for meeting: Meeting) -> [String] {
        let segmentCount = meeting.segments.count
        if let entry = entries[meeting.id],
           entry.title == meeting.title, entry.attendees == meeting.attendees,
           entry.summaryData == meeting.summaryData, entry.segmentCount == segmentCount {
            return entry.texts
        }
        let texts = MeetingGrouping.searchableTexts(of: meeting)
        entries[meeting.id] = Entry(
            title: meeting.title, attendees: meeting.attendees,
            summaryData: meeting.summaryData, segmentCount: segmentCount, texts: texts
        )
        return texts
    }

    /// Drops meetings that no longer exist, so deleted transcripts aren't kept in memory.
    func prune(keeping ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}
