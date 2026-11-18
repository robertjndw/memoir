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
