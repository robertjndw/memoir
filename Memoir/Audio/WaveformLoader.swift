import Accelerate
import AVFoundation

/// Reduces a recording to a few hundred loudness values for drawing its waveform.
nonisolated enum WaveformLoader {
    /// Enough resolution for a full-width bar on any window size; the view resamples down.
    static let resolution = 600

    /// Normalized 0...1 RMS per bucket, or nil if the file can't be read.
    static func peaks(for url: URL, count: Int = resolution) async -> [Float]? {
        await Task.detached(priority: .utility) {
            try? compute(url: url, count: count)
        }.value
    }

    private static func compute(url: URL, count: Int) throws -> [Float]? {
        let file = try AVAudioFile(forReading: url)
        let total = Int(file.length)
        guard total > 0, count > 0 else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        let framesPerBucket = max(1, total / count)
        var buckets: [Float] = []
        buckets.reserveCapacity(count + 1)
        var sumOfSquares: Float = 0
        var filled = 0

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            // The mixdown is mono, so the first channel is the whole recording.
            guard frames > 0, let samples = buffer.floatChannelData?[0] else { break }
            var offset = 0
            while offset < frames {
                let take = min(frames - offset, framesPerBucket - filled)
                var partial: Float = 0
                vDSP_svesq(samples + offset, 1, &partial, vDSP_Length(take))
                sumOfSquares += partial
                filled += take
                offset += take
                if filled == framesPerBucket {
                    buckets.append(sqrt(sumOfSquares / Float(filled)))
                    sumOfSquares = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { buckets.append(sqrt(sumOfSquares / Float(filled))) }
        return normalized(buckets)
    }

    /// Scales to the loudest bucket. The power curve lifts quiet speech, which would otherwise
    /// look almost flat next to a few loud peaks.
    static func normalized(_ values: [Float]) -> [Float] {
        guard let loudest = values.max(), loudest > 0 else { return values.map { _ in 0 } }
        return values.map { pow(min(1, $0 / loudest), 0.6) }
    }
}
