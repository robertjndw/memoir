import AVFoundation
import Observation

@Observable
final class PlaybackController {
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isLoaded = false
    var rate: Float = 1 {
        didSet { if isPlaying { player?.rate = rate } }
    }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func load(url: URL, fallbackDuration: TimeInterval) {
        unload()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        duration = fallbackDuration
        isLoaded = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player != nil else { return }
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
        timeObserver = nil
        endObserver = nil
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.1 { seek(to: 0) }
            player.rate = rate
            isPlaying = true
        }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    #if DEBUG
    /// Looks loaded but has no player, so previews get enabled controls without an audio file.
    static func preview(at time: TimeInterval, of duration: TimeInterval, playing: Bool = false) -> PlaybackController {
        let controller = PlaybackController()
        controller.isLoaded = true
        controller.duration = duration
        controller.currentTime = time
        controller.isPlaying = playing
        return controller
    }
    #endif

    func seek(to time: TimeInterval, play: Bool = false) {
        guard let player else { return }
        let upper = duration > 0 ? duration : time
        let target = min(max(0, time), upper)
        currentTime = target
        Task { await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        if play, !isPlaying {
            player.rate = rate
            isPlaying = true
        }
    }
}
