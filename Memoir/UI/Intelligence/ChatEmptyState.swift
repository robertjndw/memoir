import SwiftUI

struct ChatEmptyState: View {
    let scope: ChatScope
    let isEnabled: Bool
    let ask: (String) -> Void

    static func suggestions(for scope: ChatScope) -> [String] {
        switch scope {
        case .meeting:
            ["What were the key decisions?", "List the action items", "What did I commit to?", "Give me a short recap"]
        case .library:
            ["What are my open action items?", "Summarize this week's meetings", "What did we decide recently?", "Which meetings mentioned deadlines?"]
        }
    }

    private var headline: LocalizedStringKey {
        switch scope {
        case .meeting: "Ask about this meeting"
        case .library: "Ask about your meetings"
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(headline).font(.title3.weight(.semibold))
            VStack(spacing: 8) {
                ForEach(Self.suggestions(for: scope), id: \.self) { suggestion in
                    Button(suggestion) { ask(suggestion) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(!isEnabled)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ChatEmptyState(scope: .library, isEnabled: true, ask: { _ in })
        .frame(width: 520, height: 420)
}
