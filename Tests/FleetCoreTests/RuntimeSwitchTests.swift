import Foundation
import Testing
@testable import FleetCore

private let hub = URL(string: "http://localhost:8765")!
private let base = String(repeating: "a", count: 64)
private let result = String(repeating: "c", count: 64)
private let now = 10_000.0

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private func receipt(_ request: PendingRequest, changed: [[String: Any]], updates: [String] = ["vps"]) throws -> ControlReceipt {
    let fields: [String: Any] = ["ok": true, "request_id": request.requestID.uuidString.lowercased(), "client": request.client, "replayed": false,
                                 "agent": "vps", "revision": String(repeating: "b", count: 40), "sha256": result, "changed": changed,
                                 "updates_requested": updates, "settings_pending": !changed.isEmpty, "activation": NSNull()]
    return try JSONDecoder().decode(ControlReceipt.self, from: json(fields))
}

private func line(_ readiness: Any?) throws -> ReportingLine {
    var fields: [String: Any] = ["agent": "vps", "role": "worker", "reports_to": "manager"]
    if let readiness { fields["runtime_switch"] = readiness }
    let team: [String: Any] = ["db": "db", "revision": String(repeating: "b", count: 40), "sha256": base, "open_tasks": [:],
                               "lines": [["agent": "manager", "role": "manager", "reports_to": NSNull()], fields]]
    return try #require(try JSONDecoder().decode(TeamSnapshot.self, from: json(team)).lines.last)
}

private func machine(loaded: String?, pending: Bool = false, reported: Double = now - 30, runtimes: Any? = nil) throws -> MachineStatus {
    let settings: [String: Any] = ["model": NSNull(), "effort": NSNull(), "can": ["shell"]]          // never names a runtime
    var fields: [String: Any] = ["agent": "vps", "machine": "vps", "role": "worker", "update": [:], "security": [:], "os": [:],
                                 "runtime": loaded.map { ["name": $0, "signed_in": true] } ?? [:],
                                 "reported_at": reported, "settings": settings, "settings_pending": pending]
    if let runtimes { fields["runtimes"] = runtimes }
    return try JSONDecoder().decode(MachineStatus.self, from: json(fields))
}

private func tokens(_ total: Int, at collected: Double) -> [String: Any] {
    ["input": total, "output": 0, "cache_read": 0, "cache_write": 0, "total": total, "sessions": 1, "since": 1000.0,
     "last_activity": collected, "collected_at": collected, "source": "test", "scope": "test"]
}

struct RuntimeSwitchTests {
    @Test func aSwitchSendsTheRuntimeAloneAndMatchesOnlyItsOwnReceipt() throws {
        let request = PendingRequest(hub: hub, database: "db", client: "local", command: .agentRuntime(agent: "vps", sha256: base, runtime: "claude"), text: "")
        let body = try JSONSerialization.jsonObject(with: request.body()) as! [String: Any]
        #expect(body["runtime"] as? String == "claude" && body["base_sha256"] as? String == base && body["model"] == nil)
        #expect(request.route == "ui/team/agents/vps" && request.command?.requiredFeature == "runtime_switch")
        #expect(throws: (any Error).self) { try OwnerCommand.agentRuntime(agent: "vps", sha256: base, runtime: "grok").bodyFields(text: "") }
        #expect(throws: (any Error).self) { try OwnerCommand.agentRuntime(agent: "vps", sha256: base, runtime: "claude").bodyFields(text: "{}") }
        let switched: [[String: Any]] = [["field": "runtime", "before": "codex", "after": "claude"],
                                         ["field": "model", "before": "gpt-6.1-sol", "after": NSNull()], ["field": "account", "before": "codex-main", "after": NSNull()]]
        #expect(try receipt(request, changed: switched).matches(request))
        #expect(try receipt(request, changed: [], updates: []).matches(request))            // already that runtime
        #expect(try !receipt(request, changed: [], updates: ["vps"]).matches(request))
        #expect(try !receipt(request, changed: [["field": "runtime", "before": "claude", "after": "codex"]]).matches(request))
        #expect(try !receipt(request, changed: switched + [["field": "can", "before": [], "after": ["shell"]]]).matches(request))
        #expect(try !receipt(request, changed: [["field": "runtime", "before": "codex", "after": "claude"],
                                                ["field": "effort", "before": NSNull(), "after": "high"]]).matches(request))
    }

    @Test func readinessDecodesEveryCaseAndNeverOffersAnUnreadableSwitch() throws {
        let busy = try #require(try line(["to": "claude", "ready": false, "missing": ["agent_busy"],
                                          "busy": ["open_tasks": ["T-90"], "chats_waiting": 1, "desktop": NSNull()]]).runtime_switch)
        #expect(busy.to == "claude" && !busy.ready && busy.reasons(current: "codex") == ["Busy: 1 task open, 1 chat waiting."])
        let ready = try #require(try line(["to": "codex", "ready": true, "missing": [], "busy": NSNull()]).runtime_switch)
        #expect(ready.ready && ready.reasons(current: "claude").isEmpty)
        let grok = try #require(try line(["to": NSNull(), "ready": false, "missing": ["runtime_not_supported"], "busy": NSNull()]).runtime_switch)
        #expect(grok.to == nil && !grok.ready && grok.reasons(current: "grok") == ["Grok Build cannot switch."])
        let manager = try #require(try line(["to": "claude", "ready": false, "missing": ["manager_not_supported"]]).runtime_switch)
        #expect(manager.reasons(current: "codex") == ["Switching the manager is not supported yet."])
        let waiting = try #require(try line(["to": "claude", "ready": false, "missing": ["settings_pending", "chat_not_bound"]]).runtime_switch)
        #expect(waiting.reasons(current: "codex") == ["Waiting for its current settings.", "Link its existing chat first."])
        let rules = try #require(try line(["to": "claude", "ready": false, "missing": ["wakeup_rules_depend"]]).runtime_switch)
        #expect(rules.reasons(current: "codex") == ["Pause its code wake-up rules or change their runner first."])
        // A wrong shape or target never hides the team and never counts as ready.
        let unreadable = try #require(try line("ready").runtime_switch)
        #expect(!unreadable.ready && unreadable.to == nil && unreadable.reasons(current: "codex") == ["Founderizer cannot tell yet."])
        let target = try #require(try line(["to": "grok", "ready": true, "missing": []]).runtime_switch)
        #expect(!target.ready && target.to == nil)
        #expect(try line(nil).runtime_switch == nil)
        #expect(RuntimeSwitch.unavailable(offered: false, readiness: ready) == "This hub cannot switch providers.")
        #expect(RuntimeSwitch.unavailable(offered: true, readiness: nil) != nil && RuntimeSwitch.unavailable(offered: true, readiness: ready) == nil)
    }

    @Test func onlyALoadedRuntimeThatMatchesConfirmsTheProvider() throws {
        let confirmed = ProviderState(configured: "claude", machine: try machine(loaded: "claude"), at: now)
        #expect(confirmed.isConfirmed && confirmed.switchingFrom == nil)
        let switching = ProviderState(configured: "claude", machine: try machine(loaded: "codex", pending: true), at: now)
        #expect(!switching.isConfirmed && switching.switchingFrom == "codex")
        let unloaded = ProviderState(configured: "claude", machine: try machine(loaded: nil), at: now)   // no runtime name: unknown
        #expect(!unloaded.isConfirmed && unloaded.switchingFrom == nil && unloaded.known)
        #expect(!ProviderState(configured: "claude", machine: try machine(loaded: "claude", pending: true), at: now).isConfirmed)
        let old = ProviderState(configured: "claude", machine: try machine(loaded: "codex", reported: now - 900), at: now)
        #expect(!old.known && !old.isConfirmed && old.switchingFrom == nil)               // an old reading proves nothing
        #expect(!ProviderState(configured: "claude", machine: nil, at: now).isConfirmed)
    }

    @Test func anEarlierProviderTotalStaysInTheTokensButNotInTheirReadingTime() throws {
        // Read again from the kept transcripts after the switch (its final turn), and still not a live reading.
        let previous: [String: Any] = ["runtime": "codex", "tokens": tokens(500, at: 2600), "until": 2500.0]
        let usage = try JSONDecoder().decode(AgentUsage.self, from: json(["tokens": tokens(100, at: now - 30), "previous": previous]))
        let combined = try #require(usage.combinedTokens)
        #expect(combined.total == 600 && combined.sessions == 2)
        #expect(combined.collected_at == now - 30 && !combined.isStale(at: now))           // the old total does not make it old
        #expect(usage.limits == nil && usage.previous?.runtime == "codex")
        let alone = try JSONDecoder().decode(AgentUsage.self, from: json(["previous": previous]))
        #expect(alone.combinedTokens?.total == 500 && alone.combinedTokens?.collected_at == 2600)
        let broken = try JSONDecoder().decode(AgentUsage.self, from: json(["tokens": tokens(100, at: now - 30), "previous": ["runtime": "codex", "until": "later"]]))
        #expect(broken.previous == nil && broken.combinedTokens?.total == 100)            // never hides the live reading
    }

    @Test func aModelListCountsOnlyForTheRuntimeThatTheAgentRunsNow() throws {
        func list(_ runtime: String, ok: Bool = true) throws -> RuntimeModels {
            try JSONDecoder().decode(RuntimeModels.self, from: json(["runtime": runtime, "ok": ok, "read_at": now, "source": "test",
                                                                     "other_names": false, "error": NSNull(), "options": []]))
        }
        #expect(try list("codex").isFor("codex"))
        #expect(try !list("codex").isFor("claude"))                                        // the list from before a switch
        #expect(try !list("codex").isFor(nil))                                             // an unknown provider stays unknown
        #expect(try !list("codex", ok: false).isFor("codex"))
    }

    @Test func aMachineReadingGivesBothRuntimesAndItsLoadedOne() throws {
        let runtimes: [String: Any] = ["codex": ["version": "0.160.0", "signed_in": true], "claude": ["version": NSNull(), "signed_in": NSNull()],
                                       "grok": NSNull(), "bad": "x"]
        let reading = try machine(loaded: "codex", runtimes: runtimes)
        #expect(reading.runtime.name == "codex" && reading.settings?.can == ["shell"])
        #expect(reading.runtimes?.byName.keys.sorted() == ["claude", "codex"])
        #expect(reading.runtimes?.byName["codex"]?.signed_in == true && reading.runtimes?.byName["claude"]?.version == nil)
        #expect(try machine(loaded: nil, runtimes: "x").runtimes?.byName.isEmpty == true)
    }

    @Test func onlyTheTargetRuntimesOwnSetupReasonsOfferItsSetup() throws {
        func readiness(_ fields: [String: Any]) throws -> RuntimeSwitch { try #require(try line(fields).runtime_switch) }
        let worker4 = try readiness(["to": "claude", "ready": false, "missing": ["runtime_not_installed", "chat_not_bound"]])
        #expect(worker4.needsSetup)
        #expect(worker4.reasons(current: "codex").contains("Link its existing chat first."))   // the other blocker stays
        #expect(try readiness(["to": "claude", "ready": false, "missing": ["runtime_sign_in_unknown"]]).needsSetup)
        #expect(try !readiness(["to": "claude", "ready": false, "missing": ["chat_not_bound"]]).needsSetup)
        #expect(try !readiness(["to": "claude", "ready": true, "missing": []]).needsSetup)
        #expect(try !readiness(["to": NSNull(), "ready": false, "missing": ["runtime_not_supported", "runtime_not_installed"]]).needsSetup)
    }
}

// MARK: the reasons on a row that already names the provider

// The owner has four machines; "Codex is not installed." says nothing about which one. On the one row that the
// Change provider control opens, the reason names the machine instead of repeating the provider.
@Test func aRowReasonNamesTheMachineAndNotTheProviderAgain() throws {
    let switchable = try JSONDecoder().decode(RuntimeSwitch.self, from: Data("""
        {"to": "codex", "ready": false, "missing": ["runtime_not_installed"]}
        """.utf8))
    #expect(switchable.reasons(current: "claude") == ["Codex is not installed."])
    #expect(switchable.rowReasons(current: "claude", machine: "hub", agent: "manager") == ["Not installed on hub."])

    let signedOut = try JSONDecoder().decode(RuntimeSwitch.self, from: Data("""
        {"to": "codex", "ready": false, "missing": ["runtime_not_signed_in"]}
        """.utf8))
    #expect(signedOut.rowReasons(current: "claude", machine: "vps", agent: "vps") == ["Not signed in on vps."])

    // A reason that is not about the machine keeps the hub's own sentence.
    let busy = try JSONDecoder().decode(RuntimeSwitch.self, from: Data("""
        {"to": "codex", "ready": false, "missing": ["agent_busy"], "busy": {"open_tasks": ["T-12"]}}
        """.utf8))
    #expect(busy.rowReasons(current: "claude", machine: "hub", agent: "manager") == ["Busy: 1 task open."])

    let ready = try JSONDecoder().decode(RuntimeSwitch.self, from: Data("""
        {"to": "codex", "ready": true, "missing": []}
        """.utf8))
    #expect(ready.rowReasons(current: "claude", machine: "hub", agent: "manager").isEmpty)
}

// A dead end states a fact, disables the button and offers nothing. The owner, 20 October 2026: "look at the
// messages, what do they even mean, they dont make any sense!" So the reason says what the other provider cannot
// do, and for whom.
@Test func aSwitchThatWouldCostTheAgentSomethingSaysWhatAndForWhom() throws {
    let access = try JSONDecoder().decode(RuntimeSwitch.self, from: Data("""
        {"to": "codex", "ready": false, "missing": ["access_not_equivalent"]}
        """.utf8))
    #expect(access.rowReasons(current: "claude", machine: "studio", agent: "studio")
            == ["Codex cannot do everything Studio does."])
    // Away from a row that knows the agent, the same fact without the name.
    #expect(access.reasons(current: "claude") == ["Codex cannot do everything this agent does."])
}
