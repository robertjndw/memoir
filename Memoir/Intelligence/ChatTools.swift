import Foundation
import FoundationModels

nonisolated struct SearchTranscriptTool: Tool {
    let name = "searchTranscript"
    let description = "Searches the meeting transcript and returns the best matching passages with their [mm:ss] positions."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Key words of what to look for, for example 'budget approval' or 'launch date'")
        var query: String
    }

    let index: RetrievalIndex
    let meetingID: UUID
    let budget: Int
    let estimator: TokenEstimator

    @concurrent func call(arguments: Arguments) async throws -> String {
        await index.searchMeeting(meetingID, query: arguments.query, budget: budget, estimator: estimator)
    }
}

nonisolated struct SearchMeetingsTool: Tool {
    let name = "searchMeetings"
    let description = "Searches titles, summaries and transcripts of all recorded meetings. Returns matching meetings with their title, date and relevant passages."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Key words of what to look for, for example 'pricing change' or 'Anna hiring'")
        var query: String
        @Guide(description: "Only meetings on or after this day, as YYYY-MM-DD. Omit to search all.")
        var fromDate: String?
        @Guide(description: "Only meetings on or before this day, as YYYY-MM-DD. Omit to search all.")
        var toDate: String?
    }

    let index: RetrievalIndex
    let budget: Int
    let estimator: TokenEstimator

    @concurrent func call(arguments: Arguments) async throws -> String {
        await index.searchLibrary(
            query: arguments.query,
            from: DayParser.start(of: arguments.fromDate),
            to: DayParser.end(of: arguments.toDate),
            budget: budget,
            estimator: estimator
        )
    }
}

nonisolated struct ListMeetingsTool: Tool {
    let name = "listMeetings"
    let description = "Lists recorded meetings, newest first, with title, date, length and a one line overview. Optionally limited to a date range."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "First day to include, as YYYY-MM-DD. Omit for no lower limit.")
        var fromDate: String?
        @Guide(description: "Last day to include, as YYYY-MM-DD. Omit for no upper limit.")
        var toDate: String?
    }

    let index: RetrievalIndex
    let budget: Int
    let estimator: TokenEstimator

    @concurrent func call(arguments: Arguments) async throws -> String {
        await index.listMeetings(
            from: DayParser.start(of: arguments.fromDate),
            to: DayParser.end(of: arguments.toDate),
            budget: budget,
            estimator: estimator
        )
    }
}

/// Parses the `YYYY-MM-DD` days the model passes to tools, in the user's calendar and time
/// zone. Anything unparsable means "no limit" rather than an error the model cannot fix.
nonisolated enum DayParser {
    static func start(of day: String?, calendar: Calendar = .current) -> Date? {
        guard let components = components(day) else { return nil }
        return calendar.date(from: components)
    }

    static func end(of day: String?, calendar: Calendar = .current) -> Date? {
        guard let start = start(of: day, calendar: calendar),
              let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return next.addingTimeInterval(-1)
    }

    private static func components(_ day: String?) -> DateComponents? {
        guard let day else { return nil }
        let parts = day.trimmingCharacters(in: .whitespaces).prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }
}
