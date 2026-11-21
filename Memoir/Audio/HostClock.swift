import Darwin

/// Converts mach host time (the clock Core Audio and AVAudioEngine stamp buffers with) to
/// seconds. Both capture sources are placed on one timeline by measuring against a single
/// start host time.
nonisolated enum HostClock {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static var now: UInt64 { mach_absolute_time() }

    /// Signed, because a buffer's first frame can predate the start stamp by a few ms.
    static func seconds(
        from start: UInt64,
        to host: UInt64,
        timebase: mach_timebase_info_data_t = timebase
    ) -> Double {
        let ticks = host >= start ? Double(host - start) : -Double(start - host)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func ticks(
        forSeconds seconds: Double,
        timebase: mach_timebase_info_data_t = timebase
    ) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// Recording-relative timestamp for a buffer. Clamped at zero so consumers never see a
    /// negative position.
    static func recordingTime(of host: UInt64, start: UInt64) -> Double {
        max(0, seconds(from: start, to: host))
    }
}
