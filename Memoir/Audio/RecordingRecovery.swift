import AVFoundation
import os

/// Rebuilds a recording's `audio.m4a` from the part files `SourcePipeline` writes while
/// recording, for recordings that ended without a successful mixdown.
nonisolated enum RecordingRecovery {
    static let log = Logger(subsystem: "Memoir", category: "Recovery")

    /// What a part file's name says about it: `part-<source>-<index>-<offset>ms.caf`.
    struct PartName: Equatable {
        let source: AudioSource
        let index: Int
        let offset: TimeInterval
    }

    static func parse(_ fileName: String) -> PartName? {
        // The offset can be slightly negative: the first buffer may be stamped just before the
        // start time was taken.
        guard let match = fileName.wholeMatch(of: /part-([a-z]+)-(\d+)-(-?\d+)ms\.caf/),
              let source = AudioSource(rawValue: String(match.1)),
              let index = Int(match.2),
              let millis = Int(match.3)
        else { return nil }
        return PartName(source: source, index: index, offset: Double(millis) / 1000)
    }

    static func hasParts(in folder: URL) -> Bool {
        !partURLs(in: folder).isEmpty
    }

    /// The parts in `folder` laid out on the recording timeline, with their real lengths read
    /// from the files. A part that cannot be opened (cut off before its header was written)
    /// is left out.
    static func segments(in folder: URL) -> [PartSegment] {
        partURLs(in: folder).compactMap { url in
            guard let name = parse(url.lastPathComponent) else { return nil }
            do {
                let file = try AVAudioFile(forReading: url)
                return PartSegment(
                    url: url, offset: name.offset,
                    sampleRate: file.fileFormat.sampleRate, frames: file.length
                )
            } catch {
                log.error("Unreadable part \(url.lastPathComponent, privacy: .public): \(error)")
                return nil
            }
        }
    }

    /// Makes sure `folder` holds a complete `audio.m4a` if its parts hold any audio, and returns
    /// that file's duration, or nil when there is no audio. Runs off the caller's thread, since
    /// mixing an hour takes a while.
    static func recover(folder: URL) async throws -> TimeInterval? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try recoverNow(folder: folder) })
            }
        }
    }

    static func recoverNow(folder: URL) throws -> TimeInterval? {
        let destination = folder.appending(path: AudioRecorder.audioFileName)
        // The mixdown moves its file into place only once it is complete, so an existing one
        // is whole. This is a run that was interrupted after mixing, before removing the parts.
        if let duration = duration(of: destination) {
            removeParts(segments(in: folder))
            return duration
        }
        let segments = segments(in: folder)
        guard !segments.isEmpty else { return nil }
        let duration = try AudioMixdown.mix(segments, to: destination)
        // Only the parts that were read. Ones that could not be opened are kept, never deleted.
        removeParts(segments)
        return duration
    }

    private static func duration(of audio: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: audio.path),
              let file = try? AVAudioFile(forReading: audio), file.length > 0
        else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private static func removeParts(_ segments: [PartSegment]) {
        for segment in segments {
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    private static func partURLs(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { parse($0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
