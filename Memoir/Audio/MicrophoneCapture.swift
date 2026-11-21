import AVFoundation
import os

nonisolated enum MicrophoneError: Error {
    case noInputDevice
}

/// Captures the default input device with Apple's voice processing (echo cancellation), so
/// the remote participants coming out of the speakers do not end up in the "You" stream.
///
/// Threading: engine setup, teardown and the pipeline all live on `queue`. The tap callback
/// runs on an AVAudioEngine internal (non realtime) thread; it copies the buffer and hops to
/// `queue`.
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Memoir.Microphone", qos: .userInitiated)
    private let pipeline: SourcePipeline
    private let log = Logger(subsystem: "Memoir", category: "Audio")

    // Confined to `queue`.
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var generation = 0
    private var isStopped = false

    init(pipeline: SourcePipeline) {
        self.pipeline = pipeline
    }

    /// Asks for microphone access if it was never decided. False when denied or restricted.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.startEngine()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async -> [PartSegment] {
        await withCheckedContinuation { continuation in
            queue.async {
                self.isStopped = true
                self.tearDownEngine()
                // Tap callbacks that were already queued ran before this block.
                continuation.resume(returning: self.pipeline.finish())
            }
        }
    }

    // MARK: - Queue confined

    private func startEngine() throws {
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            log.error("Voice processing input failed (\(error)), falling back to plain input")
            tearDownEngine()
            try startEngine(voiceProcessing: false)
        }
    }

    private func startEngine(voiceProcessing: Bool) throws {
        // A fresh engine per (re)start: voice processing state and the input format do not
        // reliably reset on an engine that went through a configuration change.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Without this, voice processing turns other apps down, including the meeting.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneError.noInputDevice }

        generation += 1
        let generation = generation
        // With voice processing on, channel 0 is the processed voice and any further channels
        // are not meant for listening. Without it, fold all mic channels to mono.
        let mix: MonoMix = voiceProcessing ? .firstChannel : .average
        let bufferSize = AVAudioFrameCount(format.sampleRate / 10)
        try InputTap.install(on: input, bufferSize: bufferSize) { [weak self] list, format, frames, hostTime in
            guard let self, let copy = PCMCopy.mono(from: list, format: format, frames: frames, mix: mix) else { return }
            let host = hostTime ?? HostClock.now &- HostClock.ticks(forSeconds: Double(frames) / format.sampleRate)
            let handoff = BufferHandoff(buffer: copy)
            self.queue.async {
                guard generation == self.generation else { return }
                self.pipeline.process(handoff.buffer, hostTime: host)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.configurationChanged(generation: generation) }
        }
    }

    private func tearDownEngine() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Device switched, headphones plugged in, sample rate changed: the engine has stopped
    /// itself. Rebuild it and keep recording; the pipeline starts a new part if the format
    /// changed.
    private func configurationChanged(generation: Int) {
        guard !isStopped, generation == self.generation else { return }
        // Voice processing posts spurious changes while the engine keeps running.
        if let engine, engine.isRunning { return }
        log.info("Microphone configuration changed, restarting input")
        tearDownEngine()
        restart(attempt: 0)
    }

    private func restart(attempt: Int) {
        guard !isStopped else { return }
        do {
            try startEngine()
        } catch {
            tearDownEngine()
            // Usually the input device is mid-switch. Keep trying while recording.
            let delay = min(0.25 * Double(1 << min(attempt, 3)), 2)
            log.error("Microphone restart failed (\(error)), retrying in \(delay)s")
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restart(attempt: attempt + 1) }
        }
    }
}

/// Carries a freshly copied buffer across the queue hop. Nothing else references it.
private nonisolated struct BufferHandoff: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

// MARK: - Tap wrapper

/// Hides the macOS 27 tap API change. Both variants hand out the raw buffer list, valid only
/// for the duration of the callback.
nonisolated enum InputTap {
    typealias Handler = @Sendable (
        _ list: UnsafePointer<AudioBufferList>,
        _ format: AVAudioFormat,
        _ frames: Int,
        _ hostTime: UInt64?
    ) -> Void

    static func install(on node: AVAudioNode, bufferSize: AVAudioFrameCount, handler: @escaping Handler) throws {
        if #available(macOS 27.0, *) {
            try node.installAudioTap(onBus: 0, bufferSize: bufferSize, format: nil) { buffer, when in
                let hostTime = when.isHostTimeValid ? when.hostTime : nil
                buffer.withUnsafeAudioBufferList { list in
                    handler(list, buffer.format, buffer.frameLength, hostTime)
                }
            }
        } else {
            node.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { buffer, when in
                let hostTime = when.isHostTimeValid ? when.hostTime : nil
                handler(UnsafePointer(buffer.audioBufferList), buffer.format, Int(buffer.frameLength), hostTime)
            }
        }
    }
}

// MARK: - Mono copy

nonisolated enum MonoMix {
    case firstChannel
    case average
}

nonisolated enum PCMCopy {
    /// Copies Float32 audio (interleaved or not) into a new mono standard-format buffer.
    /// Returns nil for anything that is not Float32.
    static func mono(
        from list: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        frames: Int,
        mix: MonoMix
    ) -> AVAudioPCMBuffer? {
        guard frames > 0, format.commonFormat == .pcmFormatFloat32,
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0]
        else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let channels = Int(format.channelCount)
        let used = mix == .firstChannel ? 1 : channels
        destination.initialize(repeating: 0, count: frames)

        if format.isInterleaved {
            guard buffers.count > 0, let data = buffers[0].mData,
                  Int(buffers[0].mDataByteSize) >= frames * channels * MemoryLayout<Float>.size
            else { return nil }
            let source = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<used { sum += source[frame * channels + channel] }
                destination[frame] = sum
            }
        } else {
            guard buffers.count >= used else { return nil }
            for channel in 0..<used {
                guard let data = buffers[channel].mData,
                      Int(buffers[channel].mDataByteSize) >= frames * MemoryLayout<Float>.size
                else { return nil }
                let source = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { destination[frame] += source[frame] }
            }
        }
        if used > 1 {
            let scale = 1 / Float(used)
            for frame in 0..<frames { destination[frame] *= scale }
        }
        output.frameLength = AVAudioFrameCount(frames)
        return output
    }
}
