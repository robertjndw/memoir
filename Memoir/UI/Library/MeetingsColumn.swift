import SwiftData
import SwiftUI

/// How the Meetings content column presents the library.
enum MeetingsLayout: String, CaseIterable, Identifiable {
    case list
    case calendar

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .list: "List"
        case .calendar: "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .calendar: "calendar"
        }
    }
}

/// Content column for the Meetings section: the same meetings as a grouped list or a month calendar.
struct MeetingsColumn: View {
    let meetings: [Meeting]
    @Binding var layout: MeetingsLayout
    @Binding var selection: UUID?
    @Binding var searchText: String
    @Binding var selectedDay: Date

    var body: some View {
        // Both layouts stay inside one container so the search field and toolbar don't
        // reappear on every switch, and the crossfade has a stable parent to run in.
        ZStack {
            switch layout {
            case .list:
                MeetingListView(meetings: meetings, selection: $selection, searchText: searchText)
                    .transition(.opacity)
            case .calendar:
                CalendarPane(meetings: meetings, selection: $selection, selectedDay: $selectedDay, searchText: searchText)
                    .transition(.opacity)
            }
        }
        .searchable(text: $searchText, prompt: "Search Meetings")
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem {
                // A crossfade involves no movement, so it stays on with Reduce Motion.
                Picker("View As", selection: $layout.animation(.easeInOut(duration: 0.18))) {
                    ForEach(MeetingsLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbol)
                            .labelStyle(.iconOnly)
                            .tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .help("Show meetings as a list or a calendar")
            }
        }
    }
}

#if DEBUG
#Preview("List") {
    @Previewable @State var layout = MeetingsLayout.list
    @Previewable @State var selection: UUID?
    @Previewable @State var search = ""
    @Previewable @State var day = Calendar.current.startOfDay(for: .now)
    @Previewable @State var model = AppModel.preview(samples: true)
    QueriedMeetings { meetings in
        NavigationStack {
            MeetingsColumn(meetings: meetings, layout: $layout, selection: $selection, searchText: $search, selectedDay: $day)
        }
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 380, height: 620)
}

#Preview("Calendar") {
    @Previewable @State var layout = MeetingsLayout.calendar
    @Previewable @State var selection: UUID?
    @Previewable @State var search = ""
    @Previewable @State var day = Calendar.current.startOfDay(for: .now.addingTimeInterval(-3 * 3600))
    @Previewable @State var model = AppModel.preview(samples: true)
    QueriedMeetings { meetings in
        NavigationStack {
            MeetingsColumn(meetings: meetings, layout: $layout, selection: $selection, searchText: $search, selectedDay: $day)
        }
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 380, height: 620)
}

#Preview("Calendar, searching") {
    @Previewable @State var layout = MeetingsLayout.calendar
    @Previewable @State var selection: UUID?
    @Previewable @State var search = "roadmap"
    @Previewable @State var day = Calendar.current.startOfDay(for: .now)
    @Previewable @State var model = AppModel.preview(samples: true)
    QueriedMeetings { meetings in
        NavigationStack {
            MeetingsColumn(meetings: meetings, layout: $layout, selection: $selection, searchText: $search, selectedDay: $day)
        }
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 380, height: 620)
}
#endif
