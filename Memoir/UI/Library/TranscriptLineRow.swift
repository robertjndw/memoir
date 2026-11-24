import AppKit
import SwiftUI

/// How a line relates to the playhead.
enum TranscriptLineEmphasis: Equatable {
    /// Nothing is playing, or the transcript is live.
    case plain
    /// The line being spoken.
    case current
    /// Playing, but the reader has scrolled away, so other lines stay comfortably readable.
    case muted
    /// Playing and following along: everything but the current line recedes, like lyrics.
    case dimmed
}

/// One transcript line, plus the speaker header when it opens a speaker turn.
///
/// Every input is a plain value or an object reference, so SwiftUI can skip this view when the
/// playhead moves elsewhere. Only the rows whose emphasis changes re-render on a line change.
struct TranscriptLineRow: View {
    let row: TranscriptRow
    let query: String
    /// The match that Find is currently on, which stands out from the other matches.
    var isFocusedMatch = false
    let emphasis: TranscriptLineEmphasis
    /// Set when the recording can be played; lines become click-to-seek buttons.
    let playback: PlaybackController?

    @State private var isHovered = false

    static func tint(for speaker: Speaker) -> Color {
        speaker == .me ? .accentColor : .secondary
    }

    private var line: TranscriptLine { row.line }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if row.startsBlock {
                header
            }
            content
                .animation(.smooth(duration: 0.35), value: emphasis)
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            SpeakerAvatar(speaker: line.speaker)
            Text(line.speaker.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Self.tint(for: line.speaker))
            if let playback {
                Button {
                    playback.seek(to: line.start, play: true)
                } label: {
                    Text(LibraryFormat.timecode(line.start))
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .pointerStyle(.link)
                .help("Play from \(LibraryFormat.timecode(line.start))")
                .accessibilityLabel("Play from \(LibraryFormat.timecode(line.start))")
            } else {
                Text(LibraryFormat.timecode(line.start))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Line

    @ViewBuilder
    private var content: some View {
        if let playback {
            // A selectable Text swallows clicks, so seekable lines trade drag-selection for
            // click-to-seek and offer copying through the context menu instead.
            Button {
                playback.seek(to: line.start, play: true)
            } label: {
                lineText
                    .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .contextMenu {
                Button("Play from Here", systemImage: "play") {
                    playback.seek(to: line.start, play: true)
                }
                Divider()
                Button("Copy", systemImage: "doc.on.doc") {
                    copy(line.text)
                }
                Button("Copy with Timestamp") {
                    copy("[\(LibraryFormat.timecode(line.start))] \(line.speaker.label): \(line.text)")
                }
            }
            .accessibilityHint("Plays the recording from here")
            .accessibilityAddTraits(emphasis == .current ? .isSelected : [])
        } else {
            lineText
                .textSelection(.enabled)
        }
    }

    private var lineText: some View {
        Text(highlighted(line.text))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(background, in: .rect(cornerRadius: 8))
    }

    private var foreground: AnyShapeStyle {
        switch emphasis {
        case .plain: AnyShapeStyle(.primary)
        // Colour alone marks the playhead, so nothing slides between lines as playback moves.
        case .current: AnyShapeStyle(.tint)
        case .muted: AnyShapeStyle(.secondary)
        case .dimmed: AnyShapeStyle(.tertiary)
        }
    }

    // Only hover gets a background, as click feedback.
    private var background: AnyShapeStyle {
        if isHovered {
            AnyShapeStyle(.quaternary.opacity(0.6))
        } else {
            AnyShapeStyle(.clear)
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return result }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: result),
               let upper = AttributedString.Index(found.upperBound, within: result) {
                if isFocusedMatch {
                    // Solid yellow needs dark text in both appearances.
                    result[lower..<upper].backgroundColor = .yellow
                    result[lower..<upper].foregroundColor = .black
                } else {
                    result[lower..<upper].backgroundColor = .yellow.opacity(0.35)
                }
            }
            searchRange = found.upperBound..<text.endIndex
        }
        return result
    }
}

struct SpeakerAvatar: View {
    let speaker: Speaker
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: speaker == .others ? "person.2.fill" : "person.fill")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(speaker == .me ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.gray.gradient), in: .circle)
            .accessibilityHidden(true)
    }
}

/// Turns the playhead into the current line ID. It is the only part of the transcript that reads
/// `currentTime`, so the ten-per-second ticks re-render this empty view instead of every line,
/// and the transcript itself only updates when the current line actually changes.
struct TranscriptPlayheadReader: View {
    let lines: [TranscriptLine]
    let playback: PlaybackController
    @Binding var currentLineID: UUID?

    var body: some View {
        // At position zero and paused nothing has been played yet, so nothing is highlighted.
        let started = playback.currentTime > 0 || playback.isPlaying
        let id = started ? TranscriptGrouping.currentLineID(in: lines, at: playback.currentTime) : nil
        Color.clear
            .onChange(of: id, initial: true) { _, id in currentLineID = id }
    }
}
