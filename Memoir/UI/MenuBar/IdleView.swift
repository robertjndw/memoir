import SwiftData
import SwiftUI

struct IdleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Record", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Start recording")

            if let upcoming = model.upcomingMeeting {
                UpcomingRow(title: upcoming.title, start: upcoming.start)
            }

            RecentMeetings()
        }
    }
}

struct UpcomingRow: View {
    let title: String
    let start: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            TimelineView(.everyMinute) { context in
                Text(Self.relative(start, now: context.date))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    static func relative(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "in \(hours) hr" : "in \(hours) hr \(rest) min"
    }
}

struct RecentMeetings: View {
    @Environment(AppModel.self) private var model
    @Query private var meetings: [Meeting]

    init() {
        var descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 4
        _meetings = Query(descriptor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            if meetings.isEmpty {
                Text("Your recordings will appear here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(meetings) { meeting in
                        RecentRow(title: meeting.title, date: meeting.startDate, duration: meeting.duration) {
                            model.openLibrary(selecting: meeting.id)
                        }
                    }
                }
            }
        }
    }
}

struct RecentRow: View {
    let title: String
    let date: Date
    let duration: TimeInterval
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinute : .minuteSecond)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title), \(date.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityHint("Opens in Library")
    }
}

#if DEBUG
#Preview("Idle with meetings") {
    @Previewable @State var model = AppModel.preview(hasCompletedOnboarding: true, samples: true)
    MenuBarView()
        .environment(model)
        .modelContainer(model.container)
}
#endif

#Preview("Rows") {
    VStack(alignment: .leading, spacing: 10) {
        UpcomingRow(title: "Weekly Design Review", start: .now.addingTimeInterval(25 * 60))
        UpcomingRow(title: "Quarterly Planning", start: .now.addingTimeInterval(2 * 3600 + 30 * 60))
        Divider()
        RecentRow(title: "Design Review", date: .now.addingTimeInterval(-3 * 3600), duration: 42 * 60) {}
        RecentRow(title: "All Hands", date: .now.addingTimeInterval(-86400), duration: 75 * 60) {}
    }
    .padding()
    .frame(width: 340)
}
