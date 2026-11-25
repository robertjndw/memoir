import Accelerate
import AVFoundation

/// Mixes the part files of both sources into one mono AAC file, each part placed at its
/// offset on the shared timeline, or renders one source alone the same way.
///
/// Done by hand with AVAudioFile and AVAudioConverter rather than AVMutableComposition and an
/// export session: the export presets offer no bitrate control, and the reader/writer route
/// is deprecated on macOS 27 while its replacement does not exist on 26. Streaming block by
/// block keeps memory flat for hour-long meetings.
nonisolated enum AudioMixdown {
    static let sampleRate: Double = 48_000
    /// Mono speech; 64 kbps AAC-LC is transparent enough for voice and ~29 MB per hour.
    static let bitRate = 64_000

    enum MixdownError: Error {
        case unsupportedFormat
        case conversionFailed
    }

    /// Sample rate of the per-source tracks the post-recording speech models consume.
    static let trackSampleRate: Double = 16_000

    /// Writes `destination` and returns the mixed duration, or nil if there was no audio.
    /// Writes to a temporary sibling first so a failed mix never leaves a truncated file.
    static func mix(_ segments: [PartSegment], to destination: URL) throws -> TimeInterval? {
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw MixdownError.unsupportedFormat
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        return try render(segments, format: outputFormat, settings: settings, to: destination)
    }

    /// Renders the parts of one source into a 16 kHz mono 16-bit PCM CAF on the same timeline as
    /// the mix: a part at offset 12.5 s starts 12.5 s in, gaps are silence. Returns the track
    /// duration, or nil if there was no audio. Same temporary-sibling safety as `mix`.
    static func renderTrack(_ segments: [PartSegment], to destination: URL) throws -> TimeInterval? {
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: trackSampleRate, channels: 1) else {
            throw MixdownError.unsupportedFormat
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: trackSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try render(segments, format: outputFormat, settings: settings, to: destination)
    }

    private static func render(
        _ segments: [PartSegment],
        format: AVAudioFormat,
        settings: [String: Any],
        to destination: URL
    ) throws -> TimeInterval? {
        let readers = try segments
            .filter { $0.frames > 0 }
            .map { try SegmentReader(segment: $0, outputFormat: format) }
            .filter { $0.expectedFrames > 0 }
        guard let totalFrames = readers.map({ $0.startFrame + $0.expectedFrames }).max(), totalFrames > 0 else {
            return nil
        }

        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.deletingPathExtension().lastPathComponent)-mixing.\(destination.pathExtension)")
        try? FileManager.default.removeItem(at: temporary)
        do {
            try write(readers: readers, totalFrames: totalFrames, settings: settings, to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return Double(totalFrames) / format.sampleRate
    }

    private static func write(
        readers: [SegmentReader],
        totalFrames: AVAudioFramePosition,
        settings: [String: Any],
        to url: URL
    ) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }

        // One second per block, whatever the rate, so memory does not depend on the recording length.
        let blockSize = AVAudioFrameCount(file.processingFormat.sampleRate)
        guard let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockSize),
              let samples = block.floatChannelData?[0]
        else { throw MixdownError.unsupportedFormat }

        var position: AVAudioFramePosition = 0
        while position < totalFrames {
            let count = Int(min(AVAudioFramePosition(blockSize), totalFrames - position))
            samples.initialize(repeating: 0, count: count)
            for reader in readers where reader.startFrame < position + AVAudioFramePosition(count) {
                let lead = Int(max(0, reader.startFrame - position))
                try reader.add(into: samples + lead, count: count - lead)
            }
            var low: Float = -1
            var high: Float = 1
            vDSP_vclip(samples, 1, &low, &high, samples, 1, vDSP_Length(count))
            block.frameLength = AVAudioFrameCount(count)
            try file.write(from: block)
            position += AVAudioFramePosition(count)
        }
    }
}

/// Streams one part file, converted to the mix format, strictly in order.
private nonisolated final class SegmentReader {
    let startFrame: AVAudioFramePosition
    let expectedFrames: AVAudioFramePosition

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var pending: [Float] = []
    private var pendingIndex = 0
    private var inputExhausted = false
    private var finished = false

    init(segment: PartSegment, outputFormat: AVAudioFormat) throws {
        file = try AVAudioFile(forReading: segment.url)
        let sourceFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192)
        else { throw AudioMixdown.MixdownError.unsupportedFormat }
        // Average stereo system audio into mono instead of keeping only the left channel.
        converter.downmix = true
        self.converter = converter
        self.input = input
        self.output = output
        startFrame = AVAudioFramePosition((segment.offset * outputFormat.sampleRate).rounded())
        expectedFrames = AVAudioFramePosition(
            (Double(file.length) * outputFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)
        )
    }

    /// Sums the next `count` frames into `destination`. Past the end it adds nothing.
    func add(into destination: UnsafeMutablePointer<Float>, count: Int) throws {
        var filled = 0
        while filled < count {
            if pendingIndex < pending.count {
                let n = min(count - filled, pending.count - pendingIndex)
                pending.withUnsafeBufferPointer { source in
                    vDSP_vadd(source.baseAddress! + pendingIndex, 1, destination + filled, 1, destination + filled, 1, vDSP_Length(n))
                }
                pendingIndex += n
                filled += n
                continue
            }
            if finished { return }
            try refill()
        }
    }

    private func refill() throws {
        pending.removeAll(keepingCapacity: true)
        pendingIndex = 0
        output.frameLength = 0
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] packets, inputStatus in
            if inputExhausted {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: min(packets, input.frameCapacity))
            } catch {
                input.frameLength = 0
            }
            if input.frameLength == 0 {
                inputExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        switch status {
        case .error:
            throw conversionError ?? AudioMixdown.MixdownError.conversionFailed
        case .endOfStream:
            finished = true
        case .haveData, .inputRanDry:
            if output.frameLength == 0 { finished = inputExhausted }
        @unknown default:
            finished = true
        }
        if let data = output.floatChannelData?[0], output.frameLength > 0 {
            pending.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        }
    }
}
