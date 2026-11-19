import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let message = model.errorMessage {
                    MenuErrorBanner(message: message) { model.errorMessage = nil }
                        .transition(.blurReplace)
                }
                if !model.settings.hasCompletedOnboarding {
                    FinishSetupRow { openWindow(id: AppModel.WindowID.onboarding) }
                        .transition(.blurReplace)
                }
                content
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            MenuBarFooter()
        }
        .frame(width: 320)
        .animation(.smooth(duration: 0.3), value: model.recordingState)
        .animation(.smooth(duration: 0.3), value: model.errorMessage)
        .onAppear { model.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch model.recordingState {
        case .idle:
            IdleView().transition(.blurReplace)
        case .starting:
            StatusRow(title: "Starting...").transition(.blurReplace)
        case .recording:
            RecordingView().transition(.blurReplace)
        case .finishing:
            StatusRow(title: "Saving recording...").transition(.blurReplace)
        }
    }
}

/// Small secondary heading, as in the Control Center and Wi-Fi menus.
struct MenuSectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Row chrome shared by every clickable line: a rounded hover highlight like native menu items.
struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
            }
            .contentShape(.rect(cornerRadius: 8))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

struct StatusRow: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

struct MenuErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
    }
}

struct FinishSetupRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text("Finish Setup")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityLabel("Finish Setup")
        .accessibilityHint("Opens the setup window")
    }
}

#if DEBUG
#Preview("Idle") {
    @Previewable @State var model = AppModel.preview()
    MenuBarView()
        .environment(model)
        .modelContainer(model.container)
}

#Preview("Recording") {
    @Previewable @State var model = AppModel.preview(hasCompletedOnboarding: true) {
        $0.simulateRecording(
            Meeting(title: "Design Review"),
            lines: Meeting.sampleLines,
            volatile: [.others: "Works for me, I'll tell"]
        )
    }
    MenuBarView()
        .environment(model)
        .modelContainer(model.container)
}

#Preview("Starting") {
    @Previewable @State var model = AppModel.preview(hasCompletedOnboarding: true) { $0.simulate(.starting) }
    MenuBarView()
        .environment(model)
        .modelContainer(model.container)
}

#Preview("Saving") {
    @Previewable @State var model = AppModel.preview(hasCompletedOnboarding: true) { $0.simulate(.finishing) }
    MenuBarView()
        .environment(model)
        .modelContainer(model.container)
}

#Preview("Error") {
    @Previewable @State var model = AppModel.preview(hasCompletedOnboarding: true) {
        $0.errorMessage = "Live transcription is unavailable: the speech model for English is not installed."
    }
    MenuBarView()
        .environment(model)
        .modelContainer(model.container)
}
#endif
