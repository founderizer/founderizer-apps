import Foundation
import Testing
@testable import FleetCore

struct AgentSetupTests {
    private let hash = String(repeating: "a", count: 64)
    private let revision = String(repeating: "b", count: 40)
    private func decode<T: Decodable>(_ type: T.Type, _ fields: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: fields))
    }
    private func request(_ command: OwnerCommand, text: String = "") -> PendingRequest {
        PendingRequest(hub: URL(string: "http://localhost:8765")!, database: "db", client: "local", command: command, text: text)
    }

    @Test func settingsResetUsesExplicitNullsAndKeepsItsRequestAfterRelaunch() throws {
        let input = AgentSettingsInput(can: ["screen", "shell"])
        let original = request(.agentSettings(agent: "worker", sha256: hash), text: try input.payload())
        let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.route == "ui/team/agents/worker")
        #expect(restored.command?.requiredFeature == "agent_setup")
        let body = try JSONSerialization.jsonObject(with: restored.body()) as! [String: Any]
        #expect(body["model"] is NSNull && body["effort"] is NSNull)
        #expect(body["can"] as? [String] == ["shell", "screen"])
        #expect(body["base_sha256"] as? String == hash)
        #expect(!AgentSettingsInput(model: "name;command", can: []).isValid)
        #expect(!AgentSettingsInput(effort: "HIGH", can: []).isValid)
        #expect(!AgentSettingsInput(can: ["shell", "shell"]).isValid)
        let activation = request(.agentActivation(agent: "worker", sha256: hash, active: true))
        let activeBody = try JSONSerialization.jsonObject(with: activation.body()) as! [String: Any]
        #expect(activeBody["active"] as? Bool == true)
        #expect(activeBody["model"] == nil && activeBody["can"] == nil)
    }

    /// **A role goes to the agent's settings route on every hub with agent setup** (the owner's yes of 3 November 2026 to
    /// a Role field under Rename…), with its other identity fields as they were: it was gated on "projects", which no hub
    /// offers any more, so the app could not send it at all.
    @Test func aRoleIsAnAgentSettingWithItsOtherIdentityKept() throws {
        var input = AgentIdentityInput(title: "Old", expertise: ["seo"], account: nil)
        input.title = "  Acme Support "
        let original = request(.agentIdentity(agent: "iris", sha256: hash), text: try input.payload())
        let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(original))
        #expect(restored.route == "ui/team/agents/iris")
        #expect(restored.command?.requiredFeature == "agent_setup")
        let body = try JSONSerialization.jsonObject(with: restored.body()) as! [String: Any]
        #expect(body["title"] as? String == "Acme Support")
        #expect(body["expertise"] as? [String] == ["seo"])
        #expect(body["account"] is NSNull)
        #expect(body["base_sha256"] as? String == hash)
        #expect(AgentIdentityInput(title: "   ").normalized.title == nil)
    }

    @Test func modelSelectionUsesFreshMachineOptionsWithoutInventedEfforts() throws {
        func models(runtime: String = "codex", other: Bool = false) throws -> RuntimeModels {
            try decode(RuntimeModels.self, ["runtime": runtime, "ok": true, "read_at": 1000,
                "source": "local runtime", "other_names": other, "options": [
                    ["model": "sample", "display_name": "Sample", "default": true, "efforts": ["high", "ultra"]],
                    ["model": "small", "display_name": "Small", "default": false, "efforts": ["low"]]]])
        }
        let reading = try models()
        #expect(reading.supports(.init(model: "sample", effort: "ultra", can: []), at: 1100))
        #expect(reading.supports(.init(effort: "high", can: []), at: 1100))
        #expect(!reading.supports(.init(model: "small", effort: "high", can: []), at: 1100))
        #expect(!reading.supports(.init(model: "unknown", can: []), at: 1100))
        #expect(!reading.supports(.init(model: "sample", can: []), at: 100_000))
        #expect(reading.supports(.init(can: []), at: 100_000))
        let claude = try models(runtime: "claude", other: true)
        #expect(claude.supports(.init(model: "claude-full-name", effort: "high", can: []), at: 1100))
        #expect(!claude.supports(.init(model: "another-provider", can: []), at: 1100))
    }

    @Test func settingReceiptsCannotAcknowledgeAnotherAgentOrConfiguration() throws {
        let pending = request(.agentSettings(agent: "worker", sha256: hash), text: try AgentSettingsInput(model: "sample", can: ["shell"]).payload())
        var fields: [String: Any] = ["ok": true, "request_id": pending.requestID.uuidString, "client": "local", "replayed": false,
            "agent": "worker", "sha256": hash, "revision": revision, "settings_pending": true, "updates_requested": ["worker"],
            "changed": [["field": "model", "before": NSNull(), "after": "sample"]]]
        #expect(try decode(ControlReceipt.self, fields).matches(pending))
        fields["changed"] = [["field": "model", "before": NSNull(), "after": "other"]]
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        fields["changed"] = []
        #expect(try decode(ControlReceipt.self, fields).matches(pending))
        fields["updates_requested"] = ["other"]
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        fields["updates_requested"] = []; fields["agent"] = "other"
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        let activation = request(.agentActivation(agent: "worker", sha256: hash, active: true))
        fields["agent"] = "worker"; fields["request_id"] = activation.requestID.uuidString
        fields["changed"] = [["field": "active", "before": false, "after": true]]
        #expect(try !decode(ControlReceipt.self, fields).matches(activation))
        fields["activation"] = ["check": 7, "checked_at": 1000]
        #expect(try decode(ControlReceipt.self, fields).matches(activation))
        fields["changed"] = [["field": "active", "before": true, "after": false]]
        #expect(try !decode(ControlReceipt.self, fields).matches(activation))
    }

    @Test func primaryEditsAndOldDraftsPreserveScreenSettings() throws {
        let saved = AgentSettingsInput(model: "claude-example", effort: "high", can: ["shell", "screen"],
            screen: .init(model: "screen-example", effort: "low"))
        let old = try decode(AgentSettingsInput.self, ["model": "claude-example", "effort": "high", "can": ["shell", "screen"]])
        #expect(old.screen == nil && !old.differs(from: saved))
        var changed = saved; changed.model = "claude-new"
        let primaryBody = try JSONSerialization.jsonObject(with: Data(changed.changes(from: saved).payload().utf8)) as! [String: Any]
        #expect(changed.differs(from: saved))
        #expect(primaryBody["screen"] == nil)
        #expect(primaryBody["model"] as? String == "claude-new")
        changed = saved; changed.screen = .init()
        let pending = request(.agentSettings(agent: "worker", sha256: hash), text: try changed.changes(from: saved).payload())
        let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(pending))
        let body = try JSONSerialization.jsonObject(with: restored.body()) as! [String: Any]
        let screen = body["screen"] as! [String: Any]
        #expect(screen["model"] is NSNull && screen["effort"] is NSNull)
        #expect(body["model"] as? String == "claude-example")
        #expect(throws: DecodingError.self) { try decode(ScreenSettingsInput.self, ["model": "screen-example"]) }
    }

    @Test func screenReceiptMustMatchTheRequestedScreenAndNeverAcknowledgeAnOmittedChange() throws {
        let choice = ScreenSettingsInput(model: "screen-example", effort: "low")
        let pending = request(.agentSettings(agent: "worker", sha256: hash),
            text: try AgentSettingsInput(can: ["screen"], screen: choice).payload())
        var fields: [String: Any] = ["ok": true, "request_id": pending.requestID.uuidString, "client": "local", "replayed": false,
            "agent": "worker", "sha256": hash, "revision": revision, "settings_pending": true, "updates_requested": ["worker"],
            "changed": [["field": "screen", "before": ["model": NSNull(), "effort": NSNull()],
                         "after": ["model": "screen-example", "effort": "low"]]]]
        #expect(try decode(ControlReceipt.self, fields).matches(pending))
        fields["changed"] = [["field": "screen", "before": NSNull(), "after": ["model": "screen-example", "effort": "high"]]]
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        let primary = request(.agentSettings(agent: "worker", sha256: hash), text: try AgentSettingsInput(can: ["screen"]).payload())
        fields["request_id"] = primary.requestID.uuidString
        #expect(try !decode(ControlReceipt.self, fields).matches(primary))
    }

    @Test func screenOptionsAndReportedModelsStaySeparateFromThePrimaryRuntime() throws {
        let fields: [String: Any] = ["runtime": "codex", "ok": true, "read_at": 1000,
            "source": "codex app-server model/list", "other_names": false,
            "options": [["model": "screen-example", "display_name": "Screen model", "default": true, "efforts": ["low"]]]]
        let models = try decode(RuntimeModels.self, fields)
        #expect(models.supportsScreen(.init(model: "screen-example", effort: "low"), at: 1100))
        #expect(!models.supportsScreen(.init(model: "claude-example", effort: "low"), at: 1100))
        #expect(!models.supportsScreen(.init(model: "screen-example", effort: "high"), at: 1100))
        #expect(!models.supportsScreen(.init(model: "screen-example", effort: "low"), at: 100_000))
        var wrongRuntime = fields; wrongRuntime["runtime"] = "claude"
        #expect(try !decode(RuntimeModels.self, wrongRuntime).supportsScreen(.init(), at: 1100))
        let line = try decode(ReportingLine.self, ["agent": "studio", "role": "worker", "reports_to": "manager",
            "model": "claude-example", "screen": ["model": "screen-example", "effort": "low"],
            "reported_model": ["model": "claude-observed", "effort": "high", "at": 1000],
            "reported_screen_model": ["model": "screen-observed", "effort": NSNull(), "at": 1100]])
        #expect(line.model == "claude-example" && line.screen?.model == "screen-example")
        #expect(line.reported_model?.model == "claude-observed")
        #expect(line.reported_screen_model?.model == "screen-observed" && line.reported_screen_model?.effort == nil)
    }

    @Test func activationRequiresCurrentRequiredChecksAndLoadedSettings() throws {
        var item: [String: Any] = ["kind": "runtime", "ref": "codex", "state": "ok", "detail": "Signed in", "required": true]
        var fields: [String: Any] = ["agent": "worker", "machine": "sample", "role": "worker", "reported_at": 1000,
            "stale": false, "update": ["state": "current"], "runtime": [:], "security": [:], "os": [:],
            "settings_pending": false, "check": ["id": 7, "state": "completed", "requested_at": 999, "completed_at": 1000]]
        func permits(time: Double = 1100, revision: String? = nil, holds: Bool? = nil) throws -> Bool {
            var all = fields
            var verify: [String: Any] = ["check": 7, "checked_at": 1000, "revision": self.revision, "items": [item]]
            if let holds { verify["holds"] = holds }        // an older hub sends none
            all["verify"] = verify
            let machine = try decode(MachineStatus.self, all)
            return machine.verify!.permitsActivation(machine: machine, desiredRevision: revision ?? self.revision, at: time)
        }
        #expect(try permits())
        fields["settings_pending"] = true; #expect(try !permits())
        fields["settings_pending"] = false
        #expect(try !permits(revision: String(repeating: "c", count: 40)))
        // The hub's current state also accepts a documentation-only commit difference.
        fields["revision"] = revision
        #expect(try permits(revision: String(repeating: "c", count: 40)))
        // The hub's own answer decides (owner API 1.80): its check holds across a commit that changed nothing it saw,
        // also once the machine took that commit, and a check that the hub no longer takes is not activated.
        fields["revision"] = String(repeating: "d", count: 40)
        #expect(try !permits(revision: String(repeating: "c", count: 40)))
        #expect(try permits(revision: String(repeating: "c", count: 40), holds: true))
        fields["revision"] = revision
        #expect(try !permits(holds: false))
        fields["update"] = ["state": "behind"]
        #expect(try !permits(revision: String(repeating: "c", count: 40)))
        #expect(try !permits(holds: true))
        fields["update"] = ["state": "current"]
        item["state"] = "not_verified"; #expect(try !permits())
        item["required"] = false; #expect(try permits())
        item.removeValue(forKey: "required"); #expect(try !permits())
        item["required"] = true; item["state"] = "ok"
        #expect(try !permits(time: 1600))
        fields["reported_at"] = 5000; #expect(try !permits(time: 5000))
        fields["reported_at"] = 1000; fields["check"] = ["id": 8, "state": "requested", "requested_at": 1001]
        #expect(try !permits())
    }

    @Test func actualModelsStayWithTheirAttemptAndNeverComeFromRequestedValues() throws {
        func event(_ id: Int, _ extras: [String: Any]) throws -> RuntimeEvent {
            try decode(RuntimeEvent.self, ["id": id, "attempt": 1, "session": "root", "seq": id, "type": "model",
                "requested_model": "sample", "requested_effort": "high"].merging(extras) { _, new in new })
        }
        var timeline = ActivityTimeline()
        let first = try event(1, [:])
        timeline.append([first, first, try event(2, ["model": "other", "parent": "child"]),
            try event(3, ["attempt": 2, "session": "retry", "model": "other", "effort": "low"])])
        #expect(timeline.models.count == 2)
        #expect(timeline.models[0].model == nil && timeline.models[0].effort == nil)
        #expect(!timeline.models[0].differs)
        #expect(timeline.models[1].attempt == 2 && timeline.models[1].session == "retry")
        #expect(timeline.models[1].differs)
    }

    @Test func eachSettingSendsOnlyItsFieldAgainstTheNewestTeam() throws {
        let team = try decode(TeamSnapshot.self, ["db": "db", "revision": revision, "sha256": hash, "open_tasks": ["busy": 1], "lines": [
            ["agent": "manager", "role": "manager", "reports_to": NSNull()],
            ["agent": "lead", "role": "lead", "reports_to": "manager"],
            ["agent": "worker", "role": "worker", "reports_to": "manager", "model": "sample", "effort": "high", "can": ["shell", "web"],
             "screen": ["model": NSNull(), "effort": NSNull()]],
            ["agent": "busy", "role": "worker", "reports_to": "manager"]]])
        func body(_ edit: AgentSettingEdit, agent: String = "worker", can: [String] = []) throws -> [String: Any] {
            let sent = try edit.request(agent: agent, team: team, can: can)
            #expect(sent.command == .agentSettings(agent: agent, sha256: hash))
            return try JSONSerialization.jsonObject(with: request(sent.command, text: sent.payload).body()) as! [String: Any]
        }
        // The model with its reasoning; the capabilities as saved, and the desktop settings left out.
        let model = try body(.model("small", effort: nil))
        #expect(model["model"] as? String == "small" && model["effort"] is NSNull && model["can"] as? [String] == ["shell", "web"])
        #expect(model["screen"] == nil)
        // The capabilities carry the saved model and reasoning again.
        let can = try body(.capabilities(["web", "browser", "shell"]))
        #expect(can["model"] as? String == "sample" && can["effort"] as? String == "high" && can["can"] as? [String] == ["shell", "web", "browser"])
        let screen = try body(.screen(.init(model: "screen-example", effort: "low")))
        #expect((screen["screen"] as? [String: Any])?["model"] as? String == "screen-example" && screen["model"] as? String == "sample")
        // A line without capabilities (an older hub) takes the agent's.
        #expect(try body(.model(nil, effort: nil), agent: "busy", can: ["shell"])["can"] as? [String] == ["shell"])
        #expect(throws: SettingProblem(words: "The hub does not take this value.")) {
            try AgentSettingEdit.model("name;command", effort: nil).request(agent: "worker", team: team, can: [])
        }

        // The position goes with the reporting lines: only this agent's line changes.
        let parent = try AgentSettingEdit.reportsTo("lead").request(agent: "worker", team: team, can: [])
        #expect(parent.command == .teamLines(sha256: hash))
        let lines = try JSONDecoder().decode(TeamLinesInput.self, from: Data(parent.payload.utf8)).lines
        #expect(lines.map(\.agent) == ["manager", "lead", "worker", "busy"])
        #expect(lines.map(\.reports_to) == [nil, "manager", "lead", "manager"] && lines.map(\.role) == ["manager", "lead", "worker", "worker"])
        #expect(throws: SettingProblem(words: "Busy has open tasks. Change its role when those tasks end.")) {
            try AgentSettingEdit.role("lead").request(agent: "busy", team: team, can: [])
        }
        #expect(throws: SettingProblem(words: "Unknown is not in the team now.")) {
            try AgentSettingEdit.role("lead").request(agent: "unknown", team: team, can: [])
        }
    }

    @Test func aChangeElsewhereOfTheSameFieldIsFoundAndOfAnotherFieldIsNot() {
        var before = ReportingLine(agent: "worker", role: "worker", reports_to: "manager")
        before.model = "sample"; before.effort = "high"; before.can = ["shell"]
        var after = before
        after.can = ["web", "shell"]
        #expect(AgentSettingEdit.changed(.capabilities, from: before, to: after))
        #expect(!AgentSettingEdit.changed(.model, from: before, to: after) && !AgentSettingEdit.changed(.screen, from: before, to: after))
        after.effort = "low"
        #expect(AgentSettingEdit.changed(.model, from: before, to: after))
        #expect(!AgentSettingEdit.changed(.role, from: before, to: after) && !AgentSettingEdit.changed(.reportsTo, from: before, to: after))
        // A value that the line has already needs no request.
        #expect(AgentSettingEdit.capabilities(["shell", "web"]).isSaved(in: after, can: []))
        #expect(!AgentSettingEdit.model("sample", effort: "high").isSaved(in: after, can: []))
        #expect(AgentSettingEdit.capabilities(["browser"]).isSaved(in: ReportingLine(agent: "worker", role: "worker", reports_to: "manager"), can: ["browser"]))
    }

    @Test func aNewModelKeepsTheReasoningOnlyWhenItOffersIt() throws {
        let reading = try decode(RuntimeModels.self, ["runtime": "codex", "ok": true, "read_at": 1000, "source": "local runtime",
            "other_names": false, "options": [
                ["model": "sample", "display_name": "Sample", "default": true, "efforts": ["high", "ultra"]],
                ["model": "small", "display_name": "Small", "default": false, "efforts": ["low"]]]])
        #expect(reading.effort("high", with: "sample") == "high")
        #expect(reading.effort("high", with: "small") == nil)                      // the model's default
        #expect(reading.effort("ultra", with: nil) == "ultra")                     // the runtime's default model offers it
        #expect(reading.effort(nil, with: "small") == nil)
    }

    @Test func aReportingLineSendsItsPositionOnly() throws {
        var line = ReportingLine(agent: "worker", role: "worker", reports_to: "manager")
        line.active = false; line.model = "sample"; line.can = ["shell"]
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(line)) as! [String: Any]
        #expect(Set(body.keys) == ["agent", "role", "reports_to"])
    }
}
