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
            summarize: { Task { await model.summarize(meeting) } }
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
    let summarize: () -> Void

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
        VStack(spacing: 12) {
            if let value {
                ProgressView(value: value) { Text(label) }
                    .frame(maxWidth: 280)
            } else {
                ProgressView { Text(label) }
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
                Label("No Summary Yet", systemImage: "sparkles")
            } description: {
                Text("Summarize this meeting to get the key points, decisions and action items.")
            } actions: {
                Button("Summarize", action: summarize)
                    .buttonStyle(.borderedProminent)
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
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progressLabel).foregroundStyle(.secondary)
                    }
                }
                if let summary {
                    SummaryContent(summary: summary)
                    if canRegenerate {
                        actions(for: summary)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func actions(for summary: MeetingSummary) -> some View {
        HStack(spacing: 10) {
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(summary.markdown, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button(action: summarize) {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(availability != .available || !hasTranscript)
        }
        .controlSize(.regular)
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

#Preview("Live model") {
    let model = AppModel.preview()
    let meeting = Meeting(title: "Q3 planning")
    meeting.summary = .sample
    model.context.insert(meeting)
    return SummaryView(meeting: meeting)
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 600)
}
