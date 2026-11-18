import SwiftUI

struct MeetingListView: View {
    let meetings: [Meeting]
    @Binding var selection: UUID?
    @Binding var searchText: String

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
        .searchable(text: $searchText, prompt: "Search Meetings")
        .navigationTitle("Meetings")
    }
}
