import Foundation
import CryptoKit
import Testing
@testable import FleetCore

/// Wake-up rules as the app meets them (UI-API.md 1.7, 1.8 and 1.20): a read, and the state actions. The app writes
/// no rule any more — the agents do, with `save_trigger` — so there is no create or edit body to check here.
struct TriggerTests {
    private let hub = URL(string: "http://localhost:8765")!
    private let schedule = TriggerSchedule(days: ["fri", "mon"], timezone: "Europe/Madrid")
    private let task = TriggerTask(title: "Synthetic task", details: "Local check\nOnly",
                                   done_when: "A result exists", goal_id: 3)

    private func object(_ pending: PendingRequest, id: Int = 4, revision: Int = 1, state: String = "active",
                        check: TriggerCheck? = nil) throws -> [String: Any] {
        ["id": id, "agent": "vps", "state": state, "revision": revision,
         "schedule": try payloadFields(schedule.normalized), "task": try payloadFields(task.normalized),
         "late_minutes": 60, "max_tasks_per_day": 4, "tasks_24h": 0, "created": 1000, "updated": 1000,
         "check": check.map { try! payloadFields($0) } ?? NSNull(),
         "request_id": pending.requestID.uuidString.lowercased()]
    }

    private func receipt(_ pending: PendingRequest, trigger: [String: Any], run: [String: Any]? = nil) throws -> ControlReceipt {
        var fields: [String: Any] = ["ok": true, "request_id": pending.requestID.uuidString.lowercased(),
                                     "client": pending.client, "replayed": true, "trigger": trigger]
        fields["run"] = run
        return try JSONDecoder().decode(ControlReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func manualRunNeedsItsMatchingRunReceipt() throws {
        let request = PendingRequest(hub: hub, database: "db", client: "local", command: .triggerState(id: 4, revision: 8, action: .run_now), text: "")
        #expect(request.route == "ui/triggers/4/state" && request.command?.requiredFeature == "triggers")
        let run: [String: Any] = ["id": 3, "due": 1000, "created": 1000, "manual": true, "revision": 8, "state": "not_started", "reason": "Agent is busy"]
        var trigger = try object(request, revision: 8); trigger["last_run"] = run
        #expect(try receipt(request, trigger: trigger, run: run).matches(request))
        #expect(try !receipt(request, trigger: trigger).matches(request))
        var other = run; other["id"] = 4
        #expect(try !receipt(request, trigger: trigger, run: other).matches(request))
        let paused = PendingRequest(hub: hub, database: "db", client: "local", command: .triggerState(id: 4, revision: 8, action: .pause), text: "")
        #expect(try receipt(paused, trigger: object(paused, revision: 9, state: "paused")).matches(paused))
        #expect(try !receipt(paused, trigger: object(paused, revision: 9)).matches(paused))
    }

    @Test func calendarShapesAndNullGoalUseTheAgreedContract() throws {
        #expect(TriggerSchedule(kind: "monthly", day: 31, timezone: "Europe/Madrid").isValid)
        #expect(!TriggerSchedule(kind: "monthly", day: 32).isValid)
        #expect(!TriggerSchedule(days: []).isValid)
        #expect(!TriggerSchedule(days: ["mon", "mon"]).isValid)
        #expect(!TriggerSchedule(time: "25:00").isValid)
        #expect(!TriggerSchedule(timezone: "not/a/zone").isValid)
        let interval = TriggerSchedule(kind: "every", minutes: 15, time: nil, timezone: nil)
        #expect(interval.isValid)
        #expect(TriggerSchedule(kind: "every", minutes: 1, time: nil, timezone: nil).isValid)       // plan C12: from 1
        #expect(TriggerSchedule(kind: "every", minutes: 20160, time: nil, timezone: nil).isValid)
        #expect(!TriggerSchedule(kind: "every", minutes: 0, time: nil, timezone: nil).isValid)
        #expect(schedule.normalized.days == ["mon", "fri"])
        var free = task; free.goal_id = nil
        let fields = try payloadFields(free.normalized)
        #expect(fields["goal_id"] is NSNull)
        #expect(try payloadFields(interval)["timezone"] == nil)
    }

    @Test func aRuleAndAListWithNoLateWindowCapsOrFleetBudgetAreValid() throws {
        // plan C12: a newer hub sends no late_minutes, max_tasks_per_day, tasks_24h or fleet limits
        let request = PendingRequest(hub: hub, database: "db", client: "local", text: "")
        var rule = try object(request)
        for key in ["late_minutes", "max_tasks_per_day", "tasks_24h"] { rule.removeValue(forKey: key) }
        rule["schedule"] = ["kind": "every", "minutes": 1]
        let list = try JSONDecoder().decode(TriggerList.self, from: JSONSerialization.data(withJSONObject: [
            "db": "db", "triggers": [rule]]))
        try list.validate(database: "db")
        #expect(list.fleet == nil && list.triggers.first?.late_minutes == nil)
        let old = try JSONDecoder().decode(TriggerList.self, from: JSONSerialization.data(withJSONObject: [
            "db": "db", "triggers": [try object(request)], "fleet": ["max_tasks_per_day": 20, "tasks_24h": 3]]))
        try old.validate(database: "db")                                    // an older hub still reads
        #expect(old.triggers.first?.max_tasks_per_day == 4)
    }

    @Test func historyRejectsOtherDatabasesAndBrokenPageCursors() throws {
        let request = PendingRequest(hub: hub, database: "db", client: "local", text: "")
        var fields: [String: Any] = ["db": "db", "trigger": try object(request), "upcoming": [],
            "runs": [["id": 7, "due": 1000, "created": 1000, "manual": false, "revision": 1, "state": "future_state"]], "next": 7]
        func page() throws -> TriggerDetail { try JSONDecoder().decode(TriggerDetail.self, from: JSONSerialization.data(withJSONObject: fields)) }
        try page().validate(database: "db", id: 4, before: 8)
        #expect(throws: (any Error).self) { try page().validate(database: "other", id: 4, before: 8) }
        #expect(throws: (any Error).self) { try page().validate(database: "db", id: 4, before: 7) }
        fields["next"] = 9
        #expect(throws: (any Error).self) { try page().validate(database: "db", id: 4, before: 8) }
    }

    private var check: TriggerCheck {
        TriggerCheck(path: "checks/synthetic_value.py", commit: String(repeating: "a", count: 40), sha256: String(repeating: "b", count: 64),
                     args: ["value": .integer(11)], condition: .init(op: ">", value: 10), repeat_minutes: nil)
    }

    @Test func checksKeepTheApprovedVersionArgumentsAndRepeatChoice() throws {
        let request = PendingRequest(hub: hub, database: "db", client: "local", text: "")
        let saved = try payloadFields(check)
        #expect(saved["repeat_minutes"] is NSNull)
        let read = try JSONDecoder().decode(FleetTrigger.self, from: JSONSerialization.data(withJSONObject: try object(request, check: check)))
        #expect(read.isValid && read.check == check)
        // A hub that leaves the repeat out has none: the page shows the rule, and the repeat is not on it.
        var noRepeat = saved; noRepeat.removeValue(forKey: "repeat_minutes")
        let unrepeated = try JSONDecoder().decode(TriggerCheck.self, from: JSONSerialization.data(withJSONObject: noRepeat))
        #expect(unrepeated.isValid && unrepeated.repeat_minutes == nil && unrepeated.condition == check.condition)
        var wrong = check; wrong.condition?.value = .infinity
        #expect(!wrong.isValid)
        wrong = check; wrong.condition?.op = "~"
        #expect(!wrong.isValid)
        wrong = check; wrong.path = "checks/Upper-Case.py"
        #expect(!wrong.isValid)
        wrong = check; wrong.path = "checks/" + String(repeating: "a", count: 65) + ".py"
        #expect(!wrong.isValid)
        wrong = check; wrong.args = ["long": .string(String(repeating: "x", count: 4096))]
        #expect(!wrong.isValid)
        // plan C12: the author's own timeout and repeat, with no fleet ceiling; never zero or below
        var own = check; own.timeout_seconds = 90; own.repeat_minutes = 20160
        #expect(own.isValid)
        own.timeout_seconds = 0
        #expect(!own.isValid)
        let mixed = Data(#"{"flag":true,"nested":[null,9007199254740993,0.5,"text"]}"#.utf8)
        let args = try JSONDecoder().decode([String: CheckArgument].self, from: mixed)
        #expect(args["flag"] == .bool(true))
        #expect(args["nested"] == .array([.null, .integer(9007199254740993), .number(0.5), .string("text")]))
        #expect(try JSONDecoder().decode([String: CheckArgument].self, from: JSONEncoder().encode(args)) == args)
    }

    /// Plan P4 (lane L4): a check that prints lines has no condition and no repeat. One such rule used to empty the
    /// whole list ("Key 'condition' not found"), so the rule list and the rule's own page lost every rule with it.
    @Test func aCheckThatPrintsLinesReadsInTheListAndOnItsPage() throws {
        let request = PendingRequest(hub: hub, database: "db", client: "local", text: "")
        let lines: [String: Any] = ["form": "lines", "code": "saved", "sha256": String(repeating: "a", count: 64),
                                    "bytes": 10, "code_by": "vps", "args": [:], "timeout_seconds": 60]
        var rule = try object(request, id: 5)
        rule["check"] = lines; rule["created_by"] = "vps"
        for key in ["late_minutes", "max_tasks_per_day"] { rule.removeValue(forKey: key) }
        let list = try JSONDecoder().decode(TriggerList.self, from: JSONSerialization.data(withJSONObject: [
            "db": "db", "triggers": [try object(request, check: check), rule]]))
        try list.validate(database: "db")
        let read = try #require(list.triggers.first { $0.id == 5 }?.check)
        #expect(read.form == "lines" && read.condition == nil && read.repeat_minutes == nil && read.isSaved)
        #expect(list.triggers.first { $0.id == 4 }?.check == check)      // the value form beside it is unchanged
        let page = try JSONDecoder().decode(TriggerDetail.self, from: JSONSerialization.data(withJSONObject: [
            "db": "db", "trigger": rule, "upcoming": [], "runs": []]))
        try page.validate(database: "db", id: 5, before: nil)
        #expect(page.trigger.check?.form == "lines")
        // The form is kept as it came, and nothing of the value form is added to it.
        let again = try payloadFields(read)
        #expect(again["form"] as? String == "lines" && again["condition"] == nil && again["repeat_minutes"] == nil)
    }

    @Test func checkOnlyReceiptCannotBecomeAnAgentTaskReceipt() throws {
        let request = PendingRequest(hub: hub, database: "db", client: "local", command: .triggerState(id: 4, revision: 8, action: .check_now), text: "")
        #expect(request.command?.requiredFeature == "trigger_checks")
        var run: [String: Any] = ["id": 3, "due": 1000, "created": 1000, "manual": true, "check_now": true, "revision": 8, "state": "sent", "attempts": 1]
        var trigger = try object(request, revision: 8, check: check); trigger["last_run"] = run
        #expect(try receipt(request, trigger: trigger, run: run).matches(request))
        run["check_now"] = false; trigger["last_run"] = run
        #expect(try !receipt(request, trigger: trigger, run: run).matches(request))
        run["check_now"] = true; run["task"] = 99; trigger["last_run"] = run
        #expect(try !receipt(request, trigger: trigger, run: run).matches(request))
        run.removeValue(forKey: "task"); run["manual"] = false; trigger["last_run"] = run
        #expect(try !receipt(request, trigger: trigger, run: run).matches(request))
    }

    @Test func catalogVerifiesTheExactSourceBytesAndDatabase() throws {
        let source = "print(11)\n"
        let hash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        var entry: [String: Any] = ["path": check.path, "commit": check.commit, "sha256": hash, "source": source, "bytes": source.utf8.count]
        func catalog() throws -> TriggerCheckCatalog {
            try JSONDecoder().decode(TriggerCheckCatalog.self, from: JSONSerialization.data(withJSONObject: ["db": "db", "revision": check.commit, "checks": [entry]]))
        }
        try catalog().validate(database: "db")
        #expect(throws: (any Error).self) { try catalog().validate(database: "other") }
        entry["source"] = "print(12)\n"
        #expect(throws: (any Error).self) { try catalog().validate(database: "db") }
        entry["source"] = source; entry["bytes"] = 100
        #expect(throws: (any Error).self) { try catalog().validate(database: "db") }
    }
}
