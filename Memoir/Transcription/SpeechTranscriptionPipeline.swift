import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

/// Live transcription of the two capture streams, plus file transcription. Single use.
///
/// Speech has no diarization, so each source gets its own analyzer and its own speaker.
actor SpeechTranscriptionPipeline: Transcribing {
    /// How long `finish()` waits for a model download that has not completed yet. After that the
    /// buffered audio is dropped; the recording file can still be transcribed later.
    private let modelWaitAtFinish: Duration = .seconds(30)

    /// Audio held per source while the model downloads. Captured buffers are float PCM at the
    /// device rate, so five minutes are roughly 60 MB for a mono microphone and 115 MB for
    /// stereo system audio at 48 kHz. That covers a typical download, and it is also all the
    /// analyzer has to catch up on once the model arrives.
    static let backlogLimit: TimeInterval = 300

    private var didStart = false
    private var didFinish = false
    private var gate: ModelGate?
    private var sources: [Task<Void, Never>] = []
    private var output: AsyncStream<TranscriptEvent>.Continuation?

    init() {}

    func start(
        streams: CaptureStreams,
        locale: Locale,
        contextualStrings: [String]
    ) async throws -> AsyncStream<TranscriptEvent> {
        precondition(!didStart, "SpeechTranscriptionPipeline is single use")
        didStart = true

        let (events, output) = AsyncStream.makeStream(of: TranscriptEvent.self)
        let issues = IssueReporter { output.yield(.issue($0)) }
        let gate = ModelGate()

        // Buffering starts before any await, so nothing is lost while the locale and model
        // are checked, and producers using a bounded buffering policy never drop audio.
        let onDrop: @Sendable () -> Void = { issues.report(.liveTranscriptIncomplete) }
        let microphone = Self.buffered(streams.microphone, until: gate, limit: Self.backlogLimit, onDrop: onDrop)
        let system = Self.buffered(streams.system, until: gate, limit: Self.backlogLimit, onDrop: onDrop)

        let resolved: Locale
        do {
            resolved = try await SpeechAssets.resolve(locale)
            let probe = SpeechAssets.makeTranscriber(locale: resolved, volatileResults: true)
            switch await AssetInventory.status(forModules: [probe]) {
            case .installed:
                await gate.open(ready: true)
            case .unsupported:
                throw TranscriptionError.unsupportedLocale(locale)
            default:
                Task.detached {
                    do {
                        try await SpeechAssets.install(for: probe, locale: resolved)
                        await gate.open(ready: true)
                    } catch {
                        SpeechAssets.log.error("Model install failed: \(error.localizedDescription, privacy: .public)")
                        await gate.open(ready: false)
                    }
                }
            }
        } catch {
            // The buffering tasks keep reading the capture streams for the whole meeting. A
            // closed gate makes them discard the audio instead of holding a backlog for nobody.
            await gate.open(ready: false)
            output.finish()
            throw error
        }

        self.gate = gate
        self.output = output
        sources = [(microphone, Speaker.me), (system, Speaker.others)].map { input, speaker in
            Task.detached {
                await SourceTranscription.run(
                    input: input,
                    speaker: speaker,
                    locale: resolved,
                    contextualStrings: contextualStrings,
                    gate: gate,
                    output: output,
                    issues: issues
                )
            }
        }
        return events
    }

    func finish() async {
        guard let gate, let output, !didFinish else { return }
        didFinish = true

        // Opening the gate is first-wins, so this only matters if the model is still missing.
        let wait = modelWaitAtFinish
        let timeout = Task.detached {
            try? await Task.sleep(for: wait)
            await gate.open(ready: false)
        }
        for source in sources {
            await source.value
        }
        timeout.cancel()
        output.finish()
    }

    nonisolated func transcribe(file: URL, locale: Locale) -> AsyncThrowingStream<TranscriptUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await FileTranscription.run(file: file, locale: locale) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Holds the newest `limit` seconds of `input` until the gate opens, then forwards
    /// everything. Once the gate opened false the audio is discarded. The input is read to its
    /// end in every case: the recorder's streams are unbounded, so anything left unread there
    /// would pile up for the rest of the meeting.
    static func buffered(
        _ input: AsyncStream<CapturedAudio>,
        until gate: ModelGate,
        limit: TimeInterval,
        onDrop: @escaping @Sendable () -> Void
    ) -> AsyncStream<CapturedAudio> {
        let (stream, continuation) = AsyncStream.makeStream(of: CapturedAudio.self, bufferingPolicy: .unbounded)
        Task.detached {
            var backlog = CaptureBacklog(limit: limit)
            var ready: Bool?
            for await chunk in input {
                if ready == nil { ready = await gate.current }
                switch ready {
                case nil:
                    if backlog.append(chunk) { onDrop() }
                case true?:
                    for held in backlog.removeAll() { continuation.yield(held) }
                    continuation.yield(chunk)
                case false?:
                    backlog.removeAll()
                }
            }
            // Capture ended before the model was ready: the consumer still waits for the gate.
            if ready != false {
                for held in backlog.removeAll() { continuation.yield(held) }
            }
            continuation.finish()
        }
        return stream
    }
}

/// Audio waiting for the speech model. Keeps the newest `limit` seconds and drops the oldest,
/// so what is left is one contiguous run that `SampleTimeline` places at its own recording
/// time, like a source that started late. Dropping the newest instead would leave a hole
/// between the backlog and the live audio after it, which the timeline would have to fill
/// with silence (up to ten minutes of it) or jump over.
nonisolated struct CaptureBacklog {
    let limit: TimeInterval
    private(set) var duration: TimeInterval = 0
    // Dropped entries are set to nil right away so their buffers are freed, and the array is
    // compacted only now and then; removing from the front on every append would be quadratic.
    private var chunks: [CapturedAudio?] = []
    private var head = 0

    init(limit: TimeInterval) {
        self.limit = limit
    }

    var count: Int { chunks.count - head }

    /// Returns true if older audio was dropped to make room. The newest chunk is always kept.
    mutating func append(_ chunk: CapturedAudio) -> Bool {
        chunks.append(chunk)
        duration += Self.duration(of: chunk)
        var dropped = false
        while duration > limit, head < chunks.count - 1, let oldest = chunks[head] {
            duration -= Self.duration(of: oldest)
            chunks[head] = nil
            head += 1
            dropped = true
        }
        if head >= 1024, head * 2 >= chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
        return dropped
    }

    /// Everything held, oldest first, and empties the backlog.
    @discardableResult
    mutating func removeAll() -> [CapturedAudio] {
        let held = chunks[head...].compactMap { $0 }
        chunks = []
        head = 0
        duration = 0
        return held
    }

    private static func duration(of chunk: CapturedAudio) -> TimeInterval {
        Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
    }
}

/// Resolves once with whether the model is usable. The first `open` wins.
actor ModelGate {
    private var state: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    /// Nil while undecided. For callers that must not suspend until the gate opens.
    var current: Bool? { state }

    func open(ready: Bool) {
        guard state == nil else { return }
        state = ready
        for waiter in waiters {
            waiter.resume(returning: ready)
        }
        waiters = []
    }

    func wait() async -> Bool {
        if let state { return state }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

nonisolated enum SourceTranscription {
    static func run(
        input: AsyncStream<CapturedAudio>,
        speaker: Speaker,
        locale: Locale,
        contextualStrings: [String],
        gate: ModelGate,
        output: AsyncStream<TranscriptEvent>.Continuation,
        issues: IssueReporter
    ) async {
        guard await gate.wait() else {
            // The buffering task discards the input once the gate is closed.
            issues.report(.speechModelUnavailable)
            return
        }

        // An unavailable source finishes its stream right away and never costs an analyzer.
        var chunks = input.makeAsyncIterator()
        guard let first = await chunks.next() else { return }

        let transcriber = SpeechAssets.makeTranscriber(locale: locale, volatileResults: true)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            SpeechAssets.log.error("No analyzer audio format for \(speaker.rawValue, privacy: .public)")
            issues.report(.transcriptionStopped(speaker))
            while await chunks.next() != nil {}
            return
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let results = Task {
            // Results end early only if the analyzer failed. Finishing the feed then stops the
            // loop below, which would otherwise keep converting audio into a stream nobody reads.
            defer { feed.finish() }
            do {
                let mapper = ResultMapper(speaker: speaker)
                for try await result in transcriber.results {
                    output.yield(.update(mapper.update(for: result)))
                }
                return true
            } catch {
                SpeechAssets.log.error("Results failed for \(speaker.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        var fedEverything = true
        do {
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: inputs)

            let converter = AnalyzerFeed(analyzerFormat: format)
            var chunk: CapturedAudio? = first
            feeding: while let current = chunk {
                for analyzerInput in converter.inputs(for: current) {
                    if case .terminated = feed.yield(analyzerInput) {
                        fedEverything = false
                        break feeding
                    }
                }
                chunk = await chunks.next()
            }
            feed.finish()
            if fedEverything {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } else {
                SpeechAssets.log.error("Analyzer stopped early for \(speaker.rawValue, privacy: .public)")
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            SpeechAssets.log.error("Analyzer failed for \(speaker.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            fedEverything = false
            feed.finish()
            await analyzer.cancelAndFinishNow()
        }
        let resultsCompleted = await results.value
        if !fedEverything || !resultsCompleted {
            issues.report(.transcriptionStopped(speaker))
            // The buffered stream is unbounded, so the rest of the meeting has to be read even
            // though nothing transcribes it any more.
            while await chunks.next() != nil {}
        }
    }
}

nonisolated enum FileTranscription {
    static func run(file: URL, locale: Locale, emit: @escaping @Sendable (TranscriptUpdate) -> Void) async throws {
        let resolved = try await SpeechAssets.resolve(locale)
        let transcriber = SpeechAssets.makeTranscriber(locale: resolved, volatileResults: false)
        try await SpeechAssets.install(for: transcriber, locale: resolved)
        let audioFile = try AVAudioFile(forReading: file)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let results = Task {
            let mapper = ResultMapper(speaker: .unknown)
            for try await result in transcriber.results where result.isFinal {
                emit(mapper.update(for: result))
            }
        }

        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
        try await results.value
        try Task.checkCancellation()
    }
}

/// Turns analyzer results into transcript updates for one speaker.
nonisolated struct ResultMapper {
    let speaker: Speaker

    /// A new volatile result always starts where the last final ended, so a final never
    /// needs to carry over the rest of the previous volatile text.
    func update(for result: SpeechTranscriber.Result) -> TranscriptUpdate {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            return update(text, Self.audioRange(of: result.text) ?? result.range, isFinal: true)
        }
        return update(text, result.range, isFinal: false)
    }

    private func update(_ text: String, _ range: CMTimeRange, isFinal: Bool) -> TranscriptUpdate {
        let start = Self.seconds(range.start)
        let end = max(start, Self.seconds(range.end))
        return TranscriptUpdate(speaker: speaker, text: text, start: start, end: end, isFinal: isFinal)
    }

    /// The span of the words actually spoken, which is tighter than the result range: that one
    /// includes the leading and trailing silence the analyzer consumed.
    static func audioRange(of text: AttributedString) -> CMTimeRange? {
        var start: CMTime?
        var end: CMTime?
        for run in text.runs {
            guard let range = run.audioTimeRange, range.isValid, !range.isEmpty else { continue }
            if start.map({ range.start < $0 }) ?? true { start = range.start }
            if end.map({ range.end > $0 }) ?? true { end = range.end }
        }
        guard let start, let end else { return nil }
        return CMTimeRange(start: start, end: end)
    }

    static func seconds(_ time: CMTime) -> TimeInterval {
        guard time.isNumeric else { return 0 }
        return max(0, time.seconds)
    }
}
