import Foundation
import SwiftData

@Model
final class Meeting {
    enum Status: String, Codable {
        case recording
        case ready
    }

    @Attribute(.unique) var id: UUID
    var title: String
    /// False while the title is still the generated placeholder, so a summary may replace it.
    var hasCustomTitle: Bool
    var startDate: Date
    var duration: TimeInterval
    var statusRaw: String
    var sourceAppName: String?
    var sourceAppBundleID: String?
    var calendarEventID: String?
    var attendees: [String]
    var localeIdentifier: String
    var hasAudio: Bool
    // Stored as JSON rather than a composite attribute: SwiftData is unreliable with nested
    // arrays of Codable structs.
    var summaryData: Data?
    /// JSON for the same reason as `summaryData`. Optional with no default so existing stores
    /// get a lightweight migration.
    var mutedRangesData: Data?
    /// Completed summary action items, keyed by task text instead of index so they survive
    /// regenerating the summary. Leftover entries are harmless.
    var completedActionItems: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment] = []
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.meeting)
    var messages: [ChatMessage] = []

    init(
        id: UUID = UUID(),
        title: String,
        hasCustomTitle: Bool = false,
        startDate: Date = .now,
        localeIdentifier: String = Locale.current.identifier
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.startDate = startDate
        self.duration = 0
        self.statusRaw = Status.recording.rawValue
        self.attendees = []
        self.localeIdentifier = localeIdentifier
        self.hasAudio = false
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .ready }
        set { statusRaw = newValue.rawValue }
    }

    var summary: MeetingSummary? {
        get { summaryData.flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: $0) } }
        set { summaryData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// Stretches where the user muted their microphone in Memoir, in the order they ended.
    var mutedRanges: [MutedRange] {
        get { mutedRangesData.flatMap { try? JSONDecoder().decode([MutedRange].self, from: $0) } ?? [] }
        set { mutedRangesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// Relationship arrays are unordered, so always read the transcript through this.
    var sortedLines: [TranscriptLine] {
        segments.map(\.line).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    var audioURL: URL? {
        hasAudio ? RecordingFiles.audioURL(for: id) : nil
    }

    var digest: MeetingDigest {
        MeetingDigest(
            id: id, title: title, date: startDate, duration: duration,
            attendees: attendees, summary: summary
        )
    }
}

@Model
final class TranscriptSegment {
    var id: UUID
    var speakerRaw: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var meeting: Meeting?

    init(line: TranscriptLine) {
        id = line.id
        speakerRaw = line.speaker.rawValue
        start = line.start
        end = line.end
        text = line.text
    }

    var speaker: Speaker { Speaker(rawValue: speakerRaw) ?? .unknown }

    var line: TranscriptLine {
        TranscriptLine(id: id, speaker: speaker, start: start, end: end, text: text)
    }
}

@Model
final class ChatMessage {
    var id: UUID
    var roleRaw: String
    var text: String
    var date: Date
    /// Nil for the library-wide "Ask Memoir" conversation.
    var meeting: Meeting?

    init(role: ChatTurn.Role, text: String, date: Date = .now, meeting: Meeting? = nil) {
        id = UUID()
        roleRaw = role.rawValue
        self.text = text
        self.date = date
        self.meeting = meeting
    }

    var role: ChatTurn.Role { ChatTurn.Role(rawValue: roleRaw) ?? .assistant }
    var turn: ChatTurn { ChatTurn(role: role, text: text) }
}

nonisolated enum RecordingFiles {
    /// The app is not sandboxed, so this is the real ~/Library/Application Support/Memoir.
    /// Debug builds use "Memoir Dev" so they can run next to the installed app. Sharing the
    /// folder would mean two apps writing one store, and the MCP server unlinks any socket
    /// already at its path, so the installed app would stop answering AI assistants.
    static var baseDirectory: URL {
        #if DEBUG
        let folder = "Memoir Dev"
        #else
        let folder = "Memoir"
        #endif
        return URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory)
    }

    static var storeURL: URL { baseDirectory.appending(path: "Memoir.store") }

    /// Where the MCP server listens. The `memoir-mcp` bridge hardcodes the same path.
    static var mcpSocketURL: URL { baseDirectory.appending(path: "mcp.sock") }

    static func folder(for meetingID: UUID) -> URL {
        baseDirectory
            .appending(path: "Recordings", directoryHint: .isDirectory)
            .appending(path: meetingID.uuidString, directoryHint: .isDirectory)
    }

    /// The contract with the recorder: the final mixdown is always `audio.m4a` in the folder.
    static func audioURL(for meetingID: UUID) -> URL {
        folder(for: meetingID).appending(path: "audio.m4a")
    }
}

extension ModelContainer {
    private static var memoirSchema: Schema {
        Schema([Meeting.self, TranscriptSegment.self, ChatMessage.self])
    }

    /// The on-disk store goes through `openMemoirStore`, which can ask the user what to do
    /// when it cannot be opened.
    static func memoir(inMemory: Bool = false) -> ModelContainer {
        guard inMemory else { return openMemoirStore() }
        let schema = memoirSchema
        do {
            return try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        } catch {
            // Nothing on disk is involved, so this can only be a broken schema, a bug that has
            // to show up in previews and tests rather than be worked around.
            fatalError("Could not create the in-memory Memoir store: \(error)")
        }
    }

    static func memoirOnDisk() throws -> ModelContainer {
        try FileManager.default.createDirectory(at: RecordingFiles.baseDirectory, withIntermediateDirectories: true)
        let schema = memoirSchema
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: RecordingFiles.storeURL)]
        )
    }

    /// Renames the store and its SQLite sidecar files so a fresh one can be created in its
    /// place. Never deletes: the user may get the old one back with a newer version or by hand.
    /// Returns the new location of the main store file.
    static func moveMemoirStoreAside(now: Date = .now) throws -> URL {
        let store = RecordingFiles.storeURL
        let folder = store.deletingLastPathComponent()
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let aside = folder.appending(path: "Unreadable Memoir \(stamp).store")
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: store.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: URL(filePath: aside.path + suffix))
        }
        return aside
    }
}
