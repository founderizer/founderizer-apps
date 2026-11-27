import FleetCore
import FleetMark
import Foundation
import SwiftUI
import Testing
@testable import FleetMobile

/// The phone's compact reads. The fixture proves that the app shows them; these checks prove that it reads each field
/// as the hub means it and refuses an answer that does not match the contract, so a wrong answer never reads as a
/// fleet.
@Suite("The compact reads")
struct MobileReadTests {

    // MARK: Answers of the hub, built field by field

    private func agentFields(_ changes: [String: Any?] = [:]) -> [String: Any] {
        apply(changes, to: ["name": "studio", "role": "worker", "runtime": "claude", "active": true,
                            "direct_chat": true, "last_seen": 980.0, "open_tasks": 2,
                            "usage": [["label": "5 h", "used_percent": 40.0, "resets_at": 4000.0],
                                      ["label": "7 d", "used_percent": 71.4, "resets_at": 9000.0]],
                            "last": ["ts": 990.0, "side": "agent", "preview": "The task is done."]])
    }

    private func headFields(_ changes: [String: Any?] = [:]) -> [String: Any] {
        apply(changes, to: ["id": 7, "title": "A task", "state": "working", "owner": "vps", "requester": "manager",
                            "goal": "", "needs": "shell", "attempt": 1, "created": 10.0, "started": 20.0,
                            "last_activity": 30.0])
    }

    /// A field that is set to nil leaves the answer, as the hub leaves out what it does not have.
    private func apply(_ changes: [String: Any?], to base: [String: Any]) -> [String: Any] {
        var fields = base
        for (key, value) in changes {
            if let value { fields[key] = value } else { fields.removeValue(forKey: key) }
        }
        return fields
    }

    private func snapshot(agents: [[String: Any]], _ changes: [String: Any?] = [:]) throws -> MobileSnapshot {
        let fields = apply(changes, to: ["schema_version": 1, "db": "gen-1", "time": 1000.0, "agents": agents,
                                         "needs": [], "tasks": [], "recent": [], "holds": [], "outcomes": [],
                                         "counts": ["tasks_open": 0, "needs_open": 0, "messages": 3, "reports": 4]])
        return try MobileSnapshot.decode(JSONSerialization.data(withJSONObject: fields))
    }

    private func head(_ changes: [String: Any?] = [:]) throws -> MobileTaskHead {
        try JSONDecoder().decode(MobileTaskHead.self, from: JSONSerialization.data(withJSONObject: headFields(changes)))
    }

    // MARK: The agents

    @Test("One agent's head reads as the hub sends it")
    func anAgentHead() throws {
        let read = try snapshot(agents: [agentFields()])
        let agent = try #require(read.agents.first)
        #expect(agent.open_tasks == 2)
        #expect(agent.helperIsRecent(serverTime: read.time))
        #expect(!agent.helperIsRecent(serverTime: read.time + 120))
        // The row shows the window with the highest used share, in whole percent.
        #expect(agent.busiestWindow?.label == "7 d")
        #expect(agent.busiestWindow?.percent == 71)
        #expect(agent.last?.isFromAgent == true)
        #expect(agent.limit == nil)
        // An older hub, and an agent whose turns the hub does not know, say nothing of a turn end (hub 1.110).
        #expect(agent.turn_ended_after == nil)
        #expect(try snapshot(agents: [agentFields(["turn_ended_after": NSNull()])]).agents.first?.turn_ended_after == nil)
        #expect(try snapshot(agents: [agentFields(["turn_ended_after": 970.5])]).agents.first?.turn_ended_after == 970.5)
        // An older hub says nothing of a message that does not arrive (hub 1.144); a newer one says true or false.
        #expect(agent.chat_undelivered == nil)
        #expect(try snapshot(agents: [agentFields(["chat_undelivered": true])]).agents.first?.chat_undelivered == true)
        #expect(try snapshot(agents: [agentFields(["chat_undelivered": false])]).agents.first?.chat_undelivered == false)
    }

    @Test("A check that the hub gave an agent asks the owner nothing in the chat either (owner API 1.324)")
    func aRoutedCheckIsNoAskInTheChat() throws {
        // A held task, whose unknown outcome the hub gave the manager: the chat's Asked row reads the reading's
        // features, as Needs you does; a hub that does not serve outcome_checks keeps the app's own rule.
        let held: [String: Any] = ["id": 1, "task": 7, "kind": "stop", "state": "stopped", "attempt": 1]
        let row: [String: Any] = ["id": 5, "task": 7, "attempt": 1, "title": "Send the note", "kind": "send",
                                  "state": "unknown", "checker": "manager"]
        let task = try #require(try head().fleetTask)
        let cases: [([String], Bool)] = [([TaskOutcome.routedFeature], false), ([], true)]
        for (features, asks) in cases {
            let read = try snapshot(agents: [agentFields()], ["holds": [held], "outcomes": [row], "ui_features": features])
            #expect(MobileStore.askReading(read, tasks: [task], messages: []).outcomeUnknown(7) == asks)
        }
    }

    @Test("A reading without a window is unknown, never nought percent")
    func noWindowNoPercent() throws {
        let read = try snapshot(agents: [agentFields(["usage": []])])
        #expect(read.agents.first?.busiestWindow == nil)
    }

    @Test("An agent that said nothing has no last line")
    func noConversationNoLine() throws {
        let read = try snapshot(agents: [agentFields(["last": nil])])
        #expect(read.agents.first?.last == nil)
    }

    @Test("A usage window without a share is left out of the row")
    func aWindowWithoutAShare() throws {
        let read = try snapshot(agents: [agentFields(["usage": [["label": "5 h"]]])])
        #expect(read.agents.first?.busiestWindow == nil)
    }

    @Test("A hub that holds an agent's work says until when")
    func aHeldAgent() throws {
        let read = try snapshot(agents: [agentFields(["limit": ["since": 900.0, "until": 4000.0,
                                                                "reset_known": true]])])
        #expect(read.agents.first?.limit?.until == 4000.0)
        #expect(read.agents.first?.limit?.reset_known == true)
    }

    @Test("A helper that was recent in the answer keeps the age it had, and an older one ages on")
    func aHelpersAgeAfterA304() throws {
        // The hub's tag holds whether a helper answered in the last minute, not when: a 304 ten minutes on says
        // that the recent one is recent still, and that the other one has not answered since.
        let read = try snapshot(agents: [agentFields(), agentFields(["name": "vps", "last_seen": 700.0])])
        let later = read.time + 600
        #expect(read.agents[0].helperClock(serverTime: read.time, hubNow: later) == read.time)
        #expect(read.agents[1].helperClock(serverTime: read.time, hubNow: later) == later)
    }

    // MARK: The answer as a whole

    @Test("An answer of another API version is refused")
    func anotherVersionIsRefused() {
        #expect(throws: MobileError.self) { try snapshot(agents: [agentFields()], ["schema_version": 2]) }
    }

    @Test("An answer without a generation is refused")
    func noGenerationIsRefused() {
        #expect(throws: MobileError.self) { try snapshot(agents: [agentFields()], ["db": ""]) }
    }

    @Test("An answer with the same agent twice is refused")
    func duplicatesAreRefused() {
        #expect(throws: MobileError.self) { try snapshot(agents: [agentFields(), agentFields()]) }
    }

    // MARK: The tasks

    /// A task's one word (`TaskWords.state`, through the head's own door), against no hold and no limit.
    private func word(_ changes: [String: Any?] = [:], holds: [TaskHold] = [], limited: Set<String> = []) throws -> String {
        let task = try head(changes)
        return task.stateWord(holds: holds, limited: limited.contains(task.owner))
    }

    private func hold(_ kind: String, _ state: String, task: Int = 7) throws -> TaskHold {
        try JSONDecoder().decode(TaskHold.self, from: JSONSerialization.data(withJSONObject: [
            "id": 1, "task": task, "kind": kind, "state": state, "attempt": 1]))
    }

    @Test("A task says one word, the Mac's, on its row, its page and its agent's page")
    func taskWords() throws {
        #expect(try word() == "Working")
        #expect(try word(["state": "submitted"]) == "Queued")
        #expect(try word(["state": "completed", "accepted": 1]) == "Checked")
        #expect(try word(["state": "completed"]) == "Awaiting check")
        #expect(try word(["state": "auth-required"]) == "Sign-in needed")
        // Whose answer it waits for, in three words: him, or the agent that asked.
        #expect(try word(["state": "input-required", "requester": "owner"]) == "Waiting for you")
        #expect(try word(["state": "input-required"]) == "Waiting for Manager")
        // A result that is not a success says so, whatever else holds but a hold: a stop that its helper has not
        // confirmed says "Stopping…" first, as on the Mac (review B4i).
        #expect(try word(["state": "canceled"], limited: ["vps"]) == "Canceled")
        #expect(try word(["state": "canceled"], holds: [hold("stop", "requested")]) == "Stopping…")
        #expect(try word(["state": "completed", "accepted": 0]) == "Not accepted")
        // A state that this app does not know is never shown as work, and never hidden.
        #expect(try word(["state": "something-new"]) == "Something-new")
        // A row with no state (no writer of the hub makes one; a block of older tasks can hold it, owner API 1.330) is a
        // state that this app does not know: the reading keeps every other row, as for a null goal on the Mac.
        let stateless = try snapshot(agents: [agentFields()], ["tasks": [headFields(["state": NSNull()]), headFields(["id": 8])]])
        #expect(stateless.tasks.map(\.state) == ["", "working"])
        #expect(stateless.tasks.first?.isTerminal == false && stateless.tasks.first?.fleetTask?.state == "")
    }

    /// A task's word by the phone's own rule (`MobileStore.limit`, FleetCore's `TaskLimit`), from a reading whose agent
    /// `vps` has a hold of its own route or none, and whose head has its own hold or none (owner API 1.330).
    private func heldWord(features: [String]?, agentHeld: Bool, taskHeld: Bool) throws -> String {
        let hold: [String: Any] = ["since": 900.0, "until": 4000.0, "reset_known": true]
        let read = try snapshot(agents: [agentFields(["name": "vps", "limit": agentHeld ? hold : nil])],
                                ["tasks": [headFields(["needs": "screen", "limit": taskHeld ? hold : nil])],
                                 "ui_features": features])
        let head = try #require(read.tasks.first)
        // The ask rows read the head as FleetCore's task, with the same hold (`askReading`, `markReading`).
        #expect(head.fleetTask?.limit?.until == head.limit?.until)
        return head.stateWord(holds: read.holds, limited: MobileStore.limit(head.limit, owner: head.owner, in: read) != nil)
    }

    /// **On a hub with `task_limit` a task's own `limit` alone says "Usage limit"** (owner API 1.330; the owner, 24
    /// November 2026: an agent's usage was wrong): a desktop task that a hold of its screen route keeps waiting, while
    /// its agent's `limit` (the hold of the agent's own route) is null; and no other task of an agent whose own route is
    /// held. A hub without it gives no task `limit`, and the agent's `limit` decides, as before. Fails when the phone
    /// reads the agent's `limit` on every hub: the held desktop task said "Working" for days.
    @Test("What holds a task is its word: a hold, its usage limit, a stall")
    func whatHoldsATask() throws {
        #expect(try heldWord(features: ["push", TaskLimit.feature], agentHeld: false, taskHeld: true) == "Usage limit")
        #expect(try heldWord(features: [TaskLimit.feature], agentHeld: true, taskHeld: false) == "Working")
        #expect(try heldWord(features: ["push"], agentHeld: true, taskHeld: false) == "Usage limit")
        #expect(try heldWord(features: nil, agentHeld: false, taskHeld: true) == "Working")
        // The list said "Working" for each of these while the task's page and the Mac said what held it.
        #expect(try word(holds: [hold("pause", "held")]) == "Paused")
        #expect(try word(holds: [hold("stop", "requested")]) == "Stopping…")
        #expect(try word(holds: [hold("stop", "not_confirmed")]) == "Stop not confirmed")
        #expect(try word(holds: [hold("pause", "held", task: 8)]) == "Working")
        #expect(try word(holds: [hold("pause", "released")]) == "Working")
        #expect(try word(limited: ["vps"]) == "Usage limit")
        #expect(try word(limited: ["juno"]) == "Working")
        #expect(try word(["stalled_since": 500.0]) == "Stalled")
        #expect(try word(["nudge_level": 2]) == "Stalled")
        #expect(try word(["missing_since": 500.0]) == "Reconnecting")
        // A hold comes before the limit, as on the Mac.
        #expect(try word(holds: [hold("pause", "held")], limited: ["vps"]) == "Paused")
    }

    @Test("An agent's state is the Mac's: an old reading keeps its look, a paused task is no work, a wait says its word")
    func anAgentsState() throws {
        func state(_ heads: [[String: Any]], holds: [[String: Any]] = [], fresh: Bool = true) throws -> AgentState {
            let read = try snapshot(agents: [agentFields(["name": "vps"])], ["tasks": heads, "holds": holds])
            return try #require(read.agents.first).mobileState(in: read, isFresh: fresh)
        }
        #expect(try state([headFields()]) == .working)
        // An old reading: the look it read, and the mark at rest.
        #expect(try state([headFields()], fresh: false) == .old(.working))
        #expect(try state([headFields(["state": "input-required"])], fresh: false) == .old(.attention("Waiting for Manager")))
        // A paused task is no work; a stalled one, a wait for its requester and a sign-in say their own word.
        #expect(try state([headFields()], holds: [["id": 1, "task": 7, "kind": "pause", "state": "held", "attempt": 1]])
                == .online)
        #expect(try state([headFields(["stalled_since": 500.0])]) == .attention("Stalled"))
        #expect(try state([headFields(["state": "auth-required"])]) == .attention("Sign-in needed"))
        #expect(try state([headFields(["state": "submitted"])]) == .online)
        // What an agent does now is the words of its task whose session works (hub 1.148); none from a task that waits.
        let acting = try snapshot(agents: [agentFields(["name": "vps"])],
                                  ["tasks": [headFields(["works": true, "doing": "Read live API health and public status"]),
                                             headFields(["id": 8, "works": false, "doing": "Words that a turn's end left",
                                                         "last_activity": 90.0])]])
        #expect(acting.action(of: "vps") == "Read live API health and public status")
        #expect(acting.action(of: "studio") == nil)
        // A task between its turns, or parked on a reminder, is no work: its agent's mark rests.
        #expect(try state([headFields(["works": false])]) == .online)
        #expect(try state([headFields(["works": true])]) == .working)
        // An old reading says so in words, with the look it read (fix round 3, COPY): its mark keeps its colour and rests.
        #expect(AgentState.old(.working).words == "Last reading" && AgentState.attention("Stalled").words == "Stalled")
        // A dot is a problem: neither online nor work has one. With Reduce Motion nothing moves, and work keeps its dot.
        #expect(!AgentState.working.hasDot(reduceMotion: false) && !AgentState.old(.working).hasDot(reduceMotion: false))
        #expect(AgentState.working.hasDot(reduceMotion: true) && !AgentState.old(.online).hasDot(reduceMotion: true))
        #expect(AgentState.limited.hasDot(reduceMotion: false) && AgentState.attention("Stalled").hasDot(reduceMotion: false))
        #expect(AgentState.offline.hasDot(reduceMotion: false) && AgentState.setup.hasDot(reduceMotion: false))
        // An agent that works on his newest chat message works too, by a current reading or an old one.
        let idle = try snapshot(agents: [agentFields(["name": "vps"])], ["tasks": [], "holds": []])
        #expect(try #require(idle.agents.first).mobileState(in: idle, isFresh: true, thinking: true) == .working)
        #expect(try #require(idle.agents.first).mobileState(in: idle, isFresh: false, thinking: true) == .old(.working))
    }

    @Test("A task's mark is the Mac's: a paused, a stalled and a limited task are not the green circle of work")
    func taskMarks() throws {
        func mark(_ changes: [String: Any?] = [:], holds: [TaskHold] = [], limited: Bool = false) throws -> String {
            try head(changes).mark(holds: holds, limited: limited).symbol
        }
        #expect(try mark() == "circle.dotted")
        #expect(try mark(holds: [hold("pause", "held")]) == "pause.circle")
        #expect(try mark(["stalled_since": 500.0]) == "exclamationmark.circle")
        #expect(try mark(limited: true) == "hourglass")
        #expect(try mark(["state": "submitted", "waiting_on": "juno"]) == "hourglass")
        #expect(try mark(["state": "completed", "accepted": 1]) == "checkmark.circle.fill")
        #expect(try mark(["state": "failed"]) == "exclamationmark.circle.fill")
        #expect(try mark(["state": "canceled"]) == "exclamationmark.circle.fill")
        #expect(try head().mark(holds: [hold("pause", "held")], limited: false, outcomeUnknown: true).symbol
                == "questionmark.circle")
        #expect(try !head().mark(holds: [hold("pause", "held")], limited: false).inWork)
        // A task in state working is work only while its session works on it (hub 1.147): no work where its last turn
        // ended and nothing of it runs; its state says it where the hub says nothing of its turns.
        #expect(try head().mark(holds: [], limited: false).inWork)
        #expect(try head(["works": true]).mark(holds: [], limited: false).inWork)
        #expect(try !head(["works": false]).mark(holds: [], limited: false).inWork)
        #expect(try head(["works": false]).mark(holds: [], limited: false).symbol == "circle.dotted")
    }

    @Test("In the app that hosts the checks no request leaves this Mac: the owner's hub is never reached")
    func noCheckReachesHisHub() async throws {
        #expect(MobileStore.hostsTests)
        #expect(MobileClient.isLoopback(URL(string: "http://127.0.0.1:9/")))
        #expect(!MobileClient.isLoopback(URL(string: HubClient.defaultAddress)))
        // A read of an address off this Mac is refused before it goes, as every path's request is. The address is a
        // documentation one (TEST-NET-1), never his: if the door failed, this check would reach nobody.
        let hub = try MobileClient.address("http://192.0.2.1:9")
        await #expect(throws: MobileClient.OffThisMac.self) {
            _ = try await MobileClient().snapshot(at: hub, key: nil, database: nil, etag: nil)
        }
    }

    @Test("A task waits on an agent by its name, and never on the hub's own mark")
    func waitingOn() throws {
        #expect(try word(["state": "submitted", "waiting_on": "juno"]) == "Waiting on Juno")
        // The hub's marks of what a task waits on are its books: the task waits for its requester.
        #expect(try word(["state": "input-required", "waiting_on": "Q-12", "requester": "owner"]) == "Waiting for you")
        #expect(try word(["state": "submitted", "waiting_on": "its screen"]) == "Waiting for Manager")
    }

    @Test("A request's head is the Mac's: who asks and when, the time today, the weekday in the last week")
    func requestHeads() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15)))
        let today = now.addingTimeInterval(-2 * 3600).timeIntervalSince1970
        let head = requestHead(by: "iris", raised: today, now: now)
        #expect(head.hasPrefix("From Iris · "))
        #expect(head == "From Iris · " + Date(timeIntervalSince1970: today).formatted(date: .omitted, time: .shortened))
        let earlier = now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970
        #expect(requestTime(earlier, now: now, calendar: calendar)
                == Date(timeIntervalSince1970: earlier).formatted(.dateTime.weekday(.wide).hour().minute()))
        let older = now.addingTimeInterval(-20 * 86_400).timeIntervalSince1970
        #expect(requestTime(older, now: now, calendar: calendar)
                == Date(timeIntervalSince1970: older).formatted(date: .abbreviated, time: .shortened))
    }

    @Test("The fleet's read names the answered requests, and an older hub's read names none")
    func theAnsweredRequests() throws {
        let answered: [String: Any] = ["id": 3, "by": "iris", "title": "Which courier for Portugal?", "why": "",
                                       "todo": "", "raised": 20.0, "answer": "Correos", "answered": 40.0,
                                       "options": ["Correos", "DHL"], "chosen": 0]
        let read = try snapshot(agents: [agentFields()], ["answered_needs": [answered]])
        let need = try #require(read.answered_needs?.first)
        #expect(need.id == 3 && need.answer == "Correos" && !need.isOpen)
        // A hub from before the field: the chats show the open requests only.
        #expect(try snapshot(agents: [agentFields()]).answered_needs == nil)
        // Two items with one number are no answer of the hub's.
        #expect(throws: MobileError.self) {
            try snapshot(agents: [agentFields()], ["answered_needs": [answered, answered]])
        }
    }

    /// Owner API 1.274 (the owner, 20 November 2026, of a chat where a folded card said "Replaced by manager with a new
    /// item: …" over the card of the new item): the bug that this catches is a chat of the phone, or the line of its
    /// row on Chats, that places the hub's answered requests as they come, so the old card with the hub's own words
    /// stands over the new one; or one that drops the card while his own answer to it is still in the outbox.
    @Test("A request that a new item replaced has no card in its chat, unless his answer to it is in the outbox")
    func aReplacedRequestHasNoCard() throws {
        func need(_ id: Int, answer: String, replacedBy: Int? = nil) -> [String: Any] {
            var fields: [String: Any] = ["id": id, "by": "manager", "title": "Publish the post?", "why": "", "todo": "",
                                         "raised": 20.0, "answer": answer, "answered": 40.0]
            if let replacedBy { fields["replaced_by"] = replacedBy }
            return fields
        }
        let read = try snapshot(agents: [agentFields()], ["answered_needs": [
            need(3, answer: "Replaced by manager with a new item: Publish the post?", replacedBy: 4),
            need(5, answer: "Yes")]])
        #expect(MobileStore.answered(read, holding: nil).map(\.id) == [5])
        // his answer to it is the outbox's request: its card stays until that answer is cleared
        #expect(MobileStore.answered(read, holding: 3).map(\.id) == [3, 5])
    }

    @Test("A time to come reads as the Mac writes it: the time today, the weekday this week, else the day")
    func aTimeToCome() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9)))
        let later = now.addingTimeInterval(2 * 3600)
        #expect(comingTime(later.timeIntervalSince1970, now: now.timeIntervalSince1970, calendar: calendar)
                == later.formatted(date: .omitted, time: .shortened))
        let thisWeek = now.addingTimeInterval(2 * 86_400)
        #expect(comingTime(thisWeek.timeIntervalSince1970, now: now.timeIntervalSince1970, calendar: calendar)
                == thisWeek.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        let far = now.addingTimeInterval(10 * 86_400)
        #expect(comingTime(far.timeIntervalSince1970, now: now.timeIntervalSince1970, calendar: calendar)
                == far.formatted(.dateTime.day().month(.abbreviated)))
    }

    /// **A task's page says until when the hold that keeps it ends** (`MobileStore.untilLine`, by the rule of every
    /// limit; owner API 1.330): its own hold on a hub with `task_limit`, with "(estimate)" when the provider gave no reset
    /// time; else its agent's, as before; and no line for a task that ended. Fails when the page reads its agent's limit
    /// on every hub (a line under a desktop task that its agent's own route does not hold, and none under the one that a
    /// hold of the screen route keeps), or when an ended task keeps a line.
    @Test("A task's page says until when its usage limit holds it")
    func theTaskPagesUntilLine() throws {
        func line(features: [String]?, agentHeld: Bool, taskHeld: Bool, known: Bool = true,
                  state: String = "working") throws -> String? {
            let hold: [String: Any] = ["since": 900.0, "until": 4000.0, "reset_known": known]
            let read = try snapshot(agents: [agentFields(["name": "vps", "limit": agentHeld ? hold : nil])],
                                    ["tasks": [headFields(["needs": "screen", "state": state, "limit": taskHeld ? hold : nil])],
                                     "ui_features": features])
            let task = try #require(read.tasks.first?.fleetTask)
            return MobileStore.untilLine(task, in: read, now: read.time)
        }
        let until = "Until " + comingTime(4000, now: 1000)
        #expect(try line(features: [TaskLimit.feature], agentHeld: false, taskHeld: true) == until)
        #expect(try line(features: [TaskLimit.feature], agentHeld: false, taskHeld: true, known: false) == until + " (estimate)")
        #expect(try line(features: [TaskLimit.feature], agentHeld: true, taskHeld: false) == nil)
        #expect(try line(features: nil, agentHeld: true, taskHeld: false) == until)
        #expect(try line(features: [TaskLimit.feature], agentHeld: false, taskHeld: true, state: "completed") == nil)
    }

    @Test("A result that is not a success has its own word")
    func taskResults() throws {
        #expect(try head(["state": "failed"]).failedResult == "Failed")
        #expect(try head(["state": "rejected"]).failedResult == "Rejected")
        #expect(try head(["state": "canceled"]).failedResult == "Canceled")
        #expect(try head(["state": "completed", "accepted": 0]).failedResult == "Not accepted")
        #expect(try head(["state": "completed", "accepted": 1]).failedResult == nil)
        #expect(try head().failedResult == nil)
        #expect(try head(["state": "completed"]).isTerminal)
        #expect(try !head().isTerminal)
    }

    @Test("A task head has no activity of its own before it starts")
    func headActivityTime() throws {
        #expect(try head(["started": nil, "last_activity": nil]).activityTime == 10.0)
        #expect(try head(["last_activity": nil]).activityTime == 20.0)
        #expect(try head().activityTime == 30.0)
    }

    // MARK: One conversation

    @Test("A message is known by its request number and a report by its own number")
    func chatItemsHaveTwoKindsOfNumber() throws {
        let page = try JSONDecoder().decode(MobileChatPage.self, from: Data("""
        {"db": "gen-1", "agent": "studio", "cursor": 20.0, "items": [
          {"kind": "message", "ts": 10.0, "id": "0f8d4b1e-1111-2222-3333-444455556666", "text": "Hello",
           "client": "founderizer-ios/1/x", "read_at": 11.0, "replaces": null},
          {"kind": "report", "ts": 20.0, "id": 42, "text": "Done", "about": "task", "in_reply_to": null}]}
        """.utf8))
        #expect(page.items.count == 2)
        #expect(page.items[0].key == "0f8d4b1e-1111-2222-3333-444455556666")
        #expect(page.items[0].id == "message-0f8d4b1e-1111-2222-3333-444455556666")
        #expect(page.items[0].client == "founderizer-ios/1/x")
        #expect(page.items[1].key == "42")
        #expect(page.items[1].id == "report-42")
        // The two kinds never take each other's identity, so one page never replaces the other's rows.
        #expect(page.items[0].id != page.items[1].id)
        #expect(page.cursor == 20.0)
    }

    @Test("The feature names come with the compact read, so no other read is wanted")
    func featuresInTheCompactRead() throws {
        let withNames = try snapshot(agents: [agentFields()], ["ui_features": ["mobile", "direct_chat", "corrections"]])
        #expect(withNames.ui_features.map(Set.init) == ["mobile", "direct_chat", "corrections"])
        // An answer without them is still read: the phone then offers no direct chat and no correction, rather
        // than claiming either.
        #expect(try snapshot(agents: [agentFields()]).ui_features == nil)
    }

    @Test("The compact read carries the change token, and an older hub's is read without one")
    func theChangeToken() throws {
        let read = try snapshot(agents: [agentFields()], ["token": "a1b2c3d4.12.40"])
        #expect(read.token == "a1b2c3d4.12.40")
        #expect(LiveToken(read.token)?.state == 12)
        // A hub from before 1.47 sends none: the phone then reads on its clock alone and waits on nothing.
        #expect(try snapshot(agents: [agentFields()]).token == nil)
    }

    @Test("A report says whether the agent wrote it first, and an older hub says nothing")
    func pushedReports() throws {
        func report(_ fields: String) throws -> MobileChatItem {
            try JSONDecoder().decode(MobileChatItem.self, from: Data("""
            {"kind": "report", "ts": 1.0, "id": 1, "text": "Hello", "about": "", "in_reply_to": null\(fields)}
            """.utf8))
        }
        #expect(try report(", \"pushed\": true").isPushed)
        #expect(try !report(", \"pushed\": false").isPushed)
        // Without the field the mark stays off: it rests on the hub's word, never on a guess.
        #expect(try !report("").isPushed)
        #expect(try report("").pushed == nil)
    }

    @Test("The phone says the Mac's words: the hub line whole, an old reading, a refused message")
    func theMacsWords() {
        #expect(MobileError.noAnswer.localizedDescription == "Your hub did not answer. Check that its server is on.")
        #expect(AgentState.unknown.words == "Last reading")
        let refused = MobileError.refusal(HubRefusal(status: 409, hubWords: "atlas is in setup"), auth: nil)
        #expect(refused.notSentWords == "Not sent: Atlas is in setup.")
        // A refusal of this phone's key keeps the words that say what to do.
        let key = MobileError.refusal(HubRefusal(status: 403, hubWords: ""), auth: "device_key_mismatch")
        #expect(key.notSentWords == MobileError.authWords("device_key_mismatch"))
    }

    @Test("A return to the front holds a reading's marks for its read's first second, never a failed read's line")
    @MainActor
    func theHoldOnReturn() {
        #expect(MobileStore.holdsOnReturn(hasReading: true, readFailed: false))
        // A read that failed keeps its line: holding it would take the line away for a second and bring it back.
        #expect(!MobileStore.holdsOnReturn(hasReading: true, readFailed: true))
        // Nothing read: nothing to hold, the page's loading line says it after a second.
        #expect(!MobileStore.holdsOnReturn(hasReading: false, readFailed: false))
    }

    @Test("A reading is old a second into a request of its read, or twice its last time on a slower hub, as on the Mac")
    @MainActor
    func theReadHold() {
        #expect(MobileStore.readHold(after: .zero) == .seconds(1))
        #expect(MobileStore.readHold(after: .milliseconds(300)) == .seconds(1))
        // A hub that answers every request in 1.6 s: its reads never turn the reading old for part of each read.
        #expect(MobileStore.readHold(after: .milliseconds(1600)) == .milliseconds(3200))
    }

    @Test("A first reading that comes just after the loading line showed waits until the line stood half a second")
    @MainActor
    func theLoadingLineStands() async {
        func waits(after age: Duration) async -> Duration {
            let started = ContinuousClock.now
            await MobileStore.settle(since: started - age)
            return ContinuousClock.now - started
        }
        // Inside the quiet second nothing showed, so nothing waits; long after it, the line stood long enough.
        #expect(await waits(after: .milliseconds(400)) < .milliseconds(100))
        #expect(await waits(after: .seconds(3)) < .milliseconds(100))
        // Shown at one second: a reading at 1.2 s waits for 1.5 s.
        let held = await waits(after: .milliseconds(1200))
        #expect(held > .milliseconds(200) && held < .milliseconds(600))
    }

    @Test("Where a message was written, from the client label alone")
    func theSourceOfAMessage() {
        #expect(messageSource("founderizer-ios/1/abc") == "iPhone")
        #expect(messageSource("founderizer-swift/1/abc") == "Mac")
        #expect(messageSource("fleet-channels/1/discord-studio") == "Discord")
        #expect(messageSource("fleet-channels/1/whatsapp-main") == "WhatsApp")
        #expect(messageSource(nil) == "Another client")
    }

    @Test("An agent names the server it runs on, and an older hub's read names none")
    func theServerOfAnAgent() throws {
        #expect(try snapshot(agents: [agentFields(["machine": "atlas-mac"])]).agents.first?.machine == "atlas-mac")
        #expect(try snapshot(agents: [agentFields()]).agents.first?.machine == nil)
    }

    @Test("The chat and the share sheet ask one rule which agent takes a message, and say why one does not")
    func whoTakesAMessage() throws {
        let read = try snapshot(agents: [agentFields(["name": "manager", "role": "manager"]), agentFields(),
                                         agentFields(["name": "scout", "active": false]),
                                         agentFields(["name": "mini", "direct_chat": false])])
        let direct: Set<String> = ["direct_chat"]
        #expect(read.canChat(with: "studio", features: direct))
        #expect(read.chatUnavailableWords("studio", features: direct) == nil)
        #expect(!read.canChat(with: "scout", features: direct))
        #expect(read.chatUnavailableWords("scout", features: direct)
            == "This agent is in setup. Activate it in the Mac app before sending work.")
        #expect(read.chatUnavailableWords("mini", features: direct)
            == "Direct chat is unavailable for this agent. Send a task to Manager.")
        // A hub without direct chat takes a message to the manager alone.
        #expect(read.canChat(with: "manager", features: []))
        #expect(read.chatUnavailableWords("studio", features: [])
            == "This hub needs an update before direct chat is available.")
        // An agent that the read does not name takes nothing.
        #expect(!read.canChat(with: "gone", features: direct))
    }

    @Test("The roster for the share sheet names the hub, the label and each agent in order, its role, and whether it takes a message")
    func theRosterForTheShareSheet() throws {
        let read = try snapshot(agents: [agentFields(["name": "manager", "role": "manager", "title": "Fleet Manager"]),
                                         agentFields(["title": "Support"]),
                                         agentFields(["name": "scout", "active": false])])
        let hub = try MobileClient.address("http://127.0.0.1:9")
        let roster = SharedRoster(hub: hub, installation: "founderizer-ios/1/check", snapshot: read,
                                  features: ["direct_chat"])
        #expect(roster.team.map(\.name) == ["manager", "studio", "scout"])
        #expect(roster.team.map(\.title) == ["Fleet Manager", "Support", nil])
        #expect(roster.team.map(\.takesMessage) == [true, true, false])
        #expect(roster.hubURL == hub)
        // Before any read it names the hub and the label, and no agent.
        #expect(SharedRoster(hub: hub, installation: "x", snapshot: nil, features: []).team.isEmpty)
        // The keychain gives back what the app left, and the newest roster takes the place of the one before.
        let account = "roster-check-\(UUID().uuidString)"
        defer { SharedPlace.forget(account: account) }
        #expect(SharedPlace.roster(account: account) == nil)
        #expect(SharedPlace.keep(roster, account: account))
        #expect(SharedPlace.roster(account: account) == roster)
        let next = SharedRoster(hub: hub, installation: "founderizer-ios/1/check", snapshot: nil, features: [])
        #expect(SharedPlace.keep(next, account: account))
        #expect(SharedPlace.roster(account: account) == next)
    }

    /// **Needs you draws the reading's copy of a card that stays open** (review B of 20 November 2026): the page kept
    /// its copy of each card until a card came or went, so his message under an open card and the agent's reply there
    /// (Needs clarification) never showed on Needs you, where the chat showed them; a card that folds away keeps the
    /// copy that the page kept.
    @Test func needsYouDrawsTheReadingsCopyOfAnOpenCard() throws {
        func card(_ id: Int, talk: String) throws -> OwnerNeed {
            try JSONDecoder().decode(OwnerNeed.self, from: Data(#"{"id": \#(id), "by": "manager", "title": "Refund it?", "why": "", "todo": "", "raised": 20, "answer": null, "answered": null, "clarify": true, "talk": \#(talk)}"#.utf8))
        }
        let kept = [try card(7, talk: "[]"), try card(8, talk: "[]")]
        let read = [try card(7, talk: #"[{"who": "manager", "text": "Yes, the same customer.", "ts": 30}]"#)]
        let drawn = NeedsPage.drawn(kept, open: read)
        #expect(drawn.map(\.id) == [7, 8])
        #expect(drawn.map { $0.talk?.map(\.text) ?? [] } == [["Yes, the same customer."], []])
    }

    /// **Needs you draws no copy of his answer on a card that the hub still lists as open with none on its way**
    /// (`NeedsPage.kept`): the page's copy follows the store's answers by an onChange call, and SwiftUI drops a call of
    /// one onChange that comes after others in one frame. The bug that this stops: a copy whose removal was dropped
    /// holds the open card folded, and it takes no touch. A card that folds away keeps the copy until its fold ends.
    @Test func needsYouDrawsNoCopyOfAnAnswerOnAnOpenCardWithoutOne() {
        let copy = MobileStore.GivenAnswer.option(1)
        // the call that took it away did not run: the store has no answer, and the hub lists the card as open
        #expect(NeedsPage.kept(copy, of: 8, going: [:], open: [7, 8]) == nil)
        // the card folds away (the hub no longer lists it): the copy stays
        #expect(NeedsPage.kept(copy, of: 8, going: [:], open: [7]) == copy)
        // the store has his answer: the card draws that one, also over a copy of an earlier answer that stayed
        #expect(NeedsPage.kept(copy, of: 8, going: [8: .option(2)], open: [7, 8]) == .option(2))
        #expect(NeedsPage.kept(nil, of: 8, going: [8: .option(2)], open: [8]) == .option(2))
    }

    // MARK: The mark of an answered card

    /// The Fleet Manager's request that he answered with its first option, which let task 41 go on.
    private var answeredNeed: [String: Any] {
        ["id": 9, "title": "Move the shop?", "why": "", "todo": "", "raised": 900.0, "by": "manager", "answer": "Yes",
         "answered": 950.0, "options": ["Yes", "No"], "chosen": 0, "task": 41]
    }

    /// **An answered card in a chat says what came of his answer, from the parts that the phone reads** (owner feature
    /// `need_marks`): the red mark for its task that failed, which only the heads of the tasks that ended hold, and the
    /// green mark while it works, each in the look of the phone's own mark of that state. The phone's reading had none
    /// of the hub's features, so every card stood with the check, also on a hub that sends the marks.
    @Test("An answered card is red for its task that failed and green while it works, on a hub that sends the marks")
    func anAnsweredCardsMark() throws {
        let agents = [agentFields(["name": "manager", "role": "manager"]), agentFields(["name": "vps"])]
        let failed = headFields(["id": 41, "title": "Move the shop", "state": "failed", "delivered": 40.0])
        let features = ["mobile", AnsweredMark.feature]
        let read = try snapshot(agents: agents, ["ui_features": features, "recent": [failed],
                                                 "answered_needs": [answeredNeed]])
        let need = try #require(read.answered_needs?.first)
        let red = need.answeredMark(in: MobileStore.markReading(read, ended: [], of: need))
        #expect(red == .failed(words: "Failed"))
        let redLook = AnsweredMarkView.look(of: red)
        #expect(redLook.symbol == "exclamationmark.circle.fill" && redLook.tint == .failed)
        // an ended head that a chat's read of the ended tasks brought, and an open task in work
        let ended = try head(["id": 41, "title": "Move the shop", "state": "failed", "delivered": 40.0])
        let alone = try snapshot(agents: agents, ["ui_features": features])
        #expect(need.answeredMark(in: MobileStore.markReading(alone, ended: [ended], of: need)) == red)
        let working = headFields(["id": 41, "title": "Move the shop", "works": true])
        let open = try snapshot(agents: agents, ["ui_features": features, "tasks": [working]])
        let green = need.answeredMark(in: MobileStore.markReading(open, ended: [], of: need))
        #expect(green == .working(words: "\("vps".agentLabel) · Move the shop", agent: "vps", title: "Move the shop"))
        let greenLook = AnsweredMarkView.look(of: green)
        #expect(greenLook.symbol == "circle.dotted" && greenLook.tint == .work)
        // a hub before the feature: the check, as before
        let older = try snapshot(agents: agents, ["ui_features": ["mobile"], "recent": [failed]])
        let check = need.answeredMark(in: MobileStore.markReading(older, ended: [], of: need))
        #expect(check == .done(words: "\("manager".agentLabel) has your answer"))
        #expect(AnsweredMarkView.look(of: check).symbol == "checkmark" && AnsweredMarkView.look(of: check).tint == nil)
        // a task that needs him: its own row's mark, in orange
        let orange = AnsweredMarkView.look(of: .attention(symbol: "questionmark.circle", words: "Outcome not known: check it"))
        #expect(orange.symbol == "questionmark.circle" && orange.tint == .attention)
    }
}

/// What a chat draws from what it read: the waiting line's state, Send's arrow and a chat app's mark.
@Suite("The chat's lines and marks")
@MainActor
struct MobileChatTests {
    private func item(_ json: String) throws -> MobileChatItem {
        try JSONDecoder().decode(MobileChatItem.self, from: Data(json.utf8))
    }

    @Test("The chat waits until a reply names his newest message, as the Mac's does")
    func theWaitingState() throws {
        let message = try item(#"{"kind": "message", "ts": 10, "id": "ABC-1", "text": "Is it live?", "client": "founderizer-ios/1/x"}"#)
        let reply = try item(#"{"kind": "report", "ts": 11, "id": 5, "text": "Yes.", "in_reply_to": "abc-1"}"#)
        let unlinked = try item(#"{"kind": "report", "ts": 12, "id": 6, "text": "Also this.", "in_reply_to": null}"#)
        let first = try item(#"{"kind": "report", "ts": 12, "id": 7, "text": "By the way.", "pushed": true}"#)
        #expect(ChatPage.pending(in: []) == .none)
        #expect(ChatPage.pending(in: [message]) == .waiting)
        // Only a reply that names the message answers it, whatever the case of its id.
        #expect(ChatPage.pending(in: [message, reply]) == .none)
        // A report since then that names nothing says nothing either way.
        #expect(ChatPage.pending(in: [message, unlinked]) == .spokenSince)
        // A report the agent wrote first is no reply.
        #expect(ChatPage.pending(in: [message, first]) == .waiting)
        // A reply to an older message does not answer a newer one.
        let newer = try item(#"{"kind": "message", "ts": 13, "id": "DEF-2", "text": "And now?", "client": "founderizer-ios/1/x"}"#)
        #expect(ChatPage.pending(in: [message, reply, newer]) == .waiting)
        // His answer to a request is no message that waits, as on the Mac.
        let answer = try item(#"{"kind": "message", "ts": 14, "id": "GHI-3", "text": "Yes", "client": "founderizer-ios/1/x", "answer_to": 3}"#)
        #expect(ChatPage.pending(in: [message, reply, answer]) == .none)
        // But in the manager's chat it is (hub 1.283, `ChatPage.answersWait`): the manager works on it in a turn
        // of that chat, and the end of that turn ends the wait.
        #expect(ChatPage.pending(in: [message, reply, answer], answers: true) == .waiting)
        #expect(ChatPage.pending(in: [message, reply, answer], turnEndedAfter: 14, answers: true) == .turnOver)
        // A message that the agent read in a turn that has ended with no reply is not worked on (hub 1.110): the
        // hub says when he sent the newest message that the agent's last ended turn had read.
        #expect(ChatPage.pending(in: [message], turnEndedAfter: 10) == .turnOver)
        #expect(ChatPage.pending(in: [message], turnEndedAfter: 9.5) == .waiting)
        #expect(ChatPage.pending(in: [message, reply, newer], turnEndedAfter: 10) == .waiting)
        #expect(ChatPage.pending(in: [message, reply, newer], turnEndedAfter: 13) == .turnOver)
        // A reply still comes first.
        #expect(ChatPage.pending(in: [message, reply], turnEndedAfter: 10) == .none)
        #expect(ChatPage.pending(in: [message, unlinked], turnEndedAfter: 10) == .spokenSince)
        // The hub calls his message late (hub 1.144): a word with no link then ends nothing, and the chat's line says
        // "Not answering". A reply that names his message ends the wait whatever the hub's field says.
        #expect(ChatPage.pending(in: [message, unlinked]).late(true) == .waiting)
        #expect(ChatPage.pending(in: [message, unlinked]).late(false) == .spokenSince)
        #expect(ChatPage.pending(in: [message, reply]).late(true) == .none)
    }

    @Test("An agent's row moves for its chat's Thinking: by the hub's word, or with an older hub by the chat the phone read")
    func anAgentThinks() throws {
        func agent(last ts: Double, side: String, seen: Double = 995, limited: Bool = false,
                   ended: Double? = nil, waits: Double? = nil, late: Bool = false,
                   role: String = "worker") throws -> MobileAgent {
            var fields: [String: Any] = ["name": "studio", "role": role, "runtime": "claude", "active": true,
                                         "open_tasks": 0, "usage": [[String: Any]](), "last_seen": seen,
                                         "last": ["ts": ts, "side": side, "preview": "Is it live?"]]
            if limited { fields["limit"] = ["since": 900.0, "until": 2000.0, "reset_known": true] }
            if let ended { fields["turn_ended_after"] = ended }
            if let waits { fields["waits_since"] = waits }
            if late { fields["chat_undelivered"] = true }
            return try JSONDecoder().decode(MobileAgent.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let message = try item(#"{"kind": "message", "ts": 10, "id": "ABC-1", "text": "Is it live?", "client": "founderizer-ios/1/x"}"#)
        let reply = try item(#"{"kind": "report", "ts": 11, "id": 5, "text": "Yes.", "in_reply_to": "abc-1"}"#)

        // The hub says since when the chat waits (owner feature chat_waits): a chat that the phone never read moves too.
        #expect(MobileStore.thinks(try agent(last: 10, side: "owner", waits: 10), items: [], time: 1000, hubSays: true))
        // Nothing waits by the hub's word, whatever the phone holds of the chat.
        #expect(!MobileStore.thinks(try agent(last: 10, side: "owner"), items: [message], time: 1000, hubSays: true))
        // The turn that took the message has ended; a message after that turn end waits again.
        #expect(!MobileStore.thinks(try agent(last: 10, side: "owner", ended: 10, waits: 10), items: [], time: 1000, hubSays: true))
        #expect(MobileStore.thinks(try agent(last: 12, side: "owner", ended: 10, waits: 12), items: [], time: 1000, hubSays: true))
        // Not the agent's work: its usage limit, and a server that does not answer.
        #expect(!MobileStore.thinks(try agent(last: 10, side: "owner", limited: true, waits: 10), items: [], time: 1000, hubSays: true))
        #expect(!MobileStore.thinks(try agent(last: 10, side: "owner", seen: 100, waits: 10), items: [], time: 1000, hubSays: true))
        // Nor a message that does not arrive although the server answers (hub 1.144): the chat says "Not answering".
        #expect(!MobileStore.thinks(try agent(last: 10, side: "owner", waits: 10, late: true), items: [], time: 1000, hubSays: true))

        // A hub from before the feature: his message is the conversation's newest line, and the phone holds it.
        #expect(MobileStore.thinks(try agent(last: 10, side: "owner"), items: [message], time: 1000, hubSays: false))
        // A line came since that the phone has not read (a reply): nothing says that the agent still thinks.
        #expect(!MobileStore.thinks(try agent(last: 11, side: "agent"), items: [message], time: 1000, hubSays: false))
        // The phone read the reply: it answers his message.
        #expect(!MobileStore.thinks(try agent(last: 11, side: "agent"), items: [message, reply], time: 1000, hubSays: false))
        // A chat that the phone never read says nothing.
        #expect(!MobileStore.thinks(try agent(last: 10, side: "owner"), items: [], time: 1000, hubSays: false))
        #expect(!MobileStore.thinks(try agent(last: 10, side: "owner", limited: true), items: [message], time: 1000, hubSays: false))
        #expect(!MobileStore.thinks(try agent(last: 10, side: "owner", seen: 100), items: [message], time: 1000, hubSays: false))
        #expect(!MobileStore.thinks(try agent(last: 10, side: "owner", ended: 10), items: [message], time: 1000, hubSays: false))

        // The manager's answer to its card (hub 1.283): its chat waits on it only on a hub that counts such answers
        // (`chat_waits_answers`), and a worker's chat never does.
        let answer = try item(#"{"kind": "message", "ts": 12, "id": "GHI-3", "text": "Yes", "client": "founderizer-ios/1/x", "answer_to": 3}"#)
        let manager = try agent(last: 12, side: "owner", role: "manager")
        #expect(MobileStore.thinks(manager, items: [message, reply, answer], time: 1000, hubSays: false, answers: true))
        #expect(!MobileStore.thinks(manager, items: [message, reply, answer], time: 1000, hubSays: false))
        #expect(ChatPage.answersWait(manager, features: [ChatWaiting.answersFeature]))
        #expect(!ChatPage.answersWait(manager, features: ["chat_waits"]))
        #expect(!ChatPage.answersWait(try agent(last: 12, side: "owner"), features: [ChatWaiting.answersFeature]))
        // The row of his ask waits on his newest message, never on his answer, whose card stands in no turn.
        #expect(ChatPage.asksWaitOn([message, reply, answer], moving: true) == message.key)
        #expect(ChatPage.asksWaitOn([message, reply, answer], moving: false) == nil)
    }

    @Test("A reply that came while the chat was open fades in, and at the end it takes the waiting line's place")
    func aReplyTakesTheLinesPlace() throws {
        let asked = try item(#"{"kind": "message", "ts": 10, "id": "abc-1", "text": "Is it live?", "client": "founderizer-ios/1/x"}"#)
        let reply = try item(#"{"kind": "report", "ts": 11, "id": 5, "text": "Yes.", "in_reply_to": "abc-1"}"#)
        let rows = ChatPage.rows([asked, reply], needs: [], places: ChatRequestPlaces())
        guard rows.count == 2, case .run(let his) = rows[0], case .run(let theirs) = rows[1] else {
            Issue.record("not two runs"); return
        }
        let thinking = ChatWaiting(says: ChatWaiting.working, moving: true)
        // At the end, it takes the place of the line that showed over it: one cross-fade.
        #expect(ChatPage.arrival(of: theirs, isLast: true, arrived: [reply.id], line: thinking) == (true, thinking))
        // With no line over it, it only fades in.
        #expect(ChatPage.arrival(of: theirs, isLast: true, arrived: [reply.id], line: nil) == (true, nil))
        // Over a card that waits at the end, the line stood under the card: it fades in, and the line simply goes.
        #expect(ChatPage.arrival(of: theirs, isLast: false, arrived: [reply.id], line: thinking) == (true, nil))
        // What the chat opened with draws at once, and so does his own message.
        #expect(ChatPage.arrival(of: theirs, isLast: true, arrived: [], line: thinking) == (false, nil))
        #expect(ChatPage.arrival(of: his, isLast: false, arrived: [asked.id], line: thinking) == (false, nil))

        // One clock for both: the reply's words at 0 and the line's at 1 when it came, then easing out over 0.2 s.
        let came = Date(timeIntervalSince1970: 1000)
        func shown(after seconds: Double) -> Double {
            ArrivalFade<EmptyView>.shown(since: came, at: came.addingTimeInterval(seconds))
        }
        #expect(shown(after: -0.05) == 0 && shown(after: 0) == 0)
        #expect(abs(shown(after: 0.1) - 0.75) < 0.0001)
        #expect(shown(after: 0.2) == 1 && shown(after: 3) == 1)
    }

    @Test("A request card stands under the agent's reply of the turn in which it was raised, by the Mac's rule")
    func aRequestUnderTheReplyOfItsTurn() throws {
        let asked = try item(#"{"kind": "message", "ts": 10, "id": "ABC-1", "text": "Publish it?", "client": "founderizer-ios/1/x"}"#)
        let told = try item(#"{"kind": "report", "ts": 30, "id": 7, "text": "It is in Needs you.", "in_reply_to": "abc-1"}"#)
        let next = try item(#"{"kind": "message", "ts": 50, "id": "ABC-2", "text": "Done.", "client": "founderizer-ios/1/x"}"#)
        let need = try JSONDecoder().decode(OwnerNeed.self, from: Data(#"{"id": 3, "by": "manager", "title": "Publish now?", "why": "", "todo": "", "raised": 20, "answer": null, "answered": null}"#.utf8))
        let entries = ChatPage.entries([asked, told, next], agent: "manager")
        // The phone's ids are the Mac's, so the places name the phone's own items.
        #expect(entries.map(\.id) == [asked.id, told.id, next.id])
        // Raised in the agent's turn: under "It is in Needs you.", and his next message under the card.
        #expect(ChatRequestPlaces.inTime(needs: [need], in: entries, whole: false).after == [told.id: [3]])
        // The hub's own messages have an event, and the ones that this phone knows he wrote as an answer have none.
        guard case .message(let hubs) = entries[0],
              case .message(let his) = try #require(ChatPage.entries([asked], agent: "manager", written: ["abc-1"]).first)
        else { Issue.record("not messages"); return }
        #expect(hubs.event_id != 0 && his.event_id == 0)
    }

    @Test("A message names the request it answers, keeps it between launches, and an older hub's names none")
    func theRequestAnAnswerAnswers() throws {
        let answer = try item(#"{"kind": "message", "ts": 40, "id": "ABC-3", "text": "Correos", "client": "founderizer-ios/1/x", "answer_to": 3}"#)
        #expect(answer.answer_to == 3)
        #expect(try item(#"{"kind": "message", "ts": 40, "id": "ABC-4", "text": "Hi", "answer_to": null}"#).answer_to == nil)
        #expect(try item(#"{"kind": "message", "ts": 40, "id": "ABC-5", "text": "Hi"}"#).answer_to == nil)
        // The chat this phone keeps reads back with the same decoder.
        let kept = try JSONDecoder().decode(MobileChatItem.self, from: JSONSerialization.data(withJSONObject: answer.wire))
        #expect(kept == answer)
        // The Mac's rule reads it as an answer to that request.
        guard case .message(let message) = try #require(ChatPage.entries([answer], agent: "iris").first) else {
            Issue.record("not a message"); return
        }
        #expect(message.kind == "answer" && message.need_id == 3)
    }

    @Test("A card stands where it was raised: a pressed option is no second bubble, and written words are his message")
    func aCardWhereItWasRaised() throws {
        func need(_ id: Int, raised: Double, answered: Double?, options: Bool = false, chosen: Int? = nil) throws -> OwnerNeed {
            let answer = answered == nil ? "null" : #""Correos""#
            let time = answered.map { "\($0)" } ?? "null"
            let offered = options ? #"["Correos", "SEUR"]"# : "null"
            let pressed = chosen.map { "\($0)" } ?? "null"
            return try JSONDecoder().decode(OwnerNeed.self, from: Data(#"{"id": \#(id), "by": "iris", "title": "Which courier?", "why": "", "todo": "", "raised": \#(raised), "answer": \#(answer), "answered": \#(time), "options": \#(offered), "chosen": \#(pressed)}"#.utf8))
        }
        func placed(_ items: [MobileChatItem], _ needs: [OwnerNeed], written: Set<String> = []) -> [ChatPage.Row] {
            ChatPage.rows(items, needs: needs, places: ChatPage.places(of: needs, in: items, agent: "iris", written: written))
        }
        func rows(_ items: [MobileChatItem], _ needs: [OwnerNeed], written: Set<String> = []) -> [String] {
            placed(items, needs, written: written).map(\.id)
        }
        let asked = try item(#"{"kind": "message", "ts": 10, "id": "a", "text": "Ship it?", "client": "founderizer-ios/1/x"}"#)
        let told = try item(#"{"kind": "report", "ts": 30, "id": 7, "text": "It is in Needs you.", "in_reply_to": "a"}"#)
        let answer = try item(#"{"kind": "message", "ts": 40, "id": "b", "text": "Correos", "client": "founderizer-ios/1/x", "answer_to": 3}"#)
        let thanks = try item(#"{"kind": "report", "ts": 45, "id": 8, "text": "Booked with Correos."}"#)

        // He pressed an option: the card stands under the reply of its turn, his answer is not drawn, and the agent's
        // next line stands under the card, in a run of its own.
        #expect(try rows([asked, told, answer, thanks], [need(3, raised: 20, answered: 40, options: true, chosen: 0)])
                == ["run-message-a", "run-report-7", "request-3", "run-report-8"])
        // He wrote the words: the card stands in the same place, folded to its title, and his words are his message
        // under it, with the agent's line under them.
        let spoken = try placed([asked, told, answer, thanks], [need(3, raised: 20, answered: 40)])
        #expect(spoken.map(\.id) == ["run-message-a", "run-report-7", "request-3", "run-message-b", "run-report-8"])
        if case .request(_, _, let says) = spoken[2] { #expect(says) } else { Issue.record("no card") }

        // While the reading still has the request open (the open chat reads before the fleet): a pressed option's
        // words are no bubble over the card, and words that he wrote on this phone are his message at once, also when
        // they are an option's own words.
        #expect(try rows([asked, told, answer], [need(3, raised: 20, answered: nil, options: true)])
                == ["run-message-a", "run-report-7", "request-3"])
        #expect(try rows([asked, told, answer], [need(3, raised: 20, answered: nil, options: true)], written: ["b"])
                == ["run-message-a", "run-report-7", "request-3", "run-message-b"])

        // Told by no message: the card stands at its own time, between his messages around it, and not at the end.
        let after = try item(#"{"kind": "message", "ts": 50, "id": "c", "text": "And thanks.", "client": "founderizer-ios/1/x"}"#)
        let between = try placed([asked, after], [need(3, raised: 35, answered: nil)])
        #expect(between.map(\.id) == ["run-message-a", "request-3", "run-message-c"])
        // Twenty-five seconds after his message before it: no mark for the day or the hour over it, and it says its
        // own answer when it has one.
        if case .request(_, let stamp, let says) = between[1] { #expect(stamp == nil && !says) } else { Issue.record("no card") }
        // Answered in words: it folds where it stands, and his words stand at their time, in his run.
        #expect(try rows([asked, answer, after], [need(3, raised: 35, answered: 40)])
                == ["run-message-a", "request-3", "run-message-b"])

        // Nothing came after it: at the chat's end, with its own mark when it was raised a day after the row over it.
        let first = try item(#"{"kind": "report", "ts": 5, "id": 6, "text": "Starting."}"#)
        #expect(try rows([first, asked], [need(4, raised: 35, answered: nil)]) == ["run-report-6", "run-message-a", "request-4"])
        let late = try placed([asked], [need(6, raised: 172_810, answered: nil)])
        if case .request(_, let stamp, _) = try #require(late.last) { #expect(stamp == 172_810) } else { Issue.record("no card") }

        // The phone holds the newest pages only. A waiting request that is older than all of them stands over them,
        // with no item at all it stands alone, and an answered one that old is not drawn.
        #expect(try rows([told, after], [need(5, raised: 1, answered: nil)]) == ["request-5", "run-report-7", "run-message-c"])
        #expect(try rows([], [need(5, raised: 1, answered: nil)]) == ["request-5"])
        #expect(try rows([told, after], [need(5, raised: 1, answered: 20)]) == ["run-report-7", "run-message-c"])
        // An answered one that old, whose answer the phone holds: an option that he pressed shows as its folded card
        // where the answer is, and words that he wrote are his message there, with no card.
        let old = try item(#"{"kind": "message", "ts": 40, "id": "e", "text": "Correos", "client": "founderizer-ios/1/x", "answer_to": 5}"#)
        #expect(try rows([told, old, thanks], [need(5, raised: 1, answered: 40, options: true, chosen: 0)])
                == ["run-report-7", "request-5", "run-report-8"])
        #expect(try rows([told, old], [need(5, raised: 1, answered: 40, options: true, chosen: 0)])
                == ["run-report-7", "request-5"])
        #expect(try rows([told, old, thanks], [need(5, raised: 1, answered: 40)])
                == ["run-report-7", "run-message-e", "run-report-8"])
        // Two of them: in the order of his answers, whatever the order in which they were raised.
        let earlier = try item(#"{"kind": "message", "ts": 35, "id": "f", "text": "SEUR", "client": "founderizer-ios/1/x", "answer_to": 6}"#)
        #expect(try rows([told, earlier, old, thanks], [need(5, raised: 1, answered: 40, options: true, chosen: 0),
                                                       need(6, raised: 2, answered: 35, options: true, chosen: 1)])
                == ["run-report-7", "request-6", "request-5", "run-report-8"])
    }

    @Test("An answered card folds from the open card's height to the two lines', with no step where it begins or ends")
    func theFoldsHeight() {
        // The question's row: two lines of a wrapped question to the folded card's one, 22 points each.
        #expect(CrossFold.height(from: 44, to: 22, shown: 0) == 44)
        #expect(CrossFold.height(from: 44, to: 22, shown: 0.5) == 33)
        #expect(CrossFold.height(from: 44, to: 22, shown: 1) == 22)
        // The rows under it: the open rows to the answer's line, never past either end.
        #expect(CrossFold.height(from: 300, to: 20, shown: -0.1) == 300)
        #expect(CrossFold.height(from: 300, to: 20, shown: 1.1) == 20)
    }

    @Test("A correction of a message nothing read changes it where it stands, also in the chat kept between launches")
    func aCorrectionInPlace() throws {
        let typo = try item(#"{"kind": "message", "ts": 10, "id": "abc-1", "text": "Ship it tomorow.", "client": "founderizer-ios/1/x"}"#)
        let told = try item(#"{"kind": "report", "ts": 5, "id": 6, "text": "Ready when you are."}"#)
        // The hub's read gives the message with its new words and its read time, and a new reply: the phone keeps one
        // bubble with the new words, and the reply comes after it.
        let fixed = try item(#"{"kind": "message", "ts": 10, "id": "abc-1", "text": "Ship it tomorrow.", "client": "founderizer-ios/1/x", "read_at": 12, "edited": 11}"#)
        let reply = try item(#"{"kind": "report", "ts": 13, "id": 7, "text": "Done.", "in_reply_to": "abc-1"}"#)
        let merged = MobileStore.merge([told, typo], [fixed, reply])
        #expect(merged.items.map(\.text) == ["Ready when you are.", "Ship it tomorrow."])
        #expect(merged.items.last?.read_at == 12)
        #expect(merged.fresh == [reply])

        // His message that the agent has not read and no reply names is changed in place; once read or answered, not.
        #expect(MobileStore.editsInPlace("ABC-1", in: [told, typo]))
        #expect(!MobileStore.editsInPlace("abc-1", in: [told, fixed]))
        #expect(!MobileStore.editsInPlace("abc-1", in: [told, typo, reply]))

        // The receipt that says so changes the words where they stand, and the chat this phone keeps says them.
        let edited = MobileStore.edit([told, typo], message: "abc-1", to: "Ship it tomorrow.")
        #expect(edited.map(\.id) == [told.id, typo.id] && edited.last?.text == "Ship it tomorrow.")
        let kept = try JSONDecoder().decode(MobileChatItem.self, from: JSONSerialization.data(withJSONObject: edited[1].wire))
        #expect(kept.text == "Ship it tomorrow.")

        // A receipt that was lost: the hub holds the correction when the message carries its words, with no message of
        // its own.
        let correction = PendingRequest(hub: try MobileClient.address("http://127.0.0.1:9"), database: "gen-1",
                                        client: "founderizer-ios/1/x", recipient: "nova", replacesRequestID: "abc-1",
                                        text: "Ship it tomorrow.")
        #expect(MobileStore.held(correction, in: [told, fixed]) == (true, "abc-1"))
        #expect(MobileStore.held(correction, in: [told, typo]) == (false, nil))
        let own = try item(#"{"kind": "message", "ts": 20, "id": "\#(correction.requestID.uuidString.lowercased())", "text": "Ship it tomorrow.", "client": "founderizer-ios/1/x", "replaces": "abc-1"}"#)
        #expect(MobileStore.held(correction, in: [told, typo, own]) == (true, nil))
    }

    @Test("His message on its way is the item the hub's read will bring, by its id")
    func aMessageOnItsWay() throws {
        let request = PendingRequest(hub: try MobileClient.address("http://127.0.0.1:9"), database: "gen-1",
                                     client: "founderizer-ios/1/x", recipient: "nova", text: "Cut it to 400 words.")
        let waiting = MobileChatItem(waiting: request)
        // The hub keeps the request's number in lower case, as the phone sends it.
        let read = try item(#"{"kind": "message", "ts": 10, "id": "\#(request.requestID.uuidString.lowercased())", "text": "Cut it to 400 words.", "client": "founderizer-ios/1/x"}"#)
        #expect(waiting.id == read.id)
        #expect(waiting.kind == .message && waiting.client == read.client && waiting.text == read.text)
        // So the chat keeps his message where it stood when the read brings it, and his newest message waits.
        #expect(ChatPage.pending(in: [waiting]) == .waiting)
    }

    @Test("A link that is a paragraph of its own is found, and a link inside words is not")
    func aLinkOfItsOwn() {
        #expect(ReplyText.onlyLink(MessageBlock.inline("[Read the full announcement](https://example.com/a)"))
                == URL(string: "https://example.com/a"))
        #expect(ReplyText.onlyLink(MessageBlock.inline("See [the page](https://example.com/a) first.")) == nil)
        #expect(ReplyText.onlyLink(MessageBlock.inline("No link here.")) == nil)
    }

    /// **A value's chip copies exactly what the agent put in inline code, and the card's words gain and lose no
    /// character** (`CardValueText.pieces`; the owner's "Yes, as drawn" of 21 November 2026 to a chip with a copy icon
    /// on each value): the room of the chip and its icon are kerns. Code in a link and code of spaces only are no
    /// value. The bugs that this stops: a press copies a key with its last character cut, or with a space that the
    /// chip's room added, and what he pastes does not work.
    @Test("A value's chip copies the inline code exactly, and the card's words keep every character")
    func aValueChipCopiesTheCodeExactly() {
        let text = "`ssh-ed25519 AAAAC3Nza key@example` is the key. Open [the `page`](https://example.com/a), "
            + "skip `   ` and run `fleet doctor --fix`"
        let words = MessageBlock.inline(text)
        let pieces = CardValueText.pieces(words, size: 15)
        #expect(pieces.map { String($0.words.characters) }.joined() == String(words.characters))
        let values = pieces.compactMap(\.value)
        #expect(values.map(\.words) == ["ssh-ed25519 AAAAC3Nza key@example", "fleet doctor --fix"])
        #expect(values.map(\.words) == CardValues.values(in: words, names: nil))
        #expect(values.map(\.index) == [0, 1])
    }

    @Test("Send's arrow is white where white reads 3:1, and near-black on the lighter colours, as on the Mac")
    func theArrowOnSend() {
        // White where it reads 3:1 (blue, orchid), near-black on the lighter colours (lime), as on the Mac.
        #expect(ChatPage.arrow(on: Color(red: 0.08, green: 0.44, blue: 0.72)) == .white)
        #expect(ChatPage.arrow(on: Color(red: 0.68, green: 0.16, blue: 0.78)) == .white)
        #expect(ChatPage.arrow(on: Color(red: 0.50, green: 0.74, blue: 0.17)) == Brand.ink)
    }

    @Test("A status dot keeps its place on its mark's own shape at every text size")
    func aDotOnItsMark() {
        // At the ordinary size its centre stands 4 points in from the mark's corner, whatever the shape.
        for kind in GlyphKind.allCases {
            #expect(AgentAvatar.badgeCentre(kind: kind, base: 40, size: 40) == 36)
            #expect(AgentAvatar.badgeCentre(kind: kind, base: 20, size: 20) == 16)
        }
        // A round mark's edge stands at 46 % of the side from its centre. The dot touches it at the ordinary size, and
        // still at the largest text size, where the mark is 60 points: it stood 5.5 points off there.
        func gap(_ size: CGFloat) -> CGFloat {
            (AgentAvatar.badgeCentre(kind: .circle, base: 40, size: size) - size / 2) * 2.squareRoot() - 0.46 * size - 4
        }
        #expect(abs(gap(40)) < 0.5)
        #expect(abs(gap(60) - gap(40)) < 0.05)
    }

    /// The owner's "B, go ahead" of 24 November 2026 (owner feature `message_hands`): an AI session's message is no
    /// filled bubble of his. The bugs: the phone does not read the hand, or loses it in the chat that it keeps between
    /// launches, so an AI session's words look like his again after a launch; the mark on his own words or on a report;
    /// the outline on a hub that gives no hands; and a mark that VoiceOver does not name.
    @Test("Only a chat app or an AI session gets a mark on his bubble's corner: his own apps have none")
    func theMarkOfAChatApp() throws {
        #expect(ChatAppMark.app(of: "fleet-channels/1/discord-studio") == "discord")
        #expect(ChatAppMark.app(of: "fleet-channels/1/whatsapp-main") == "whatsapp")
        #expect(ChatAppMark.app(of: "founderizer-ios/1/abc") == nil)
        #expect(ChatAppMark.app(of: "founderizer-swift/1/abc") == nil)
        #expect(ChatAppMark.app(of: nil) == nil)

        let hands: Set<String> = ["direct_chat", OwnerHand.feature]
        let ai = try item(#"{"kind": "message", "ts": 1, "id": "m-1", "text": "Draft it", "client": "example-tool/1/x", "hand": "tool", "runtime": "claude-code"}"#)
        #expect(ChatPage.look(of: ai, features: hands) == OwnerHand.Look(outlined: true, mark: .claude))
        #expect(ChatAppMark.app(of: ai.client) == nil)
        let phone = try item(#"{"kind": "message", "ts": 2, "id": "m-2", "text": "Hi", "client": "founderizer-ios/1/abc", "hand": "device", "runtime": null}"#)
        #expect(ChatPage.look(of: phone, features: hands) == .his)
        let old = try item(#"{"kind": "message", "ts": 3, "id": "m-3", "text": "Hi", "client": "founderizer-ios/1/abc"}"#)
        #expect(old.hand == nil && ChatPage.look(of: old, features: hands) == .his)
        let report = try item(#"{"kind": "report", "ts": 4, "id": 7, "text": "Done", "hand": "tool", "runtime": "codex"}"#)
        #expect(ChatPage.look(of: report, features: hands) == .his)
        #expect(ChatPage.look(of: ai, features: ["direct_chat"]) == .his)
        // the chat that the phone keeps reads back with its hand
        let kept = try JSONDecoder().decode(MobileChatItem.self, from: JSONSerialization.data(withJSONObject: ai.wire))
        #expect(kept == ai && kept.hand == "tool" && kept.runtime == "claude-code")
        // VoiceOver reads the Mac's hover words
        #expect(AISessionMark.words == "Sent by your AI session")
    }

    /// The list of chats writes "You: " before his own last words only (owner feature `message_hands`). The bugs: an AI
    /// session's, a connected app's or a later hand's words read as his there, or his own lose the "You: ", or a hub
    /// without the feature changes the row.
    @Test("The list of chats says \"You: \" before his own words only")
    func theChatsRowNamesOnlyHisOwnWords() throws {
        func last(_ fields: String) throws -> MobilePreview {
            try JSONDecoder().decode(MobilePreview.self,
                                     from: Data((#"{"ts": 1, "side": "owner", "preview": "Draft **it**""# + fields + "}").utf8))
        }
        let hands: Set<String> = [OwnerHand.feature]
        #expect(ChatsPage.lastLine(try last(#", "hand": "tool", "runtime": "claude-code""#), features: hands) == "Draft it")
        for hand in ["other", "connected", "job"] {
            #expect(ChatsPage.lastLine(try last(#", "hand": "\#(hand)", "runtime": null"#), features: hands) == "Draft it")
        }
        for fields in [#", "hand": "device", "runtime": null"#, #", "hand": null"#, ""] {
            #expect(ChatsPage.lastLine(try last(fields), features: hands) == "You: Draft it", "\(fields)")
        }
        #expect(ChatsPage.lastLine(try last(#", "hand": "tool""#), features: []) == "You: Draft it")
        let reply = try JSONDecoder().decode(MobilePreview.self, from: Data(#"{"ts": 1, "side": "agent", "preview": "Done"}"#.utf8))
        #expect(ChatsPage.lastLine(reply, features: hands) == "Done")
    }

    @Test("A mark's path data reads into its own box, arcs included")
    func aMarksPath() {
        let square = BrandMarkShape.read("M2 2h20v20H2Z").boundingRect
        #expect(abs(square.minX - 2) < 0.001 && abs(square.maxX - 22) < 0.001 && abs(square.maxY - 22) < 0.001)
        // A half circle over the box's middle: the arc reaches the top of its 12-point radius.
        let arc = BrandMarkShape.read("M0 12a12 12 0 0124 0").boundingRect
        #expect(abs(arc.minX) < 0.01 && abs(arc.maxX - 24) < 0.01)
        #expect(abs(arc.minY) < 0.05 && abs(arc.maxY - 12) < 0.01)
    }

    @Test("Each provider has its real logo on the phone")
    func providerLogos() {
        for runtime in ["claude", "codex", "grok"] { #expect(ProviderLogo.image(runtime) != nil) }
        // each program that marks a bubble has its glyph: one without would show an empty tile (`AISessionMark`)
        for runtime in OwnerHand.Runtime.allCases { #expect(ProviderLogo.glyph(runtime.rawValue) != nil, "\(runtime)") }
    }

    /// The owner, 14 November 2026: "why does the preview not show the card if the card is the latest element on the
    /// chat?", his yes to its title in orange on the Mac, and "Yes, iPhone too".
    @Test("A waiting card that is the newest thing in a chat is its row's line, as on the Mac")
    func aWaitingCardIsTheRowsLine() throws {
        func need(_ id: Int, raised: Double, by agent: String = "iris", answered: Double? = nil) throws -> OwnerNeed {
            let answer = answered == nil ? "null" : #""Yes""#
            let time = answered.map { "\($0)" } ?? "null"
            return try JSONDecoder().decode(OwnerNeed.self, from: Data(#"{"id": \#(id), "by": "\#(agent)", "title": "Request \#(id)", "why": "", "todo": "", "raised": \#(raised), "answer": \#(answer), "answered": \#(time)}"#.utf8))
        }
        func last(_ ts: Double, side: String = "agent") throws -> MobilePreview {
            try JSONDecoder().decode(MobilePreview.self, from: Data(#"{"ts": \#(ts), "side": "\#(side)", "preview": "Synthetic"}"#.utf8))
        }
        let asked = try item(#"{"kind": "message", "ts": 10, "id": "a", "text": "Ship it?", "client": "founderizer-ios/1/x"}"#)
        let told = try item(#"{"kind": "report", "ts": 30, "id": 7, "text": "It is in Needs you.", "in_reply_to": "a"}"#)
        let later = try item(#"{"kind": "report", "ts": 50, "id": 8, "text": "Something else."}"#)
        let open = [try need(3, raised: 20), try need(4, raised: 5, by: "vps")]

        // A chat that the phone holds: the card under the reply of its turn is the newest thing, and a later line is not.
        #expect(ChatsPage.waitingRequest(agent: "iris", last: try last(30), items: [asked, told], open: open, answered: [])?.id == 3)
        #expect(ChatsPage.waitingRequest(agent: "iris", last: try last(50), items: [asked, told, later], open: open, answered: []) == nil)
        // An answered request, or another agent's, is no line of this row.
        #expect(ChatsPage.waitingRequest(agent: "iris", last: try last(30), items: [asked, told], open: [],
                                         answered: [try need(3, raised: 20, answered: 40)]) == nil)
        #expect(ChatsPage.waitingRequest(agent: "vps", last: nil, items: nil, open: open, answered: [])?.id == 4)
        // A chat that it has not read, or whose newest line came since: the request raised after its last line.
        #expect(ChatsPage.waitingRequest(agent: "iris", last: try last(15, side: "owner"), items: nil, open: open, answered: [])?.id == 3)
        #expect(ChatsPage.waitingRequest(agent: "iris", last: try last(30), items: nil, open: open, answered: []) == nil)
        #expect(ChatsPage.waitingRequest(agent: "iris", last: try last(50), items: [asked], open: open, answered: []) == nil)
    }
}

/// What he asked for in a chat is one row there, on the phone as on the Mac (the owner, 16 November 2026: "this tasks
/// should also show inside the conversation!!", and "the Mac and the iPhone"): FleetCore's rules, read from the phone's
/// heads and chat items. Explicit test data only. On the main actor, as the chat's own functions are.
@MainActor
struct MobileAskTests {
    private func item(_ json: String) throws -> MobileChatItem {
        try JSONDecoder().decode(MobileChatItem.self, from: Data(json.utf8))
    }

    /// The bug that this catches (hub 1.258, `ended_asks`): the phone reads the ended heads of a chat from a time after
    /// a line that it shows, and the row of what he asked for under that line goes; or it reads them at every refresh;
    /// or it never reads them again after their mark moved.
    @Test("the ended heads of a chat are read from its oldest line, and again only for a new mark or an older line")
    func endedReadOfAChat() throws {
        let lines = [try item(#"{"kind": "report", "ts": 20, "id": 5, "text": "Done."}"#),
                     try item(#"{"kind": "message", "ts": 12.5, "id": "ABC-1", "text": "Do it", "client": "x"}"#)]
        let read = MobileStore.endedRead([:], chat: "studio", lines: lines, mark: "m1", scoped: true)
        #expect(read?.place == "studio" && read?.from == 12.5)
        #expect(MobileStore.endedRead([:], chat: "studio", lines: nil, mark: "m1", scoped: true) == nil, "no line yet")
        let held = ["studio": MobileStore.EndedAsks(mark: "m1", from: 12.5, heads: [], names: [:])]
        #expect(MobileStore.endedRead(held, chat: "studio", lines: lines, mark: "m1", scoped: true) == nil)
        #expect(MobileStore.endedRead(held, chat: "studio", lines: Array(lines.prefix(1)), mark: "m1", scoped: true) == nil,
                "a later oldest line is covered")
        #expect(MobileStore.endedRead(held, chat: "studio", lines: lines, mark: "m2", scoped: true)?.from == 12.5)
        let older = lines + [try item(#"{"kind": "message", "ts": 3, "id": "ABC-0", "text": "First", "client": "x"}"#)]
        #expect(MobileStore.endedRead(held, chat: "studio", lines: older, mark: "m1", scoped: true)?.from == 3)
        #expect(MobileStore.endedRead(held, chat: "vps", lines: lines, mark: "m1", scoped: true)?.place == "vps")
        // A hub before it: every head, once for each mark.
        let whole = MobileStore.endedRead(held, chat: "studio", lines: lines, mark: "m1", scoped: false)
        #expect(whole?.place == "" && whole?.from == nil)
        let wholeHeld = ["": MobileStore.EndedAsks(mark: "m1", from: nil, heads: [], names: [:])]
        #expect(MobileStore.endedRead(wholeHeld, chat: "studio", lines: lines, mark: "m1", scoped: false) == nil)
    }

    private func head(_ fields: [String: Any]) throws -> MobileTaskHead {
        var row: [String: Any] = ["id": 7, "title": "Read the clock", "state": "working", "owner": "vps",
                                  "requester": "manager", "goal": "", "needs": "none", "attempt": 1, "created": 10.0,
                                  "started": 12.0, "last_activity": 30.0]
        for (key, value) in fields { row[key] = value }
        return try JSONDecoder().decode(MobileTaskHead.self, from: JSONSerialization.data(withJSONObject: row))
    }

    @Test("A head carries its ask, its parent and its park, and reads as FleetCore's task")
    func aHeadIsFleetCoresTask() throws {
        let task = try #require(try head(["ask": "abc-1", "parent": 3, "parked_until": 900.0, "works": false]).fleetTask)
        #expect(task.ask == "abc-1" && task.parent == 3 && task.parked_until == 900 && task.works == false)
        // A hub from before them sends none.
        let older = try #require(try head([:]).fleetTask)
        #expect(older.ask == nil && older.parent == nil)
    }

    @Test("The row of what he asked stands under the reply of its turn, with the name the read gives it")
    func aRowUnderTheReply() throws {
        let asked = try item(#"{"kind": "message", "ts": 10, "id": "abc-1", "text": "What time is it in UTC?", "client": "founderizer-ios/1/x"}"#)
        let reply = try item(#"{"kind": "report", "ts": 11, "id": 5, "text": "I opened a task for it.", "in_reply_to": "abc-1"}"#)
        let later = try item(#"{"kind": "message", "ts": 20, "id": "abc-2", "text": "Thanks", "client": "founderizer-ios/1/x"}"#)
        let lines = [asked, reply, later]
        let entries = ChatPage.entries(lines, agent: "vps", names: ["abc-1": "Show the UTC time"])
        let task = try #require(try head(["ask": "abc-1", "works": true, "doing": "Reads the clock"]).fleetTask)
        let reading = HubState(phoneTime: 40, db: "gen-1", agents: [FleetAgent(phoneName: "vps", role: "worker",
                               runtime: "claude", limit: nil)], tasks: [task], needs: [],
                               messages: entries.compactMap { if case .message(let message) = $0 { message } else { nil } },
                               holds: [], outcomes: [])
        let asks = ChatPage.asks(in: entries, places: ChatRequestPlaces(), agent: "vps", reading: reading)
        let rows = ChatPage.rows(lines, needs: [], places: ChatRequestPlaces(), asks: asks)
        #expect(rows.map(\.id) == ["run-message-abc-1", "run-report-5", "ask-abc-1", "run-message-abc-2"])
        guard case .ask(let row) = rows[2] else { Issue.record("no row of the ask"); return }
        #expect(row.title == "Show the UTC time" && row.line == "Reads the clock" && row.moves && row.task == 7)
        // While the chat waits for the reply to his message, the row waits too, and comes with the reply.
        let alone = ChatPage.asks(in: Array(entries.prefix(1)), places: ChatRequestPlaces(), agent: "vps",
                                  reading: reading, waitsOn: "abc-1")
        #expect(alone.isEmpty)
    }

    @Test("The Fleet Manager's words that took the turn of his message stand over its row, and the phone keeps the turn")
    func theTurnPlacesTheRow() throws {
        let asked = try item(#"{"kind": "message", "ts": 10, "id": "abc-1", "text": "Move the images.", "client": "founderizer-ios/1/x"}"#)
        let line = try item(#"{"kind": "report", "ts": 11, "id": 4, "text": "Standing item ended."}"#)
        let reply = try item(#"{"kind": "report", "ts": 12, "id": 5, "text": "The developer has it.", "turn": "abc-1"}"#)
        #expect(reply.turn == "abc-1" && line.turn == nil)
        // Kept between launches with it.
        let kept = try JSONDecoder().decode(MobileChatItem.self, from: JSONSerialization.data(withJSONObject: reply.wire))
        #expect(kept.turn == "abc-1")
        let lines = [asked, line, reply]
        let entries = ChatPage.entries(lines, agent: "manager", names: ["abc-1": "Move the images"])
        let task = try #require(try head(["ask": "abc-1"]).fleetTask)
        let reading = HubState(phoneTime: 40, db: "gen-1", agents: [], tasks: [task], needs: [],
                               messages: entries.compactMap { if case .message(let message) = $0 { message } else { nil } },
                               holds: [], outcomes: [])
        let rows = ChatPage.rows(lines, needs: [], places: ChatRequestPlaces(),
                                 asks: ChatPage.asks(in: entries, places: ChatRequestPlaces(), agent: "manager", reading: reading))
        #expect(rows.map(\.id) == ["run-message-abc-1", "run-report-4", "ask-abc-1"])
    }
}
