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
    }

    @Test("What holds a task is its word: a hold, the agent's usage limit, a stall")
    func whatHoldsATask() throws {
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
        // An old reading says so in words, with the look it read (fix round 3, COPY): its mark keeps its colour and rests.
        #expect(AgentState.old(.working).words == "Last reading" && AgentState.attention("Stalled").words == "Stalled")
        #expect(AgentState.old(.working).hasDot && !AgentState.old(.online).hasDot)
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
        let refused = MobileError.refusal(status: 409, auth: nil, message: "atlas is in setup")
        #expect(refused.notSentWords == "Not sent: Atlas is in setup.")
        // A refusal of this phone's key keeps the words that say what to do.
        let key = MobileError.refusal(status: 403, auth: "device_key_mismatch", message: "")
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
        // A message that the agent read in a turn that has ended with no reply is not worked on (hub 1.110): the
        // hub says when he sent the newest message that the agent's last ended turn had read.
        #expect(ChatPage.pending(in: [message], turnEndedAfter: 10) == .turnOver)
        #expect(ChatPage.pending(in: [message], turnEndedAfter: 9.5) == .waiting)
        #expect(ChatPage.pending(in: [message, reply, newer], turnEndedAfter: 10) == .waiting)
        #expect(ChatPage.pending(in: [message, reply, newer], turnEndedAfter: 13) == .turnOver)
        // A reply still comes first.
        #expect(ChatPage.pending(in: [message, reply], turnEndedAfter: 10) == .none)
        #expect(ChatPage.pending(in: [message, unlinked], turnEndedAfter: 10) == .spokenSince)
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

    @Test("A request card stands under the agent's reply that told him about it, by the Mac's rule")
    func aRequestUnderTheReplyThatToldHim() throws {
        let asked = try item(#"{"kind": "message", "ts": 10, "id": "ABC-1", "text": "Publish it?", "client": "founderizer-ios/1/x"}"#)
        let told = try item(#"{"kind": "report", "ts": 30, "id": 7, "text": "It is in Needs you."}"#)
        let next = try item(#"{"kind": "message", "ts": 50, "id": "ABC-2", "text": "Done.", "client": "founderizer-ios/1/x"}"#)
        let need = try JSONDecoder().decode(OwnerNeed.self, from: Data(#"{"id": 3, "by": "manager", "title": "Publish now?", "why": "", "todo": "", "raised": 20, "answer": null, "answered": null}"#.utf8))
        let entries = ChatPage.entries([asked, told, next], agent: "manager")
        // The phone's ids are the Mac's, so the places name the phone's own items.
        #expect(entries.map(\.id) == [asked.id, told.id, next.id])
        // Raised in the agent's turn: under "It is in Needs you.", and his next message under the card.
        #expect(ChatRequestPlaces.of(needs: [need], in: entries, whole: false).after == [told.id: [3]])
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

    @Test("An answered card folds where it stood, and his answer is no second bubble")
    func anAnsweredCard() throws {
        func need(_ id: Int, raised: Double, answered: Double?) throws -> OwnerNeed {
            let answer = answered == nil ? "null" : #""Correos""#
            let time = answered.map { "\($0)" } ?? "null"
            return try JSONDecoder().decode(OwnerNeed.self, from: Data(#"{"id": \#(id), "by": "iris", "title": "Which courier?", "why": "", "todo": "", "raised": \#(raised), "answer": \#(answer), "answered": \#(time)}"#.utf8))
        }
        func rows(_ items: [MobileChatItem], _ needs: [OwnerNeed]) -> [String] {
            ChatPage.rows(items, needs: needs, places: ChatPage.places(of: needs, in: items, agent: "iris")).map(\.id)
        }
        let asked = try item(#"{"kind": "message", "ts": 10, "id": "a", "text": "Ship it?", "client": "founderizer-ios/1/x"}"#)
        let told = try item(#"{"kind": "report", "ts": 30, "id": 7, "text": "It is in Needs you."}"#)
        let answer = try item(#"{"kind": "message", "ts": 40, "id": "b", "text": "Correos", "client": "founderizer-ios/1/x", "answer_to": 3}"#)
        let thanks = try item(#"{"kind": "report", "ts": 45, "id": 8, "text": "Booked with Correos."}"#)

        // Told by a message: the card stands under it, his answer is not drawn, and the agent's next line stands under
        // the card, in a run of its own.
        #expect(try rows([asked, told, answer, thanks], [need(3, raised: 20, answered: 40)])
                == ["run-message-a", "run-report-7", "request-3", "run-report-8"])
        // While it waits, the same place, and his answer, which the chat holds before the fleet's read says it, once.
        #expect(try rows([asked, told, answer], [need(3, raised: 20, answered: nil)])
                == ["run-message-a", "run-report-7", "request-3"])

        // Told by no message: the card takes his answer's place, between his messages around it.
        let after = try item(#"{"kind": "message", "ts": 50, "id": "c", "text": "And thanks.", "client": "founderizer-ios/1/x"}"#)
        let inPlace = try need(3, raised: 35, answered: 40)
        let placed = ChatPage.rows([asked, answer, after], needs: [inPlace],
                                   places: ChatPage.places(of: [inPlace], in: [asked, answer, after], agent: "iris"))
        #expect(placed.map(\.id) == ["run-message-a", "request-3", "run-message-c"])
        // Thirty seconds after his message before it: no mark for the day or the hour over it.
        if case .request(_, let stamp) = placed[1] { #expect(stamp == nil) } else { Issue.record("no card") }
        // Told by no message and still waiting at the end, with his answer in the chat already (the open chat reads
        // before the fleet): the answer is no bubble over the card. The fleet's read puts the card in its place.
        let waiting = try need(3, raised: 35, answered: nil)
        let early = ChatPage.rows([asked, answer], needs: [waiting],
                                  places: ChatPage.places(of: [waiting], in: [asked, answer], agent: "iris"))
        #expect(early.map(\.id) == ["run-message-a", "request-3"])
        if case .run(let run) = early[0] { #expect(run.items.map(\.id) == [asked.id]) } else { Issue.record("no run") }
        #expect(try rows([asked, answer], [need(3, raised: 35, answered: 40)]) == ["run-message-a", "request-3"])

        // Answered after everything the chat holds, and told by no message (his message stands before its raise): at
        // the end, where his answer comes with the chat's next read, as it stood while it waited.
        let first = try item(#"{"kind": "report", "ts": 5, "id": 6, "text": "Starting."}"#)
        #expect(try rows([first, asked], [need(4, raised: 35, answered: 60)]) == ["run-report-6", "run-message-a", "request-4"])
        #expect(try rows([first, asked], [need(4, raised: 35, answered: nil)]) == ["run-report-6", "run-message-a", "request-4"])
        // Answered before the newest item the chat holds, and raised before all of them: not drawn, as on the Mac.
        #expect(try rows([told, after], [need(5, raised: 1, answered: 20)]) == ["run-report-7", "run-message-c"])
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

    @Test("Only a chat app gets a mark on his bubble's corner: his own apps have none")
    func theMarkOfAChatApp() {
        #expect(ChatAppMark.app(of: "fleet-channels/1/discord-studio") == "discord")
        #expect(ChatAppMark.app(of: "fleet-channels/1/whatsapp-main") == "whatsapp")
        #expect(ChatAppMark.app(of: "founderizer-ios/1/abc") == nil)
        #expect(ChatAppMark.app(of: "founderizer-swift/1/abc") == nil)
        #expect(ChatAppMark.app(of: nil) == nil)
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
    }
}
