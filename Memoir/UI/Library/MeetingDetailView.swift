import AppKit
import SwiftData
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting

    @Environment(AppModel.self) private var model
    @Environment(\.meetingCommands) private var commands
    @State private var playback = PlaybackController()
    @State private var tab: Tab
    @State private var titleDraft = ""
    /// The title `titleDraft` was last in step with. A draft that differs from it was typed by the
    /// user, which is the only case worth committing.
    @State private var titleBaseline = ""
    @State private var findRequested = false
    @FocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case chat = "Chat"
        var id: Self { self }

        var shortcut: KeyEquivalent {
            switch self {
            case .summary: "1"
            case .transcript: "2"
            case .chat: "3"
            }
        }
    }

    /// `initialTab` overrides the default, which is the live transcript while recording.
    init(meeting: Meeting, initialTab: Tab? = nil) {
        self.meeting = meeting
        _titleDraft = State(initialValue: meeting.title)
        _titleBaseline = State(initialValue: meeting.title)
        // Decided here rather than in `.task` so the first frame already shows the right tab.
        // The environment isn't readable yet, so the persisted status stands in for
        // `model.recordingMeetingID`; interrupted recordings are reset to ready at launch.
        _tab = State(initialValue: initialTab ?? (meeting.status == .recording ? .transcript : .summary))
    }

    private var isRecording: Bool { model.recordingMeetingID == meeting.id }

    private struct PlayerKey: Hashable {
        var id: UUID
        var hasAudio: Bool
        var isRecording: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                content
                    .id(tab)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // A short crossfade only, which is fine with Reduce Motion as nothing moves.
            .animation(.easeInOut(duration: 0.15), value: tab)
        }
        // A safe area bar rather than an inset, so scrolling content softly fades out under the
        // player instead of ending at a hard line.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            // The chat has its own composer at the bottom edge, and two stacked bars crowd it.
            // Audio that was started from a citation keeps its controls, or it could not be paused.
            if meeting.audioURL != nil, !isRecording, tab != .chat || playback.isPlaying {
                MeetingPlaybackBar(meeting: meeting, playback: playback)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: tab == .chat)
        .animation(.easeInOut(duration: 0.15), value: playback.isPlaying)
        .toolbar { toolbar }
        .focusedSceneValue(\.focusedMeeting, FocusedMeeting(
            meeting: meeting,
            isActive: model.activeMeetingID == meeting.id,
            commands: commands,
            tab: $tab,
            rename: { titleFocused = true },
            find: {
                tab = .transcript
                findRequested = true
            }
        ))
        .navigationTitle(meeting.title)
        .task(id: PlayerKey(id: meeting.id, hasAudio: meeting.hasAudio, isRecording: isRecording)) {
            // `isRecording` turns false before the mixdown is done, so the file only becomes
            // playable when `hasAudio` flips, which is why that is part of the key.
            if let url = meeting.audioURL, !isRecording {
                playback.load(url: url, fallbackDuration: meeting.duration)
            }
        }
        .onChange(of: meeting.title) { _, title in
            // An untouched draft follows the title even while focused, or leaving the field
            // would write the old title back over a generated one.
            if !titleFocused || titleDraft == titleBaseline {
                titleDraft = title
                titleBaseline = title
            }
        }
        .onDisappear { playback.unload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            MeetingIcon(bundleID: meeting.sourceAppBundleID, size: 44)
                // Lines the icon up with the title's cap height.
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.title.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    // Escape puts the old title back, as when renaming in Finder.
                    .onExitCommand {
                        titleDraft = meeting.title
                        titleBaseline = meeting.title
                        titleFocused = false
                    }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitTitle() }
                    }
                    .accessibilityLabel("Meeting title")
                HStack(spacing: 6) {
                    if isRecording {
                        Label("Recording", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, isActive: !reduceMotion)
                            .transition(.opacity)
                    }
                    Text(meeting.startDate, format: .dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
                    if !isRecording, meeting.duration > 0 {
                        Text("\u{00B7} \(LibraryFormat.length(meeting.duration))")
                            .transition(.opacity)
                    }
                    if let app = meeting.sourceAppName, !app.isEmpty {
                        Text("\u{00B7} \(app)")
                    }
                }
                .foregroundStyle(.secondary)
                .animation(.smooth(duration: 0.25), value: isRecording)
                if !meeting.attendees.isEmpty {
                    HStack(spacing: 8) {
                        AvatarStack(names: meeting.attendees, size: 20)
                        Text(meeting.attendees.formatted(.list(type: .and, width: .narrow)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Attendees: \(meeting.attendees.formatted(.list(type: .and)))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isRecording {
                LiveWaveform(barCount: 32)
                    .frame(width: 120, height: 32)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .animation(.smooth(duration: 0.3), value: isRecording)
    }

    private func commitTitle() {
        if titleDraft != titleBaseline {
            model.rename(meeting, to: titleDraft)
        }
        titleDraft = meeting.title
        titleBaseline = meeting.title
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .summary:
            SummaryView(meeting: meeting)
        case .transcript:
            TranscriptView(meeting: meeting, playback: playback, findRequested: $findRequested)
        case .chat:
            ChatView(
                scope: .meeting(meeting.id),
                onSeek: meeting.audioURL == nil ? nil : { playback.seek(to: $0, play: true) }
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // In the toolbar the segmented control picks up the system glass treatment.
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Switch between summary, transcript and chat (Command-1, 2, 3)")
        }

        // Only Share stays visible. The rest is in More and in the Meeting menu, which also
        // holds the keyboard shortcuts.
        ToolbarItemGroup {
            ShareLink(
                item: MeetingShareItem(meeting: meeting),
                subject: Text(meeting.title),
                preview: SharePreview(meeting.title)
            )
            .help("Share")

            MoreMenu(meeting: meeting, rename: { titleFocused = true })
        }
    }
}

/// Its own view because it watches the transcription work on the meeting, which reports
/// progress many times a second and shouldn't redraw the whole detail view each time.
private struct MoreMenu: View {
    let meeting: Meeting
    let rename: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.meetingCommands) private var commands
    @State private var canIdentifySpeakers = false
    @State private var installCheck = 0

    private struct InstallCheck: Hashable {
        var enabled: Bool
        var generation: Int
    }

    private var isBusy: Bool {
        model.activeMeetingID == meeting.id
            || model.retranscribing.contains(meeting.id)
            || model.enhancing[meeting.id] != nil
    }

    var body: some View {
        Menu {
            Button("Rename", systemImage: "pencil", action: rename)
            Button("Export as Markdown…", systemImage: "square.and.arrow.down") { commands.export(meeting) }
            Button("Reveal in Finder", systemImage: "folder") { commands.reveal(meeting) }
            if meeting.audioURL != nil {
                Divider()
                // Only offered when it can do something, so the menu doesn't advertise a
                // feature that is switched off in Settings.
                if canIdentifySpeakers, !meeting.segments.isEmpty {
                    Button("Identify Speakers", systemImage: "person.2") {
                        Task { await model.identifySpeakers(in: meeting) }
                    }
                    .disabled(isBusy)
                }
                // Always there with audio: without the optional model it uses Apple's.
                Button("Transcribe Again", systemImage: "waveform") {
                    Task { await model.retranscribe(meeting) }
                }
                .disabled(isBusy)
            }
            Divider()
            Button("Delete Meeting…", systemImage: "trash", role: .destructive) { commands.delete(meeting) }
                .disabled(model.activeMeetingID == meeting.id)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
        // The model is usually installed from Settings, so look again whenever a window
        // comes forward, which includes this one after Settings closes.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            installCheck += 1
        }
        .task(id: InstallCheck(enabled: model.settings.identifySpeakers, generation: installCheck)) {
            guard model.settings.identifySpeakers else {
                canIdentifySpeakers = false
                return
            }
            canIdentifySpeakers = await model.services.optionalModels.isInstalled(.speakerIdentification)
        }
    }
}

/// Sorting the transcript for the waveform colours is too much work to repeat on every
/// keystroke in the title field, so it lives in a view that only updates with the meeting.
private struct MeetingPlaybackBar: View {
    let meeting: Meeting
    let playback: PlaybackController

    var body: some View {
        PlaybackBar(
            playback: playback,
            speakers: meeting.sortedLines.map { SpeakerSpan(start: $0.start, end: $0.end, speaker: $0.speakerID) }
        )
    }
}

#if DEBUG
#Preview("Summary") {
    @Previewable @State var model = AppModel.preview(samples: true)
    NavigationStack { MeetingDetailView(meeting: model.previewMeeting("Design Review")) }
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 760, height: 640)
}

#Preview("Not summarized") {
    @Previewable @State var model = AppModel.preview(samples: true)
    NavigationStack { MeetingDetailView(meeting: model.previewMeeting("Call at 9:15 AM")) }
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 760, height: 640)
}

#Preview("Chat") {
    @Previewable @State var model = AppModel.preview(samples: true) { model in
        let meeting = model.previewMeeting("Design Review")
        model.context.insert(ChatMessage(role: .user, text: "When do we launch?", meeting: meeting))
        model.context.insert(ChatMessage(
            role: .assistant,
            text: "On **the first Monday of next month** [0:31].",
            date: .now.addingTimeInterval(1),
            meeting: meeting
        ))
    }
    NavigationStack { MeetingDetailView(meeting: model.previewMeeting("Design Review"), initialTab: .chat) }
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 760, height: 640)
}

#Preview("Recording") {
    @Previewable @State var model = AppModel.preview {
        let meeting = Meeting(title: "Weekly Sync", startDate: .now.addingTimeInterval(-754))
        meeting.attendees = ["Maya Chen", "Jonas Weber"]
        $0.simulateRecording(meeting, lines: Meeting.sampleLines, volatile: [.others: "Works for me, I'll tell"])
    }
    NavigationStack { MeetingDetailView(meeting: model.previewMeeting("Weekly Sync")) }
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 760, height: 640)
}
#endif
