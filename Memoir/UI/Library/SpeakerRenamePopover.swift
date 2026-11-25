import SwiftData
import SwiftUI

/// Names one identified voice for the whole meeting. Return keeps the name, Escape or clicking
/// elsewhere leaves it as it was, like renaming in Finder.
struct SpeakerRenamePopover: View {
    let meeting: Meeting
    let voice: Int

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var selection: TextSelection?
    @FocusState private var isFieldFocused: Bool
    private let original: String

    init(meeting: Meeting, voice: Int) {
        self.meeting = meeting
        self.voice = voice
        let name = meeting.speakerNames[voice] ?? ""
        original = name
        _draft = State(initialValue: name)
        // Selected so typing replaces the old name right away.
        _selection = State(initialValue: TextSelection(range: name.startIndex..<name.endIndex))
    }

    /// New speakers are about to be numbered, which would put this name on someone else.
    private var isIdentifying: Bool { model.enhancing[meeting.id] != nil }

    var body: some View {
        let suggestions = SpeakerNameSuggestions.suggestions(
            attendees: meeting.attendees,
            speakerNames: meeting.speakerNames,
            query: draft == original ? "" : draft
        )
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $draft, selection: $selection, prompt: Text("Speaker \(voice)"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($isFieldFocused)
                .onSubmit { commit(draft) }
                .onExitCommand { dismiss() }
                .accessibilityLabel("Name for Speaker \(voice)")
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attendees")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(suggestions, id: \.self) { name in
                        SuggestionButton(name: name) { commit(name) }
                    }
                }
            }
            if isIdentifying {
                Text("Speakers are being identified. You can name them when that's done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isIdentifying)
        .frame(width: 240)
        .padding(12)
        .onAppear { isFieldFocused = true }
    }

    private func commit(_ name: String) {
        guard !isIdentifying else { return }
        model.renameSpeaker(voice, to: name, in: meeting)
        dismiss()
    }
}

/// An attendee to pick with one click. Highlights on hover like a menu item, since that is
/// what the list behaves like.
private struct SuggestionButton: View {
    let name: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(name)
                    .lineLimit(1)
            } icon: {
                PersonAvatar(name: name, size: 18)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(name)
        .accessibilityHint("Uses this name for the speaker")
    }
}

#if DEBUG
#Preview("Rename speaker") {
    @Previewable @State var model = AppModel.preview(samples: true)
    SpeakerRenamePopover(meeting: model.previewMeeting("Planning Sync"), voice: 2)
        .environment(model)
        .modelContainer(model.container)
}

#Preview("Rename named speaker") {
    @Previewable @State var model = AppModel.preview(samples: true)
    SpeakerRenamePopover(meeting: model.previewMeeting("Planning Sync"), voice: 1)
        .environment(model)
        .modelContainer(model.container)
}
#endif
