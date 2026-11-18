import Foundation
import Observation
import SwiftData

/// One persisted conversation: about a single meeting, or about the whole library.
@Observable
final class ChatController {
    let scope: ChatScope
    private(set) var messages: [ChatMessage] = []
    /// The answer being generated. Becomes a message once complete.
    private(set) var streamingText: String?
    private(set) var isResponding = false
    var errorMessage: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let corpus: any TranscriptCorpus
    @ObservationIgnored private var session: (any ChatSessioning)?
    @ObservationIgnored private var responseTask: Task<Void, Never>?

    init(scope: ChatScope, model: AppModel, corpus: any TranscriptCorpus) {
        self.scope = scope
        self.model = model
        self.corpus = corpus
        messages = storedMessages()
    }

    private var meeting: Meeting? {
        if case .meeting(let id) = scope { model?.meeting(with: id) } else { nil }
    }

    private func storedMessages() -> [ChatMessage] {
        guard let model else { return [] }
        switch scope {
        case .meeting:
            return (meeting?.messages ?? []).sorted { $0.date < $1.date }
        case .library:
            let descriptor = FetchDescriptor<ChatMessage>(
                predicate: #Predicate { $0.meeting == nil },
                sortBy: [SortDescriptor(\.date)]
            )
            return (try? model.context.fetch(descriptor)) ?? []
        }
    }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding, let model else { return }
        errorMessage = nil
        isResponding = true
        streamingText = ""

        let history = messages.map(\.turn)
        append(.user, question)

        responseTask = Task {
            defer {
                isResponding = false
                streamingText = nil
            }
            do {
                if session == nil {
                    session = await model.services.intelligence.makeChatSession(
                        scope: scope, corpus: corpus, history: history
                    )
                }
                guard let session else { return }
                var answer = ""
                for try await snapshot in session.respond(to: question) {
                    answer = snapshot
                    streamingText = snapshot
                }
                if !answer.isEmpty {
                    append(.assistant, answer)
                }
            } catch is CancellationError {
                // Stopped by the user. Keep what was said so far out of the history.
            } catch {
                errorMessage = error.localizedDescription
                // The session's own transcript may now be out of step with ours.
                session = nil
            }
        }
    }

    func stop() {
        responseTask?.cancel()
    }

    func clear() {
        stop()
        guard let model else { return }
        for message in messages {
            model.context.delete(message)
        }
        messages = []
        session = nil
        errorMessage = nil
    }

    private func append(_ role: ChatTurn.Role, _ text: String) {
        guard let model else { return }
        let message = ChatMessage(role: role, text: text)
        model.context.insert(message)
        message.meeting = meeting
        messages.append(message)
    }
}
