import Foundation
import Testing
@testable import FleetCore

/// What the chat says while the owner waits for an answer.
///
/// His words, 20 October 2026: "we need some kind of Thinking animation, like in chatgpt or like in our [other]
/// project". His own project carries his own correction to the obvious design — 14 October 2026: "why does it say
/// Thinking and sometimes Starting??" — so the rule is one word for everything that is the agent's own work, and
/// its own words only for a wait that is not.
struct ChatWaitingTests {
    private func limit(_ until: Double, known: Bool = true) throws -> RuntimeLimit {
        try JSONDecoder().decode(RuntimeLimit.self, from: Data(
            "{\"since\": 1, \"until\": \(until), \"reset_known\": \(known), \"task\": null}".utf8))
    }

    private func said(_ waiting: ChatWaiting?) -> String? { waiting?.says }

    @Test func nothingIsWaitedForUntilSomethingIsWaitedFor() {
        #expect(ChatWaiting.of(agent: "vps", pending: .none, sending: false, limit: nil, offline: false,
                               until: { _ in "" }) == nil)
        // This Mac's own request on its way is a wait of its own, before the hub has it at all.
        #expect(ChatWaiting.of(agent: "vps", pending: .none, sending: true, limit: nil, offline: false,
                               until: { _ in "" })?.says == ChatWaiting.working)
    }

    /// The queue, the pickup and the reply are one thing to him, and the line moves because something is moving.
    @Test func everythingThatIsTheAgentsOwnWorkSaysOneWordAndMoves() {
        let waiting = ChatWaiting.of(agent: "worker4", pending: .waiting, sending: false, limit: nil, offline: false,
                                     until: { _ in "" })
        #expect(waiting?.says == "Thinking")
        #expect(waiting?.moving == true)
    }

    /// The case he must never be left guessing about: nothing of this agent's will run until its allowance
    /// resets, so the line says so in two words and stops moving, and which agent and until when are on hover.
    @Test func aUsageLimitSaysUntilWhenAndDoesNotMove() throws {
        let waiting = ChatWaiting.of(agent: "worker4", pending: .waiting, sending: false,
                                     limit: try limit(1000), offline: false, until: { _ in "14:30" })
        #expect(waiting?.says == "Usage limit")
        #expect(waiting?.detail == "Worker4 is at its usage limit until 14:30.")
        #expect(waiting?.moving == false)
        // A provider that gave no reset time is not given an invented one.
        let unknown = ChatWaiting.of(agent: "worker4", pending: .waiting, sending: false,
                                     limit: try limit(1000, known: false), offline: false, until: { _ in "14:30" })
        #expect(unknown?.says == "Usage limit")
        #expect(unknown?.detail == "Worker4 is at its usage limit.")
        #expect(unknown?.moving == false)
        // Its mark is the board's hourglass, as on every screen that shows a usage limit (fix round 3).
        #expect(waiting?.symbol == "hourglass")
    }

    @Test func aMachineThatHasGoneQuietSaysSoAndSaysTheMessageIsKept() {
        let waiting = ChatWaiting.of(agent: "studio", pending: .waiting, sending: false, limit: nil, offline: true,
                                     until: { _ in "" })
        #expect(waiting?.says == "Not answering")
        #expect(waiting?.detail == "Studio is not answering. Your message is kept and reaches it when it is back.")
        #expect(waiting?.moving == false)
        #expect(waiting?.symbol == "clock")
    }

    /// **Its server answers, and his message does not arrive** (hub 1.144, `agents[].chat_undelivered`). On 13
    /// November 2026 a message of his stood under "Thinking" for seven minutes: the agent's server polled the hub,
    /// and it could hand the message to no session. The hub now says when his newest message is late, and the chat
    /// says of it what it says of a silent server, and nothing moves for it.
    @Test func aMessageThatDoesNotArriveSaysNotAnsweringAlthoughItsServerAnswers() throws {
        func state(late: Any?) throws -> HubState {
            var agent: [String: Any] = ["name": "studio", "role": "worker", "runtime": "claude", "active": true,
                                        "can": [], "last_seen": 4_990]
            if let late { agent["chat_undelivered"] = late }
            let message: [String: Any] = ["request_id": "s-1", "recipient": "studio", "kind": "message",
                                          "need_id": NSNull(), "text": "Is it live?", "event_id": 7, "created": 4_800,
                                          "read_at": NSNull(), "client": "founderizer-mac/1/x"]
            return try HubState.decode(JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": "db", "time": 5_000, "agents": [agent], "tasks": [], "notes": [],
                "needs": [], "permissions": [], "messages": [message], "reports": [],
            ] as [String: Any]))
        }
        func line(late: Any?) throws -> ChatWaiting? {
            let state = try state(late: late)
            return try #require(state.agents.first).chatWaiting(in: state, sending: false, fresh: true, until: { _ in "" })
        }
        // An older hub says nothing, and a newer one says false while the message is not late: its server answered
        // ten seconds ago, so the agent works on it.
        for late in [nil, NSNull(), false] as [Any?] {
            #expect(try line(late: late)?.says == "Thinking")
        }
        #expect(try state(late: nil).agents.first?.chat_undelivered == nil)
        let waiting = try line(late: true)
        #expect(waiting?.says == "Not answering")
        #expect(waiting?.detail == "Studio is not answering. Your message is kept and reaches it when it is back.")
        #expect(waiting?.moving == false)
        let late = try state(late: true)
        #expect(try #require(late.agents.first).thinks(in: late, sending: false, fresh: true) == false)
    }

    /// **A first sentence with no task behind it.** The agent can write a word that names no message: the chat then
    /// claims nothing and shows no line (`spokenSince`). When that word was the first sentence of a request for work
    /// and the task never opened, his message has no reply, and nothing on the screen said so. The hub calls that
    /// message late two minutes after its read, and then the word ends nothing: the line says "Not answering". A
    /// reply that names his message ends it as before, whatever the hub's field says.
    @Test func aWordWithNoLinkDoesNotEndTheWaitOfAMessageThatTheHubCallsLate() throws {
        func line(late: Bool, reply: String?) throws -> ChatWaiting? {
            let agent: [String: Any] = ["name": "studio", "role": "worker", "runtime": "claude", "active": true,
                                        "can": [], "last_seen": 4_990, "chat_undelivered": late]
            let message: [String: Any] = ["request_id": "s-1", "recipient": "studio", "kind": "message",
                                          "need_id": NSNull(), "text": "Fix the sign-in page.", "event_id": 7,
                                          "created": 4_800, "read_at": 4_803, "client": "founderizer-mac/1/x"]
            let word: [String: Any] = ["id": 1, "text": "I open a task for it.", "about": "", "created": 4_806,
                                       "agent": "studio", "in_reply_to": reply.map { $0 as Any } ?? NSNull(),
                                       "pushed": false]
            let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": "db", "time": 5_000, "agents": [agent], "tasks": [], "notes": [],
                "needs": [], "permissions": [], "messages": [message], "reports": [word],
            ] as [String: Any]))
            return try #require(state.agents.first).chatWaiting(in: state, sending: false, fresh: true, until: { _ in "" })
        }
        #expect(try line(late: false, reply: nil) == nil)           // a word with no link: the chat claims nothing
        #expect(try line(late: true, reply: nil)?.says == "Not answering")
        #expect(try line(late: true, reply: nil)?.moving == false)
        #expect(try line(late: true, reply: "s-1") == nil)          // his message has its reply
        // Only that one state changes: nothing to wait for stays nothing, and a turn that is over stays over.
        #expect(ChatWaiting.Pending.none.late(true) == ChatWaiting.Pending.none)
        #expect(ChatWaiting.Pending.turnOver.late(true) == .turnOver)
        #expect(ChatWaiting.Pending.spokenSince.late(nil) == .spokenSince)
        #expect(ChatWaiting.Pending.spokenSince.late(true) == .waiting)
    }

    /// A line that moves while nothing is happening is the lie this exists to avoid: four minutes of pulsing is
    /// indistinguishable from a hang. So only the agent's own work moves, and it is the only thing that does.
    @Test func onlyWhatIsHappeningMoves() throws {
        let blocked = [ChatWaiting.of(agent: "a", pending: .waiting, sending: false, limit: try limit(1), offline: false, until: { _ in "x" }),
                       ChatWaiting.of(agent: "a", pending: .waiting, sending: false, limit: nil, offline: true, until: { _ in "x" })]
        #expect(blocked.allSatisfy { $0?.moving == false })
        // A limit outranks a quiet machine: it is the one with a time on it, and the more useful of the two.
        let both = ChatWaiting.of(agent: "a", pending: .waiting, sending: true, limit: try limit(1), offline: true,
                                  until: { _ in "14:30" })
        #expect(both?.says == "Usage limit")
        #expect(both?.detail == "A is at its usage limit until 14:30.")
    }

    /// **The manager's reply never carries a link, so a line that waits for one never clears.** The hub gives a
    /// request id only to a worker's or a lead's chat (`owner_message_rows`), so every reply the fleet manager
    /// writes comes back with `in_reply_to` empty. The owner saw the result on his own screen on 20 October
    /// 2026: the manager's answer, and "Thinking" turning under it for ever.
    @Test func anAnswerNothingLinksStillEndsTheWait() throws {
        #expect(ChatWaiting.of(agent: "manager", pending: .spokenSince, sending: false, limit: nil,
                               offline: false, until: { _ in "" }) == nil)
        // And it is not overridden by the two states that are about the agent's machine: with nothing waited
        // for, a usage limit and a silent helper are facts of the fleet, not something to say under his message.
        let held = try limit(1_792_000_000)
        #expect(ChatWaiting.of(agent: "manager", pending: .spokenSince, sending: false,
                               limit: held, offline: true, until: { _ in "14:30" }) == nil)
        // His own next message is waited for again, and this Mac's send is its own wait whatever came before.
        #expect(ChatWaiting.of(agent: "manager", pending: .spokenSince, sending: true, limit: nil,
                               offline: false, until: { _ in "" })?.says == ChatWaiting.working)
    }

    /// **A turn that ended with no reply is not work.** 10 November 2026, his own screen: a session on his Mac sent
    /// the manager three messages in his name, each with "No answer to the owner is necessary." The manager did the
    /// work in turns of 20 seconds and wrote none, and "Thinking" turned in its chat for more than an hour.
    @Test func aTurnThatEndedWithNoReplyEndsTheWait() throws {
        #expect(ChatWaiting.of(agent: "manager", pending: .turnOver, sending: false, limit: nil,
                               offline: false, until: { _ in "" }) == nil)
        // Nothing is waited for, so the two states of the agent's machine say nothing under his message either.
        #expect(ChatWaiting.of(agent: "manager", pending: .turnOver, sending: false,
                               limit: try limit(1_792_000_000), offline: true, until: { _ in "14:30" }) == nil)
        // His own next message on its way is waited for again.
        #expect(ChatWaiting.of(agent: "manager", pending: .turnOver, sending: true, limit: nil,
                               offline: false, until: { _ in "" })?.says == ChatWaiting.working)
        // The hub names the newest message that the ended turn had read: that one and each one before it.
        #expect(ChatWaiting.turnIsOver(sent: 100, turnEndedAfter: 100))
        #expect(ChatWaiting.turnIsOver(sent: 90, turnEndedAfter: 100))
        #expect(!ChatWaiting.turnIsOver(sent: 100.5, turnEndedAfter: 100))
        // An agent whose turns the hub does not know, and an older hub: nothing is known, so the wait stays.
        #expect(!ChatWaiting.turnIsOver(sent: 100, turnEndedAfter: nil))
    }

    /// The hub's state of that day, in small: his three messages to the manager, each read, and no report after them.
    private func state(turnEndedAfter: Double?, reports: [[String: Any]] = [], field: Bool = true) throws -> HubState {
        func message(_ id: String, _ created: Double, to recipient: String? = nil, kind: String = "message",
                     read: Bool = true) -> [String: Any] {
            ["request_id": id, "recipient": recipient.map { $0 as Any } ?? NSNull(), "kind": kind, "need_id": NSNull(),
             "text": "No answer to the owner is necessary.", "event_id": Int(created), "created": created,
             "read_at": read ? created + 2 : NSNull() as Any, "client": "founderizer-mcp/1/x"]
        }
        var manager: [String: Any] = ["name": "manager", "role": "manager", "runtime": "claude", "active": true, "can": []]
        if field { manager["turn_ended_after"] = turnEndedAfter.map { $0 as Any } ?? NSNull() }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "db", "time": 5_000,
            "agents": [manager, ["name": "leo", "role": "worker", "runtime": "claude", "active": true, "can": []]],
            "tasks": [], "notes": [], "needs": [], "permissions": [],
            "messages": [message("m-1", 1_000), message("m-2", 2_000), message("m-3", 3_000),
                         message("l-1", 3_500, to: "leo")],
            "reports": reports,
        ] as [String: Any]))
    }

    private func waits(_ state: HubState, _ agent: String = "manager") -> ChatWaiting.Pending? {
        state.agents.first { $0.name == agent }?.pendingChat(in: state)?.waits
    }

    @Test func theChatWaitsOnlyWhileTheTurnThatTookHisNewestMessageRuns() throws {
        // The manager's last ended turn had read his newest message: nothing is waited for.
        #expect(waits(try state(turnEndedAfter: 3_000)) == .turnOver)
        // It had read the one before, and the newest is read in a turn that still runs, or not read yet: it works.
        #expect(waits(try state(turnEndedAfter: 2_000)) == .waiting)
        // No turn end is known, and an older hub that sends no such field: the wait is as it was.
        #expect(waits(try state(turnEndedAfter: nil)) == .waiting)
        #expect(waits(try state(turnEndedAfter: nil, field: false)) == .waiting)
        // A reply still comes first: one that names the message answers it, and a later one that names none says
        // nothing either way.
        let named: [String: Any] = ["id": 1, "text": "Done.", "about": "", "created": 3_010, "agent": "manager",
                                    "in_reply_to": "m-3", "pushed": false]
        #expect(waits(try state(turnEndedAfter: 3_000, reports: [named])) == nil)
        let unlinked = named.merging(["in_reply_to": NSNull()]) { _, new in new }
        #expect(waits(try state(turnEndedAfter: 3_000, reports: [unlinked])) == .spokenSince)
        // Another agent's chat reports no turns: the manager's turn says nothing of it.
        #expect(waits(try state(turnEndedAfter: 3_000), "leo") == .waiting)
    }

    /// **The agent's row of the sidebar moves exactly while its chat says "Thinking"** (the owner, 13 November 2026:
    /// "The subtitle text on the sidebar task item should animate like the Thinking label, while the agent is
    /// Thinking"): one rule for the chat's line and for the row, from the hub's state.
    @Test func anAgentThinksExactlyWhileItsChatSaysThinking() throws {
        func agent(_ name: String, in state: HubState) throws -> FleetAgent {
            try #require(state.agents.first { $0.name == name })
        }
        // His newest message is read in a turn that still runs: the manager thinks, and its chat says so.
        let runs = try state(turnEndedAfter: 2_000)
        #expect(try agent("manager", in: runs).thinks(in: runs, sending: false, fresh: false))
        #expect(try agent("manager", in: runs).chatWaiting(in: runs, sending: false, fresh: false, until: { _ in "" })?.says
                == ChatWaiting.working)
        // The turn that took it has ended: nothing moves, until his next message is on its way.
        let over = try state(turnEndedAfter: 3_000)
        #expect(try !agent("manager", in: over).thinks(in: over, sending: false, fresh: false))
        #expect(try agent("manager", in: over).thinks(in: over, sending: true, fresh: false))
        // A wait that is not the agent's work does not move: by a current reading these agents' servers are quiet
        // (the state has no `last_seen`), and the chat says "Not answering".
        #expect(try !agent("leo", in: runs).thinks(in: runs, sending: false, fresh: true))
        #expect(try agent("leo", in: runs).thinks(in: runs, sending: false, fresh: false))
    }
}
