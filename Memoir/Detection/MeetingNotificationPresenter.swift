import AppKit
import UserNotifications
import os

/// Presents meeting suggestions as system notifications, so they follow the user's
/// notification style, Focus and Notification Center settings like any other app's.
///
/// Only the latest suggestion is live. Responses to anything older, including notifications
/// left in Notification Center by a previous launch, are ignored: tapping "Record" on a
/// suggestion from an hour ago must not start a recording.
final class MeetingNotificationPresenter: NSObject {
    /// A suggestion still sitting in Notification Center after this long is about a meeting
    /// that has most likely ended, so it is withdrawn.
    private static let expiry: Duration = .seconds(10 * 60)

    private enum Category {
        static let start = "meeting.start"
        static let startMutable = "meeting.start.mutable"
        static let stop = "meeting.stop"
        static let stopMutable = "meeting.stop.mutable"
    }

    private enum Action {
        static let accept = "meeting.accept"
        static let mute = "meeting.mute"
    }

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "Memoir", category: "Notifications")
    private var current: (id: String, actions: MeetingHintActions)?
    private var expiryTask: Task<Void, Never>?

    override init() {
        super.init()
        // Must be set before launch finishes, or a click that launches the app is lost.
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        // Leftovers from a previous launch can no longer be acted on.
        center.removeAllDeliveredNotifications()
    }

    func show(_ suggestion: MeetingSuggestion, actions: MeetingHintActions) {
        hide()
        let id = suggestion.id.uuidString
        current = (id, actions)

        let content = UNMutableNotificationContent()
        let text = MeetingNotificationText(suggestion: suggestion)
        content.title = text.title
        content.body = text.body
        content.threadIdentifier = "meeting-suggestions"
        content.interruptionLevel = .active
        let canMute = actions.muteApp != nil
        content.categoryIdentifier = switch suggestion.kind {
        case .start: canMute ? Category.startMutable : Category.start
        case .stop: canMute ? Category.stopMutable : Category.stop
        }
        if let attachment = Self.iconAttachment(for: suggestion) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            guard await authorize() else {
                log.notice("Notifications are not allowed, dropping a meeting suggestion")
                return
            }
            // Hidden or replaced while the permission prompt was up.
            guard current?.id == id else { return }
            do {
                try await center.add(request)
            } catch {
                log.error("Could not post a meeting suggestion: \(error)")
                return
            }
            // Hidden while `add` was in flight, which removed nothing at the time.
            if current?.id != id {
                center.removeDeliveredNotifications(withIdentifiers: [id])
            }
        }

        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.expiry)
            guard !Task.isCancelled, let self, current?.id == id else { return }
            // Expiring is not a "no": the detector is not told, so no cooldown starts.
            hide()
        }
    }

    func hide() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let current else { return }
        self.current = nil
        center.removePendingNotificationRequests(withIdentifiers: [current.id])
        center.removeDeliveredNotifications(withIdentifiers: [current.id])
    }

    /// Asks the first time a suggestion comes up for anyone who skipped the onboarding step,
    /// including everyone updating from a version that drew its own banner.
    private func authorize() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func respond(to actionIdentifier: String, for id: String) {
        guard let current, current.id == id else {
            center.removeDeliveredNotifications(withIdentifiers: [id])
            return
        }
        switch actionIdentifier {
        case Action.accept:
            current.actions.accept()
        case Action.mute:
            current.actions.muteApp?()
        case UNNotificationDismissActionIdentifier:
            current.actions.dismiss()
        default:
            // Clicking the notification body. Starting a recording from a stray click would
            // be worse than doing nothing, so only the explicit buttons act.
            break
        }
    }

    private static var categories: Set<UNNotificationCategory> {
        let record = UNNotificationAction(identifier: Action.accept, title: String(localized: "Record"))
        let stop = UNNotificationAction(identifier: Action.accept, title: String(localized: "Stop Recording"))
        // Category actions are registered up front, so the app cannot be named here. The
        // notification's title already names it.
        let mute = UNNotificationAction(identifier: Action.mute, title: String(localized: "Don't Ask for This App"))

        func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            // Without customDismissAction closing the notification is never reported, and
            // closing is what starts the detector's cooldown.
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [.customDismissAction])
        }
        return [
            category(Category.start, [record]),
            category(Category.startMutable, [record, mute]),
            category(Category.stop, [stop]),
            category(Category.stopMutable, [stop, mute]),
        ]
    }

    /// The notification itself always carries Memoir's icon, so the meeting app's icon is
    /// attached as a thumbnail to show where the call is.
    private static func iconAttachment(for suggestion: MeetingSuggestion) -> UNNotificationAttachment? {
        let bundleID = suggestion.bundleID ?? (suggestion.event != nil ? "com.apple.iCal" : nil)
        guard let bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path(percentEncoded: false))
        var rect = NSRect(x: 0, y: 0, width: 256, height: 256)
        guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return nil }

        // The system moves the file into its own store when the notification is added, so
        // every notification needs a fresh copy.
        let url = FileManager.default.temporaryDirectory
            .appending(path: "NotificationIcons", directoryHint: .isDirectory)
            .appending(path: "\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            return try UNNotificationAttachment(identifier: "icon", url: url)
        } catch {
            return nil
        }
    }
}

extension MeetingNotificationPresenter: UNUserNotificationCenterDelegate {
    // Without this a suggestion is silently dropped while a Memoir window is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let id = response.notification.request.identifier
        await respond(to: action, for: id)
    }
}

/// The wording of a suggestion. Separate from the presenter so the rules stay in one place.
struct MeetingNotificationText: Equatable {
    var title: String
    var body: String

    init(suggestion: MeetingSuggestion) {
        let appName = suggestion.appName
        let isBrowser = suggestion.bundleID.flatMap(MeetingApps.app(forBundleID:))?.category == .browser

        switch suggestion.kind {
        case .stop:
            title = String(localized: "Meeting ended?")
            body = appName.map { String(localized: "\($0) stopped using the microphone") }
                ?? String(localized: "The call seems to be over")

        case .start:
            if let event = suggestion.event {
                title = event.title
                let start = event.start.formatted(date: .omitted, time: .shortened)
                let end = event.end.formatted(date: .omitted, time: .shortened)
                let time = String(localized: "\(start) to \(end)")
                body = appName.map { "\($0) · \(time)" } ?? time
            } else if let appName {
                title = isBrowser
                    ? String(localized: "Meeting detected in \(appName)")
                    : String(localized: "\(appName) meeting detected")
                body = String(localized: "Record and transcribe on this Mac")
            } else {
                title = String(localized: "Meeting detected")
                body = String(localized: "Record and transcribe on this Mac")
            }
        }
    }
}
