import AppKit
import SwiftData
import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable {
    case meetings = "Meetings"
    case calendar = "Calendar"
    case ask = "Ask Memoir"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .meetings: "waveform"
        case .calendar: "calendar"
        case .ask: "sparkles"
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.calendar) private var calendar
    @Query(sort: \Meeting.startDate, order: .reverse) private var meetings: [Meeting]

    @State private var section: LibrarySection = .meetings
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
                if selectedID == meeting.id { selectedID = nil }
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
            MeetingListView(meetings: meetings, selection: $selectedID, searchText: $searchText)
        case .calendar:
            CalendarPane(meetings: meetings, selection: $selectedID, selectedDay: $selectedDay)
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

    private func applyPendingSelection() {
        guard let id = model.librarySelection else { return }
        section = .meetings
        searchText = ""
        selectedID = id
        model.librarySelection = nil
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
