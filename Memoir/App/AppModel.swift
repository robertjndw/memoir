import AppKit
import Foundation
import Observation
import SwiftData

/// Root state of the app: owns the recording lifecycle and connects the engines to the store.
@Observable
final class AppModel {
    enum RecordingState: Equatable {
        case idle
        case starting
        case recording(UUID)
        case finishing
    }

    struct SummaryActivity: Equatable {
        var isRunning = true
        /// Set while a long transcript is condensed, before the summary itself streams.
        var condensing: Double?
        var draft: MeetingSummary?
        var error: String?
    }

    /// Shown in the menu bar for a while after a recording stops.
    struct FinishedRecording: Equatable {
        let meetingID: UUID
        let date: Date
    }

    enum WindowID {
        static let library = "library"
        static let onboarding = "onboarding"
    }

    let settings: AppSettings
    let container: ModelContainer
    @ObservationIgnored let services: Services
    let mcpServer: MCPServer
    var context: ModelContext { container.mainContext }

    private(set) var recordingState: RecordingState = .idle
    private(set) var recordingStartDate: Date?
    private(set) var levels = AudioLevels()
    /// Final lines of the recording in progress, in time order.
    private(set) var liveLines: [TranscriptLine] = []
    /// Text still being revised by the recognizer, per speaker.
    private(set) var volatileText: [Speaker: String] = [:]
    private(set) var unavailableSources: Set<AudioSource> = []
    /// The microphone is recorded as silence. System audio is unaffected.
    private(set) var isMicrophoneMuted = false
    var errorMessage: String?

    private(set) var upcomingMeeting: CalendarMeeting?
    private(set) var intelligenceAvailability: IntelligenceAvailability
    private(set) var summaryActivity: [UUID: SummaryActivity] = [:]
    private(set) var retranscribing: Set<UUID> = []
    /// Why the last attempt to transcribe a meeting from its file produced nothing.
    private(set) var transcriptionErrors: [UUID: String] = [:]

    /// Meeting the Library should select when it opens or comes forward.
    var librarySelection: UUID?
    /// Set when a question was asked from the menu bar, so the Library opens on Ask Memoir.
    var libraryAskRequested = false
    private(set) var lastRecording: FinishedRecording?
    /// Installed by the menu bar label, the one view that is alive for the whole app lifetime.
    @ObservationIgnored var openWindow: ((String) -> Void)?

    @ObservationIgnored private var recorder: (any AudioRecording)?
    @ObservationIgnored private var transcriber: (any Transcribing)?
    @ObservationIgnored private var levelsTask: Task<Void, Never>?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Recording time the current mute began. Only closed ranges are stored on the meeting.
    @ObservationIgnored private var mutedSince: TimeInterval?
    @ObservationIgnored private var isChangingMute = false
    @ObservationIgnored private var backgroundTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var chats: [ChatScope: ChatController] = [:]
    @ObservationIgnored private var regularWindowCount = 0
    @ObservationIgnored private lazy var corpus = StoreCorpus(container: container)

    init(settings: AppSettings, container: ModelContainer, services: Services) {
        self.settings = settings
        self.container = container
        self.services = services
        mcpServer = MCPServer(library: StoreCorpus(container: container))
        intelligenceAvailability = services.intelligence.availability
    }

    var isRecording: Bool {
        if case .recording = recordingState { true } else { false }
    }

    var recordingMeetingID: UUID? {
        if case .recording(let id) = recordingState { id } else { nil }
    }

    // MARK: - Lifecycle

    /// Called once at launch. Not part of init so previews and tests stay passive.
    func activate() {
        closeInterruptedRecordings()
        refresh()

        settings.detectionChanged = { [weak self] in
            guard let self else { return }
            services.detector.update(options: settings.detectionOptions)
        }
        services.detector.start(options: settings.detectionOptions)

        settings.mcpEnabledChanged = { [weak self] in self?.updateMCPServer() }
        updateMCPServer()

        let suggestions = services.detector.suggestions
        backgroundTasks.append(Task { [weak self] in
            for await suggestion in suggestions {
                self?.handle(suggestion)
            }
        })
        backgroundTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.refresh()
            }
        })
    }

    /// Cheap state that can go stale: next calendar meeting and model availability.
    func refresh() {
        intelligenceAvailability = services.intelligence.availability
        upcomingMeeting = settings.detectCalendar && services.calendar.hasAccess
            ? services.calendar.next(within: 8 * 3600)
            : nil
    }

    private func updateMCPServer() {
        if settings.mcpEnabled {
            mcpServer.start()
        } else {
            mcpServer.stop()
        }
    }

    private func closeInterruptedRecordings() {
        let recording = Meeting.Status.recording.rawValue
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.statusRaw == recording })
        for meeting in (try? context.fetch(descriptor)) ?? [] {
            meeting.status = .ready
            if let last = meeting.segments.map(\.end).max() {
                meeting.duration = max(meeting.duration, last)
            }
        }
    }

    // MARK: - Recording

    func toggleRecording() async {
        switch recordingState {
        case .idle: await startRecording()
        case .recording: await stopRecording()
        case .starting, .finishing: break
        }
    }

    func startRecording(from suggestion: MeetingSuggestion? = nil) async {
        guard recordingState == .idle else { return }
        recordingState = .starting
        errorMessage = nil
        lastRecording = nil
        services.hints.hide()

        let event = suggestion?.event ?? (services.calendar.hasAccess ? services.calendar.current() : nil)
        let now = Date.now
        let locale = settings.transcriptionLocale
        let meeting = Meeting(
            title: event?.title ?? Self.placeholderTitle(appName: suggestion?.appName, date: now),
            hasCustomTitle: event != nil,
            startDate: now,
            localeIdentifier: locale.identifier
        )
        meeting.sourceAppName = suggestion?.appName
        meeting.sourceAppBundleID = suggestion?.bundleID
        meeting.calendarEventID = event?.id
        meeting.attendees = event?.attendees ?? []

        let folder = RecordingFiles.folder(for: meeting.id)
        let recorder = services.makeRecorder(folder)
        let streams: CaptureStreams
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            streams = try await recorder.start()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            errorMessage = error.localizedDescription
            recordingState = .idle
            return
        }

        context.insert(meeting)
        self.recorder = recorder
        unavailableSources = streams.unavailable
        // Never carried over: a mute left on from the last call would silently lose the
        // user's side of this one.
        isMicrophoneMuted = false
        mutedSince = nil
        liveLines = []
        volatileText = [:]
        levels = AudioLevels()
        recordingStartDate = now
        recordingState = .recording(meeting.id)
        services.detector.setRecording(true)

        levelsTask = Task { [weak self] in
            for await levels in streams.levels {
                self?.levels = levels
            }
        }

        // A recording without a transcript is still worth keeping (it can be transcribed from
        // the file later), so a transcription failure does not abort the recording.
        let transcriber = services.makeTranscriber()
        do {
            let updates = try await transcriber.start(
                streams: streams,
                locale: locale,
                contextualStrings: meeting.attendees + (event.map { [$0.title] } ?? [])
            )
            // Stopped while the transcriber was still starting: `stopRecording` could not finish
            // it then, so do it here instead of attaching updates to a saved meeting.
            guard recordingState == .recording(meeting.id) else {
                await transcriber.finish()
                return
            }
            self.transcriber = transcriber
            updatesTask = Task { [weak self] in
                for await update in updates {
                    self?.apply(update, to: meeting)
                }
            }
        } catch {
            errorMessage = "Live transcription is unavailable: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard case .recording(let meetingID) = recordingState, let recorder else { return }
        recordingState = .finishing
        services.hints.hide()

        let output = await recorder.stop()
        await transcriber?.finish()
        // The update stream ends after the last final result, so this drains everything.
        await updatesTask?.value
        levelsTask?.cancel()

        if let meeting = meeting(with: meetingID) {
            // The mix can be shorter than the meeting (or missing); never report less than
            // the time that actually passed.
            let elapsed = recordingStartDate.map { Date.now.timeIntervalSince($0) } ?? 0
            meeting.duration = output.audioURL == nil ? max(output.duration, elapsed) : output.duration
            meeting.hasAudio = output.audioURL != nil
            closeMutedRange(at: meeting.duration, in: meeting)
            meeting.status = .ready
            try? context.save()
            lastRecording = FinishedRecording(meetingID: meetingID, date: .now)
            contentChanged(in: meetingID)
            if settings.autoSummarize, !meeting.segments.isEmpty {
                Task { await summarize(meeting) }
            }
        }

        self.recorder = nil
        transcriber = nil
        levelsTask = nil
        updatesTask = nil
        recordingStartDate = nil
        isMicrophoneMuted = false
        mutedSince = nil
        volatileText = [:]
        levels = AudioLevels()
        services.detector.setRecording(false)
        recordingState = .idle
    }

    /// Brings a recording that is starting, running or being saved to a finished file. Unlike
    /// `stopRecording` it also waits out the transitional states, which is what quitting and
    /// the Stop shortcut need.
    func finishRecording() async {
        // A start can sit behind a permission prompt for as long as the user likes. Quitting
        // should not wait on that forever.
        let deadline = Date.now.addingTimeInterval(15)
        while recordingState != .idle, Date.now < deadline {
            if isRecording {
                await stopRecording()
            } else {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        try? context.save()
    }

    func toggleMicrophoneMuted() async {
        await setMicrophoneMuted(!isMicrophoneMuted)
    }

    func setMicrophoneMuted(_ muted: Bool) async {
        guard case .recording(let meetingID) = recordingState, let recorder,
              !unavailableSources.contains(.microphone),
              muted != isMicrophoneMuted, !isChangingMute
        else { return }
        // Two changes in flight could reach the capture queue out of order and leave the audio
        // disagreeing with this state, so a request during a change is dropped.
        isChangingMute = true
        defer { isChangingMute = false }

        let time = await recorder.setMicrophoneMuted(muted)
        // Stopped meanwhile. `stopRecording` has already closed any open range and reset the state.
        guard recordingState == .recording(meetingID), let meeting = self.meeting(with: meetingID) else { return }
        if muted {
            guard let time else { return }
            mutedSince = time
            isMicrophoneMuted = true
            // Otherwise half-recognized speech stays on screen until the recognizer finalizes
            // on the silence.
            volatileText[.me] = nil
        } else {
            isMicrophoneMuted = false
            let elapsed = recordingStartDate.map { Date.now.timeIntervalSince($0) } ?? 0
            closeMutedRange(at: time ?? elapsed, in: meeting)
        }
    }

    /// Written to the meeting right away, so a crash later in the recording keeps the range.
    private func closeMutedRange(at end: TimeInterval, in meeting: Meeting) {
        guard let start = mutedSince else { return }
        mutedSince = nil
        meeting.mutedRanges.append(MutedRange(start: start, end: max(start, end)))
    }

    private func apply(_ update: TranscriptUpdate, to meeting: Meeting) {
        guard update.isFinal else {
            volatileText[update.speaker] = update.text
            return
        }
        volatileText[update.speaker] = nil
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let line = TranscriptLine(speaker: update.speaker, start: update.start, end: update.end, text: text)
        // The two speakers finalize independently, so a line can arrive slightly out of order.
        let index = liveLines.lastIndex { $0.start <= line.start }.map { $0 + 1 } ?? 0
        liveLines.insert(line, at: index)

        let segment = TranscriptSegment(line: line)
        context.insert(segment)
        segment.meeting = meeting
    }

    private static func placeholderTitle(appName: String?, date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return appName.map { "\($0) Meeting at \(time)" } ?? "Meeting at \(time)"
    }

    // MARK: - Suggestions

    private func handle(_ suggestion: MeetingSuggestion) {
        switch (suggestion.kind, recordingState) {
        case (.start, .idle):
            break
        case (.stop, .recording) where settings.suggestStopping:
            break
        default:
            return
        }

        let muteApp: (() -> Void)? = suggestion.bundleID.map { bundleID in
            { [weak self] in
                self?.settings.mutedBundleIDs.insert(bundleID)
                self?.services.hints.hide()
            }
        }
        services.hints.show(suggestion, actions: MeetingHintActions(
            accept: { [weak self] in
                guard let self else { return }
                services.hints.hide()
                Task {
                    switch suggestion.kind {
                    case .start: await self.startRecording(from: suggestion)
                    case .stop: await self.stopRecording()
                    }
                }
            },
            dismiss: { [weak self] in
                self?.services.detector.dismissed(suggestion)
                self?.services.hints.hide()
            },
            muteApp: muteApp
        ))
    }

    // MARK: - Summary and transcript

    func summarize(_ meeting: Meeting) async {
        let id = meeting.id
        guard summaryActivity[id]?.isRunning != true else { return }
        let lines = meeting.sortedLines
        guard !lines.isEmpty else { return }

        refresh()
        guard intelligenceAvailability == .available else { return }

        summaryActivity[id] = SummaryActivity()
        let request = SummaryRequest(
            lines: lines,
            attendees: meeting.attendees,
            date: meeting.startDate,
            locale: Locale(identifier: meeting.localeIdentifier)
        )
        do {
            for try await progress in services.intelligence.summarize(request) {
                // Deleted while the model was still writing. Touching the model now would trap.
                guard isStored(meeting) else { return }
                switch progress {
                case .condensing(let fraction):
                    summaryActivity[id]?.condensing = fraction
                case .partial(let draft):
                    summaryActivity[id]?.condensing = nil
                    summaryActivity[id]?.draft = draft
                case .finished(let summary):
                    meeting.summary = summary
                    let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !meeting.hasCustomTitle, !title.isEmpty {
                        meeting.title = title
                    }
                    try? context.save()
                    contentChanged(in: id)
                }
            }
            summaryActivity[id] = nil
        } catch {
            guard isStored(meeting) else { return }
            summaryActivity[id] = SummaryActivity(isRunning: false, error: error.localizedDescription)
        }
    }

    /// Replaces the transcript with one made from the saved audio file.
    func retranscribe(_ meeting: Meeting) async {
        let id = meeting.id
        guard let url = meeting.audioURL, !retranscribing.contains(id), recordingMeetingID != id else { return }
        retranscribing.insert(id)
        transcriptionErrors[id] = nil
        defer { retranscribing.remove(id) }

        var lines: [TranscriptLine] = []
        do {
            let locale = Locale(identifier: meeting.localeIdentifier)
            for try await update in services.makeTranscriber().transcribe(file: url, locale: locale)
            where update.isFinal {
                let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append(TranscriptLine(speaker: update.speaker, start: update.start, end: update.end, text: text))
            }
        } catch {
            if isStored(meeting) { transcriptionErrors[id] = error.localizedDescription }
            return
        }
        guard isStored(meeting) else { return }
        // Only swap once the new transcript is complete, so a failure keeps the old one.
        guard !lines.isEmpty else {
            transcriptionErrors[id] = String(localized: "No speech was found in this recording.")
            return
        }
        for segment in meeting.segments {
            context.delete(segment)
        }
        for line in lines {
            let segment = TranscriptSegment(line: line)
            context.insert(segment)
            segment.meeting = meeting
        }
        try? context.save()
        contentChanged(in: id)
    }

    /// Chat sessions index the store when they are created and would keep answering from
    /// the old transcript or summary.
    private func contentChanged(in meetingID: UUID) {
        mcpServer.libraryChanged()
        chats[.library]?.invalidateSession()
        chats[.meeting(meetingID)]?.invalidateSession()
    }

    // MARK: - Library

    /// False once the meeting was deleted. Long-running work holds on to the model object and
    /// has to check before writing to it.
    private func isStored(_ meeting: Meeting) -> Bool {
        !meeting.isDeleted && meeting.modelContext != nil
    }

    func meeting(with id: UUID) -> Meeting? {
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func rename(_ meeting: Meeting, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != meeting.title else { return }
        meeting.title = title
        meeting.hasCustomTitle = true
    }

    func toggleActionItem(_ task: String, in meeting: Meeting) {
        if let index = meeting.completedActionItems.firstIndex(of: task) {
            meeting.completedActionItems.remove(at: index)
        } else {
            meeting.completedActionItems.append(task)
        }
    }

    func delete(_ meeting: Meeting) {
        guard recordingMeetingID != meeting.id else { return }
        let id = meeting.id
        chats[.meeting(id)]?.stop()
        chats[.meeting(id)] = nil
        chats[.library]?.invalidateSession()
        summaryActivity[id] = nil
        transcriptionErrors[id] = nil
        if librarySelection == id { librarySelection = nil }
        if lastRecording?.meetingID == id { lastRecording = nil }
        context.delete(meeting)
        try? context.save()
        mcpServer.libraryChanged()
        try? FileManager.default.removeItem(at: RecordingFiles.folder(for: id))
    }

    func chat(for scope: ChatScope) -> ChatController {
        if let existing = chats[scope] { return existing }
        let controller = ChatController(scope: scope, model: self, corpus: corpus)
        chats[scope] = controller
        return controller
    }

    func dismissLastRecording() {
        lastRecording = nil
    }

    /// Takes the title and attendees from the event and passes the names to the transcriber.
    func startRecording(event: CalendarMeeting, appName: String?, bundleID: String?) async {
        await startRecording(from: MeetingSuggestion(kind: .start, appName: appName, bundleID: bundleID, event: event))
    }

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        chat(for: .library).send(question)
        libraryAskRequested = true
        openLibrary()
    }

    func openLibrary(selecting meetingID: UUID? = nil) {
        if let meetingID { librarySelection = meetingID }
        openWindow?(WindowID.library)
        NSApp.activate()
    }

    // MARK: - Dock presence

    // Memoir is an agent app (LSUIElement). While one of its real windows is open it behaves
    // like a regular app, with Dock icon and main menu, and goes back to the menu bar after.

    func regularWindowAppeared() {
        regularWindowCount += 1
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    func regularWindowDisappeared() {
        regularWindowCount = max(0, regularWindowCount - 1)
        if regularWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

#if DEBUG
extension AppModel {
    /// Fakes a running recording for previews, no audio capture. Has to live in this file
    /// because the state is `private(set)`.
    func simulateRecording(
        _ meeting: Meeting,
        elapsed: TimeInterval = 754,
        lines: [TranscriptLine] = [],
        volatile: [Speaker: String] = [:],
        levels: AudioLevels = AudioLevels(microphone: 0.55, system: 0.3),
        unavailable: Set<AudioSource> = [],
        microphoneMuted: Bool = false
    ) {
        meeting.status = .recording
        context.insert(meeting)
        recordingState = .recording(meeting.id)
        recordingStartDate = .now.addingTimeInterval(-elapsed)
        liveLines = lines
        volatileText = volatile
        self.levels = levels
        unavailableSources = unavailable
        isMicrophoneMuted = microphoneMuted
        mutedSince = microphoneMuted ? elapsed : nil
    }

    /// For the transitional states that have no data of their own.
    func simulate(_ state: RecordingState) {
        recordingState = state
    }

    func simulateTranscribing(_ meeting: Meeting) {
        retranscribing.insert(meeting.id)
    }

    func simulateUpcoming(_ event: CalendarMeeting?) {
        upcomingMeeting = event
    }

    func simulateFinished(_ meeting: Meeting, summarizing: Bool = false) {
        lastRecording = FinishedRecording(meetingID: meeting.id, date: .now.addingTimeInterval(-40))
        if summarizing { summaryActivity[meeting.id] = SummaryActivity() }
    }
}
#endif

/// Read access to the store for chat retrieval and the MCP tools, callable from any isolation.
@MainActor
final class StoreCorpus: MeetingLibrary {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    @MainActor func meetings() async -> [MeetingDigest] {
        let descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        return ((try? container.mainContext.fetch(descriptor)) ?? []).map(\.digest)
    }

    @MainActor func lines(of meetingID: UUID) async -> [TranscriptLine] {
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        descriptor.fetchLimit = 1
        return (try? container.mainContext.fetch(descriptor).first)?.sortedLines ?? []
    }

    @MainActor func completedActionItems(of meetingID: UUID) async -> Set<String> {
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        descriptor.fetchLimit = 1
        return Set((try? container.mainContext.fetch(descriptor).first)?.completedActionItems ?? [])
    }
}
