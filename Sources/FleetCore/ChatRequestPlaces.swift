import Foundation

/// **Where each request of an agent stands in its chat** (D-7 item 1, the lead's call of 29 October 2026): right after
/// the agent's message that told the owner about it ("It is in Needs you."), as the decision's mockup draws it, so his
/// next message and the agent's next line stand under it. A waiting card that stood at the end of the chat took his next
/// message above it; an answered one folds where it stood, and his answer, which the card shows, is not a second bubble.
///
/// The hub links no request to a message, so the message is found by time, in the agent's own chat:
///   1. the agent's messages that came after the request was raised, up to the owner's next message — the reply of the
///      turn in which it was raised — and the card stands after the last of them;
///   2. else the agent's message right before it was raised, when nothing of the owner's stands between the two (the
///      agent told him first and raised it after);
///   3. else no message told him: a waiting card stands at the end of the chat, where he sees it, and an answered one
///      in the place of his answer. A request whose place is older than the messages the chat holds is not placed by
///      them: at the end while it waits, and not drawn once answered, unless its answer is among them.
public struct ChatRequestPlaces: Sendable, Equatable {
    /// The cards that stand right after an entry, by the entry's id, in the order they were raised.
    public var after: [String: [Int]] = [:]
    /// The waiting requests that no message told him about, at the end of the chat, in the order they were raised.
    public var atEnd: [Int] = []
    /// His answer messages, by entry id, whose folded card stands in their place.
    public var inPlaceOf: [String: Int] = [:]
    /// His answer messages that are not drawn: the card of their request stands where it was raised, and shows them.
    public var hidden: Set<String> = []

    public init() {}

    /// The places of `needs` (this agent's requests, waiting and answered) among `entries` (its chat, oldest first).
    /// `whole`: the entries are the chat's whole history, not only its newest part.
    public static func of(needs: [OwnerNeed], in entries: [ChatEntry], whole: Bool) -> ChatRequestPlaces {
        var places = ChatRequestPlaces()
        for need in needs.sorted(by: { ($0.raised, $0.id) < ($1.raised, $1.id) }) {
            let answer = entries.first { entry in
                if case .message(let message) = entry { message.kind == "answer" && message.need_id == need.id } else { false }
            }?.id
            if let message = told(about: need, in: entries, whole: whole) {
                places.after[message, default: []].append(need.id)
                if let answer { places.hidden.insert(answer) }
            } else if need.isOpen {
                places.atEnd.append(need.id)
            } else if let answer {
                places.inPlaceOf[answer] = need.id
            }
        }
        return places
    }

    /// The agent's message that told the owner about `need`, by the three steps above, or nil.
    static func told(about need: OwnerNeed, in entries: [ChatEntry], whole: Bool) -> String? {
        let split = entries.firstIndex { $0.created >= need.raised } ?? entries.count
        // Raised before the oldest entry held here: its own message, if any, is older still.
        if split == 0 && !whole { return nil }
        var reply: String?
        for entry in entries[split...] {
            guard case .report = entry else { break }
            reply = entry.id
        }
        if let reply { return reply }
        if split > 0, case .report = entries[split - 1] { return entries[split - 1].id }
        return nil
    }
}
