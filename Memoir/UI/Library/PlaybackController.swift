import AVFoundation
import Observation

@Observable
final class PlaybackController {
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isLoaded = false
    /// Nil until the file has been analysed, which happens in the background.
    private(set) var waveform: [Float]?
    /// Increases with every seek, so views can tell a deliberate jump apart from playback simply
    /// moving on (the transcript resumes following along on a jump).
    private(set) var seekGeneration = 0
    var rate: Float = 1 {
        didSet { if isPlaying { player?.rate = rate } }
    }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    /// Finished recordings don't change, so peaks are cached for the session.
    @ObservationIgnored private static var waveformCache: [URL: [Float]] = [:]

    /// Fine enough that the transcript highlight lands within a tenth of a second of the audio.
    /// Only `currentTime` changes at this rate, and only views that read it re-render.
    private static let tickInterval = CMTime(value: 1, timescale: 10)
    private static let endTolerance: TimeInterval = 0.1

    func load(url: URL, fallbackDuration: TimeInterval) {
        unload()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        duration = fallbackDuration
        isLoaded = true

        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.tickInterval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                // Ticks that arrive while a seek is in flight still report the old position and
                // would briefly snap the transcript highlight back.
                guard let self, self.player != nil, !self.isSeeking else { return }
                self.currentTime = max(0, time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.currentTime = self?.duration ?? 0
            }
        }
        statusObserver = item.observe(\.status) { [weak self] item, _ in
            // KVO can call back on any thread, so only the Sendable status crosses over.
            let failed = item.status == .failed
            guard failed else { return }
            Task { @MainActor in self?.itemDidFail() }
        }
        if let cached = Self.waveformCache[url] {
            waveform = cached
        } else {
            waveformTask = Task { [weak self] in
                guard let peaks = await WaveformLoader.peaks(for: url), !Task.isCancelled else { return }
                Self.waveformCache[url] = peaks
                guard let self, self.player?.currentItem === item else { return }
                self.waveform = peaks
            }
        }
        Task { [weak self] in
            // The stored duration can be zero or stale if the app quit mid-recording.
            guard let loaded = try? await item.asset.load(.duration), loaded.isNumeric else { return }
            guard let self, self.player?.currentItem === item else { return }
            self.duration = loaded.seconds
        }
    }

    /// Releases the player. Must run before the controller goes away, since the time observer
    /// is registered on the player.
    func unload() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
        player = nil
        waveformTask?.cancel()
        waveformTask = nil
        waveform = nil
        timeObserver = nil
        endObserver = nil
        statusObserver = nil
        isSeeking = false
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
        #if DEBUG
        previewClock?.cancel()
        #endif
    }

    func togglePlayback() {
        guard isLoaded else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - Self.endTolerance { seek(to: 0) }
            startPlaying()
        }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func seek(to time: TimeInterval, play: Bool = false) {
        guard isLoaded else { return }
        let upper = duration > 0 ? duration : time
        let target = min(max(0, time), upper)
        currentTime = target
        seekGeneration += 1
        if let player {
            let generation = seekGeneration
            isSeeking = true
            Task {
                // AVPlayer always calls back, with false when interrupted or when the item can't
                // seek. Either way this seek is over, unless a newer one has taken the flag.
                _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if generation == self.seekGeneration { self.isSeeking = false }
            }
        }
        // Nothing left to play, and an item sitting at its end may never report that it finished,
        // which would leave `isPlaying` stuck on.
        let atEnd = duration > 0 && target >= duration - Self.endTolerance
        if play, !isPlaying, !atEnd { startPlaying() }
    }

    /// A failed item never seeks or ticks again, so nothing would otherwise reset this state.
    private func itemDidFail() {
        guard player?.currentItem?.status == .failed else { return }
        isSeeking = false
        isPlaying = false
    }

    private func startPlaying() {
        player?.rate = rate
        isPlaying = true
        #if DEBUG
        if player == nil { runPreviewClock() }
        #endif
    }

    #if DEBUG
    @ObservationIgnored private var previewClock: Task<Void, Never>?

    /// Looks loaded but has no player, so previews get enabled controls without an audio file.
    /// While "playing" the time advances on its own, so previews show the transcript following along.
    static func preview(at time: TimeInterval, of duration: TimeInterval, playing: Bool = false) -> PlaybackController {
        let controller = PlaybackController()
        controller.isLoaded = true
        controller.duration = duration
        controller.currentTime = time
        controller.waveform = WaveformLoader.preview
        if playing { controller.startPlaying() }
        return controller
    }

    private func runPreviewClock() {
        previewClock?.cancel()
        previewClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isPlaying, self.player == nil else { return }
                self.currentTime = min(self.currentTime + 0.1 * Double(self.rate), self.duration)
                if self.currentTime >= self.duration { self.isPlaying = false }
            }
        }
    }
    #endif
}
