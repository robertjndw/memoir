import AVFoundation
import CoreAudio
import os
import Synchronization

nonisolated enum SystemAudioError: Error {
    case tapUnavailable
    case aggregateUnavailable
    case unsupportedFormat
    case coreAudio(OSStatus)
}

/// Captures everything the Mac plays (except Memoir itself) through a Core Audio process tap.
///
/// Threading: the IOProc runs on the HAL realtime thread and only writes into a preallocated
/// ring. Everything else (setup, teardown, draining, rebuilds) runs on `queue`, which is also
/// the queue the pipeline is confined to.
nonisolated final class SystemAudioTap: @unchecked Sendable {
    private static let drainInterval: DispatchTimeInterval = .milliseconds(20)

    private let queue = DispatchQueue(label: "Memoir.SystemAudio", qos: .userInitiated)
    private let pipeline: SourcePipeline
    private let log = Logger(subsystem: "Memoir", category: "Audio")

    // Confined to `queue`.
    private var session: TapSession?
    private var drainTimer: DispatchSourceTimer?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var rebuildGeneration = 0
    private var ticksSinceHealthCheck = 0
    private var isStopped = false

    init(pipeline: SourcePipeline) {
        self.pipeline = pipeline
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.startOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops capture, flushes what is still in the ring and finishes the pipeline.
    func stop() async -> [PartSegment] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.stopOnQueue())
            }
        }
    }

    // MARK: - Queue confined

    private func startOnQueue() throws {
        session = try TapSession(queue: queue) { [weak self] in self?.scheduleRebuild(after: .milliseconds(250)) }
        observeDefaultOutput()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        drainTimer = timer
    }

    private func stopOnQueue() -> [PartSegment] {
        isStopped = true
        drainTimer?.cancel()
        drainTimer = nil
        removeDefaultOutputObserver()
        tearDownSession()
        return pipeline.finish()
    }

    private func tick() {
        guard let session else { return }
        drain(session)
        ticksSinceHealthCheck += 1
        // Roughly once a second. Catches sample rate switches (e.g. a Bluetooth headset
        // dropping into its call profile) that did not arrive through a listener.
        if session.ring.layoutMismatch.load(ordering: .relaxed) {
            scheduleRebuild(after: .nanoseconds(0))
        } else if ticksSinceHealthCheck >= 50 {
            ticksSinceHealthCheck = 0
            if session.hasFormatChanged() { scheduleRebuild(after: .nanoseconds(0)) }
        }
    }

    /// Runs on `queue`, not the IO thread, so allocating here is fine. Buffers are sized to the
    /// audio that is pending: they travel on to the transcriber, which may hold minutes of
    /// them while the speech model downloads.
    private func drain(_ session: TapSession) {
        let ring = session.ring
        let format = session.format
        let tolerance = HostClock.ticks(forSeconds: 0.002)
        // Merge back-to-back IO cycles into one buffer of at most a second, but never across a
        // discontinuity: the buffer's time is that of its first frame.
        while let first = ring.peek(),
              let run = ring.contiguousRun(maxFrames: Int(format.sampleRate), sampleRate: format.sampleRate, tolerance: tolerance)
        {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(run.frames)),
                  let channels = buffer.floatChannelData
            else { return }
            var filled = 0
            for _ in 0..<run.chunks {
                guard let chunk = ring.peek() else { break }
                ring.consume(chunk, into: channels, at: filled)
                filled += chunk.frames
            }
            buffer.frameLength = AVAudioFrameCount(filled)
            pipeline.process(buffer, hostTime: first.hostTime)
        }
        let dropped = ring.droppedFrames.exchange(0, ordering: .relaxed)
        if dropped > 0 {
            log.error("System audio ring overflowed, dropped \(dropped) frames")
        }
    }

    private func tearDownSession() {
        guard let session else { return }
        session.stopIO()
        drain(session)
        session.destroy()
        self.session = nil
    }

    private func scheduleRebuild(after delay: DispatchTimeInterval) {
        guard !isStopped else { return }
        rebuildGeneration += 1
        let generation = rebuildGeneration
        // Device changes arrive as bursts of notifications; coalesce them into one rebuild.
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopped, generation == self.rebuildGeneration else { return }
            self.rebuild()
        }
    }

    private func rebuild() {
        log.info("Rebuilding system audio tap")
        tearDownSession()
        do {
            session = try TapSession(queue: queue) { [weak self] in self?.scheduleRebuild(after: .milliseconds(250)) }
        } catch {
            log.error("System audio tap rebuild failed: \(error), retrying")
            scheduleRebuild(after: .seconds(2))
        }
    }

    private func observeDefaultOutput() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild(after: .milliseconds(250))
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        if status == noErr {
            defaultOutputListener = listener
        }
    }

    private func removeDefaultOutputObserver() {
        guard let listener = defaultOutputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        defaultOutputListener = nil
    }
}

// MARK: - Tap session

/// One tap + private aggregate device + IOProc. Rebuilt from scratch whenever the output
/// device or its format changes, since the aggregate is clocked by that device.
private nonisolated final class TapSession: @unchecked Sendable {
    let ring: AudioRingBuffer
    let format: AVAudioFormat

    private let system = AudioHardwareSystem.shared
    private let tap: AudioHardwareTap
    private let aggregate: AudioHardwareAggregateDevice
    private let queue: DispatchQueue
    private var procID: AudioDeviceIOProcID?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var isDestroyed = false

    init(queue: DispatchQueue, onChange: @escaping () -> Void) throws {
        self.queue = queue

        // Memoir has no process object until it opens an audio client, so this is often nil.
        let ownProcess = try? system.process(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0.id] } ?? [])
        description.name = "Memoir"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard let tap = try system.makeProcessTap(description: description) else {
            throw SystemAudioError.tapUnavailable
        }
        self.tap = tap

        let aggregate: AudioHardwareAggregateDevice
        do {
            aggregate = try Self.makeAggregate(system: system, tap: tap)
        } catch {
            try? system.destroyProcessTap(tap)
            throw error
        }
        self.aggregate = aggregate

        do {
            let tapFormat = try tap.format
            guard tapFormat.mFormatID == kAudioFormatLinearPCM,
                  tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  tapFormat.mBitsPerChannel == 32,
                  tapFormat.mChannelsPerFrame > 0
            else { throw SystemAudioError.unsupportedFormat }
            // The aggregate runs at its main device's rate and the tap is resampled into it
            // (drift compensation), so the aggregate rate is what the IOProc delivers.
            let aggregateRate = (try? aggregate.nominalSampleRate) ?? 0
            let sampleRate = aggregateRate > 0 ? aggregateRate : tapFormat.mSampleRate
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(tapFormat.mChannelsPerFrame)
            ) else { throw SystemAudioError.unsupportedFormat }
            self.format = format
            // Ten seconds of slack: the consumer drains every 20 ms, so this only matters if
            // the disk stalls badly.
            ring = AudioRingBuffer(channels: Int(format.channelCount), frameCapacity: Int(sampleRate * 10))
        } catch {
            try? system.destroyAggregateDevice(aggregate)
            try? system.destroyProcessTap(tap)
            throw error
        }

        do {
            try startIO()
        } catch {
            destroy()
            throw error
        }
        listen(onChange: onChange)
    }

    deinit {
        destroy()
    }

    /// Clock the aggregate from the current default output device and add the tap as a
    /// drift-compensated sub tap. A tap-only aggregate also runs, but then nothing anchors
    /// its clock and the tap's drift compensation has no reference; Apple's own tap sample
    /// uses the output device as main sub-device, so follow that. The price is that the
    /// aggregate must be rebuilt when the default output changes, which the owner handles.
    private static func makeAggregate(
        system: AudioHardwareSystem,
        tap: AudioHardwareTap
    ) throws -> AudioHardwareAggregateDevice {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Memoir System Audio",
            kAudioAggregateDeviceUIDKey: "\(Bundle.main.bundleIdentifier ?? "Memoir").system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: try tap.uid,
                    kAudioSubTapDriftCompensationKey: true,
                ] as [String: Any]
            ],
        ]
        if let output = try? system.defaultOutputDevice, let outputUID = try? output.uid {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        guard let aggregate = try system.makeAggregateDevice(description: description) else {
            throw SystemAudioError.aggregateUnavailable
        }
        return aggregate
    }

    private func startIO() throws {
        let ring = ring
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) { _, input, inputTime, _, _ in
            TapSession.capture(input, at: inputTime, into: ring)
        }
        guard status == noErr, let procID else { throw SystemAudioError.coreAudio(status) }
        self.procID = procID
        try aggregate.start(IOProcID: procID)
    }

    /// Runs on the HAL IO thread: no locks, no allocation, no Swift runtime calls that may
    /// take either.
    private static func capture(
        _ input: UnsafePointer<AudioBufferList>,
        at time: UnsafePointer<AudioTimeStamp>,
        into ring: AudioRingBuffer
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let count = buffers.count
        guard count > 0 else { return }
        let channels = ring.channels
        let hostTime = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : mach_absolute_time()

        // If the output device has input streams of its own (a USB headset, an interface),
        // they come first in the aggregate; the sub tap's stream is always appended last.
        let last = buffers[count - 1]
        if Int(last.mNumberChannels) == channels, let data = last.mData {
            let samples = data.assumingMemoryBound(to: Float.self)
            let frames = Int(last.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            ring.write(frames: frames, hostTime: hostTime) { frame, channel in
                samples[frame * channels + channel]
            }
        } else if last.mNumberChannels == 1, count >= channels {
            let first = count - channels
            let frames = Int(last.mDataByteSize) / MemoryLayout<Float>.size
            for channel in 0..<channels where buffers[first + channel].mData == nil { return }
            ring.write(frames: frames, hostTime: hostTime) { frame, channel in
                buffers[first + channel].mData.unsafelyUnwrapped.assumingMemoryBound(to: Float.self)[frame]
            }
        } else {
            ring.layoutMismatch.store(true, ordering: .relaxed)
        }
    }

    func hasFormatChanged() -> Bool {
        guard let rate = try? aggregate.nominalSampleRate, rate > 0 else { return false }
        return rate != format.sampleRate
    }

    func stopIO() {
        guard let procID else { return }
        try? aggregate.stop(IOProcID: procID)
    }

    /// Idempotent; safe on partially started sessions.
    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        listeners = []
        if let procID {
            try? aggregate.stop(IOProcID: procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
            self.procID = nil
        }
        try? system.destroyAggregateDevice(aggregate)
        try? system.destroyProcessTap(tap)
    }

    private func listen(onChange: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var targets: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (aggregate.id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (aggregate.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (tap.id, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal),
        ]
        if let main = try? aggregate.subdevices.first {
            targets.append((main.id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal))
        }
        for (object, selector, scope) in targets {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                listeners.append((object, address, block))
            }
        }
    }
}
