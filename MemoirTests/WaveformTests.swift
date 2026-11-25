import AVFoundation
import Foundation
import Testing
@testable import Memoir

struct WaveformTests {
    private let me = SpeakerID(speaker: .me)
    private let others = SpeakerID(speaker: .others)
    private var spans: [SpeakerSpan] {
        [SpeakerSpan(start: 0, end: 5, speaker: me), SpeakerSpan(start: 10, end: 20, speaker: others)]
    }

    @Test func speakerLookupBridgesShortPausesOnly() {
        #expect(SpeakerSpan.speaker(at: 2, in: spans) == me)
        // Within the grace period after a line ends, the turn still belongs to that speaker.
        #expect(SpeakerSpan.speaker(at: 6, in: spans) == me)
        #expect(SpeakerSpan.speaker(at: 8, in: spans) == nil)
        #expect(SpeakerSpan.speaker(at: 10, in: spans) == others)
        #expect(SpeakerSpan.speaker(at: 30, in: spans) == nil)
        #expect(SpeakerSpan.speaker(at: 1, in: []) == nil)
    }

    @Test func resampleKeepsPeaks() {
        let values: [Float] = [0, 0.1, 0.9, 0.2, 0, 0, 0.3, 0.1]
        #expect(WaveformScrubber.resample(values, to: 4) == [0.1, 0.9, 0, 0.3])
        #expect(WaveformScrubber.resample(values, to: 1) == [0.9])
        // Wider than the data: each source value is repeated rather than reading out of bounds.
        #expect(WaveformScrubber.resample([0.5, 1], to: 4) == [0.5, 0.5, 1, 1])
        #expect(WaveformScrubber.resample([], to: 3) == [0, 0, 0])
    }

    @Test func normalizationScalesToLoudest() {
        let normalized = WaveformLoader.normalized([0, 0.25, 0.5])
        #expect(normalized.first == 0)
        #expect(normalized.last == 1)
        // Quiet passages are lifted above their linear share.
        #expect(normalized[1] > 0.5)
        #expect(WaveformLoader.normalized([0, 0]) == [0, 0])
    }

    /// Same format as the recorder's mixdown: mono AAC in an m4a container. The second half is
    /// silent, so the waveform must show speech up front and a flat line after.
    @Test func loadsPeaksFromAnAACFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "waveform-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 48_000.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let frames = AVAudioFrameCount(rate * 2)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<Int(frames) {
                samples[index] = index < Int(rate) ? Float(sin(Double(index) * 2 * .pi * 440 / rate)) * 0.5 : 0
            }
            try file.write(from: buffer)
        }

        let peaks = try #require(await WaveformLoader.peaks(for: url, count: 20))
        #expect((19...22).contains(peaks.count))
        #expect(peaks.max() == 1)
        #expect(peaks.prefix(8).allSatisfy { $0 > 0.5 })
        #expect(peaks.suffix(5).allSatisfy { $0 < 0.1 })
    }

    @Test func completedActionItemsAreCheckedInMarkdown() {
        let summary = MeetingSummary(
            actionItems: [.init(task: "Write docs", owner: "Sam"), .init(task: "Ship", owner: nil)]
        )
        #expect(summary.markdown(completed: ["Ship"]) == "## Action Items\n- [ ] Write docs (Sam)\n- [x] Ship")

        let export = MeetingExporter.markdown(
            title: "T", date: .now, duration: 0, attendees: [], summary: summary, lines: [],
            completedActionItems: ["Write docs"]
        )
        #expect(export.contains("- [x] Write docs (Sam)\n- [ ] Ship"))
    }
}
