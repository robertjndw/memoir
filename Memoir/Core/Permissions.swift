import AVFoundation
import AppKit
import Observation
import UserNotifications

/// Privacy permissions the app can read. System audio recording is deliberately absent:
/// there is no public API to query it, macOS asks the first time a recording starts.
@Observable
final class Permissions {
    enum Access: Equatable {
        case notDetermined
        case granted
        case denied
    }

    private(set) var microphone: Access = .notDetermined
    /// Meeting suggestions are system notifications, so without this they never show.
    private(set) var notifications: Access = .notDetermined
    private(set) var calendarGranted = false
    /// EventKit access cannot be told apart as "never asked" versus "denied" through
    /// `CalendarProviding`, so a refused request is remembered for this session.
    private(set) var calendarRefused = false

    @ObservationIgnored private var calendar: (any CalendarProviding)?

    init() {
        refreshMicrophone()
        Task { await refreshNotifications() }
    }

    func bind(calendar: any CalendarProviding) {
        self.calendar = calendar
        refresh()
    }

    /// Statuses change behind the app's back in System Settings, so call this when the app
    /// becomes active again.
    func refresh() {
        refreshMicrophone()
        Task { await refreshNotifications() }
        calendarGranted = calendar?.hasAccess ?? false
        if calendarGranted { calendarRefused = false }
    }

    private func refreshMicrophone() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshMicrophone()
    }

    private func refreshNotifications() async {
        notifications = switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshNotifications()
    }

    func requestCalendar() async {
        guard let calendar else { return }
        let granted = await calendar.requestAccess()
        calendarGranted = granted || calendar.hasAccess
        calendarRefused = !calendarGranted
    }

    // MARK: - System Settings

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case systemAudio = "Privacy_AudioCapture"
        case calendars = "Privacy_Calendars"
    }

    static func open(_ pane: Pane) {
        openSystemSettings("com.apple.preference.security?\(pane.rawValue)")
    }

    /// Notification settings have no privacy pane. They live under the app's own entry.
    static func openNotifications() {
        openSystemSettings("com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
    }

    static func openSystemSettings(_ path: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(path)") else { return }
        NSWorkspace.shared.open(url)
    }
}
