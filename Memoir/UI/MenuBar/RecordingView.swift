import SwiftUI

struct RecordingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ElapsedTime(start: model.recordingStartDate)
                .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                LevelMeter(symbol: "mic.fill", label: "Microphone level", level: model.levels.microphone)
                LevelMeter(symbol: "speaker.wave.2.fill", label: "System audio level", level: model.levels.system)
            }

            if !model.unavailableSources.isEmpty {
                ForEach(model.unavailableSources.sorted { $0.rawValue < $1.rawValue }, id: \.self) { source in
                    SourceWarning(source: source)
                }
            }

            TranscriptTail(lines: model.liveLines, volatile: model.volatileText)

            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Stop recording")
        }
    }
}

struct ElapsedTime: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start ?? context.date)))
            Text(Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                .font(.system(size: 34, weight: .light, design: .rounded))
                .monospacedDigit()
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
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message).font(.callout)
            Spacer(minLength: 0)
            Button("Open Settings") { NSWorkspace.shared.open(settingsURL) }
                .buttonStyle(.borderless)
                .font(.callout)
                .accessibilityLabel("Open Privacy and Security settings")
        }
        .accessibilityElement(children: .contain)
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
        .frame(width: 340)
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
        .frame(width: 340)
}
#endif

#Preview("Timer and warning") {
    VStack(spacing: 12) {
        ElapsedTime(start: .now.addingTimeInterval(-754))
        SourceWarning(source: .system)
    }
    .padding().frame(width: 340)
}
