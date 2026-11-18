import Foundation
import Testing
@testable import Memoir

@Suite("Detection: meeting app catalog")
struct DetectionAppsTests {
    @Test(arguments: [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams (classic)"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.google.Chrome", "Google Chrome"),
        ("company.thebrowser.Browser", "Arc"),
        ("company.thebrowser.dia", "Dia"),
    ])
    func exactBundleIDs(_ bundleID: String, _ name: String) {
        #expect(MeetingApps.app(forBundleID: bundleID)?.name == name)
    }

    @Test(arguments: [
        // Chromium and Electron helpers share the app's prefix.
        ("com.google.Chrome.helper", "com.google.Chrome"),
        ("com.google.Chrome.helper.renderer", "com.google.Chrome"),
        ("com.tinyspeck.slackmacgap.helper", "com.tinyspeck.slackmacgap"),
        ("com.hnc.DiscordPTB.helper.Renderer", "com.hnc.DiscordPTB"),
        ("com.microsoft.teams2.helper", "com.microsoft.teams2"),
        ("com.brave.Browser.helper", "com.brave.Browser"),
        // Arc's helpers change the casing of the app's bundle ID.
        ("company.thebrowser.browser.helper", "company.thebrowser.Browser"),
        // Zoom's helpers use their own namespace.
        ("us.zoom.caphost", "us.zoom.xos"),
        ("us.zoom.CptHost", "us.zoom.xos"),
        ("zoom.us.ZoomAgent", "us.zoom.xos"),
        ("com.apple.avconferenced", "com.apple.FaceTime"),
        ("org.mozilla.plugincontainer", "org.mozilla.firefox"),
    ])
    func helpersResolveToTheirApp(_ helper: String, _ owner: String) {
        #expect(MeetingApps.app(forBundleID: helper)?.bundleID == owner)
    }

    @Test func longestPrefixWins() {
        #expect(MeetingApps.app(forBundleID: "com.google.Chrome.beta")?.name == "Google Chrome Beta")
        #expect(MeetingApps.app(forBundleID: "com.google.Chrome.beta.helper")?.name == "Google Chrome Beta")
        let meet = MeetingApps.app(forBundleID: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan")
        #expect(meet?.name == "Google Meet")
        #expect(meet?.category == .meeting)
        // Another installed web app is still just Chrome.
        #expect(MeetingApps.app(forBundleID: "com.google.Chrome.app.someotherapp")?.name == "Google Chrome")
    }

    @Test func prefixMatchesOnlyWholeComponents() {
        // teams2 must not be mistaken for a helper of classic Teams, and vice versa.
        #expect(MeetingApps.app(forBundleID: "com.microsoft.teams2")?.bundleID == "com.microsoft.teams2")
        #expect(MeetingApps.app(forBundleID: "com.microsoft.teamsfoo") == nil)
        #expect(MeetingApps.app(forBundleID: "us.zoomer.app") == nil)
    }

    @Test(arguments: [
        "com.apple.VoiceMemos",
        "com.apple.SpeechRecognitionCore.speechrecognitiond",
        "com.apple.WebKit.GPU",
        "com.apple.QuickTimePlayerX",
        "de.jandow.Memoir",
        "",
    ])
    func unknownAppsAreNotMeetingApps(_ bundleID: String) {
        #expect(MeetingApps.app(forBundleID: bundleID) == nil)
    }

    @Test func categories() {
        #expect(MeetingApps.app(forBundleID: "us.zoom.xos")?.category == .meeting)
        #expect(MeetingApps.app(forBundleID: "com.apple.Safari")?.category == .browser)
        #expect(MeetingApps.app(forBundleID: "com.google.Chrome.helper")?.category == .browser)
    }

    @Test func catalogHasNoDuplicates() {
        let ids = MeetingApps.all.map { $0.bundleID.lowercased() }
        #expect(Set(ids).count == ids.count)
    }

    @Test func resolveTriesCandidatesInOrder() {
        // Safari's shared WebKit GPU process only resolves through its responsible app.
        #expect(MeetingApps.resolve(["com.apple.WebKit.GPU", "com.apple.Safari", nil])?.name == "Safari")
        // The process's own identity wins over the responsible app.
        #expect(MeetingApps.resolve(["us.zoom.caphost", "com.apple.Safari"])?.name == "Zoom")
        // A WebKit view inside Mail is nobody's meeting.
        #expect(MeetingApps.resolve(["com.apple.WebKit.GPU", "com.apple.mail", nil, nil]) == nil)
        #expect(MeetingApps.resolve([nil, "", "com.hnc.DiscordPTB"])?.name == "Discord PTB")
    }

    @Test(arguments: [
        ("/Applications/zoom.us.app/Contents/Frameworks/caphost.app/Contents/MacOS/caphost", "/Applications/zoom.us.app"),
        ("/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Versions/A/Helpers/Browser Helper.app/Contents/MacOS/Browser Helper",
         "/Applications/Arc.app"),
        ("/Users/me/Applications/Chrome Apps.localized/Google Meet.app/Contents/MacOS/app_mode_loader",
         "/Users/me/Applications/Chrome Apps.localized/Google Meet.app"),
        ("/Applications/Slack.app/Contents/MacOS/Slack", "/Applications/Slack.app"),
    ])
    func outermostAppBundle(_ path: String, _ bundle: String) {
        #expect(MeetingApps.outermostAppBundle(inExecutablePath: path) == bundle)
    }

    @Test func noAppBundleInSystemServicePaths() {
        let gpu = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        #expect(MeetingApps.outermostAppBundle(inExecutablePath: gpu) == nil)
        #expect(MeetingApps.outermostAppBundle(inExecutablePath: "/usr/libexec/avconferenced") == nil)
    }
}
