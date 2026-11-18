import EventKit
import Foundation

/// Meeting-like events from the user's calendars. Reads are served from a cache that is
/// rebuilt when the store changes, so `current()` and `next(within:)` are cheap enough for
/// UI refreshes and the detector's timer.
final class EventKitCalendar: CalendarProviding {
    /// How far `current()` looks ahead, per the contract.
    nonisolated static let currentLeadTime: TimeInterval = 5 * 60

    private var store = EKEventStore()
    private var cache: [CalendarMeeting] = []
    private var cachedRange: DateInterval?
    private var cachedAt: Date = .distantPast
    private var changeObserver: NSObjectProtocol?

    init() {
        observeChanges()
    }

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async -> Bool {
        if hasAccess { return true }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted {
            // A store created before access was granted can keep returning no events.
            store = EKEventStore()
            observeChanges()
            invalidate()
        }
        return granted
    }

    func current() -> CalendarMeeting? {
        let now = Date.now
        return Self.current(in: meetings(covering: now), at: now)
    }

    func next(within interval: TimeInterval) -> CalendarMeeting? {
        let now = Date.now
        return Self.next(in: meetings(covering: now.addingTimeInterval(interval)), at: now, within: interval)
    }

    // MARK: - Selection (pure)

    /// In progress or starting soon. With overlaps, the one whose start is closest to now wins:
    /// at 10:57 the 11:00 meeting is a better guess than the workshop running since 9:00.
    nonisolated static func current(in meetings: [CalendarMeeting], at now: Date) -> CalendarMeeting? {
        meetings
            .filter { $0.start <= now.addingTimeInterval(currentLeadTime) && $0.end > now }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    nonisolated static func next(
        in meetings: [CalendarMeeting],
        at now: Date,
        within interval: TimeInterval
    ) -> CalendarMeeting? {
        meetings
            .filter { $0.start >= now && $0.start <= now.addingTimeInterval(interval) }
            .min { $0.start < $1.start }
    }

    // MARK: - Cache

    private func meetings(covering date: Date) -> [CalendarMeeting] {
        guard hasAccess else {
            cache = []
            cachedRange = nil
            return []
        }
        let now = Date.now
        // The store notification covers edits; the age limit covers events that move into the
        // window simply because time passed, and anything the notification missed.
        let isFresh = now.timeIntervalSince(cachedAt) < 15 * 60
        if let cachedRange, isFresh, cachedRange.contains(now.addingTimeInterval(-12 * 3600)),
           cachedRange.contains(date)
        {
            return cache
        }
        let start = now.addingTimeInterval(-12 * 3600)
        let end = max(date, now.addingTimeInterval(24 * 3600))
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        cache = store.events(matching: predicate)
            .compactMap(Self.meeting(from:))
            .sorted { $0.start < $1.start }
        cachedRange = DateInterval(start: start, end: end)
        cachedAt = now
        return cache
    }

    private func invalidate() {
        cachedAt = .distantPast
    }

    private func observeChanges() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidate()
            }
        }
    }

    // MARK: - Mapping

    private static func meeting(from event: EKEvent) -> CalendarMeeting? {
        guard !event.isAllDay, event.status != .canceled else { return nil }
        let participants = event.attendees ?? []
        if participants.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) {
            return nil
        }
        let others = participants.filter { participant in
            !participant.isCurrentUser
                && participant.participantType != .room
                && participant.participantType != .resource
        }
        let link = MeetingLinkParser.link(url: event.url, location: event.location, notes: event.notes)
        guard link != nil || !others.isEmpty else { return nil }

        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarMeeting(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: title.isEmpty ? String(localized: "Meeting") : title,
            start: event.startDate,
            end: event.endDate,
            attendees: others.compactMap(displayName(of:)),
            joinURL: link?.url
        )
    }

    private static func displayName(of participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let url = participant.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.absoluteString.dropFirst("mailto:".count)
        return address.isEmpty ? nil : String(address).removingPercentEncoding ?? String(address)
    }
}
