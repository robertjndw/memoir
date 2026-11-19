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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAvailable: Bool { availability == .available }

    private var messages: [ChatDisplayMessage] {
        controller.messages.map { ChatDisplayMessage(id: $0.id, role: $0.role, text: $0.text) }
    }

    private var hasConversation: Bool {
        !controller.messages.isEmpty || controller.streamingText != nil
    }

    private var canReset: Bool {
        !controller.messages.isEmpty || controller.isResponding
    }

    /// In a meeting the toolbar belongs to the meeting (export, delete, ...), so a conversation
    /// action there would read as one of those. Ask Memoir is its own window content, so its
    /// reset lives in the toolbar like a compose button.
    private var resetsFromToolbar: Bool { controller.scope == .library }

    var body: some View {
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
                        .transition(.opacity)
                }
                if !isAvailable && hasConversation {
                    IntelligenceUnavailableView(availability: availability, compact: true)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if !resetsFromToolbar && canReset {
                        newConversationButton
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .controlSize(.large)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
                    }
                    ChatComposer(
                        text: $draft,
                        isResponding: controller.isResponding,
                        isEnabled: isAvailable,
                        send: submit,
                        stop: controller.stop
                    )
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.2), value: canReset)
            .animation(.smooth(duration: 0.2), value: controller.errorMessage)
        }
        .toolbar {
            if resetsFromToolbar {
                ToolbarItem(placement: .primaryAction) {
                    newConversationButton
                        .disabled(!canReset)
                }
            }
        }
        .contextMenu {
            Button("New Conversation", action: controller.clear)
                .disabled(!canReset)
        }
    }

    private var newConversationButton: some View {
        Button("New Conversation", systemImage: "square.and.pencil", action: controller.clear)
            .keyboardShortcut("k", modifiers: .command)
            .help("Start a new conversation. The current one is cleared.")
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

#if DEBUG
#Preview("Ask Memoir") {
    @Previewable @State var model = AppModel.preview(samples: true)
    ChatView(scope: .library, onSeek: nil)
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 640, height: 520)
}

#Preview("Meeting chat") {
    @Previewable @State var model = AppModel.preview(samples: true) { model in
        let meeting = model.previewMeeting("Design Review")
        model.context.insert(ChatMessage(role: .user, text: "When do we launch?", meeting: meeting))
        model.context.insert(ChatMessage(
            role: .assistant,
            text: "On **the first Monday of next month** [0:31]. Maya updates the prototype before then [0:16].",
            date: .now.addingTimeInterval(1),
            meeting: meeting
        ))
    }
    ChatView(scope: .meeting(model.previewMeeting("Design Review").id), onSeek: { _ in })
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 640, height: 520)
}

#Preview("Ask Memoir, conversation") {
    @Previewable @State var model = AppModel.preview(samples: true) { model in
        model.context.insert(ChatMessage(role: .user, text: "What are my open action items?"))
        model.context.insert(ChatMessage(
            role: .assistant,
            text: "Update the prototype before launch, and send the onboarding numbers to Jonas.",
            date: .now.addingTimeInterval(1)
        ))
    }
    NavigationStack {
        ChatView(scope: .library, onSeek: nil)
            .navigationTitle("Ask Memoir")
    }
    .environment(model)
    .modelContainer(model.container)
    .frame(width: 640, height: 520)
}

#Preview("Unavailable") {
    @Previewable @State var model = AppModel.preview(services: .inert)
    ChatView(scope: .library, onSeek: nil)
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 640, height: 520)
}
#endif
