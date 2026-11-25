import Foundation
import Synchronization
import Testing
@testable import Memoir

struct SpeakerUITests {
    private func line(_ speaker: Speaker, _ start: TimeInterval, voice: Int? = nil) -> TranscriptLine {
        TranscriptLine(speaker: speaker, start: start, end: start + 1, text: "t", voice: voice)
    }

    // MARK: - Grouping

    @Test func eachVoiceStartsItsOwnBlock() {
        let lines = [
            line(.me, 0),
            line(.others, 2, voice: 1),
            line(.others, 4, voice: 1),
            line(.others, 6, voice: 2),
            line(.others, 8, voice: 1),
        ]
        let blocks = TranscriptGrouping.blocks(lines)
        #expect(blocks.map(\.speaker.voice) == [nil, 1, 2, 1])
        #expect(blocks.map { $0.lines.count } == [1, 2, 1, 1])
        #expect(TranscriptGrouping.rows(lines).map(\.startsBlock) == [true, true, false, true, true])
    }

    @Test func unidentifiedOthersStillGroupTogether() {
        let lines = [line(.others, 0), line(.others, 2), line(.others, 4, voice: 1)]
        #expect(TranscriptGrouping.rows(lines).map(\.startsBlock) == [true, false, true])
    }

    // MARK: - Palette

    @Test func voicesGetStableDistinctColorsThatCycle() {
        let count = SpeakerPalette.colors.count
        let indices = (1...count).map(SpeakerPalette.index(forVoice:))
        #expect(indices == Array(0..<count))
        #expect(SpeakerPalette.index(forVoice: count + 1) == 0)
        #expect(SpeakerPalette.index(forVoice: 2 * count + 3) == 2)
        // A voice number from a corrupt store must not crash the transcript.
        #expect((0..<count).contains(SpeakerPalette.index(forVoice: 0)))
        #expect((0..<count).contains(SpeakerPalette.index(forVoice: -4)))
    }

    @Test func onlyNumberedVoicesAreColored() {
        #expect(SpeakerPalette.color(for: SpeakerID(speaker: .me)) == nil)
        #expect(SpeakerPalette.color(for: SpeakerID(speaker: .others)) == nil)
        #expect(SpeakerPalette.color(for: SpeakerID(speaker: .others, voice: 1)) == SpeakerPalette.colors[0])
        #expect(SpeakerPalette.color(for: SpeakerID(speaker: .unknown, voice: 2)) == SpeakerPalette.colors[1])
    }

    // MARK: - Suggestions

    @Test func suggestsAttendeesNotYetUsed() {
        let attendees = ["Maya Chen", "Jonas Weber", "Priya Raman"]
        #expect(SpeakerNameSuggestions.suggestions(attendees: attendees, speakerNames: [:]) == attendees)
        #expect(SpeakerNameSuggestions.suggestions(attendees: attendees, speakerNames: [1: " maya chen "])
            == ["Jonas Weber", "Priya Raman"])
    }

    @Test func suggestionsIgnoreDuplicatesAndBlanks() {
        let attendees = ["Zoë Park", "Zoe Park", "", "  ", "Ana"]
        #expect(SpeakerNameSuggestions.suggestions(attendees: attendees, speakerNames: [:]) == ["Zoë Park", "Ana"])
        #expect(SpeakerNameSuggestions.suggestions(attendees: attendees, speakerNames: [2: "ZOE PARK"]) == ["Ana"])
    }

    @Test func typingNarrowsSuggestions() {
        let attendees = ["Maya Chen", "Jonas Weber", "Priya Raman"]
        #expect(SpeakerNameSuggestions.suggestions(attendees: attendees, speakerNames: [:], query: "ra")
            == ["Priya Raman"])
        #expect(SpeakerNameSuggestions.suggestions(attendees: attendees, speakerNames: [:], query: "  ") == attendees)
    }

    // MARK: - Optional model controller

    @Test func installReportsProgressThenInstalled() async {
        let models = FakeOptionalModels(script: .install(size: 1_000))
        let controller = OptionalModelController(model: .speakerIdentification)
        controller.install(using: models)
        #expect(controller.isDownloading)
        await settle { !controller.isDownloading }
        #expect(controller.availability == .installed(size: 1_000))
        #expect(controller.failure == nil)
    }

    @Test func installWhenAlreadyInstalledDownloadsNothing() async {
        let models = FakeOptionalModels(script: .hang, installed: [.speakerIdentification: 5])
        let controller = OptionalModelController(model: .speakerIdentification)
        await controller.refresh(using: models)
        controller.install(using: models)
        #expect(!controller.isDownloading)
        #expect(controller.availability == .installed(size: 5))
        #expect(models.installCalls == 0)
    }

    @Test func failedDownloadKeepsTheErrorForRetry() async {
        let models = FakeOptionalModels(script: .fail("No connection"))
        let controller = OptionalModelController(model: .enhancedTranscription)
        controller.install(using: models)
        await settle { !controller.isDownloading }
        #expect(controller.availability == .notInstalled)
        #expect(controller.failure == "No connection")
    }

    /// An install stream can end without an error and still leave nothing on disk.
    @Test func streamEndingWithoutInstallIsAFailure() async {
        let models = FakeOptionalModels(script: .finishWithoutInstalling)
        let controller = OptionalModelController(model: .enhancedTranscription)
        controller.install(using: models)
        await settle { !controller.isDownloading }
        #expect(controller.availability == .notInstalled)
        #expect(controller.failure != nil)
    }

    @Test func cancelStopsTheDownloadAndSettles() async {
        let models = FakeOptionalModels(script: .hang)
        let controller = OptionalModelController(model: .speakerIdentification)
        controller.install(using: models)
        await settle { controller.availability == .downloading(0.5) }
        await controller.cancel(using: models)
        #expect(!controller.isDownloading)
        #expect(controller.availability == .notInstalled)
        #expect(controller.failure == nil)
        await settle { models.cancellations == 1 }
        #expect(models.cancellations == 1)

        // Nothing left over blocks a second attempt.
        controller.install(using: models)
        #expect(controller.isDownloading)
        await controller.cancel(using: models)
        #expect(controller.availability == .notInstalled)
    }

    @Test func removeGoesBackToNotInstalled() async {
        let models = FakeOptionalModels(script: .hang, installed: [.enhancedTranscription: 9])
        let controller = OptionalModelController(model: .enhancedTranscription)
        await controller.refresh(using: models)
        await controller.remove(using: models)
        #expect(controller.availability == .notInstalled)
        #expect(!controller.isRemoving)
    }

    @Test func clearingFailureKeepsTheState() async {
        let models = FakeOptionalModels(script: .fail("Disk full"))
        let controller = OptionalModelController(model: .enhancedTranscription)
        controller.install(using: models)
        await settle { !controller.isDownloading }
        controller.clearFailure()
        #expect(controller.failure == nil)
        #expect(controller.availability == .notInstalled)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private nonisolated final class FakeOptionalModels: OptionalModelManaging {
    enum Script: Sendable {
        case install(size: Int64)
        case fail(String)
        case finishWithoutInstalling
        /// Reports halfway and then never finishes.
        case hang
    }

    private struct State {
        var installed: [OptionalModel: Int64]
        var installCalls = 0
        var cancellations = 0
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private let script: Script
    private let state: Mutex<State>

    init(script: Script, installed: [OptionalModel: Int64] = [:]) {
        self.script = script
        state = Mutex(State(installed: installed))
    }

    var installCalls: Int { state.withLock { $0.installCalls } }
    var cancellations: Int { state.withLock { $0.cancellations } }

    func isInstalled(_ model: OptionalModel) async -> Bool {
        state.withLock { $0.installed[model] != nil }
    }

    func installedSize(of model: OptionalModel) async -> Int64? {
        state.withLock { $0.installed[model] }
    }

    func install(_ model: OptionalModel) -> AsyncThrowingStream<Double, Error> {
        state.withLock { $0.installCalls += 1 }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    self.state.withLock { $0.cancellations += 1 }
                }
            }
            continuation.yield(0.5)
            switch script {
            case .install(let size):
                state.withLock { $0.installed[model] = size }
                continuation.finish()
            case .fail(let message):
                continuation.finish(throwing: Failure(errorDescription: message))
            case .finishWithoutInstalling:
                continuation.finish()
            case .hang:
                break
            }
        }
    }

    func remove(_ model: OptionalModel) async throws {
        _ = state.withLock { $0.installed.removeValue(forKey: model) }
    }
}
