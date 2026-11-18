import Foundation
import Testing
@testable import Memoir

@Suite("Detection: meeting link parser")
struct DetectionLinkParserTests {
    typealias Service = MeetingLinkParser.Service

    @Test(arguments: [
        ("https://us02web.zoom.us/j/81234567890?pwd=abc123", Service.zoom),
        ("https://zoom.us/my/jane.doe", .zoom),
        ("https://company.zoom.com/j/123456789", .zoom),
        ("https://acme.zoomgov.com/j/1601234567", .zoom),
        ("zoommtg://zoom.us/join?confno=123456789", .zoom),
        ("https://meet.google.com/abc-defg-hij", .googleMeet),
        ("https://meet.google.com/lookup/abcdef?authuser=0", .googleMeet),
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d", .teams),
        ("https://teams.microsoft.com/meet/2851234567?p=abcdef", .teams),
        ("https://teams.live.com/meet/9381234567", .teams),
        ("msteams:/l/meetup-join/19:meeting", .teams),
        ("https://acme.webex.com/acme/j.php?MTID=m1234", .webex),
        ("https://acme.webex.com/meet/jane", .webex),
        ("https://facetime.apple.com/join#v=1&p=abc&k=def", .faceTime),
        ("https://whereby.com/team-standup", .whereby),
        ("https://meet.jit.si/MyRoom123", .jitsi),
        ("https://8x8.vc/company/room", .jitsi),
        ("https://global.gotomeeting.com/join/123456789", .goTo),
        ("https://meet.goto.com/123456789", .goTo),
        ("https://bluejeans.com/123456789", .blueJeans),
        ("https://chime.aws/1234567890", .chime),
        ("https://app.slack.com/huddle/T123/C456", .slack),
        ("https://around.co/r/design-sync", .around),
    ])
    func recognizesJoinLinks(_ string: String, _ service: Service) throws {
        let url = try #require(URL(string: string))
        #expect(MeetingLinkParser.service(for: url) == service)
    }

    @Test(arguments: [
        "https://zoom.us",
        "https://zoom.us/download",
        "https://meet.google.com/",
        "https://teams.microsoft.com/",
        "https://www.webex.com/pricing",
        "https://example.com/j/123",
        "https://docs.google.com/document/d/abc",
        "mailto:jane@example.com",
    ])
    func ignoresOtherLinks(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(MeetingLinkParser.service(for: url) == nil)
    }

    @Test func findsLinkInInvitationNotes() {
        let notes = """
        Hi all,

        Agenda: https://docs.google.com/document/d/abc
        ==========
        Join Zoom Meeting
        https://us06web.zoom.us/j/87654321098?pwd=xyz

        Meeting ID: 876 5432 1098
        Download the app at https://zoom.us/download
        """
        let link = MeetingLinkParser.link(url: nil, location: nil, notes: notes)
        #expect(link?.service == .zoom)
        #expect(link?.url.absoluteString == "https://us06web.zoom.us/j/87654321098?pwd=xyz")
    }

    @Test func findsLinkInAngleBracketsAndHTML() {
        let outlook = "Microsoft Teams meeting\nJoin: <https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0>"
        #expect(MeetingLinkParser.link(url: nil, location: nil, notes: outlook)?.service == .teams)

        let html = #"<p>Join with <a href="https://meet.google.com/xyz-abcd-efg">Google Meet</a></p>"#
        #expect(MeetingLinkParser.link(url: nil, location: nil, notes: html)?.service == .googleMeet)
    }

    @Test func findsLinkWithoutScheme() {
        let link = MeetingLinkParser.link(url: nil, location: "meet.google.com/abc-defg-hij", notes: nil)
        #expect(link?.service == .googleMeet)
        #expect(link?.url.scheme == "https")
    }

    @Test func prefersURLThenLocationThenNotes() throws {
        let zoom = try #require(URL(string: "https://zoom.us/j/111111111"))
        let location = "https://meet.google.com/aaa-bbbb-ccc"
        let notes = "https://teams.microsoft.com/l/meetup-join/abc"

        #expect(MeetingLinkParser.link(url: zoom, location: location, notes: notes)?.service == .zoom)
        #expect(MeetingLinkParser.link(url: nil, location: location, notes: notes)?.service == .googleMeet)
        #expect(MeetingLinkParser.link(url: nil, location: "Room 4.12", notes: notes)?.service == .teams)
    }

    @Test func nonMeetingEventFieldsGiveNoLink() throws {
        let url = try #require(URL(string: "https://example.com/event"))
        #expect(MeetingLinkParser.link(url: url, location: "Café Central", notes: "Bring slides") == nil)
        #expect(MeetingLinkParser.link(url: nil, location: nil, notes: nil) == nil)
        #expect(MeetingLinkParser.link(url: nil, location: "", notes: "") == nil)
    }
}

@Suite("Detection: calendar selection")
struct DetectionCalendarSelectionTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func meeting(_ id: String, start: TimeInterval, minutes: Double = 30) -> CalendarMeeting {
        CalendarMeeting(
            id: id,
            title: id,
            start: now.addingTimeInterval(start),
            end: now.addingTimeInterval(start + minutes * 60),
            attendees: [],
            joinURL: nil
        )
    }

    @Test func currentIncludesInProgressAndStartingSoon() {
        #expect(EventKitCalendar.current(in: [meeting("a", start: -600)], at: now)?.id == "a")
        #expect(EventKitCalendar.current(in: [meeting("b", start: 240)], at: now)?.id == "b")
        #expect(EventKitCalendar.current(in: [meeting("c", start: 400)], at: now) == nil)
        #expect(EventKitCalendar.current(in: [meeting("d", start: -3600, minutes: 30)], at: now) == nil)
    }

    @Test func currentPrefersStartClosestToNow() {
        let workshop = meeting("workshop", start: -7200, minutes: 240)
        let sync = meeting("sync", start: 120)
        #expect(EventKitCalendar.current(in: [workshop, sync], at: now)?.id == "sync")
    }

    @Test func nextIsEarliestUpcomingWithinInterval() {
        let meetings = [meeting("now", start: -60), meeting("later", start: 7200), meeting("soon", start: 1800)]
        #expect(EventKitCalendar.next(in: meetings, at: now, within: 3600)?.id == "soon")
        #expect(EventKitCalendar.next(in: meetings, at: now, within: 600) == nil)
    }
}
