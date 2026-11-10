import Foundation
import Testing
@testable import FleetCore

/// The owner grant interface (`vault_access`): give or remove one agent's use of its machine's vault. Synthetic data only.
struct VaultAccessTests {
    private let hash = String(repeating: "a", count: 64)
    private let revision = String(repeating: "b", count: 40)
    private func request(_ command: OwnerCommand, text: String = "") -> PendingRequest {
        PendingRequest(hub: URL(string: "http://localhost:8765")!, database: "db", client: "local", command: command, text: text)
    }
    private func receipt(_ pending: PendingRequest, _ changes: Any = [["field": "vault", "before": "none", "after": "broker"]],
                         extra: [String: Any] = [:]) throws -> ControlReceipt {
        let fields: [String: Any] = ["ok": true, "request_id": pending.requestID.uuidString, "client": "local", "replayed": false,
            "agent": "seo", "revision": revision, "sha256": hash, "changed": changes, "updates_requested": ["seo"],
            "settings_pending": false, "activation": NSNull(), "open_tasks": []]
        return try JSONDecoder().decode(ControlReceipt.self, from: JSONSerialization.data(withJSONObject: fields.merging(extra) { _, b in b }))
    }

    @Test func aVaultCommandSendsOnlyTheVaultAndSurvivesARelaunch() throws {
        let grant = request(.agentVault(agent: "seo", sha256: hash, access: .broker))
        let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(grant))
        #expect(restored == grant && restored.route == "ui/team/agents/seo" && restored.command?.requiredFeature == "vault_access")
        let body = try #require(JSONSerialization.jsonObject(with: restored.body()) as? [String: Any])
        #expect(Set(body.keys) == ["request_id", "db", "base_sha256", "vault"])        // never a saved model or effort again
        #expect(body["vault"] as? String == "broker" && body["base_sha256"] as? String == hash)
        let revoke = request(.agentVault(agent: "seo", sha256: hash, access: .none))
        #expect(try (JSONSerialization.jsonObject(with: revoke.body()) as? [String: Any])?["vault"] as? String == "none")
        #expect(grant.command?.label == "Give Seo vault access" && revoke.command?.label == "Remove vault access of Seo")
        for bad in [request(.agentVault(agent: "Seo!", sha256: hash, access: .broker)),
                    request(.agentVault(agent: "seo", sha256: "abc", access: .broker)),
                    request(.agentVault(agent: "seo", sha256: hash, access: .broker), text: "note")] {
            #expect(throws: HubError.self) { try bad.body() }
        }
    }

    @Test func aVaultReceiptMatchesOnlyThisAgentAndThisAccess() throws {
        let grant = request(.agentVault(agent: "seo", sha256: hash, access: .broker))
        #expect(try receipt(grant).matches(grant))
        #expect(try receipt(grant, []).matches(grant))                                   // the same value again: changed []
        let revoked = try receipt(grant, [["field": "vault", "before": "broker", "after": "none"]], extra: ["open_tasks": [12, 15]])
        #expect(!revoked.matches(grant) && revoked.open_tasks == [12, 15])
        let revoke = request(.agentVault(agent: "seo", sha256: hash, access: .none))
        #expect(try receipt(revoke, [["field": "vault", "before": "broker", "after": "none"]]).matches(revoke))
        for bad: [String: Any] in [["agent": "vps"], ["updates_requested": ["vps"]], ["activation": ["check": 7, "checked_at": 1000]],
                                   ["revision": "short"]] {
            #expect(try !receipt(grant, extra: bad).matches(grant))
        }
        for changes in [[["field": "model", "before": NSNull(), "after": "sample"]],
                        [["field": "vault", "before": "none", "after": "broker"],
                         ["field": "vault_recipient", "before": NSNull(), "after": "age1" + String(repeating: "q", count: 58)]]] {
            #expect(try !receipt(grant, changes).matches(grant))                           // nothing but the access may change
        }
        #expect(try receipt(grant, extra: ["open_tasks": NSNull()]).matches(grant))         // open_tasks is not part of the match
        // A settings request never takes a vault receipt as its own.
        let settings = request(.agentSettings(agent: "seo", sha256: hash), text: try AgentSettingsInput(can: ["shell"]).payload())
        #expect(try !receipt(settings).matches(settings))
    }

    @Test func theControlChangesOnlyBrokerAndNoneAndOnlyWhenTheHubSaysSo() {
        let ready = VaultGrant(ready: true, missing: []), waiting = VaultGrant(ready: false, missing: ["agent_without_key", "no_vault_store"])
        func control(_ role: String?, _ vault: String?, offered: Bool = true, _ grant: VaultGrant? = nil) -> VaultAccessControl {
            VaultAccessControl(role: role, vault: vault, offered: offered, grant: grant, callers: true)
        }
        // Every worker or lead with broker access can lose it, also the store's own agent and the last one.
        #expect(control("worker", "broker").action == .revoke && control("lead", "broker").action == .revoke)
        #expect(control("worker", "none", ready).action == .grant && control("worker", "none", ready).reasons.isEmpty)
        let blocked = control("worker", "none", waiting)
        #expect(blocked.action == nil && blocked.reasons == ["This agent has no agent key yet.", "Its server has no vault store."])
        #expect(control("worker", "none").action == nil && control("worker", "none").reasons.isEmpty)   // readiness unknown
        #expect(control("manager", "broker").action == nil && control("manager", "broker").status == "Uses this server's vault.")
        #expect(control("worker", "file", ready).action == nil && control("worker", "file").status == "Uses its own vault files.")
        #expect(control("worker", nil).status == nil && control("worker", nil).action == nil)    // a hub before 1.12
        for (vault, grant) in [("broker", nil), ("none", ready)] as [(String, VaultGrant?)] {
            let older = control("worker", vault, offered: false, grant)                       // no vault_access: saved access stays
            #expect(older.action == nil && older.reasons.isEmpty && older.status != nil)
        }
    }

    @Test func anOldOrSilentBrokerKeepsTheSavedAccessAndOffersNoChange() {
        let ready = VaultGrant(ready: true, missing: []), blocked = VaultGrant(ready: false, missing: ["broker_without_callers"])
        let update = "This server's vault needs its update before this access can change here."
        let silent = "Founderizer has no current answer from this server's vault, so this access cannot change here now."
        for (vault, grant, callers, note) in [("broker", nil, false, update), ("broker", nil, nil, silent),
                                              ("none", ready, false, update), ("none", blocked, false, update),
                                              ("none", ready, nil, silent)] as [(String, VaultGrant?, Bool?, String)] {
            let control = VaultAccessControl(role: "worker", vault: vault, offered: true, grant: grant, callers: callers)
            #expect(control.action == nil && control.reasons == [note] && control.status != nil)   // no vault command
        }
        #expect(VaultAccessControl(role: "worker", vault: "broker", offered: true, grant: nil, callers: true).action == .revoke)
        #expect(VaultAccessControl(role: "lead", vault: "none", offered: true, grant: ready, callers: true).action == .grant)
        // No note where Fleet never offers a change: the fleet manager, file mode and a hub without vault_access.
        for (role, vault, offered) in [("manager", "broker", true), ("worker", "file", true), ("worker", "broker", false)] {
            let control = VaultAccessControl(role: role, vault: vault, offered: offered, grant: nil, callers: false)
            #expect(control.action == nil && control.reasons.isEmpty)
        }
    }

    @Test func theBrokerAnswerCountsOnlyInACurrentReading() throws {
        func row(_ vault: [String: Any], reportedAt: Double = 1000) throws -> MachineStatus {
            try JSONDecoder().decode(MachineStatus.self, from: JSONSerialization.data(withJSONObject: [
                "agent": "studio", "machine": "mac-studio", "role": "worker", "update": [:], "runtime": [:], "os": [:],
                "reported_at": reportedAt, "security": ["vault": vault]]))
        }
        #expect(try row(["mode": "broker", "isolated": true, "callers": true]).brokerCallers(at: 1100) == true)
        #expect(try row(["mode": "broker", "isolated": true, "callers": false]).brokerCallers(at: 1100) == false)
        #expect(try row(["mode": "broker", "isolated": true, "callers": NSNull()]).brokerCallers(at: 1100) == nil)
        #expect(try row(["mode": "broker", "isolated": true]).brokerCallers(at: 1100) == nil)          // an older helper
        #expect(try row(["mode": "broker", "isolated": true, "callers": true]).brokerCallers(at: 2000) == nil)   // stale
    }

    @Test func readinessCodesAreFactsInOrdinaryWords() {
        let codes = ["agent_without_key", "helper_without_broker_callers", "no_vault_store", "broker_status_unknown",
                     "vault_store_mismatch", "broker_without_callers", "a_new_code"]
        let texts = codes.map(VaultAccessControl.reason)
        #expect(Set(texts).count == texts.count && texts.last == "Founderizer cannot give vault access now.")
        for text in texts {
            #expect(!text.contains("_"))
            for word in ["permission", "sign in", "sign-in", "log in", "login", "sudo", "install"] { #expect(!text.lowercased().contains(word)) }
        }
    }

    @Test func aTeamLineReadsItsVaultButALinesSaveNeverSendsIt() throws {
        let object: [String: Any] = ["db": "db", "revision": revision, "sha256": hash, "open_tasks": [:], "lines": [
            ["agent": "manager", "role": "manager", "reports_to": NSNull(), "vault": "file", "vault_grant": NSNull()],
            ["agent": "studio", "role": "worker", "reports_to": "manager", "vault": "broker", "vault_grant": NSNull()],
            ["agent": "seo", "role": "worker", "reports_to": "manager", "vault": "none",
             "vault_grant": ["ready": false, "missing": ["broker_without_callers"]]]]]
        let team = try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        try team.validate(database: "db")
        #expect(team.lines.map(\.vault) == ["file", "broker", "none"])
        #expect(team.lines[0].vault_grant == nil && team.lines[2].vault_grant == VaultGrant(ready: false, missing: ["broker_without_callers"]))
        let payload = try TeamLinesInput(lines: team.lines).payload()
        #expect(!payload.contains("vault"))
    }
}
