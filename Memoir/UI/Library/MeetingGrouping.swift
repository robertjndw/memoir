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

    static func matches(_ meeting: Meeting, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if meeting.title.localizedStandardContains(query) { return true }
        if meeting.attendees.contains(where: { $0.localizedStandardContains(query) }) { return true }
        if let summary = meeting.summary {
            let texts = [summary.title, summary.overview] + summary.keyPoints + summary.decisions
                + summary.actionItems.flatMap { [$0.task, $0.owner ?? ""] }
            if texts.contains(where: { $0.localizedStandardContains(query) }) { return true }
        }
        return meeting.segments.contains { $0.text.localizedStandardContains(query) }
    }
}
