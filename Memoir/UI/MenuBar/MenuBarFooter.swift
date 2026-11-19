import AppKit
import SwiftUI

/// Plain text rows like the system status menus. The shortcuts work but aren't displayed.
struct MenuBarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 14)
            VStack(spacing: 0) {
                Button("Memoir Settings...") {
                    // Agent apps do not come forward on their own, so the window would open behind.
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("Quit Memoir") {
                    // Quitting mid-recording would drop the audio mix and transcript tail, so finalize first.
                    Task {
                        await model.stopRecording()
                        NSApp.terminate(nil)
                    }
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(MenuRowStyle())
            // Same inset as the content above so the text lines up.
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
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
