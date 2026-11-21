import SwiftUI

/// Actions that need window-level UI (confirmation, save panel), supplied by `LibraryView`.
struct MeetingCommands {
    var rename: (Meeting) -> Void = { _ in }
    var export: (Meeting) -> Void = { _ in }
    var reveal: (Meeting) -> Void = { _ in }
    var delete: (Meeting) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var meetingCommands = MeetingCommands()
}
