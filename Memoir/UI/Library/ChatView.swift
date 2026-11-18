import SwiftData
import SwiftUI

struct ChatView: View {
    let scope: ChatScope
    /// Called when the user clicks a `[mm:ss]` citation. Nil where there is nothing to seek.
    var onSeek: ((TimeInterval) -> Void)?

    @Environment(AppModel.self) private var model

    var body: some View {
        // The scope is part of the identity so draft text and scroll state never leak between meetings.
        ChatPane(
            controller: model.chat(for: scope),
            availability: model.intelligenceAvailability,
            onSeek: scope == .library ? nil : onSeek
        )
        .id(scope)
        .onAppear { model.refresh() }
    }
}

private struct ChatPane: View {
    let controller: ChatController
    let availability: IntelligenceAvailability
    let onSeek: ((TimeInterval) -> Void)?

    @State private var draft = ""

    private var isAvailable: Bool { availability == .available }

    private var messages: [ChatDisplayMessage] {
        controller.messages.map { ChatDisplayMessage(id: $0.id, role: $0.role, text: $0.text) }
    }

    var body: some View {
        let hasConversation = !controller.messages.isEmpty || controller.streamingText != nil
        Group {
            if hasConversation {
                ChatMessageList(
                    messages: messages,
                    streamingText: controller.streamingText,
                    onSeek: onSeek
                )
            } else if isAvailable {
                ChatEmptyState(scope: controller.scope, isEnabled: true, ask: controller.send)
            } else {
                IntelligenceUnavailableView(availability: availability)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if let message = controller.errorMessage {
                    ErrorRow(message: message) { controller.errorMessage = nil }
                }
                if !isAvailable && hasConversation {
                    IntelligenceUnavailableView(availability: availability, compact: true)
                }
                ChatComposer(
                    text: $draft,
                    isResponding: controller.isResponding,
                    isEnabled: isAvailable,
                    send: submit,
                    stop: controller.stop
                )
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button("Clear Conversation", systemImage: "trash", action: controller.clear)
                    .disabled(controller.messages.isEmpty && !controller.isResponding)
                    .help("Clear Conversation")
            }
        }
        .contextMenu {
            Button("Clear Conversation", action: controller.clear)
                .disabled(controller.messages.isEmpty && !controller.isResponding)
        }
    }

    private func submit() {
        let text = draft
        draft = ""
        controller.send(text)
    }
}

private struct ErrorRow: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message).font(.callout)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

#Preview("Meeting chat") {
    let model = AppModel.preview()
    return ChatView(scope: .library, onSeek: nil)
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 640, height: 520)
}
