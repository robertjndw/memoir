import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting

    @Environment(AppModel.self) private var model
    @Environment(\.meetingCommands) private var commands
    @State private var playback = PlaybackController()
    @State private var tab: Tab = .summary
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case chat = "Chat"
        var id: Self { self }
    }

    private var isRecording: Bool { model.recordingMeetingID == meeting.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.bottom, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if meeting.audioURL != nil, !isRecording {
                PlaybackBar(playback: playback)
            }
        }
        .toolbar { toolbar }
        .navigationTitle(meeting.title)
        .task(id: meeting.id) {
            titleDraft = meeting.title
            tab = isRecording ? .transcript : .summary
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
                }
                Text(meeting.startDate, format: .dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
                if !isRecording, meeting.duration > 0 {
                    Text("\u{00B7} \(LibraryFormat.length(meeting.duration))")
                }
            }
            .foregroundStyle(.secondary)
            if !meeting.attendees.isEmpty {
                Text(meeting.attendees.formatted(.list(type: .and, width: .narrow)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel("Attendees: \(meeting.attendees.formatted(.list(type: .and)))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
        ToolbarItemGroup {
            Button { commands.export(meeting) } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Export as Markdown")

            ShareLink(
                item: MeetingExporter.markdown(for: meeting),
                subject: Text(meeting.title),
                preview: SharePreview(meeting.title)
            )
            .help("Share Markdown")

            Button { commands.reveal(meeting) } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Reveal in Finder")

            Button { commands.delete(meeting) } label: {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(isRecording)
            .help("Delete Meeting")
        }
    }
}
