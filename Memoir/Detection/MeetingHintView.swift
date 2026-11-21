import AppKit
import SwiftUI

/// What the hint shows, derived from a suggestion. Separate from the view so the wording
/// rules stay in one place.
struct MeetingHintContent: Equatable {
    enum Icon: Equatable {
        case app(bundleID: String)
        case calendar
        case recording
    }

    var kind: MeetingSuggestion.Kind
    var icon: Icon
    var title: String
    var subtitle: String
    var primaryTitle: String
    /// Nil hides the "Don't Ask" option.
    var muteTitle: String?

    init(suggestion: MeetingSuggestion, canMute: Bool) {
        kind = suggestion.kind
        let appName = suggestion.appName
        let isBrowser = suggestion.bundleID.flatMap(MeetingApps.app(forBundleID:))?.category == .browser
        muteTitle = canMute ? appName.map { String(localized: "Don't Ask for \($0)") } : nil

        switch suggestion.kind {
        case .stop:
            icon = suggestion.bundleID.map { .app(bundleID: $0) } ?? .recording
            title = String(localized: "Meeting ended?")
            subtitle = appName.map { String(localized: "\($0) stopped using the microphone") }
                ?? String(localized: "The call seems to be over")
            primaryTitle = String(localized: "Stop Recording")

        case .start:
            primaryTitle = String(localized: "Record")
            if let event = suggestion.event {
                icon = suggestion.bundleID.map { .app(bundleID: $0) } ?? .calendar
                title = event.title
                let start = event.start.formatted(date: .omitted, time: .shortened)
                let end = event.end.formatted(date: .omitted, time: .shortened)
                let time = String(localized: "\(start) to \(end)")
                subtitle = appName.map { "\($0) · \(time)" } ?? time
            } else if let appName {
                icon = suggestion.bundleID.map { .app(bundleID: $0) } ?? .recording
                title = isBrowser
                    ? String(localized: "Meeting detected in \(appName)")
                    : String(localized: "\(appName) meeting detected")
                subtitle = String(localized: "Record and transcribe on this Mac")
            } else {
                icon = .recording
                title = String(localized: "Meeting detected")
                subtitle = String(localized: "Record and transcribe on this Mac")
            }
        }
    }
}

/// State shared between the panel controller and the SwiftUI content.
@Observable
final class MeetingHintModel {
    var content: MeetingHintContent?
    var isHovered = false
    @ObservationIgnored var onAccept: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onMute: () -> Void = {}
    @ObservationIgnored var onHoverChange: (Bool) -> Void = { _ in }
}

struct MeetingHintView: View {
    /// Room around the card for the close button, which overlaps the corner like the one on
    /// system notifications.
    static let outerInset: CGFloat = 8
    static let cardWidth: CGFloat = 356
    static let cornerRadius: CGFloat = 22

    let model: MeetingHintModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        if let content = model.content {
            card(content)
                .padding(Self.outerInset)
        }
    }

    private func card(_ content: MeetingHintContent) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 12) {
                HintIcon(icon: content.icon)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(content.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                HStack(spacing: 6) {
                    Button(action: model.onAccept) {
                        Text(content.primaryTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 2)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(content.kind == .start ? .red : nil)
                    .controlSize(.regular)
                    .accessibilityHint(content.kind == .start
                        ? Text("Starts recording and transcribing this meeting on this Mac")
                        : Text("Stops the recording and saves the transcript"))

                    if let muteTitle = content.muteTitle {
                        Menu {
                            Button(muteTitle, action: model.onMute)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .fixedSize()
                        .accessibilityLabel(Text("More Options"))
                    }
                }
                .fixedSize()
            }
            .padding(.vertical, 11)
            .padding(.leading, 11)
            .padding(.trailing, 12)
            .frame(width: Self.cardWidth)
            .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        }
        .overlay(alignment: .topLeading) {
            closeButton
                .offset(x: -Self.outerInset + 2, y: -Self.outerInset + 2)
                .opacity(model.isHovered || voiceOverEnabled ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: model.isHovered)
        }
        .contentShape(.rect(cornerRadius: Self.cornerRadius))
        .onHover { hovering in
            model.isHovered = hovering
            model.onHoverChange(hovering)
        }
        .contextMenu {
            if let muteTitle = content.muteTitle {
                Button(muteTitle, action: model.onMute)
                Divider()
            }
            Button("Close", action: model.onClose)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(content.title))
        .accessibilityAction(named: Text("Close"), model.onClose)
    }

    private var closeButton: some View {
        Button(action: model.onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close"))
        .help(Text("Close"))
    }
}

private struct HintIcon: View {
    let icon: MeetingHintContent.Icon

    var body: some View {
        Group {
            switch icon {
            case .app(let bundleID):
                if let image = Self.appIcon(bundleID) {
                    Image(nsImage: image).resizable()
                } else {
                    glyph("video.fill", color: .accentColor)
                }
            case .calendar:
                if let image = Self.appIcon("com.apple.iCal") {
                    Image(nsImage: image).resizable()
                } else {
                    glyph("calendar", color: .red)
                }
            case .recording:
                glyph("waveform", color: .red)
            }
        }
        .frame(width: 38, height: 38)
    }

    private func glyph(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(.fill.tertiary, in: .rect(cornerRadius: 9))
    }

    private static func appIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }
}

#Preview("Hints") {
    let start = Date.now.addingTimeInterval(-60)
    let event = CalendarMeeting(
        id: "preview",
        title: "Weekly Design Review",
        start: start,
        end: start.addingTimeInterval(1800),
        attendees: ["Ana", "Ben"],
        joinURL: nil
    )
    let suggestions = [
        MeetingSuggestion(kind: .start, appName: "Zoom", bundleID: "us.zoom.xos"),
        MeetingSuggestion(kind: .start, appName: "Zoom", bundleID: "us.zoom.xos", event: event),
        MeetingSuggestion(kind: .start, event: event),
        MeetingSuggestion(kind: .start, appName: "Google Chrome", bundleID: "com.google.Chrome"),
        MeetingSuggestion(kind: .stop, appName: "Microsoft Teams", bundleID: "com.microsoft.teams2"),
    ]
    let models = suggestions.map { suggestion in
        let model = MeetingHintModel()
        model.content = MeetingHintContent(suggestion: suggestion, canMute: suggestion.bundleID != nil)
        return model
    }
    VStack(spacing: 4) {
        ForEach(models.indices, id: \.self) { index in
            MeetingHintView(model: models[index])
        }
    }
    .padding()
    .background(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
}
