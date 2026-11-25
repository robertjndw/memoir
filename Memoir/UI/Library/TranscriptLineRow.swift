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
    let line: TranscriptLine
    let startsBlock: Bool
    let query: String
    /// The match that Find is currently on, which stands out from the other matches.
    var isFocusedMatch = false
    let emphasis: TranscriptLineEmphasis
    /// Set when the recording can be played; lines become click-to-seek buttons.
    let playback: PlaybackController?
    /// Set when identified speakers can be named, which is never in a live transcript.
    var meeting: Meeting?

    @State private var isHovered = false
    @State private var isNameHovered = false
    @State private var isRenaming = false

    static func tint(for speaker: Speaker) -> Color {
        speaker == .me ? .accentColor : .secondary
    }

    static func tint(for speaker: SpeakerID) -> AnyShapeStyle {
        if let color = SpeakerPalette.color(for: speaker) {
            AnyShapeStyle(SpeakerNameStyle(color: color))
        } else {
            AnyShapeStyle(tint(for: speaker.speaker))
        }
    }

    private var renamableVoice: Int? {
        meeting == nil ? nil : line.voice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if startsBlock {
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
            SpeakerAvatar(speaker: line.speakerID, name: line.name)
            speakerName
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

    @ViewBuilder
    private var speakerName: some View {
        let name = Text(line.label)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Self.tint(for: line.speakerID))
        if renamableVoice != nil {
            // Looks like plain text until hovered, like a link, so a long transcript is not full of buttons.
            Button {
                isRenaming = true
            } label: {
                name
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isNameHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 4))
                    .padding(.horizontal, -4)
                    .padding(.vertical, -1)
            }
            .buttonStyle(.plain)
            .onHover { isNameHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isNameHovered)
            .help("Rename Speaker")
            .accessibilityLabel(line.label)
            .accessibilityHint("Renames this speaker throughout the meeting")
            .popover(isPresented: $isRenaming, arrowEdge: .bottom) { renamePopover }
        } else {
            name
        }
    }

    @ViewBuilder
    private var renamePopover: some View {
        if let meeting, let voice = renamableVoice {
            SpeakerRenamePopover(meeting: meeting, voice: voice)
        }
    }

    // MARK: - Line

    @ViewBuilder
    private var content: some View {
        // Rows that open a block anchor the rename popover at the name instead.
        if startsBlock || renamableVoice == nil {
            lineContent
        } else {
            lineContent
                .popover(isPresented: $isRenaming, arrowEdge: .bottom) { renamePopover }
        }
    }

    @ViewBuilder
    private var lineContent: some View {
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
            .contextMenu { contextMenu }
            .accessibilityHint("Plays the recording from here")
            .accessibilityAddTraits(emphasis == .current ? .isSelected : [])
            .accessibilityActions { renameAction }
        } else {
            lineText
                .textSelection(.enabled)
                .contextMenu { contextMenu }
                .accessibilityActions { renameAction }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let playback {
            Button("Play from Here", systemImage: "play") {
                playback.seek(to: line.start, play: true)
            }
            Divider()
        }
        if renamableVoice != nil {
            Button("Rename Speaker…", systemImage: "person.crop.circle") {
                isRenaming = true
            }
            Divider()
        }
        Button("Copy", systemImage: "doc.on.doc") {
            copy(line.text)
        }
        Button("Copy with Timestamp") {
            copy("[\(LibraryFormat.timecode(line.start))] \(line.label): \(line.text)")
        }
    }

    @ViewBuilder
    private var renameAction: some View {
        if renamableVoice != nil {
            Button("Rename Speaker") { isRenaming = true }
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

/// Marks a stretch where the user was muted. Lines from the others keep going around it.
struct MutedMarkerRow: View {
    let range: MutedRange

    var body: some View {
        let start = LibraryFormat.timecode(range.start)
        let end = LibraryFormat.timecode(range.end)
        HStack(spacing: 6) {
            Image(systemName: "mic.slash.fill")
                .accessibilityHidden(true)
            Text("You were muted \(start)-\(end)")
                .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You were muted from \(start) to \(end)")
    }
}

/// A named speaker shows initials, everyone else a glyph: one person, or two for the
/// other side of a call that was never split into voices.
struct SpeakerAvatar: View {
    let speaker: SpeakerID
    var name: String?
    var size: CGFloat = 20

    init(speaker: SpeakerID, name: String? = nil, size: CGFloat = 20) {
        self.speaker = speaker
        self.name = name
        self.size = size
    }

    init(speaker: Speaker, size: CGFloat = 20) {
        self.init(speaker: SpeakerID(speaker: speaker), size: size)
    }

    var body: some View {
        Group {
            if let name, !name.isEmpty {
                Text(PersonAvatar.initials(of: name))
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(size * 0.08)
            } else {
                Image(systemName: speaker.speaker == .others && speaker.voice == nil ? "person.2.fill" : "person.fill")
                    .font(.system(size: size * 0.48, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(fill, in: .circle)
        .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        if speaker.speaker == .me {
            AnyShapeStyle(Color.accentColor.gradient)
        } else if let color = SpeakerPalette.color(for: speaker) {
            AnyShapeStyle(color.gradient)
        } else {
            AnyShapeStyle(Color.gray.gradient)
        }
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
