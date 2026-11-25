import Foundation

nonisolated enum LibraryFormat {
    /// Position inside a recording, "05:07" or "1:05:07" past an hour.
    static func timecode(_ time: TimeInterval) -> String {
        let seconds = Int(max(0, time).rounded(.down))
        let duration = Duration.seconds(seconds)
        if seconds >= 3600 {
            return duration.formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1)))
        }
        return duration.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }

    /// Length of a meeting, "42 min" or "1 hr, 5 min". Rounded to whole minutes once past a minute.
    static func length(_ time: TimeInterval, locale: Locale = .current) -> String {
        let seconds = Int(max(0, time).rounded())
        if seconds < 60 {
            return Duration.seconds(seconds)
                .formatted(.units(allowed: [.seconds], width: .abbreviated).locale(locale))
        }
        let minutes = (seconds + 30) / 60
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale))
    }

    /// Like `length`, but nil where there is nothing worth showing, so a meeting with no
    /// recorded time doesn't get "0 sec".
    static func optionalLength(_ time: TimeInterval, locale: Locale = .current) -> String? {
        guard Int(max(0, time).rounded()) > 0 else { return nil }
        return length(time, locale: locale)
    }
}
