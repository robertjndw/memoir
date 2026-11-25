import SwiftUI

struct RecordingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RecordingHeader()

            VStack(spacing: 8) {
                LiveWaveform()
                    .frame(height: 44)
                SourceLegend()
            }
            .padding(.horizontal, 8)

            ForEach(model.unavailableSources.sorted { $0.rawValue < $1.rawValue }, id: \.self) { source in
                SourceWarning(source: source)
                    .transition(.blurReplace)
            }

            if model.isMicrophoneMuted {
                MutedNotice()
                    .transition(.blurReplace)
            }

            TranscriptTail(lines: model.liveLines, volatile: model.volatileText)

            HStack(spacing: 8) {
                if !model.unavailableSources.contains(.microphone) {
                    MuteButton()
                }
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.large)
                .accessibilityLabel("Stop recording")
            }
        }
        .animation(.smooth(duration: 0.3), value: model.unavailableSources)
        .animation(.smooth(duration: 0.3), value: model.isMicrophoneMuted)
    }
}

private struct MuteButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let muted = model.isMicrophoneMuted
        Button {
            Task { await model.toggleMicrophoneMuted() }
        } label: {
            Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .help(muted ? "Unmute Microphone (⇧⌘M)" : "Mute Microphone (⇧⌘M)")
        .accessibilityLabel(muted ? "Unmute microphone" : "Mute microphone")
        .accessibilityHint("Others are recorded either way")
    }
}

private struct RecordingHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let meeting = model.recordingMeetingID.flatMap(model.meeting(with:))
        // The only way into the Library while recording, since Recent is hidden then.
        Button {
            model.openLibrary(selecting: model.recordingMeetingID)
        } label: {
            content(meeting)
        }
        .buttonStyle(MenuRowStyle())
        .keyboardShortcut("l", modifiers: .command)
        .accessibilityHint("Opens the live transcript in the Library")
    }

    private func content(_ meeting: Meeting?) -> some View {
        HStack(spacing: 10) {
            MeetingIcon(bundleID: meeting?.sourceAppBundleID, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting?.title ?? String(localized: "Recording"))
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    RecordingIndicator()
                        .font(.caption)
                    Text("Recording")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            ElapsedTime(start: model.recordingStartDate)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Also the VoiceOver element for the input levels.
private struct SourceLegend: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            entry(.microphone, label: "You", symbol: "mic.fill", mutedSymbol: "mic.slash.fill", level: model.levels.microphone)
            entry(.system, label: "Others", symbol: "speaker.wave.2.fill", mutedSymbol: "speaker.slash.fill", level: model.levels.system)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func entry(
        _ source: AudioSource,
        label: LocalizedStringKey,
        symbol: String,
        mutedSymbol: String,
        level: Float
    ) -> some View {
        let unavailable = model.unavailableSources.contains(source)
        let muted = source == .microphone && model.isMicrophoneMuted
        return HStack(spacing: 5) {
            Circle()
                .fill(speakerColor(SpeakerID(speaker: source == .microphone ? .me : .others)))
                .frame(width: 6, height: 6)
            Image(systemName: unavailable || muted ? mutedSymbol : symbol)
                .contentTransition(.symbolEffect(.replace))
            Text(label)
        }
        .opacity(unavailable || muted ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source == .microphone ? "Microphone level" : "System audio level")
        .accessibilityValue(value(unavailable: unavailable, muted: muted, level: level))
    }

    private func value(unavailable: Bool, muted: Bool, level: Float) -> Text {
        if unavailable { return Text("Not recording") }
        if muted { return Text("Muted") }
        return Text(Double(level), format: .percent.precision(.fractionLength(0)))
    }
}

struct RecordingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "record.circle.fill")
            .symbolRenderingMode(.multicolor)
            .foregroundStyle(.red)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .accessibilityHidden(true)
    }
}

struct ElapsedTime: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start ?? context.date)))
            Text(Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                .font(.system(.title3, design: .default, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(countsDown: false))
                .animation(.smooth, value: seconds)
                .accessibilityLabel("Elapsed time")
                .accessibilityValue(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds])))
        }
    }
}

struct SourceWarning: View {
    let source: AudioSource

    private var message: LocalizedStringKey {
        switch source {
        case .microphone: "Microphone is not being recorded"
        case .system: "System audio is not being recorded"
        }
    }

    private var settingsURL: URL {
        let pane = source == .microphone ? "Privacy_Microphone" : "Privacy_AudioCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            Text(message).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Open Settings") { NSWorkspace.shared.open(settingsURL) }
                .buttonStyle(.borderless)
                .font(.callout)
                .accessibilityLabel("Open Privacy and Security settings")
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
    }
}

/// Not a SourceWarning, since muting is on purpose.
struct MutedNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Your microphone is muted. Others are still recorded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Recording") {
    @Previewable @State var model = AppModel.preview {
        $0.simulateRecording(Meeting(title: "Design Review"), lines: Meeting.sampleLines)
    }
    RecordingView()
        .environment(model)
        .padding()
        .frame(width: 320)
}

#Preview("System audio missing") {
    @Previewable @State var model = AppModel.preview {
        $0.simulateRecording(
            Meeting(title: "Design Review"),
            elapsed: 12,
            levels: AudioLevels(microphone: 0.4, system: 0),
            unavailable: [.system]
        )
    }
    RecordingView()
        .environment(model)
        .padding()
        .frame(width: 320)
}

#Preview("Microphone muted") {
    @Previewable @State var model = AppModel.preview {
        $0.simulateRecording(
            Meeting(title: "Design Review"),
            lines: Meeting.sampleLines,
            levels: AudioLevels(microphone: 0, system: 0.3),
            microphoneMuted: true
        )
    }
    RecordingView()
        .environment(model)
        .padding()
        .frame(width: 320)
}
#endif

#Preview("Timer and warning") {
    VStack(spacing: 12) {
        ElapsedTime(start: .now.addingTimeInterval(-754))
        SourceWarning(source: .system)
    }
    .padding().frame(width: 320)
}
