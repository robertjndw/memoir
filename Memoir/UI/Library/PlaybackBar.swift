import SwiftUI

struct PlaybackBar: View {
    var playback: PlaybackController
    @State private var scrubTime: TimeInterval?

    private var shownTime: TimeInterval { scrubTime ?? playback.currentTime }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playback.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
            }
            .accessibilityLabel("Skip back 15 seconds")

            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button {
                playback.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
            }
            .accessibilityLabel("Skip forward 15 seconds")

            Text(LibraryFormat.timecode(shownTime))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)

            Slider(
                value: Binding(get: { shownTime }, set: { scrubTime = $0 }),
                in: 0...max(playback.duration, 0.1)
            ) { editing in
                if !editing, let scrubTime {
                    playback.seek(to: scrubTime)
                    self.scrubTime = nil
                }
            }
            .accessibilityLabel("Playback position")
            .accessibilityValue(LibraryFormat.timecode(shownTime))

            Text("-" + LibraryFormat.timecode(max(0, playback.duration - shownTime)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)

            Menu {
                Picker("Speed", selection: Bindable(playback).rate) {
                    ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { rate in
                        Text("\(rate, format: .number)x").tag(rate)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text("\(playback.rate, format: .number)x").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Playback speed")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .disabled(!playback.isLoaded)
    }
}
