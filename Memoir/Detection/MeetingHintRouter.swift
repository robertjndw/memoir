import Foundation

/// Sends each suggestion to the presentation the user picked, and makes sure only one is up.
final class MeetingHintRouter: MeetingHintPresenting {
    private let notifications = MeetingNotificationPresenter()
    private let tips = MenuBarTipController()

    func show(_ suggestion: MeetingSuggestion, style: MeetingHintStyle, actions: MeetingHintActions) {
        switch style {
        case .menuBarTip:
            notifications.hide()
            // The icon can be hidden by the user or pushed off a crowded menu bar. A tip
            // pointing at nothing is useless, so fall back to a notification.
            guard tips.show(suggestion, actions: actions) else {
                notifications.show(suggestion, actions: actions)
                return
            }
        case .notification:
            tips.hide()
            notifications.show(suggestion, actions: actions)
        }
    }

    func hide() {
        notifications.hide()
        tips.hide()
    }
}
