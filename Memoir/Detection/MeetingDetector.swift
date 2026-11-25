import Foundation

/// Feeds the monitors, the calendar and a timer into `DetectionPolicy`.
///
/// Idle cost: Core Audio and CoreMediaIO notify on change, so nothing runs until something
/// happens. The only timers are a wake-up for the policy's own deadlines, a 2 s poll while a
/// meeting app or browser is running audio (see `AudioProcessMonitor`), and a 30 s calendar
/// check while calendar detection is on, which is served from `EventKitCalendar`'s cache
/// (every 10 s instead while calendar access is still missing, to notice a grant).
final class MeetingDetector: MeetingDetecting {
    let suggestions: AsyncStream<MeetingSuggestion>

    private let continuation: AsyncStream<MeetingSuggestion>.Continuation
    private let calendar: any CalendarProviding
    private let audio = AudioProcessMonitor()
    private let camera = CameraMonitor()
    private var policy = DetectionPolicy()
    private var isStarted = false
    private var wakeTask: Task<Void, Never>?
    private var evaluationScheduled = false

    private static let pollInterval: TimeInterval = 2
    private static let calendarInterval: TimeInterval = 30
    private static let accessCheckInterval: TimeInterval = 10

    init(calendar: any CalendarProviding) {
        self.calendar = calendar
        (suggestions, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
        audio.onChange = { [weak self] in self?.setNeedsEvaluation() }
        camera.onChange = { [weak self] in self?.setNeedsEvaluation() }
    }

    isolated deinit {
        wakeTask?.cancel()
        audio.stop()
        camera.stop()
        continuation.finish()
    }

    func start(options: DetectionOptions) {
        isStarted = true
        update(options: options)
    }

    func update(options: DetectionOptions) {
        policy.update(options: options)
        guard isStarted else { return }
        // Turning a signal off also removes its listeners, so it costs nothing at all.
        if options.microphoneApps { audio.start() } else { audio.stop() }
        // The camera only corroborates a browser holding the microphone, so on its own it
        // has no effect and its listeners would be wasted.
        if options.camera && options.microphoneApps { camera.start() } else { camera.stop() }
        evaluate()
    }

    func setRecording(_ isRecording: Bool) {
        policy.setRecording(isRecording, at: .now)
        if isStarted { evaluate() }
    }

    func dismissed(_ suggestion: MeetingSuggestion) {
        policy.dismissed(suggestion, at: .now)
        if isStarted { evaluate() }
    }

    // MARK: - Evaluation

    /// Listener callbacks arrive in bursts (one process change fires several properties), so
    /// they are coalesced into one evaluation on the next main queue turn.
    private func setNeedsEvaluation() {
        guard isStarted, !evaluationScheduled else { return }
        evaluationScheduled = true
        Task { [weak self] in
            guard let self else { return }
            evaluationScheduled = false
            evaluate()
        }
    }

    private func evaluate() {
        let now = Date.now
        let options = policy.options
        let signals = DetectionSignals(
            microphoneUsers: options.microphoneApps ? audio.microphoneUsers() : [],
            cameraActive: options.camera && camera.isActive,
            currentEvent: options.calendar && calendar.hasAccess ? calendar.current() : nil
        )
        if let suggestion = policy.evaluate(signals, at: now) {
            continuation.yield(suggestion)
        }
        scheduleWake(after: now)
    }

    private func scheduleWake(after now: Date) {
        var wake = policy.nextDeadline(after: now)
        func consider(_ date: Date) {
            wake = min(wake ?? date, date)
        }
        if audio.needsPolling {
            consider(now + Self.pollInterval)
        }
        if policy.options.calendar {
            // Nothing tells the detector when access is granted, in Memoir or in System
            // Settings, so keep looking until it is.
            consider(now + (calendar.hasAccess ? Self.calendarInterval : Self.accessCheckInterval))
        }

        wakeTask?.cancel()
        guard let wake else {
            wakeTask = nil
            return
        }
        let delay = max(0.05, wake.timeIntervalSince(now))
        wakeTask = Task { [weak self] in
            // Generous tolerance lets the system batch this wake-up with others.
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(min(1, delay * 0.1)))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }
}
