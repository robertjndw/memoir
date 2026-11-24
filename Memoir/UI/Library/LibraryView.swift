import AppKit
import SwiftData
import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable {
    case meetings = "Meetings"
    case ask = "Ask Memoir"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .meetings: "waveform"
        case .ask: "sparkles"
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.calendar) private var calendar
    @Query(sort: \Meeting.startDate, order: .reverse) private var meetings: [Meeting]

    @State private var section: LibrarySection = .meetings
    @AppStorage("meetingsLayout") private var meetingsLayout: MeetingsLayout = .list
    @State private var selectedID: UUID?
    @State private var searchText = ""
    @State private var selectedDay = Date.now

    @State private var renameTarget: Meeting?
    @State private var renameDraft = ""
    @State private var deleteTarget: Meeting?
    @State private var exportDocument = MarkdownDocument(text: "")
    @State private var exportName = ""
    @State private var isExporting = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 480)
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 520)
        .environment(\.meetingCommands, commands)
        .onAppear(perform: applyPendingSelection)
        .onChange(of: model.librarySelection) { applyPendingSelection() }
        .onChange(of: model.libraryAskRequested, initial: true) { _, requested in
            guard requested else { return }
            section = .ask
            model.libraryAskRequested = false
        }
        .onChange(of: meetingsLayout) { _, layout in
            if layout == .calendar { revealSelectionInCalendar() }
        }
        .onChange(of: meetings.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
        .alert("Rename Meeting", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Title", text: $renameDraft)
            Button("Rename") {
                if let renameTarget { model.rename(renameTarget, to: renameDraft) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { meeting in
            Button("Delete \"\(meeting.title)\"", role: .destructive) {
                if selectedID == meeting.id { selectedID = selectionAfterDeleting(meeting) }
                model.delete(meeting)
            }
        } message: { _ in
            Text("The recording, transcript and summary are permanently deleted.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: MarkdownDocument.markdownType,
            defaultFilename: exportName
        ) { _ in }
    }

    // MARK: - Columns

    private var sidebar: some View {
        List(selection: Binding(get: { section }, set: { if let new = $0 { section = new } })) {
            ForEach(LibrarySection.allCases) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
        }
        .navigationTitle("Memoir")
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch section {
        case .meetings:
            MeetingsColumn(
                meetings: meetings,
                layout: $meetingsLayout,
                selection: $selectedID,
                searchText: $searchText,
                selectedDay: $selectedDay
            )
        case .ask:
            ContentUnavailableView(
                "Ask Memoir",
                systemImage: "sparkles",
                description: Text("Ask questions across all of your meetings. Answers are generated on this Mac.")
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if section == .ask {
            ChatView(scope: .library, onSeek: nil)
                .navigationTitle("Ask Memoir")
        } else if let selectedID, let meeting = meetings.first(where: { $0.id == selectedID }) {
            MeetingDetailView(meeting: meeting)
                .id(meeting.id)
        } else {
            ContentUnavailableView("No Meeting Selected", systemImage: "waveform", description: Text("Choose a meeting to see its summary and transcript."))
                .toolbar { placeholderToolbar }
        }
    }

    /// Mirrors the meeting actions in a disabled state, like Mail does with no message selected.
    /// Without any detail items the window has no toolbar section for this column, so the
    /// content column's items get pushed to the trailing edge until a meeting is opened.
    @ToolbarContentBuilder
    private var placeholderToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Group {
                Button("Share", systemImage: "square.and.arrow.up") {}
                Button("More", systemImage: "ellipsis") {}
            }
            .disabled(true)
        }
    }

    // MARK: - Actions

    private var commands: MeetingCommands {
        MeetingCommands(
            rename: { meeting in
                renameDraft = meeting.title
                renameTarget = meeting
            },
            export: { meeting in
                exportDocument = MarkdownDocument(text: MeetingExporter.markdown(for: meeting))
                exportName = MeetingExporter.fileName(for: meeting.title)
                isExporting = true
            },
            reveal: { meeting in
                let folder = RecordingFiles.folder(for: meeting.id)
                if let url = meeting.audioURL, FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else if FileManager.default.fileExists(atPath: folder.path) {
                    NSWorkspace.shared.open(folder)
                } else {
                    NSWorkspace.shared.open(RecordingFiles.baseDirectory)
                }
            },
            delete: { meeting in
                guard model.recordingMeetingID != meeting.id else { return }
                deleteTarget = meeting
            }
        )
    }

    /// The row that takes over the selection, like in Mail and Notes: the one below, or the
    /// one above when the last row is deleted. Limited to what the column currently shows.
    private func selectionAfterDeleting(_ meeting: Meeting) -> UUID? {
        var visible = meetings.filter { MeetingGrouping.matches($0, query: searchText) }
        if meetingsLayout == .calendar {
            visible = visible.filter { calendar.isDate($0.startDate, inSameDayAs: selectedDay) }
        }
        guard let index = visible.firstIndex(where: { $0.id == meeting.id }) else { return nil }
        if index + 1 < visible.count { return visible[index + 1].id }
        return index > 0 ? visible[index - 1].id : nil
    }

    private func applyPendingSelection() {
        guard let id = model.librarySelection else { return }
        section = .meetings
        searchText = ""
        selectedID = id
        if meetingsLayout == .calendar { revealSelectionInCalendar() }
        model.librarySelection = nil
    }

    /// Moves the calendar to the selected meeting's day, so the highlighted row is actually on screen.
    private func revealSelectionInCalendar() {
        guard let selectedID else { return }
        // A recording that just started may not have reached the query yet, and it is today's.
        let start = meetings.first(where: { $0.id == selectedID })?.startDate ?? .now
        selectedDay = calendar.startOfDay(for: start)
    }
}

#if DEBUG
#Preview("Library") {
    @Previewable @State var model = AppModel.preview(samples: true)
    LibraryView()
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 1080, height: 700)
}

#Preview("Selected meeting") {
    @Previewable @State var model = AppModel.preview(samples: true) {
        $0.librarySelection = $0.previewMeeting("Design Review").id
    }
    LibraryView()
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 1080, height: 700)
}

// A private defaults suite so this layout choice doesn't leak into the other previews.
#Preview("Selected meeting, calendar") {
    @Previewable @State var model = AppModel.preview(samples: true) {
        $0.librarySelection = $0.previewMeeting("Design Review").id
    }
    let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "MemoirPreview.CalendarLayout") ?? .standard
        defaults.set(MeetingsLayout.calendar.rawValue, forKey: "meetingsLayout")
        return defaults
    }()
    LibraryView()
        .defaultAppStorage(defaults)
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 1080, height: 700)
}

#Preview("While recording") {
    @Previewable @State var model = AppModel.preview(samples: true) {
        let live = Meeting(title: "Weekly Sync", startDate: .now.addingTimeInterval(-600))
        $0.simulateRecording(live, lines: Meeting.sampleLines)
        $0.librarySelection = live.id
    }
    LibraryView()
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 1080, height: 700)
}

#Preview("Empty") {
    @Previewable @State var model = AppModel.preview()
    LibraryView()
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 1080, height: 700)
}
#endif
