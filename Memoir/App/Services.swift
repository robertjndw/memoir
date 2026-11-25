import Foundation

/// Everything AppModel needs from the engines. `live` wires the real implementations,
/// `inert` is for previews and tests.
struct Services {
    var makeRecorder: (_ folder: URL) -> any AudioRecording
    var makeTranscriber: () -> any Transcribing
    var speechModels: any SpeechModelManaging
    var intelligence: any Intelligence
    var calendar: any CalendarProviding
    var detector: any MeetingDetecting
    var hints: any MeetingHintPresenting
}

extension Services {
    static var inert: Services {
        Services(
            makeRecorder: { _ in InertRecorder() },
            makeTranscriber: { InertTranscriber() },
            speechModels: InertSpeechModels(),
            intelligence: InertIntelligence(),
            calendar: InertCalendar(),
            detector: InertDetector(),
            hints: InertHints()
        )
    }
}

private nonisolated struct InertRecorder: AudioRecording {
    func start() async throws -> CaptureStreams { throw RecordingError.noAudioSource }
    func setMicrophoneMuted(_ muted: Bool) async -> TimeInterval? { nil }
    func stop() async -> RecordingOutput { RecordingOutput(audioURL: nil, duration: 0) }
}

private nonisolated struct InertTranscriber: Transcribing {
    func start(streams: CaptureStreams, locale: Locale, contextualStrings: [String]) async throws
        -> AsyncStream<TranscriptEvent>
    {
        AsyncStream { $0.finish() }
    }
    func finish() async {}
    func transcribe(file: URL, locale: Locale) -> AsyncThrowingStream<TranscriptUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private nonisolated struct InertSpeechModels: SpeechModelManaging {
    func supportedLocales() async -> [Locale] { [Locale(identifier: "en_US")] }
    func status(for locale: Locale) async -> SpeechModelStatus { .installed }
    func install(locale: Locale) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private nonisolated struct InertIntelligence: Intelligence {
    private struct Session: ChatSessioning {
        func respond(to question: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    var availability: IntelligenceAvailability { .appleIntelligenceNotEnabled }
    func prewarm() {}
    func summarize(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func makeChatSession(scope: ChatScope, corpus: any TranscriptCorpus, history: [ChatTurn]) async
        -> any ChatSessioning
    {
        Session()
    }
}

private final class InertCalendar: CalendarProviding {
    var hasAccess: Bool { false }
    func requestAccess() async -> Bool { false }
    func current() -> CalendarMeeting? { nil }
    func next(within interval: TimeInterval) -> CalendarMeeting? { nil }
}

private final class InertDetector: MeetingDetecting {
    let suggestions = AsyncStream<MeetingSuggestion> { $0.finish() }
    func start(options: DetectionOptions) {}
    func update(options: DetectionOptions) {}
    func setRecording(_ isRecording: Bool) {}
    func dismissed(_ suggestion: MeetingSuggestion) {}
}

private final class InertHints: MeetingHintPresenting {
    func show(_ suggestion: MeetingSuggestion, actions: MeetingHintActions) {}
    func hide() {}
}
