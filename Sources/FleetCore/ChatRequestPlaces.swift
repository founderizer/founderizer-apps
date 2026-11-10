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

/// **Needs you keeps its order while he looks at it** (fix round 3b; D-7 item 2, B-MOT-12): a request he answers there
/// folds where it stands in the frame he answers it (`WordsOnTheirWay`), and the reading that confirms the answer moves
/// nothing — neither that card nor any other. The page sorted its list again with that reading, a round trip after the
/// fold: the open requests first, newest first, then the answered ones, so "Nothing needs you" came over the list and the
/// card he answered went 268 points down. The page's own order comes back the next time he opens it.
public struct NeedsOrder: Sendable, Equatable {
    /// The requests that this visit drew in the open group at the top, and in the answered group under the owner's tasks,
    /// each in the order it drew them.
    public private(set) var top: [Int] = []
    public private(set) var bottom: [Int] = []

    public init() {}

    /// The two groups of `needs` as the page draws them now: every request it drew keeps its group and its place, also
    /// one that was answered meanwhile; a new open request comes at the top, and a new answered one at the head of the
    /// answered ones, newest first; a request that the hub no longer lists goes. With nothing drawn yet, that is the
    /// page's own order.
    public func groups(of needs: [OwnerNeed]) -> (top: [OwnerNeed], bottom: [OwnerNeed]) {
        let byID = Dictionary(needs.map { ($0.id, $0) }) { first, _ in first }
        let drawn = Set(top).union(bottom)
        let new = needs.filter { !drawn.contains($0.id) }.sorted { $0.id > $1.id }
        return (new.filter(\.isOpen) + top.compactMap { byID[$0] }, new.filter { !$0.isOpen } + bottom.compactMap { byID[$0] })
    }

    /// Keeps the groups that the page draws for `needs`.
    public mutating func keep(_ needs: [OwnerNeed]) {
        let now = groups(of: needs)
        top = now.top.map(\.id)
        bottom = now.bottom.map(\.id)
    }
}
