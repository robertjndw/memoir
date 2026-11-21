import Foundation

/// Renders a meeting as Markdown. Pure on purpose so it can be tested without a store.
nonisolated enum MeetingExporter {
    static func markdown(
        title: String,
        date: Date,
        duration: TimeInterval,
        attendees: [String],
        summary: MeetingSummary?,
        lines: [TranscriptLine],
        completedActionItems: Set<String> = [],
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var out: [String] = ["# \(title)", ""]

        let dateStyle = Date.FormatStyle(date: .complete, time: .shortened, locale: locale, timeZone: timeZone)
        out.append("- **Date:** \(date.formatted(dateStyle))")
        if duration > 0 {
            out.append("- **Duration:** \(LibraryFormat.length(duration, locale: locale))")
        }
        if !attendees.isEmpty {
            out.append("- **Attendees:** \(attendees.joined(separator: ", "))")
        }
        out.append("")

        if let summary, hasContent(summary) {
            out.append("## Summary")
            out.append("")
            if !summary.overview.isEmpty {
                out.append(summary.overview)
                out.append("")
            }
            section("Key Points", summary.keyPoints.map { "- \($0)" }, into: &out)
            section("Decisions", summary.decisions.map { "- \($0)" }, into: &out)
            section("Action Items", summary.actionItems.map { item in
                let box = completedActionItems.contains(item.task) ? "[x]" : "[ ]"
                return item.owner.flatMap { $0.isEmpty ? nil : $0 }.map { "- \(box) \(item.task) (\($0))" }
                    ?? "- \(box) \(item.task)"
            }, into: &out)
        }

        out.append("## Transcript")
        out.append("")
        if lines.isEmpty {
            out.append("_No transcript._")
        } else {
            for line in lines {
                out.append("[\(LibraryFormat.timecode(line.start))] **\(line.speaker.label):** \(line.text)")
                out.append("")
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// A file name that is safe on disk.
    static func fileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Meeting" : cleaned
    }

    private static func hasContent(_ summary: MeetingSummary) -> Bool {
        !summary.overview.isEmpty || !summary.keyPoints.isEmpty
            || !summary.decisions.isEmpty || !summary.actionItems.isEmpty
    }

    private static func section(_ heading: String, _ items: [String], into out: inout [String]) {
        guard !items.isEmpty else { return }
        out.append("### \(heading)")
        out.append("")
        out.append(contentsOf: items)
        out.append("")
    }
}

extension MeetingExporter {
    static func markdown(for meeting: Meeting) -> String {
        markdown(
            title: meeting.title,
            date: meeting.startDate,
            duration: meeting.duration,
            attendees: meeting.attendees,
            summary: meeting.summary,
            lines: meeting.sortedLines,
            completedActionItems: Set(meeting.completedActionItems)
        )
    }
}
