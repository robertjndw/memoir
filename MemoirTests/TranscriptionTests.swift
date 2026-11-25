import AVFoundation
import Foundation
import Speech
import Synchronization
import Testing
@testable import Memoir

@Suite("Transcription units")
struct TranscriptionUnitTests {
    @Test func timelineIsContiguousAndAbsorbsJitter() {
        var timeline = SampleTimeline(sampleRate: 16_000)
        #expect(timeline.place(time: 0, frameCount: 1600).start == 0)
        // 10 ms late and 5 ms early both snap onto the contiguous position.
        #expect(timeline.place(time: 0.11, frameCount: 1600) == .init(start: 1600, silence: 1600..<1600))
        #expect(timeline.place(time: 0.195, frameCount: 1600) == .init(start: 3200, silence: 3200..<3200))
    }

    @Test func timelineNeverOverlaps() {
        var timeline = SampleTimeline(sampleRate: 16_000)
        _ = timeline.place(time: 1, frameCount: 16_000)
        // A buffer claiming to start a full second early still lands after the previous one.
        #expect(timeline.place(time: 1, frameCount: 1600).start == 32_000)
    }

    @Test func timelineStartsLateAndFillsGapsWithSilence() {
        var timeline = SampleTimeline(sampleRate: 16_000)
        #expect(timeline.place(time: 12.5, frameCount: 1600) == .init(start: 200_000, silence: 200_000..<200_000))
        #expect(timeline.place(time: 20, frameCount: 1600) == .init(start: 320_000, silence: 201_600..<320_000))
        #expect(timeline.time(ofSample: 320_000).seconds == 20)
    }

    @Test func timelineJumpsAbsurdGaps() {
        var timeline = SampleTimeline(sampleRate: 16_000, maximumFillSeconds: 60)
        _ = timeline.place(time: 0, frameCount: 1600)
        #expect(timeline.place(time: 3600, frameCount: 1600).silence.isEmpty)
    }

    @Test func feedConvertsAndRebuildsOnFormatChange() throws {
        let analyzerFormat = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let feed = AnalyzerFeed(analyzerFormat: analyzerFormat)

        let stereo48 = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var produced: AVAudioFrameCount = 0
        var previousEnd = 3.0
        for index in 0..<10 {
            for input in feed.inputs(for: Self.tone(format: stereo48, frames: 4800, time: 3 + Double(index) * 0.1)) {
                let start = try #require(input.bufferStartTime).seconds
                #expect(input.buffer.format == analyzerFormat)
                #expect(abs(start - previousEnd) < 0.001)
                previousEnd = start + Double(input.buffer.frameLength) / 16_000
                produced += input.buffer.frameLength
            }
        }
        // Resampler latency may hold back a few samples, never more.
        #expect(produced > 15_500 && produced <= 16_000, "produced \(produced)")

        // A device switch after a 1.5 s gap: new converter, gap filled with silence.
        let mono44 = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let switched = feed.inputs(for: Self.tone(format: mono44, frames: 4410, time: 5.5))
        let starts = try switched.map { try #require($0.bufferStartTime).seconds }
        #expect(abs(starts[0] - previousEnd) < 0.001)
        #expect(starts.last == 5.5)
        #expect(try #require(switched.last).buffer.frameLength > 1000)
    }

    @Test func modelGateIsFirstWins() async {
        let gate = ModelGate()
        async let waiter = gate.wait()
        await gate.open(ready: false)
        await gate.open(ready: true)
        #expect(await waiter == false)
        #expect(await gate.wait() == false)
    }

    @Test func backlogKeepsTheNewestAudio() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        var backlog = CaptureBacklog(limit: 3)
        var drops: [Int] = []
        for index in 0..<10 where backlog.append(Self.tone(format: format, frames: 16_000, time: Double(index))) {
            drops.append(index)
        }
        #expect(drops == Array(3..<10))
        #expect(backlog.count == 3)
        #expect(abs(backlog.duration - 3) < 0.001)
        let kept = backlog.removeAll()
        #expect(kept.map(\.time) == [7, 8, 9])
        #expect(backlog.count == 0 && backlog.duration == 0)
    }

    @Test func backlogKeepsAChunkLongerThanTheLimit() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        var backlog = CaptureBacklog(limit: 1)
        let droppedFirst = backlog.append(Self.tone(format: format, frames: 32_000, time: 0))
        let droppedSecond = backlog.append(Self.tone(format: format, frames: 32_000, time: 2))
        #expect(!droppedFirst && droppedSecond)
        let kept = backlog.removeAll()
        #expect(kept.map(\.time) == [2])
    }

    /// Dropping the oldest audio must not shift what is left: the analyzer starts at the first
    /// kept chunk's recording time, with no silence before it and no gap after it.
    @Test func timelineStartsAtTheFirstKeptChunkAfterDropping() throws {
        let analyzerFormat = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        // 1.55 rather than 1.5 keeps the expectation clear of floating point sums.
        var backlog = CaptureBacklog(limit: 1.55)
        for index in 0..<20 {
            _ = backlog.append(Self.tone(format: format, frames: 1600, time: Double(index) * 0.1))
        }
        let kept = backlog.removeAll()
        #expect(kept.count == 15)

        let feed = AnalyzerFeed(analyzerFormat: analyzerFormat)
        let inputs = kept.flatMap { feed.inputs(for: $0) } + feed.inputs(for: Self.tone(format: format, frames: 1600, time: 2))
        let starts = try inputs.map { try #require($0.bufferStartTime).seconds }
        #expect(abs(try #require(starts.first) - 0.5) < 0.0001)
        #expect(abs(try #require(starts.last) - 2) < 0.0001)
        var previousEnd = 0.5
        for (input, start) in zip(inputs, starts) {
            #expect(abs(start - previousEnd) < 0.0001)
            previousEnd = start + Double(input.buffer.frameLength) / 16_000
        }
    }

    @Test func bufferingHoldsTheNewestAudioUntilTheModelIsReady() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let gate = ModelGate()
        let (input, capture) = AsyncStream.makeStream(of: CapturedAudio.self)
        let (drops, dropped) = AsyncStream.makeStream(of: Void.self)
        let output = SpeechTranscriptionPipeline.buffered(input, until: gate, limit: 3) { dropped.yield() }

        for index in 0..<4 {
            capture.yield(Self.tone(format: format, frames: 16_000, time: Double(index)))
        }
        // The fourth second overflows the backlog. Waiting for that makes sure the gate opens
        // only after the first four chunks were buffered.
        var dropIterator = drops.makeAsyncIterator()
        _ = await dropIterator.next()
        await gate.open(ready: true)
        capture.yield(Self.tone(format: format, frames: 16_000, time: 4))
        capture.finish()

        var times: [TimeInterval] = []
        for await chunk in output { times.append(chunk.time) }
        #expect(times == [1, 2, 3, 4])
    }

    @Test func bufferingDiscardsOnceTheModelIsUnavailable() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let gate = ModelGate()
        await gate.open(ready: false)
        let (input, capture) = AsyncStream.makeStream(of: CapturedAudio.self)
        let output = SpeechTranscriptionPipeline.buffered(input, until: gate, limit: 3) {}
        for index in 0..<5 {
            capture.yield(Self.tone(format: format, frames: 16_000, time: Double(index)))
        }
        capture.finish()
        var count = 0
        for await _ in output { count += 1 }
        #expect(count == 0)
    }

    @Test func issuesAreReportedOnce() {
        let sent = Mutex<[RecordingIssue]>([])
        let reporter = IssueReporter { issue in sent.withLock { $0.append(issue) } }
        for _ in 0..<3 {
            reporter.report(.liveTranscriptIncomplete)
            reporter.report(.transcriptionStopped(.me))
        }
        reporter.report(.transcriptionStopped(.others))
        #expect(sent.withLock { $0 } == [.liveTranscriptIncomplete, .transcriptionStopped(.me), .transcriptionStopped(.others)])
    }

    @Test func finishWithoutStartReturns() async {
        await SpeechTranscriptionPipeline().finish()
    }

    @Test func modelStatusMapping() {
        #expect(SpeechModelManager.status(from: .installed) == .installed)
        #expect(SpeechModelManager.status(from: .supported) == .notInstalled)
        #expect(SpeechModelManager.status(from: .downloading) == .downloading)
        #expect(SpeechModelManager.status(from: .unsupported) == .unsupported)
    }

    @Test func unsupportedLocaleThrows() async {
        let pipeline = SpeechTranscriptionPipeline()
        let streams = TranscriptionFixture.streams(microphone: [], system: [])
        await #expect(throws: TranscriptionError.self) {
            _ = try await pipeline.start(streams: streams, locale: Locale(identifier: "tlh_XX"), contextualStrings: [])
        }
        #expect(await SpeechModelManager().status(for: Locale(identifier: "tlh_XX")) == .unsupported)
    }

    static func tone(format: AVAudioFormat, frames: AVAudioFrameCount, time: TimeInterval) -> CapturedAudio {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = 0.2 * sin(Float(frame) * 0.05)
            }
        }
        return CapturedAudio(buffer: buffer, time: time)
    }
}

/// Real speech through the real model. Skipped when the en-US model cannot be installed.
@Suite(
    "Transcription end to end",
    .serialized,
    .enabled("en-US speech model is installed or installable") { await TranscriptionFixture.modelReady() },
    .timeLimit(.minutes(10))
)
struct TranscriptionEndToEndTests {
    static let sentenceA = "The quick brown fox jumps over the lazy dog."
    static let sentenceB = "Please send the quarterly report by Friday afternoon."

    @Test func transcribesFile() async throws {
        let url = try await TranscriptionFixture.speech(Self.sentenceA, as: "m4a")
        let clock = ContinuousClock()
        let began = clock.now
        var updates: [TranscriptUpdate] = []
        for try await update in SpeechTranscriptionPipeline().transcribe(file: url, locale: Locale(identifier: "en-US")) {
            updates.append(update)
        }
        TranscriptionFixture.report("file", updates, elapsed: clock.now - began)

        #expect(updates.allSatisfy { $0.isFinal && $0.speaker == .unknown })
        let text = TranscriptionFixture.text(of: updates)
        for word in ["quick", "brown", "fox", "lazy", "dog"] {
            #expect(text.contains(word), "missing \(word) in \(text)")
        }
        TranscriptionFixture.expectSaneTimes(updates, within: 0...(try TranscriptionFixture.duration(of: url)) + 0.5)
    }

    @Test(arguments: [0.0, 7.25])
    func transcribesLiveStreamAtOffset(offset: TimeInterval) async throws {
        let url = try await TranscriptionFixture.speech(Self.sentenceA, as: "aiff")
        let chunks = try TranscriptionFixture.chunks(of: url, startingAt: offset)
        let duration = try TranscriptionFixture.duration(of: url)

        // Paced at real time once, so the volatile behavior is what a live meeting would see.
        let updates = try await TranscriptionFixture.runLive(
            microphone: chunks, system: [], pace: offset == 0 ? 1 : 0, label: "live offset \(offset)")

        let finals = updates.filter(\.isFinal)
        #expect(finals.allSatisfy { $0.speaker == .me })
        let text = TranscriptionFixture.text(of: finals)
        for word in ["quick", "fox", "lazy", "dog"] {
            #expect(text.contains(word), "missing \(word) in \(text)")
        }
        TranscriptionFixture.expectSaneTimes(finals, within: (offset - 0.05)...(offset + duration + 0.5))
    }

    @Test func liveStreamKeepsRecordingTimeAcrossGap() async throws {
        let first = try await TranscriptionFixture.speech(Self.sentenceA, as: "aiff")
        let second = try await TranscriptionFixture.speech(Self.sentenceB, as: "aiff")
        let firstStart = 1.5
        let secondStart = firstStart + (try TranscriptionFixture.duration(of: first)) + 4
        let chunks = try TranscriptionFixture.chunks(of: first, startingAt: firstStart)
            + TranscriptionFixture.chunks(of: second, startingAt: secondStart)

        // System audio this time, with the microphone unavailable.
        let updates = try await TranscriptionFixture.runLive(microphone: [], system: chunks, pace: 0, label: "gap")
        let finals = updates.filter(\.isFinal)
        #expect(finals.allSatisfy { $0.speaker == .others })
        TranscriptionFixture.expectSaneTimes(finals, within: (firstStart - 0.05)...(secondStart + 5))

        let reportFinals = finals.filter { $0.text.lowercased().contains("report") }
        #expect(!reportFinals.isEmpty, "no final mentions the report: \(TranscriptionFixture.text(of: finals))")
        for final in reportFinals {
            #expect(final.end > secondStart, "\(final.text) ends at \(final.end), before the second sentence started")
        }
        let foxFinals = finals.filter { $0.text.lowercased().contains("fox") }
        #expect(!foxFinals.isEmpty)
        for final in foxFinals {
            #expect(final.start < secondStart)
        }
    }

    @Test func bothSourcesTranscribeIndependently() async throws {
        let a = try await TranscriptionFixture.speech(Self.sentenceA, as: "aiff")
        let b = try await TranscriptionFixture.speech(Self.sentenceB, as: "aiff")
        let updates = try await TranscriptionFixture.runLive(
            microphone: try TranscriptionFixture.chunks(of: a, startingAt: 0),
            system: try TranscriptionFixture.chunks(of: b, startingAt: 2),
            pace: 0,
            label: "two sources"
        )
        let me = TranscriptionFixture.text(of: updates.filter { $0.isFinal && $0.speaker == .me })
        let others = TranscriptionFixture.text(of: updates.filter { $0.isFinal && $0.speaker == .others })
        #expect(me.contains("fox") && !me.contains("report"))
        #expect(others.contains("report") && !others.contains("fox"))
    }
}

nonisolated enum TranscriptionFixture {
    static let locale = Locale(identifier: "en-US")

    static func modelReady() async -> Bool {
        do {
            let resolved = try await SpeechAssets.resolve(locale)
            try await SpeechAssets.install(
                for: SpeechAssets.makeTranscriber(locale: resolved, volatileResults: true), locale: resolved)
            return true
        } catch {
            print("Speech model unavailable, skipping: \(error)")
            return false
        }
    }

    static func streams(microphone: [CapturedAudio], system: [CapturedAudio], pace: Double = 0) -> CaptureStreams {
        func stream(_ chunks: [CapturedAudio]) -> AsyncStream<CapturedAudio> {
            AsyncStream { continuation in
                let task = Task {
                    for chunk in chunks {
                        if pace > 0 {
                            try? await Task.sleep(for: .seconds(Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate / pace))
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return CaptureStreams(
            microphone: stream(microphone),
            system: stream(system),
            levels: AsyncStream { $0.finish() },
            unavailable: Set([microphone.isEmpty ? AudioSource.microphone : nil, system.isEmpty ? .system : nil].compactMap { $0 })
        )
    }

    /// Feeds the chunks, waits for both streams to drain, then finishes like AppModel does.
    static func runLive(
        microphone: [CapturedAudio],
        system: [CapturedAudio],
        pace: Double,
        label: String
    ) async throws -> [TranscriptUpdate] {
        let pipeline = SpeechTranscriptionPipeline()
        let audioDuration = (microphone + system).map { $0.time + Double($0.buffer.frameLength) / $0.buffer.format.sampleRate }.max() ?? 0
        let clock = ContinuousClock()
        let began = clock.now
        let events = try await pipeline.start(
            streams: streams(microphone: microphone, system: system, pace: pace),
            locale: locale,
            contextualStrings: ["Memoir"]
        )
        let collector = Task {
            var collected: [(TranscriptUpdate, Duration)] = []
            var issues: [RecordingIssue] = []
            for await event in events {
                switch event {
                case .update(let update): collected.append((update, clock.now - began))
                case .issue(let issue): issues.append(issue)
                }
            }
            #expect(issues.isEmpty)
            return collected
        }
        if pace > 0 {
            // AppModel calls finish only after capture stopped, so wait out the paced audio.
            let fed = (microphone.isEmpty ? system : microphone).reduce(0.0) { $0 + Double($1.buffer.frameLength) / $1.buffer.format.sampleRate }
            try await Task.sleep(for: .seconds(fed / pace + 0.2))
        }
        let finishStarted = clock.now - began
        await pipeline.finish()
        let collected = await collector.value
        print("[\(label)] audio ends at \(fmt(audioDuration))s on the timeline, finish() called at \(finishStarted), stream ended at \(clock.now - began)")
        for (update, at) in collected {
            print("[\(label)] +\(at) \(update.isFinal ? "FINAL" : "volatile") \(update.speaker.rawValue) [\(fmt(update.start))-\(fmt(update.end))] \(update.text)")
        }
        return collected.map(\.0)
    }

    static func report(_ label: String, _ updates: [TranscriptUpdate], elapsed: Duration) {
        print("[\(label)] \(updates.count) updates in \(elapsed)")
        for update in updates {
            print("[\(label)] \(update.isFinal ? "FINAL" : "volatile") [\(fmt(update.start))-\(fmt(update.end))] \(update.text)")
        }
    }

    static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    static func text(of updates: [TranscriptUpdate]) -> String {
        updates.map(\.text).joined(separator: " ").lowercased()
    }

    static func expectSaneTimes(_ finals: [TranscriptUpdate], within bounds: ClosedRange<TimeInterval>) {
        let nonEmpty = finals.filter { !$0.text.isEmpty }
        #expect(!nonEmpty.isEmpty)
        var previousEnd = -Double.infinity
        for update in nonEmpty {
            #expect(update.start <= update.end)
            #expect(bounds.contains(update.start) && bounds.contains(update.end), "\(update.text) at \(update.start)-\(update.end) outside \(bounds)")
            #expect(update.start >= previousEnd - 0.01, "\(update.text) starts at \(update.start) before previous end \(previousEnd)")
            previousEnd = update.end
        }
    }

    static func speech(_ sentence: String, as fileExtension: String) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MemoirTranscriptionTests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(sentence.filter(\.isLetter).prefix(32))
        let aiff = directory.appending(path: "\(name).aiff")
        if !FileManager.default.fileExists(atPath: aiff.path) {
            try run("/usr/bin/say", ["-o", aiff.path, sentence])
        }
        guard fileExtension == "m4a" else { return aiff }
        let m4a = directory.appending(path: "\(name).m4a")
        if !FileManager.default.fileExists(atPath: m4a.path) {
            try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", aiff.path, m4a.path])
        }
        return m4a
    }

    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// 100 ms chunks in the file's native format, stamped on the recording timeline.
    static func chunks(of url: URL, startingAt offset: TimeInterval) throws -> [CapturedAudio] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let size = AVAudioFrameCount(format.sampleRate / 10)
        var chunks: [CapturedAudio] = []
        var position: AVAudioFramePosition = 0
        while position < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size)!
            try file.read(into: buffer, frameCount: size)
            guard buffer.frameLength > 0 else { break }
            chunks.append(CapturedAudio(buffer: buffer, time: offset + Double(position) / format.sampleRate))
            position += AVAudioFramePosition(buffer.frameLength)
        }
        return chunks
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"])
        }
    }
}
