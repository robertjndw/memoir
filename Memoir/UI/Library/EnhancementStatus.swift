import SwiftUI

extension AppModel.EnhancementActivity.Step {
    var title: LocalizedStringKey {
        switch self {
        case .transcribing: "Improving transcript…"
        case .identifyingSpeakers: "Identifying speakers…"
        }
    }
}

/// Waveform instead of sparkles, since transcription uses the speech model and not Apple Intelligence.
struct TranscribingStatus: View {
    private let title: LocalizedStringKey

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: LocalizedStringKey = "Transcribing…") {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            ShimmeringText(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Above the transcript while the optional models work on it, or after they failed.
///
/// Its own view so that progress reports, which arrive many times a second, only redraw this
/// bar and not the transcript. There is no progress bar: each step reports its own 0...1, so a
/// single bar would run to the end and start over.
struct EnhancementStatusBar: View {
    let meeting: Meeting

    @Environment(AppModel.self) private var model
    @State private var canRetry = false

    var body: some View {
        let step = model.enhancing[meeting.id]?.step
        let error = model.enhancementErrors[meeting.id]
        VStack(spacing: 0) {
            if let step {
                progress(step)
            } else if let error {
                errorRow(error)
            }
        }
        .animation(.smooth(duration: 0.3), value: step)
        .animation(.smooth(duration: 0.3), value: error)
        .task(id: error) { await updateRetry(for: error) }
    }

    @ViewBuilder
    private func progress(_ step: AppModel.EnhancementActivity.Step) -> some View {
        TranscribingStatus(step.title)
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .transition(.blurReplace)
        Divider()
    }

    private func errorRow(_ error: String) -> some View {
        ErrorRow(
            title: "The transcript could not be improved",
            message: error,
            retry: canRetry ? { retryEnhancement() } : nil,
            dismiss: { model.dismissEnhancementError(for: meeting.id) }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .transition(.opacity)
    }

    /// Retrying only helps while a model is still switched on and installed.
    private func updateRetry(for error: String?) async {
        guard error != nil, meeting.audioURL != nil else {
            canRetry = false
            return
        }
        canRetry = await !plan().isEmpty
    }

    private func plan() async -> AppModel.EnhancementPlan {
        await model.enhancementPlan(for: Locale(identifier: meeting.localeIdentifier))
    }

    private func retryEnhancement() {
        model.dismissEnhancementError(for: meeting.id)
        Task {
            // Transcribing again also identifies the speakers when that is on, so it covers
            // both. Without the transcription model the text is kept.
            if await plan().transcribe {
                await model.retranscribe(meeting)
            } else {
                await model.identifySpeakers(in: meeting)
            }
        }
    }
}
