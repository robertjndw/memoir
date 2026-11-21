import AVFoundation
import CoreMedia
import OSLog
import Speech

/// Places converted buffers on the recording timeline, in analyzer samples.
///
/// Every buffer gets an explicit `bufferStartTime` that is never earlier than the end of the
/// previous buffer, which is what keeps `audioDisordered` from ever firing: small jitter or
/// overlap snaps onto the contiguous position. A source that starts late simply starts at its
/// recording time. A real gap later on (a device rebuild, a stall) is filled with silence,
/// because handing the analyzer a jump in `bufferStartTime` made it finalize garbage
/// (",......") for the speech after the jump, even though its volatile text was correct.
nonisolated struct SampleTimeline {
    struct Placement: Equatable {
        var start: Int64
        /// Samples to fill with silence before `start`. Empty when contiguous.
        var silence: Range<Int64>
    }

    let sampleRate: Double
    /// Gaps up to this many samples are treated as timestamp jitter, not as missing audio.
    let tolerance: Int64
    /// Longer gaps are jumped instead of filled. Only a broken clock produces these, and
    /// feeding hours of silence would stall the transcript far worse than a bad segment.
    let maximumFill: Int64
    private(set) var nextSample: Int64?

    init(sampleRate: Double, toleranceSeconds: Double = 0.05, maximumFillSeconds: Double = 600) {
        self.sampleRate = sampleRate
        self.tolerance = Int64((toleranceSeconds * sampleRate).rounded())
        self.maximumFill = Int64((maximumFillSeconds * sampleRate).rounded())
    }

    mutating func place(time: TimeInterval, frameCount: Int64) -> Placement {
        let desired = Int64((max(time, 0) * sampleRate).rounded())
        let placement: Placement
        if let next = nextSample {
            let gap = desired - next
            if gap <= tolerance {
                placement = Placement(start: next, silence: next..<next)
            } else if gap <= maximumFill {
                placement = Placement(start: desired, silence: next..<desired)
            } else {
                placement = Placement(start: desired, silence: desired..<desired)
            }
        } else {
            placement = Placement(start: desired, silence: desired..<desired)
        }
        nextSample = placement.start + frameCount
        return placement
    }

    func time(ofSample sample: Int64) -> CMTime {
        CMTime(value: sample, timescale: CMTimeScale(sampleRate))
    }
}

/// Converts captured buffers from whatever the device delivers into the analyzer format.
/// Owned by a single task; not thread safe.
nonisolated final class AnalyzerFeed {
    let analyzerFormat: AVAudioFormat
    private var timeline: SampleTimeline
    private var converter: AVAudioConverter?

    init(analyzerFormat: AVAudioFormat) {
        self.analyzerFormat = analyzerFormat
        self.timeline = SampleTimeline(sampleRate: analyzerFormat.sampleRate)
    }

    func inputs(for chunk: CapturedAudio) -> [AnalyzerInput] {
        guard chunk.buffer.frameLength > 0 else { return [] }
        let converted = convert(chunk.buffer)
        let frames = converted.reduce(Int64(0)) { $0 + Int64($1.frameLength) }
        guard frames > 0 else { return [] }

        let placement = timeline.place(time: chunk.time, frameCount: frames)
        var inputs = silence(placement.silence)
        var sample = placement.start
        for buffer in converted {
            inputs.append(AnalyzerInput(buffer: buffer, bufferStartTime: timeline.time(ofSample: sample)))
            sample += Int64(buffer.frameLength)
        }
        return inputs
    }

    private func silence(_ range: Range<Int64>) -> [AnalyzerInput] {
        let chunk = Int64(analyzerFormat.sampleRate)
        return stride(from: range.lowerBound, to: range.upperBound, by: Int(chunk)).compactMap { start in
            let frames = AVAudioFrameCount(min(chunk, range.upperBound - start))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: frames) else { return nil }
            // Fresh buffers are not guaranteed to be zeroed.
            let audio = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for channel in audio {
                if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
            }
            buffer.frameLength = frames
            return AnalyzerInput(buffer: buffer, bufferStartTime: timeline.time(ofSample: start))
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        if buffer.format == analyzerFormat { return [buffer] }

        // A device switch changes the format mid-stream. The old converter's few buffered
        // samples are dropped; that is inaudible next to the switch itself.
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            // Without this, a stereo system tap would be reduced to its left channel.
            converter?.downmix = true
            if converter == nil {
                SpeechAssets.log.error("No converter from \(buffer.format, privacy: .public) to the analyzer format")
            }
        }
        guard let converter else { return [] }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024

        // `.noDataNow` instead of `.endOfStream` keeps the resampler state, so consecutive
        // buffers join without clicks or lost samples. The converter works in its own packet
        // sizes, so it may fill an output buffer before it has drained the input: keep pulling
        // until it asks for more data.
        nonisolated(unsafe) let input = buffer
        nonisolated(unsafe) var delivered = false
        var outputs: [AVAudioPCMBuffer] = []
        while let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if delivered {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                delivered = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                SpeechAssets.log.error("Audio conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                break
            }
            if output.frameLength > 0 { outputs.append(output) }
            if status != .haveData || output.frameLength == 0 { break }
        }
        return outputs
    }
}
