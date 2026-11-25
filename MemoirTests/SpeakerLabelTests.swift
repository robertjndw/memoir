import Foundation
import SwiftData
import Testing
@testable import Memoir

struct SpeakerLabelTests {
    private func line(_ speaker: Speaker, voice: Int? = nil, name: String? = nil) -> TranscriptLine {
        TranscriptLine(speaker: speaker, start: 0, end: 1, text: "x", voice: voice, name: name)
    }

    @Test func fallsBackToTheSideLabel() {
        #expect(line(.me).label == "You")
        #expect(line(.others).label == "Others")
        #expect(line(.unknown).label == "Speaker")
    }

    @Test func voiceWithoutNameIsNumbered() {
        #expect(line(.others, voice: 2).label == "Speaker 2")
    }

    @Test func nameWinsOverVoice() {
        #expect(line(.others, voice: 2, name: "Dana").label == "Dana")
    }

    @Test func emptyNameIsIgnored() {
        #expect(line(.others, voice: 3, name: "").label == "Speaker 3")
        #expect(line(.others, name: "").label == "Others")
    }

    @Test func speakerIDDistinguishesVoices() {
        #expect(line(.others, voice: 1).speakerID != line(.others, voice: 2).speakerID)
        #expect(line(.others, voice: 1).speakerID == line(.others, voice: 1, name: "Dana").speakerID)
        #expect(line(.others).speakerID != line(.others, voice: 1).speakerID)
    }

    // The meeting dies with its context, so the container has to travel with it.
    @MainActor private func makeMeeting() -> (meeting: Meeting, container: ModelContainer) {
        let container = ModelContainer.memoir(inMemory: true)
        let meeting = Meeting(title: "Panel", hasCustomTitle: true)
        meeting.segments = [
            // Deliberately out of order: the relationship is unordered.
            TranscriptSegment(line: TranscriptLine(speaker: .others, start: 6, end: 7, text: "Agreed", voice: 2)),
            TranscriptSegment(line: TranscriptLine(speaker: .me, start: 0, end: 1, text: "Welcome")),
            TranscriptSegment(line: TranscriptLine(speaker: .others, start: 2, end: 3, text: "Thanks", voice: 1)),
            TranscriptSegment(line: TranscriptLine(speaker: .others, start: 4, end: 5, text: "Same", voice: 2)),
        ]
        container.mainContext.insert(meeting)
        return (meeting, container)
    }

    @MainActor @Test func sortedLinesCarryVoicesAndLabels() {
        let (meeting, container) = makeMeeting()
        defer { withExtendedLifetime(container) {} }
        let lines = meeting.sortedLines
        #expect(lines.map(\.voice) == [nil, 1, 2, 2])
        #expect(lines.map(\.name) == [nil, nil, nil, nil])
        #expect(lines.map(\.label) == ["You", "Speaker 1", "Speaker 2", "Speaker 2"])
    }

    @MainActor @Test func speakerNamesApplyPerVoice() {
        let (meeting, container) = makeMeeting()
        defer { withExtendedLifetime(container) {} }
        meeting.speakerNames = [2: "Dana"]
        let lines = meeting.sortedLines
        #expect(lines.map(\.name) == [nil, nil, "Dana", "Dana"])
        #expect(lines.map(\.label) == ["You", "Speaker 1", "Dana", "Dana"])
    }

    @MainActor @Test func renamingChangesLabelsAndClearingRestoresThem() {
        let (meeting, container) = makeMeeting()
        defer { withExtendedLifetime(container) {} }
        meeting.speakerNames = [1: "Sam", 2: "Dana"]
        meeting.speakerNames = [1: "Samira"]
        #expect(meeting.sortedLines.map(\.label) == ["You", "Samira", "Speaker 2", "Speaker 2"])
        meeting.speakerNames = [:]
        #expect(meeting.sortedLines.map(\.label) == ["You", "Speaker 1", "Speaker 2", "Speaker 2"])
    }

    @MainActor @Test func namedLinesRenderInTranscriptText() {
        let (meeting, container) = makeMeeting()
        defer { withExtendedLifetime(container) {} }
        meeting.speakerNames = [1: "Sam"]
        let text = TranscriptFormat.render(meeting.sortedLines)
        #expect(text.contains("[00:02] Sam: Thanks"))
        #expect(text.contains("[00:06] Speaker 2: Agreed"))
    }

    @MainActor @Test func linesWithoutVoicesKeepTheirSideLabel() {
        let container = ModelContainer.memoir(inMemory: true)
        let meeting = Meeting(title: "Old", hasCustomTitle: true)
        meeting.segments = [TranscriptSegment(line: TranscriptLine(speaker: .others, start: 0, end: 1, text: "Hi"))]
        meeting.speakerNames = [1: "Sam"]
        container.mainContext.insert(meeting)
        #expect(meeting.sortedLines.map(\.label) == ["Others"])
    }
}
