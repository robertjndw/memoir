import Foundation

/// An app that can hold the microphone during a call.
nonisolated struct MeetingApp: Sendable, Hashable {
    enum Category: Sendable, Hashable {
        /// Dedicated call apps: holding the microphone almost always means a call.
        case meeting
        /// Holding the microphone may be a web meeting, but also dictation or voice search.
        case browser
    }

    let bundleID: String
    let name: String
    let category: Category
    /// Bundle ID prefixes (without trailing dot) of helpers that do not share the app's own
    /// prefix, such as Zoom's `us.zoom.caphost` next to `us.zoom.xos`.
    var helperFamilies: [String] = []
}

/// The process (owning app) currently holding the microphone, as the policy sees it.
nonisolated struct MicrophoneUser: Sendable, Hashable {
    enum Category: Sendable, Hashable {
        case meeting
        case browser
        case other
    }

    var bundleID: String
    var name: String
    var category: Category
}

/// Catalog of known meeting apps and browsers, plus the pure part of mapping a helper
/// process's bundle ID to the app that owns it.
nonisolated enum MeetingApps {
    static let meetingApps: [MeetingApp] = [
        MeetingApp(bundleID: "us.zoom.xos", name: "Zoom", category: .meeting, helperFamilies: ["us.zoom", "zoom.us"]),
        MeetingApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", category: .meeting),
        MeetingApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams (classic)", category: .meeting),
        // FaceTime calls run their audio in avconferenced, not in the FaceTime app.
        MeetingApp(bundleID: "com.apple.FaceTime", name: "FaceTime", category: .meeting,
                   helperFamilies: ["com.apple.avconferenced"]),
        MeetingApp(bundleID: "Cisco-Systems.Spark", name: "Webex", category: .meeting),
        MeetingApp(bundleID: "com.webex.meetingmanager", name: "Webex Meetings", category: .meeting,
                   helperFamilies: ["com.cisco.webexmeetingsapp", "com.webex"]),
        MeetingApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", category: .meeting),
        MeetingApp(bundleID: "com.hnc.Discord", name: "Discord", category: .meeting),
        MeetingApp(bundleID: "com.hnc.DiscordPTB", name: "Discord PTB", category: .meeting),
        MeetingApp(bundleID: "com.hnc.DiscordCanary", name: "Discord Canary", category: .meeting),
        MeetingApp(bundleID: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", name: "Google Meet",
                   category: .meeting),
        MeetingApp(bundleID: "com.skype.skype", name: "Skype", category: .meeting),
        MeetingApp(bundleID: "com.logmein.GoToMeeting", name: "GoTo Meeting", category: .meeting),
        MeetingApp(bundleID: "com.logmein.goto", name: "GoTo", category: .meeting),
        MeetingApp(bundleID: "com.bluejeansnet.Blue", name: "BlueJeans", category: .meeting,
                   helperFamilies: ["com.bluejeansnet"]),
        MeetingApp(bundleID: "co.teamport.around", name: "Around", category: .meeting),
        MeetingApp(bundleID: "app.tuple.app", name: "Tuple", category: .meeting),
        MeetingApp(bundleID: "com.amazon.Amazon-Chime", name: "Amazon Chime", category: .meeting),
        MeetingApp(bundleID: "com.ringcentral.glip", name: "RingCentral", category: .meeting),
        MeetingApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", category: .meeting),
        MeetingApp(bundleID: "desktop.WhatsApp", name: "WhatsApp", category: .meeting),
        MeetingApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram", category: .meeting),
        MeetingApp(bundleID: "org.telegram.desktop", name: "Telegram", category: .meeting),
        MeetingApp(bundleID: "org.whispersystems.signal-desktop", name: "Signal", category: .meeting),
        MeetingApp(bundleID: "im.riot.app", name: "Element", category: .meeting),
        MeetingApp(bundleID: "org.jitsi.jitsi-meet", name: "Jitsi Meet", category: .meeting),
    ]

    static let browsers: [MeetingApp] = [
        MeetingApp(bundleID: "com.apple.Safari", name: "Safari", category: .browser),
        MeetingApp(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", category: .browser),
        MeetingApp(bundleID: "com.google.Chrome", name: "Google Chrome", category: .browser),
        MeetingApp(bundleID: "com.google.Chrome.beta", name: "Google Chrome Beta", category: .browser),
        MeetingApp(bundleID: "com.google.Chrome.dev", name: "Google Chrome Dev", category: .browser),
        MeetingApp(bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary", category: .browser),
        MeetingApp(bundleID: "org.chromium.Chromium", name: "Chromium", category: .browser),
        MeetingApp(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", category: .browser),
        MeetingApp(bundleID: "com.microsoft.edgemac.Beta", name: "Microsoft Edge Beta", category: .browser),
        MeetingApp(bundleID: "com.microsoft.edgemac.Dev", name: "Microsoft Edge Dev", category: .browser),
        MeetingApp(bundleID: "com.microsoft.edgemac.Canary", name: "Microsoft Edge Canary", category: .browser),
        MeetingApp(bundleID: "company.thebrowser.Browser", name: "Arc", category: .browser),
        MeetingApp(bundleID: "company.thebrowser.dia", name: "Dia", category: .browser),
        MeetingApp(bundleID: "org.mozilla.firefox", name: "Firefox", category: .browser,
                   helperFamilies: ["org.mozilla.plugincontainer"]),
        MeetingApp(bundleID: "org.mozilla.firefoxdeveloperedition", name: "Firefox Developer Edition", category: .browser),
        MeetingApp(bundleID: "org.mozilla.nightly", name: "Firefox Nightly", category: .browser),
        MeetingApp(bundleID: "com.brave.Browser", name: "Brave", category: .browser),
        MeetingApp(bundleID: "com.brave.Browser.beta", name: "Brave Beta", category: .browser),
        MeetingApp(bundleID: "com.brave.Browser.nightly", name: "Brave Nightly", category: .browser),
        MeetingApp(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", category: .browser),
        MeetingApp(bundleID: "com.operasoftware.Opera", name: "Opera", category: .browser),
        MeetingApp(bundleID: "com.operasoftware.OperaGX", name: "Opera GX", category: .browser),
        MeetingApp(bundleID: "com.kagi.kagimacOS", name: "Orion", category: .browser),
        MeetingApp(bundleID: "app.zen-browser.zen", name: "Zen", category: .browser),
        MeetingApp(bundleID: "com.duckduckgo.macos.browser", name: "DuckDuckGo", category: .browser),
    ]

    static let all: [MeetingApp] = meetingApps + browsers

    /// The catalog entry for a bundle ID, matching helpers by prefix. Matching ignores case
    /// because helpers do not always keep the app's casing (Arc is `company.thebrowser.Browser`,
    /// its helpers `company.thebrowser.browser.helper`). The longest match wins, so the Google
    /// Meet web app beats Chrome and `com.google.Chrome.beta` beats `com.google.Chrome`.
    static func app(forBundleID bundleID: String) -> MeetingApp? {
        let id = bundleID.lowercased()
        var best: (app: MeetingApp, length: Int)?
        for app in all {
            for prefix in [app.bundleID] + app.helperFamilies {
                let candidate = prefix.lowercased()
                guard id == candidate || id.hasPrefix(candidate + ".") else { continue }
                if candidate.count > best?.length ?? -1 {
                    best = (app, candidate.count)
                }
            }
        }
        return best?.app
    }

    /// Resolves a process to the catalog app it belongs to by trying each identity in order:
    /// the process's own bundle ID, then the responsible app, the enclosing app bundle and the
    /// parent process. The first match wins; nil means none of them is a known app.
    static func resolve(_ candidates: [String?]) -> MeetingApp? {
        for case let bundleID? in candidates where !bundleID.isEmpty {
            if let app = app(forBundleID: bundleID) {
                return app
            }
        }
        return nil
    }

    /// The outermost `.app` bundle in an executable path. Helpers live nested inside their
    /// app (`zoom.us.app/Contents/Frameworks/caphost.app/...`), so the outermost one is the
    /// app the user launched.
    static func outermostAppBundle(inExecutablePath path: String) -> String? {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            components.append(component)
            if component.hasSuffix(".app") {
                let joined = components.joined(separator: "/")
                return joined.isEmpty ? nil : joined
            }
        }
        return nil
    }
}
