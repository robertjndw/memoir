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
    #if DEBUG
    // Debug builds are not LSUIElement, because Xcode previews never finish launching an
    // agent app. Outside of previews they turn into one here, so running from Xcode still
    // behaves like the shipped menu bar app. It has to be after launch: SwiftUI sets the
    // policy from Info.plist during launch and would undo an earlier change.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ProcessInfo.processInfo.isRunningForPreviews else { return }
        NSApp.setActivationPolicy(.accessory)
    }
    #endif

    // Every way of quitting ends up here: the menu bar window, the Dock, the app menu, an
    // update relaunch and logging out. Quitting mid-recording would drop the audio mix and the
    // tail of the transcript, so the recording is finalized first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.recordingState != .idle else {
            // A rename or a ticked action item right before quitting may not have been
            // autosaved yet.
            try? model.context.save()
            return .terminateNow
        }
        Task {
            await model.finishRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension AppModel {
    /// The one live instance. Under test and in Xcode previews the engines are inert and the
    /// store is in memory, so neither touches real recordings or hardware. Previews launch the
    /// whole app, and starting the real engines there stalls the launch until it times out.
    static let shared: AppModel = {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.isRunningForPreviews
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
    /// `-debugSuggestApp com.tinyspeck.slackmacgap` shows a meeting suggestion for that app.
    private func runDebugRecordingIfRequested() {
        if let bundleID = UserDefaults.standard.string(forKey: "debugSuggestApp") {
            Task {
                // The status item needs a moment to land in the menu bar.
                try? await Task.sleep(for: .seconds(2))
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    .map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) }
                debugSuggest(MeetingSuggestion(kind: .start, appName: name ?? bundleID, bundleID: bundleID))
            }
        }
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
                log.info("debug line [\(line.start, format: .fixed(precision: 1))-\(line.end, format: .fixed(precision: 1))] \(line.label, privacy: .public): \(line.text, privacy: .public)")
            }
        }
    }
    #endif
}

extension ProcessInfo {
    /// Xcode previews launch the whole app and wait for it to finish launching as a regular
    /// app. Turning it into an agent app at any point during that launch stalls the preview
    /// until it times out.
    var isRunningForPreviews: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

extension ModelContainer {
    /// Opens the library, or asks the user what to do when it cannot be opened: a damaged file
    /// or one written by a newer version would otherwise stop the app at every launch.
    ///
    /// Runs before the app has finished launching, so the alerts are modal and the only way
    /// out other than a fresh store is to quit.
    static func openMemoirStore() -> ModelContainer {
        let error: any Error
        do {
            return try memoirOnDisk()
        } catch let openError {
            error = openError
        }
        Logger(subsystem: "Memoir", category: "Store").error("Could not open the store: \(error)")

        let app = NSApplication.shared
        // An agent app's alert would otherwise open behind whatever is frontmost.
        app.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Memoir can't open its library")
        alert.informativeText = String(localized: """
            \(error.localizedDescription)

            You can start with an empty library. The current one is not deleted: it is renamed \
            and kept in the same folder, and your recordings' audio files stay where they are.
            """)
        alert.addButton(withTitle: String(localized: "Start with an Empty Library"))
        alert.addButton(withTitle: String(localized: "Quit"))
        guard alert.runModal() == .alertFirstButtonReturn else { exit(EXIT_SUCCESS) }

        do {
            let aside = try moveMemoirStoreAside()
            Logger(subsystem: "Memoir", category: "Store").notice("Moved the store aside to \(aside.path, privacy: .public)")
            return try memoirOnDisk()
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = String(localized: "Memoir can't create a new library")
            failure.informativeText = error.localizedDescription
            failure.addButton(withTitle: String(localized: "Quit"))
            failure.runModal()
            exit(EXIT_FAILURE)
        }
    }
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
