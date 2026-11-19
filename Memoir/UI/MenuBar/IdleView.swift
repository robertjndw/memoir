import AppKit
import SwiftData
import SwiftUI

struct IdleView: View {
    @Environment(AppModel.self) private var model

    /// How long a finished recording stays in the menu.
    private static let handoffWindow: TimeInterval = 30 * 60

    private var justRecorded: Meeting? {
        guard let last = model.lastRecording,
              Date.now.timeIntervalSince(last.date) < Self.handoffWindow
        else { return nil }
        return model.meeting(with: last.meetingID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let meeting = justRecorded {
                JustRecordedCard(meeting: meeting)
                    .transition(.blurReplace)
            }

            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Start recording")

            if let upcoming = model.upcomingMeeting {
                VStack(alignment: .leading, spacing: 6) {
                    MenuSectionHeader("Up Next")
                    UpNextCard(event: upcoming)
                }
                .transition(.blurReplace)
            }

            if model.intelligenceAvailability == .available {
                AskMemoirRow()
            }

            RecentMeetings()
        }
        .animation(.smooth(duration: 0.3), value: model.lastRecording)
        .animation(.smooth(duration: 0.3), value: model.upcomingMeeting)
    }
}

private struct MenuCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Just recorded

/// Shown after a recording stops. With auto-summarize on, the summary streams in here.
struct JustRecordedCard: View {
    let meeting: Meeting

    @Environment(AppModel.self) private var model
    @State private var isHovered = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var activity: AppModel.SummaryActivity? { model.summaryActivity[meeting.id] }
    private var isSummarizing: Bool { activity?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MeetingIcon(bundleID: meeting.sourceAppBundleID, size: 34)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .background(.background, in: .circle)
                            .offset(x: 3, y: 3)
                            .accessibilityHidden(true)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title)
                        .font(.headline)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Open") {
                    model.openLibrary(selecting: meeting.id)
                    model.dismissLastRecording()
                }
                .buttonStyle(.glass)
                .accessibilityHint("Opens the meeting in the Library")
            }

            summary
        }
        .modifier(MenuCard())
        .intelligenceGlow(isActive: isSummarizing, cornerRadius: 14)
        .overlay(alignment: .topLeading) {
            Button(action: model.dismissLastRecording) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .offset(x: -6, y: -6)
            .opacity(isHovered || voiceOverEnabled ? 1 : 0)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.smooth(duration: 0.35), value: isSummarizing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording saved: \(meeting.title)")
    }

    private var details: String {
        var parts = [String(localized: "Saved")]
        if meeting.duration > 0 { parts.append(LibraryFormat.length(meeting.duration)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var summary: some View {
        if isSummarizing {
            if let overview = activity?.draft?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.callout)
                    .lineLimit(3)
                    .transition(.blurReplace)
            } else {
                IntelligenceActivity("Summarizing...")
                    .font(.callout)
                    .transition(.blurReplace)
            }
        } else if let overview = meeting.summary?.overview, !overview.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(IntelligencePalette.linear)
                    .accessibilityHidden(true)
                Text(overview)
                    .lineLimit(3)
            }
            .font(.callout)
            .transition(.blurReplace)
        }
    }
}

// MARK: - Up next

struct UpNextCard: View {
    let event: CalendarMeeting

    @Environment(AppModel.self) private var model

    private var joinApp: String? { event.joinURL.flatMap(JoinApp.bundleID(for:)) }
    private var service: String? { event.joinURL.flatMap(MeetingLinkParser.service(for:))?.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MeetingIcon(bundleID: joinApp ?? "com.apple.iCal", size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.headline)
                        .lineLimit(1)
                    TimelineView(.everyMinute) { context in
                        Text(subtitle(now: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 8) {
                if !event.attendees.isEmpty {
                    AvatarStack(names: event.attendees, size: 20, limit: 3)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                if let url = event.joinURL {
                    Button("Join") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.glass)
                        .accessibilityHint(service.map { Text("Opens the meeting in \($0)") } ?? Text("Opens the meeting link"))
                }
                Button {
                    Task { await model.startRecording(event: event, appName: service, bundleID: joinApp) }
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .accessibilityHint("Starts recording now, titled after this event")
            }
        }
        .modifier(MenuCard())
        .accessibilityElement(children: .contain)
    }

    private func subtitle(now: Date) -> String {
        let when = Self.relative(event.start, now: now)
        let people = event.attendees.isEmpty ? nil : String(localized: "\(event.attendees.count) people")
        return [when, service, people].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    static func relative(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return String(localized: "Now") }
        if minutes < 60 { return String(localized: "In \(minutes) min") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? String(localized: "In \(hours) hr") : String(localized: "In \(hours) hr \(rest) min")
    }
}

/// The app that would open the join link: Zoom for a Zoom link if it's installed, otherwise
/// the browser.
enum JoinApp {
    static func bundleID(for url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
}

// MARK: - Ask

/// A row that expands into a text field. An always-visible field could take focus when the
/// menu opens and swallow Return, which should start a recording.
struct AskMemoirRow: View {
    @Environment(AppModel.self) private var model
    @State private var isAsking = false
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isAsking {
                field.transition(.blurReplace)
            } else {
                row.transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.3), value: isAsking)
    }

    private var row: some View {
        Button { isAsking = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(IntelligencePalette.linear)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text("Ask Memoir")
                Spacer()
            }
        }
        .buttonStyle(MenuRowStyle())
        .keyboardShortcut("k", modifiers: .command)
        .help("Ask a question about your meetings (Command-K)")
        .accessibilityHint("Ask a question about your meetings")
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(IntelligencePalette.linear)
                .accessibilityHidden(true)
            TextField("Ask about your meetings", text: $question)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { isAsking = false }
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help("Ask")
            .accessibilityLabel("Ask")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .intelligenceGlow(isActive: true, cornerRadius: 18)
        .onAppear { focused = true }
        .onChange(of: focused) { _, focused in
            // Collapse again when an empty field loses focus.
            if !focused, question.isEmpty { isAsking = false }
        }
    }

    private var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        model.ask(question)
        question = ""
        isAsking = false
    }
}

// MARK: - Recent

struct RecentMeetings: View {
    @Environment(AppModel.self) private var model
    @Query private var meetings: [Meeting]

    init() {
        var descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 4
        _meetings = Query(descriptor)
    }

    /// Skips the meeting in the just-recorded card and the one being recorded.
    private var shown: [Meeting] {
        meetings.filter { $0.id != model.lastRecording?.meetingID && $0.id != model.recordingMeetingID }.prefix(3).map { $0 }
    }

    var body: some View {
        if meetings.isEmpty || !shown.isEmpty {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                MenuSectionHeader("Recent")
                Spacer()
                if !meetings.isEmpty {
                    Button("Show All") { model.openLibrary() }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                        .keyboardShortcut("l", modifiers: .command)
                        .help("Open the Library (Command-L)")
                        .accessibilityLabel("Show all meetings in the Library")
                }
            }

            if meetings.isEmpty {
                Text("Your recordings will appear here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { meeting in
                        RecentRow(
                            title: meeting.title,
                            bundleID: meeting.sourceAppBundleID,
                            date: meeting.startDate,
                            duration: meeting.duration,
                            hasSummary: meeting.summary != nil
                        ) {
                            model.openLibrary(selecting: meeting.id)
                        }
                    }
                }
            }
        }
    }
}

struct RecentRow: View {
    let title: String
    let bundleID: String?
    let date: Date
    let duration: TimeInterval
    var hasSummary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MeetingIcon(bundleID: bundleID, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        if hasSummary {
                            Image(systemName: "sparkles")
                                .foregroundStyle(IntelligencePalette.linear)
                                .help("Summarized")
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinute : .minuteSecond)))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityLabel("\(title), \(date.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityHint("Opens in Library")
    }
}

#if DEBUG
private extension CalendarMeeting {
    static let preview = CalendarMeeting(
        id: "preview",
        title: "Weekly Design Review",
        start: .now.addingTimeInterval(25 * 60),
        end: .now.addingTimeInterval(55 * 60),
        attendees: ["Maya Chen", "Jonas Weber", "Ana Ortiz", "Ben Lee"],
        joinURL: URL(string: "facetime://maya@example.com")
    )
}

#Preview("Idle with meetings") {
    @Previewable @State var model = AppModel.preview(hasCompletedOnboarding: true, samples: true) {
        $0.simulateUpcoming(.preview)
    }
    MenuBarView()
        .environment(model)
        .modelContainer(model.container)
}

#Preview("Just recorded, summarizing") {
    @Previewable @State var model = AppModel.preview(hasCompletedOnboarding: true, samples: true) {
        $0.simulateFinished($0.previewMeeting("Call at 9:15 AM"), summarizing: true)
    }
    MenuBarView()
        .environment(model)
        .modelContainer(model.container)
}

#Preview("Just recorded, summarized") {
    @Previewable @State var model = AppModel.preview(hasCompletedOnboarding: true, samples: true) {
        $0.simulateFinished($0.previewMeeting("Design Review"))
        $0.simulateUpcoming(.preview)
    }
    MenuBarView()
        .environment(model)
        .modelContainer(model.container)
}
#endif

#Preview("Rows") {
    VStack(alignment: .leading, spacing: 10) {
        RecentRow(title: "Design Review", bundleID: "com.apple.FaceTime", date: .now.addingTimeInterval(-3 * 3600), duration: 42 * 60, hasSummary: true) {}
        RecentRow(title: "All Hands", bundleID: nil, date: .now.addingTimeInterval(-86400), duration: 75 * 60) {}
    }
    .padding()
    .frame(width: 320)
}
