import Foundation
import CryptoKit
import Testing
@testable import FleetCore

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
private let code = "import json\nprint(json.dumps({'value': 11}))\n"
private func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
private func savedCheck() -> [String: Any] {
    ["code": "saved", "sha256": sha(code), "bytes": Data(code.utf8).count, "code_by": "shop-pm", "run_on": "vps",
     "condition": ["op": ">", "value": 10], "repeat_minutes": NSNull()]
}

private func trigger(check: [String: Any]?, createdBy: String? = "shop-pm", project: String? = "shop") -> [String: Any] {
    var fields: [String: Any] = ["id": 7, "agent": "seo", "state": "active", "revision": 3,
        "schedule": ["kind": "every", "minutes": 15],
        "task": ["title": "Look at the queue", "details": "", "done_when": "The queue is handled.", "needs": "none", "goal_id": NSNull()],
        "late_minutes": 60, "max_tasks_per_day": 4, "tasks_24h": 0, "created": 1000, "updated": 1000, "request_id": "req-shop-0001"]
    if let check { fields["check"] = check }
    if let createdBy { fields["created_by"] = createdBy }
    if let project { fields["project"] = project }
    return fields
}

struct WakeupRuleTests {
    @Test func savedAgentCheckDecodesWithoutRepositoryFields() throws {
        let value = try JSONDecoder().decode(FleetTrigger.self, from: json(trigger(check: savedCheck())))
        #expect(value.isValid)
        #expect(value.isAgentRule && value.author == "shop-pm" && value.project == "shop")
        #expect(value.check?.isSaved == true && value.check?.path == "" && value.check?.commit == "")
        #expect(value.check?.runner(target: value.agent) == "vps")
        #expect(value.check?.args == [:] && value.check?.timeout_seconds == 30)
    }
    @Test func savedCodeOnAnOwnerRuleOrABadSavedFormIsRefused() throws {
        #expect(try !JSONDecoder().decode(FleetTrigger.self, from: json(trigger(check: savedCheck(), createdBy: nil, project: nil))).isValid)
        var bad = savedCheck(); bad["code_by"] = "Not An Agent"
        #expect(try !JSONDecoder().decode(FleetTrigger.self, from: json(trigger(check: bad))).isValid)
        bad = savedCheck(); bad["bytes"] = 70_000
        #expect(try !JSONDecoder().decode(FleetTrigger.self, from: json(trigger(check: bad))).isValid)
        // Plan P4: a hub that leaves the repeat out has none, so the rule still reads (a check that prints lines has
        // neither a repeat nor a condition).
        var unrepeated = savedCheck(); unrepeated.removeValue(forKey: "repeat_minutes")
        let read = try JSONDecoder().decode(FleetTrigger.self, from: json(trigger(check: unrepeated)))
        #expect(read.isValid && read.check?.repeat_minutes == nil)
    }
    @Test func anApprovedRevisionShowsItsApproverAndTheAppNeverSendsItBack() throws {
        var check = savedCheck(); check["code_by"] = "seo"
        check["approval"] = ["prompt": 12, "approver": "shop-pm", "subject": ["author": "seo", "runner": "vps"]]
        let value = try JSONDecoder().decode(FleetTrigger.self, from: json(trigger(check: check, createdBy: "seo")))
        #expect(value.isValid && value.check?.approval == TriggerCheck.CodeApproval(prompt: 12, approver: "shop-pm"))
        let sent = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value.check)) as? [String: Any])
        #expect(sent["approval"] == nil)                                    // only the hub creates an approval
        for bad: Any in ["P-12", ["prompt": 0, "approver": "shop-pm"], ["prompt": 12, "approver": "Not An Agent"], ["prompt": 12]] {
            var other = check; other["approval"] = bad
            let decoded = try JSONDecoder().decode(FleetTrigger.self, from: json(trigger(check: other, createdBy: "seo")))
            #expect(decoded.isValid && decoded.check?.approval == nil)      // an unreadable approval never hides the rule
        }
        #expect(try JSONDecoder().decode(FleetTrigger.self, from: json(trigger(check: savedCheck()))).check?.approval == nil)
    }
    @Test func repositoryChecksAndOlderTriggersStayAsTheyWere() throws {
        let pinned: [String: Any] = ["path": "checks/synthetic_value.py", "commit": String(repeating: "a", count: 40),
                                     "sha256": String(repeating: "b", count: 64), "args": ["value": 11], "timeout_seconds": 30,
                                     "condition": ["op": ">", "value": 10], "repeat_minutes": NSNull()]
        let value = try JSONDecoder().decode(FleetTrigger.self, from: json(trigger(check: pinned, createdBy: nil, project: nil)))
        #expect(value.isValid && !value.isAgentRule && value.author == "owner" && value.project == nil)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.check)) as! [String: Any]
        #expect(wire["path"] as? String == "checks/synthetic_value.py" && wire["code"] == nil)
    }
    @Test func theDetailShowsOnlyTheCodeOfThePinnedHash() throws {
        func detail(source: String) throws -> TriggerDetail {
            try JSONDecoder().decode(TriggerDetail.self, from: json(["db": "db", "trigger": trigger(check: savedCheck()), "upcoming": [], "runs": [],
                "next": NSNull(), "source": source, "history": [["revision": 3, "ts": 1000, "by": "shop-pm", "action": "edit"]]]))
        }
        let good = try detail(source: code)
        #expect(good.verifiedSource == code)
        #expect(good.history?.first?.by == "shop-pm")
        try good.validate(database: "db", id: 7, before: nil)
        let changed = try detail(source: code + "# changed\n")
        #expect(changed.verifiedSource == nil)
        #expect(throws: HubError.self) { try changed.validate(database: "db", id: 7, before: nil) }
    }
}

/// GET /ui/capacity as the hub's capacity_view serializes it: Fixtures/capacity.json was written by the real backend
/// function on synthetic agents and readings. Studio's screen route and worker4 share one account that a session hold
/// limits while its window is at 40%; Studio is held by a screen task while its primary account is available; seo's
/// account is at 100%; ads waits for a hold without a reset time; three routes have no account identity.
private func fixtureObject() throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: "capacity", withExtension: "json", subdirectory: "Fixtures"))
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}
private func report(_ object: [String: Any]) throws -> CapacityReport {
    try JSONDecoder().decode(CapacityReport.self, from: JSONSerialization.data(withJSONObject: object))
}
private func changeAccount(_ object: [String: Any], _ group: String, _ change: (inout [String: Any]) -> Void) -> [String: Any] {
    var copy = object
    copy["accounts"] = (object["accounts"] as! [[String: Any]]).map { a in var a = a; if a["group"] as? String == group { change(&a) }; return a }
    return copy
}

struct CapacityTests {
    @Test func theSerializedShapeKeepsRoutesAccountsHoldsAndEstimatesApart() throws {
        let value = try report(fixtureObject()), t = 1791700000.0
        try value.validate(database: "test-generation")
        #expect(value.stale_after == 900)
        let shared = try #require(value.account("openai:bbbbbbbb"))
        #expect(shared.routes == [.init(agent: "studio", route: "screen"), .init(agent: "worker4", route: "primary")])     // counted once
        #expect(shared.label == "codex-team" && shared.windows.first?.used_percent == 40)
        #expect(shared.state == "limited" && shared.allowance(at: t, staleAfter: 900) == .usedUp(until: 1791706000))   // a hold, below 100%
        #expect(shared.allowance(at: 1791706001, staleAfter: 900) == .awaitingReading)            // after its known reset
        #expect(value.account("openai:dddddddd")?.allowance(at: t, staleAfter: 900) == .usedUp(until: 1791707200))
        #expect(value.account("openai:aaaaaaaa")?.allowance(at: t, staleAfter: 900) == .available)
        let estimate = try #require(value.account("unknown:ads:primary"))
        #expect(estimate.allowance(at: t, staleAfter: 900) == .usedUp(until: nil) && estimate.retry_at == 1791703500)   // only an estimate
        let studio = try #require(value.agents.first { $0.agent == "studio" })
        #expect(studio.routes.map(\.route) == ["primary", "screen"] && studio.routes.map(\.group) == ["anthropic:cccccccc", "openai:bbbbbbbb"])
        #expect(studio.routes[0].state == "available" && studio.hold?.route == "screen" && studio.hold?.until == 1791706000)  // held anyway
        #expect(studio.hold?.task == 1 && studio.hold?.retry_at == nil)
        let ads = try #require(value.agents.first { $0.agent == "ads" })
        #expect(ads.hold?.until == nil && ads.hold?.retry_at == 1791703500 && ads.routes[0].until == nil)
        #expect(value.agents.first { $0.agent == "vps" }?.hold == nil)
        let unknown = value.accounts.filter { !$0.isIdentified }
        #expect(unknown.map(\.group) == ["unknown:ads:primary", "unknown:manager:primary", "unknown:newbie:primary"])
        #expect(unknown.allSatisfy { $0.provider == nil && $0.labels.isEmpty })                   // never merged by a label
        #expect(value.account("unknown:manager:primary")?.allowance(at: t, staleAfter: 900) == .unknown)
        #expect(value.agents.first { $0.agent == "newbie" }?.routes.first?.state == "in_setup")
    }
    @Test func aShapeThatBreaksTheContractIsRefused() throws {
        let good = try fixtureObject()
        #expect(throws: HubError.self) { try report(good).validate(database: "other") }
        #expect(throws: HubError.self) {          // an unknown identity never has a provider
            try report(changeAccount(good, "unknown:ads:primary") { $0["provider"] = "openai" }).validate(database: "test-generation")
        }
        var lost = good                          // a route must name a group of the report
        lost["accounts"] = (good["accounts"] as! [[String: Any]]).filter { $0["group"] as? String != "openai:aaaaaaaa" }
        #expect(throws: HubError.self) { try report(lost).validate(database: "test-generation") }
        #expect(throws: (any Error).self) { try report(changeAccount(good, "openai:aaaaaaaa") { $0.removeValue(forKey: "state") }) }
    }
    @Test func anAvailableReadingAgesAtTheCurrentTime() throws {
        let good = try fixtureObject(), t = 1791700000.0
        func state(at time: Double = t, _ change: @escaping (inout [String: Any]) -> Void = { _ in }) throws -> AllowanceState {
            try #require(report(changeAccount(good, "openai:aaaaaaaa", change)).account("openai:aaaaaaaa")).allowance(at: time, staleAfter: 900)
        }
        #expect(try state() == .available)
        #expect(try state(at: t + 1000) == .awaitingReading)                                   // older than stale_after now
        #expect(try state { $0["stale"] = true } == .awaitingReading)
        #expect(try state { $0["error"] = "read failed" } == .awaitingReading)
        #expect(try state { a in a["windows"] = [["label": "7 days", "used_percent": 10, "remaining_percent": 90, "resets_at": t - 5,
                                                  "window_minutes": 10080]] } == .awaitingReading)            // its reset has passed
        #expect(try state { $0["state"] = "unknown" } == .awaitingReading)                     // a reading that the hub cannot use
    }
}

struct CapacityFeedTests {
    private struct Failure: LocalizedError { var errorDescription: String? { "The hub did not answer." } }
    @Test func aReadingIsCurrentOnlyWhileFetchesSucceedAndFleetIsFresh() throws {
        var feed = CapacityFeed()
        feed.failed(Failure())
        #expect(feed.report == nil && feed.error == "The hub did not answer.")          // the first fetch failed: nothing current
        feed.received(try report(fixtureObject()))
        let account = try #require(feed.report?.account("openai:bbbbbbbb"))
        #expect(feed.allowance(account, at: 1791700030, fresh: true) == .usedUp(until: 1791706000))
        #expect(feed.allowance(account, at: 1791700030, fresh: false) == .awaitingReading)   // Fleet itself is stale
        #expect(feed.allowance(account, at: 1791700200, fresh: true) == .awaitingReading)    // the report is too old now
        #expect(!feed.isCurrent(at: 1791700200, fresh: true) && feed.isCurrent(at: 1791700030, fresh: true))
        feed.failed(Failure())
        #expect(feed.report != nil && feed.allowance(account, at: 1791700030, fresh: true) == .awaitingReading)   // kept as history
        var later = try fixtureObject(); later["time"] = 1791700500.0
        feed.received(try report(later))
        #expect(feed.error == nil && feed.isCurrent(at: 1791700520, fresh: true))
    }
}

private func changeRoute(_ object: [String: Any], _ agent: String, _ route: String, _ change: (inout [String: Any]) -> Void) -> [String: Any] {
    var copy = object
    copy["agents"] = (object["agents"] as! [[String: Any]]).map { a in
        guard a["agent"] as? String == agent else { return a }
        var a = a
        a["routes"] = (a["routes"] as! [[String: Any]]).map { r in var r = r; if r["route"] as? String == route { change(&r) }; return r }
        return a
    }
    return copy
}

struct CapacityBoundaryTests {
    private let t = 1791700000.0
    @Test func aFullWindowWithoutAResetIsCertainOnlyWhileItsReadingIsFresh() throws {
        let noReset = changeAccount(try fixtureObject(), "openai:dddddddd") { a in
            a["until"] = NSNull()
            a["windows"] = [["label": "codex / 7 days", "used_percent": 100, "remaining_percent": 0, "resets_at": NSNull(), "window_minutes": 10080]]
        }
        let account = try #require(try report(noReset).account("openai:dddddddd"))
        let read = try #require(account.read_at)
        #expect(account.allowance(at: read + 900, staleAfter: 900) == .usedUp(until: nil))       // fresh at the boundary
        #expect(account.allowance(at: read + 900.5, staleAfter: 900) == .awaitingReading)        // stale just after it
        let hold = try #require(try report(fixtureObject()).account("unknown:ads:primary"))       // a hold with an estimate only
        #expect(hold.allowance(at: 1791703500 + 600, staleAfter: 900) == .usedUp(until: nil))   // no reset is assumed
    }
    @Test func routesAgeLikeTheirAccountsBetweenPolls() throws {
        var feed = CapacityFeed()
        var nearReset = try fixtureObject(); nearReset["time"] = 1791706000.0 - 30           // a poll 30 s before a known reset
        feed.received(try report(nearReset))
        let studio = try #require(feed.report?.agents.first { $0.agent == "studio" })
        let screen = try #require(studio.routes.first { $0.route == "screen" })
        #expect(feed.availability(of: screen, at: 1791706000 - 10, fresh: true) == .account(.usedUp(until: 1791706000)))
        #expect(feed.availability(of: screen, at: 1791706000 + 10, fresh: true) == .account(.awaitingReading))   // the reset passed
        var aging = try fixtureObject()
        aging = changeAccount(aging, "openai:aaaaaaaa") { $0["read_at"] = 1791700000.0 - 880 }
        aging = changeRoute(aging, "vps", "primary") { $0["read_at"] = 1791700000.0 - 880 }
        feed.received(try report(aging))
        let vps = try #require(feed.report?.agents.first { $0.agent == "vps" }?.routes.first)
        #expect(feed.availability(of: vps, at: t + 10, fresh: true) == .account(.available))
        #expect(feed.availability(of: vps, at: t + 30, fresh: true) == .account(.awaitingReading))         // past stale_after now
        #expect(feed.availability(of: vps, at: t + 10, fresh: false) == .account(.awaitingReading))        // Fleet is stale
    }
    @Test func agentStatesAndLocalModelsStayApartFromAccounts() throws {
        var feed = CapacityFeed()
        var object = try fixtureObject()
        object = changeRoute(object, "vps", "primary") { $0["state"] = "unknown"; $0["reason"] = "Its helper has never checked in." }
        object = changeRoute(object, "worker4", "primary") { $0["group"] = NSNull(); $0["state"] = "available" }
        feed.received(try report(object))
        func route(_ agent: String) throws -> CapacityReport.Route { try #require(feed.report?.agents.first { $0.agent == agent }?.routes.first) }
        #expect(feed.availability(of: try route("vps"), at: t, fresh: true) == .agent("unknown"))   // its account is available
        #expect(feed.availability(of: try route("newbie"), at: t, fresh: true) == .agent("in_setup"))
        #expect(feed.availability(of: try route("worker4"), at: t, fresh: true) == .localModel)
        #expect(feed.availability(of: try route("manager"), at: t, fresh: true) == .account(.unknown))  // no reading at all
    }
    @Test func accountEmailsAgeByEachRoutesOwnReadingAndNeverGroupAnAccount() throws {
        var object = try fixtureObject()
        let before = try report(object)                                                    // a hub without the feature
        #expect(before.accounts.allSatisfy(\.emails.isEmpty) && before.agents.flatMap(\.routes).allSatisfy { $0.account_email == nil })
        // One account, two routes: worker4 read it 880 s ago; Studio's screen route read it long ago. The shared
        // allowance (`read_at`, `stale`) is new for the two routes, and it is limited, failed and without windows.
        object = changeRoute(object, "worker4", "primary") { $0["account_email"] = "team@example.test"; $0["account_email_read_at"] = 1791700000.0 - 880 }
        object = changeRoute(object, "studio", "screen") { $0["account_email"] = "studio@example.test"; $0["account_email_read_at"] = 1791700000.0 - 2000 }
        object = changeRoute(object, "studio", "primary") { $0["account_email"] = "primary@example.test" }       // no time of its own
        object = changeRoute(object, "vps", "primary") { $0["account_email"] = "codex-main"; $0["account_email_read_at"] = 1791700000.0 - 60 }
        object = changeAccount(object, "openai:bbbbbbbb") { a in
            a["emails"] = ["studio@example.test", "team@example.test"]; a["error"] = "read failed"; a["windows"] = [[String: Any]]()
        }
        object = changeAccount(object, "anthropic:cccccccc") { $0["emails"] = ["primary@example.test"] }
        var feed = CapacityFeed()
        feed.received(try report(object))
        let value = try #require(feed.report)
        try value.validate(database: "test-generation")
        func route(_ agent: String, _ name: String = "primary") throws -> CapacityReport.Route {
            try #require(value.agents.first { $0.agent == agent }?.routes.first { $0.route == name })
        }
        let shared = try #require(value.account("openai:bbbbbbbb")), worker4 = try route("worker4"), screen = try route("studio", "screen")
        #expect(shared.routes.count == 2 && shared.emails == ["studio@example.test", "team@example.test"])   // one account, by its key
        #expect(screen.read_at == 1791699940 && !screen.stale && screen.account_email == "studio@example.test")
        #expect(feed.allowance(shared, at: t + 10, fresh: true) != .available)                  // the allowance is not usable now
        #expect(feed.email(of: worker4, at: t + 10, fresh: true) == "team@example.test")        // and the identity is still known
        #expect(feed.email(of: screen, at: t + 10, fresh: true) == nil)                         // its own reading is old
        #expect(feed.emails(of: shared, at: t + 10, fresh: true) == ["team@example.test"])      // only what a route gives now
        #expect(feed.email(of: try route("studio"), at: t + 10, fresh: true) == nil)            // an email without its time is unknown
        #expect(feed.emails(of: try #require(value.account("anthropic:cccccccc")), at: t + 10, fresh: true).isEmpty)
        #expect(feed.email(of: try route("vps"), at: t + 10, fresh: true) == nil)               // an owner label is no email
        #expect(feed.email(of: try route("manager"), at: t + 10, fresh: true) == nil)           // no reading at all
        // After the report, the reading ages at the current time.
        #expect(feed.email(of: worker4, at: t + 30, fresh: true) == nil && feed.emails(of: shared, at: t + 30, fresh: true).isEmpty)
        #expect(feed.email(of: worker4, at: t + 10, fresh: false) == nil)                       // Fleet is stale
        #expect(feed.emails(of: shared, at: t + 10, fresh: false).isEmpty)
        var later = object; later["time"] = 1791700000.0 - 200                                  // an old report of a new reading
        feed.received(try report(later))
        #expect(feed.email(of: worker4, at: t + 10, fresh: true) == nil)
        let broken = changeRoute(object, "worker4", "primary") { $0["account_email_read_at"] = "soon" }
        #expect(throws: (any Error).self) { try report(broken) }                                // a time is a number
    }
}
