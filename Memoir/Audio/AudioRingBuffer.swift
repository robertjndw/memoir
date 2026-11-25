import Darwin
import Synchronization

/// Single-producer single-consumer ring of interleaved Float32 frames plus the host time of
/// each written chunk. The producer side is the Core Audio IO thread and must never lock or
/// allocate; everything here is preallocated and synchronized with atomics only.
nonisolated final class AudioRingBuffer: @unchecked Sendable {
    struct Chunk {
        var hostTime: UInt64
        var frames: Int
    }

    let channels: Int
    let frameCapacity: Int
    private let chunkCapacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let chunks: UnsafeMutablePointer<Chunk>

    // Producer owned.
    private var producerFrame = 0
    private var producerChunk = 0
    // Consumer owned.
    private var consumerFrame = 0
    private var consumerChunk = 0

    private let publishedChunks = Atomic<Int>(0)
    private let consumedFrames = Atomic<Int>(0)
    private let consumedChunks = Atomic<Int>(0)

    /// Frames lost because the consumer fell behind by more than the whole capacity.
    let droppedFrames = Atomic<Int>(0)
    /// Set by the producer when the device delivered a layout it cannot interpret.
    let layoutMismatch = Atomic<Bool>(false)

    init(channels: Int, frameCapacity: Int, chunkCapacity: Int = 2048) {
        self.channels = max(channels, 1)
        self.frameCapacity = max(frameCapacity, 1)
        self.chunkCapacity = max(chunkCapacity, 1)
        samples = .allocate(capacity: self.frameCapacity * self.channels)
        samples.initialize(repeating: 0, count: self.frameCapacity * self.channels)
        chunks = .allocate(capacity: self.chunkCapacity)
        chunks.initialize(repeating: Chunk(hostTime: 0, frames: 0), count: self.chunkCapacity)
    }

    deinit {
        samples.deallocate()
        chunks.deallocate()
    }

    // MARK: Producer

    /// Realtime safe. `sample(frame, channel)` reads the source. Returns false if the chunk
    /// did not fit and was dropped.
    @discardableResult
    func write(frames: Int, hostTime: UInt64, sample: (Int, Int) -> Float) -> Bool {
        guard frames > 0 else { return true }
        let usedFrames = producerFrame - consumedFrames.load(ordering: .acquiring)
        let usedChunks = producerChunk - consumedChunks.load(ordering: .acquiring)
        guard frames <= frameCapacity - usedFrames, usedChunks < chunkCapacity else {
            droppedFrames.wrappingAdd(frames, ordering: .relaxed)
            return false
        }
        for frame in 0..<frames {
            let base = ((producerFrame + frame) % frameCapacity) * channels
            for channel in 0..<channels {
                samples[base + channel] = sample(frame, channel)
            }
        }
        chunks[producerChunk % chunkCapacity] = Chunk(hostTime: hostTime, frames: frames)
        producerFrame += frames
        producerChunk += 1
        publishedChunks.store(producerChunk, ordering: .releasing)
        return true
    }

    // MARK: Consumer

    /// The oldest unread chunk, without consuming it.
    func peek() -> Chunk? {
        guard consumerChunk < publishedChunks.load(ordering: .acquiring) else { return nil }
        return chunks[consumerChunk % chunkCapacity]
    }

    /// How many unread chunks, starting with the oldest, form one run of back-to-back audio
    /// (each starting within `tolerance` host ticks of where the previous one ended), and how
    /// many frames they hold. Stops before the run would exceed `maxFrames`, but always counts
    /// the first chunk. Nil when nothing is unread.
    func contiguousRun(maxFrames: Int, sampleRate: Double, tolerance: UInt64) -> (chunks: Int, frames: Int)? {
        let published = publishedChunks.load(ordering: .acquiring)
        guard consumerChunk < published else { return nil }
        var count = 0
        var frames = 0
        var expectedHost: UInt64 = 0
        for index in consumerChunk..<published {
            let chunk = chunks[index % chunkCapacity]
            if count > 0 {
                let jump = chunk.hostTime > expectedHost ? chunk.hostTime - expectedHost : expectedHost - chunk.hostTime
                if jump > tolerance || frames + chunk.frames > maxFrames { break }
            }
            count += 1
            frames += chunk.frames
            expectedHost = chunk.hostTime + HostClock.ticks(forSeconds: Double(chunk.frames) / sampleRate)
        }
        return (count, frames)
    }

    /// Consumes the chunk returned by `peek`, deinterleaving it into `destination` (one
    /// pointer per channel) starting at frame `offset`.
    func consume(_ chunk: Chunk, into destination: UnsafePointer<UnsafeMutablePointer<Float>>, at offset: Int) {
        for frame in 0..<chunk.frames {
            let base = ((consumerFrame + frame) % frameCapacity) * channels
            for channel in 0..<channels {
                destination[channel][offset + frame] = samples[base + channel]
            }
        }
        consumerFrame += chunk.frames
        consumerChunk += 1
        consumedFrames.store(consumerFrame, ordering: .releasing)
        consumedChunks.store(consumerChunk, ordering: .releasing)
    }
}
