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

    private var didStart = false
    private var didFinish = false
    private var gate: ModelGate?
    private var sources: [Task<Void, Never>] = []
    private var output: AsyncStream<TranscriptUpdate>.Continuation?

    init() {}

    func start(
        streams: CaptureStreams,
        locale: Locale,
        contextualStrings: [String]
    ) async throws -> AsyncStream<TranscriptUpdate> {
        precondition(!didStart, "SpeechTranscriptionPipeline is single use")
        didStart = true

        // Buffering starts before any await, so nothing is lost while the locale and model
        // are checked, and producers using a bounded buffering policy never drop audio.
        let microphone = Self.buffered(streams.microphone)
        let system = Self.buffered(streams.system)

        let resolved = try await SpeechAssets.resolve(locale)
        let probe = SpeechAssets.makeTranscriber(locale: resolved, volatileResults: true)
        let gate = ModelGate()
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

        let (updates, output) = AsyncStream.makeStream(of: TranscriptUpdate.self)
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
                    output: output
                )
            }
        }
        return updates
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

    private static func buffered(_ input: AsyncStream<CapturedAudio>) -> AsyncStream<CapturedAudio> {
        let (stream, continuation) = AsyncStream.makeStream(of: CapturedAudio.self, bufferingPolicy: .unbounded)
        Task.detached {
            for await chunk in input {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        return stream
    }
}

/// Resolves once with whether the model is usable. The first `open` wins.
actor ModelGate {
    private var state: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

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
        output: AsyncStream<TranscriptUpdate>.Continuation
    ) async {
        guard await gate.wait() else { return }

        // An unavailable source finishes its stream right away and never costs an analyzer.
        var chunks = input.makeAsyncIterator()
        guard let first = await chunks.next() else { return }

        let transcriber = SpeechAssets.makeTranscriber(locale: locale, volatileResults: true)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            SpeechAssets.log.error("No analyzer audio format for \(speaker.rawValue, privacy: .public)")
            return
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task {
            do {
                let mapper = ResultMapper(speaker: speaker)
                for try await result in transcriber.results {
                    output.yield(mapper.update(for: result))
                }
            } catch {
                SpeechAssets.log.error("Results failed for \(speaker.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
            try await analyzer.start(inputSequence: inputs)

            let converter = AnalyzerFeed(analyzerFormat: format)
            var chunk: CapturedAudio? = first
            while let current = chunk {
                for analyzerInput in converter.inputs(for: current) {
                    feed.yield(analyzerInput)
                }
                chunk = await chunks.next()
            }
            feed.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            SpeechAssets.log.error("Analyzer failed for \(speaker.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await analyzer.cancelAndFinishNow()
        }
        await results.value
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
