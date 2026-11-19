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

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(IntelligencePalette.linear)
                .symbolEffect(.bounce, value: appeared)
                .accessibilityHidden(true)
            Text(headline).font(.title3.weight(.semibold))
            VStack(spacing: 8) {
                ForEach(Array(Self.suggestions(for: scope).enumerated()), id: \.element) { index, suggestion in
                    Button(suggestion) { ask(suggestion) }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .disabled(!isEnabled)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 10)
                        .blur(radius: appeared || reduceMotion ? 0 : 4)
                        .animation(.smooth(duration: 0.45).delay(0.08 * Double(index + 1)), value: appeared)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appeared = true }
    }
}

#Preview {
    ChatEmptyState(scope: .library, isEnabled: true, ask: { _ in })
        .frame(width: 520, height: 420)
}
