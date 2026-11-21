import AppKit
import SwiftUI

/// Transport for a finished recording, laid out like Voice Memos: a full-width waveform with the
/// controls centered beneath it, attached to the bottom edge of the meeting pane.
struct PlaybackBar: View {
    var playback: PlaybackController
    /// Sorted by start; colours the waveform by who was speaking.
    var speakers: [SpeakerSpan] = []
    @State private var skipBackCount = 0
    @State private var skipForwardCount = 0

    var body: some View {
        VStack(spacing: 6) {
            PlaybackTimeline(playback: playback, speakers: speakers)

            // Speed and transport share one row; the transport stays optically centered because
            // the speed menu sits in an overlay instead of pushing it aside.
            transport
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) { speedMenu }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .disabled(!playback.isLoaded)
        .background { PlaybackSpaceKey(playback: playback) }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button {
                skipBackCount += 1
                playback.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .symbolEffect(.bounce, value: skipBackCount)
            }
            .help("Skip Back 15 Seconds")
            .accessibilityLabel("Skip back 15 seconds")

            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .foregroundStyle(.primary)
            .help(playback.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button {
                skipForwardCount += 1
                playback.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.title2)
                    .symbolEffect(.bounce, value: skipForwardCount)
            }
            .help("Skip Forward 15 Seconds")
            .accessibilityLabel("Skip forward 15 seconds")
        }
        .foregroundStyle(.secondary)
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Bindable(playback).rate) {
                ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { rate in
                    Text("\(rate, format: .number)x").tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("\(playback.rate, format: .number)x")
                .monospacedDigit()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback Speed")
        .accessibilityLabel("Playback speed")
    }
}

/// The only part of the bar that reads `currentTime`, so playback ticks don't re-render the
/// transport buttons and menu.
private struct PlaybackTimeline: View {
    var playback: PlaybackController
    let speakers: [SpeakerSpan]
    @State private var scrubTime: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shownTime: TimeInterval { scrubTime ?? playback.currentTime }

    var body: some View {
        let remaining = max(0, playback.duration - shownTime)
        let duration = max(playback.duration, 0.1)
        HStack(spacing: 12) {
            Text(LibraryFormat.timecode(shownTime))
                .contentTransition(.numericText(value: shownTime))
                .frame(minWidth: 48, alignment: .trailing)
                .accessibilityHidden(true)

            WaveformScrubber(
                peaks: playback.waveform,
                speakers: speakers,
                duration: duration,
                progress: shownTime / duration,
                onScrub: { scrubTime = $0 * duration },
                onCommit: { fraction in
                    playback.seek(to: fraction * duration)
                    scrubTime = nil
                }
            )
            .frame(height: 34)
            // VoiceOver and Full Keyboard Access get a regular slider.
            .accessibilityRepresentation {
                Slider(
                    value: Binding(get: { shownTime }, set: { playback.seek(to: $0) }),
                    in: 0...duration
                )
                .accessibilityLabel("Playback position")
                .accessibilityValue(LibraryFormat.timecode(shownTime))
            }

            Text("-" + LibraryFormat.timecode(remaining))
                .contentTransition(.numericText(value: -remaining))
                .frame(minWidth: 52, alignment: .leading)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        // Roll the digits once a second during playback, but follow the thumb instantly while scrubbing.
        .animation(scrubTime == nil && !reduceMotion ? .snappy : nil, value: Int(shownTime))
    }
}

/// Space toggles playback, like in Music and QuickTime.
///
/// A plain `keyboardShortcut(.space)` would also fire while typing in the title, find, or chat
/// fields and eat the space. A local event monitor can look at the first responder first and only
/// claim the key when nothing else in this window would use it.
private struct PlaybackSpaceKey: NSViewRepresentable {
    let playback: PlaybackController

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.playback = playback
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.playback = playback
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        weak var playback: PlaybackController?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Read the key on this side so only a Sendable value crosses into the main actor.
                let key = SpaceKey(event)
                let handled = MainActor.assumeIsolated { self?.handle(key) ?? false }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private struct SpaceKey: Sendable {
            var isPlainSpace: Bool
            var isRepeat: Bool
            var windowNumber: Int

            init(_ event: NSEvent) {
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                isPlainSpace = event.charactersIgnoringModifiers == " " && modifiers.isEmpty
                isRepeat = event.isARepeat
                windowNumber = event.windowNumber
            }
        }

        private func handle(_ key: SpaceKey) -> Bool {
            guard key.isPlainSpace,
                  let window, key.windowNumber == window.windowNumber, window.attachedSheet == nil,
                  spaceIsUnclaimed(in: window),
                  let playback, playback.isLoaded
            else { return false }
            if !key.isRepeat { playback.togglePlayback() }
            return true
        }

        /// Whether Space would otherwise do nothing: no text is being edited and no control has
        /// keyboard focus.
        private func spaceIsUnclaimed(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder, responder !== window else { return true }
            // Lists don't use Space, and the meeting list is what usually has focus, so playback
            // gets it there like in Music.
            if responder is NSTableView || responder is NSCollectionView { return true }
            // Text views and other AppKit controls (segmented controls, popups) use Space themselves.
            if responder is NSText || responder is NSControl { return false }
            // With Full Keyboard Access, SwiftUI buttons and transcript lines take focus inside the
            // hosting view, invisible to AppKit, and Space must press them. Those users can focus
            // the play button instead.
            return !NSApp.isFullKeyboardAccessEnabled
        }
    }
}

#if DEBUG
#Preview("Playing") {
    PlaybackBar(
        playback: .preview(at: 754, of: 42 * 60, playing: true),
        speakers: (0..<21).map { SpeakerSpan(start: Double($0) * 120, end: Double($0) * 120 + 110, speaker: $0.isMultiple(of: 3) ? .me : .others) }
    )
        .frame(width: 720)
        .padding(.top, 40)
        .background(.background)
}

#Preview("Paused") {
    PlaybackBar(playback: .preview(at: 754, of: 42 * 60))
        .frame(width: 720)
}

#Preview("Not loaded") {
    PlaybackBar(playback: PlaybackController())
        .frame(width: 720)
}
#endif
