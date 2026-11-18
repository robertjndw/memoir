import SwiftUI

/// The summary sections as plain values, so it previews and streams without a live model.
struct SummaryContent: View {
    let summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !summary.overview.isEmpty {
                Text(summary.overview)
                    .font(.body)
                    .lineSpacing(3)
            }
            if !summary.keyPoints.isEmpty {
                section("Key Points") {
                    ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, point in
                        row(marker: "circle.fill") { Text(point) }
                    }
                }
            }
            if !summary.decisions.isEmpty {
                section("Decisions") {
                    ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                        row(marker: "checkmark.seal") { Text(decision) }
                    }
                }
            }
            if !summary.actionItems.isEmpty {
                section("Action Items") {
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                        row(marker: "circle") {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.task).frame(maxWidth: .infinity, alignment: .leading)
                                if let owner = item.owner, !owner.isEmpty {
                                    OwnerTag(name: owner)
                                }
                            }
                        }
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

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    private func row(marker: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: marker)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            content()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OwnerTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
            .accessibilityLabel("Owner: \(name)")
    }
}

extension MeetingSummary {
    /// Markdown that also reads fine as plain text.
    var markdown: String {
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
                if let owner = item.owner, !owner.isEmpty { "- [ ] \(item.task) (\(owner))" } else { "- [ ] \(item.task)" }
            }
            blocks.append("## Action Items\n" + lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }
}

extension MeetingSummary {
    static let sample = MeetingSummary(
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
    ScrollView {
        SummaryContent(summary: .sample)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(32)
    }
    .frame(width: 720, height: 600)
}
