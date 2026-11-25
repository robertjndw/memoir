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

    /// Per-source tracks are named `track-<source>.caf`. They are scratch files for the models
    /// that run after a recording, so anything found at launch is a leftover.
    static let trackPrefix = "track-"

    /// Removes leftover tracks, and the temporary file of a render cut short, from `folder`.
    static func removeStaleTracks(in folder: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in contents where isTrack(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Cleans every meeting folder under the recordings directory except `skipping`, which must
    /// hold the meetings being recorded or processed right now: their tracks and parts are in
    /// use. This is the entry point for finished meetings, which `recover` never visits.
    ///
    /// Besides tracks, it removes parts sitting next to a complete `audio.m4a`. The recorder
    /// keeps them past the mixdown when tracks are wanted, and an app that ends before they are
    /// rendered leaves them behind in a meeting that already has its audio.
    static func removeStaleTracks(skipping: Set<UUID>, recordings: URL? = nil) {
        let root = recordings ?? RecordingFiles.baseDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if let id = UUID(uuidString: folder.lastPathComponent), skipping.contains(id) { continue }
            removeStaleTracks(in: folder)
            if duration(of: folder.appending(path: AudioRecorder.audioFileName)) != nil {
                for url in partURLs(in: folder) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private static func isTrack(_ fileName: String) -> Bool {
        fileName.hasSuffix(".caf") && (fileName.hasPrefix(trackPrefix) || fileName.hasPrefix(".\(trackPrefix)"))
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
        removeStaleTracks(in: folder)
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
