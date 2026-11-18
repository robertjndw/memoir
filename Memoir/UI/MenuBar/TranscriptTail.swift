import SwiftUI

/// The last few transcript lines plus in-progress text, pinned to the newest.
struct TranscriptTail: View {
    let lines: [TranscriptLine]
    let volatile: [Speaker: String]

    private static let visibleLines = 4
    private var tail: ArraySlice<TranscriptLine> { lines.suffix(Self.visibleLines) }
    private var pending: [(Speaker, String)] {
        volatile.filter { !$0.value.isEmpty }.sorted { $0.key.rawValue < $1.key.rawValue }.map { ($0.key, $0.value) }
    }

    var body: some View {
        Group {
            if tail.isEmpty && pending.isEmpty {
                Text("Listening...")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(tail) { line in
                                entry(speaker: line.speaker, text: line.text, secondary: false)
                            }
                            ForEach(pending, id: \.0) { speaker, text in
                                entry(speaker: speaker, text: text, secondary: true)
                            }
                            Color.clear.frame(height: 0).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: lines.count) { scrollToEnd(proxy) }
                    .onChange(of: volatile) { scrollToEnd(proxy) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .font(.callout)
        .frame(height: 96)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live transcript")
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
    }

    private func entry(speaker: Speaker, text: String, secondary: Bool) -> some View {
        let label = Text(speaker.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        let body = Text(text).foregroundStyle(secondary ? .secondary : .primary)
        return Text("\(label)  \(body)")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Text") {
    TranscriptTail(
        lines: [
            TranscriptLine(speaker: .me, start: 0, end: 3, text: "Let's start with the roadmap."),
            TranscriptLine(speaker: .others, start: 3, end: 6, text: "Sounds good, I have two items."),
        ],
        volatile: [.me: "Great, so the first one is"]
    )
    .padding().frame(width: 340)
}

#Preview("Empty") {
    TranscriptTail(lines: [], volatile: [:]).padding().frame(width: 340)
}
