import AVFoundation
import os

/// Records microphone and system audio for one meeting into `folder/audio.m4a`.
///
/// While recording, each source is written to its own crash-tolerant part file in `folder`.
/// `stop()` mixes them into the final file and removes the parts.
actor AudioRecorder: AudioRecording {
    private struct Session {
        var microphone: MicrophoneCapture?
        var system: SystemAudioTap?
        let levels: LevelMonitor
        let startHostTime: UInt64
    }

    private enum Phase {
        case idle
        case starting
        case recording(Session)
        case stopped
    }

    static let audioFileName = "audio.m4a"

    private let folder: URL
    private var phase = Phase.idle
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private let log = Logger(subsystem: "Memoir", category: "Audio")

    init(folder: URL) {
        self.folder = folder
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
                continuation: microphoneContinuation, levels: levels
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
            continuation: systemContinuation, levels: levels
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
            phase = .stopped
            throw microphoneAllowed ? RecordingError.noAudioSource : RecordingError.microphonePermissionDenied
        }

        phase = .recording(Session(microphone: microphone, system: system, levels: levels, startHostTime: startHostTime))
        return CaptureStreams(
            microphone: microphoneStream,
            system: systemStream,
            levels: levelStream,
            unavailable: unavailable
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

        let destination = folder.appending(path: Self.audioFileName)
        let fallbackDuration = segments.map(\.end).max() ?? 0
        do {
            let duration = try await Self.mixOffActor(segments, to: destination)
            for segment in segments {
                try? FileManager.default.removeItem(at: segment.url)
            }
            guard let duration else { return RecordingOutput(audioURL: nil, duration: 0) }
            return RecordingOutput(audioURL: destination, duration: duration)
        } catch {
            // The parts stay on disk so the audio is not lost.
            log.error("Mixdown failed: \(error)")
            return RecordingOutput(audioURL: nil, duration: fallbackDuration)
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
