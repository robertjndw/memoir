import SwiftUI

/// Colours for the people in a transcript, shared by the names, avatars and the waveform.
nonisolated enum SpeakerPalette {
    /// System colours that stay apart from each other and from the default blue accent, which
    /// belongs to "You". Blue, cyan and indigo are left out for that reason, red because it
    /// already means recording.
    static let colors: [Color] = [.orange, .green, .purple, .teal, .pink, .brown]

    /// Voices are numbered from 1. A transcript with more voices than colours starts over.
    static func index(forVoice voice: Int) -> Int {
        let count = colors.count
        return ((voice - 1) % count + count) % count
    }

    /// Nil for anyone without a voice number, who keeps the plain look.
    static func color(for speaker: SpeakerID) -> Color? {
        guard speaker.speaker != .me, let voice = speaker.voice else { return nil }
        return colors[index(forVoice: voice)]
    }
}

/// A palette colour used for text. In light mode the bright system colours (orange, teal,
/// green) fall well short of 4.5:1 on white, so they are darkened there. Dark mode already
/// reads fine and keeps the system colour as is.
struct SpeakerNameStyle: ShapeStyle {
    let color: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .light ? color.mix(with: .black, by: 0.35) : color
    }
}

/// Calendar attendees offered when naming a speaker.
nonisolated enum SpeakerNameSuggestions {
    /// The attendees not yet given to any speaker, in invitation order. Once the user has typed
    /// something, only the names containing it.
    static func suggestions(attendees: [String], speakerNames: [Int: String], query: String = "") -> [String] {
        let taken = Set(speakerNames.values.map(normalized))
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return attendees.filter { name in
            let key = normalized(name)
            guard !key.isEmpty, !taken.contains(key), seen.insert(key).inserted else { return false }
            return query.isEmpty || name.localizedStandardContains(query)
        }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
