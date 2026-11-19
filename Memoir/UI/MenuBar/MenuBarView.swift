import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if let message = model.errorMessage {
                    MenuErrorBanner(message: message) { model.errorMessage = nil }
                }
                if !model.settings.hasCompletedOnboarding {
                    FinishSetupRow { openWindow(id: AppModel.WindowID.onboarding) }
                }
                content
            }
            .padding(16)

            Divider()
            MenuBarFooter()
        }
        .frame(width: 340)
        .onAppear { model.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch model.recordingState {
        case .idle:
            IdleView()
        case .starting:
            StatusRow(title: "Starting...")
        case .recording:
            RecordingView()
        case .finishing:
            StatusRow(title: "Saving recording...")
        }
    }
}

struct StatusRow: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .accessibilityElement(children: .combine)
    }
}

struct MenuErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss error")
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

struct FinishSetupRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(.tint)
                Text("Finish Setup")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
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
