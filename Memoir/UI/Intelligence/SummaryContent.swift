import SwiftUI

/// The summary sections as plain values, so it previews and streams without a live model.
struct SummaryContent: View {
    let summary: MeetingSummary
    /// Task texts of completed action items.
    var completed: Set<String> = []
    /// Nil while the summary is streaming, since items can still change.
    var onToggle: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !summary.overview.isEmpty {
                OverviewCard(text: summary.overview)
                    .transition(.blurReplace)
            }
            if !summary.keyPoints.isEmpty {
                section("Key Points", symbol: "list.bullet.circle.fill", color: .blue) {
                    ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, point in
                        row(marker: "circle.fill") { Text(point) }
                    }
                }
            }
            if !summary.decisions.isEmpty {
                section("Decisions", symbol: "checkmark.seal.fill", color: .green) {
                    ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                        row(marker: "arrow.turn.down.right") { Text(decision) }
                    }
                }
            }
            if !summary.actionItems.isEmpty {
                section("Action Items", symbol: "checklist", color: .orange) {
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                        ActionItemRow(
                            item: item,
                            isDone: completed.contains(item.task),
                            toggle: onToggle.map { toggle in { toggle(item.task) } }
                        )
                        .transition(.blurReplace)
                    }
                }
            }
        }
        .textSelection(.enabled)
        // Only structural growth animates, so streamed text does not re-animate per update.
        .animation(.smooth(duration: 0.3), value: structure)
    }

    private var structure: [Int] {
        [summary.overview.isEmpty ? 0 : 1, summary.keyPoints.count, summary.decisions.count, summary.actionItems.count]
    }

    private func section(
        _ title: LocalizedStringKey,
        symbol: String,
        color: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(title)
            }
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .transition(.blurReplace)
    }

    private func row(marker: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: marker)
                .font(.system(size: marker == "circle.fill" ? 6 : 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            content()
        }
        .transition(.blurReplace)
        .accessibilityElement(children: .combine)
    }
}

/// Tinted card so it's obvious the overview was generated.
private struct OverviewCard: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Summary")
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(IntelligencePalette.linear)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)

            Text(text)
                .font(.title3)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            shape.fill(.quinary)
            shape.fill(IntelligencePalette.linear.opacity(0.07))
        }
        .overlay {
            shape.strokeBorder(IntelligencePalette.linear.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct ActionItemRow: View {
    let item: MeetingSummary.ActionItem
    let isDone: Bool
    let toggle: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                toggle?()
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(toggle == nil)
            .help(isDone ? "Mark as Not Done" : "Mark as Done")

            Text(item.task)
                .strikethrough(isDone, color: .secondary)
                .foregroundStyle(isDone ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let owner = item.owner, !owner.isEmpty {
                OwnerTag(name: owner)
            }
        }
        .animation(.smooth(duration: 0.2), value: isDone)
        .sensoryFeedback(.alignment, trigger: isDone) { _, done in done }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(isDone ? Text("Done") : Text("Not done"))
        .accessibilityAddTraits(toggle == nil ? [] : .isToggle)
        .accessibilityAction { toggle?() }
    }

    private var accessibilityText: Text {
        if let owner = item.owner, !owner.isEmpty {
            Text("\(item.task), owner: \(owner)")
        } else {
            Text(item.task)
        }
    }
}

private struct OwnerTag: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            PersonAvatar(name: name, size: 16)
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(.quaternary, in: .capsule)
    }
}

extension MeetingSummary {
    /// Markdown that also reads fine as plain text.
    var markdown: String { markdown(completed: []) }

    func markdown(completed: Set<String>) -> String {
        var blocks: [String] = []
        if !overview.isEmpty { blocks.append(overview) }
        if !keyPoints.isEmpty {
            blocks.append("## Key Points\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !decisions.isEmpty {
            blocks.append("## Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !actionItems.isEmpty {
            let lines = actionItems.map { item in
                let box = completed.contains(item.task) ? "[x]" : "[ ]"
                return if let owner = item.owner, !owner.isEmpty { "- \(box) \(item.task) (\(owner))" } else { "- \(box) \(item.task)" }
            }
            blocks.append("## Action Items\n" + lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }
}

extension MeetingSummary {
    nonisolated static let sample = MeetingSummary(
        title: "Q3 planning",
        overview: "The team reviewed Q3 priorities and agreed to ship the new onboarding flow before the end of the quarter, deferring the analytics rework.",
        keyPoints: [
            "Onboarding drop-off is the largest conversion problem.",
            "The analytics rework needs a dedicated owner before it can start.",
        ],
        decisions: ["Ship onboarding in September.", "Defer analytics to Q4."],
        actionItems: [
            .init(task: "Draft the onboarding rollout plan", owner: "Maya"),
            .init(task: "Find an owner for the analytics rework", owner: nil),
        ]
    )
}

#Preview {
    @Previewable @State var completed: Set<String> = ["Draft the onboarding rollout plan"]
    ScrollView {
        SummaryContent(summary: .sample, completed: completed) { task in
            if completed.contains(task) { completed.remove(task) } else { completed.insert(task) }
        }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(32)
    }
    .frame(width: 720, height: 600)
}
