import Foundation
import FoundationModels

// Property order is generation order. The title comes after the overview so the model names
// the meeting once it has worked out what it was about, and decisions and action items come
// last, where an empty list is the natural ending rather than something to fill.

@Generable(description: "A faithful summary of one meeting")
nonisolated struct GeneratedSummary {
    @Guide(description: "Two to four short sentences naming the main subject and the most important outcomes. Do not list every topic. Only facts from the transcript. Do not describe the meeting itself, for example 'the meeting ended with a recap'.")
    var overview: String

    @Guide(description: "A short, specific title of three to eight words naming the main topic, for example 'Q3 launch timeline review'. Not a generic title like 'Team meeting'.")
    var title: String

    @Guide(description: "The most important points, each one short, specific sentence stating a fact or outcome. Cover every major topic in order. No repetition.", .maximumCount(10))
    var keyPoints: [String]

    @Guide(description: "Choices the participants explicitly agreed on, such as a new date, an approved amount or a selected option. Not tasks. Empty if nothing was decided.", .maximumCount(6))
    var decisions: [String]

    @Guide(description: "Concrete tasks someone committed to or was asked to do, one task per item, never two tasks joined in one item. Empty if there were none.", .maximumCount(10))
    var actionItems: [GeneratedActionItem]
}

@Generable(description: "A task someone took on during the meeting")
nonisolated struct GeneratedActionItem {
    @Guide(description: "The task, starting with a verb")
    var task: String

    @Guide(description: "Who will do it. 'You' only when a 'You:' line says they will do it. A person's name or speaker label such as 'Speaker 2' when the transcript makes it clear. Omit when unclear.")
    var owner: String?
}

nonisolated extension MeetingSummary {
    init(_ generated: GeneratedSummary) {
        self.init(
            title: Self.clean(generated.title),
            overview: Self.clean(generated.overview),
            keyPoints: Self.cleanList(generated.keyPoints),
            decisions: Self.cleanList(generated.decisions),
            actionItems: generated.actionItems.compactMap { item in
                let task = Self.clean(item.task)
                guard !task.isEmpty else { return nil }
                return ActionItem(task: task, owner: Self.cleanOwner(item.owner))
            }
        )
    }

    init(_ partial: GeneratedSummary.PartiallyGenerated) {
        self.init(
            title: Self.clean(partial.title ?? ""),
            overview: Self.clean(partial.overview ?? ""),
            keyPoints: Self.cleanList(partial.keyPoints ?? []),
            decisions: Self.cleanList(partial.decisions ?? []),
            actionItems: (partial.actionItems ?? []).compactMap { item in
                let task = Self.clean(item.task ?? "")
                guard !task.isEmpty else { return nil }
                return ActionItem(task: task, owner: Self.cleanOwner(item.owner ?? nil))
            }
        )
    }

    private static func clean(_ text: String) -> String {
        var text = TranscriptFormat.collapseWhitespace(text)
        if text.count > 1, text.first == "\"", text.last == "\"" {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func cleanList(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.map(clean).filter { item in
            guard !item.isEmpty, !isPlaceholder(item) else { return false }
            return seen.insert(item.lowercased()).inserted
        }
    }

    /// The model sometimes fills an empty list with "None" instead of leaving it empty.
    private static func isPlaceholder(_ item: String) -> Bool {
        let normalized = item.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["none", "n/a", "na", "no decisions", "no action items", "no decisions were made",
                "no action items were assigned", "nothing", "-"].contains(normalized)
    }

    /// A numbered label like "Speaker 2" is kept: it points at one specific person in this
    /// meeting, which is more useful than no owner. Only the unnumbered, generic words go.
    private static func cleanOwner(_ owner: String?) -> String? {
        guard let owner else { return nil }
        let cleaned = clean(owner)
        let lowered = cleaned.lowercased()
        if cleaned.isEmpty || ["unknown", "none", "n/a", "unassigned", "others", "speaker", "everyone", "null"].contains(lowered) {
            return nil
        }
        return cleaned
    }
}
