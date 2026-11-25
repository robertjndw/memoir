import SwiftData
import SwiftUI

struct TranscriptView: View {
    let meeting: Meeting
    var playback: PlaybackController
    /// Set by the Find command. Cleared here once the field has taken focus.
    @Binding var findRequested: Bool

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
                if !isLive {
                    EnhancementStatusBar(meeting: meeting)
                }
                // Replacing the transcript gives every line a new ID, so the first one changing
                // is when the improved transcript has arrived. A live transcript only grows.
                let replacementKey = isLive ? nil : lines.first?.id
                ZStack {
                    transcript(lines: lines, matches: matches)
                        .id(replacementKey)
                        .transition(.blurReplace)
                }
                .animation(.smooth(duration: 0.4), value: replacementKey)
            }
            // `initial` covers Command-F from another tab, where this view appears with the
            // request already set.
            .onChange(of: findRequested, initial: true) { _, requested in
                guard requested else { return }
                findFocused = true
                findRequested = false
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
                VStack(spacing: 12) {
                    if let activity = model.enhancing[meeting.id] {
                        TranscribingStatus(activity.step.title)
                            .font(.title3)
                            .transition(.blurReplace)
                    } else if model.retranscribing.contains(meeting.id) {
                        TranscribingStatus()
                            .font(.title3)
                            .transition(.blurReplace)
                    } else {
                        Button("Transcribe Recording", systemImage: "waveform") {
                            Task { await model.retranscribe(meeting) }
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .transition(.blurReplace)
                        if let failure = model.transcriptionErrors[meeting.id] ?? model.enhancementErrors[meeting.id] {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .transition(.blurReplace)
                        }
                    }
                }
                .animation(.smooth(duration: 0.3), value: model.retranscribing.contains(meeting.id))
                .animation(.smooth(duration: 0.3), value: model.enhancing[meeting.id]?.step)
                .animation(.smooth(duration: 0.3), value: model.transcriptionErrors[meeting.id])
            }
        } else {
            ContentUnavailableView("No Transcript", systemImage: "quote.bubble", description: Text("Nothing was transcribed for this meeting."))
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
                // Escape first clears the search, then gives up the field, like in Safari.
                .onExitCommand {
                    if query.isEmpty { findFocused = false } else { query = "" }
                }
            if isSearching {
                Text(matches.isEmpty ? "No matches" : "\(min(matchPosition, matches.count - 1) + 1) of \(matches.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .transition(.opacity)
                Group {
                    Button { step(by: -1, count: matches.count) } label: { Image(systemName: "chevron.up") }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .help("Previous Match (Shift-Command-G)")
                        .accessibilityLabel("Previous match")
                    Button { step(by: 1, count: matches.count) } label: { Image(systemName: "chevron.down") }
                        .keyboardShortcut("g", modifiers: .command)
                        .help("Next Match (Command-G)")
                        .accessibilityLabel("Next match")
                }
                .disabled(matches.isEmpty)
                .transition(.opacity)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.smooth(duration: 0.2), value: isSearching)
        .animation(.snappy(duration: 0.2), value: matchPosition)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func step(by delta: Int, count: Int) {
        guard count > 0 else { return }
        matchPosition = (matchPosition + delta + count) % count
    }

    // MARK: - Transcript

    private func transcript(lines: [TranscriptLine], matches: [UUID]) -> some View {
        TranscriptScroller(
            lines: lines,
            rows: TranscriptGrouping.rows(lines, mutedRanges: meeting.mutedRanges),
            query: query,
            focusedMatch: matches.isEmpty ? nil : matches[min(matchPosition, matches.count - 1)],
            isLive: isLive,
            playback: playback,
            meeting: meeting
        )
    }
}

#if DEBUG
#Preview("Transcript") {
    @Previewable @State var model = AppModel.preview(samples: true)
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: PlaybackController(), findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Speakers") {
    @Previewable @State var model = AppModel.preview(samples: true)
    TranscriptView(meeting: model.previewMeeting("Planning Sync"), playback: PlaybackController(), findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Identifying speakers") {
    @Previewable @State var model = AppModel.preview(samples: true) {
        $0.simulateEnhancing($0.previewMeeting("Design Review"))
    }
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: PlaybackController(), findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Improvement failed") {
    @Previewable @State var model = AppModel.preview(samples: true) {
        $0.simulateEnhancementError($0.previewMeeting("Planning Sync"), message: "The speaker model could not be loaded.")
    }
    TranscriptView(meeting: model.previewMeeting("Planning Sync"), playback: PlaybackController(), findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Playing") {
    @Previewable @State var model = AppModel.preview(samples: true)
    @Previewable @State var playback = PlaybackController.preview(at: 18, of: 42 * 60, playing: true)
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: playback, findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Paused") {
    @Previewable @State var model = AppModel.preview(samples: true)
    @Previewable @State var playback = PlaybackController.preview(at: 18, of: 42 * 60)
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: playback, findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Muted") {
    @Previewable @State var model = AppModel.preview(samples: true) {
        $0.previewMeeting("Design Review").mutedRanges = [MutedRange(start: 15.5, end: 23)]
    }
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: PlaybackController(), findRequested: .constant(false))
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
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: PlaybackController(), findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Listening") {
    @Previewable @State var model = AppModel.preview { $0.simulateRecording(Meeting(title: "Design Review")) }
    TranscriptView(meeting: model.previewMeeting("Design Review"), playback: PlaybackController(), findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Transcribing") {
    @Previewable @State var model = AppModel.preview(samples: true) {
        $0.simulateTranscribing($0.previewMeeting("Voice Note"))
    }
    TranscriptView(meeting: model.previewMeeting("Voice Note"), playback: PlaybackController(), findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}

#Preview("Audio, no transcript") {
    @Previewable @State var model = AppModel.preview(samples: true)
    TranscriptView(meeting: model.previewMeeting("Voice Note"), playback: PlaybackController(), findRequested: .constant(false))
        .environment(model)
        .modelContainer(model.container)
        .frame(width: 720, height: 480)
}
#endif
