import SwiftUI

struct ChatComposer: View {
    @Binding var text: String
    let isResponding: Bool
    let isEnabled: Bool
    let send: () -> Void
    let stop: () -> Void

    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    private var canSend: Bool {
        isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a question", text: $text, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .disabled(!isEnabled)
                .padding(.vertical, 6)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        insertNewline()
                        return .handled
                    }
                    if canSend && !isResponding { send() }
                    return .handled
                }

            if isResponding {
                Button(action: stop) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .buttonStyle(.plain)
                .help("Stop")
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .help("Send")
                .accessibilityLabel("Send")
                .padding(.bottom, 4)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: isResponding)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .intelligenceGlow(isActive: isResponding, cornerRadius: 20)
        .onAppear { focused = true }
    }

    /// Shift-Return breaks the line where the cursor is, replacing any selected text.
    private func insertNewline() {
        guard case .selection(let range) = selection?.indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex
        else {
            text += "\n"
            return
        }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        text.replaceSubrange(range, with: "\n")
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: offset + 1))
    }
}

#Preview {
    @Previewable @State var text = ""
    ChatComposer(text: $text, isResponding: false, isEnabled: true, send: {}, stop: {})
        .padding()
        .frame(width: 520)
}

#Preview("Responding") {
    @Previewable @State var text = ""
    ChatComposer(text: $text, isResponding: true, isEnabled: true, send: {}, stop: {})
        .padding()
        .frame(width: 520)
}
