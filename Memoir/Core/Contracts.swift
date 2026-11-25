import AVFoundation
import Foundation
import Synchronization

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
    /// Which person this is, numbered from 1 in the order they first speak. Nil for the user's
    /// own lines and for transcripts whose speakers were never identified.
    var voice: Int?
    /// The name the user gave this voice. Not stored per line: the store fills it in on read.
    var name: String?

    /// What to call the speaker of this line anywhere it is shown or handed to a model.
    var label: String {
        if let name, !name.isEmpty { return name }
        if let voice { return "Speaker \(voice)" }
        return speaker.label
    }

    var speakerID: SpeakerID { SpeakerID(speaker: speaker, voice: voice) }
}

/// One person in a transcript. Two lines belong to the same turn only if this matches, which
/// `speaker` alone no longer says once the other side was split into individual voices.
nonisolated struct SpeakerID: Sendable, Hashable {
    var speaker: Speaker
    var voice: Int?
}

/// A word and where it was spoken, in seconds from the start of the recording.
nonisolated struct TimedWord: Sendable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
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
    /// Problems that come up after capture started. Each issue is sent at most once, and the
    /// stream finishes when the recording stops.
    var issues = AsyncStream<RecordingIssue> { $0.finish() }
}

/// Something went wrong while a recording keeps running. Recording never stops because of
/// one of these; they only tell the user that part of the audio or live transcript is missing.
nonisolated enum RecordingIssue: Sendable, Hashable {
    /// A part file could not be created or written, typically because the disk is full.
    case audioNotSaved(AudioSource)
    /// The speech model never became ready, so nothing is transcribed live.
    case speechModelUnavailable
    /// The speech model took so long that the oldest audio waiting for it was dropped.
    case liveTranscriptIncomplete
    /// The analyzer of one side failed. Its live transcript ends here.
    case transcriptionStopped(Speaker)

    var message: String {
        switch self {
        case .audioNotSaved(.microphone):
            "Memoir could not save the microphone audio. Check that your Mac has enough free disk space."
        case .audioNotSaved(.system):
            "Memoir could not save the system audio. Check that your Mac has enough free disk space."
        case .speechModelUnavailable:
            "The speech model is not available, so this meeting has no live transcript. You can transcribe the recording in the Library afterwards."
        case .liveTranscriptIncomplete:
            "The speech model took a while to download, so the live transcript is missing the start of the meeting."
        case .transcriptionStopped(.me):
            "Live transcription of your microphone stopped. The audio is still being recorded."
        case .transcriptionStopped:
            "Live transcription of the other participants stopped. The audio is still being recorded."
        }
    }
}

/// Passes each issue on once, however often it is hit. The same failure tends to repeat for
/// every buffer, or to hit both sources at the same moment.
nonisolated final class IssueReporter: Sendable {
    private let reported = Mutex<Set<RecordingIssue>>([])
    private let send: @Sendable (RecordingIssue) -> Void

    init(_ send: @escaping @Sendable (RecordingIssue) -> Void) {
        self.send = send
    }

    func report(_ issue: RecordingIssue) {
        guard reported.withLock({ $0.insert(issue).inserted }) else { return }
        send(issue)
    }
}

nonisolated struct RecordingOutput: Sendable {
    /// The single mixed-down file, or nil if nothing could be written.
    let audioURL: URL?
    let duration: TimeInterval
    /// Each source on its own as 16 kHz mono, for the models that run after the recording.
    /// Only written when the recorder was asked to keep them. The caller deletes them.
    var tracks: [AudioSource: URL] = [:]
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

/// A stretch of the recording where the user muted their microphone in Memoir. Seconds from
/// the start of the recording, on the same clock as transcript lines.
nonisolated struct MutedRange: Codable, Sendable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
}

/// One recording. Instances are single use: `start` once, `stop` once.
nonisolated protocol AudioRecording: Sendable {
    /// Starts capture and writing to disk. Throws only if no source at all could start.
    func start() async throws -> CaptureStreams
    /// Replaces microphone audio with silence (file, meter and stream) while muted. System
    /// audio is never affected. Returns the recording time the change took effect, or nil
    /// when not recording or there is no microphone.
    func setMicrophoneMuted(_ muted: Bool) async -> TimeInterval?
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
    /// The words of a final update with their timing, when the engine reports it. Needed to
    /// split a line that turns out to span two people.
    var words: [TimedWord]? = nil
}

nonisolated enum TranscriptEvent: Sendable {
    case update(TranscriptUpdate)
    /// Sent at most once per issue. Updates keep coming for whatever is still transcribed.
    case issue(RecordingIssue)
}

/// One transcription run. Single use.
nonisolated protocol Transcribing: Sendable {
    /// Returns promptly. If the speech model still has to be downloaded, the most recent audio
    /// is buffered and transcribed once it is ready. The returned stream finishes after
    /// `finish()` once all final results were delivered.
    func start(
        streams: CaptureStreams,
        locale: Locale,
        contextualStrings: [String]
    ) async throws -> AsyncStream<TranscriptEvent>

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

// MARK: - Optional models

/// Models Memoir does not need to work, which the user can download to get more out of a
/// recording. They are third-party and run on this Mac like everything else.
nonisolated enum OptionalModel: String, Sendable, CaseIterable, Identifiable {
    /// Tells the people on the other side of a call apart (speaker diarization).
    case speakerIdentification
    /// A second, more accurate transcription pass after the recording.
    case enhancedTranscription

    var id: String { rawValue }
}

nonisolated protocol OptionalModelManaging: Sendable {
    func isInstalled(_ model: OptionalModel) async -> Bool
    /// Bytes on disk, nil when not installed.
    func installedSize(of model: OptionalModel) async -> Int64?
    /// Yields download progress 0...1 and finishes once the model is ready to use. The only
    /// time any of this touches the network.
    func install(_ model: OptionalModel) -> AsyncThrowingStream<Double, Error>
    func remove(_ model: OptionalModel) async throws
}

nonisolated struct EnhancementRequest: Sendable {
    nonisolated enum Audio: Sendable {
        /// Fresh from the recorder: each source on its own, so the microphone is known to be
        /// the user and only the system track needs its speakers told apart.
        case tracks([AudioSource: URL])
        /// An older recording where only the mix is left.
        case mixed(URL)
    }

    var audio: Audio
    var locale: Locale
    /// The transcript as it stands. Kept as the text when `transcribe` is false, and used to
    /// find the user's own voice in a mixed file.
    var lines: [TranscriptLine]
    /// Word timings of `lines` by line id, for the lines that have them.
    var words: [UUID: [TimedWord]] = [:]
    /// Replace the text with a new transcription.
    var transcribe: Bool
    /// Split the other side into individual voices.
    var identifySpeakers: Bool
}

nonisolated enum EnhancementProgress: Sendable {
    /// 0...1 within the step.
    case transcribing(Double)
    case identifyingSpeakers(Double)
    /// The complete new transcript, in time order. Always the last element.
    case finished([TranscriptLine])
}

/// The work done on a recording after it ended, with the optional models.
nonisolated protocol TranscriptEnhancing: Sendable {
    /// Whether the transcription model knows this language. Speaker identification does not
    /// depend on language.
    func supportsTranscription(in locale: Locale) -> Bool
    /// The models the request needs must be installed. Never downloads anything.
    func enhance(_ request: EnhancementRequest) -> AsyncThrowingStream<EnhancementProgress, Error>
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
