import Foundation

/// What the MCP tools read. The transcript corpus plus the bits of a meeting that only the
/// store knows, like which action items the user ticked off.
nonisolated protocol MeetingLibrary: TranscriptCorpus {
    /// Task texts of the summary action items marked as done.
    func completedActionItems(of meetingID: UUID) async -> Set<String>
}

nonisolated struct JSONRPCError: Error, Sendable, Equatable {
    var code: Int
    var message: String

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602

    static func invalidParams(_ message: String) -> JSONRPCError {
        JSONRPCError(code: invalidParams, message: message)
    }
}

nonisolated struct MCPToolResult: Sendable, Equatable {
    var text: String
    /// Per MCP, a tool that ran but failed reports that in the result rather than as a
    /// protocol error, so the model sees the message and can correct its call.
    var isError = false

    static func failure(_ text: String) -> MCPToolResult {
        MCPToolResult(text: text, isError: true)
    }

    var json: JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}

/// The read-only meeting tools offered to MCP clients.
///
/// Budgets are much larger than in the on-device chat. Clients run on models with big context
/// windows, and passages that are cut too short just make them call again or guess.
nonisolated struct MCPTools: Sendable {
    let library: any MeetingLibrary
    var estimator = TokenEstimator()
    var calendar = Calendar.current
    var searchBudget = 8_000
    var transcriptBudget = 60_000

    static let defaultListLimit = 20
    static let maxListLimit = 200

    func call(_ name: String, arguments: [String: JSONValue]) async throws(JSONRPCError) -> MCPToolResult {
        let arguments = Arguments(values: arguments)
        switch name {
        case "list_meetings":
            return await listMeetings(
                from: try arguments.string("from"),
                to: try arguments.string("to"),
                limit: try arguments.int("limit") ?? Self.defaultListLimit
            )
        case "search_meetings":
            guard let query = try arguments.string("query") else {
                throw .invalidParams("search_meetings needs a \"query\" argument.")
            }
            return await searchMeetings(query: query, from: try arguments.string("from"), to: try arguments.string("to"))
        case "get_meeting":
            guard let id = try arguments.string("id") else {
                throw .invalidParams("get_meeting needs an \"id\" argument.")
            }
            return await getMeeting(
                id: id,
                includeTranscript: try arguments.bool("include_transcript") ?? false,
                query: try arguments.string("query")
            )
        default:
            throw .invalidParams("Unknown tool \"\(name)\".")
        }
    }

    // MARK: list_meetings

    func listMeetings(from: String?, to: String?, limit: Int) async -> MCPToolResult {
        let range: (from: Date?, to: Date?)
        do {
            range = try dateRange(from: from, to: to)
        } catch {
            return .failure(error.message)
        }
        let limit = min(max(limit, 1), Self.maxListLimit)
        // A fresh index per call: sessions stay open for hours and must see new recordings.
        let meetings = await RetrievalIndex(corpus: library).digests()
            .filter { RetrievalIndex.isInRange($0.date, from: range.from, to: range.to) }
        guard !meetings.isEmpty else {
            return MCPToolResult(text: "There are no recorded meetings\(Self.rangeText(from: from, to: to)).")
        }

        var entries: [String] = []
        var used = 0
        for meeting in meetings.prefix(limit) {
            var entry = "- \(meeting.title)\n  id: \(meeting.id.uuidString)\n  date: \(Prompts.format(meeting.date)), \(Prompts.durationText(meeting.duration))"
            if let attendees = Self.attendeeText(meeting.attendees) {
                entry += "\n  attendees: \(attendees)"
            }
            if let overview = meeting.summary?.overview, !overview.isEmpty {
                entry += "\n  overview: " + estimator.truncate(TranscriptFormat.collapseWhitespace(overview), toTokens: 120)
            }
            let cost = estimator.tokens(entry)
            guard used + cost <= searchBudget else { break }
            used += cost
            entries.append(entry)
        }

        var text = "\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")\(Self.rangeText(from: from, to: to)), newest first"
        text += entries.count < meetings.count ? ", showing the first \(entries.count):\n\n" : ":\n\n"
        text += entries.joined(separator: "\n")
        if entries.count < meetings.count {
            text += "\n\n\(meetings.count - entries.count) older meetings not shown. Narrow the date range with from and to, or raise limit."
        }
        return MCPToolResult(text: text)
    }

    // MARK: search_meetings

    func searchMeetings(query: String, from: String?, to: String?) async -> MCPToolResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failure("The query is empty. Pass the words to look for.") }
        let range: (from: Date?, to: Date?)
        do {
            range = try dateRange(from: from, to: to)
        } catch {
            return .failure(error.message)
        }
        let result = await RetrievalIndex(corpus: library).searchLibrary(
            query: query,
            from: range.from,
            to: range.to,
            budget: searchBudget,
            estimator: estimator,
            maxMeetings: 6,
            passagesPerMeeting: 5,
            includeIDs: true
        )
        return MCPToolResult(text: result)
    }

    // MARK: get_meeting

    func getMeeting(id: String, includeTranscript: Bool, query: String?) async -> MCPToolResult {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else {
            return .failure(
                "\"\(id)\" is not a meeting id. Ids are UUIDs such as 1F0C3B5E-8A1D-4C4B-9F64-2D4C8E1A7B90, as returned by list_meetings and search_meetings."
            )
        }
        let index = RetrievalIndex(corpus: library)
        guard let meeting = await index.digest(uuid) else {
            return .failure("There is no meeting with id \(uuid.uuidString). It may have been deleted. Use list_meetings or search_meetings to find current ids.")
        }

        var sections = [Self.header(meeting)]
        if let summary = meeting.summary {
            let completed = await library.completedActionItems(of: uuid)
            sections.append(Self.summarySection(summary, completed: completed))
        } else {
            sections.append("No summary has been generated for this meeting. Read the transcript with query or include_transcript.")
        }

        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            let passages = await index.searchMeeting(uuid, query: query, budget: searchBudget, estimator: estimator)
            sections.append("## Passages matching \"\(query)\"\n\n\(passages)")
        }
        if includeTranscript {
            sections.append("## Transcript\n\n" + transcript(await index.lines(of: uuid)))
        }
        return MCPToolResult(text: sections.joined(separator: "\n\n"))
    }

    private func transcript(_ lines: [TranscriptLine]) -> String {
        guard !lines.isEmpty else { return "The transcript of this meeting is empty." }
        var rendered: [String] = []
        var used = 0
        for line in lines {
            let text = TranscriptFormat.render(line)
            let cost = estimator.tokens(text) + 1
            if used + cost > transcriptBudget {
                rendered.append(
                    "[Transcript truncated at \(TranscriptFormat.citation(line.start)) after \(rendered.count) of \(lines.count) lines. Use get_meeting with a query to find passages from later in the meeting.]"
                )
                break
            }
            used += cost
            rendered.append(text)
        }
        return rendered.joined(separator: "\n")
    }

    // MARK: Rendering

    private static func header(_ meeting: MeetingDigest) -> String {
        var lines = [
            "# \(meeting.title)",
            "id: \(meeting.id.uuidString)",
            "date: \(Prompts.format(meeting.date))",
            "duration: \(Prompts.durationText(meeting.duration))",
        ]
        if let attendees = attendeeText(meeting.attendees) {
            lines.append("attendees: \(attendees)")
        }
        return lines.joined(separator: "\n")
    }

    private static func summarySection(_ summary: MeetingSummary, completed: Set<String>) -> String {
        var parts: [String] = []
        if !summary.overview.isEmpty {
            parts.append("## Overview\n\n\(summary.overview)")
        }
        if !summary.keyPoints.isEmpty {
            parts.append("## Key points\n\n" + summary.keyPoints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.decisions.isEmpty {
            parts.append("## Decisions\n\n" + summary.decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.actionItems.isEmpty {
            let items = summary.actionItems.map { item in
                let box = completed.contains(item.task) ? "[x]" : "[ ]"
                return "- \(box) \(item.task)" + (item.owner.map { " (owner: \($0))" } ?? "")
            }
            parts.append("## Action items ([x] marks items the user completed)\n\n" + items.joined(separator: "\n"))
        }
        return parts.isEmpty ? "The summary of this meeting is empty." : parts.joined(separator: "\n\n")
    }

    private static func attendeeText(_ attendees: [String]) -> String? {
        let names = attendees.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static func rangeText(from: String?, to: String?) -> String {
        switch (from, to) {
        case let (from?, to?): " from \(from) to \(to)"
        case let (from?, nil): " since \(from)"
        case let (nil, to?): " until \(to)"
        case (nil, nil): ""
        }
    }

    /// Unlike the on-device chat, a bad date is an error here. Quietly ignoring it would search
    /// the whole library, and the client would trust results from the wrong time range.
    private func dateRange(from: String?, to: String?) throws(ToolFailure) -> (from: Date?, to: Date?) {
        let start = DayParser.start(of: from, calendar: calendar)
        let end = DayParser.end(of: to, calendar: calendar)
        if let from, start == nil {
            throw ToolFailure(message: "\"from\" must be a day as YYYY-MM-DD, got \"\(from)\".")
        }
        if let to, end == nil {
            throw ToolFailure(message: "\"to\" must be a day as YYYY-MM-DD, got \"\(to)\".")
        }
        return (start, end)
    }

    private struct ToolFailure: Error {
        let message: String
    }

    // MARK: Definitions

    static var definitions: [JSONValue] {
        let day: JSONValue = ["type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"]
        func dayParameter(_ description: String) -> JSONValue {
            guard case .object(var object) = day else { return day }
            object["description"] = .string(description)
            return .object(object)
        }
        return [
            tool(
                name: "list_meetings",
                title: "List meetings",
                description: "Lists the user's recorded meetings, newest first, with id, title, date, duration, attendees and a one-line overview. Use it to browse meetings in a date range or to find a meeting's id.",
                properties: [
                    "from": dayParameter("First day to include, as YYYY-MM-DD in the user's time zone. Omit for no lower limit."),
                    "to": dayParameter("Last day to include, as YYYY-MM-DD in the user's time zone. Omit for no upper limit."),
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": .int(maxListLimit),
                        "default": .int(defaultListLimit),
                        "description": "Maximum number of meetings to return.",
                    ],
                ],
                required: []
            ),
            tool(
                name: "search_meetings",
                title: "Search meetings",
                description: "Searches the titles, summaries and transcripts of all recorded meetings for a topic. Returns the best matching meetings with their id, title, date and the relevant transcript passages as [mm:ss] Speaker: text lines. Combines keyword and semantic matching, so short topical queries work best.",
                properties: [
                    "query": [
                        "type": "string",
                        "minLength": 1,
                        "description": "What to look for, for example \"budget approval\" or \"launch date\".",
                    ],
                    "from": dayParameter("Only meetings on or after this day, as YYYY-MM-DD. Omit to search all."),
                    "to": dayParameter("Only meetings on or before this day, as YYYY-MM-DD. Omit to search all."),
                ],
                required: ["query"]
            ),
            tool(
                name: "get_meeting",
                title: "Get meeting",
                description: "Returns one meeting by id: title, date, duration, attendees and its summary (overview, key points, decisions, action items with completion state). Pass query to also get the transcript passages that best match it, or include_transcript to get the full transcript. Prefer query for long meetings.",
                properties: [
                    "id": [
                        "type": "string",
                        "format": "uuid",
                        "description": "The meeting id from list_meetings or search_meetings.",
                    ],
                    "include_transcript": [
                        "type": "boolean",
                        "default": false,
                        "description": "Include the full transcript as [mm:ss] Speaker: text lines. Very long transcripts are truncated.",
                    ],
                    "query": [
                        "type": "string",
                        "description": "Also return the transcript passages that best match this topic.",
                    ],
                ],
                required: ["id"]
            ),
        ]
    }

    private static func tool(
        name: String,
        title: String,
        description: String,
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(JSONValue.string))
        }
        return [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object(schema),
            "annotations": [
                "title": .string(title),
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ]
    }
}

/// Typed access to tool arguments. A value of the wrong JSON type is a protocol-level
/// invalid-params error, as the schema already rules it out.
private nonisolated struct Arguments {
    let values: [String: JSONValue]

    func string(_ key: String) throws(JSONRPCError) -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw .invalidParams("\"\(key)\" must be a string.")
        }
    }

    func bool(_ key: String) throws(JSONRPCError) -> Bool? {
        switch values[key] {
        case nil, .null?: return nil
        case .bool(let value)?: return value
        default: throw .invalidParams("\"\(key)\" must be a boolean.")
        }
    }

    func int(_ key: String) throws(JSONRPCError) -> Int? {
        guard let value = values[key], value != .null else { return nil }
        guard let int = value.intValue else { throw .invalidParams("\"\(key)\" must be an integer.") }
        return int
    }
}
