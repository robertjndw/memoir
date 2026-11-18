import Foundation

/// Finds video call join links in calendar event fields.
nonisolated enum MeetingLinkParser {
    enum Service: String, Sendable, CaseIterable {
        case zoom = "Zoom"
        case googleMeet = "Google Meet"
        case teams = "Microsoft Teams"
        case webex = "Webex"
        case faceTime = "FaceTime"
        case whereby = "Whereby"
        case jitsi = "Jitsi Meet"
        case goTo = "GoTo Meeting"
        case blueJeans = "BlueJeans"
        case chime = "Amazon Chime"
        case slack = "Slack Huddle"
        case skype = "Skype"
        case around = "Around"
        case discord = "Discord"
        case ringCentral = "RingCentral"
        case zohoMeeting = "Zoho Meeting"
        case gather = "Gather"
    }

    struct Link: Sendable, Equatable {
        let service: Service
        let url: URL
    }

    /// The first join link, checking the event's URL field first, then location, then notes.
    static func link(url: URL?, location: String?, notes: String?) -> Link? {
        if let url, let service = service(for: url) {
            return Link(service: service, url: url)
        }
        for text in [location, notes] {
            if let text, let link = firstLink(in: text) {
                return link
            }
        }
        return nil
    }

    static func firstLink(in text: String) -> Link? {
        guard !text.isEmpty else { return nil }
        for url in urls(in: text) {
            if let service = service(for: url) {
                return Link(service: service, url: url)
            }
        }
        return nil
    }

    /// Classifies a URL as a join link. Bare service home pages (zoom.us, meet.google.com)
    /// do not count, because invitations often mention them in boilerplate.
    static func service(for url: URL) -> Service? {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "zoommtg", "zoomus": return .zoom
        case "msteams": return .teams
        case "facetime", "facetime-audio": return .faceTime
        case "http", "https": break
        default: return nil
        }

        guard let rawHost = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let path = url.path(percentEncoded: false)
        let segments = path.split(separator: "/").map { $0.lowercased() }
        let first = segments.first ?? ""

        func matches(_ domain: String) -> Bool {
            host == domain || host.hasSuffix("." + domain)
        }

        if matches("zoom.us") || matches("zoom.com") || matches("zoomgov.com") {
            return ["j", "my", "s", "w", "wc", "join", "meeting"].contains(first) && segments.count >= 2
                ? .zoom : nil
        }
        if host == "meet.google.com" {
            // Room codes look like abc-defg-hij; "lookup" links resolve to a room as well.
            return !first.isEmpty && first != "new" && first != "landing" ? .googleMeet : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.microsoft.us" {
            let joinPaths: Set<String> = ["l", "meet", "dl"]
            return joinPaths.contains(first) && segments.count >= 2 ? .teams : nil
        }
        if matches("webex.com") {
            let joinMarkers = ["meet", "join", "j.php", "wbxmjs", "m", "webappng"]
            return segments.contains { joinMarkers.contains($0) } ? .webex : nil
        }
        if host == "facetime.apple.com" {
            return first == "join" ? .faceTime : nil
        }
        if matches("whereby.com") {
            return !first.isEmpty && !["information", "user", "org", "pricing"].contains(first) ? .whereby : nil
        }
        if host == "meet.jit.si" || host == "8x8.vc" || host.hasPrefix("jitsi.") || host.hasPrefix("meet.jitsi.") {
            return !first.isEmpty ? .jitsi : nil
        }
        if matches("gotomeeting.com") || matches("gotomeet.me") || host == "meet.goto.com" {
            return !first.isEmpty ? .goTo : nil
        }
        if matches("bluejeans.com") {
            return first.allSatisfy(\.isNumber) && !first.isEmpty ? .blueJeans : nil
        }
        if host == "chime.aws" || host == "app.chime.aws" {
            return !first.isEmpty ? .chime : nil
        }
        if host == "app.slack.com" {
            return first == "huddle" ? .slack : nil
        }
        if host == "join.skype.com" {
            return !first.isEmpty ? .skype : nil
        }
        if host == "around.co" {
            return first == "r" && segments.count >= 2 ? .around : nil
        }
        if host == "discord.gg" || ((host == "discord.com" || host == "discordapp.com") && first == "channels") {
            return !first.isEmpty ? .discord : nil
        }
        if host == "meetings.ringcentral.com" || host == "v.ringcentral.com" || host == "video.ringcentral.com" {
            return !first.isEmpty ? .ringCentral : nil
        }
        if host.hasPrefix("meeting.zoho.") {
            return !first.isEmpty ? .zohoMeeting : nil
        }
        if host == "app.gather.town" {
            return first == "app" || first == "invite" ? .gather : nil
        }
        return nil
    }

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func urls(in text: String) -> [URL] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard var url = match.url else { return nil }
            // Bare "meet.google.com/abc" is detected as http; join links all work over https.
            if url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.scheme = "https"
                url = components.url ?? url
            }
            return url
        }
    }
}
