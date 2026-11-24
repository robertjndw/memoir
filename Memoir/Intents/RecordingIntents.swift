import AppIntents

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts recording and transcribing a meeting in Memoir.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        switch model.recordingState {
        case .idle:
            break
        case .starting, .recording:
            return .result(dialog: "Memoir is already recording.")
        case .finishing:
            return .result(dialog: "Memoir is still saving the last recording. Try again in a moment.")
        }
        await model.startRecording()
        guard model.isRecording else {
            throw RecordingIntentError.couldNotStart(model.errorMessage)
        }
        return .result(dialog: "Recording started.")
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the current Memoir recording and saves it.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard model.recordingState != .idle else {
            return .result(dialog: "Memoir is not recording.")
        }
        // Also covers a recording that is only just starting, which would otherwise keep running.
        await model.finishRecording()
        return .result(dialog: "Recording saved.")
    }
}

enum RecordingIntentError: Error, CustomLocalizedStringResourceConvertible {
    case couldNotStart(String?)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .couldNotStart(let reason):
            "Memoir could not start recording. \(reason ?? "")"
        }
    }
}

struct MemoirShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording in \(.applicationName)", "Start a \(.applicationName) recording"],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording in \(.applicationName)", "Stop the \(.applicationName) recording"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
