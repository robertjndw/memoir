import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Int, CaseIterable {
        case welcome, microphone, systemAudio, calendar, notifications, speech, ready
    }

    @State private var step = Step.welcome
    @State private var goingForward = true
    @State private var permissions = Permissions()
    @State private var speech = SpeechModelController()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .id(step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 560, height: 620)
        // A granted permission swaps its button for the checkmark instead of popping in.
        .animation(.smooth(duration: 0.3), value: permissions.microphone)
        .animation(.smooth(duration: 0.3), value: permissions.calendarGranted)
        .animation(.smooth(duration: 0.3), value: permissions.calendarRefused)
        .animation(.smooth(duration: 0.3), value: permissions.notifications)
        .animation(.smooth(duration: 0.3), value: speech.status)
        .sensoryFeedback(.success, trigger: grantedCount)
        .task {
            permissions.bind(calendar: model.services.calendar)
        }
        .task(id: model.settings.localeIdentifier) {
            await speech.refresh(locale: model.settings.transcriptionLocale, using: model.services.speechModels)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    /// Counts up as permissions are granted and the model finishes installing.
    private var grantedCount: Int {
        [permissions.microphone == .granted, permissions.calendarGranted, permissions.notifications == .granted, speech.status == .installed]
            .count { $0 }
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let edge: Edge = goingForward ? .trailing : .leading
        let opposite: Edge = goingForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: opposite).combined(with: .opacity)
        )
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        goingForward = delta > 0
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            step = next
        }
    }

    // MARK: - Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            StepLayout(
                hero: { AppIconHero() },
                title: "Welcome to Memoir",
                message: "Meeting notes without the note-taking."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    point("person.2.wave.2.fill", "Records both sides", "Your microphone and the other participants, kept as separate voices.")
                    point("text.quote", "Transcribes and summarizes on this Mac", "Apple's on-device speech and language models do the work.")
                    point("lock.shield.fill", "Nothing leaves your device", "No accounts, no servers, no uploads.")
                }
            }

        case .microphone:
            StepLayout(
                symbol: "mic.fill",
                title: "Your Microphone",
                message: "Memoir needs the microphone to capture what you say in a meeting."
            ) {
                switch permissions.microphone {
                case .granted:
                    GrantedBadge(text: "Microphone access allowed")
                case .notDetermined:
                    Button("Allow Microphone Access") { Task { await permissions.requestMicrophone() } }
                        .controlSize(.large)
                case .denied:
                    VStack(spacing: 10) {
                        Text("Access is turned off. You can allow it in System Settings.")
                            .foregroundStyle(.secondary)
                        Button("Open System Settings") { Permissions.open(.microphone) }
                            .controlSize(.large)
                    }
                }
            }

        case .systemAudio:
            StepLayout(
                symbol: "speaker.wave.3.fill",
                title: "Other People's Voices",
                message: "To hear the other participants, Memoir records the audio playing on your Mac."
            ) {
                VStack(spacing: 10) {
                    Text("macOS will ask for permission to record system audio the first time you start a recording. You can review it later in Privacy & Security.")
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") { Permissions.open(.systemAudio) }
                        .buttonStyle(.link)
                }
            }

        case .calendar:
            StepLayout(
                symbol: "calendar",
                title: "Your Calendar",
                message: "Optional. With calendar access, Memoir can suggest recording when a meeting starts and name the recording after the event."
            ) {
                if permissions.calendarGranted {
                    GrantedBadge(text: "Calendar access allowed")
                } else if permissions.calendarRefused {
                    VStack(spacing: 10) {
                        Text("Access is turned off. You can allow it in System Settings, or skip this step.")
                            .foregroundStyle(.secondary)
                        Button("Open System Settings") { Permissions.open(.calendars) }
                            .controlSize(.large)
                    }
                } else {
                    Button("Allow Calendar Access") { Task { await permissions.requestCalendar() } }
                        .controlSize(.large)
                }
            }

        case .notifications:
            StepLayout(
                symbol: "bell.badge.fill",
                title: "Meeting Suggestions",
                message: "Memoir suggests recording when a call starts, with a notification you can answer with one click."
            ) {
                switch permissions.notifications {
                case .granted:
                    GrantedBadge(text: "Notifications allowed")
                case .notDetermined:
                    Button("Allow Notifications") { Task { await permissions.requestNotifications() } }
                        .controlSize(.large)
                case .denied:
                    VStack(spacing: 10) {
                        Text("Notifications are turned off. You can allow them in System Settings, or show suggestions under the menu bar icon instead in Settings > Detection.")
                            .foregroundStyle(.secondary)
                        Button("Open System Settings") { Permissions.openNotifications() }
                            .controlSize(.large)
                    }
                }
            }

        case .speech:
            StepLayout(
                symbol: "character.bubble.fill",
                title: "Speech Model",
                message: "Transcription uses a language model that is stored on this Mac."
            ) {
                speechContent
            }

        case .ready:
            StepLayout(
                symbol: "checkmark.circle.fill",
                title: "You're Ready",
                message: "Memoir lives in the menu bar. Click its icon to start a recording or open your library."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    point("sparkles", "Apple Intelligence", intelligenceLine)
                    point("person.wave.2.fill", "Tell people they are being recorded", "Laws on recording consent vary, so let participants know.")
                }
            }
        }
    }

    @ViewBuilder private var speechContent: some View {
        let locale = model.settings.transcriptionLocale
        VStack(spacing: 10) {
            Text(localizedName(of: locale))
                .font(.headline)
            switch speech.status {
            case nil:
                ProgressView().controlSize(.small)
            case .installed:
                GrantedBadge(text: "Ready for transcription")
            case .unsupported:
                Text("This language is not supported for on-device transcription. You can pick another in Settings later.")
                    .foregroundStyle(.secondary)
            case .downloading:
                VStack(spacing: 6) {
                    if let progress = speech.progress {
                        ProgressView(value: progress)
                            .frame(width: 220)
                            .accessibilityLabel("Download progress")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Downloading. You can continue while this finishes.")
                        .foregroundStyle(.secondary)
                }
            case .notInstalled:
                Button("Download Speech Model") {
                    speech.download(locale: locale, using: model.services.speechModels)
                }
                .controlSize(.large)
            }
            if let failure = speech.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var intelligenceLine: String {
        switch model.intelligenceAvailability {
        case .available: "Available. Summaries and chat run on this Mac."
        case .appleIntelligenceNotEnabled: "Turned off. Enable it in System Settings to get summaries."
        case .modelNotReady: "Still preparing. Summaries will work once it finishes."
        case .deviceNotEligible: "Not supported on this Mac. Recording and transcripts still work."
        }
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // StepLayout centers its detail text, which would center wrapped lines here.
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: String) -> some View {
        point(symbol, title, LocalizedStringResource(stringLiteral: detail))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Back") { go(-1) }
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)

            Spacer()
            PageDots(count: Step.allCases.count, current: step.rawValue)
            Spacer()

            if (step == .calendar && !permissions.calendarGranted)
                || (step == .notifications && permissions.notifications != .granted) {
                Button("Not Now") { go(1) }
            }
            if step == .ready {
                Button("Start Using Memoir", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { go(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private func finish() {
        model.settings.hasCompletedOnboarding = true
        model.refresh()
        dismissWindow(id: AppModel.WindowID.onboarding)
    }
}

// MARK: - Pieces

private struct StepLayout<Hero: View, Body: View>: View {
    let hero: Hero
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let detail: Body

    init(
        hero: () -> Hero,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        @ViewBuilder detail: () -> Body
    ) {
        self.hero = hero()
        self.title = title
        self.message = message
        self.detail = detail()
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            hero
                .padding(.bottom, 8)
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            detail
                .padding(.top, 10)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: .infinity)
    }
}

extension StepLayout where Hero == SymbolHero {
    init(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        @ViewBuilder detail: () -> Body
    ) {
        self.init(hero: { SymbolHero(name: symbol) }, title: title, message: message, detail: detail)
    }
}

private struct SymbolHero: View {
    let name: String
    @ScaledMetric private var size = 64.0
    @State private var appeared = false

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            // One bounce as the step slides in. Symbol effects already respect Reduce Motion.
            .symbolEffect(.bounce, value: appeared)
            .frame(height: size * 1.3)
            .accessibilityHidden(true)
            .onAppear { appeared = true }
    }
}

private struct AppIconHero: View {
    @ScaledMetric private var size = 96.0

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct GrantedBadge: View {
    let text: LocalizedStringKey

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(.green)
            .transition(.blurReplace)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: index == current ? 18 : 7, height: 7)
            }
        }
        .animation(.snappy(duration: 0.3), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

#if DEBUG
#Preview("Onboarding") {
    @Previewable @State var model = AppModel.preview()
    OnboardingView()
        .environment(model)
}
#endif
