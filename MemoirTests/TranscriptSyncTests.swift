import Foundation
import Testing
@testable import Memoir

struct TranscriptSyncTests {
    private func line(_ speaker: Speaker, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptLine {
        TranscriptLine(speaker: speaker, start: start, end: end, text: "t")
    }

    private func line(_ start: TimeInterval, _ end: TimeInterval) -> TranscriptLine {
        line(.me, start, end)
    }

    @Test func nothingIsCurrentBeforeTheFirstLineOrInAnEmptyTranscript() {
        let lines = [line(5, 8), line(10, 12)]
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 0) == nil)
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 4.8) == nil)
        #expect(TranscriptGrouping.currentLineID(in: [], at: 3) == nil)
    }

    @Test func lineBecomesCurrentSlightlyBeforeItStarts() {
        let lines = [line(0, 4), line(10, 12)]
        let lead = TranscriptGrouping.highlightLead
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 10 - lead) == lines[1].id)
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 10 - lead - 0.01) == lines[0].id)
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 10) == lines[1].id)
    }

    @Test func lineStaysCurrentThroughTheGapAfterIt() {
        let lines = [line(0, 4), line(20, 22)]
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 4.5) == lines[0].id)
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 19) == lines[0].id)
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 500) == lines[1].id)
    }

    @Test func latestStartWinsWhenSpeakersOverlap() {
        let lines = [line(.me, 0, 10), line(.others, 3, 6), line(.others, 3, 8)]
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 2) == lines[0].id)
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 4) == lines[2].id)
        #expect(TranscriptGrouping.currentLineID(in: lines, at: 9) == lines[2].id)
    }

    @Test func binarySearchMatchesLinearScanOnLongTranscripts() {
        var generator = SystemRandomNumberGenerator()
        var start: TimeInterval = 0
        var lines: [TranscriptLine] = []
        for _ in 0..<5_000 {
            start += Double.random(in: 0...4, using: &generator)
            lines.append(line(start, start + 2))
        }
        for _ in 0..<2_000 {
            let time = Double.random(in: -1...(start + 5), using: &generator)
            let expected = lines.last { $0.start <= time + TranscriptGrouping.highlightLead }?.id
            #expect(TranscriptGrouping.currentLineID(in: lines, at: time) == expected)
        }
    }

    @Test func rowsMarkTheStartOfEachSpeakerTurn() {
        let lines = [line(.me, 0, 1), line(.me, 2, 3), line(.others, 4, 5), line(.me, 6, 7)]
        let rows = TranscriptGrouping.rows(lines)
        #expect(rows.map(\.id) == lines.map(\.id))
        #expect(rows.map(\.startsBlock) == [true, false, true, true])
    }

    @Test func seeksAreCountedAndClamped() {
        let playback = PlaybackController.preview(at: 0, of: 60)
        playback.seek(to: 90)
        #expect(playback.currentTime == 60)
        playback.seek(to: -5, play: true)
        #expect(playback.currentTime == 0)
        #expect(playback.isPlaying)
        #expect(playback.seekGeneration == 2)
        playback.unload()
    }
}
