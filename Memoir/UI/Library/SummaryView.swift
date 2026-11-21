import SwiftData
import AppKit
import SwiftUI

struct SummaryView: View {
    let meeting: Meeting

    @Environment(AppModel.self) private var model

    var body: some View {
        let activity = model.summaryActivity[meeting.id]
        SummaryPane(
            state: state(activity: activity),
            availability: model.intelligenceAvailability,
            hasTranscript: !meeting.segments.isEmpty,
            completedItems: Set(meeting.completedActionItems),
            summarize: { Task { await model.summarize(meeting) } },
            toggleItem: { model.toggleActionItem($0, in: meeting) }
        )
        .onAppear { model.refresh() }
    }

    private func state(activity: AppModel.SummaryActivity?) -> SummaryPane.State {
        if let activity, activity.isRunning {
            if let condensing = activity.condensing { return .condensing(condensing) }
            if let draft = activity.draft { return .generating(draft) }
            return .preparing(previous: meeting.summary)
        }
        if let error = activity?.error {
            return .failed(error, previous: meeting.summary)
        }
        if let summary = meeting.summary { return .ready(summary) }
        return .empty
    }
}

/// Everything the summary pane shows, as plain values.
struct SummaryPane: View {
    enum State {
        case ready(MeetingSummary)
        case preparing(previous: MeetingSummary?)
        case condensing(Double)
        case generating(MeetingSummary)
        case failed(String, previous: MeetingSummary?)
        case empty
    }

    let state: State
    let availability: IntelligenceAvailability
    let hasTranscript: Bool
    var completedItems: Set<String> = []
    let summarize: () -> Void
    var toggleItem: ((String) -> Void)?

    var body: some View {
        switch state {
        case .ready(let summary):
            reading(summary: summary, canRegenerate: true)
        case .generating(let draft):
            reading(summary: draft, canRegenerate: false, progressLabel: "Summarizing...")
        case .preparing(let previous):
            if let previous {
                reading(summary: previous, canRegenerate: false, progressLabel: "Summarizing...")
            } else {
                progress(value: nil, label: "Preparing...")
            }
        case .condensing(let fraction):
            progress(value: fraction, label: "Reading transcript...")
        case .failed(let message, let previous):
            reading(summary: previous, canRegenerate: false, error: message)
        case .empty:
            emptyState
        }
    }

    private func progress(value: Double?, label: LocalizedStringKey) -> some View {
        VStack(spacing: 14) {
            IntelligenceActivity(label)
                .font(.title3)
            if let value {
                ProgressView(value: value)
                    .tint(IntelligencePalette.linear)
                    .frame(maxWidth: 240)
                    .accessibilityLabel(Text(label))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var emptyState: some View {
        if !hasTranscript {
            ContentUnavailableView(
                "No Summary",
                systemImage: "text.alignleft",
                description: Text("A summary needs a transcript. Record or transcribe this meeting first.")
            )
        } else if availability != .available {
            IntelligenceUnavailableView(availability: availability)
        } else {
            ContentUnavailableView {
                Label {
                    Text("No Summary Yet")
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(IntelligencePalette.linear)
                }
            } description: {
                Text("Summarize this meeting to get the key points, decisions and action items.")
            } actions: {
                Button("Summarize", systemImage: "sparkles", action: summarize)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
    }

    private func reading(
        summary: MeetingSummary?,
        canRegenerate: Bool,
        progressLabel: LocalizedStringKey? = nil,
        error: String? = nil
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error {
                    ErrorBanner(message: error, retry: availability == .available && hasTranscript ? summarize : nil)
                } else if availability != .available, progressLabel == nil {
                    IntelligenceUnavailableView(availability: availability, compact: true)
                }
                if let progressLabel {
                    IntelligenceActivity(progressLabel)
                        .transition(.blurReplace)
                }
                if let summary {
                    // Items can't be ticked off while the summary is still streaming.
                    SummaryContent(
                        summary: summary,
                        completed: completedItems,
                        onToggle: canRegenerate ? toggleItem : nil
                    )
                    if canRegenerate {
                        actions(for: summary)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.4), value: progressLabel == nil)
        }
    }

    private func actions(for summary: MeetingSummary) -> some View {
        HStack(spacing: 10) {
            CopyButton(text: summary.markdown(completed: completedItems))
            Button(action: summarize) {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(availability != .available || !hasTranscript)
        }
        .controlSize(.regular)
    }
}

/// Copies the summary and briefly confirms it in place, since the pasteboard gives no feedback of its own.
private struct CopyButton: View {
    let text: String

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            didCopy = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .animation(.smooth(duration: 0.2), value: didCopy)
        .sensoryFeedback(.alignment, trigger: didCopy) { _, copied in copied }
        .onDisappear { resetTask?.cancel() }
    }
}

private struct ErrorBanner: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("The summary could not be created").font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let retry {
                Button("Retry", action: retry)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

#Preview("Summary") {
    SummaryPane(state: .ready(.sample), availability: .available, hasTranscript: true, summarize: {})
        .frame(width: 720, height: 600)
}

#Preview("Streaming") {
    SummaryPane(
        state: .generating(MeetingSummary(overview: "The team reviewed Q3 priorities", keyPoints: ["Onboarding drop-off"])),
        availability: .available, hasTranscript: true, summarize: {}
    )
    .frame(width: 720, height: 600)
}

#Preview("Condensing") {
    SummaryPane(state: .condensing(0.4), availability: .available, hasTranscript: true, summarize: {})
        .frame(width: 720, height: 400)
}

#Preview("Error") {
    SummaryPane(state: .failed("The model stopped responding.", previous: nil), availability: .available, hasTranscript: true, summarize: {})
        .frame(width: 720, height: 400)
}

#Preview("Empty") {
    SummaryPane(state: .empty, availability: .available, hasTranscript: true, summarize: {})
        .frame(width: 720, height: 400)
}

#Preview("Unavailable") {
    SummaryPane(state: .empty, availability: .deviceNotEligible, hasTranscript: true, summarize: {})
        .frame(width: 720, height: 400)
}

#if DEBUG
#Preview("Live model") {
    @Previewable @State var model = AppModel.preview(samples: true)
    SummaryView(meeting: model.previewMeeting("Design Review"))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 600)
}

// Click Summarize in the live canvas to watch the canned summary stream in.
#Preview("Live model, not summarized") {
    @Previewable @State var model = AppModel.preview(samples: true)
    SummaryView(meeting: model.previewMeeting("Call at 9:15 AM"))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 600)
}
#endif
