import AppKit
import SwiftUI

/// Presents the meeting hint as a notification-style banner under the menu bar.
///
/// The panel never activates Memoir and never becomes key, so the meeting app keeps focus
/// and keyboard input while the hint is up.
final class MeetingHintPanelController: MeetingHintPresenting {
    private static let autoDismissDelay: TimeInterval = 15
    /// After the pointer leaves, at least this much time remains, so the hint does not vanish
    /// the instant the user moves away while still reading it.
    private static let minimumRemainingAfterHover: TimeInterval = 4
    private static let screenMargin = CGSize(width: 12, height: 8)

    private let model = MeetingHintModel()
    private var panel: HintPanel?
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

    func show(_ suggestion: MeetingSuggestion, actions: MeetingHintActions) {
        model.content = MeetingHintContent(suggestion: suggestion, canMute: actions.muteApp != nil)
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
        let target = targetFrame(for: panel)

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
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        pausedRemaining = nil
        guard isPresented, let panel else { return }
        isPresented = false
        generation += 1
        let generation = generation

        let completion: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.finishHide(generation) }
        }
        if Self.reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: completion)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(Self.offscreen(panel.frame), display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: completion)
        }
    }

    private func finishHide(_ generation: Int) {
        guard self.generation == generation else { return }
        panel?.orderOut(nil)
        model.content = nil
        model.isHovered = false
    }

    // MARK: - Presentation

    private func present(_ panel: HintPanel, at target: NSRect) {
        if Self.reduceMotion {
            panel.setFrame(target, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(Self.offscreen(target), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                // Fast out, long settle: close to the system's notification banner.
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        }
        panel.invalidateShadow()
    }

    private func makePanel() -> HintPanel {
        let panel = HintPanel()
        let hosting = FirstMouseHostingView(rootView: MeetingHintView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        return panel
    }

    /// Top right of the screen that has the menu bar, just below it.
    private func targetFrame(for panel: HintPanel) -> NSRect {
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 372, height: 80)
        let screen = NSScreen.screens.first ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The view's outer inset is transparent room for the close button; the card itself
        // sits at the margins.
        let inset = MeetingHintView.outerInset
        return NSRect(
            x: visible.maxX - size.width - Self.screenMargin.width + inset,
            y: visible.maxY - size.height - Self.screenMargin.height + inset,
            width: size.width,
            height: size.height
        )
    }

    private static func offscreen(_ frame: NSRect) -> NSRect {
        frame.offsetBy(dx: frame.width * 0.6, dy: 0)
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
                .announcement: "\(content.title). \(content.subtitle)",
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

private final class HintPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 80),
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
        titleVisibility = .hidden
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
