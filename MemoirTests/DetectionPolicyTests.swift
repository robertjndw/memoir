import Foundation
import Testing
@testable import Memoir

/// Drives the policy like the detector does, evaluating once per simulated second.
private struct Harness {
    var policy: DetectionPolicy
    var now = Date(timeIntervalSinceReferenceDate: 700_000_000)
    var signals = DetectionSignals()
    var emitted: [MeetingSuggestion] = []

    init(options: DetectionOptions = DetectionOptions()) {
        policy = DetectionPolicy(options: options)
    }

    var timing: DetectionPolicy.Timing { policy.timing }

    /// Advances the clock in one second steps and returns what was suggested meanwhile.
    @discardableResult
    mutating func run(_ seconds: TimeInterval) -> [MeetingSuggestion] {
        var produced: [MeetingSuggestion] = []
        var elapsed: TimeInterval = 0
        repeat {
            if let suggestion = policy.evaluate(signals, at: now) {
                produced.append(suggestion)
            }
            guard elapsed < seconds else { break }
            let step = min(1, seconds - elapsed)
            now += step
            elapsed += step
        } while true
        emitted += produced
        return produced
    }

    mutating func hold(_ users: MicrophoneUser...) {
        signals.microphoneUsers = users
    }

    mutating func release() {
        signals.microphoneUsers = []
    }

    mutating func dismiss(_ suggestion: MeetingSuggestion) {
        policy.dismissed(suggestion, at: now)
    }

    mutating func setRecording(_ on: Bool) {
        policy.setRecording(on, at: now)
    }

    mutating func setOptions(_ options: DetectionOptions) {
        policy.update(options: options)
    }

    func event(_ id: String = "event", startsIn offset: TimeInterval, minutes: Double = 30) -> CalendarMeeting {
        CalendarMeeting(
            id: id,
            title: "Design Review",
            start: now + offset,
            end: now + offset + minutes * 60,
            attendees: ["Ana"],
            joinURL: nil
        )
    }
}

nonisolated private let zoom = MicrophoneUser(bundleID: "us.zoom.xos", name: "Zoom", category: .meeting)
nonisolated private let teams = MicrophoneUser(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", category: .meeting)
nonisolated private let chrome = MicrophoneUser(bundleID: "com.google.Chrome", name: "Google Chrome", category: .browser)
nonisolated private let voiceMemos = MicrophoneUser(bundleID: "com.apple.VoiceMemos", name: "Voice Memos", category: .other)
nonisolated private let memoir = MicrophoneUser(bundleID: "de.jandow.Memoir", name: "Memoir", category: .other)

@Suite("Detection: policy")
struct DetectionPolicyTests {
    // MARK: Meeting apps

    @Test func meetingAppTriggersAfterDebounce() throws {
        var h = Harness()
        h.hold(zoom)
        #expect(h.run(h.timing.micDebounce - 1).isEmpty)
        let suggestions = h.run(1)
        let suggestion = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(suggestion.kind == .start)
        #expect(suggestion.bundleID == "us.zoom.xos")
        #expect(suggestion.appName == "Zoom")
        #expect(suggestion.event == nil)
    }

    @Test func briefMicrophoneUseIsIgnored() {
        var h = Harness()
        h.hold(zoom)
        h.run(2)
        h.release()
        h.run(60)
        #expect(h.emitted.isEmpty)
    }

    @Test func repeatedBlipsDoNotAddUp() {
        var h = Harness()
        for _ in 0..<10 {
            h.hold(zoom)
            h.run(2)
            h.release()
            h.run(2)
        }
        #expect(h.emitted.isEmpty)
    }

    @Test func noRepeatWhileTheAppKeepsTheMicrophone() {
        var h = Harness()
        h.hold(zoom)
        h.run(3600)
        #expect(h.emitted.count == 1)
    }

    @Test func shortReleaseContinuesTheSameSession() {
        var h = Harness()
        h.hold(zoom)
        h.run(30)
        h.release()
        h.run(h.timing.sessionGap - 2)
        h.hold(zoom)
        h.run(300)
        #expect(h.emitted.count == 1)
    }

    @Test func newCallAfterAPauseIsSuggestedAgain() {
        var h = Harness()
        h.hold(zoom)
        h.run(30)
        h.release()
        h.run(h.timing.sessionGap + 5)
        h.hold(zoom)
        h.run(30)
        #expect(h.emitted.count == 2)
    }

    @Test func twoAppsAtOnceGiveOneSuggestionPreferringTheMeetingApp() {
        var h = Harness()
        h.signals.cameraActive = true
        h.hold(chrome, zoom)
        h.run(60)
        #expect(h.emitted.count == 1)
        #expect(h.emitted.first?.bundleID == "us.zoom.xos")
    }

    @Test func secondAppJoiningLaterGetsItsOwnSuggestion() {
        var h = Harness()
        h.hold(zoom)
        h.run(30)
        h.hold(zoom, teams)
        h.run(30)
        #expect(h.emitted.map(\.bundleID) == ["us.zoom.xos", "com.microsoft.teams2"])
    }

    // MARK: Browsers and other apps

    @Test func browserAloneNeverTriggers() {
        var h = Harness()
        h.hold(chrome)
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func browserWithCameraTriggers() {
        var h = Harness()
        h.hold(chrome)
        h.run(30)
        h.signals.cameraActive = true
        let suggestions = h.run(1)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.bundleID == "com.google.Chrome")
        #expect(h.run(600).isEmpty)
    }

    @Test func browserWithCurrentEventTriggersWithTheEvent() {
        var h = Harness()
        let event = h.event(startsIn: 120)
        h.signals.currentEvent = event
        h.hold(chrome)
        h.run(h.timing.micDebounce)
        #expect(h.emitted.count == 1)
        #expect(h.emitted.first?.bundleID == "com.google.Chrome")
        #expect(h.emitted.first?.event == event)
        // The event reaching its start time is the same meeting.
        h.run(600)
        #expect(h.emitted.count == 1)
    }

    @Test func browserNeedsDebounceEvenWithCamera() {
        var h = Harness()
        h.signals.cameraActive = true
        h.hold(chrome)
        #expect(h.run(h.timing.micDebounce - 1).isEmpty)
        #expect(h.run(1).count == 1)
    }

    @Test(arguments: [voiceMemos, memoir])
    func otherAppsNeverTrigger(_ app: MicrophoneUser) {
        var h = Harness()
        h.signals.cameraActive = true
        h.hold(app)
        h.run(3600)
        #expect(h.emitted.isEmpty)
    }

    // MARK: Calendar

    @Test func eventReachingStartTriggersOnce() throws {
        var h = Harness()
        let event = h.event(startsIn: 240)
        h.signals.currentEvent = event
        #expect(h.run(239).isEmpty)
        let suggestions = h.run(1)
        let suggestion = try #require(suggestions.first)
        #expect(suggestion.kind == .start)
        #expect(suggestion.event == event)
        #expect(suggestion.bundleID == nil)
        #expect(h.run(1200).isEmpty)
    }

    @Test func eventAlreadyLongUnderwayIsSkipped() {
        var h = Harness()
        h.signals.currentEvent = h.event(startsIn: -(h.timing.eventLateness + 60), minutes: 60)
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func eventStartedRecentlyIsStillSuggested() {
        var h = Harness()
        h.signals.currentEvent = h.event(startsIn: -120)
        h.run(0)
        #expect(h.emitted.count == 1)
    }

    @Test func recurringOccurrencesAreSeparateMeetings() {
        var h = Harness()
        h.signals.currentEvent = h.event("daily", startsIn: 0, minutes: 15)
        h.run(15 * 60)
        h.signals.currentEvent = nil
        h.run(60)
        h.signals.currentEvent = h.event("daily", startsIn: 0, minutes: 15)
        h.run(5)
        #expect(h.emitted.count == 2)
    }

    @Test func appSignalDuringEventGivesOneCombinedSuggestion() throws {
        var h = Harness()
        let event = h.event(startsIn: 60)
        h.signals.currentEvent = event
        h.hold(zoom)
        h.run(600)
        let suggestion = try #require(h.emitted.first)
        #expect(h.emitted.count == 1)
        #expect(suggestion.bundleID == "us.zoom.xos")
        #expect(suggestion.event == event)
    }

    @Test func eventStartWaitsForAPendingAppSignal() throws {
        var h = Harness()
        let event = h.event(startsIn: 10)
        h.signals.currentEvent = event
        h.run(8)
        h.hold(zoom)
        h.run(120)
        let suggestion = try #require(h.emitted.first)
        #expect(h.emitted.count == 1)
        #expect(suggestion.bundleID == "us.zoom.xos")
        #expect(suggestion.event == event)
    }

    @Test func eventStartDuringAnOfferedCallStaysQuiet() {
        var h = Harness()
        h.hold(zoom)
        h.run(30)
        h.signals.currentEvent = h.event(startsIn: 60)
        h.run(600)
        #expect(h.emitted.count == 1)
    }

    @Test func eventStartDuringAnOfferedCallStaysQuietAfterTheCallEnds() {
        var h = Harness()
        h.hold(zoom)
        h.run(30)
        h.signals.currentEvent = h.event(startsIn: 60)
        h.run(120)
        h.release()
        h.run(300)
        #expect(h.emitted.count == 1)
        #expect(h.emitted.first?.event == nil)
    }

    @Test func eventStartDuringADismissedCallStaysQuietAfterTheCallEnds() throws {
        var h = Harness()
        h.hold(zoom)
        let first = try #require(h.run(10).first)
        h.dismiss(first)
        h.signals.currentEvent = h.event(startsIn: 60)
        h.run(120)
        h.release()
        h.run(300)
        #expect(h.emitted.count == 1)
    }

    @Test func callJoinedAfterAnIgnoredEventHintIsOfferedWithTheEvent() {
        var h = Harness()
        let event = h.event(startsIn: 0)
        h.signals.currentEvent = event
        h.run(180)
        h.hold(zoom)
        h.run(30)
        #expect(h.emitted.count == 2)
        #expect(h.emitted.last?.bundleID == "us.zoom.xos")
        #expect(h.emitted.last?.event == event)
    }

    // MARK: Dismissal and cooldown

    @Test func dismissedAppStaysQuietUntilCooldownAfterRelease() throws {
        var h = Harness()
        h.hold(zoom)
        let first = try #require(h.run(10).first)
        h.dismiss(first)
        h.run(600)
        h.release()
        h.run(h.timing.dismissCooldown - 10)
        h.hold(zoom)
        h.run(60)
        #expect(h.emitted.count == 1)

        h.release()
        h.run(h.timing.dismissCooldown + 1)
        h.hold(zoom)
        h.run(10)
        #expect(h.emitted.count == 2)
    }

    @Test func dismissingOneAppLeavesOthersAlone() throws {
        var h = Harness()
        h.hold(zoom)
        let first = try #require(h.run(10).first)
        h.dismiss(first)
        h.hold(zoom, teams)
        h.run(10)
        #expect(h.emitted.map(\.bundleID) == ["us.zoom.xos", "com.microsoft.teams2"])
    }

    @Test func dismissedEventIsNotOfferedAgainEvenWithAnApp() throws {
        var h = Harness()
        h.signals.currentEvent = h.event(startsIn: 0)
        let first = try #require(h.run(0).first)
        h.dismiss(first)
        h.hold(zoom)
        h.run(600)
        #expect(h.emitted.count == 1)
    }

    @Test func dismissingACombinedSuggestionSilencesBoth() throws {
        var h = Harness()
        h.signals.currentEvent = h.event(startsIn: -30)
        h.hold(zoom)
        let first = try #require(h.run(10).first)
        #expect(first.event != nil)
        h.dismiss(first)
        h.release()
        h.run(30)
        h.hold(zoom)
        h.run(600)
        #expect(h.emitted.count == 1)
    }

    // MARK: Options

    @Test func mutedAppNeverTriggers() {
        var h = Harness(options: DetectionOptions(mutedBundleIDs: ["us.zoom.xos"]))
        h.hold(zoom)
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func mutingDuringDebounceTakesEffectImmediately() {
        var h = Harness()
        h.hold(zoom)
        h.run(2)
        h.setOptions(DetectionOptions(mutedBundleIDs: ["us.zoom.xos"]))
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func microphoneDetectionOff() {
        var h = Harness(options: DetectionOptions(microphoneApps: false))
        h.hold(zoom)
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func cameraDetectionOffLeavesBrowsersAmbiguous() {
        var h = Harness(options: DetectionOptions(camera: false))
        h.signals.cameraActive = true
        h.hold(chrome)
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func calendarDetectionOff() {
        var h = Harness(options: DetectionOptions(calendar: false))
        h.signals.currentEvent = h.event(startsIn: 0)
        h.run(300)
        #expect(h.emitted.isEmpty)

        h.hold(zoom)
        h.run(10)
        #expect(h.emitted.count == 1)
        #expect(h.emitted.first?.event == nil)
    }

    @Test func turningCalendarOnWithEventWellUnderwayStaysQuiet() {
        var h = Harness(options: DetectionOptions(calendar: false))
        h.signals.currentEvent = h.event(startsIn: 0, minutes: 60)
        h.run(h.timing.eventLateness + 60)
        h.setOptions(DetectionOptions())
        h.run(60)
        #expect(h.emitted.isEmpty)
    }

    // MARK: Recording

    @Test func noStartSuggestionsWhileRecording() {
        var h = Harness()
        h.setRecording(true)
        h.signals.currentEvent = h.event(startsIn: 10)
        h.hold(zoom, memoir)
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func stopSuggestedOnceAfterMeetingAppReleases() throws {
        var h = Harness()
        h.hold(zoom)
        h.run(10)
        h.setRecording(true)
        h.hold(zoom, memoir)
        h.run(600)
        h.hold(memoir)
        #expect(h.run(h.timing.stopGrace - 1).isEmpty)
        let suggestions = h.run(1)
        let stop = try #require(suggestions.first)
        #expect(stop.kind == .stop)
        #expect(stop.bundleID == "us.zoom.xos")
        #expect(stop.appName == "Zoom")
        #expect(h.run(600).isEmpty)
    }

    @Test func briefMicrophoneUseDuringRecordingDoesNotSuggestStopping() {
        var h = Harness()
        h.setRecording(true)
        h.hold(teams)
        h.run(2)
        h.release()
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func appJoiningTheMicrophoneDuringRecordingCountsAfterDebounce() {
        var h = Harness()
        h.setRecording(true)
        h.hold(zoom)
        h.run(h.timing.micDebounce)
        h.release()
        h.run(h.timing.stopGrace)
        #expect(h.emitted.map(\.kind) == [.stop])
    }

    @Test func briefReleaseDuringRecordingDoesNotSuggestStopping() {
        var h = Harness()
        h.setRecording(true)
        h.hold(zoom)
        h.run(60)
        h.release()
        h.run(h.timing.stopGrace - 5)
        h.hold(zoom)
        h.run(60)
        #expect(h.emitted.isEmpty)
    }

    @Test func noStopWithoutAMeetingAppDuringTheRecording() {
        var h = Harness()
        h.setRecording(true)
        h.hold(memoir, voiceMemos, chrome)
        h.run(120)
        h.release()
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func browserWithCameraCountsForStopping() {
        var h = Harness()
        h.setRecording(true)
        h.signals.cameraActive = true
        h.hold(chrome)
        h.run(60)
        h.signals.cameraActive = false
        h.release()
        h.run(h.timing.stopGrace)
        #expect(h.emitted.map(\.kind) == [.stop])
    }

    @Test func stopRearmsWhenTheAppComesBack() {
        var h = Harness()
        h.setRecording(true)
        h.hold(zoom)
        h.run(60)
        h.release()
        h.run(60)
        h.hold(zoom)
        h.run(60)
        h.release()
        h.run(60)
        #expect(h.emitted.map(\.kind) == [.stop, .stop])
    }

    @Test func dismissedStopStaysQuietForThatRelease() throws {
        var h = Harness()
        h.setRecording(true)
        h.hold(zoom)
        h.run(60)
        h.release()
        let stop = try #require(h.run(h.timing.stopGrace).first)
        h.dismiss(stop)
        h.run(1200)
        #expect(h.emitted.count == 1)
    }

    @Test func mutedAppDoesNotSuggestStopping() {
        var h = Harness()
        h.setRecording(true)
        h.hold(zoom)
        h.run(60)
        h.setOptions(DetectionOptions(mutedBundleIDs: ["us.zoom.xos"]))
        h.release()
        h.run(600)
        #expect(h.emitted.isEmpty)
    }

    @Test func callStillRunningAfterRecordingStopsIsNotOfferedAgain() {
        var h = Harness()
        h.hold(zoom)
        h.run(10)
        h.setRecording(true)
        h.run(300)
        h.setRecording(false)
        h.run(600)
        #expect(h.emitted.count == 1)
    }

    @Test func eventRecordedIsNotOfferedAfterRecordingStops() {
        var h = Harness()
        h.signals.currentEvent = h.event(startsIn: 120)
        h.run(60)
        h.setRecording(true)
        h.run(300)
        h.setRecording(false)
        h.run(300)
        #expect(h.emitted.isEmpty)
    }

    @Test func newCallAfterRecordingIsOffered() {
        var h = Harness()
        h.setRecording(true)
        h.hold(zoom)
        h.run(60)
        h.release()
        h.run(30)
        h.setRecording(false)
        h.run(60)
        h.hold(teams)
        h.run(10)
        #expect(h.emitted.map(\.kind) == [.stop, .start])
        #expect(h.emitted.last?.bundleID == "com.microsoft.teams2")
    }

    // MARK: Deadlines

    @Test func deadlinesCoverDebounceEventStartAndStopGrace() {
        var h = Harness()
        let start = h.now
        #expect(h.policy.nextDeadline(after: h.now) == nil)

        h.hold(zoom)
        h.run(0)
        #expect(h.policy.nextDeadline(after: h.now) == start + h.timing.micDebounce)

        var calendar = Harness()
        let event = calendar.event(startsIn: 200)
        calendar.signals.currentEvent = event
        calendar.run(0)
        #expect(calendar.policy.nextDeadline(after: calendar.now) == event.start)

        var recording = Harness()
        recording.setRecording(true)
        recording.hold(zoom)
        recording.run(5)
        recording.release()
        recording.run(0)
        // The session's own expiry comes first; the stop deadline follows it.
        let released = recording.now
        #expect(recording.policy.nextDeadline(after: released) == released + recording.timing.sessionGap)
        #expect(
            recording.policy.nextDeadline(after: released + recording.timing.sessionGap)
                == released + recording.timing.stopGrace
        )
    }

    @Test func idlePolicyHasNoDeadline() {
        var h = Harness()
        h.hold(zoom)
        h.run(60)
        #expect(h.policy.nextDeadline(after: h.now) == nil)
    }
}
