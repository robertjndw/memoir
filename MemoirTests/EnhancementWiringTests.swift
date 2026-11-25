import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Memoir

// MARK: - Fakes

/// Writes track files when asked to keep them, and remembers that it was asked.
private nonisolated final class TrackRecorder: AudioRecording {
    let folder: URL
    let keepTracks: Bool

    init(folder: URL, keepTracks: Bool) {
        self.folder = folder
        self.keepTracks = keepTracks
    }

    func start() async throws -> CaptureStreams {
        func finished<T>(_: T.Type) -> AsyncStream<T> { AsyncStream { $0.finish() } }
        return CaptureStreams(
            microphone: finished(CapturedAudio.self),
            system: finished(CapturedAudio.self),
            levels: finished(AudioLevels.self),
            unavailable: []
        )
    }

    func setMicrophoneMuted(_ muted: Bool) async -> TimeInterval? { nil }

    func stop() async -> RecordingOutput {
        var tracks: [AudioSource: URL] = [:]
        if keepTracks {
            for source in [AudioSource.microphone, .system] {
                let url = folder.appending(path: "track-\(source.rawValue).caf")
                FileManager.default.createFile(atPath: url.path, contents: Data([0]))
                tracks[source] = url
            }
        }
        return RecordingOutput(audioURL: folder.appending(path: "audio.m4a"), duration: 3, tracks: tracks)
    }
}

/// One final line from the other side, with word timings, when the recording finishes.
private actor LineTranscriber: Transcribing {
    private var continuation: AsyncStream<TranscriptEvent>.Continuation?

    func start(streams: CaptureStreams, locale: Locale, contextualStrings: [String]) async throws
        -> AsyncStream<TranscriptEvent>
    {
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
        self.continuation = continuation
        return stream
    }

    func finish() async {
        let words = [TimedWord(text: "Hello", start: 0.2, end: 0.5), TimedWord(text: "there", start: 0.6, end: 1)]
        continuation?.yield(.update(TranscriptUpdate(
            speaker: .others, text: "Hello there", start: 0.2, end: 1, isFinal: true, words: words
        )))
        continuation?.finish()
    }

    nonisolated func transcribe(file: URL, locale: Locale) -> AsyncThrowingStream<TranscriptUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private nonisolated struct InstalledModels: OptionalModelManaging {
    var installed: Set<OptionalModel>

    func isInstalled(_ model: OptionalModel) async -> Bool { installed.contains(model) }
    func installedSize(of model: OptionalModel) async -> Int64? { installed.contains(model) ? 1 : nil }
    func install(_ model: OptionalModel) -> AsyncThrowingStream<Double, Error> { AsyncThrowingStream { $0.finish() } }
    func remove(_ model: OptionalModel) async throws {}
}

private nonisolated final class RecordingEnhancer: TranscriptEnhancing {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The model gave up." }
    }

    let result: Result<[TranscriptLine], Failure>
    let languages: Set<String>
    private let received = Mutex<[EnhancementRequest]>([])
    /// Whether the track files were still there while the models ran.
    private let sawTracks = Mutex(false)

    init(result: Result<[TranscriptLine], Failure>, languages: Set<String> = []) {
        self.result = result
        self.languages = languages
    }

    var requests: [EnhancementRequest] { received.withLock { $0 } }
    var tracksExistedDuringRun: Bool { sawTracks.withLock { $0 } }

    func supportsTranscription(in locale: Locale) -> Bool {
        languages.contains(locale.language.languageCode?.identifier ?? "")
    }

    func enhance(_ request: EnhancementRequest) -> AsyncThrowingStream<EnhancementProgress, Error> {
        received.withLock { $0.append(request) }
        if case .tracks(let tracks) = request.audio {
            let present = !tracks.isEmpty && tracks.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            sawTracks.withLock { $0 = present }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.identifyingSpeakers(0.5))
            switch result {
            case .success(let lines):
                continuation.yield(.finished(lines))
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

// MARK: - Tests

@MainActor
@Suite(.serialized) struct EnhancementWiringTests {
    private static let identified = [
        TranscriptLine(speaker: .others, start: 0.2, end: 0.5, text: "Hello", voice: 1),
        TranscriptLine(speaker: .others, start: 0.6, end: 1, text: "there", voice: 2),
    ]

    private struct Harness {
        let model: AppModel
        let enhancer: RecordingEnhancer
        let recorders: MadeRecorders
    }

    private func makeHarness(
        installed: Set<OptionalModel>,
        result: Result<[TranscriptLine], RecordingEnhancer.Failure> = .success(identified),
        languages: Set<String> = [],
        configure: (AppSettings) -> Void
    ) -> Harness {
        let suite = "MemoirTests.enhancement"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.autoSummarize = false
        settings.localeIdentifier = "en_US"
        configure(settings)

        let enhancer = RecordingEnhancer(result: result, languages: languages)
        let made = MadeRecorders()
        var services = Services.inert
        services.makeRecorder = { folder, keepTracks in
            let recorder = TrackRecorder(folder: folder, keepTracks: keepTracks)
            made.add(recorder)
            return recorder
        }
        services.makeTranscriber = { LineTranscriber() }
        services.optionalModels = InstalledModels(installed: installed)
        services.enhancer = enhancer
        let model = AppModel(settings: settings, container: .memoir(inMemory: true), services: services)
        return Harness(model: model, enhancer: enhancer, recorders: made)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func record(with model: AppModel) async throws -> Meeting {
        await model.startRecording()
        let id = try #require(model.recordingMeetingID)
        let meeting = try #require(model.meeting(with: id))
        await model.stopRecording()
        return meeting
    }

    private func cleanUp(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: RecordingFiles.folder(for: meeting.id))
    }

    private func trackURLs(of meeting: Meeting) -> [URL] {
        let folder = RecordingFiles.folder(for: meeting.id)
        return ["track-microphone.caf", "track-system.caf"].map { folder.appending(path: $0) }
    }

    @Test func nothingRunsWhileTheFeatureIsOff() async throws {
        let harness = makeHarness(installed: [.speakerIdentification]) { _ in }
        let (model, enhancer) = (harness.model, harness.enhancer)
        let meeting = try await record(with: model)
        defer { cleanUp(meeting) }

        #expect(harness.recorders.all.map(\.keepTracks) == [false])
        #expect(enhancer.requests.isEmpty)
        #expect(meeting.sortedLines.map(\.label) == ["Others"])
    }

    @Test func aSwitchedOnFeatureWithoutItsModelDoesNothing() async throws {
        let harness = makeHarness(installed: []) { $0.identifySpeakers = true }
        let (model, enhancer) = (harness.model, harness.enhancer)
        let meeting = try await record(with: model)
        defer { cleanUp(meeting) }

        #expect(harness.recorders.all.map(\.keepTracks) == [false])
        #expect(enhancer.requests.isEmpty)
    }

    @Test func speakersAreIdentifiedAfterTheRecording() async throws {
        let harness = makeHarness(installed: [.speakerIdentification]) { $0.identifySpeakers = true }
        let (model, enhancer) = (harness.model, harness.enhancer)
        let meeting = try await record(with: model)
        defer { cleanUp(meeting) }

        try await waitUntil { meeting.sortedLines.count == 2 && model.enhancing[meeting.id] == nil }
        #expect(harness.recorders.all.map(\.keepTracks) == [true])
        #expect(meeting.sortedLines.map(\.label) == ["Speaker 1", "Speaker 2"])

        let request = try #require(enhancer.requests.first)
        #expect(enhancer.requests.count == 1)
        #expect(request.identifySpeakers)
        #expect(!request.transcribe)
        guard case .tracks(let tracks) = request.audio else {
            Issue.record("A fresh recording should hand over its tracks")
            return
        }
        #expect(Set(tracks.keys) == [.microphone, .system])
        #expect(enhancer.tracksExistedDuringRun)
        // The live line's word timings travel with it, so it can be split between speakers.
        let line = try #require(request.lines.first)
        #expect(request.words[line.id]?.map(\.text) == ["Hello", "there"])

        try await waitUntil { trackURLs(of: meeting).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
    }

    @Test func transcriptionOnlyRunsForALanguageTheModelKnows() async throws {
        let harness = makeHarness(
            installed: [.enhancedTranscription], languages: ["de"]
        ) { $0.enhancedTranscription = true }
        let (model, enhancer) = (harness.model, harness.enhancer)
        let meeting = try await record(with: model)
        defer { cleanUp(meeting) }

        #expect(harness.recorders.all.map(\.keepTracks) == [false])
        #expect(enhancer.requests.isEmpty)
    }

    @Test func aFailureKeepsTheLiveTranscript() async throws {
        let harness = makeHarness(
            installed: [.speakerIdentification], result: .failure(.init())
        ) { $0.identifySpeakers = true }
        let (model, enhancer) = (harness.model, harness.enhancer)
        let meeting = try await record(with: model)
        defer { cleanUp(meeting) }

        try await waitUntil { model.enhancementErrors[meeting.id] != nil }
        #expect(enhancer.requests.count == 1)
        #expect(model.enhancementErrors[meeting.id] == "The model gave up.")
        #expect(meeting.sortedLines.map(\.text) == ["Hello there"])
        #expect(meeting.sortedLines.map(\.label) == ["Others"])
        #expect(model.enhancing[meeting.id] == nil)
        try await waitUntil { trackURLs(of: meeting).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
    }

    @Test func renamingASpeakerRenamesAllTheirLines() async throws {
        let harness = makeHarness(installed: [.speakerIdentification]) { $0.identifySpeakers = true }
        let model = harness.model
        let meeting = try await record(with: model)
        defer { cleanUp(meeting) }
        try await waitUntil { meeting.sortedLines.count == 2 && model.enhancing[meeting.id] == nil }

        model.renameSpeaker(2, to: "  Dana  ", in: meeting)
        #expect(meeting.sortedLines.map(\.label) == ["Speaker 1", "Dana"])

        model.renameSpeaker(2, to: "", in: meeting)
        #expect(meeting.sortedLines.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(meeting.speakerNamesData == nil)
    }

    @Test func identifyingAgainUsesTheMixAndForgetsTheOldNames() async throws {
        let harness = makeHarness(installed: [.speakerIdentification]) { $0.identifySpeakers = true }
        let (model, enhancer) = (harness.model, harness.enhancer)
        let meeting = try await record(with: model)
        defer { cleanUp(meeting) }
        try await waitUntil { meeting.sortedLines.count == 2 && model.enhancing[meeting.id] == nil }
        model.renameSpeaker(1, to: "Dana", in: meeting)

        await model.identifySpeakers(in: meeting)

        #expect(enhancer.requests.count == 2)
        let request = try #require(enhancer.requests.last)
        guard case .mixed(let url) = request.audio else {
            Issue.record("An existing recording only has its mix")
            return
        }
        #expect(url == meeting.audioURL)
        #expect(!request.transcribe)
        // The voices were numbered afresh, so "Dana" could now be someone else.
        #expect(meeting.sortedLines.map(\.label) == ["Speaker 1", "Speaker 2"])
    }
}

private nonisolated final class MadeRecorders: Sendable {
    private let recorders = Mutex<[TrackRecorder]>([])

    func add(_ recorder: TrackRecorder) { recorders.withLock { $0.append(recorder) } }
    var all: [TrackRecorder] { recorders.withLock { $0 } }
}
