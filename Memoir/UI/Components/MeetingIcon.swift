import AppKit
import SwiftUI

/// Icon of the app the meeting was recorded from, or a waveform tile if there is none.
struct MeetingIcon: View {
    let bundleID: String?
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let bundleID, let icon = AppIconCache.icon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                // App icons have a transparent margin of roughly 10%, so the tile is inset to match
                // their optical size and rows line up whether or not an icon was found.
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(.fill.tertiary)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum AppIconCache {
    // Looked up on every row render, and the Launch Services call isn't cheap. Misses are
    // cached too.
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
        cache[bundleID] = icon
        return icon
    }
}

/// Initials on a colour derived from the name, so it stays the same across launches.
struct PersonAvatar: View {
    let name: String
    var size: CGFloat = 22

    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan]

    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(letters).uppercased()
    }

    private var color: Color {
        // `hashValue` is seeded per launch, so it would reshuffle the colours every time.
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return Self.palette[abs(seed) % Self.palette.count]
    }

    var body: some View {
        Circle()
            .fill(color.gradient)
            .overlay {
                Text(Self.initials(of: name))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(size * 0.1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AvatarStack: View {
    let names: [String]
    var size: CGFloat = 22
    var limit = 4

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(limit).enumerated()), id: \.offset) { _, name in
                PersonAvatar(name: name, size: size)
                    .padding(1.5)
                    .background(.background, in: .circle)
            }
            if names.count > limit {
                Text("+\(names.count - limit)")
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.fill.secondary, in: .circle)
                    .padding(1.5)
                    .background(.background, in: .circle)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Icons and avatars") {
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
            MeetingIcon(bundleID: "com.apple.FaceTime", size: 44)
            MeetingIcon(bundleID: "com.example.not-installed", size: 44)
            MeetingIcon(bundleID: nil, size: 28)
        }
        AvatarStack(names: ["Maya Chen", "Jonas Weber", "Ana", "Ben Ortiz", "Chris Lee", "Dana"])
        AvatarStack(names: ["Maya Chen", "Jonas Weber"], size: 28)
    }
    .padding(24)
}
