import SwiftUI

/// Explains why Apple Intelligence cannot be used right now. Shared by the summary and the chat.
struct IntelligenceUnavailableView: View {
    let availability: IntelligenceAvailability
    /// A single row for tucking above the composer, instead of a full-pane placeholder.
    var compact = false

    @Environment(\.openURL) private var openURL

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")

    private var title: LocalizedStringKey {
        switch availability {
        case .available: "Apple Intelligence is available"
        case .deviceNotEligible: "Apple Intelligence is not supported"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is turned off"
        case .modelNotReady: "Apple Intelligence is getting ready"
        }
    }

    private var detail: LocalizedStringKey {
        switch availability {
        case .available: ""
        case .deviceNotEligible: "This Mac does not support Apple Intelligence, which Memoir uses to summarize and answer questions on your Mac."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to summarize meetings and ask questions."
        case .modelNotReady: "The on-device model is still downloading. Try again shortly."
        }
    }

    private var symbol: String {
        availability == .modelNotReady ? "arrow.down.circle" : "sparkles"
    }

    private var opensSettings: Bool { availability == .appleIntelligenceNotEnabled }

    var body: some View {
        if compact {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if opensSettings { settingsButton }
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .contain)
        } else {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text(detail)
            } actions: {
                if opensSettings { settingsButton }
            }
        }
    }

    private var settingsButton: some View {
        Button("Open System Settings") {
            if let url = Self.settingsURL { openURL(url) }
        }
    }
}

#Preview("Off") {
    IntelligenceUnavailableView(availability: .appleIntelligenceNotEnabled)
        .frame(width: 480, height: 320)
}

#Preview("Compact") {
    IntelligenceUnavailableView(availability: .modelNotReady, compact: true)
        .padding()
        .frame(width: 480)
}
