import Foundation

/// **Where each request of an agent stands in its chat: where it was raised** (the owner, 14 November 2026: "Cards
/// during a thread should appear wherever in the conversation they were requested, not all at the bottom of the
/// conversation!"; `inTime`, one rule for the Mac and the iPhone while a request waits). A request is a part of the
/// conversation at the time the agent raised it, and what came after it stands under it; an answered one stays there
/// on the iPhone, and on the Mac it stands where he answered it (the last paragraph). Every waiting request that no message of the agent's
/// told him about stood at the end of the chat instead: eight of them on his fleet that day, some a week old, under
/// the reply to the answer that he had just written.
///
/// The hub links no request to a message, so its place is its time, in the agent's own chat: under everything that
/// came before it was raised and over everything that came after, and at the end of the chat only while nothing came
/// after it. One entry that came after it stands over it: **the agent's reply of the turn in which it was raised**
/// ("It is in Needs you.", then the card: D-7 item 1), which is the agent's first message after the request when it
/// answers (`in_reply_to`) a message of his that is older than the request. A request raised before the oldest entry
/// that the chat holds is not drawn until he asks for the earlier messages (on the Mac, one that he answered among
/// the entries held is drawn at that answer).
///
/// The rule of 29 October 2026 took every message of the agent's after a request, up to his next message, for that
/// reply, and put the card under the last of them: on his fleet, 20 of 56 requests stood under a message that came
/// more than ten minutes after them, some half a day after. A waiting request that no such message told him about
/// stood at the end of the chat, and an answered one in the place of his answer.
///
/// **What he answers in his own words is his message in the chat** (the same day: "When I reply to a card, the
/// conversation should follow!"): it stands at its time as every message of his, with the agent's reply under it, and
/// its card folds to its title where it stands (`spoken`). An option that he pressed is no bubble, also while its
/// card is among the earlier messages: its card shows it (`hidden`).
///
/// **On the Mac an answered request stands where he answered it** (`Answered.atItsAnswer`; the owner, 19 November
/// 2026, of his chat with the Fleet Manager after he answered twelve requests: "it does not have any context... maybe
/// we sohuld show a row/card with the reply there?", and "A: the card" to its picture): its folded card, with his
/// answer on it, stands in the place of his answer, for an option that he pressed and for words that he wrote, and
/// that answer is no bubble of its own. A request that waits stays where it was raised, and so does one that closed
/// with no message of his in the chat: the hub or its agent closed it, or he answered on the hub's own page, which
/// writes none. On his fleet that morning
/// nine options that he pressed drew nothing at the time he pressed them (each card folded where it was raised, up to
/// two days higher), two answers in words stood as "Done" alone, and a reply of the manager's about one request stood
/// under his "Done" to another. The iPhone keeps the rule above (`whereRaised`).
public struct ChatRequestPlaces: Sendable, Equatable {
    /// Where an answered request stands: where it was raised, with what he wrote as his own message (the iPhone), or
    /// in the place of his answer, which its card says (the Mac).
    public enum Answered: Sendable { case whereRaised, atItsAnswer }

    /// The answered cards that stand in the place of his answer, by that answer's entry id (`Answered.atItsAnswer`).
    public var inPlace: [String: Int] = [:]
    /// When he answered each request whose card stands at its answer, by the request's number: the card's time for the
    /// marks of a day or an hour (`cardTimes`).
    public var answeredAt: [Int: Double] = [:]
    /// The cards that stand right after an entry, by the entry's id, in the order they were raised.
    public var after: [String: [Int]] = [:]
    /// The cards that stand right before an entry, by the entry's id, in the order they were raised.
    public var before: [String: [Int]] = [:]
    /// The cards at the end of the chat, in the order they were raised: the ones that nothing came after.
    public var atEnd: [Int] = []
    /// His answer messages that are not drawn: the card of their request shows them.
    public var hidden: Set<String> = []
    /// The requests whose answer stands in the chat as his own message: their card folds to its title.
    public var spoken: Set<Int> = []

    public init() {}

    /// The places of `needs` (this agent's requests, waiting and answered) among `entries` (its chat, oldest first), each
    /// where it was raised. `whole`: the entries are the chat's whole history, not only its newest part. `answered`:
    /// where an answered request stands (`Answered`).
    public static func inTime(needs: [OwnerNeed], in entries: [ChatEntry], whole: Bool,
                              answered: Answered = .whereRaised) -> ChatRequestPlaces {
        var places = ChatRequestPlaces()
        let raised = needs.sorted(by: { ($0.raised, $0.id) < ($1.raised, $1.id) })
        // The cards that the chat draws where they were raised, each with the index of the first entry that came after.
        var drawn: [(need: OwnerNeed, split: Int)] = []
        for need in raised {
            let answer = answer(to: need, in: entries)
            if answered == .atItsAnswer, let answer {
                // His answer among the entries, the hub's copy or his words and his press on their way: the card
                // stands in its place and says it, also when it was raised before the oldest entry held here. A
                // request that closed with no message of his in this chat (the hub or its agent closed it, or he
                // answered on the hub's own page) stays where it was raised, by the lines under these.
                places.inPlace[ChatEntry.message(answer).id] = need.id
                places.answeredAt[need.id] = answer.created
                continue
            }
            let split = entries.firstIndex { $0.created >= need.raised } ?? entries.count
            // Raised before the oldest entry held here: its place is among the earlier messages.
            let shows = split > 0 || whole
            if shows { drawn.append((need, split)) }
            guard let answer else { continue }
            // While the reading still has the request open, the answer among the entries is his words on their way,
            // which the chat itself put there (no event of the hub's yet). The fleet's reading is one snapshot of the
            // hub, so the hub's copy of an answer does not come beside its open request; should a reading hold both,
            // its words say whether he pressed them.
            let inWords = need.isOpen ? answer.event_id == 0 || !need.offers(answer.text) : need.answeredInWords
            if !inWords {
                places.hidden.insert(ChatEntry.message(answer).id)
            } else if shows {
                places.spoken.insert(need.id)
            }
        }
        for (need, split) in drawn {
            if let reply = turnReply(at: split, in: entries) {
                places.after[reply, default: []].append(need.id)
            } else if let next = entries[split...].first(where: { !places.hidden.contains($0.id) }) {
                places.before[next.id, default: []].append(need.id)
            } else {
                places.atEnd.append(need.id)
            }
        }
        return places
    }

    /// The agent's reply of the turn in which a request was raised, whose first later entry is `entries[split]`: that
    /// entry, when it is the agent's and answers a message of his that stands before it. Else nil.
    private static func turnReply(at split: Int, in entries: [ChatEntry]) -> String? {
        guard split < entries.count, case .report(let report) = entries[split], let asked = report.in_reply_to else { return nil }
        let his = entries[..<split].contains { entry in
            if case .message(let message) = entry { message.request_id.caseInsensitiveCompare(asked) == .orderedSame } else { false }
        }
        return his ? entries[split].id : nil
    }

    /// **The chat's rows in order**: the entries that are drawn, and each request's card in its place. One
    /// list, so a card has one identity in the chat wherever it stands: an entry that comes after a card at the chat's
    /// end moves the card over it, and the view of that card, with the cursor in its answer, stays the same view.
    /// **One row for one id**: an entry that comes a second time under the id of an entry before it (his words on
    /// their way beside the hub's copy of them, which keeps their id) is not drawn, so no card and no message stands
    /// twice.
    public func rows(of entries: [ChatEntry]) -> [ChatPart] {
        var rows: [ChatPart] = []
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.id).inserted {
            rows += (before[entry.id] ?? []).map(ChatPart.request)
            if let need = inPlace[entry.id] {
                // His answer: the card of its request stands in its place.
                rows.append(.request(need))
            } else if !hidden.contains(entry.id) {
                rows.append(.entry(entry))
            }
            rows += (after[entry.id] ?? []).map(ChatPart.request)
        }
        return rows + atEnd.map(ChatPart.request)
    }

    /// The time of each request's card for the marks of a day or an hour (`times`): when he answered it, for a card
    /// that stands at its answer, else when it was raised.
    public func cardTimes(of needs: [OwnerNeed]) -> [Int: Double] {
        Dictionary(needs.map { ($0.id, answeredAt[$0.id] ?? $0.raised) }) { first, _ in first }
    }

    /// **The time of each row, for the marks of a day or an hour over the chat** (`ChatStamp`): an entry's own, and a
    /// card's when it was raised (`raised`, by the request's number; the Mac gives `cardTimes`, with the time of his
    /// answer for a card that stands there), so a card that was raised a day after the entry over it has that day's
    /// mark. Never earlier than the row over it: the reply of a request's turn stands over its card and came after it.
    /// `granted`: the time of each card of grant lines, by the number of its first line (`ChatGrantPlaces.times`).
    public static func times(of rows: [ChatPart], raised: [Int: Double], granted: [Int: Double] = [:]) -> [Double] {
        var times: [Double] = []
        for row in rows {
            let own: Double? = switch row {
            case .entry(let entry): entry.created
            case .request(let need): raised[need]
            case .grants(let first): granted[first]
            // The row of a thing that he asked for stands under its turn's reply, at that reply's time.
            case .ask: nil
            }
            times.append(max(own ?? 0, times.last ?? 0))
        }
        return times
    }

    /// His message that answers `need`, among `entries`, or nil.
    private static func answer(to need: OwnerNeed, in entries: [ChatEntry]) -> OwnerMessage? {
        for entry in entries {
            if case .message(let message) = entry, message.kind == "answer", message.need_id == need.id { return message }
        }
        return nil
    }
}

/// One part of an agent's chat as it draws: an entry of the conversation, the card of a request, by its number, the
/// row of a thing that he asked for in this chat, by his message's request_id (`ChatAskPlaces`), or the card of a run
/// of grant lines, by the number of its first line (`ChatGrantPlaces`).
public enum ChatPart: Identifiable, Equatable, Sendable {
    case entry(ChatEntry), request(Int), ask(String), grants(Int)
    public var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .request(let need): "need-\(need)"
        case .ask(let ask): "ask-\(ask)"
        case .grants(let first): "grants-\(first)"
        }
    }
}

extension OwnerNeed {
    /// **He answered in his own words, or with files alone**: no option of the request that he pressed or ticked, and
    /// no secure form. Such an answer can ask something back or say no, so nothing marks it as a yes: it has no check,
    /// and in the iPhone's chat it is his message, where the Mac's chat says it on its card (the owner, 14 November
    /// 2026: "when I typed a custom answer instead of choosign one of the suggested ones, do not show the CHECK
    /// animation because it is misleading").
    /// **A press of Run is no answer in words** (owner feature `need_run`): its card folds with its check, and the chat
    /// shows no message of his for it.
    /// **His words about a key request are words too** (Needs clarification, API 1.249): the form of such a request
    /// answered it with no secret, so its card has no check either.
    public var answeredInWords: Bool {
        !isOpen && chosen == nil && (chose ?? []).isEmpty && (!asksForSecret || secret?.clarified == true) && run_status == nil
    }

    /// `words` are an option of this request, or its ticked options as the hub joins them: what a press writes as the
    /// answer. It tells a press from his own words while the reading still has the request open. The hub's words of a
    /// press of Run are a press too (`NeedRun.answerWords`).
    public func offers(_ words: String) -> Bool {
        if choices.contains(words) { return true }
        if run_command != nil, words.hasPrefix(NeedRun.answerPrefix) { return true }
        let parts = words.components(separatedBy: "; ")
        return combines && parts.count > 1 && parts.allSatisfy(choices.contains)
    }
}

extension PendingRequest {
    /// An answer to a request in his own words, or with files alone: no option that he pressed or ticked.
    public var answersInWords: Bool { needID != nil && command == nil && choice == nil && choices == nil && ran == nil }
}
