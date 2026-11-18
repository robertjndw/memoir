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
    static var baseDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Memoir", directoryHint: .isDirectory)
    }

    static var storeURL: URL { baseDirectory.appending(path: "Memoir.store") }

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
    static func memoir(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema([Meeting.self, TranscriptSegment.self, ChatMessage.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try? FileManager.default.createDirectory(
                at: RecordingFiles.baseDirectory, withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(schema: schema, url: RecordingFiles.storeURL)
        }
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not open the Memoir store: \(error)")
        }
    }
}
