import SwiftUI

/// The meeting in the key window, published by `MeetingDetailView` for the menu commands.
struct FocusedMeeting {
    let meeting: Meeting
    let isRecording: Bool
    let commands: MeetingCommands
    let tab: Binding<MeetingDetailView.Tab>
    /// Focuses the title field. Titles are edited inline, not in a sheet.
    let rename: () -> Void
}

extension FocusedValues {
    @Entry var focusedMeeting: FocusedMeeting?
}

/// Meeting and View menu commands. The shortcuts live here so they work regardless of what
/// the toolbar shows.
struct MeetingMenuCommands: Commands {
    @FocusedValue(\.focusedMeeting) private var focused

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(MeetingDetailView.Tab.allCases) { tab in
                Button(LocalizedStringKey(tab.rawValue)) { focused?.tab.wrappedValue = tab }
                    .keyboardShortcut(tab.shortcut, modifiers: .command)
                    .disabled(focused == nil)
            }
            Divider()
        }

        CommandMenu("Meeting") {
            Button("Rename") { focused?.rename() }
                .disabled(focused == nil)
            Button("Export as Markdown...") {
                if let focused { focused.commands.export(focused.meeting) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(focused == nil)
            Button("Reveal in Finder") {
                if let focused { focused.commands.reveal(focused.meeting) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(focused == nil)
            Divider()
            // No shortcut: Command-Delete has to keep deleting to the start of the line in text fields.
            // The Delete key works in the list.
            Button("Delete Meeting...") {
                if let focused { focused.commands.delete(focused.meeting) }
            }
            .disabled(focused == nil || focused?.isRecording == true)
        }
    }
}
