import AppKit
import SwiftData
import SwiftUI
import os

@main
struct MemoirApp: App {
    @State private var model = AppModel.shared
    @State private var updater = Updater(model: AppModel.shared)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
        .commands {
            MeetingMenuCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!Updater.isEnabled || !updater.canCheckForUpdates)
            }
        }
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
                .environment(updater)
                .regularAppWindow(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Every way of quitting ends up here: the menu bar window, the Dock, the app menu, an
    // update relaunch and logging out. Quitting mid-recording would drop the audio mix and the
    // tail of the transcript, so the recording is finalized first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.recordingState != .idle else { return .terminateNow }
        Task {
            await model.finishRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

    @State private var now = Date.now

    var body: some View {
        // Status items are rendered as templates, so state is carried by the glyph and motion, not colour.
        HStack(spacing: 4) {
            // Swap the glyph rather than add a second image. Status item labels don't reliably
            // render more than one.
            Image(systemName: glyph)
                .symbolEffect(.pulse, options: .repeating, isActive: model.isRecording && !reduceMotion)
            if model.isRecording, let start = model.recordingStartDate {
                Text(LibraryFormat.timecode(now.timeIntervalSince(start)))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            model.openWindow = { id in openWindow(id: id) }
        }
        // Driven by state instead of TimelineView, which isn't guaranteed to update in a MenuBarExtra label.
        .task(id: model.isRecording) {
            while model.isRecording, !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var glyph: String {
        guard model.isRecording else { return "waveform" }
        return model.isMicrophoneMuted ? "mic.slash.circle.fill" : "record.circle.fill"
    }

    private var accessibilityLabel: LocalizedStringKey {
        guard model.isRecording else { return "Memoir" }
        return model.isMicrophoneMuted ? "Memoir, recording, microphone muted" : "Memoir, recording"
    }
}
