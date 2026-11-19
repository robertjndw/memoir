import AppKit
import SwiftUI

struct ChatDisplayMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatTurn.Role
    let text: String
}

/// The scrolling conversation as plain values.
struct ChatMessageList: View {
    let messages: [ChatDisplayMessage]
    /// Nil when no answer is being generated.
    let streamingText: String?
    var onSeek: ((TimeInterval) -> Void)?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(messages) { message in
                    ChatMessageRow(role: message.role, text: message.text, onSeek: onSeek)
                }
                if let streamingText {
                    if streamingText.isEmpty {
                        ThinkingIndicator()
                    } else {
                        ChatMessageRow(role: .assistant, text: streamingText, onSeek: onSeek)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                contentHeight: geometry.contentSize.height,
                distanceFromBottom: geometry.contentSize.height
                    - geometry.contentOffset.y - geometry.containerSize.height
            )
        } action: { old, new in
            // Growth while pinned keeps following the content. Any other change is the user moving.
            if new.contentHeight > old.contentHeight, isAtBottom {
                position.scrollTo(edge: .bottom)
            } else {
                isAtBottom = new.distanceFromBottom < 24
            }
        }
    }
}

private struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var distanceFromBottom: CGFloat
}

private struct ChatMessageRow: View {
    let role: ChatTurn.Role
    let text: String
    let onSeek: ((TimeInterval) -> Void)?

    var body: some View {
        let attributed = ChatTextFormatter.attributed(text, linkCitations: onSeek != nil)
        Group {
            switch role {
            case .user:
                HStack(spacing: 0) {
                    Spacer(minLength: 64)
                    Text(attributed)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 16))
                }
            case .assistant:
                HStack(spacing: 0) {
                    Text(attributed)
                        .lineSpacing(3)
                    Spacer(minLength: 32)
                }
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let seconds = ChatTextFormatter.seconds(from: url), let onSeek else { return .systemAction }
            onSeek(seconds)
            return .handled
        })
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(role == .user ? "You" : "Memoir")
        .accessibilityValue(text)
    }
}

private struct ThinkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking...").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension ChatDisplayMessage {
    static let samples: [ChatDisplayMessage] = [
        .init(id: UUID(), role: .user, text: "What were the key decisions?"),
        .init(id: UUID(), role: .assistant, text: "Two decisions came out of this meeting:\n- **Onboarding ships in September** [12:34]\n- Analytics is deferred to Q4 [1:02:03]"),
    ]
}

#Preview("Conversation") {
    ChatMessageList(messages: ChatDisplayMessage.samples, streamingText: nil, onSeek: { _ in })
        .frame(width: 600, height: 400)
}

#Preview("Streaming") {
    ChatMessageList(messages: ChatDisplayMessage.samples, streamingText: "Let me check **the notes** [3:10]", onSeek: nil)
        .frame(width: 600, height: 400)
}
