import AppKit
import SwiftUI

struct MenuBarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 4) {
            Button("Open Library") { model.openLibrary() }
                .accessibilityLabel("Open Library")
            Spacer()
            Button {
                // Agent apps do not come forward on their own, so the window would open behind.
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
            .accessibilityLabel("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit Memoir")
            .accessibilityLabel("Quit Memoir")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
