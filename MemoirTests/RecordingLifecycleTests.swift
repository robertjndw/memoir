import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Memoir

// MARK: - Fakes

/// Opens once and stays open. Lets a test hold an engine call at a point of its choosing.
nonisolated final class TestGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func open() { continuation.finish() }

    func wait() async {
        for await _ in stream {}
    }
}

private nonisolated final class FakeRecorder: AudioRecording {
    let folder: URL
    let stopGate: TestGate?
    /// Leaves a part behind and reports no file, the way the recorder does when the mixdown throws.
    let failMixdown: Bool

    init(folder: URL, stopGate: TestGate? = nil, failMixdown: Bool = false) {
        self.folder = folder
        self.stopGate = stopGate
        self.failMixdown = failMixdown
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
        await stopGate?.wait()
        if failMixdown {
            FileManager.default.createFile(atPath: folder.appending(path: "part-microphone-1-0ms.caf").path, contents: Data())
            return RecordingOutput(audioURL: nil, duration: 3)
        }
        return RecordingOutput(audioURL: folder.appending(path: "audio.m4a"), duration: 3)
    }
}

/// Delivers one final line when finished, like a recognizer flushing its last result.
private actor FakeTranscriber: Transcribing {
    let startGate: TestGate?
    let finishGate: TestGate?
    private var continuation: AsyncStream<TranscriptEvent>.Continuation?

    init(startGate: TestGate? = nil, finishGate: TestGate? = nil) {
        self.startGate = startGate
        self.finishGate = finishGate
    }

    func start(streams: CaptureStreams, locale: Locale, contextualStrings: [String]) async throws
        -> AsyncStream<TranscriptEvent>
    {
        await startGate?.wait()
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
        self.continuation = continuation
        return stream
    }

    func finish() async {
        await finishGate?.wait()
        continuation?.yield(.update(TranscriptUpdate(speaker: .me, text: "Last words", start: 0.2, end: 1, isFinal: true)))
        continuation?.finish()
    }

    nonisolated func transcribe(file: URL, locale: Locale) -> AsyncThrowingStream<TranscriptUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Recording lifecycle

@MainActor
@Suite(.serialized) struct RecordingLifecycleTests {
    private func makeModel(
        stopGate: TestGate? = nil,
        failMixdown: Bool = false,
        transcriber: @escaping @Sendable () -> any Transcribing = { FakeTranscriber() }
    ) -> AppModel {
        let suite = "MemoirTests.lifecycle"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var services = Services.inert
        services.makeRecorder = { folder, _ in FakeRecorder(folder: folder, stopGate: stopGate, failMixdown: failMixdown) }
        services.makeTranscriber = transcriber
        return AppModel(settings: AppSettings(defaults: defaults), container: .memoir(inMemory: true), services: services)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    /// Recording starts create the meeting's real folder; it must not outlive the test.
    private func cleanUp(_ id: UUID) {
        try? FileManager.default.removeItem(at: RecordingFiles.folder(for: id))
    }

    @Test func finishingMeetingCannotBeDeleted() async throws {
        let gate = TestGate()
        let model = makeModel(stopGate: gate)
        await model.startRecording()
        let id = try #require(model.recordingMeetingID)
        defer { cleanUp(id) }
        let meeting = try #require(model.meeting(with: id))
        #expect(model.activeMeetingID == id)

        let stop = Task { await model.stopRecording() }
        try await waitUntil { model.recordingState == .finishing(id) }
        #expect(model.recordingMeetingID == nil)
        #expect(model.activeMeetingID == id)

        model.delete(meeting)
        #expect(model.meeting(with: id) != nil)

        gate.open()
        await stop.value
        #expect(model.recordingState == .idle)
        #expect(model.activeMeetingID == nil)
        #expect(meeting.status == .ready)

        model.delete(meeting)
        #expect(model.meeting(with: id) == nil)
    }

    @Test func audioIsSavedBeforeTheTranscriptDrains() async throws {
        let finishGate = TestGate()
        let model = makeModel(transcriber: { FakeTranscriber(finishGate: finishGate) })
        await model.startRecording()
        let id = try #require(model.recordingMeetingID)
        defer { cleanUp(id) }
        let meeting = try #require(model.meeting(with: id))

        let stop = Task { await model.stopRecording() }
        try await waitUntil { meeting.hasAudio }
        #expect(model.recordingState == .finishing(id))
        #expect(meeting.duration == 3)
        #expect(!meeting.hasChanges)

        finishGate.open()
        await stop.value
        #expect(meeting.sortedLines.map(\.text) == ["Last words"])
    }

    @Test func finishRecordingWaitsForAStopInFlight() async throws {
        let gate = TestGate()
        let model = makeModel(stopGate: gate)
        await model.startRecording()
        let id = try #require(model.recordingMeetingID)
        defer { cleanUp(id) }

        let stop = Task { await model.stopRecording() }
        try await waitUntil { model.recordingState == .finishing(id) }
        let finish = Task { await model.finishRecording() }
        // Held well past where a deadline poll would have spun; the stop must still complete.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.recordingState == .finishing(id))
        gate.open()
        #expect(await finish.value == .saved(id))
        await stop.value
        #expect(model.recordingState == .idle)
    }

    @Test func stopDuringTranscriberStartKeepsTheTranscript() async throws {
        let startGate = TestGate()
        let model = makeModel(transcriber: { FakeTranscriber(startGate: startGate) })
        let start = Task { await model.startRecording() }
        try await waitUntil { model.isRecording }
        let id = try #require(model.recordingMeetingID)
        defer { cleanUp(id) }

        let stop = Task { await model.stopRecording() }
        try await waitUntil { model.recordingState == .finishing(id) }
        startGate.open()
        await start.value
        await stop.value

        let meeting = try #require(model.meeting(with: id))
        #expect(meeting.sortedLines.map(\.text) == ["Last words"])
        #expect(meeting.status == .ready)
    }

    @Test func failedMixdownIsReported() async throws {
        let model = makeModel(failMixdown: true)
        await model.startRecording()
        let id = try #require(model.recordingMeetingID)
        defer { cleanUp(id) }

        #expect(await model.finishRecording() == .savedWithoutAudio(id))
        #expect(model.errorMessage != nil)
        #expect(model.meeting(with: id)?.hasAudio == false)
    }

    @Test func nothingToFinishWhenTheStartFails() async {
        // The inert recorder refuses to start, like one without any audio source.
        let model = AppModel(settings: makeModel().settings, container: .memoir(inMemory: true), services: .inert)
        await model.startRecording()
        #expect(model.recordingState == .idle)
        #expect(model.errorMessage != nil)
        #expect(await model.finishRecording() == .notStarted)
    }

    @Test func interruptedRecordingGetsItsAudioBack() async throws {
        let model = makeModel()
        let meeting = Meeting(title: "Crashed")
        model.context.insert(meeting)
        try model.context.save()
        let folder = RecordingFiles.folder(for: meeting.id)
        defer { cleanUp(meeting.id) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try AudioFixtures.part(
            in: folder, name: "part-microphone-1-500ms", offset: 0.5,
            buffer: AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 1, seconds: 1)
        )

        await model.recoverAudio()
        #expect(meeting.hasAudio)
        #expect(abs(meeting.duration - 1.5) < 0.01)
        #expect(FileManager.default.fileExists(atPath: RecordingFiles.audioURL(for: meeting.id).path))
        #expect(!RecordingRecovery.hasParts(in: folder))
    }
}

// MARK: - Recovery from part files

@Suite struct RecordingRecoveryTests {
    @Test func partNamesParse() {
        #expect(RecordingRecovery.parse("part-microphone-1-0ms.caf")
            == .init(source: .microphone, index: 1, offset: 0))
        #expect(RecordingRecovery.parse("part-system-12-2100ms.caf")
            == .init(source: .system, index: 12, offset: 2.1))
        #expect(RecordingRecovery.parse("part-system-1--15ms.caf")
            == .init(source: .system, index: 1, offset: -0.015))
        #expect(RecordingRecovery.parse("audio.m4a") == nil)
        #expect(RecordingRecovery.parse(".audio-mixing.m4a") == nil)
        #expect(RecordingRecovery.parse("part-camera-1-0ms.caf") == nil)
        #expect(RecordingRecovery.parse("part-microphone-1-0ms.caf.tmp") == nil)
    }

    /// Ties the parser to the names `SourcePipeline` writes.
    @Test func segmentsRebuiltFromPipelineParts() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, continuation) = AsyncStream.makeStream(of: CapturedAudio.self)
        let start = HostClock.now
        let pipeline = SourcePipeline(
            source: .system, folder: folder, startHostTime: start,
            continuation: continuation, levels: nil
        )
        pipeline.process(
            AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 2, seconds: 1),
            hostTime: start + HostClock.ticks(forSeconds: 0.25)
        )
        pipeline.process(
            AudioFixtures.sine(frequency: 440, sampleRate: 44_100, channels: 1, seconds: 0.5),
            hostTime: start + HostClock.ticks(forSeconds: 2)
        )
        let written = pipeline.finish()

        let rebuilt = RecordingRecovery.segments(in: folder)
        #expect(rebuilt.map(\.url.lastPathComponent) == written.map(\.url.lastPathComponent))
        #expect(rebuilt.map(\.frames) == written.map(\.frames))
        #expect(rebuilt.map(\.sampleRate) == written.map(\.sampleRate))
        for (a, b) in zip(rebuilt, written) {
            #expect(abs(a.offset - b.offset) < 0.001)
        }
    }

    @Test func recoveryMixesPartsAndCanRunAgain() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try AudioFixtures.part(
            in: folder, name: "part-microphone-1-0ms", offset: 0,
            buffer: AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 1, seconds: 1)
        )
        _ = try AudioFixtures.part(
            in: folder, name: "part-system-1-2000ms", offset: 2,
            buffer: AudioFixtures.sine(frequency: 660, sampleRate: 48_000, channels: 2, seconds: 1)
        )

        let duration = try #require(try RecordingRecovery.recoverNow(folder: folder))
        #expect(abs(duration - 3) < 0.01)
        let audio = folder.appending(path: "audio.m4a")
        #expect(try AudioFixtures.rms(of: audio, from: 2.2, to: 2.8) > 0.2)
        #expect(!RecordingRecovery.hasParts(in: folder))

        // A second run finds the finished file and adopts it.
        let again = try #require(try RecordingRecovery.recoverNow(folder: folder))
        #expect(abs(again - duration) < 0.05)
    }

    @Test func existingMixIsAdoptedAndLeftoverPartsRemoved() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let part = try AudioFixtures.part(
            in: folder, name: "part-microphone-1-0ms", offset: 0,
            buffer: AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 1, seconds: 2)
        )
        let audio = folder.appending(path: "audio.m4a")
        _ = try #require(try AudioMixdown.mix([part], to: audio))
        let modified = try FileManager.default.attributesOfItem(atPath: audio.path)[.modificationDate] as? Date

        let duration = try #require(try RecordingRecovery.recoverNow(folder: folder))
        #expect(abs(duration - 2) < 0.05)
        #expect(!RecordingRecovery.hasParts(in: folder))
        #expect(try FileManager.default.attributesOfItem(atPath: audio.path)[.modificationDate] as? Date == modified)
    }

    @Test func unreadablePartsAreKept() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = folder.appending(path: "part-microphone-1-0ms.caf")
        FileManager.default.createFile(atPath: broken.path, contents: Data())

        #expect(try RecordingRecovery.recoverNow(folder: folder) == nil)
        #expect(FileManager.default.fileExists(atPath: broken.path))
        #expect(try RecordingRecovery.recoverNow(folder: folder.appending(path: "missing")) == nil)
    }
}
