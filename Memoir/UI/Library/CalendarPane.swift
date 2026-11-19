import SwiftData
import SwiftUI

/// Content column for the Calendar section: month grid on top, the selected day's meetings below.
struct CalendarPane: View {
    let meetings: [Meeting]
    @Binding var selection: UUID?
    @Binding var selectedDay: Date

    @Environment(\.calendar) private var calendar

    var body: some View {
        let dayMeetings = meetings
            .filter { calendar.isDate($0.startDate, inSameDayAs: selectedDay) }
            .sorted { $0.startDate > $1.startDate }
        VStack(spacing: 0) {
            CalendarGridView(meetings: meetings, selectedDay: $selectedDay)
            Divider()
            List(selection: $selection) {
                ForEach(dayMeetings) { meeting in
                    MeetingRow(meeting: meeting)
                        .tag(meeting.id)
                        .meetingActions(for: meeting)
                }
            }
            .overlay {
                if dayMeetings.isEmpty {
                    ContentUnavailableView("No Recordings", systemImage: "calendar", description: Text("Nothing was recorded on this day."))
                }
            }
        }
        .navigationTitle("Calendar")
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
