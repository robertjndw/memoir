@preconcurrency import AVFoundation
import FluidAudio
import Foundation

nonisolated enum EnhancementError: LocalizedError {
    case modelMissing(OptionalModel)
    case unsupportedLanguage(Locale)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let model):
            OptionalModelError.notInstalled(model).errorDescription
        case .unsupportedLanguage(let locale):
            "Enhanced transcription does not support \(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)."
        }
    }
}

/// Runs the optional models over a finished recording: Parakeet for a new transcription,
/// pyannote Community-1 for telling speakers apart.
nonisolated struct FluidEnhancer: TranscriptEnhancing {
    let directory: URL

    init(directory: URL = FluidModels.directory) {
        self.directory = directory
        FluidNetwork.stayOffline()
    }

    /// The 25 languages on the Parakeet TDT v3 and Parakeet Ultra model cards.
    static let languages: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    func supportsTranscription(in locale: Locale) -> Bool {
        guard let code = locale.language.languageCode?.identifier else { return false }
        return Self.languages.contains(code)
    }

    func enhance(_ request: EnhancementRequest) -> AsyncThrowingStream<EnhancementProgress, Error> {
        let directory = directory
        let supported = supportsTranscription(in: request.locale)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if request.transcribe, !supported { throw EnhancementError.unsupportedLanguage(request.locale) }
                    let run = EnhancementRun(request: request, directory: directory) { continuation.yield($0) }
                    let lines = try await Self.queue.run { try await run.perform() }
                    continuation.yield(.finished(lines))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One enhancement at a time across the app. The models are large, and FluidAudio has
    /// crashed on Core ML predictions running concurrently.
    private static let queue = ModelRunQueue()
}

/// Runs async jobs one after another, in the order they arrived.
private actor ModelRunQueue {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ job: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        return try await job()
    }
}

private nonisolated struct EnhancementRun: Sendable {
    let request: EnhancementRequest
    let directory: URL
    let report: @Sendable (EnhancementProgress) -> Void

    /// Neither model has anything to work with below this.
    private static let minimumDuration: TimeInterval = 1

    func perform() async throws -> [TranscriptLine] {
        guard request.transcribe || request.identifySpeakers else { return request.lines }
        if request.transcribe, !FluidModels.isInstalled(.enhancedTranscription, in: directory) {
            throw EnhancementError.modelMissing(.enhancedTranscription)
        }
        if request.identifySpeakers, !FluidModels.isInstalled(.speakerIdentification, in: directory) {
            throw EnhancementError.modelMissing(.speakerIdentification)
        }

        switch request.audio {
        case .tracks(let tracks):
            return try await enhance(tracks: tracks)
        case .mixed(let url):
            return try await enhance(mixed: url)
        }
    }

    // MARK: - Steps

    private func enhance(tracks: [AudioSource: URL]) async throws -> [TranscriptLine] {
        let tracks = tracks.filter { Self.duration(of: $0.value) >= Self.minimumDuration }
        let userLines = request.lines.filter { $0.speaker == .me }
        let otherLines = request.lines.filter { $0.speaker != .me }

        var words: [AudioSource: [TimedWord]] = [:]
        if request.transcribe {
            let sources = [AudioSource.microphone, .system].filter { tracks[$0] != nil }
            let results = try await transcribe(sources.compactMap { tracks[$0] })
            words = Dictionary(uniqueKeysWithValues: zip(sources, results))
        }

        var turns: [SpeakerTurn]?
        if request.identifySpeakers, let system = tracks[.system] {
            turns = try await diarize(system)
        }
        let others: TranscriptAssembler.Attribution =
            turns.map { .turns($0, user: nil, others: .others) } ?? .speaker(.others)

        // A side without a track keeps what the live transcript has for it.
        var drafts: [TranscriptAssembler.Draft] = []
        if let userWords = words[.microphone] {
            drafts += TranscriptAssembler.lines(from: userWords, attribution: .speaker(.me))
        } else {
            drafts += TranscriptAssembler.lines(keeping: userLines, words: request.words, attribution: .speaker(.me))
        }
        if let otherWords = words[.system] {
            drafts += TranscriptAssembler.lines(from: otherWords, attribution: others)
        } else {
            drafts += TranscriptAssembler.lines(keeping: otherLines, words: request.words, attribution: others)
        }
        return TranscriptAssembler.finish(drafts)
    }

    private func enhance(mixed url: URL) async throws -> [TranscriptLine] {
        let words = request.transcribe ? try await transcribe([url]).first ?? [] : nil
        var attribution = TranscriptAssembler.Attribution.lines(request.lines, fallback: .unknown)
        if request.identifySpeakers {
            let turns = try await diarize(url)
            let user = TranscriptAssembler.userCluster(in: turns, lines: request.lines, words: request.words)
            // Without a convincing match nobody can be called the user, so nobody is "Others".
            attribution = .turns(turns, user: user, others: user == nil ? .unknown : .others)
        }
        let drafts = if let words {
            TranscriptAssembler.lines(from: words, attribution: attribution)
        } else {
            TranscriptAssembler.lines(keeping: request.lines, words: request.words, attribution: attribution)
        }
        return TranscriptAssembler.finish(drafts)
    }

    // MARK: - Models

    /// Transcribes the files one after another with a single loaded model. Returns the words of
    /// each file, in the order given.
    private func transcribe(_ urls: [URL]) async throws -> [[TimedWord]] {
        report(.transcribing(0))
        let durations = urls.map { max(Self.duration(of: $0), 0.001) }
        let total = durations.reduce(0, +)
        let models = try FluidModels.loadTranscription(from: directory)
        let manager = AsrManager(config: .default, models: models)
        let language = request.locale.language.languageCode.flatMap { Language(rawValue: $0.identifier) }

        var results: [[TimedWord]] = []
        var done: TimeInterval = 0
        for (url, duration) in zip(urls, durations) {
            try Task.checkCancellation()
            guard duration >= Self.minimumDuration else {
                results.append([])
                done += duration
                continue
            }
            // Progress only comes for audio longer than one 15 s window, and the stream is not
            // finished for shorter files, so the watcher is cancelled rather than awaited.
            let stream = await manager.transcriptionProgressStream
            let base = done
            let watcher = Task { [report] in
                for try await fraction in stream {
                    report(.transcribing(min((base + fraction * duration) / total, 1)))
                }
            }
            defer { watcher.cancel() }
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(url, decoderState: &state, language: language)
            results.append(Self.words(from: result.tokenTimings ?? []))
            done += duration
            report(.transcribing(min(done / total, 1)))
        }
        await manager.cleanup()
        return results
    }

    private func diarize(_ url: URL) async throws -> [SpeakerTurn] {
        report(.identifyingSpeakers(0))
        guard Self.duration(of: url) >= Self.minimumDuration else { return [] }
        try Task.checkCancellation()
        var config = OfflineDiarizerConfig()
        // Words are attributed to one speaker each, which needs one speaker per instant.
        config.postProcessing.exclusiveSegments = true
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: try FluidModels.loadDiarizer(from: directory))
        // `process(_ url:)` streams the file through a disk-backed buffer, so a long meeting
        // never sits in memory as samples.
        let result = try await manager.process(url) { [report] processed, total in
            report(.identifyingSpeakers(Double(processed) / Double(max(total, 1))))
        }
        report(.identifyingSpeakers(1))
        return Self.turns(from: result.segments)
    }

    // MARK: - Conversion

    /// Parakeet's tokens are SentencePiece pieces; a piece that starts with the word boundary
    /// marker begins a new word, which is what `buildWordTimings` groups by.
    static func words(from tokens: [TokenTiming]) -> [TimedWord] {
        buildWordTimings(from: tokens).compactMap { word in
            let text = word.word.replacingOccurrences(of: "<unk>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedWord(text: text, start: word.startTime, end: max(word.startTime, word.endTime))
        }
    }

    /// Clusters are numbered in the order they first speak, which is also the order voices get.
    static func turns(from segments: [TimedSpeakerSegment]) -> [SpeakerTurn] {
        var clusters: [String: Int] = [:]
        return segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .filter { $0.endTimeSeconds > $0.startTimeSeconds }
            .map { segment in
                let cluster = clusters[segment.speakerId] ?? clusters.count
                clusters[segment.speakerId] = cluster
                return SpeakerTurn(start: TimeInterval(segment.startTimeSeconds), end: TimeInterval(segment.endTimeSeconds), cluster: cluster)
            }
    }

    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
