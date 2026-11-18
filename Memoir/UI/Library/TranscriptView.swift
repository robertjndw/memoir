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
                Label("No Transcript", systemImage: "text.alignleft")
            } description: {
                Text("This recording has audio but no transcript yet.")
            } actions: {
                if model.retranscribing.contains(meeting.id) {
                    ProgressView {
                        Text("Transcribing...")
                    }
                } else {
                    Button("Transcribe Recording") {
                        Task { await model.retranscribe(meeting) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else {
            ContentUnavailableView("No Transcript", systemImage: "text.alignleft", description: Text("Nothing was transcribed for this meeting."))
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
        let current = playback.isLoaded && !isLive ? TranscriptGrouping.currentLineID(in: lines, at: playback.currentTime) : nil
        let highlight = playback.currentTime > 0 || playback.isPlaying
        let focusedMatch = matches.isEmpty ? nil : matches[min(matchPosition, matches.count - 1)]

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(TranscriptGrouping.blocks(lines)) { block in
                        TranscriptBlockView(
                            block: block,
                            query: query,
                            currentLineID: highlight ? current : nil,
                            canSeek: playback.isLoaded,
                            onSeek: { playback.seek(to: $0, play: true) }
                        )
                    }
                    if isLive {
                        livePreview
                        Color.clear.frame(height: 1).id(Self.endID)
                    }
                }
                .padding(16)
            }
            .onChange(of: current) { _, id in
                guard playback.isPlaying, let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: focusedMatch) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: lines.count) {
                guard isLive else { return }
                proxy.scrollTo(Self.endID, anchor: .bottom)
            }
        }
    }

    private static let endID = "transcript-end"

    @ViewBuilder
    private var livePreview: some View {
        ForEach(Speaker.allCases.filter { model.volatileText[$0]?.isEmpty == false }, id: \.self) { speaker in
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TranscriptBlockView.tint(for: speaker))
                Text(model.volatileText[speaker] ?? "")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let query: String
    let currentLineID: UUID?
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void

    static func tint(for speaker: Speaker) -> Color {
        speaker == .me ? .accentColor : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(block.speaker.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.tint(for: block.speaker))
                Text(LibraryFormat.timecode(block.start))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            ForEach(block.lines) { line in
                Text(highlighted(line.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(
                        line.id == currentLineID ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 6)
                    )
                    .contentShape(.rect)
                    .onTapGesture {
                        if canSeek { onSeek(line.start) }
                    }
                    .accessibilityHint(canSeek ? "Plays the recording from here" : "")
                    .id(line.id)
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return result }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: result),
               let upper = AttributedString.Index(found.upperBound, within: result) {
                result[lower..<upper].backgroundColor = .yellow.opacity(0.5)
            }
            searchRange = found.upperBound..<text.endIndex
        }
        return result
    }
}
