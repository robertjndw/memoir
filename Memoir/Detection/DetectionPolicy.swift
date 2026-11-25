import Foundation

/// A snapshot of everything the detector observes.
nonisolated struct DetectionSignals: Sendable, Equatable {
    /// Owning apps that hold the microphone right now.
    var microphoneUsers: [MicrophoneUser] = []
    var cameraActive = false
    /// A meeting-like event in progress or starting within a few minutes.
    var currentEvent: CalendarMeeting?
}

/// Decides when to suggest recording. Pure and deterministic: time only enters through the
/// `now` arguments, so the detector drives it with the wall clock and tests with a fake one.
///
/// A "session" is one continuous use of the microphone by one app. Gaps shorter than
/// `sessionGap` (a device switch, a call app reopening its audio unit) continue the session,
/// so the user is asked at most once per call.
nonisolated struct DetectionPolicy {
    struct Timing: Sendable, Equatable {
        /// How long a meeting app must hold the microphone before it counts. Filters out
        /// permission probes and audio units that apps open briefly at launch.
        var micDebounce: TimeInterval = 4
        /// A release shorter than this continues the same session.
        var sessionGap: TimeInterval = 15
        /// After a dismissal, how long the app must stay off the microphone before a new
        /// session can be suggested again.
        var dismissCooldown: TimeInterval = 120
        /// While recording, how long the meeting app must stay off the microphone before
        /// suggesting to stop. Long enough to ride out a rejoin or a device switch.
        var stopGrace: TimeInterval = 20
        /// An event that started longer ago than this no longer gets a suggestion of its own,
        /// for example when Memoir launches in the middle of it.
        var eventLateness: TimeInterval = 10 * 60
    }

    private struct Session {
        var app: MicrophoneUser
        var activeSince: Date
        /// Nil while the app holds the microphone.
        var releasedAt: Date?
        /// A suggestion was made (or deliberately skipped) for this session.
        var handled = false
        var dismissed = false

        var isActive: Bool { releasedAt == nil }
    }

    private struct RecordingState {
        /// Meeting apps seen on the microphone during this recording.
        var apps: [String: MicrophoneUser] = [:]
        var lastApp: MicrophoneUser?
        var releasedAt: Date?
        var stopSuggested = false
    }

    let timing: Timing
    private(set) var options: DetectionOptions
    private(set) var isRecording = false

    private var sessions: [String: Session] = [:]
    /// Event keys mapped to the event end, so entries can be dropped once the event is over.
    private var handledEvents: [String: Date] = [:]
    private var dismissedEvents: [String: Date] = [:]
    private var recording = RecordingState()
    private var lastEvent: CalendarMeeting?

    init(options: DetectionOptions = DetectionOptions(), timing: Timing = Timing()) {
        self.options = options
        self.timing = timing
    }

    // MARK: - Inputs

    mutating func update(options: DetectionOptions) {
        self.options = options
    }

    mutating func setRecording(_ isRecording: Bool, at now: Date) {
        guard isRecording != self.isRecording else { return }
        self.isRecording = isRecording
        recording = RecordingState()
        // Whatever is going on right now is the meeting being (or just) recorded. Without
        // this, stopping a recording mid-call would immediately suggest starting one again.
        for key in sessions.keys where sessions[key]?.isActive == true {
            sessions[key]?.handled = true
        }
        if let lastEvent {
            handledEvents[Self.key(lastEvent)] = lastEvent.end
        }
    }

    mutating func dismissed(_ suggestion: MeetingSuggestion, at now: Date) {
        switch suggestion.kind {
        case .stop:
            recording.stopSuggested = true
        case .start:
            if let bundleID = suggestion.bundleID {
                var session = sessions[bundleID] ?? Session(
                    app: MicrophoneUser(bundleID: bundleID, name: suggestion.appName ?? bundleID, category: .meeting),
                    activeSince: now,
                    releasedAt: now
                )
                session.handled = true
                session.dismissed = true
                sessions[bundleID] = session
            }
            if let event = suggestion.event {
                dismissedEvents[Self.key(event)] = event.end
                handledEvents[Self.key(event)] = event.end
            }
        }
    }

    // MARK: - Evaluation

    /// Feeds a fresh snapshot. Returns at most one suggestion.
    mutating func evaluate(_ signals: DetectionSignals, at now: Date) -> MeetingSuggestion? {
        let event = options.calendar ? signals.currentEvent : nil
        let camera = options.camera && signals.cameraActive
        let holders = options.microphoneApps
            ? signals.microphoneUsers.filter { $0.category != .other && !options.mutedBundleIDs.contains($0.bundleID) }
            : []
        lastEvent = event
        handledEvents = handledEvents.filter { $0.value > now }
        dismissedEvents = dismissedEvents.filter { $0.value > now }
        updateSessions(holders: holders, at: now)

        if isRecording {
            return evaluateRecording(holders: holders, camera: camera, event: event, at: now)
        }
        return evaluateIdle(camera: camera, event: event, at: now)
    }

    /// The next moment at which `evaluate` could produce a different result even if the
    /// signals stay the same.
    func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for session in sessions.values {
            if let releasedAt = session.releasedAt {
                deadlines.append(releasedAt + gap(for: session))
            } else if !session.handled, !session.dismissed {
                deadlines.append(session.activeSince + timing.micDebounce)
            }
        }
        if let lastEvent, handledEvents[Self.key(lastEvent)] == nil {
            deadlines.append(lastEvent.start)
        }
        if isRecording, let releasedAt = recording.releasedAt, !recording.stopSuggested {
            deadlines.append(releasedAt + timing.stopGrace)
        }
        return deadlines.filter { $0 > now }.min()
    }

    // MARK: - Internals

    private mutating func updateSessions(holders: [MicrophoneUser], at now: Date) {
        let holding = Set(holders.map(\.bundleID))
        for key in sessions.keys where sessions[key]?.isActive == true && !holding.contains(key) {
            sessions[key]?.releasedAt = now
        }
        sessions = sessions.filter { _, session in
            guard let releasedAt = session.releasedAt else { return true }
            return now.timeIntervalSince(releasedAt) < gap(for: session)
        }
        for app in holders {
            if var session = sessions[app.bundleID] {
                if !session.isActive {
                    session.releasedAt = nil
                    // A blip must not add up to the debounce across separate short uses.
                    if !session.handled { session.activeSince = now }
                }
                session.app = app
                sessions[app.bundleID] = session
            } else {
                sessions[app.bundleID] = Session(app: app, activeSince: now)
            }
        }
    }

    private func gap(for session: Session) -> TimeInterval {
        session.dismissed ? timing.dismissCooldown : timing.sessionGap
    }

    /// Dedicated meeting apps always count. A browser counts only with corroboration, since
    /// it also uses the microphone for dictation and voice search.
    private func qualifies(_ app: MicrophoneUser, camera: Bool, event: CalendarMeeting?) -> Bool {
        switch app.category {
        case .meeting: true
        case .browser: camera || event != nil
        case .other: false
        }
    }

    private mutating func evaluateIdle(camera: Bool, event: CalendarMeeting?, at now: Date) -> MeetingSuggestion? {
        let eventKey = event.map(Self.key)
        let eventDismissed = eventKey.map { dismissedEvents[$0] != nil } ?? false

        let ready = sessions.values.filter { session in
            session.isActive && !session.handled && !session.dismissed
                && now.timeIntervalSince(session.activeSince) >= timing.micDebounce
                && qualifies(session.app, camera: camera, event: event)
        }
        if !ready.isEmpty {
            for session in ready {
                sessions[session.app.bundleID]?.handled = true
            }
            // The user already declined the meeting on the calendar.
            if eventDismissed { return nil }
            let best = ready.min { a, b in
                if (a.app.category == .meeting) != (b.app.category == .meeting) {
                    return a.app.category == .meeting
                }
                if a.activeSince != b.activeSince { return a.activeSince < b.activeSince }
                return a.app.bundleID < b.app.bundleID
            }!
            if let event, let eventKey {
                handledEvents[eventKey] = event.end
            }
            return MeetingSuggestion(kind: .start, appName: best.app.name, bundleID: best.app.bundleID, event: event)
        }

        guard let event, let eventKey, handledEvents[eventKey] == nil, now >= event.start else { return nil }
        if now.timeIntervalSince(event.start) > timing.eventLateness {
            handledEvents[eventKey] = event.end
            return nil
        }
        // A call in progress either was already offered or is about to be; either way it
        // stands for this event. A pending one is waited for so both arrive as one hint.
        // An offered or dismissed one is marked handled now, otherwise the event would fire
        // as soon as that call ends.
        let calls = sessions.values.filter { session in
            session.isActive && qualifies(session.app, camera: camera, event: event)
        }
        if calls.contains(where: { !$0.handled }) { return nil }
        if !calls.isEmpty {
            handledEvents[eventKey] = event.end
            return nil
        }
        handledEvents[eventKey] = event.end
        return MeetingSuggestion(kind: .start, event: event)
    }

    private mutating func evaluateRecording(
        holders: [MicrophoneUser],
        camera: Bool,
        event: CalendarMeeting?,
        at now: Date
    ) -> MeetingSuggestion? {
        recording.apps = recording.apps.filter { key, _ in
            options.microphoneApps && !options.mutedBundleIDs.contains(key)
        }
        if let lastApp = recording.lastApp, recording.apps[lastApp.bundleID] == nil {
            recording.lastApp = recording.apps.values.min { $0.bundleID < $1.bundleID }
        }
        for app in holders where qualifies(app, camera: camera, event: event) {
            // Apps opening the microphone for a moment at launch must not become part of the
            // call, or their release would suggest stopping. Sessions are kept up to date
            // while recording, so `activeSince` is the start of this use.
            guard let session = sessions[app.bundleID], session.isActive,
                  now.timeIntervalSince(session.activeSince) >= timing.micDebounce
            else { continue }
            recording.apps[app.bundleID] = app
            recording.lastApp = app
        }
        guard !recording.apps.isEmpty else {
            recording.releasedAt = nil
            return nil
        }
        if holders.contains(where: { recording.apps[$0.bundleID] != nil }) {
            recording.releasedAt = nil
            recording.stopSuggested = false
            return nil
        }
        let releasedAt = recording.releasedAt ?? now
        recording.releasedAt = releasedAt
        guard !recording.stopSuggested, now.timeIntervalSince(releasedAt) >= timing.stopGrace else { return nil }
        recording.stopSuggested = true
        return MeetingSuggestion(kind: .stop, appName: recording.lastApp?.name, bundleID: recording.lastApp?.bundleID)
    }

    /// Recurring events share one identifier across occurrences, so the start is part of the key.
    private static func key(_ event: CalendarMeeting) -> String {
        "\(event.id)@\(event.start.timeIntervalSinceReferenceDate)"
    }
}
