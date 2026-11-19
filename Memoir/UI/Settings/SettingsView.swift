import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var permissions = Permissions()

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralPane()
            }
            Tab("Detection", systemImage: "dot.radiowaves.left.and.right") {
                DetectionPane(permissions: permissions)
            }
            Tab("Intelligence", systemImage: "sparkles") {
                IntelligencePane()
            }
            Tab("AI Assistants", systemImage: "point.3.connected.trianglepath.dotted") {
                AIAssistantsPane()
            }
            Tab("Privacy", systemImage: "hand.raised") {
                PrivacyPane(permissions: permissions)
            }
        }
        .scenePadding()
        .frame(width: 560)
        .task {
            permissions.bind(calendar: model.services.calendar)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
            model.refresh()
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var locales: [Locale] = []
    @State private var speech = SpeechModelController()
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Open Memoir at login", isOn: loginBinding)
                if loginStatus == .requiresApproval {
                    LabeledContent("Memoir needs your approval in Login Items.") {
                        Button("Open Login Items Settings") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Memoir starts in the menu bar so it can notice meetings.")
            }

            Section {
                Picker("Language", selection: $settings.localeIdentifier) {
                    Text("System Language").tag("")
                    Divider()
                    ForEach(languageChoices, id: \.identifier) { locale in
                        Text(localizedName(of: locale)).tag(locale.identifier)
                    }
                }
                LabeledContent("Speech model") {
                    ModelStatusView(
                        controller: speech,
                        download: { speech.download(locale: model.settings.transcriptionLocale, using: model.services.speechModels) }
                    )
                }
            } header: {
                Text("Transcription")
            } footer: {
                Text("Transcription runs entirely on this Mac. Audio is never sent anywhere.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            locales = await model.services.speechModels.supportedLocales()
                .sorted { localizedName(of: $0).localizedStandardCompare(localizedName(of: $1)) == .orderedAscending }
        }
        .task(id: settings.localeIdentifier) {
            await speech.refresh(locale: model.settings.transcriptionLocale, using: model.services.speechModels)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    /// Keeps a previously chosen language selectable even if it is missing from the list.
    private var languageChoices: [Locale] {
        let current = model.settings.localeIdentifier
        guard !current.isEmpty, !locales.contains(where: { $0.identifier == current }) else { return locales }
        return locales + [Locale(identifier: current)]
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { enable in
                loginError = nil
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    loginError = error.localizedDescription
                }
                loginStatus = SMAppService.mainApp.status
            }
        )
    }
}

private struct ModelStatusView: View {
    let controller: SpeechModelController
    let download: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch controller.status {
            case nil:
                ProgressView().controlSize(.small)
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .unsupported:
                Label("Not supported", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .downloading:
                if let progress = controller.progress {
                    ProgressView(value: progress)
                        .frame(width: 100)
                        .accessibilityLabel("Download progress")
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Downloading")
                    .foregroundStyle(.secondary)
            case .notInstalled:
                Text("Not downloaded")
                    .foregroundStyle(.secondary)
                Button("Download", action: download)
            }
        }
        .help(controller.failure ?? "")
        if let failure = controller.failure {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Detection

private struct DetectionPane: View {
    @Environment(AppModel.self) private var model
    let permissions: Permissions

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Suggest recording when") {
                toggle(
                    "A meeting app uses the microphone",
                    detail: "Zoom, Teams, FaceTime and similar apps start a call.",
                    isOn: $settings.detectMicrophoneApps
                )
                toggle(
                    "A calendar meeting starts",
                    detail: "Uses events with a call link or other attendees.",
                    isOn: $settings.detectCalendar
                )
                if settings.detectCalendar && !permissions.calendarGranted {
                    CalendarAccessRow(permissions: permissions)
                }
                toggle(
                    "The camera turns on",
                    detail: "A camera in use often means a video call.",
                    isOn: $settings.detectCamera
                )
            }

            Section {
                toggle(
                    "Suggest stopping when the call ends",
                    detail: "Memoir offers to stop when the meeting app releases the microphone.",
                    isOn: $settings.suggestStopping
                )
            }

            Section {
                if settings.mutedBundleIDs.isEmpty {
                    Text("No apps are muted. Choosing \"Don't ask for this app\" in a suggestion adds it here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.mutedBundleIDs.sorted(), id: \.self) { bundleID in
                        MutedAppRow(bundleID: bundleID) {
                            settings.mutedBundleIDs.remove(bundleID)
                        }
                    }
                }
            } header: {
                Text("Muted apps")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toggle(_ title: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(detail)
        }
    }
}

private struct CalendarAccessRow: View {
    let permissions: Permissions

    var body: some View {
        LabeledContent {
            if permissions.calendarRefused {
                Button("Open Settings") { Permissions.open(.calendars) }
            } else {
                Button("Grant Access") { Task { await permissions.requestCalendar() } }
            }
        } label: {
            Label("Calendar access is off", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

private struct MutedAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let app = AppInfo(bundleID: bundleID)
        LabeledContent {
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Ask about this app again")
            .accessibilityLabel("Remove \(app.name)")
        } label: {
            Label {
                Text(app.name)
            } icon: {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
        }
    }
}

private struct AppInfo {
    let name: String
    let icon: NSImage

    init(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
                .replacing(/\.app$/, with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            name = bundleID
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }
}

// MARK: - Intelligence

private struct IntelligencePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: $settings.autoSummarize) {
                    Text("Summarize meetings automatically")
                    Text("Creates a title, overview, decisions and action items when a recording ends.")
                }
            }

            Section {
                LabeledContent("Apple Intelligence") {
                    statusLabel
                }
                if model.intelligenceAvailability == .appleIntelligenceNotEnabled {
                    Button("Open Apple Intelligence Settings") {
                        Permissions.openSystemSettings("com.apple.Siri-Settings.extension")
                    }
                }
            } footer: {
                Text("Summaries and chat run on this Mac with Apple Intelligence. Your meetings are not sent to a server.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var statusLabel: some View {
        switch model.intelligenceAvailability {
        case .available:
            Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .appleIntelligenceNotEnabled:
            Label("Turned off", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .modelNotReady:
            Label("Still preparing", systemImage: "clock.fill").foregroundStyle(.secondary)
        case .deviceNotEligible:
            Label("Not supported on this Mac", systemImage: "xmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}

// MARK: - AI Assistants

private struct AIAssistantsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Allow AI assistants to read your meetings", isOn: $settings.mcpEnabled)
            } footer: {
                Text("Lets Claude and other assistants search and read your meetings, summaries and transcripts. Anything they read is sent to the assistant's provider. They can't change anything.")
            }

            if settings.mcpEnabled {
                Section("Status") {
                    statusRow
                    clientRows
                }

                Section {
                    CommandRow(text: claudeCodeCommand)
                } header: {
                    Text("Claude Code")
                } footer: {
                    Text("Run this command in a terminal.")
                }

                Section {
                    LabeledContent {
                        CopyButton(text: claudeDesktopSnippet)
                    } label: {
                        Text("Configuration snippet")
                        Text("Paste it into claude_desktop_config.json (merge with any existing mcpServers) and restart Claude Desktop.")
                    }
                    if FileManager.default.fileExists(atPath: Self.claudeDesktopFolder.path) {
                        Button("Show Config Folder in Finder") {
                            NSWorkspace.shared.open(Self.claudeDesktopFolder)
                        }
                    }
                } header: {
                    Text("Claude Desktop")
                } footer: {
                    Text("~/Library/Application Support/Claude/claude_desktop_config.json")
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var statusRow: some View {
        let server = model.mcpServer
        if let error = server.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if server.isListening {
            Label("Running", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Starting", systemImage: "clock.fill")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var clientRows: some View {
        let clients = model.mcpServer.clients
        if clients.isEmpty {
            Text("No assistants connected")
                .foregroundStyle(.secondary)
        } else {
            ForEach(clients) { client in
                LabeledContent {
                    Text("connected \(client.connectedAt, style: .relative) ago")
                        .foregroundStyle(.secondary)
                } label: {
                    Text(client.name)
                }
            }
        }
    }

    private static var claudeDesktopFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Claude", directoryHint: .isDirectory)
    }

    private var bridgePath: String { MCPServer.bridgeURL.path }

    /// Quoted because the app may live in a folder with spaces in its name.
    private var claudeCodeCommand: String {
        let quoted = bridgePath.contains(/[^A-Za-z0-9_\/.\-+@%:,=~]/)
            ? "'" + bridgePath.replacing("'", with: "'\\''") + "'"
            : bridgePath
        return "claude mcp add --scope user memoir -- \(quoted)"
    }

    private var claudeDesktopSnippet: String {
        let config = ["mcpServers": ["memoir": ["command": bridgePath]]]
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: options) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct CommandRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text)
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    let permissions: Permissions

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Microphone",
                    detail: "Records your side of the conversation.",
                    state: permissions.microphone == .granted ? .granted : (permissions.microphone == .denied ? .denied : .notDetermined),
                    request: { Task { await permissions.requestMicrophone() } },
                    openSettings: { Permissions.open(.microphone) }
                )

                LabeledContent {
                    Button("Open Settings") { Permissions.open(.systemAudio) }
                } label: {
                    Text("System Audio Recording")
                    Text("Records the other participants. macOS asks the first time you record, and does not let apps check the answer. Review it in Privacy & Security.")
                }

                PermissionRow(
                    title: "Calendars",
                    detail: "Suggests recording when meetings start and names recordings.",
                    state: permissions.calendarGranted ? .granted : (permissions.calendarRefused ? .denied : .notDetermined),
                    request: { Task { await permissions.requestCalendar() } },
                    openSettings: { Permissions.open(.calendars) }
                )
            } header: {
                Text("Permissions")
            }

            Section {
                LabeledContent {
                    Button("Show in Finder") {
                        let url = RecordingFiles.baseDirectory
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Text("Recordings and transcripts")
                    Text(abbreviatedPath)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Storage")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var abbreviatedPath: String {
        (RecordingFiles.baseDirectory.path as NSString).abbreviatingWithTildeInPath
    }
}

private struct PermissionRow: View {
    enum Status {
        case notDetermined, granted, denied
    }

    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let state: Status
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        LabeledContent {
            switch state {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined:
                Button("Request Access", action: request)
            case .denied:
                Button("Open Settings", action: openSettings)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

#if DEBUG
#Preview("Settings") {
    @Previewable @State var model = AppModel.preview()
    SettingsView()
        .environment(model)
}

#Preview("AI Assistants") {
    @Previewable @State var model: AppModel = {
        let model = AppModel.preview()
        model.settings.mcpEnabled = true
        return model
    }()
    AIAssistantsPane()
        .environment(model)
        .frame(width: 560)
}
#endif
