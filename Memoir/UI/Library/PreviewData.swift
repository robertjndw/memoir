#if DEBUG
import Foundation
import SwiftData
import SwiftUI

// Debug-only, so previews using any of this need `#if DEBUG` as well or Release won't build.
//
// The canvas can run a preview body more than once. Keep the model in
// `@Previewable @State var model = AppModel.preview(...)` so it's only built once, and feed
// meeting lists through `QueriedMeetings`. Lists built from a plain array of models crash
// in the macOS List diffing; going through @Query like the Library does doesn't.

extension AppModel {
    /// Fresh settings and an empty in-memory store on every call. Use `configure` to set up
    /// a recording or extra data before any view sees the model.
    static func preview(
        services: Services = .preview,
        hasCompletedOnboarding: Bool = false,
        samples: Bool = false,
        configure: (AppModel) -> Void = { _ in }
    ) -> AppModel {
        let suite = "Memoir.preview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.hasCompletedOnboarding = hasCompletedOnboarding
        let model = AppModel(settings: settings, container: .memoir(inMemory: true), services: services)
        if samples { Meeting.samples(in: model.context) }
        configure(model)
        // Without this, autosave kicks in right as a List attaches to its window and the
        // List crashes now and then.
        try? model.context.save()
        return model
    }

    /// The stored meeting with this title. Previews only, so a missing title is a typo.
    func previewMeeting(_ title: String) -> Meeting {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.title == title })
        guard let meeting = try? context.fetch(descriptor).first else {
            preconditionFailure("No preview meeting titled \(title)")
        }
        return meeting
    }
}

/// Hands a preview the meetings in the environment's store through `@Query`, newest first.
struct QueriedMeetings<Content: View>: View {
    @Query(sort: \Meeting.startDate, order: .reverse) private var meetings: [Meeting]
    @ViewBuilder var content: ([Meeting]) -> Content

    var body: some View {
        content(meetings)
    }
}

extension Services {
    /// `inert`, but with Apple Intelligence available and canned answers, so summary and chat
    /// previews don't all show "unavailable".
    static var preview: Services {
        var services = Services.inert
        services.intelligence = PreviewIntelligence()
        return services
    }
}

private nonisolated struct PreviewIntelligence: Intelligence {
    private struct Session: ChatSessioning {
        func respond(to question: String) -> AsyncThrowingStream<String, Error> {
            let answer = "The team agreed to launch on **the first Monday of next month** [0:31]. Maya updates the prototype before then [0:16]."
            return AsyncThrowingStream { continuation in
                let task = Task {
                    var text = ""
                    for word in answer.split(separator: " ") {
                        try? await Task.sleep(for: .milliseconds(60))
                        if Task.isCancelled { break }
                        text += text.isEmpty ? String(word) : " \(word)"
                        continuation.yield(text)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    var availability: IntelligenceAvailability { .available }
    func prewarm() {}

    func summarize(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryProgress, Error> {
        let full = MeetingSummary.sample
        let steps = [
            MeetingSummary(title: full.title, overview: full.overview),
            MeetingSummary(title: full.title, overview: full.overview, keyPoints: full.keyPoints),
            MeetingSummary(title: full.title, overview: full.overview, keyPoints: full.keyPoints, decisions: full.decisions),
        ]
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in steps {
                    try? await Task.sleep(for: .milliseconds(400))
                    continuation.yield(.partial(step))
                }
                continuation.yield(.finished(full))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeChatSession(scope: ChatScope, corpus: any TranscriptCorpus, history: [ChatTurn]) async
        -> any ChatSessioning
    {
        Session()
    }
}

extension Meeting {
    /// Sample meetings for previews: one finished with summary and transcript, one without a
    /// summary, one from a few days ago with audio but no transcript.
    @discardableResult
    static func samples(in context: ModelContext) -> [Meeting] {
        let now = Date.now

        let review = Meeting(title: "Design Review", hasCustomTitle: true, startDate: now.addingTimeInterval(-3 * 3600))
        review.status = .ready
        review.duration = 42 * 60
        review.sourceAppName = "FaceTime"
        review.sourceAppBundleID = "com.apple.FaceTime"
        review.attendees = ["Maya Chen", "Jonas Weber"]
        review.summary = MeetingSummary(
            title: "Design Review",
            overview: "The team agreed on the new onboarding flow and a launch date.",
            keyPoints: ["Onboarding drops from five steps to three", "Dark mode ships with the first release"],
            decisions: ["Launch on the first Monday of next month"],
            actionItems: [.init(task: "Update the prototype", owner: "Maya"), .init(task: "Write release notes", owner: nil)]
        )
        add(sampleLines, to: review, in: context)

        let call = Meeting(title: "Call at 9:15 AM", startDate: now.addingTimeInterval(-26 * 3600))
        call.status = .ready
        call.duration = 65 * 60
        call.sourceAppName = "Zoom"
        call.sourceAppBundleID = "us.zoom.xos"
        add([
            TranscriptLine(speaker: .unknown, start: 0, end: 6, text: "Quick sync about the budget numbers."),
            TranscriptLine(speaker: .unknown, start: 14, end: 20, text: "Numbers look fine to me."),
        ], to: call, in: context)

        let voiceNote = Meeting(title: "Voice Note", startDate: now.addingTimeInterval(-5 * 24 * 3600))
        voiceNote.status = .ready
        voiceNote.duration = 3 * 60
        voiceNote.hasAudio = true
        context.insert(voiceNote)

        return [review, call, voiceNote]
    }

    /// A short two-speaker exchange, also used as the live transcript of a preview recording.
    static let sampleLines: [TranscriptLine] = [
        TranscriptLine(speaker: .me, start: 2, end: 8, text: "Thanks for joining. Let's start with the onboarding flow."),
        TranscriptLine(speaker: .me, start: 9, end: 15, text: "I think three steps is the right number."),
        TranscriptLine(speaker: .others, start: 16, end: 22, text: "Agreed. The permissions step can move into the first run."),
        TranscriptLine(speaker: .others, start: 24, end: 30, text: "We should also confirm the launch date today."),
        TranscriptLine(speaker: .me, start: 31, end: 37, text: "Let's say the first Monday of next month."),
    ]

    private static func add(_ lines: [TranscriptLine], to meeting: Meeting, in context: ModelContext) {
        context.insert(meeting)
        for line in lines {
            let segment = TranscriptSegment(line: line)
            context.insert(segment)
            segment.meeting = meeting
        }
    }
}
#endif
