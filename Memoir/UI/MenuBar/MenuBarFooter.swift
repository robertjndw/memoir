import AppKit
import SwiftUI

struct MenuBarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 14)
            VStack(spacing: 0) {
                FooterRow(title: "Open Library", symbol: "books.vertical", shortcut: "L") {
                    model.openLibrary()
                }
                .keyboardShortcut("l", modifiers: .command)
                FooterRow(title: "Settings...", symbol: "gearshape", shortcut: ",") {
                    // Agent apps do not come forward on their own, so the window would open behind.
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                FooterRow(title: "Quit Memoir", symbol: "power", shortcut: "Q") {
                    // Quitting mid-recording would drop the audio mix and transcript tail, so finalize first.
                    Task {
                        await model.stopRecording()
                        NSApp.terminate(nil)
                    }
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(6)
        }
    }
}

private struct FooterRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                Spacer()
                Text("\u{2318}\(shortcut)")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(MenuRowStyle())
        .padding(.horizontal, 8)
    }
}

#if DEBUG
#Preview {
    @Previewable @State var model = AppModel.preview()
    MenuBarFooter()
        .environment(model)
        .frame(width: 320)
}
#endif
