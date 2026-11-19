import SwiftData
import SwiftUI
import os

@main
struct MemoirApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .modelContainer(model.container)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Memoir", id: AppModel.WindowID.library) {
            LibraryView()
                .environment(model)
                .regularAppWindow(model)
        }
        .modelContainer(model.container)
        .defaultSize(width: 1080, height: 700)
        .defaultLaunchBehavior(.suppressed)

        Window("Welcome to Memoir", id: AppModel.WindowID.onboarding) {
            OnboardingView()
                .environment(model)
                .regularAppWindow(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(model.settings.hasCompletedOnboarding ? .suppressed : .presented)

        Settings {
            SettingsView()
                .environment(model)
                .regularAppWindow(model)
        }
    }
}

extension AppModel {
    /// The one live instance. Under test the engines are inert and the store is in memory, so
    /// hosting the tests in the app never touches real recordings or hardware.
    static let shared: AppModel = {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let model = AppModel(
            settings: AppSettings(),
            container: .memoir(inMemory: isTesting),
            services: isTesting ? .inert : .live
        )
        if !isTesting {
            model.activate()
            #if DEBUG
            model.runDebugRecordingIfRequested()
            #endif
        }
        return model
    }()

    #if DEBUG
    /// End-to-end smoke test without touching the UI:
    /// `Memoir -debugAutoRecordSeconds 15` records for that long, then stops and logs the result.
    /// `-debugOpenLibrary YES` opens the Library window at launch.
    private func runDebugRecordingIfRequested() {
        if UserDefaults.standard.bool(forKey: "debugOpenLibrary") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                openLibrary()
            }
        }
        let seconds = UserDefaults.standard.double(forKey: "debugAutoRecordSeconds")
        guard seconds > 0 else { return }
        let log = Logger(subsystem: "Memoir", category: "Debug")
        Task {
            try? await Task.sleep(for: .seconds(1))
            await startRecording()
            log.info("debug recording unavailable=\(String(describing: self.unavailableSources), privacy: .public) error=\(self.errorMessage ?? "none", privacy: .public)")
            guard let id = recordingMeetingID else { return }
            var peak = AudioLevels()
            for _ in 0..<Int(seconds * 10) {
                try? await Task.sleep(for: .milliseconds(100))
                peak.microphone = max(peak.microphone, levels.microphone)
                peak.system = max(peak.system, levels.system)
            }
            log.info("debug peak levels mic=\(peak.microphone) system=\(peak.system)")
            await stopRecording()
            guard let meeting = meeting(with: id) else { return }
            log.info("debug recording done duration=\(meeting.duration) hasAudio=\(meeting.hasAudio) lines=\(meeting.segments.count)")
            for line in meeting.sortedLines {
                log.info("debug line [\(line.start, format: .fixed(precision: 1))-\(line.end, format: .fixed(precision: 1))] \(line.speaker.label, privacy: .public): \(line.text, privacy: .public)")
            }
        }
    }
    #endif
}

private struct RegularAppWindow: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .onAppear { model.regularWindowAppeared() }
            .onDisappear { model.regularWindowDisappeared() }
    }
}

extension View {
    /// Gives the agent app a Dock icon and main menu for as long as this window is open.
    func regularAppWindow(_ model: AppModel) -> some View {
        modifier(RegularAppWindow(model: model))
    }
}

/// The menu bar icon. It is the only view that exists for the whole lifetime of the app, so it
/// also hands the `openWindow` action to the model for use outside of views.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Status items are rendered as templates, so state is carried by the glyph and motion, not colour.
        Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
            .symbolEffect(.pulse, options: .repeating, isActive: model.isRecording && !reduceMotion)
            .accessibilityLabel(model.isRecording ? "Memoir, recording" : "Memoir")
            .onAppear {
                model.openWindow = { id in openWindow(id: id) }
            }
    }
}
