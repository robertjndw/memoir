import AVFoundation
import Foundation

// The seams between the app spine (AppModel, UI) and the engines (audio, speech, intelligence,
// detection). The module defaults to MainActor isolation, so everything that runs off the main
// actor is explicitly `nonisolated` here.

// MARK: - Shared values

nonisolated enum Speaker: String, Sendable, Codable, CaseIterable {
    /// Microphone stream.
    case me
    /// System audio stream.
    case others
    /// Transcribed from a mixed file, where the two sides can no longer be told apart.
    case unknown

    var label: String {
        switch self {
        case .me: "You"
        case .others: "Others"
        case .unknown: "Speaker"
        }
    }
}

nonisolated struct TranscriptLine: Sendable, Identifiable, Hashable {
    var id = UUID()
    var speaker: Speaker
    /// Seconds from the start of the recording.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

// MARK: - Audio capture

nonisolated enum AudioSource: String, Sendable, Hashable {
    case microphone
    case system
}

/// A chunk of captured audio in the source's native format.
nonisolated struct CapturedAudio: @unchecked Sendable {
    // AVAudioPCMBuffer is not Sendable. Producers hand over a buffer they never touch again.
    let buffer: AVAudioPCMBuffer
    /// Seconds from the start of the recording to the first frame of `buffer`.
    let time: TimeInterval
}

/// Normalized 0...1 levels for metering.
nonisolated struct AudioLevels: Sendable, Equatable {
    var microphone: Float = 0
    var system: Float = 0
}

nonisolated struct CaptureStreams: Sendable {
    let microphone: AsyncStream<CapturedAudio>
    let system: AsyncStream<CapturedAudio>
    let levels: AsyncStream<AudioLevels>
    /// Sources that could not be started (permission denied, no device). Their stream is
    /// already finished. Recording continues with whatever is left.
    let unavailable: Set<AudioSource>
}

nonisolated struct RecordingOutput: Sendable {
    /// The single mixed-down file, or nil if nothing could be written.
    let audioURL: URL?
    let duration: TimeInterval
}

nonisolated enum RecordingError: LocalizedError {
    case noAudioSource
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .noAudioSource: "No audio source could be started."
        case .microphonePermissionDenied: "Memoir does not have permission to use the microphone."
        }
    }
}

/// One recording. Instances are single use: `start` once, `stop` once.
nonisolated protocol AudioRecording: Sendable {
    /// Starts capture and writing to disk. Throws only if no source at all could start.
    func start() async throws -> CaptureStreams
    /// Stops capture, finishes all streams, and produces the final audio file.
    func stop() async -> RecordingOutput
}

// MARK: - Transcription

nonisolated struct TranscriptUpdate: Sendable {
    let speaker: Speaker
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    /// A volatile update replaces the previous volatile text of the same speaker. A final update
    /// is appended to the transcript and clears that speaker's volatile text.
    let isFinal: Bool
}

/// One transcription run. Single use.
nonisolated protocol Transcribing: Sendable {
    /// Returns promptly. If the speech model still has to be downloaded, audio is buffered and
    /// transcribed once it is ready. The returned stream finishes after `finish()` once all
    /// final results were delivered.
    func start(
        streams: CaptureStreams,
        locale: Locale,
        contextualStrings: [String]
    ) async throws -> AsyncStream<TranscriptUpdate>

    /// Call after the audio streams ended. Flushes pending results and ends the update stream.
    func finish() async

    /// Transcribes a finished recording from disk. Speakers come back as `.unknown`.
    func transcribe(file: URL, locale: Locale) -> AsyncThrowingStream<TranscriptUpdate, Error>
}

nonisolated enum SpeechModelStatus: Sendable, Equatable {
    case unsupported
    case notInstalled
    case downloading
    case installed
}

nonisolated protocol SpeechModelManaging: Sendable {
    func supportedLocales() async -> [Locale]
    func status(for locale: Locale) async -> SpeechModelStatus
    /// Yields download progress 0...1 and finishes once the model is installed.
    func install(locale: Locale) -> AsyncThrowingStream<Double, Error>
}

// MARK: - Intelligence

nonisolated enum IntelligenceAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
}

nonisolated struct MeetingSummary: Codable, Sendable, Hashable {
    nonisolated struct ActionItem: Codable, Sendable, Equatable, Hashable {
        var task: String
        var owner: String?
    }

    var title: String = ""
    var overview: String = ""
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
}

nonisolated enum SummaryProgress: Sendable {
    /// Long transcripts are condensed in chunks first. 0...1.
    case condensing(Double)
    /// The summary as generated so far.
    case partial(MeetingSummary)
    case finished(MeetingSummary)
}

nonisolated struct SummaryRequest: Sendable {
    var lines: [TranscriptLine]
    var attendees: [String]
    var date: Date
    var locale: Locale
}

nonisolated struct MeetingDigest: Sendable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var attendees: [String]
    var summary: MeetingSummary?
}

/// Read access to recorded meetings for retrieval during chat.
nonisolated protocol TranscriptCorpus: Sendable {
    func meetings() async -> [MeetingDigest]
    func lines(of meetingID: UUID) async -> [TranscriptLine]
}

nonisolated enum ChatScope: Sendable, Hashable {
    case meeting(UUID)
    case library
}

nonisolated struct ChatTurn: Sendable, Hashable {
    nonisolated enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    var role: Role
    var text: String
}

nonisolated protocol ChatSessioning: Sendable {
    /// Streams the answer as cumulative text (each element replaces the previous one).
    /// In meeting scope, answers cite transcript positions as `[mm:ss]` or `[h:mm:ss]`.
    func respond(to question: String) -> AsyncThrowingStream<String, Error>
}

nonisolated protocol Intelligence: Sendable {
    var availability: IntelligenceAvailability { get }
    func prewarm()
    func summarize(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryProgress, Error>
    func makeChatSession(
        scope: ChatScope,
        corpus: any TranscriptCorpus,
        history: [ChatTurn]
    ) async -> any ChatSessioning
}

// MARK: - Calendar and detection (main actor)

nonisolated struct CalendarMeeting: Sendable, Identifiable, Hashable {
    /// EventKit event identifier.
    let id: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [String]
    var joinURL: URL?
}

protocol CalendarProviding: AnyObject {
    var hasAccess: Bool { get }
    func requestAccess() async -> Bool
    /// A meeting-like event (call link or attendees) that is in progress or starts within 5 minutes.
    func current() -> CalendarMeeting?
    /// The next meeting-like event starting within the interval.
    func next(within interval: TimeInterval) -> CalendarMeeting?
}

nonisolated struct MeetingSuggestion: Sendable, Identifiable, Equatable {
    nonisolated enum Kind: Sendable, Equatable {
        case start
        case stop
    }

    var id = UUID()
    var kind: Kind
    /// The app that triggered the suggestion, if any.
    var appName: String?
    var bundleID: String?
    var event: CalendarMeeting?
}

nonisolated struct DetectionOptions: Sendable, Equatable {
    var microphoneApps = true
    var calendar = true
    var camera = true
    var mutedBundleIDs: Set<String> = []
}

protocol MeetingDetecting: AnyObject {
    /// `.start` suggestions while idle, `.stop` suggestions while recording.
    var suggestions: AsyncStream<MeetingSuggestion> { get }
    func start(options: DetectionOptions)
    func update(options: DetectionOptions)
    /// Memoir's own capture must not count as a meeting signal.
    func setRecording(_ isRecording: Bool)
    /// The user dismissed the hint. Starts the cooldown for that app or event.
    func dismissed(_ suggestion: MeetingSuggestion)
}

struct MeetingHintActions {
    /// Primary button: start (or stop) recording.
    var accept: () -> Void
    /// Closed by the user. Not called on auto-dismiss.
    var dismiss: () -> Void
    /// "Don't ask for this app". Nil when the suggestion has no app.
    var muteApp: (() -> Void)?
}

protocol MeetingHintPresenting: AnyObject {
    func show(_ suggestion: MeetingSuggestion, actions: MeetingHintActions)
    func hide()
}
