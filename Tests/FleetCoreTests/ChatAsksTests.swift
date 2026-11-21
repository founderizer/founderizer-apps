import Foundation
import Testing
@testable import FleetCore

/// The row of each thing that he asked for stands in the agent's chat (the owner, 16 November 2026: "this tasks should
/// also show inside the conversation!! like in codex or claude code!"). Explicit test data only.
struct ChatAsksTests {
    private static let now = 1_800_000_000.0

    private func task(_ id: Int, _ state: String, ask: String?, owner: String = "dev", last: Double = now - 600,
                      accepted: Int? = nil, works: Bool? = nil, doing: String? = nil, parent: Int? = nil,
                      follows: Int? = nil, waitingOn: String? = nil, parked: Double? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "title": "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": "manager", "state": state, "created": last - 60,
                                  "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
        row["started"] = state == "submitted" ? nil : last
        row["last_activity"] = state == "submitted" ? nil : last
        row["accepted"] = accepted; row["works"] = works; row["doing"] = doing; row["ask"] = ask
        row["parent"] = parent; row["follows"] = follows; row["waiting_on"] = waitingOn; row["parked_until"] = parked
        return row
    }

    private func message(_ id: String, at created: Double, to recipient: String = "dev", asked: String? = nil,
                         kind: String = "message", need: Int? = nil, replaces: String? = nil) -> [String: Any] {
        ["request_id": id, "recipient": recipient, "kind": kind, "text": "Words of \(id)", "event_id": 1,
         "created": created, "client": "test", "asked": asked ?? NSNull(), "need_id": need ?? NSNull(),
         "replaces_request_id": replaces ?? NSNull()]
    }

    /// `pushed`: the agent wrote it first (`message_owner`), so it is no reply. A report that names no message and
    /// that is not pushed is the Fleet Manager's reply to a message from the app.
    /// `turn`: the message whose turn it took (owner API 1.190), with no link.
    private func report(_ id: Int, at created: Double, by agent: String = "dev", replyingTo asked: String? = nil,
                        pushed: Bool = false, turn: String? = nil) -> [String: Any] {
        ["id": id, "agent": agent, "text": "Reply \(id)", "about": "", "created": created, "in_reply_to": asked ?? NSNull(),
         "pushed": pushed, "turn": turn ?? NSNull()]
    }

    /// `ask`: the message of his that the request names (`OwnerNeed.ask`).
    private func need(_ id: Int, by agent: String = "dev", raised: Double, answered: Double? = nil,
                      ask: String? = nil) -> [String: Any] {
        ["id": id, "title": "Need \(id)", "why": "", "todo": "", "raised": raised, "by": agent,
         "answer": answered == nil ? NSNull() : "Yes", "answered": answered ?? NSNull(), "options": ["Yes", "No"],
         "chosen": answered == nil ? NSNull() : 0, "ask": ask ?? NSNull()]
    }

    /// `managerEnded`: the manager's `turn_ended_after`. The hub counts the manager's answers (`chat_waits_answers`).
    private func hub(_ tasks: [[String: Any]], messages: [[String: Any]] = [], reports: [[String: Any]] = [],
                     needs: [[String: Any]] = [], holds: [[String: Any]] = [],
                     managerEnded: Double? = nil) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "dev", "ops"].map {
            var agent: [String: Any] = ["name": $0, "role": $0 == "manager" ? "manager" : "worker", "runtime": "codex",
                                        "can": []]
            if $0 == "manager", let managerEnded { agent["turn_ended_after"] = managerEnded }
            return agent
        }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": Self.now, "ui_features": [ChatWaiting.answersFeature],
            "agents": agents, "tasks": tasks, "holds": holds,
            "outcomes": [], "notes": [], "needs": needs, "permissions": [], "messages": messages, "reports": reports]))
    }

    /// The chat of `agent` as the Mac draws it (`ManagerView`): its entries, the cards in their places, the rows of its
    /// asks, and, by each card's request, the ask that is the card's head and has no row (`ChatAskPlaces.onCards`).
    private func drawn(_ state: HubState, agent: String, waitsOn: String?) -> (rows: [String], heads: [Int: String]) {
        var timeline = ChatTimeline()
        _ = timeline.update(messages: state.messages, reports: state.reports)
        let entries = timeline.entries(for: agent, limit: .max)
        let needs = state.needs.filter { $0.by == agent }
        let places = ChatRequestPlaces.inTime(needs: needs, in: entries, whole: true)
        let drawn = ChatAskPlaces.rows(places.rows(of: entries), asks: state.asks.filter { $0.agent == agent },
                                       open: needs.filter(\.isOpen), waitsOn: waitsOn)
        return (drawn.rows.map(\.id), drawn.heads.mapValues(\.id))
    }

    private func chat(_ state: HubState, agent: String = "dev", waitsOn: String? = nil) -> [String] {
        drawn(state, agent: agent, waitsOn: waitsOn).rows
    }

    private func row(_ state: HubState, _ id: String, agent: String = "dev") throws -> ChatAskRow {
        ChatAskRow(try #require(state.asks.first { $0.id == id }), agent: agent, state: state)
    }

    @Test func aRowStandsUnderTheReplyOfItsTurnAndStaysThere() throws {
        let state = try hub(
            [task(1, "working", ask: "a", works: true, doing: "Reads the outputs"), task(2, "completed", ask: "b", accepted: 1)],
            messages: [message("a", at: Self.now - 3000, asked: "Show the UTC time"), message("b", at: Self.now - 1000)],
            reports: [report(1, at: Self.now - 2990, replyingTo: "a"), report(2, at: Self.now - 2000, pushed: true),
                      report(3, at: Self.now - 990, replyingTo: "b"), report(4, at: Self.now - 500, replyingTo: "b")])
        #expect(chat(state) == ["message-a", "report-1", "ask-a", "report-2", "message-b", "report-3", "ask-b", "report-4"])
    }

    @Test func withNoReplyYetARowStandsUnderHisMessage() throws {
        // The agent's report that answers another message, or none, is not the reply of this turn.
        let state = try hub([task(1, "submitted", ask: "a")],
                            messages: [message("z", at: Self.now - 4000), message("a", at: Self.now - 3000)],
                            reports: [report(1, at: Self.now - 2990, replyingTo: "z")])
        #expect(chat(state) == ["message-z", "message-a", "ask-a", "report-1"])
    }

    @Test func theTurnEndsWithHisNextMessageAfterTheAgentSpoke() throws {
        // His message after the agent spoke is a turn of its own; a later reply that names his first message is still
        // the reply of the first turn.
        let state = try hub([task(1, "working", ask: "a"), task(2, "working", ask: "b")],
                            messages: [message("a", at: Self.now - 3000), message("b", at: Self.now - 2990)],
                            reports: [report(1, at: Self.now - 2995, pushed: true),
                                      report(2, at: Self.now - 1000, replyingTo: "a")])
        #expect(chat(state) == ["message-a", "report-1", "message-b", "ask-b", "report-2", "ask-a"])
    }

    @Test func theFleetManagersReplyStandsOverTheRowByTheTurnItTook() throws {
        // A line of the hub's (no link, no turn) is no reply; the Fleet Manager's words that took the turn are.
        let state = try hub([task(1, "working", ask: "a", owner: "dev")],
                            messages: [message("a", at: Self.now - 3000, to: "manager")],
                            reports: [report(1, at: Self.now - 2990, by: "manager"),
                                      report(2, at: Self.now - 2980, by: "manager", turn: "a")])
        #expect(chat(state, agent: "manager") == ["message-a", "report-1", "report-2", "ask-a"])
        // Words that took the turn after he wrote again are not this turn's reply: the hub gives the turn of the
        // oldest message that waits to the manager's next words, also when it did the work with no words.
        let later = try hub([task(1, "working", ask: "a", owner: "dev")],
                            messages: [message("a", at: Self.now - 3000, to: "manager"),
                                       message("b", at: Self.now - 2000, to: "manager")],
                            reports: [report(1, at: Self.now - 2500, by: "manager", pushed: true),
                                      report(2, at: Self.now - 1000, by: "manager", turn: "a")])
        #expect(chat(later, agent: "manager") == ["message-a", "ask-a", "report-1", "message-b", "report-2"])
    }

    @Test func aTurnIsNoLinkForARequestsCard() throws {
        // The turn places the row of an ask and nothing else: a request's card stands under the reply of its turn only
        // by `in_reply_to` (`ChatRequestPlaces.turnReply`), so a report with a turn alone has no card under it.
        let state = try hub([], messages: [message("a", at: Self.now - 3000, to: "manager")],
                            reports: [report(1, at: Self.now - 2000, by: "manager", turn: "a")],
                            needs: [need(7, by: "manager", raised: Self.now - 2500)])
        var timeline = ChatTimeline()
        _ = timeline.update(messages: state.messages, reports: state.reports)
        let entries = timeline.entries(for: "manager", limit: .max)
        let places = ChatRequestPlaces.inTime(needs: state.needs, in: entries, whole: true)
        #expect(places.rows(of: entries).map(\.id) == ["message-a", "need-7", "report-1"])
    }

    @Test func aMessageThatNamesNoneIsNoReply() throws {
        // The hub's own lines in the Fleet Manager's chat, and its reply to a message from the app, name no message:
        // the row stands under his message.
        let state = try hub([task(1, "working", ask: "a", owner: "dev")],
                            messages: [message("a", at: Self.now - 3000, to: "manager")],
                            reports: [report(1, at: Self.now - 2990, by: "manager", pushed: true),
                                      report(2, at: Self.now - 2980, by: "manager")])
        #expect(chat(state, agent: "manager") == ["message-a", "ask-a", "report-1", "report-2"])
    }

    @Test func aReplyStandsWithTheTurnOfTheMessageThatItNames() throws {
        // Two messages six minutes apart are two turns; the agent answers the first after the second came.
        let state = try hub([task(1, "working", ask: "a"), task(2, "working", ask: "b")],
                            messages: [message("a", at: Self.now - 3000), message("b", at: Self.now - 2640)],
                            reports: [report(1, at: Self.now - 2600, replyingTo: "a"),
                                      report(2, at: Self.now - 2590, replyingTo: "b")])
        #expect(chat(state) == ["message-a", "message-b", "report-1", "ask-a", "report-2", "ask-b"])
    }

    @Test func twoAsksOfOneTurnStandTogetherUnderItsReply() throws {
        let state = try hub([task(1, "working", ask: "a"), task(2, "working", ask: "b")],
                            messages: [message("a", at: Self.now - 3000), message("b", at: Self.now - 2990)],
                            reports: [report(1, at: Self.now - 2900, replyingTo: "a")])
        #expect(chat(state) == ["message-a", "message-b", "report-1", "ask-a", "ask-b"])
        // With no reply yet, they stand under his last message of the turn.
        let none = try hub([task(1, "working", ask: "a"), task(2, "working", ask: "b")],
                           messages: [message("a", at: Self.now - 3000), message("b", at: Self.now - 2990)])
        #expect(chat(none) == ["message-a", "message-b", "ask-a", "ask-b"])
    }

    @Test func messagesThatHeWroteBeforeTheAgentSpokeAreOneTurn() throws {
        // He sends two messages, and the agent answers the second, filing the work under the first.
        let state = try hub([task(1, "working", ask: "a")],
                            messages: [message("a", at: Self.now - 3000), message("b", at: Self.now - 2990)],
                            reports: [report(1, at: Self.now - 2900, replyingTo: "b")])
        #expect(chat(state) == ["message-a", "message-b", "report-1", "ask-a"])
        // Messages hours apart that nothing answered are turns of their own: each row stays under its message.
        let apart = try hub([task(1, "working", ask: "a"), task(2, "working", ask: "b")],
                            messages: [message("a", at: Self.now - 9000), message("b", at: Self.now - 3000)],
                            reports: [report(1, at: Self.now - 2900, replyingTo: "b")])
        #expect(chat(apart) == ["message-a", "ask-a", "message-b", "report-1", "ask-b"])
    }

    @Test func whileTheChatWaitsForTheReplyTheRowWaitsToo() throws {
        // The task is often a reading earlier than the reply: the row comes with the reply, and does not move.
        let state = try hub([task(1, "working", ask: "a")], messages: [message("a", at: Self.now - 30)])
        #expect(chat(state, waitsOn: "A") == ["message-a"])
        #expect(chat(state) == ["message-a", "ask-a"])
        // With its reply it stands under the reply, whatever the chat waits for.
        let replied = try hub([task(1, "working", ask: "a")], messages: [message("a", at: Self.now - 30)],
                              reports: [report(1, at: Self.now - 20, replyingTo: "a")])
        #expect(chat(replied, waitsOn: "a") == ["message-a", "report-1", "ask-a"])
    }

    /// **His answer to a card holds no row, and neither does a message whose turn is over** (two reviews of 21
    /// November 2026). In the manager's chat the line moves for his answer too (hub 1.283), but the answer's card
    /// stands in no turn: held by the answer, the row of his ask stood under his message and then moved under the reply
    /// a reading later. And when the manager opened the task of his message with no words and its turn ended, the row
    /// stood under his message: the line that moves for his answer later must not hide it for a turn. So the row waits
    /// only on his newest message, while that message itself is worked on (`ChatWaiting.asksWaitOn` with the line's
    /// rule without his answers, as the Mac's `waitsOn` reads it).
    @Test func onlyHisMessageThatIsWorkedOnHoldsTheRowOfItsAsk() throws {
        let messages = [message("a", at: Self.now - 60, to: "manager"),
                        message("x", at: Self.now - 30, to: "manager", kind: "answer", need: 7)]
        let needs = [need(7, by: "manager", raised: Self.now - 50, answered: Self.now - 30)]
        func drawn(ended: Double?) throws -> (moves: Bool, rows: [String]) {
            let state = try hub([task(1, "working", ask: "a", owner: "manager")], messages: messages, needs: needs,
                                managerEnded: ended)
            let manager = try #require(state.agents.first { $0.name == "manager" })
            var timeline = ChatTimeline()
            _ = timeline.update(messages: state.messages, reports: state.reports)
            let entries = timeline.entries(for: "manager", limit: .max)
            let line = manager.chatWaiting(in: state, sending: false, fresh: false, until: { _ in "" }, answers: false)
            let held = ChatWaiting.asksWaitOn(entries, moving: line?.moving == true)
            // The Mac's chat, with the card at his answer.
            let places = ChatRequestPlaces.inTime(needs: state.needs, in: entries, whole: true, answered: .atItsAnswer)
            let rows = ChatAskPlaces.rows(places.rows(of: entries), asks: state.asks.filter { $0.agent == "manager" },
                                          open: [], waitsOn: held).rows.map(\.id)
            return (manager.thinks(in: state, sending: false, fresh: false), rows)
        }
        // His message is still worked on: the row comes with the reply of its turn, and not under "a" first.
        #expect(try drawn(ended: nil) == (true, ["message-a", "need-7"]))
        // Its turn ended with no words, then he answered the card: the line moves for the answer, and the row stays.
        #expect(try drawn(ended: Self.now - 60) == (true, ["message-a", "ask-a", "need-7"]))
    }

    @Test func workThatNoMessageOfThisChatBeganHasNoRow() throws {
        // The manager's work, an ask of another agent's chat, and an ask whose message the chat does not hold.
        let state = try hub([task(1, "working", ask: nil), task(2, "working", ask: "o", owner: "ops"),
                             task(3, "working", ask: "gone")],
                            messages: [message("o", at: Self.now - 3000, to: "ops"), message("a", at: Self.now - 2000)])
        #expect(chat(state) == ["message-a"])
        #expect(chat(state, agent: "ops") == ["message-o", "ask-o"])
    }

    @Test func aCorrectionStandsForTheMessageThatItReplaced() throws {
        // The hub files the work under the first message; the agent answers the correction.
        let alone = try hub([task(1, "working", ask: "a")],
                            messages: [message("c", at: Self.now - 2900, replaces: "a")],
                            reports: [report(1, at: Self.now - 2800, replyingTo: "c")])
        #expect(chat(alone) == ["message-c", "report-1", "ask-a"])
        let both = try hub([task(1, "working", ask: "a")],
                           messages: [message("a", at: Self.now - 3000), message("c", at: Self.now - 2900, replaces: "a")],
                           reports: [report(1, at: Self.now - 2800, replyingTo: "c")])
        #expect(chat(both) == ["message-a", "message-c", "report-1", "ask-a"])
        // With no reply yet it stands under the newest of them, also when the agent spoke between them.
        let none = try hub([task(1, "working", ask: "a")],
                           messages: [message("a", at: Self.now - 3000), message("b", at: Self.now - 2900, replaces: "a"),
                                      message("c", at: Self.now - 2000, replaces: "b")],
                           reports: [report(1, at: Self.now - 2500)])
        #expect(chat(none) == ["message-a", "message-b", "report-1", "message-c", "ask-a"])
        // A correction after the agent's question: the work began in the correction's turn.
        let asked = try hub([task(1, "working", ask: "a")],
                            messages: [message("a", at: Self.now - 3000), message("c", at: Self.now - 2000, replaces: "a")],
                            reports: [report(1, at: Self.now - 2900, replyingTo: "a"), report(2, at: Self.now - 1900, replyingTo: "c")])
        #expect(chat(asked) == ["message-a", "report-1", "message-c", "report-2", "ask-a"])
    }

    @Test func aRowSaysWhatItsWorkDoesAndWhoDoesIt() throws {
        let state = try hub([task(1, "working", ask: "a", works: true, doing: "Reads the outputs"),
                             task(2, "working", ask: "b", owner: "ops", works: true, doing: "Runs the tests"),
                             task(3, "working", ask: "c", works: false)],
                            messages: [message("a", at: Self.now - 3000), message("b", at: Self.now - 2000),
                                       message("c", at: Self.now - 1000)])
        let mine = try row(state, "a")
        #expect(mine.line == "Reads the outputs")
        #expect(mine.moves && mine.tint == .work && mine.task == 1)
        let theirs = try row(state, "b")
        #expect(theirs.line.hasSuffix(" · Runs the tests") && theirs.task == 2)
        // A task between two turns keeps its mark at rest, and says its state word.
        let resting = try row(state, "c")
        #expect(!resting.moves && resting.symbol == "circle.dotted" && resting.tint == .quiet)
        #expect(resting.line == TaskWords.working)
    }

    @Test func aRowOfParkedWorkSaysUntilWhen() throws {
        let state = try hub([task(1, "working", ask: "a", works: false, parked: Self.now + 7200),
                             task(2, "working", ask: "b", works: true, doing: "Runs", parked: Self.now + 7200),
                             task(3, "working", ask: "c", works: false),
                             task(4, "input-required", ask: "d", parked: Self.now + 7200)],
                            messages: [message("a", at: Self.now - 3000), message("b", at: Self.now - 2000),
                                       message("c", at: Self.now - 1000), message("d", at: Self.now - 500)])
        #expect(try row(state, "a").until == Self.now + 7200)
        // Parked work is no work now, also while a turn of it runs (the board's rule of 13 November 2026); work in
        // progress with no park has no time.
        #expect(try row(state, "b").until == Self.now + 7200)
        #expect(try !row(state, "b").moves)
        #expect(try row(state, "c").until == nil)
        // Parked work that also asked a question says that wait, as its card on the board does (`parkedOnly`).
        #expect(try row(state, "d").until == nil)
    }

    @Test func aWaitThatDoesNotNeedHimIsMutedAndSaysWhatItWaitsFor() throws {
        // A wait on another agent is an orange hourglass on a task's own mark; in his chat orange says that he must act.
        let state = try hub([task(1, "working", ask: "a", waitingOn: "ops"),
                             task(2, "working", ask: "b", works: false), task(3, "working", ask: nil, owner: "ops", parent: 2)],
                            messages: [message("a", at: Self.now - 3000), message("b", at: Self.now - 2000)])
        let other = try row(state, "a")
        #expect(other.symbol == "hourglass" && other.tint == .quiet && !other.moves)
        // A task whose subtasks are open waits for their agents, as the board says it.
        let subtasks = try row(state, "b")
        #expect(subtasks.line == HubState.subtaskWords(["ops"]) && subtasks.tint == .quiet)
    }

    @Test func aRowThatWaitsForHimSaysSo() throws {
        let state = try hub([task(1, "input-required", ask: "a", waitingOn: "N-7")],
                            messages: [message("a", at: Self.now - 3000)], needs: [need(7, raised: Self.now - 2000)])
        let waits = try row(state, "a")
        #expect(waits.symbol == "hand.raised.fill" && waits.tint == .attention && waits.line == "Waits for you")
        #expect(waits.words == "Need 7" && waits.task == 1)
    }

    /// **What waits for a card of its chat is that card's head, and has no row** (the owner, 18 November 2026, of the
    /// row "Waits for you" over the card that it waited for: "Or just combine them"), only while the card waits: a row
    /// that went with a card that he answered, or with a card of another chat, would be gone from his chat for good.
    @Test func anAskThatWaitsForACardOfItsChatIsThatCardsHeadUntilHeAnswers() throws {
        let manager = (messages: [message("a", at: Self.now - 3000, to: "manager")],
                       reports: [report(1, at: Self.now - 2990, by: "manager", replyingTo: "a")])
        let open = try hub([task(1, "submitted", ask: "a")], messages: manager.messages,
                           reports: manager.reports, needs: [need(7, by: "manager", raised: Self.now - 2980, ask: "a")])
        let waits = drawn(open, agent: "manager", waitsOn: nil)
        #expect(waits.rows == ["message-a", "report-1", "need-7"])
        #expect(waits.heads == [7: "a"])
        // A card that the chat does not draw yet (older than its drawn entries) takes no ask: the ask keeps its row.
        #expect(ChatAskPlaces.onCards(open.asks, open: open.needs, in: [.entry(.report(open.reports[0]))]).isEmpty)
        let answered = try hub([task(1, "submitted", ask: "a")], messages: manager.messages,
                               reports: manager.reports,
                               needs: [need(7, by: "manager", raised: Self.now - 2980, answered: Self.now - 100, ask: "a")])
        let after = drawn(answered, agent: "manager", waitsOn: nil)
        #expect(after.rows == ["message-a", "report-1", "ask-a", "need-7"])
        #expect(after.heads.isEmpty)
        // His task waits for a card that the Fleet Manager raised: it stands in the Fleet Manager's chat, not in this one.
        let elsewhere = try hub([task(1, "input-required", ask: "a", waitingOn: "N-7")],
                                messages: [message("a", at: Self.now - 3000)],
                                reports: [report(1, at: Self.now - 2990, replyingTo: "a")],
                                needs: [need(7, by: "manager", raised: Self.now - 2000)])
        #expect(chat(elsewhere) == ["message-a", "report-1", "ask-a"])
    }

    @Test func doneOnlyAfterTheCheck() throws {
        let state = try hub([task(1, "completed", ask: "a", accepted: 1), task(2, "completed", ask: "b"),
                             task(3, "failed", ask: "c"), task(4, "canceled", ask: "d")],
                            messages: ["a", "b", "c", "d"].enumerated().map { message($1, at: Self.now - 4000 + Double($0) * 100) })
        let done = try row(state, "a")
        #expect(done.symbol == "checkmark.circle.fill" && done.tint == .checked && done.line == "Done")
        // A result that waits for its requester's check says that, and never "Done".
        let unchecked = try row(state, "b")
        #expect(unchecked.symbol == "circle" && unchecked.tint == .quiet && unchecked.line != "Done")
        let failed = try row(state, "c")
        #expect(failed.symbol == "exclamationmark.circle.fill" && failed.tint == .failed && failed.line == "Failed")
        #expect(failed.task == 3)
        // Somebody chose to end it: its word, with no red.
        let canceled = try row(state, "d")
        #expect(canceled.line == "Canceled" && canceled.tint == .quiet)
    }

    @Test func aRowStandsAtTheTimeOfTheRowOverIt() throws {
        let rows: [ChatPart] = [.request(1), .ask("a")]
        #expect(ChatRequestPlaces.times(of: rows, raised: [1: 50]) == [50, 50])
    }
}
