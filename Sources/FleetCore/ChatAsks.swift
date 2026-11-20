import Foundation

/// **What he asked an agent for, as one row in that agent's chat** (the owner, 16 November 2026, with a picture of the
/// sidebar row of an agent whose line named a task that its chat did not show: "this tasks should also show inside the
/// conversation!! like in codex or claude code! not only there"). To the picture of it he chose, of three questions, one
/// row for each thing that he asked **in this chat** (work that the Fleet Manager or a duty gave the agent stays on
/// Tasks only), a click that **opens the task**, and **the Mac and the iPhone**.
///
/// The row is one `Ask` (`HubState.asks`): his message, and every task that carries its `request_id`, subtasks of
/// other agents too. It stands under the agent's reply of the turn in which the work began ("I opened a task for it."),
/// else under his message (`ChatAskPlaces`), and it stays there when the work ends, as a task stands in a Claude Code
/// chat: its mark and its one muted line say where the work stands, with the words and the marks of the card Asked
/// and of the Tasks board. Work that has no `ask` (every task that agents filed before hub 2026.11.510) has no row.
public struct ChatAskRow: Identifiable, Sendable, Equatable {
    /// The `request_id` of his message.
    public let id: String
    /// The name of what he asked for (`Ask.title`).
    public let title: String
    /// The mark's SF Symbol: the orange raised hand of what waits for him, the dotted circle of work, the board's
    /// marks of a result, else the mark of its task (`FleetTask.mark`).
    public let symbol: String
    /// The mark's colour, as the board and the search card colour a task's mark.
    public let tint: FleetTask.MarkTint
    /// The mark turns: a turn of its task in work runs now (`FleetTask.mark(...).inWork`). A mark that turns says work
    /// now, so a task between two turns keeps the mark at rest.
    public let moves: Bool
    /// **The row's one muted line**: "Waits for you"; the agent that works on it, by its role when it is not the agent
    /// of this chat, and what its running turn does; the state word of its task; "Done"; or the word of a result that
    /// did not succeed, which the row draws in red.
    public let line: String
    /// What the pointer and VoiceOver read under the title: what it waits for from him, else the line.
    public let words: String
    /// The task that a click opens: the one that waits for him (`Ask.lead`), else the one in work, else the one whose
    /// wait the line says (`waitLead`); for one that ended, the task whose result did not succeed, else the one that
    /// moved last.
    public let task: Int?
    /// **Until when its agent parked its work** (`parked_until`), for a row that waits and that no hold or usage limit
    /// stops: the app writes it as the Tasks board does ("Until 15:00") in place of `line`.
    public let until: Double?

    /// `agent`: the agent of the chat. `state`: the reading that `ask` came from, for the holds and the usage limits
    /// that a task's mark reads.
    public init(_ ask: Ask, agent: String, state: HubState?) {
        id = ask.id
        title = ask.title
        if let wait = ask.wait {
            // What waits for him: the card Asked's look and words (`AskedCard.Mark.waitsForOwner`).
            symbol = "hand.raised.fill"; tint = .attention; moves = false
            line = String(l10n: "Waits for you")
            words = wait.words
            task = ask.lead?.id
            until = nil
            return
        }
        if !ask.isOver, let open = ask.working ?? Self.waitLead(ask) {
            let mark = open.mark(in: state)
            symbol = mark.symbol; moves = mark.inWork
            // **What waits, but not for him, is muted, as the Tasks board draws it**: a wait on another agent, a stall, a
            // lost session or a usage limit is orange on a task's own mark, and orange in his chat says that he must
            // act. Only the work mark of a turn that runs now is green.
            tint = moves ? .work : .quiet
            task = open.id
            if ask.working != nil {
                // In work: who works on it, when it is another agent, and what its turn does now, as the card Asked
                // says it; a stall or a lost session says its own word.
                if mark.words == TaskWords.working {
                    let says = [open.owner == agent ? nil : open.owner.agentLabel,
                                open.doing.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }]
                        .compactMap { $0 }.joined(separator: " · ")
                    line = says.isEmpty ? mark.words : says
                } else {
                    line = mark.words
                }
                until = nil
            } else {
                // It waits: why, in the board's words (`ActivityBoard.why`) — until when its agent parked it, when
                // nothing else holds it (`parkedOnly`), else the agents whose subtasks it waits for, else its task's
                // state word.
                until = open.parkedUntil(in: state)
                if let agents = state?.subtaskWaits[open.id], mark.words == TaskWords.working {
                    line = HubState.subtaskWords(agents)
                } else {
                    line = mark.words
                }
            }
            words = line
            return
        }
        if let failed = ask.failed {
            symbol = "exclamationmark.circle.fill"; tint = .failed; moves = false
            line = failed.failedResult ?? String(l10n: "Failed")
            words = line
            task = failed.id
            until = nil
            return
        }
        // A result of it still waits for its requester's check: that task's mark and word, so the chat never says
        // "Done" before the check (a "Done" that a refused result takes back is worse than none). It is the result
        // that has the ask's last word: a task of the ask that is no subtask of another task of it.
        if ask.unchecked {
            let ids = Set(ask.tasks.map(\.id))
            let waiting = ask.tasks.filter { $0.state == "completed" && $0.accepted == nil }
            if let quiet = waiting.first(where: { $0.parent.map { !ids.contains($0) } ?? true }) ?? waiting.first {
                let mark = quiet.mark(in: state)
                symbol = mark.symbol; tint = .quiet; moves = false
                line = mark.words
                words = line
                task = quiet.id
                until = nil
                return
            }
        }
        if ask.canceled {
            // Somebody chose to end it: its word, with the quiet circle of a task at rest, and no red or "!" that says
            // something went wrong (`FleetTask.endedBadly`), as the board's Ended says "Canceled" with no mark.
            symbol = "circle"; tint = .quiet; moves = false
            line = String(l10n: "Canceled")
            words = line
            task = ask.lead?.id
            until = nil
            return
        }
        symbol = "checkmark.circle.fill"; tint = .checked; moves = false
        line = String(l10n: "Done")
        words = line
        task = ask.lead?.id
        until = nil
    }

    /// The open task whose wait the row says, as the board's card of an ask says it: the one parked until the earliest
    /// time, else the open one that moved last.
    static func waitLead(_ ask: Ask) -> FleetTask? {
        ask.open.filter { $0.parked_until != nil }.min { ($0.parked_until ?? 0) < ($1.parked_until ?? 0) }
            ?? ask.open.first ?? ask.lead
    }
}

/// **Where the row of each thing that he asked stands in an agent's chat** (`ChatAskRow`): under the agent's reply of
/// the turn in which the work began, else under his last message of that turn, and it stays there.
///
/// - **A turn** is his messages that follow each other, each within five minutes of the one before (`turnGap`) and with
///   nothing of the agent's between them, and the agent's messages after them, up to his next message.
/// - **The reply of a turn** is the first message of the agent's that answers one of his messages of the turn
///   (`in_reply_to`), also when he wrote again before it came, or that took the turn of one of them (`turn`, owner API
///   1.190: the Fleet Manager's reply to a message written in the app, a worker's sentence before its task) before he
///   wrote again. A message that names neither is no reply: the hub writes lines of its own into the Fleet Manager's
///   chat (a standing item, a grant). With no reply the row stands under his message, and it comes when the chat's
///   "Thinking" ends, so it does not move.
/// - **His message and its corrections are one ask** (the hub's `ask_message` files the work under the first of them),
///   so its row stands in the newest turn that holds one of them: a correction after a question of the agent's is
///   where the work began.
/// - **While the chat waits for the reply of that turn** (`waitsOn`: the message that the chat's moving "Thinking"
///   stands under), the row waits too: it comes with the reply, which stands over it, and does not move from under his
///   message to under the reply a reading later. Every other wait of the chat (a usage limit, a quiet machine) holds
///   nothing.
/// - A message that the chat does not draw (older than its drawn messages, or in another chat) has no row until he
///   asks for the earlier messages. Several rows under one entry stand in the order he asked.
public enum ChatAskPlaces {
    /// The longest time between two messages of his that are one turn, as the phone's chat runs his messages together:
    /// five minutes. Messages hours apart that nothing answered are turns of their own.
    public static let turnGap: Double = 300

    /// `rows`: the chat's rows (`ChatRequestPlaces.rows`). `asks`: the things he asked for; the ones that are not of
    /// this chat find no place. `waitsOn`: the message whose reply the chat's "Thinking" waits for, or nil.
    public static func rows(_ rows: [ChatPart], asks: [Ask], waitsOn: String? = nil) -> [ChatPart] {
        guard !asks.isEmpty else { return rows }
        func key(_ id: String) -> String { id.lowercased() }
        // The turns, in order: his messages' places and ids, and the place of the reply.
        var turns: [(messages: [Int], ids: Set<String>, reply: Int?)] = []
        var said = -Double.infinity, spoke = false
        var replaced: [String: String] = [:], turnOfMessage: [String: Int] = [:]
        for (at, row) in rows.enumerated() {
            switch row {
            case .entry(.message(let message)):
                let id = key(message.request_id)
                if let earlier = message.replaces_request_id { replaced[id] = key(earlier) }
                if !turns.isEmpty, !spoke, message.created - said <= turnGap {
                    turns[turns.count - 1].messages.append(at)
                    turns[turns.count - 1].ids.insert(id)
                } else {
                    turns.append(([at], [id], nil))
                    spoke = false
                }
                turnOfMessage[id] = turns.count - 1
                said = message.created
            case .entry(.report(let report)):
                guard !turns.isEmpty else { continue }
                spoke = true
                // The reply of the turn that holds the message it names, also when he wrote again before it came.
                if let asked = report.in_reply_to, let n = turnOfMessage[key(asked)], turns[n].reply == nil {
                    turns[n].reply = at
                // A report that names none but took the turn of a message of his (`turn`): the reply of that turn,
                // only while it is the newest turn. The hub gives the turn of the oldest message that waits to the
                // Fleet Manager's next words, also after it did the work with its tools and no words, so words of a
                // later turn are not taken for this one's.
                } else if report.in_reply_to == nil, let turned = report.turn, let n = turnOfMessage[key(turned)],
                          n == turns.count - 1, turns[n].reply == nil {
                    turns[n].reply = at
                }
            default:
                continue
            }
        }
        // Each ask's newest turn: of its first message or of a correction that goes back to it.
        func first(_ id: String) -> String {
            var id = id, steps = 0
            while let earlier = replaced[id], steps < replaced.count { id = earlier; steps += 1 }
            return id
        }
        var turnOf: [String: Int] = [:]
        for (n, turn) in turns.enumerated() {
            for id in turn.ids { turnOf[first(id)] = n }
        }
        let waiting = waitsOn.map(key)

        var under: [Int: [Ask]] = [:]
        for ask in asks.sorted(by: { ($0.created, $0.id) < ($1.created, $1.id) }) {
            guard let n = turnOf[key(ask.id)], let last = turns[n].messages.last else { continue }
            if let reply = turns[n].reply {
                under[reply, default: []].append(ask)
            } else if let waiting, turns[n].ids.contains(waiting) {
                // The chat waits for the reply of this turn: the row comes with it.
                continue
            } else {
                under[last, default: []].append(ask)
            }
        }
        var out: [ChatPart] = []
        for (at, row) in rows.enumerated() {
            out.append(row)
            out += (under[at] ?? []).map { ChatPart.ask($0.id) }
        }
        return out
    }

    /// **The rows of the Mac's chat, with each ask that stands on its card as that card's head** (`onCards`): `rows`
    /// without the row of such an ask, and the heads by the card's request. `open`: the requests of this chat that wait
    /// for his answer, without one whose answer is on its way.
    public static func rows(_ rows: [ChatPart], asks: [Ask], open: [OwnerNeed],
                            waitsOn: String? = nil) -> (rows: [ChatPart], heads: [Int: Ask]) {
        let heads = onCards(asks, open: open, in: rows)
        let carded = Set(heads.values.map(\.id))
        return (self.rows(rows, asks: asks.filter { !carded.contains($0.id) }, waitsOn: waitsOn), heads)
    }

    /// **The asks that stand on the card that they wait for, by the card's request** (the owner, 18 November 2026, of
    /// the row "Waits for you" over the card that it waited for: "Or just combine them, so instead of just going to the
    /// other screen, it shows expanded here. Then if more detail is required add a button to go to the task?", and "Yes,
    /// build it" to its picture, for the Mac): an ask that waits for a request (`OwnerWait.request`) that is open and
    /// whose card this chat draws is that card's head, and has no row of its own until he answers it. Then the card
    /// folds and the row stands under its reply again. One ask for each card: the one that he asked first. `open`: the
    /// requests of this chat that wait for his answer, without one whose answer is on its way. `rows`: the chat's rows
    /// (`ChatRequestPlaces.rows`): a card that they do not draw (older than the drawn entries) takes no ask, so the
    /// ask keeps its row.
    public static func onCards(_ asks: [Ask], open: [OwnerNeed], in rows: [ChatPart]) -> [Int: Ask] {
        var drawn = Set<Int>()
        for row in rows {
            if case .request(let id) = row { drawn.insert(id) }
        }
        let waiting = Set(open.filter(\.isOpen).map(\.id)).intersection(drawn)
        var cards: [Int: Ask] = [:]
        for ask in asks.sorted(by: { ($0.created, $0.id) < ($1.created, $1.id) }) {
            guard case .request(let id, _) = ask.wait, waiting.contains(id), cards[id] == nil else { continue }
            cards[id] = ask
        }
        return cards
    }
}
