import AVFoundation
import os

/// One contiguous run of audio on disk, placed on the recording timeline at `offset`.
nonisolated struct PartSegment: Sendable, Equatable {
    let url: URL
    let offset: TimeInterval
    let sampleRate: Double
    var frames: AVAudioFramePosition = 0

    var duration: TimeInterval { Double(frames) / sampleRate }
    var end: TimeInterval { offset + duration }
}

/// How an incoming buffer relates to the segment currently being written.
nonisolated enum SegmentDecision: Equatable {
    case append
    /// The source skipped (stall, dropped IO cycles): fill with silence to stay aligned.
    case padSilence(frames: AVAudioFramePosition)
    /// Too far off to patch up, or earlier than already written audio: start a new segment
    /// at the buffer's own time.
    case split
}

nonisolated enum SegmentPolicy {
    /// Device clocks drift against host time by a few ppm, and buffer stamps jitter by a
    /// fraction of a cycle. Below this the file's sample count is trusted over the stamps.
    static let tolerance: TimeInterval = 0.1
    /// Longer gaps start a new segment instead of writing minutes of zeros.
    static let maxSilencePadding: TimeInterval = 120

    static func decide(expected: TimeInterval, actual: TimeInterval, sampleRate: Double) -> SegmentDecision {
        let deviation = actual - expected
        if abs(deviation) <= tolerance { return .append }
        if deviation > 0, deviation <= maxSilencePadding {
            return .padSilence(frames: AVAudioFramePosition((deviation * sampleRate).rounded()))
        }
        return .split
    }
}

/// Takes captured buffers of one source and fans them out to the part file on disk, the
/// level meter and the consumer stream.
///
/// Not thread safe: every call must come from the owning capture's serial queue. Buffers
/// passed to `process` must be fresh copies, since they are handed to the stream as is.
nonisolated final class SourcePipeline: @unchecked Sendable {
    let source: AudioSource
    private let folder: URL
    private let startHostTime: UInt64
    private let continuation: AsyncStream<CapturedAudio>.Continuation
    private let levels: LevelMonitor?
    private let log = Logger(subsystem: "Memoir", category: "Audio")

    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var current: PartSegment?
    private var segments: [PartSegment] = []
    private var silence: AVAudioPCMBuffer?
    private var isFinished = false

    init(
        source: AudioSource,
        folder: URL,
        startHostTime: UInt64,
        continuation: AsyncStream<CapturedAudio>.Continuation,
        levels: LevelMonitor?
    ) {
        self.source = source
        self.folder = folder
        self.startHostTime = startHostTime
        self.continuation = continuation
        self.levels = levels
    }

    func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard !isFinished, buffer.frameLength > 0 else { return }
        let time = HostClock.recordingTime(of: hostTime, start: startHostTime)
        write(buffer, at: time)
        levels?.report(source, rms: LevelMath.rms(of: buffer))
        continuation.yield(CapturedAudio(buffer: buffer, time: time))
    }

    /// Closes the part file and ends the stream. Returns everything written, in order.
    func finish() -> [PartSegment] {
        if !isFinished {
            isFinished = true
            closeSegment()
            continuation.finish()
        }
        return segments
    }

    // MARK: - Part files

    private func write(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        if let segment = current, let format = fileFormat, Self.isSameLayout(format, buffer.format) {
            switch SegmentPolicy.decide(expected: segment.end, actual: time, sampleRate: segment.sampleRate) {
            case .append:
                break
            case .padSilence(let frames):
                writeSilence(frames: frames, format: format)
            case .split:
                closeSegment()
            }
        } else {
            closeSegment()
        }

        if file == nil {
            openSegment(format: buffer.format, at: time)
        }
        guard let file else { return }
        do {
            try file.write(from: buffer)
            current?.frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            log.error("Writing \(self.source.rawValue, privacy: .public) part failed: \(error)")
            // Next buffer retries with a fresh file instead of failing every write after this.
            closeSegment()
        }
    }

    private func openSegment(format: AVAudioFormat, at time: TimeInterval) {
        let index = segments.count + 1
        let millis = Int((time * 1000).rounded())
        // The offset is in the name so a crashed recording can still be laid out.
        let url = folder.appending(path: "part-\(source.rawValue)-\(index)-\(millis)ms.caf")
        // 16-bit PCM in CAF: CAF tolerates a missing final header update, so audio up to a
        // crash stays readable, and PCM needs no packet table unlike AAC or ALAC.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            fileFormat = format
            current = PartSegment(url: url, offset: time, sampleRate: format.sampleRate)
            silence = nil
        } catch {
            log.error("Creating \(self.source.rawValue, privacy: .public) part failed: \(error)")
            file = nil
            fileFormat = nil
            current = nil
        }
    }

    private func closeSegment() {
        guard let file, let segment = current else { return }
        file.close()
        if segment.frames > 0 {
            segments.append(segment)
        } else {
            try? FileManager.default.removeItem(at: segment.url)
        }
        self.file = nil
        fileFormat = nil
        current = nil
    }

    private func writeSilence(frames: AVAudioFramePosition, format: AVAudioFormat) {
        guard let file else { return }
        let chunk = AVAudioFrameCount(format.sampleRate)
        if silence == nil, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) {
            buffer.frameLength = chunk
            for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
            }
            silence = buffer
        }
        guard let silence else { return }
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunk)))
            silence.frameLength = count
            do {
                try file.write(from: silence)
            } catch {
                log.error("Padding \(self.source.rawValue, privacy: .public) part failed: \(error)")
                return
            }
            current?.frames += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
    }

    private static func isSameLayout(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat && a.isInterleaved == b.isInterleaved
    }
}
