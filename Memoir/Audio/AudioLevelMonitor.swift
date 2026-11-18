import Accelerate
import AVFoundation
import Synchronization

/// Pure level math for the menu bar meter.
nonisolated enum LevelMath {
    /// Quiet room noise sits below this and should read as an empty meter.
    static let floorDecibels: Float = -50
    /// Normal speech peaks around -20...-10 dBFS, so the meter is full well before clipping.
    static let ceilingDecibels: Float = -10
    /// Fraction of the displayed level kept per tick while the signal falls. At ~16 Hz this
    /// drops to 10% in roughly 0.6 s, which reads as a natural meter release.
    static let release: Float = 0.75

    static func decibels(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else { return -.infinity }
        return 20 * log10(rms)
    }

    /// Maps RMS amplitude to 0...1 linearly in decibels, which matches perceived loudness far
    /// better than linear amplitude for a small meter.
    static func normalized(rms: Float) -> Float {
        let db = decibels(rms: rms)
        guard db.isFinite else { return 0 }
        let value = (db - floorDecibels) / (ceilingDecibels - floorDecibels)
        return min(1, max(0, value))
    }

    /// Instant attack, exponential release.
    static func smoothed(previous: Float, target: Float) -> Float {
        let decayed = previous * release
        return max(target, decayed < 0.001 ? 0 : decayed)
    }

    /// RMS across all channels of a float buffer. Other sample formats read as silence.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return 0 }
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        var sum: Float = 0
        if buffer.format.isInterleaved {
            var meanSquare: Float = 0
            vDSP_measqv(data[0], 1, &meanSquare, frames * vDSP_Length(stride))
            return sqrt(meanSquare)
        }
        for channel in 0..<channels {
            var meanSquare: Float = 0
            vDSP_measqv(data[channel], 1, &meanSquare, frames)
            sum += meanSquare
        }
        return sqrt(sum / Float(max(channels, 1)))
    }
}

/// Collects per-buffer levels from both sources and publishes them at a steady meter rate.
nonisolated final class LevelMonitor: @unchecked Sendable {
    private struct Peaks {
        var microphone: Float = 0
        var system: Float = 0
    }

    static let interval: DispatchTimeInterval = .milliseconds(60)

    private let peaks = Mutex(Peaks())
    private let continuation: AsyncStream<AudioLevels>.Continuation
    private let queue = DispatchQueue(label: "Memoir.AudioLevels", qos: .utility)
    // Confined to `queue`.
    private var timer: DispatchSourceTimer?
    private var displayed = AudioLevels()

    init(continuation: AsyncStream<AudioLevels>.Continuation) {
        self.continuation = continuation
    }

    /// Called from the capture pipelines (never from a realtime thread).
    func report(_ source: AudioSource, rms: Float) {
        let level = LevelMath.normalized(rms: rms)
        peaks.withLock { peaks in
            switch source {
            case .microphone: peaks.microphone = max(peaks.microphone, level)
            case .system: peaks.system = max(peaks.system, level)
            }
        }
    }

    func start() {
        queue.async { self.startTimer() }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            continuation.yield(AudioLevels())
            continuation.finish()
        }
    }

    private func tick() {
        let current = peaks.withLock { peaks in
            defer { peaks = Peaks() }
            return peaks
        }
        displayed = AudioLevels(
            microphone: LevelMath.smoothed(previous: displayed.microphone, target: current.microphone),
            system: LevelMath.smoothed(previous: displayed.system, target: current.system)
        )
        continuation.yield(displayed)
    }
}
