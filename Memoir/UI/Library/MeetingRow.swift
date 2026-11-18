import SwiftUI

struct MeetingRow: View {
    let meeting: Meeting
    @Environment(AppModel.self) private var model

    private var isRecording: Bool { model.recordingMeetingID == meeting.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isRecording {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                        .accessibilityLabel("Recording")
                }
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
            }
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
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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
        let canDelete = model.recordingMeetingID != meeting.id
        content
            .contextMenu {
                Button("Rename...") { commands.rename(meeting) }
                Button("Reveal in Finder") { commands.reveal(meeting) }
                Button("Export...") { commands.export(meeting) }
                Divider()
                Button("Delete...", role: .destructive) { commands.delete(meeting) }
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
