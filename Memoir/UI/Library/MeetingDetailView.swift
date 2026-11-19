import SwiftData
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting

    @Environment(AppModel.self) private var model
    @Environment(\.meetingCommands) private var commands
    @State private var playback = PlaybackController()
    @State private var tab: Tab
    @State private var titleDraft = ""
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
        // Decided here rather than in `.task` so the first frame already shows the right tab.
        // The environment isn't readable yet, so the persisted status stands in for
        // `model.recordingMeetingID`; interrupted recordings are reset to ready at launch.
        _tab = State(initialValue: initialTab ?? (meeting.status == .recording ? .transcript : .summary))
    }

    private var isRecording: Bool { model.recordingMeetingID == meeting.id }

    private var speakerSpans: [SpeakerSpan] {
        meeting.sortedLines.map { SpeakerSpan(start: $0.start, end: $0.end, speaker: $0.speaker) }
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
            if meeting.audioURL != nil, !isRecording, tab != .chat {
                PlaybackBar(playback: playback, speakers: speakerSpans)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: tab == .chat)
        .toolbar { toolbar }
        .focusedSceneValue(\.focusedMeeting, FocusedMeeting(
            meeting: meeting,
            isRecording: isRecording,
            commands: commands,
            tab: $tab,
            rename: { titleFocused = true }
        ))
        .navigationTitle(meeting.title)
        .task(id: meeting.id) {
            if let url = meeting.audioURL, !isRecording {
                playback.load(url: url, fallbackDuration: meeting.duration)
            }
        }
        .onChange(of: meeting.title) { _, title in
            if !titleFocused { titleDraft = title }
        }
        .onChange(of: isRecording) { _, recording in
            // The file only becomes playable once the recording has finished.
            guard !recording, let url = meeting.audioURL else { return }
            playback.load(url: url, fallbackDuration: meeting.duration)
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
        model.rename(meeting, to: titleDraft)
        titleDraft = meeting.title
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .summary:
            SummaryView(meeting: meeting)
        case .transcript:
            TranscriptView(meeting: meeting, playback: playback)
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
                item: MeetingExporter.markdown(for: meeting),
                subject: Text(meeting.title),
                preview: SharePreview(meeting.title)
            )
            .help("Share")

            Menu {
                Button("Rename", systemImage: "pencil") { titleFocused = true }
                Button("Export as Markdown...", systemImage: "square.and.arrow.down") { commands.export(meeting) }
                Button("Reveal in Finder", systemImage: "folder") { commands.reveal(meeting) }
                Divider()
                Button("Delete Meeting...", systemImage: "trash", role: .destructive) { commands.delete(meeting) }
                    .disabled(isRecording)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More")
        }
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
