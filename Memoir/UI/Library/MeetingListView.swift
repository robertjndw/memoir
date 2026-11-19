import SwiftData
import SwiftUI

struct MeetingListView: View {
    let meetings: [Meeting]
    @Binding var selection: UUID?
    /// Owned by `MeetingsColumn`, which also hosts the search field so it survives layout switches.
    var searchText: String = ""

    @Environment(\.meetingCommands) private var commands
    @Environment(\.calendar) private var calendar

    var body: some View {
        let filtered = meetings.filter { MeetingGrouping.matches($0, query: searchText) }
        List(selection: $selection) {
            ForEach(MeetingGrouping.groups(filtered, calendar: calendar)) { group in
                Section(MeetingGrouping.title(for: group.day, calendar: calendar)) {
                    ForEach(group.meetings) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(meeting.id)
                            .meetingActions(for: meeting)
                    }
                }
            }
        }
        .onDeleteCommand {
            if let id = selection, let meeting = meetings.first(where: { $0.id == id }) {
                commands.delete(meeting)
            }
        }
        .overlay {
            if meetings.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform",
                    description: Text("Click the Memoir icon in the menu bar and choose Start Recording to capture your first meeting.")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
}

#if DEBUG
#Preview("Meetings") {
    @Previewable @State var selection: UUID?
    @Previewable @State var model = AppModel.preview(samples: true)
    QueriedMeetings { meetings in
        NavigationStack {
            MeetingListView(meetings: meetings, selection: $selection)
        }
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 360, height: 520)
}

#Preview("No search results") {
    @Previewable @State var selection: UUID?
    @Previewable @State var model = AppModel.preview(samples: true)
    QueriedMeetings { meetings in
        NavigationStack {
            MeetingListView(meetings: meetings, selection: $selection, searchText: "roadmap")
        }
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 360, height: 520)
}

#Preview("Empty") {
    @Previewable @State var selection: UUID?
    @Previewable @State var model = AppModel.preview()
    NavigationStack {
        MeetingListView(meetings: [], selection: $selection)
    }
    .environment(model)
    .frame(width: 360, height: 520)
}
#endif
