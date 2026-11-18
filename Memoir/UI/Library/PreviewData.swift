#if DEBUG
import Foundation
import SwiftData

extension Meeting {
    /// Sample meetings for previews: one finished with summary and transcript, one without a
    /// summary, one from yesterday with no transcript.
    @discardableResult
    static func samples(in context: ModelContext) -> [Meeting] {
        let now = Date.now

        let standup = Meeting(title: "Design Review", hasCustomTitle: true, startDate: now.addingTimeInterval(-3 * 3600))
        standup.status = .ready
        standup.duration = 42 * 60
        standup.sourceAppName = "Zoom"
        standup.attendees = ["Maya Chen", "Jonas Weber"]
        standup.summary = MeetingSummary(
            title: "Design Review",
            overview: "The team agreed on the new onboarding flow and a launch date.",
            keyPoints: ["Onboarding drops from five steps to three", "Dark mode ships with the first release"],
            decisions: ["Launch on the first Monday of next month"],
            actionItems: [.init(task: "Update the prototype", owner: "Maya"), .init(task: "Write release notes", owner: nil)]
        )
        let lines: [(Speaker, TimeInterval, String)] = [
            (.me, 2, "Thanks for joining. Let's start with the onboarding flow."),
            (.me, 9, "I think three steps is the right number."),
            (.others, 16, "Agreed. The permissions step can move into the first run."),
            (.others, 24, "We should also confirm the launch date today."),
            (.me, 31, "Let's say the first Monday of next month."),
        ]
        add(lines, to: standup, in: context)

        let call = Meeting(title: "Call at 9:15 AM", startDate: now.addingTimeInterval(-26 * 3600))
        call.status = .ready
        call.duration = 65 * 60
        call.sourceAppName = "FaceTime"
        add([(.unknown, 0, "Quick sync about the budget numbers."), (.unknown, 14, "Numbers look fine to me.")], to: call, in: context)

        let silent = Meeting(title: "Voice Note", startDate: now.addingTimeInterval(-5 * 24 * 3600))
        silent.status = .ready
        silent.duration = 3 * 60
        silent.hasAudio = true

        for meeting in [standup, call, silent] { context.insert(meeting) }
        return [standup, call, silent]
    }

    private static func add(_ lines: [(Speaker, TimeInterval, String)], to meeting: Meeting, in context: ModelContext) {
        context.insert(meeting)
        for (speaker, start, text) in lines {
            let segment = TranscriptSegment(line: TranscriptLine(speaker: speaker, start: start, end: start + 6, text: text))
            context.insert(segment)
            segment.meeting = meeting
        }
    }
}
#endif
