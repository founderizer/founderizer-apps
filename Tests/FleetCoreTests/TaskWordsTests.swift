import Foundation
import Testing
@testable import FleetCore

/// **One task, one state word, on every screen of both apps** (T-12; fix round 2 of 29 October 2026). A finished task
/// read "Delivered" in an agent's panel where its thread said "Checked"; the phone said "Working" for a paused, a limited
/// and a stalled task, and "Waiting on juno" on its list where its page said "Queued"; "Waiting for an answer" named
/// nobody in four words.
struct TaskWordsTests {
    @Test func theOwnersHoldComesFirst() {
        #expect(TaskWords.state("working", accepted: nil, requester: "manager",
                                hold: .init(kind: "pause", state: "paused")) == "Paused")
        #expect(TaskWords.state("working", accepted: nil, requester: "manager",
                                hold: .init(kind: "stop", state: "stopped")) == "Stopped")
        #expect(TaskWords.state("working", accepted: nil, requester: "manager",
                                hold: .init(kind: "stop", state: "requested")) == "Stopping…")
        #expect(TaskWords.state("working", accepted: nil, requester: "manager",
                                hold: .init(kind: "stop", state: "not_confirmed")) == "Stop not confirmed")
        // A hold that was released says nothing any more.
        #expect(TaskWords.state("working", accepted: nil, requester: "manager",
                                hold: .init(kind: "pause", state: "released")) == "Working")
    }

    @Test func aTaskThatIsNotOverSaysWhatHoldsIt() {
        #expect(TaskWords.state("working", accepted: nil, requester: "manager", limited: true) == "Usage limit")
        #expect(TaskWords.state("working", accepted: nil, requester: "manager", stalled: true) == "Stalled")
        #expect(TaskWords.state("working", accepted: nil, requester: "manager", reconnecting: true) == "Reconnecting")
        // A task that is over is its result, whatever holds its agent now.
        #expect(TaskWords.state("completed", accepted: 1, requester: "manager", stalled: true, limited: true) == "Checked")
        #expect(TaskWords.state("failed", accepted: nil, requester: "manager", limited: true) == "Failed")
    }

    /// A result its requester's check refused is "Not accepted", as the Result check row says ("Not accepted by
    /// Manager"); only an unchecked result awaits its check.
    @Test func aRefusedResultIsNotAccepted() {
        #expect(TaskWords.state("completed", accepted: 0, requester: "manager") == "Not accepted")
        #expect(TaskWords.state("completed", accepted: nil, requester: "manager") == "Awaiting check")
        #expect(TaskWords.state("completed", accepted: 1, requester: "manager") == "Checked")
    }

    /// Who it waits for, in three words: its requester, "you" when that is the owner.
    @Test func aTaskThatWaitsNamesWhoItWaitsFor() {
        #expect(TaskWords.state("input-required", accepted: nil, requester: "manager") == "Waiting for Manager")
        #expect(TaskWords.state("input-required", accepted: nil, requester: "owner") == "Waiting for you")
        // The hub's own references are its requester's to answer, and never words for the owner.
        #expect(TaskWords.state("input-required", accepted: nil, requester: "atlas", waitingOn: "Q-12") == "Waiting for Atlas")
        #expect(TaskWords.state("working", accepted: nil, requester: "manager", waitingOn: "P-3") == "Waiting for Manager")
        #expect(TaskWords.state("working", accepted: nil, requester: "manager", waitingOn: "CM-7") == "Waiting for Manager")
        #expect(TaskWords.state("working", accepted: nil, requester: "owner", waitingOn: "its screen") == "Waiting for you")
        // A name is that agent, as the apps write it.
        #expect(TaskWords.state("submitted", accepted: nil, requester: "manager", waitingOn: "juno") == "Waiting on Juno")
        #expect(TaskWords.waiter(of: "juno") == "Juno")
        #expect(TaskWords.waiter(of: "Q-12") == nil)
        // A task that is over waits on nothing.
        #expect(TaskWords.state("completed", accepted: nil, requester: "manager", waitingOn: "juno") == "Awaiting check")
    }

    @Test func itsOwnStateInTheAppsWords() {
        #expect(TaskWords.state("working", accepted: nil, requester: "manager") == "Working")
        #expect(TaskWords.state("submitted", accepted: nil, requester: "manager") == "Queued")
        #expect(TaskWords.state("auth-required", accepted: nil, requester: "manager") == "Sign-in needed")
        #expect(TaskWords.state("completed", accepted: nil, requester: "manager") == "Awaiting check")
        #expect(TaskWords.state("completed", accepted: 1, requester: "manager") == "Checked")
        #expect(TaskWords.state("canceled", accepted: nil, requester: "manager") == "Canceled")
        #expect(TaskWords.state("rejected", accepted: nil, requester: "manager") == "Rejected")
    }

    /// The Mac's task reads its hold and its agent's limit from the fleet's state, and gives the same word.
    @Test func aTaskReadsItsHoldFromTheFleet() throws {
        let task = try JSONDecoder().decode(FleetTask.self, from: Data("""
        {"id": 437, "title": "Paused work", "details": "", "done_when": "", "needs": "", "goal": "", "owner": "remy",
         "requester": "manager", "state": "working", "created": 1, "attempt": 1, "restarts": 0, "nudge_level": 0,
         "stop_sent": 0}
        """.utf8))
        let hold = try JSONDecoder().decode(TaskHold.self, from: Data("""
        {"id": 1, "task": 437, "kind": "pause", "state": "paused", "attempt": 1}
        """.utf8))
        let other = try JSONDecoder().decode(TaskHold.self, from: Data("""
        {"id": 2, "task": 9, "kind": "stop", "state": "stopped", "attempt": 1}
        """.utf8))
        #expect(task.stateWord(holds: [other, hold], limited: true) == "Paused")
        #expect(task.stateWord(holds: [other], limited: true) == "Usage limit")
        #expect(task.stateWord(holds: [], limited: false) == "Working")
    }

    /// **A task in state working is work only while its session works on it** (hub 1.147; the owner, 13 November 2026:
    /// "the agent replied but the sidebar is still animating!"): a task that its agent parked until a time, and one whose
    /// last turn ended with nothing of it running, keep their mark and their word, with no motion and no green of work.
    @Test func aTaskThatWaitsBetweenTurnsIsNoWorkNow() throws {
        func task(_ more: String = "") throws -> FleetTask {
            try JSONDecoder().decode(FleetTask.self, from: Data("""
            {"id": 5, "title": "T", "details": "", "done_when": "", "needs": "", "goal": "", "owner": "remy",
             "requester": "manager", "state": "working", "created": 1, "attempt": 1, "restarts": 0,
             "nudge_level": 0, "stop_sent": 0\(more)}
            """.utf8))
        }
        // Nothing is known of its turns (a session that starts, an older hub): its state says it, as before.
        #expect(try task().mark(holds: []) == ("circle.dotted", "Working", false, true))
        #expect(try task().tint(holds: []) == .work)
        // A turn runs, or a command of it runs in the background.
        #expect(try task(#", "works": true"#).mark(holds: []).inWork)
        // Its last turn ended and nothing of it runs.
        #expect(try task(#", "works": false"#).mark(holds: []) == ("circle.dotted", "Working", false, false))
        #expect(try task(#", "works": false"#).tint(holds: []) == .quiet)
        // Parked on a reminder, also by a hub that says nothing of its turns.
        #expect(try !task(#", "parked_until": 9000"#).mark(holds: []).inWork)
        #expect(try !task(#", "parked_until": 9000, "works": true"#).mark(holds: []).inWork)
    }

    /// **A task's mark comes from its state word's order** (review B5), so the search card, the Tasks board and the
    /// thread agree: a hold first, a result for a task that is over, a usage limit as the board's hourglass (never the
    /// green of work), and a working task that waits on something as the hourglass too.
    @Test func aTasksMarkFollowsTheOrderOfItsWord() throws {
        func task(_ state: String, accepted: Int? = nil, waitingOn: String? = nil, nudge: Int = 0) throws -> FleetTask {
            let checked = accepted.map { String($0) } ?? "null"
            let waits = waitingOn.map { "\"\($0)\"" } ?? "null"
            return try JSONDecoder().decode(FleetTask.self, from: Data("""
            {"id": 5, "title": "T", "details": "", "done_when": "", "needs": "", "goal": "", "owner": "remy",
             "requester": "manager", "state": "\(state)", "created": 1, "attempt": 1, "restarts": 0,
             "nudge_level": \(nudge), "stop_sent": 0, "accepted": \(checked), "waiting_on": \(waits)}
            """.utf8))
        }
        let stop = try JSONDecoder().decode(TaskHold.self, from: Data("""
        {"id": 1, "task": 5, "kind": "stop", "state": "requested", "attempt": 1}
        """.utf8))
        let working = try task("working")
        #expect(working.mark(holds: []) == ("circle.dotted", "Working", false, true))
        // A usage limit is no work: the board's hourglass, and the agent's word.
        #expect(working.mark(holds: [], limited: true) == ("hourglass", "Usage limit", true, false))
        // The owner's hold comes first, also on a task that is over and on one that is limited.
        #expect(working.mark(holds: [stop], limited: true) == ("pause.circle", "Stopping…", false, false))
        #expect(try task("canceled").mark(holds: [stop]) == ("pause.circle", "Stopping…", false, false))
        // A result in the board's look (fix round 3, item 21): Checked the green filled check; the board's red badges —
        // not accepted, failed, rejected, canceled — the red filled exclamation; a muted one while it waits for its check.
        #expect(try task("completed", accepted: 1).mark(holds: []) == ("checkmark.circle.fill", "Checked", false, false))
        #expect(try task("completed", accepted: 0).mark(holds: []) == ("exclamationmark.circle.fill", "Not accepted", true, false))
        #expect(try task("failed").mark(holds: []) == ("exclamationmark.circle.fill", "Failed", true, false))
        #expect(try task("canceled").mark(holds: []) == ("exclamationmark.circle.fill", "Canceled", false, false))
        #expect(try task("completed").mark(holds: []) == ("circle", "Awaiting check", false, false))
        #expect(try task("completed", accepted: 1).tint(holds: []) == .checked)
        #expect(try task("rejected").tint(holds: []) == .failed)
        #expect(try task("canceled").tint(holds: []) == .failed)
        #expect(try task("completed").tint(holds: []) == .quiet)
        // Open: the green of work only while it works; what needs someone orange; a hold first, over a result too.
        #expect(working.tint(holds: []) == .work)
        #expect(working.tint(holds: [], limited: true) == .attention)
        #expect(working.tint(holds: [stop]) == .quiet)
        #expect(try task("canceled").tint(holds: [stop]) == .quiet)
        #expect(try task("submitted").tint(holds: []) == .quiet)
        // An outcome that is not known comes first, over the owner's hold and over a result (T-401, fix round 3b).
        let unknown = ("questionmark.circle", "Outcome not known: check it", true, false)
        #expect(working.mark(holds: [stop], limited: true, outcomeUnknown: true) == unknown)
        #expect(try task("failed").mark(holds: [], outcomeUnknown: true) == unknown)
        #expect(working.tint(holds: [stop], outcomeUnknown: true) == .attention)
        #expect(try task("completed", accepted: 1).tint(holds: [], outcomeUnknown: true) == .attention)
        // A stall before what it waits on; a working task that waits on its requester is the hourglass, not work.
        #expect(try task("working", nudge: 1).mark(holds: []) == ("exclamationmark.circle", "Stalled", true, false))
        #expect(try task("working", waitingOn: "its screen").mark(holds: []) == ("hourglass", "Waiting for Manager", true, false))
        #expect(try task("input-required", waitingOn: "Q-3").mark(holds: []) == ("questionmark.circle", "Waiting for Manager", true, false))
        #expect(try task("submitted", waitingOn: "juno").mark(holds: []) == ("hourglass", "Waiting on Juno", true, false))
        #expect(try task("submitted").mark(holds: []) == ("clock", "Queued", false, false))
    }
}
