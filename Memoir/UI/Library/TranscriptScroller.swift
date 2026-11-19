import SwiftUI

/// The scrolling transcript and its follow-along behavior.
///
/// It owns the current line and follow state, so a new spoken line only re-renders this view.
/// The parent, which sorts the meeting's lines and runs the find query, stays untouched.
struct TranscriptScroller: View {
    let lines: [TranscriptLine]
    let rows: [TranscriptRow]
    let query: String
    let focusedMatch: UUID?
    let isLive: Bool
    var playback: PlaybackController

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentLineID: UUID?
    @State private var isFollowing = true

    private var tracksPlayback: Bool { playback.isLoaded && !isLive }

    var body: some View {
        let tracksPlayback = tracksPlayback
        let current = tracksPlayback ? currentLineID : nil
        let firstID = rows.first?.id

        // ScrollViewReader rather than a ScrollPosition binding: the binding writes back as the
        // user scrolls, which would re-render the whole transcript for every line scrolled past.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        TranscriptLineRow(
                            row: row,
                            query: query,
                            emphasis: emphasis(for: row.id, current: current),
                            playback: tracksPlayback ? playback : nil
                        )
                        .padding(.top, row.startsBlock && row.id != firstID ? 14 : 0)
                    }
                    if isLive {
                        livePreview
                            .padding(.top, 14)
                            .padding(.horizontal, 8)
                        Color.clear.frame(height: 1).id(Self.endID)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
            .background {
                if tracksPlayback {
                    TranscriptPlayheadReader(lines: lines, playback: playback, currentLineID: $currentLineID)
                }
            }
            .overlay(alignment: .bottom) {
                followAlongButton(visible: tracksPlayback && playback.isPlaying && !isFollowing && current != nil) {
                    isFollowing = true
                    scroll(proxy, to: currentLineID)
                }
            }
            .onScrollPhaseChange { _, phase in
                // `.interacting` is only ever the person scrolling: scrollTo with an animation
                // reports `.animating`, and without one it changes no phase at all. `.tracking` is
                // left out because a resting finger on the trackpad is not yet a scroll.
                guard tracksPlayback, current != nil, phase == .interacting else { return }
                isFollowing = false
            }
            .onChange(of: currentLineID) { old, id in
                guard tracksPlayback, isFollowing, let id else { return }
                if old == nil {
                    // No animation for the first highlight after opening the tab or starting from zero.
                    proxy.scrollTo(id, anchor: Self.followAnchor)
                } else if playback.isPlaying {
                    scroll(proxy, to: id)
                }
            }
            .onChange(of: playback.seekGeneration) {
                guard tracksPlayback else { return }
                isFollowing = true
                // The reader publishes the new line a frame later, so look it up directly to
                // start the scroll right away.
                scroll(proxy, to: TranscriptGrouping.currentLineID(in: lines, at: playback.currentTime))
            }
            .onChange(of: playback.isPlaying) { _, playing in
                // Resuming playback after scrolling away jumps back to the playing line.
                guard tracksPlayback, playing, !isFollowing else { return }
                isFollowing = true
                scroll(proxy, to: currentLineID)
            }
            .onChange(of: focusedMatch) { _, id in
                guard let id else { return }
                isFollowing = false
                scroll(proxy, to: id)
            }
            .onChange(of: lines.count) {
                guard isLive else { return }
                proxy.scrollTo(Self.endID, anchor: .bottom)
            }
        }
    }

    private static let endID = "transcript-end"
    /// Slightly above center, so upcoming lines get more room than the ones already spoken.
    private static let followAnchor = UnitPoint(x: 0.5, y: 0.4)

    private func emphasis(for id: UUID, current: UUID?) -> TranscriptLineEmphasis {
        guard let current else { return .plain }
        if id == current { return .current }
        // Paused, the reader is likely skimming, so only the current line is marked.
        guard playback.isPlaying else { return .plain }
        return isFollowing ? .dimmed : .muted
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: UUID?) {
        guard let id else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) {
            proxy.scrollTo(id, anchor: Self.followAnchor)
        }
    }

    private func followAlongButton(visible: Bool, action: @escaping () -> Void) -> some View {
        ZStack {
            if visible {
                Button(action: action) {
                    Label("Follow Along", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Scroll back to the line being played")
                .padding(.bottom, 12)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: visible)
    }

    @ViewBuilder
    private var livePreview: some View {
        ForEach(Speaker.allCases.filter { model.volatileText[$0]?.isEmpty == false }, id: \.self) { speaker in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SpeakerAvatar(speaker: speaker)
                    Text(speaker.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TranscriptLineRow.tint(for: speaker))
                }
                Text(model.volatileText[speaker] ?? "")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
