import Foundation
import Testing
@testable import FleetCore

/// The owner fields of `login_create`: the agent's permission, the project's permission and the made logins.
/// Synthetic data only.
struct LoginCreateTests {
    private let hash = String(repeating: "a", count: 64)
    private let reference = "bws://11111111-2222-4333-8444-55555555555b"
    private func request(_ command: OwnerCommand, text: String = "") -> PendingRequest {
        PendingRequest(hub: URL(string: "http://localhost:8765")!, database: "db", client: "local", command: command, text: text)
    }
    private func receipt(_ pending: PendingRequest, _ changes: Any, extra: [String: Any] = [:]) throws -> ControlReceipt {
        let fields: [String: Any] = ["ok": true, "request_id": pending.requestID.uuidString, "client": "local", "replayed": false,
            "agent": "seo", "revision": String(repeating: "b", count: 40), "sha256": hash, "changed": changes, "activation": NSNull()]
        return try JSONDecoder().decode(ControlReceipt.self, from: JSONSerialization.data(withJSONObject: fields.merging(extra) { _, b in b }))
    }

    @Test func thePermissionCommandSendsOnlyThePermissionAndSurvivesARelaunch() throws {
        let grant = request(.agentVaultCreate(agent: "seo", sha256: hash, on: true))
        let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(grant))
        #expect(restored == grant && restored.route == "ui/team/agents/seo" && restored.command?.requiredFeature == "login_create")
        let body = try #require(JSONSerialization.jsonObject(with: restored.body()) as? [String: Any])
        #expect(Set(body.keys) == ["request_id", "db", "base_sha256", "vault_create"] && body["vault_create"] as? Bool == true)
        let stop = request(.agentVaultCreate(agent: "seo", sha256: hash, on: false))
        #expect(try (JSONSerialization.jsonObject(with: stop.body()) as? [String: Any])?["vault_create"] as? Bool == false)
        #expect(grant.command?.label == "Let Seo save new logins" && stop.command?.label == "Stop new logins of Seo")
        for bad in [request(.agentVaultCreate(agent: "Seo!", sha256: hash, on: true)), request(.agentVaultCreate(agent: "seo", sha256: "abc", on: true)),
                    request(.agentVaultCreate(agent: "seo", sha256: hash, on: true), text: "note")] {
            #expect(throws: HubError.self) { try bad.body() }
        }
        #expect(try receipt(grant, [["field": "vault_create", "before": false, "after": true]]).matches(grant))
        #expect(try receipt(grant, []).matches(grant))                                   // it was on already
        #expect(try !receipt(grant, [["field": "vault_create", "before": true, "after": false]]).matches(grant))
        #expect(try receipt(stop, [["field": "vault_create", "before": true, "after": false]]).matches(stop))
        #expect(try !receipt(grant, [["field": "vault", "before": "none", "after": "broker"]]).matches(grant))   // nothing else may change
        #expect(try !receipt(grant, [["field": "vault_create", "before": false, "after": true]], extra: ["agent": "vps"]).matches(grant))
    }

    @Test func theControlShowsThePermissionOnlyWhenTheHubOffersItAndSaysWhyNot() {
        func control(_ role: String?, _ permitted: Bool?, offered: Bool = true, _ grant: VaultGrant? = nil) -> LoginCreateControl {
            LoginCreateControl(role: role, permitted: permitted, offered: offered, grant: grant)
        }
        #expect(control("worker", true).action == .revoke && control("lead", true).status == "Can save new logins.")
        #expect(control("worker", false, VaultGrant(ready: true, missing: [])).action == .grant)
        let waiting = control("worker", false, VaultGrant(ready: false, missing: ["no_broker_access", "helper_without_login_create",
                                                                                 "broker_status_unknown", "broker_without_creates", "other"]))
        #expect(waiting.action == nil && waiting.status == "Cannot save new logins." && waiting.reasons.count == 5)
        // The setup is on a Mac or on a Linux machine: the sentence names neither a program nor a platform.
        #expect(waiting.reasons[3] == "Set up this server's vault to save new logins." && waiting.reasons[4] == "Founderizer cannot give this permission now.")
        #expect(control("worker", false).action == nil)                                  // no readiness: no grant
        for hidden in [control("manager", true), control("worker", true, offered: false), control("worker", nil), control(nil, true)] {
            #expect(hidden.status == nil && hidden.action == nil && hidden.reasons.isEmpty)
        }
    }

    @Test func theTeamGivesThePermissionsAndTheMadeLogins() throws {
        func team(_ extra: [String: Any]) throws -> TeamSnapshot {
            let lines: [[String: Any]] = [
                ["agent": "manager", "role": "manager", "reports_to": NSNull()],
                ["agent": "pm-shop", "role": "lead", "reports_to": "manager"],
                ["agent": "seo", "role": "worker", "reports_to": "manager", "vault": "broker", "vault_create": false,
                 "vault_create_grant": ["ready": false, "missing": ["broker_without_creates"]]],
                ["agent": "studio", "role": "worker", "reports_to": "manager", "vault": "broker", "vault_create": true, "vault_create_grant": NSNull()]]
            let object: [String: Any] = ["db": "db", "revision": String(repeating: "b", count: 40), "sha256": hash, "lines": lines,
                                         "open_tasks": [String: Int]()]
            return try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: object.merging(extra) { _, b in b }))
        }
        let made: [String: Any] = ["login": reference, "label": "Shop admin", "username": "owner@example.test", "url": "https://shop.example.test",
                                   "agent": "studio", "task": "T-7", "project": "shop", "state": "created", "created_at": 1791700000,
                                   "labelled": false, "protected": true]
        let waiting = made.merging(["login": NSNull(), "state": "unknown", "project": NSNull()]) { _, b in b }
        // A key that an agent saved from a page: on another address than its use address, and on the same address.
        let page = "https://dashboard.shop.example.test/settings/keys"
        let captured = made.merging(["login": "bws://21111111-2222-4333-8444-55555555555b", "label": "Shop API key", "kind": "capture",
                                     "url": "https://api.shop.example.test/v1", "source_url": page]) { _, b in b }
        let onItsPage = made.merging(["login": "bws://31111111-2222-4333-8444-55555555555b", "kind": "capture", "source_url": NSNull()]) { _, b in b }
        let value = try team(["ignored": ["shop": ["title": "Shop", "manager": "pm-shop", "members": ["seo"], "create_logins": true],
                                           "blog": ["title": "Blog", "manager": "pm-shop", "members": ["seo"]]],
                              "created_logins": [made, waiting, captured, onItsPage, made.merging(["login": "bws://41111111-2222-4333-8444-55555555555b", "kind": "create"]) { _, b in b }]])
        let seo = try #require(value.lines.first { $0.agent == "seo" }), studio = try #require(value.lines.first { $0.agent == "studio" })
        #expect(seo.vault_create == false && seo.vault_create_grant == VaultGrant(ready: false, missing: ["broker_without_creates"]))
        #expect(studio.vault_create == true && studio.vault_create_grant == nil && value.lines[0].vault_create == nil)
        #expect(value.accounts?.isEmpty != false)
        let logins = try #require(value.created_logins)
        #expect(logins.count == 5 && logins[0].login == reference && logins[0].state == "created" && logins[0].protected && !logins[0].labelled)
        #expect(logins[1].login == nil && logins[1].project == nil && Set(logins.map(\.id)).count == 5)
        // A row without `kind` is a create of a hub before captures; it has no page.
        #expect(logins[0].kind == nil && !logins[0].isCapture && logins[0].source_url == nil && logins[0].sourcePage == nil)
        #expect(logins[2].isCapture && logins[2].url == "https://api.shop.example.test/v1" && logins[2].source_url == page && logins[2].sourcePage == page)
        #expect(logins[3].isCapture && logins[3].source_url == nil && logins[3].sourcePage == nil)      // read on its use address
        #expect(logins[4].kind == "create" && !logins[4].isCapture && logins[4].sourcePage == nil)
        let same = try JSONDecoder().decode(CreatedLogin.self, from: JSONSerialization.data(withJSONObject: captured.merging(["source_url": "https://api.shop.example.test/v1"]) { _, b in b }))
        #expect(same.source_url == same.url && same.sourcePage == nil)                               // the same address is no other page
        #expect(try team([:]).created_logins == nil)                                      // a hub without the feature
        let odd = try team(["created_logins": [["label": "no other field"]]])            // a bad list does not hide the team
        #expect(odd.created_logins == nil && odd.lines.count == 4)
    }


}
