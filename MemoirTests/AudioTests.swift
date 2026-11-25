import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Memoir

// MARK: - Fixtures

nonisolated enum AudioFixtures {
    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MemoirAudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sine(
        frequency: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        seconds: Double,
        amplitude: Float = 0.5,
        phaseFrames: Int = 0
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = amplitude * Float(sin(2 * .pi * frequency * Double(frame + phaseFrames) / sampleRate))
            }
        }
        return buffer
    }

    /// Writes a part file the way SourcePipeline does and returns its segment.
    static func part(
        in folder: URL,
        name: String,
        offset: TimeInterval,
        buffer: AVAudioPCMBuffer
    ) throws -> PartSegment {
        let url = folder.appending(path: "\(name).caf")
        let format = buffer.format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        file.close()
        return PartSegment(url: url, offset: offset, sampleRate: format.sampleRate, frames: AVAudioFramePosition(buffer.frameLength))
    }

    /// RMS of a mono file between two times.
    static func rms(of url: URL, from start: TimeInterval, to end: TimeInterval) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(start * rate)
        let frames = AVAudioFrameCount((end - start) * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer, frameCount: frames)
        return LevelMath.rms(of: buffer)
    }
}

// MARK: - Levels

@Suite struct AudioLevelTests {
    @Test func silenceAndFloorReadAsEmpty() {
        #expect(LevelMath.normalized(rms: 0) == 0)
        #expect(LevelMath.normalized(rms: .nan) == 0)
        #expect(LevelMath.normalized(rms: 0.001) == 0) // -60 dB, below the floor
    }

    @Test func loudSignalReadsAsFull() {
        #expect(LevelMath.normalized(rms: 1) == 1)
        #expect(LevelMath.normalized(rms: 0.5) == 1) // -6 dB, above the ceiling
    }

    @Test func mappingIsLinearInDecibels() {
        // -30 dB is halfway between the -50 dB floor and the -10 dB ceiling.
        let half = LevelMath.normalized(rms: pow(10, -30 / 20))
        #expect(abs(half - 0.5) < 0.0001)
        let quarter = LevelMath.normalized(rms: pow(10, -40 / 20))
        #expect(abs(quarter - 0.25) < 0.0001)
    }

    @Test func meterAttacksInstantlyAndReleasesSlowly() {
        #expect(LevelMath.smoothed(previous: 0.1, target: 0.8) == 0.8)
        let released = LevelMath.smoothed(previous: 0.8, target: 0)
        #expect(released > 0.5 && released < 0.8)
        var level: Float = 1
        for _ in 0..<40 { level = LevelMath.smoothed(previous: level, target: 0) }
        #expect(level == 0)
    }

    @Test func rmsOfSineIsAmplitudeOverRootTwo() {
        let buffer = AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 2, seconds: 1, amplitude: 0.5)
        #expect(abs(LevelMath.rms(of: buffer) - 0.5 / sqrt(2)) < 0.001)
    }
}

// MARK: - Timeline

@Suite struct AudioTimelineTests {
    // Apple silicon timebase: 125/3 ns per tick, i.e. 24 MHz.
    let timebase = mach_timebase_info_data_t(numer: 125, denom: 3)

    @Test func hostTicksConvertToSeconds() {
        #expect(HostClock.seconds(from: 1_000, to: 1_000 + 24_000_000, timebase: timebase) == 1)
        #expect(HostClock.seconds(from: 24_000_000, to: 12_000_000, timebase: timebase) == -0.5)
        #expect(HostClock.ticks(forSeconds: 2, timebase: timebase) == 48_000_000)
        #expect(HostClock.ticks(forSeconds: -1, timebase: timebase) == 0)
    }

    @Test func recordingTimeNeverGoesNegative() {
        let start = HostClock.now
        #expect(HostClock.recordingTime(of: start - 1_000, start: start) == 0)
        let later = start + HostClock.ticks(forSeconds: 1.5)
        #expect(abs(HostClock.recordingTime(of: later, start: start) - 1.5) < 0.000_001)
    }

    @Test func smallDeviationsAppend() {
        #expect(SegmentPolicy.decide(expected: 10, actual: 10.05, sampleRate: 48_000) == .append)
        #expect(SegmentPolicy.decide(expected: 10, actual: 9.95, sampleRate: 48_000) == .append)
    }

    @Test func gapsArePaddedWithSilence() {
        #expect(SegmentPolicy.decide(expected: 10, actual: 10.5, sampleRate: 48_000) == .padSilence(frames: 24_000))
    }

    @Test func overlapsAndHugeGapsSplit() {
        #expect(SegmentPolicy.decide(expected: 10, actual: 9.5, sampleRate: 48_000) == .split)
        #expect(SegmentPolicy.decide(expected: 10, actual: 10 + 600, sampleRate: 48_000) == .split)
    }
}

// MARK: - Buffers

@Suite struct AudioBufferTests {
    @Test func ringRoundTripsInterleavedFramesWithHostTimes() {
        let ring = AudioRingBuffer(channels: 2, frameCapacity: 8, chunkCapacity: 4)
        #expect(ring.write(frames: 3, hostTime: 100) { frame, channel in Float(frame * 10 + channel) })
        #expect(ring.write(frames: 3, hostTime: 200) { frame, channel in Float(100 + frame * 10 + channel) })
        // Only 2 of 8 frames are free.
        #expect(!ring.write(frames: 3, hostTime: 300) { _, _ in 0 })
        #expect(ring.droppedFrames.load(ordering: .relaxed) == 3)

        let left = UnsafeMutablePointer<Float>.allocate(capacity: 6)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 6)
        defer { left.deallocate(); right.deallocate() }
        var channels = [left, right]
        var offset = 0
        var hostTimes: [UInt64] = []
        channels.withUnsafeMutableBufferPointer { pointers in
            while let chunk = ring.peek() {
                hostTimes.append(chunk.hostTime)
                ring.consume(chunk, into: UnsafePointer(pointers.baseAddress!), at: offset)
                offset += chunk.frames
            }
        }
        #expect(hostTimes == [100, 200])
        #expect(Array(UnsafeBufferPointer(start: left, count: 6)) == [0, 10, 20, 100, 110, 120])
        #expect(Array(UnsafeBufferPointer(start: right, count: 6)) == [1, 11, 21, 101, 111, 121])

        // Space is reclaimed and writes wrap around the end of the storage.
        #expect(ring.write(frames: 5, hostTime: 400) { frame, _ in Float(frame) })
        channels = [left, right]
        channels.withUnsafeMutableBufferPointer { pointers in
            let chunk = ring.peek()!
            ring.consume(chunk, into: UnsafePointer(pointers.baseAddress!), at: 0)
        }
        #expect(Array(UnsafeBufferPointer(start: left, count: 5)) == [0, 1, 2, 3, 4])
        #expect(ring.peek() == nil)
    }

    @Test func contiguousRunStopsAtJumpsAndSizeLimit() {
        let ring = AudioRingBuffer(channels: 1, frameCapacity: 48_000, chunkCapacity: 64)
        let cycle = HostClock.ticks(forSeconds: 0.01)
        let tolerance = HostClock.ticks(forSeconds: 0.002)
        #expect(ring.contiguousRun(maxFrames: 1000, sampleRate: 48_000, tolerance: tolerance) == nil)

        // Three back-to-back 10 ms cycles, then one that starts 50 ms late.
        for index in 0..<3 {
            ring.write(frames: 480, hostTime: 1_000 + UInt64(index) * cycle) { _, _ in 0 }
        }
        ring.write(frames: 480, hostTime: 1_000 + 8 * cycle) { _, _ in 0 }

        let run = ring.contiguousRun(maxFrames: 48_000, sampleRate: 48_000, tolerance: tolerance)
        #expect(run?.chunks == 3 && run?.frames == 1440)
        let capped = ring.contiguousRun(maxFrames: 1000, sampleRate: 48_000, tolerance: tolerance)
        #expect(capped?.chunks == 2 && capped?.frames == 960)
        // The first chunk always counts, even when it alone is over the limit.
        let tiny = ring.contiguousRun(maxFrames: 100, sampleRate: 48_000, tolerance: tolerance)
        #expect(tiny?.chunks == 1 && tiny?.frames == 480)

        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 1440)
        defer { scratch.deallocate() }
        var channels = [scratch]
        channels.withUnsafeMutableBufferPointer { pointers in
            for _ in 0..<3 {
                ring.consume(ring.peek()!, into: UnsafePointer(pointers.baseAddress!), at: 0)
            }
        }
        let rest = ring.contiguousRun(maxFrames: 48_000, sampleRate: 48_000, tolerance: tolerance)
        #expect(rest?.chunks == 1 && rest?.frames == 480)
    }

    @Test func monoCopyAveragesOrPicksFirstChannel() throws {
        let stereo = AudioFixtures.sine(frequency: 100, sampleRate: 48_000, channels: 2, seconds: 0.01)
        let right = stereo.floatChannelData![1]
        for frame in 0..<Int(stereo.frameLength) { right[frame] = 0 }

        let averaged = try #require(PCMCopy.mono(
            from: stereo.audioBufferList, format: stereo.format, frames: Int(stereo.frameLength), mix: .average
        ))
        let first = try #require(PCMCopy.mono(
            from: stereo.audioBufferList, format: stereo.format, frames: Int(stereo.frameLength), mix: .firstChannel
        ))
        #expect(averaged.format.channelCount == 1)
        #expect(averaged.frameLength == stereo.frameLength)
        let source = stereo.floatChannelData![0]
        for frame in [1, 50, 200] {
            #expect(abs(first.floatChannelData![0][frame] - source[frame]) < 1e-6)
            #expect(abs(averaged.floatChannelData![0][frame] - source[frame] / 2) < 1e-6)
        }
    }

    @Test func monoCopyReadsInterleavedInput() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        let samples = buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for index in 0..<8 { samples[index] = index.isMultiple(of: 2) ? 1 : 0.5 }
        let mono = try #require(PCMCopy.mono(from: buffer.audioBufferList, format: format, frames: 4, mix: .average))
        #expect(Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: 4)) == [0.75, 0.75, 0.75, 0.75])
    }
}

// MARK: - Part files and mixdown

@Suite struct AudioMixdownTests {
    @Test func mixesTwoSourcesAlignedByOffset() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let microphone = try AudioFixtures.part(
            in: folder, name: "mic", offset: 0.5,
            buffer: AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 1, seconds: 1)
        )
        let system = try AudioFixtures.part(
            in: folder, name: "system", offset: 2,
            buffer: AudioFixtures.sine(frequency: 660, sampleRate: 44_100, channels: 2, seconds: 1.5)
        )
        let destination = folder.appending(path: "audio.m4a")

        let duration = try #require(try AudioMixdown.mix([microphone, system], to: destination))
        #expect(abs(duration - 3.5) < 0.001)

        let file = try AVAudioFile(forReading: destination)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(file.fileFormat.channelCount == 1)
        let fileDuration = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(fileDuration - 3.5) < 0.05)

        // Silence before the mic starts and between the two sources, tone where each plays.
        #expect(try AudioFixtures.rms(of: destination, from: 0.05, to: 0.4) < 0.01)
        #expect(try AudioFixtures.rms(of: destination, from: 0.7, to: 1.3) > 0.2)
        #expect(try AudioFixtures.rms(of: destination, from: 1.6, to: 1.9) < 0.01)
        #expect(try AudioFixtures.rms(of: destination, from: 2.2, to: 3.3) > 0.2)

        // No temporary file left next to the result.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("mixing") }
        #expect(leftovers.isEmpty)
    }

    @Test func singleSourceMixes() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let system = try AudioFixtures.part(
            in: folder, name: "system", offset: 1,
            buffer: AudioFixtures.sine(frequency: 300, sampleRate: 48_000, channels: 2, seconds: 2)
        )
        let destination = folder.appending(path: "audio.m4a")
        let duration = try #require(try AudioMixdown.mix([system], to: destination))
        #expect(abs(duration - 3) < 0.001)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func nothingRecordedProducesNoFile() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "audio.m4a")
        #expect(try AudioMixdown.mix([], to: destination) == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func trackRendersAtSixteenKilohertzMonoOnTheSharedTimeline() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try AudioFixtures.part(
            in: folder, name: "part-a", offset: 0,
            buffer: AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 1, seconds: 1)
        )
        let second = try AudioFixtures.part(
            in: folder, name: "part-b", offset: 2.5,
            buffer: AudioFixtures.sine(frequency: 440, sampleRate: 44_100, channels: 1, seconds: 1)
        )
        let destination = folder.appending(path: "track-microphone.caf")

        let duration = try #require(try AudioMixdown.renderTrack([first, second], to: destination))
        #expect(abs(duration - 3.5) < 0.001)

        let file = try AVAudioFile(forReading: destination)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM)
        #expect(file.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
        #expect(abs(Double(file.length) / 16_000 - 3.5) < 0.001)

        #expect(try AudioFixtures.rms(of: destination, from: 0.1, to: 0.9) > 0.2)
        #expect(try AudioFixtures.rms(of: destination, from: 1.2, to: 2.3) < 0.01)
        #expect(try AudioFixtures.rms(of: destination, from: 2.6, to: 3.4) > 0.2)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("mixing") }
        #expect(leftovers.isEmpty)
    }

    @Test func trackDownmixesStereo() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The same tone in both channels must stay at its amplitude, not double or halve.
        let stereo = try AudioFixtures.part(
            in: folder, name: "part-s", offset: 0,
            buffer: AudioFixtures.sine(frequency: 300, sampleRate: 48_000, channels: 2, seconds: 1, amplitude: 0.5)
        )
        let destination = folder.appending(path: "track-system.caf")
        _ = try #require(try AudioMixdown.renderTrack([stereo], to: destination))
        #expect(try AVAudioFile(forReading: destination).fileFormat.channelCount == 1)
        let rms = try AudioFixtures.rms(of: destination, from: 0.1, to: 0.9)
        #expect(abs(rms - 0.5 / Float(2).squareRoot()) < 0.03)
    }

    @Test func emptyTrackProducesNoFile() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "track-microphone.caf")
        #expect(try AudioMixdown.renderTrack([], to: destination) == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func staleTracksAreRemovedButPartsAndAudioStay() throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = [
            "track-microphone.caf", "track-system.caf", ".track-system-mixing.caf",
            "part-microphone-0-0ms.caf", "audio.m4a",
        ]
        for name in names { FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: Data([0])) }

        #expect(RecordingRecovery.parse("track-microphone.caf") == nil)
        RecordingRecovery.removeStaleTracks(in: folder)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(remaining == ["audio.m4a", "part-microphone-0-0ms.caf"])
    }

    @Test func trackSweepSkipsMeetingsInUse() throws {
        let root = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let busy = UUID()
        let idle = UUID()
        for id in [busy, idle] {
            let folder = root.appending(path: id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appending(path: "track-system.caf").path, contents: Data([0]))
        }
        RecordingRecovery.removeStaleTracks(skipping: [busy], recordings: root)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(busy.uuidString)/track-system.caf").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "\(idle.uuidString)/track-system.caf").path))
    }

    @Test func pipelineSplitsOnFormatChangeAndPadsGaps() async throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (stream, continuation) = AsyncStream.makeStream(of: CapturedAudio.self)
        let start = HostClock.now
        let pipeline = SourcePipeline(
            source: .microphone, folder: folder, startHostTime: start,
            continuation: continuation, levels: nil
        )
        func host(_ seconds: Double) -> UInt64 { start + HostClock.ticks(forSeconds: seconds) }

        // 1 s of contiguous audio, a 0.5 s stall, 0.5 s more, then the device switches to 44.1 kHz.
        pipeline.process(AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 1, seconds: 0.5), hostTime: host(0))
        pipeline.process(AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 1, seconds: 0.5), hostTime: host(0.5))
        pipeline.process(AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 1, seconds: 0.5), hostTime: host(1.5))
        pipeline.process(AudioFixtures.sine(frequency: 440, sampleRate: 44_100, channels: 1, seconds: 1), hostTime: host(2.1))
        let segments = pipeline.finish()

        var times: [TimeInterval] = []
        for await chunk in stream { times.append(chunk.time) }
        #expect(times.count == 4)
        #expect(zip(times, [0, 0.5, 1.5, 2.1]).allSatisfy { abs($0 - $1) < 0.001 })

        #expect(segments.count == 2)
        #expect(abs(segments[0].offset) < 0.001)
        #expect(abs(segments[0].duration - 2) < 0.001) // includes the padded stall
        #expect(segments[1].sampleRate == 44_100)
        #expect(abs(segments[1].offset - 2.1) < 0.001)
        #expect(segments.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })

        let destination = folder.appending(path: "audio.m4a")
        let duration = try #require(try AudioMixdown.mix(segments, to: destination))
        #expect(abs(duration - 3.1) < 0.001)
        #expect(try AudioFixtures.rms(of: destination, from: 1.1, to: 1.4) < 0.01)
        #expect(try AudioFixtures.rms(of: destination, from: 2.3, to: 2.9) > 0.2)
    }

    @Test func partFileFailureIsReportedOnceAndRetriedLater() async throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A part file cannot be created in a folder that does not exist yet.
        let missing = folder.appending(path: "missing", directoryHint: .isDirectory)
        let reported = Mutex<[RecordingIssue]>([])
        let (stream, continuation) = AsyncStream.makeStream(of: CapturedAudio.self)
        let start = HostClock.now
        let pipeline = SourcePipeline(
            source: .system, folder: missing, startHostTime: start,
            continuation: continuation, levels: nil,
            issues: IssueReporter { issue in reported.withLock { $0.append(issue) } }
        )
        func host(_ seconds: Double) -> UInt64 { start + HostClock.ticks(forSeconds: seconds) }

        for index in 0..<10 {
            pipeline.process(AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 2, seconds: 0.1), hostTime: host(Double(index) * 0.1))
        }
        #expect(reported.withLock { $0 } == [.audioNotSaved(.system)])

        // Space came back. Writing resumes after the retry interval, at the buffer's own time.
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        pipeline.process(AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 2, seconds: 0.1), hostTime: host(1))
        let retry = SourcePipeline.writeRetryInterval
        pipeline.process(AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 2, seconds: 0.5), hostTime: host(retry + 0.5))
        let segments = pipeline.finish()

        #expect(segments.count == 1)
        #expect(abs((segments.first?.offset ?? 0) - (retry + 0.5)) < 0.001)
        #expect(abs((segments.first?.duration ?? 0) - 0.5) < 0.001)
        #expect(reported.withLock { $0 }.count == 1)

        // Audio that was not written still reached the transcriber.
        var chunks = 0
        for await _ in stream { chunks += 1 }
        #expect(chunks == 12)
    }

    @Test func mutedBuffersAreZeroedWithoutBreakingTheTimeline() async throws {
        let folder = try AudioFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (stream, continuation) = AsyncStream.makeStream(of: CapturedAudio.self)
        let start = HostClock.now
        let pipeline = SourcePipeline(
            source: .microphone, folder: folder, startHostTime: start,
            continuation: continuation, levels: nil
        )
        func host(_ seconds: Double) -> UInt64 { start + HostClock.ticks(forSeconds: seconds) }

        let mutedWhile = [false, true, true, false]
        for (index, muted) in mutedWhile.enumerated() {
            pipeline.isMuted = muted
            let buffer = AudioFixtures.sine(frequency: 440, sampleRate: 48_000, channels: 1, seconds: 0.5)
            pipeline.process(buffer, hostTime: host(Double(index) * 0.5))
        }
        let segments = pipeline.finish()

        var chunks: [CapturedAudio] = []
        for await chunk in stream { chunks.append(chunk) }
        #expect(chunks.count == 4)
        #expect(zip(chunks.map(\.time), [0, 0.5, 1.0, 1.5]).allSatisfy { abs($0 - $1) < 0.001 })
        for (chunk, muted) in zip(chunks, mutedWhile) {
            let isSilent = LevelMath.rms(of: chunk.buffer) == 0
            #expect(isSilent == muted)
        }

        #expect(segments.count == 1)
        #expect(abs(segments[0].offset) < 0.001)
        #expect(abs(segments[0].duration - 2) < 0.001)

        let destination = folder.appending(path: "audio.m4a")
        _ = try #require(try AudioMixdown.mix(segments, to: destination))
        #expect(try AudioFixtures.rms(of: destination, from: 0.1, to: 0.4) > 0.2)
        #expect(try AudioFixtures.rms(of: destination, from: 0.6, to: 0.9) < 0.01)
        #expect(try AudioFixtures.rms(of: destination, from: 1.6, to: 1.9) > 0.2)
    }
}
