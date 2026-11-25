import SwiftData
import SwiftUI

struct MeetingRow: View {
    let meeting: Meeting
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRecording: Bool { model.recordingMeetingID == meeting.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MeetingIcon(bundleID: meeting.sourceAppBundleID, size: 30)
                .overlay(alignment: .bottomTrailing) {
                    if isRecording {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 12))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                            .background(.background, in: .circle)
                            .offset(x: 3, y: 3)
                            .accessibilityLabel("Recording")
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.smooth(duration: 0.25), value: isRecording)
            text
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(1)
            Text(details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let overview = meeting.summary?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var details: String {
        var parts = [meeting.startDate.formatted(date: .omitted, time: .shortened)]
        if isRecording {
            parts.append(String(localized: "Recording"))
        } else if meeting.duration > 0 {
            parts.append(LibraryFormat.length(meeting.duration))
        }
        if let app = meeting.sourceAppName, !app.isEmpty {
            parts.append(app)
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct MeetingActionsModifier: ViewModifier {
    let meeting: Meeting
    @Environment(\.meetingCommands) private var commands
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let canDelete = model.activeMeetingID != meeting.id
        content
            .contextMenu {
                Button("Rename…") { commands.rename(meeting) }
                Button("Reveal in Finder") { commands.reveal(meeting) }
                Button("Export…") { commands.export(meeting) }
                Divider()
                Button("Delete…", role: .destructive) { commands.delete(meeting) }
                    .disabled(!canDelete)
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { commands.delete(meeting) }
                    .disabled(!canDelete)
            }
            .swipeActions(edge: .leading) {
                Button("Rename", systemImage: "pencil") { commands.rename(meeting) }
                    .tint(.accentColor)
            }
    }
}

extension View {
    func meetingActions(for meeting: Meeting) -> some View {
        modifier(MeetingActionsModifier(meeting: meeting))
    }
}

#if DEBUG
// VStack because a plain List of these rows crashes the canvas. The list, calendar and
// library previews show them in a real List.
#Preview("Rows") {
    @Previewable @State var model = AppModel.preview(samples: true) {
        let live = Meeting(title: "Weekly Sync", startDate: .now.addingTimeInterval(-600))
        live.sourceAppName = "FaceTime"
        live.sourceAppBundleID = "com.apple.FaceTime"
        $0.simulateRecording(live)
    }
    QueriedMeetings { meetings in
        VStack(alignment: .leading, spacing: 12) {
            ForEach(meetings) { MeetingRow(meeting: $0) }
        }
        .padding()
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 340, alignment: .leading)
}
#endif
