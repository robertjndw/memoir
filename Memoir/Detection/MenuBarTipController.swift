import AppKit
import SwiftUI

/// Shows a meeting suggestion as a small tip hanging from Memoir's menu bar icon.
///
/// The panel never activates Memoir and never becomes key, so the meeting app keeps focus
/// and keyboard input while the tip is up.
final class MenuBarTipController {
    private static let autoDismissDelay: TimeInterval = 15
    /// After the pointer leaves, at least this much time remains, so the tip does not vanish
    /// the instant the user moves away while still reading it.
    private static let minimumRemainingAfterHover: TimeInterval = 4
    /// Keeps the tip off the screen edge when the icon sits near it.
    private static let screenMargin: CGFloat = 8
    /// How far the tip drops in from when it appears.
    private static let dropDistance: CGFloat = 10

    private let model = MenuBarTipModel()
    private var panel: TipPanel?
    private var isPresented = false
    /// Bumped on every show and hide so a finishing animation of an older presentation does
    /// not order out a newer one.
    private var generation = 0
    private var dismissTask: Task<Void, Never>?
    private var dismissDeadline: Date?
    private var pausedRemaining: TimeInterval?

    init() {
        model.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
    }

    /// Returns false, showing nothing, when the menu bar icon cannot be found on screen.
    func show(_ suggestion: MeetingSuggestion, actions: MeetingHintActions) -> Bool {
        guard let anchor = Self.statusItemFrame() else {
            hide()
            return false
        }

        model.content = MenuBarTipContent(suggestion: suggestion, canMute: actions.muteApp != nil)
        model.onAccept = { [weak self] in
            actions.accept()
            self?.hide()
        }
        model.onClose = { [weak self] in
            actions.dismiss()
            self?.hide()
        }
        model.onMute = { [weak self] in
            actions.muteApp?()
            self?.hide()
        }

        generation += 1
        let panel = panel ?? makePanel()
        self.panel = panel
        let target = place(panel, under: anchor)

        if isPresented {
            panel.setFrame(target, display: true)
        } else {
            isPresented = true
            model.isHovered = false
            present(panel, at: target)
            announce()
        }
        pausedRemaining = nil
        startCountdown(Self.autoDismissDelay)
        return true
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        pausedRemaining = nil
        guard isPresented, let panel else { return }
        isPresented = false
        generation += 1
        let generation = generation

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !Self.reduceMotion {
                panel.animator().setFrame(Self.raised(panel.frame), display: true)
            }
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishHide(generation) }
        })
    }

    private func finishHide(_ generation: Int) {
        guard self.generation == generation else { return }
        panel?.orderOut(nil)
        model.content = nil
        model.isHovered = false
    }

    // MARK: - Placement

    /// The frame of Memoir's status item on screen.
    ///
    /// MenuBarExtra does not expose its NSStatusItem, but the item lives in a window of the
    /// private NSStatusBarWindow class that belongs to this app. With "Displays have separate
    /// Spaces" there is one per screen, so the one on the screen with the pointer wins, which
    /// is the menu bar the user is most likely looking at.
    private static func statusItemFrame() -> NSRect? {
        let candidates = NSApp.windows
            .filter { $0.className == "NSStatusBarWindow" && $0.isVisible && $0.frame.width > 0 }
            .map(\.frame)
            // macOS parks an item that does not fit off screen. Menu bar managers that hide
            // items can leave it on screen, and there is no way to tell from here.
            .filter { frame in NSScreen.screens.contains { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) } }
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        return candidates.first { mouseScreen?.frame.intersects($0) == true } ?? candidates.first
    }

    /// Centers the tip under the icon where it fits, and slides it inward near a screen edge.
    /// The arrow follows the icon either way.
    private func place(_ panel: TipPanel, under anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let bounds = screen?.frame ?? anchor
        let width = MenuBarTipView.width
        let minX = bounds.minX + Self.screenMargin
        let maxX = bounds.maxX - Self.screenMargin - width
        let x = min(max(anchor.midX - width / 2, minX), maxX)
        model.arrowX = anchor.midX - x

        panel.contentView?.layoutSubtreeIfNeeded()
        let height = panel.contentView?.fittingSize.height ?? 80
        // The arrow tip touches the bottom of the menu bar.
        return NSRect(x: x, y: anchor.minY - height, width: width, height: height)
    }

    // MARK: - Presentation

    private func present(_ panel: TipPanel, at target: NSRect) {
        panel.setFrame(Self.reduceMotion ? target : Self.raised(target), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reduceMotion ? 0.2 : 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        panel.invalidateShadow()
    }

    private func makePanel() -> TipPanel {
        let panel = TipPanel()
        let hosting = FirstMouseHostingView(rootView: MenuBarTipView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        return panel
    }

    private static func raised(_ frame: NSRect) -> NSRect {
        frame.offsetBy(dx: 0, dy: dropDistance)
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func announce() {
        guard let content = model.content else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(content.text.title). \(content.text.body)",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: - Auto-dismiss

    private func startCountdown(_ delay: TimeInterval) {
        dismissTask?.cancel()
        dismissDeadline = Date.now.addingTimeInterval(delay)
        let generation = generation
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            // Auto-dismiss is not a "no": the detector is not told, so no cooldown starts.
            hide()
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        guard isPresented else { return }
        if hovering {
            guard pausedRemaining == nil else { return }
            pausedRemaining = max(0, dismissDeadline?.timeIntervalSinceNow ?? Self.autoDismissDelay)
            dismissTask?.cancel()
            dismissTask = nil
        } else if let remaining = pausedRemaining {
            pausedRemaining = nil
            startCountdown(max(remaining, Self.minimumRemainingAfterHover))
        }
    }
}

private final class TipPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: MenuBarTipView.width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        // Above regular and floating windows, including full-screen apps' windows.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    // Buttons and the menu work without key status (see FirstMouseHostingView), and never
    // taking it means typing keeps going to the meeting app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel is never key, so without this the first click would only be swallowed.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Content

struct MenuBarTipContent: Equatable {
    var kind: MeetingSuggestion.Kind
    var text: MeetingNotificationText
    var bundleID: String?
    var primaryTitle: String
    /// Nil hides the "Don't Ask" option.
    var muteTitle: String?

    init(suggestion: MeetingSuggestion, canMute: Bool) {
        kind = suggestion.kind
        text = MeetingNotificationText(suggestion: suggestion)
        bundleID = suggestion.bundleID ?? (suggestion.event != nil ? "com.apple.iCal" : nil)
        primaryTitle = suggestion.kind == .start ? String(localized: "Record") : String(localized: "Stop Recording")
        muteTitle = canMute ? suggestion.appName.map { String(localized: "Don't Ask for \($0)") } : nil
    }
}

@Observable
final class MenuBarTipModel {
    var content: MenuBarTipContent?
    var isHovered = false
    /// Horizontal position of the icon's center, measured from the tip's leading edge.
    var arrowX: CGFloat = MenuBarTipView.width / 2
    @ObservationIgnored var onAccept: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onMute: () -> Void = {}
    @ObservationIgnored var onHoverChange: (Bool) -> Void = { _ in }
}

struct MenuBarTipView: View {
    static let width: CGFloat = 380

    let model: MenuBarTipModel

    var body: some View {
        if let content = model.content {
            tip(content)
        }
    }

    private func tip(_ content: MenuBarTipContent) -> some View {
        let shape = TipShape(arrowX: model.arrowX)
        return HStack(spacing: 10) {
            AppIcon(bundleID: content.bundleID)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(content.text.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(content.text.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            HStack(spacing: 4) {
                Button(action: model.onAccept) {
                    Text(content.primaryTitle)
                        .font(.system(size: 12, weight: .semibold))
                }
                // Not .glassProminent: the panel is never key, and system button styles in a
                // non-key window draw in their inactive look, which turns the red Record
                // button gray so it looks disabled. Overriding controlActiveState does not
                // reach them.
                .buttonStyle(TipPrimaryButtonStyle(tint: content.kind == .start ? .red : .accentColor))
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

                // Inside the card rather than hanging off a corner, so it is always visible
                // and always inside the tip's hit area.
                Button(action: model.onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
                .help(Text("Close"))
            }
            .fixedSize()
        }
        .padding(.top, 10 + TipShape.arrowSize.height)
        .padding(.bottom, 10)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(width: Self.width)
        .glassEffect(.regular, in: shape)
        .contentShape(shape)
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
        .accessibilityLabel(Text(content.text.title))
        .accessibilityAction(named: Text("Close"), model.onClose)
    }
}

private struct TipPrimaryButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1), in: .capsule)
            .contentShape(.capsule)
    }
}

/// A rounded card with an arrow on top pointing at the menu bar icon.
nonisolated struct TipShape: Shape {
    static let arrowSize = CGSize(width: 20, height: 8)
    static let cornerRadius: CGFloat = 18

    var arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        let arrow = Self.arrowSize
        let card = CGRect(x: rect.minX, y: rect.minY + arrow.height, width: rect.width, height: rect.height - arrow.height)
        // The arrow cannot sit on the rounded corners, so near an edge it stops where the
        // straight top edge ends.
        let inset = Self.cornerRadius + arrow.width / 2
        let x = rect.minX + min(max(arrowX, inset), rect.width - inset)

        var pointer = Path()
        // Overlaps the card a little so the union has no hairline seam.
        pointer.move(to: CGPoint(x: x - arrow.width / 2, y: card.minY + 1))
        pointer.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x - arrow.width / 4, y: card.minY))
        pointer.addQuadCurve(to: CGPoint(x: x + arrow.width / 2, y: card.minY + 1), control: CGPoint(x: x + arrow.width / 4, y: card.minY))
        pointer.closeSubpath()

        return Path(roundedRect: card, cornerRadius: Self.cornerRadius, style: .continuous).union(pointer)
    }
}

private struct AppIcon: View {
    let bundleID: String?

    var body: some View {
        Group {
            if let bundleID,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(width: 30, height: 30)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            }
        }
        .frame(width: 32, height: 32)
    }
}

#Preview("Menu bar tips") {
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
        MeetingSuggestion(kind: .start, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
        MeetingSuggestion(kind: .start, appName: "Zoom", bundleID: "us.zoom.xos", event: event),
        MeetingSuggestion(kind: .start, event: event),
        MeetingSuggestion(kind: .stop, appName: "Microsoft Teams", bundleID: "com.microsoft.teams2"),
    ]
    let models = suggestions.enumerated().map { index, suggestion in
        let model = MenuBarTipModel()
        model.content = MenuBarTipContent(suggestion: suggestion, canMute: suggestion.bundleID != nil)
        model.arrowX = [MenuBarTipView.width / 2, 60, MenuBarTipView.width - 30, 0][index]
        return model
    }
    VStack(spacing: 8) {
        ForEach(models.indices, id: \.self) { index in
            MenuBarTipView(model: models[index])
        }
    }
    .padding()
    .background(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
}
