import SwiftData
import SwiftUI

/// Calendar layout of the Meetings column: month grid on top, the selected day's meetings below.
struct CalendarPane: View {
    let meetings: [Meeting]
    @Binding var selection: UUID?
    @Binding var selectedDay: Date
    /// Narrows both the grid markers and the day list, so the grid shows which days have matches.
    var searchText: String = ""

    @Environment(\.calendar) private var calendar
    @Environment(\.meetingCommands) private var commands

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let matching = isSearching ? meetings.filter { MeetingGrouping.matches($0, query: searchText) } : meetings
        let dayMeetings = matching
            .filter { calendar.isDate($0.startDate, inSameDayAs: selectedDay) }
            .sorted { $0.startDate > $1.startDate }
        VStack(spacing: 0) {
            CalendarGridView(meetings: matching, selectedDay: $selectedDay)
            Divider()
            List(selection: $selection) {
                if !dayMeetings.isEmpty {
                    Section(MeetingGrouping.title(for: selectedDay, calendar: calendar)) {
                        ForEach(dayMeetings) { meeting in
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
                if dayMeetings.isEmpty {
                    emptyDay
                }
            }
        }
    }

    @ViewBuilder private var emptyDay: some View {
        if isSearching {
            ContentUnavailableView(
                "No Results on This Day",
                systemImage: "magnifyingglass",
                description: Text("Days with meetings matching \u{201C}\(searchText)\u{201D} are marked in the calendar.")
            )
        } else {
            ContentUnavailableView("No Recordings", systemImage: "calendar", description: Text("Nothing was recorded on this day."))
        }
    }
}

#if DEBUG
#Preview("Calendar") {
    @Previewable @State var selection: UUID?
    @Previewable @State var day = Calendar.current.startOfDay(for: .now.addingTimeInterval(-3 * 3600))
    @Previewable @State var model = AppModel.preview(samples: true)
    QueriedMeetings { meetings in
        NavigationStack {
            CalendarPane(meetings: meetings, selection: $selection, selectedDay: $day)
        }
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 360, height: 620)
}

#Preview("Searching") {
    @Previewable @State var selection: UUID?
    @Previewable @State var day = Calendar.current.startOfDay(for: .now.addingTimeInterval(-10 * 86400))
    @Previewable @State var model = AppModel.preview(samples: true)
    QueriedMeetings { meetings in
        NavigationStack {
            CalendarPane(meetings: meetings, selection: $selection, selectedDay: $day, searchText: "launch")
        }
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 360, height: 620)
}

#Preview("Empty day") {
    @Previewable @State var selection: UUID?
    @Previewable @State var day = Calendar.current.startOfDay(for: .now.addingTimeInterval(-10 * 86400))
    @Previewable @State var model = AppModel.preview(samples: true)
    QueriedMeetings { meetings in
        NavigationStack {
            CalendarPane(meetings: meetings, selection: $selection, selectedDay: $day)
        }
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 360, height: 620)
}
#endif
