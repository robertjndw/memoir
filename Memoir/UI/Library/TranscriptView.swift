import SwiftData
import SwiftUI

struct TranscriptView: View {
    let meeting: Meeting
    var playback: PlaybackController

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var matchPosition = 0
    @FocusState private var findFocused: Bool

    private var isLive: Bool { model.recordingMeetingID == meeting.id }

    var body: some View {
        let lines = isLive ? model.liveLines : meeting.sortedLines
        if lines.isEmpty {
            emptyState
        } else {
            let matches = TranscriptGrouping.matchingIDs(in: lines, query: query)
            VStack(spacing: 0) {
                findBar(matches: matches)
                Divider()
                transcript(lines: lines, matches: matches)
            }
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if isLive {
            ContentUnavailableView("Listening", systemImage: "waveform", description: Text("The transcript appears here as people speak."))
        } else if meeting.audioURL != nil {
            ContentUnavailableView {
                Label("No Transcript", systemImage: "quote.bubble")
            } description: {
                Text("This recording has audio but no transcript yet.")
            } actions: {
                // Same style as the Summarize button in the summary tab.
                Group {
                    if model.retranscribing.contains(meeting.id) {
                        TranscribingStatus()
                            .transition(.blurReplace)
                    } else {
                        Button("Transcribe Recording", systemImage: "waveform") {
                            Task { await model.retranscribe(meeting) }
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .transition(.blurReplace)
                    }
                }
                .animation(.smooth(duration: 0.3), value: model.retranscribing.contains(meeting.id))
            }
        } else {
            ContentUnavailableView("No Transcript", systemImage: "quote.bubble", description: Text("Nothing was transcribed for this meeting."))
        }
    }

    /// Waveform instead of sparkles, since transcription uses the speech model and not Apple Intelligence.
    private struct TranscribingStatus: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                ShimmeringText("Transcribing...")
            }
            .font(.title3)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: - Find

    private func findBar(matches: [UUID]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find in Transcript", text: $query)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { step(by: 1, count: matches.count) }
                .onChange(of: query) { matchPosition = 0 }
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(matches.isEmpty ? "No matches" : "\(min(matchPosition, matches.count - 1) + 1) of \(matches.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button { step(by: -1, count: matches.count) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Previous match")
                Button { step(by: 1, count: matches.count) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Next match")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func step(by delta: Int, count: Int) {
        guard count > 0 else { return }
        matchPosition = (matchPosition + delta + count) % count
    }

    // MARK: - Transcript

    private func transcript(lines: [TranscriptLine], matches: [UUID]) -> some View {
        TranscriptScroller(
            lines: lines,
            rows: TranscriptGrouping.rows(lines),
            query: query,
            focusedMatch: matches.isEmpty ? nil : matches[min(matchPosition, matches.count - 1)],
            isLive: isLive,
            playback: playback
        )
    }
}

#if DEBUG
#Preview("Transcript") {
    @Previewable @State var model = AppModel.preview(samples: true)
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: PlaybackController())
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Playing") {
    @Previewable @State var model = AppModel.preview(samples: true)
    @Previewable @State var playback = PlaybackController.preview(at: 18, of: 42 * 60, playing: true)
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: playback)
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Paused") {
    @Previewable @State var model = AppModel.preview(samples: true)
    @Previewable @State var playback = PlaybackController.preview(at: 18, of: 42 * 60)
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: playback)
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Live") {
    @Previewable @State var model = AppModel.preview {
        $0.simulateRecording(
            Meeting(title: "Design Review"),
            lines: Meeting.sampleLines,
            volatile: [.others: "Works for me, I'll tell"]
        )
    }
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: PlaybackController())
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Listening") {
    @Previewable @State var model = AppModel.preview { $0.simulateRecording(Meeting(title: "Design Review")) }
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: PlaybackController())
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Transcribing") {
    @Previewable @State var model = AppModel.preview(samples: true) {
        $0.simulateTranscribing($0.previewMeeting("Voice Note"))
    }
    TranscriptView(meeting: model.previewMeeting("Voice Note"), playback: PlaybackController())
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Audio, no transcript") {
    @Previewable @State var model = AppModel.preview(samples: true)
    TranscriptView(meeting: model.previewMeeting("Voice Note"), playback: PlaybackController())
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}
#endif
