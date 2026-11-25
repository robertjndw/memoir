import AVFoundation
import os

/// Records microphone and system audio for one meeting into `folder/audio.m4a`.
///
/// While recording, each source is written to its own crash-tolerant part file in `folder`.
/// `stop()` mixes them into the final file and removes the parts, unless they are kept for
/// `takeTracks`.
actor AudioRecorder: AudioRecording {
    private struct Session {
        var microphone: MicrophoneCapture?
        var system: SystemAudioTap?
        let levels: LevelMonitor
        let startHostTime: UInt64
        let issues: AsyncStream<RecordingIssue>.Continuation
    }

    private enum Phase {
        case idle
        case starting
        case recording(Session)
        case stopped
    }

    static let audioFileName = "audio.m4a"

    private let folder: URL
    private let keepTracks: Bool
    private var phase = Phase.idle
    /// Parts kept past `stop` for `takeTracks`.
    private var heldParts: [PartSegment] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private let log = Logger(subsystem: "Memoir", category: "Audio")

    init(folder: URL, keepTracks: Bool = false) {
        self.folder = folder
        self.keepTracks = keepTracks
    }

    func start() async throws -> CaptureStreams {
        guard case .idle = phase else { throw RecordingError.noAudioSource }
        phase = .starting
        defer {
            for waiter in startWaiters { waiter.resume() }
            startWaiters = []
        }

        let (microphoneStream, microphoneContinuation) = AsyncStream.makeStream(of: CapturedAudio.self, bufferingPolicy: .unbounded)
        let (systemStream, systemContinuation) = AsyncStream.makeStream(of: CapturedAudio.self, bufferingPolicy: .unbounded)
        let (levelStream, levelContinuation) = AsyncStream.makeStream(of: AudioLevels.self, bufferingPolicy: .bufferingNewest(1))
        let (issueStream, issueContinuation) = AsyncStream.makeStream(of: RecordingIssue.self)
        let issues = IssueReporter { issueContinuation.yield($0) }

        let microphoneAllowed = await MicrophoneCapture.requestAccess()
        // Taken after the permission prompt, which can take arbitrarily long.
        let startHostTime = HostClock.now
        let levels = LevelMonitor(continuation: levelContinuation)
        levels.start()
        var unavailable = Set<AudioSource>()

        var microphone: MicrophoneCapture?
        if microphoneAllowed {
            let capture = MicrophoneCapture(pipeline: SourcePipeline(
                source: .microphone, folder: folder, startHostTime: startHostTime,
                continuation: microphoneContinuation, levels: levels, issues: issues
            ))
            do {
                try await capture.start()
                microphone = capture
            } catch {
                log.error("Microphone capture failed to start: \(error)")
                _ = await capture.stop()
                unavailable.insert(.microphone)
            }
        } else {
            log.info("Microphone access denied")
            microphoneContinuation.finish()
            unavailable.insert(.microphone)
        }

        var system: SystemAudioTap?
        let tap = SystemAudioTap(pipeline: SourcePipeline(
            source: .system, folder: folder, startHostTime: startHostTime,
            continuation: systemContinuation, levels: levels, issues: issues
        ))
        do {
            try await tap.start()
            system = tap
        } catch {
            log.error("System audio capture failed to start: \(error)")
            _ = await tap.stop()
            unavailable.insert(.system)
        }

        guard microphone != nil || system != nil else {
            levels.stop()
            issueContinuation.finish()
            phase = .stopped
            throw microphoneAllowed ? RecordingError.noAudioSource : RecordingError.microphonePermissionDenied
        }

        phase = .recording(Session(
            microphone: microphone, system: system, levels: levels, startHostTime: startHostTime,
            issues: issueContinuation
        ))
        return CaptureStreams(
            microphone: microphoneStream,
            system: systemStream,
            levels: levelStream,
            unavailable: unavailable,
            issues: issueStream
        )
    }

    func setMicrophoneMuted(_ muted: Bool) async -> TimeInterval? {
        guard case .recording(let session) = phase, let microphone = session.microphone else { return nil }
        await microphone.setMuted(muted)
        return HostClock.recordingTime(of: HostClock.now, start: session.startHostTime)
    }

    func stop() async -> RecordingOutput {
        if case .starting = phase {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        guard case .recording(let session) = phase else {
            return RecordingOutput(audioURL: nil, duration: 0)
        }
        phase = .stopped

        async let microphoneParts = session.microphone?.stop() ?? []
        async let systemParts = session.system?.stop() ?? []
        let segments = await microphoneParts + systemParts
        session.levels.stop()
        // Both pipelines are finished, so nothing can report any more.
        session.issues.finish()

        let destination = folder.appending(path: Self.audioFileName)
        let fallbackDuration = segments.map(\.end).max() ?? 0
        do {
            let duration = try await Self.mixOffActor(segments, to: destination)
            // The parts are the only input the tracks can be rendered from. Rendering them here
            // would make Stop (and Quit) wait for work that is only needed afterwards, so they
            // stay until `takeTracks`. If the app quits first, the next launch removes them.
            guard let duration, keepTracks else {
                Self.remove(segments)
                return RecordingOutput(audioURL: duration == nil ? nil : destination, duration: duration ?? 0)
            }
            heldParts = segments
            return RecordingOutput(audioURL: destination, duration: duration, holdsTracks: true)
        } catch {
            // The parts stay on disk so the audio is not lost.
            log.error("Mixdown failed: \(error)")
            return RecordingOutput(audioURL: nil, duration: fallbackDuration)
        }
    }

    func takeTracks(render: Bool) async -> [AudioSource: URL] {
        let segments = heldParts
        heldParts = []
        let tracks = render ? await renderTracks(from: segments) : [:]
        Self.remove(segments)
        return tracks
    }

    private static func remove(_ segments: [PartSegment]) {
        for segment in segments {
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    /// A source that fails to render is left out; the mix is already safe on disk.
    private func renderTracks(from segments: [PartSegment]) async -> [AudioSource: URL] {
        guard !segments.isEmpty else { return [:] }
        var tracks: [AudioSource: URL] = [:]
        for source in [AudioSource.microphone, .system] {
            let sourceSegments = segments.filter {
                RecordingRecovery.parse($0.url.lastPathComponent)?.source == source
            }
            guard !sourceSegments.isEmpty else { continue }
            let destination = folder.appending(path: "\(RecordingRecovery.trackPrefix)\(source.rawValue).caf")
            do {
                if try await Self.renderTrackOffActor(sourceSegments, to: destination) != nil {
                    tracks[source] = destination
                }
            } catch {
                log.error("Track render failed for \(source.rawValue, privacy: .public): \(error)")
            }
        }
        return tracks
    }

    private static func renderTrackOffActor(_ segments: [PartSegment], to destination: URL) async throws -> TimeInterval? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try AudioMixdown.renderTrack(segments, to: destination) })
            }
        }
    }

    /// Decoding and AAC encoding an hour of audio takes a while; keep it off the cooperative pool.
    private static func mixOffActor(_ segments: [PartSegment], to destination: URL) async throws -> TimeInterval? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try AudioMixdown.mix(segments, to: destination) })
            }
        }
    }
}
