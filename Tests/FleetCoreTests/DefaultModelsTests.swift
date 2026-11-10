import Foundation
import Testing
@testable import FleetCore

/// Owner feature `default_models` (owner API 1.108): the Default models section's reading and write, and what an
/// agent's first option says.
struct DefaultModelsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ fields: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: fields))
    }
    private let luna: [String: Any] = ["model": "gpt-6-luna", "display_name": "GPT-6-Luna", "default": true,
                                       "efforts": ["low", "medium", "high"], "default_effort": "medium"]
    private let terra: [String: Any] = ["model": "gpt-5.6-terra", "display_name": "GPT-5.6-Terra", "default": false,
                                        "efforts": ["low", "ultra"], "default_effort": "low"]
    private func claude(_ name: String) -> [String: Any] {
        ["model": name, "display_name": name.capitalized, "default": false, "efforts": ["low", "high", "max"],
         "default_effort": NSNull()]
    }
    private func reading(_ runtime: String, _ options: [[String: Any]], ok: Bool = true) throws -> RuntimeModels {
        try decode(RuntimeModels.self, ["runtime": runtime, "ok": ok, "read_at": 1000, "source": "test",
                                        "other_names": runtime == "claude", "error": NSNull(), "options": options])
    }

    @Test func aReasoningLevelHasTheOwnersName() {
        #expect(["low", "medium", "high", "xhigh", "max", "ultra"].map(reasoningName)
                == ["Low", "Medium", "High", "Extra high", "Max", "Ultra"])
        #expect(automaticChoice == "Automatic")
    }

    @Test func thePageReadsEachProvidersDefaultAndItsServersModels() throws {
        let page = try decode(DefaultModelsPage.self, [
            "db": "db",
            "settings": ["model_changes": ["value": true, "default": true, "set": false, "about": "x"]],
            "runtime_facts": [
                "claude": ["default_model": ["value": ["model": "opus", "effort": "high"], "default": NSNull(), "set": true],
                           "token_weights": ["value": ["default": ["input": 1]], "default": NSNull(), "set": false]],
                "codex": ["default_model": ["value": NSNull(), "default": NSNull(), "set": false]],
                "grok": ["routine": ["value": NSNull(), "default": NSNull(), "set": false]],
                "gemini": ["default_model": ["value": ["model": NSNull(), "effort": "low"], "default": NSNull(), "set": true]]],
            "models": ["codex": [luna, terra], "claude": [claude("opus"), claude("sonnet")], "grok": []]])
        #expect(page.defaults == ["claude": ModelDefault(model: "opus", effort: "high"),
                                  "gemini": ModelDefault(effort: "low")])
        // Claude Code first, Codex second; a provider with no models but a default keeps its row; one with neither none
        #expect(page.runtimes == ["claude", "codex", "gemini"])
        #expect(page.efforts("codex", for: nil) == ["low", "medium", "high"])          // the list's default model
        #expect(page.efforts("codex", for: "gpt-5.6-terra") == ["low", "ultra"])
        #expect(page.efforts("claude", for: nil) == ["low", "high", "max"])             // no default: every model
        let older = try decode(DefaultModelsPage.self, ["db": "db"])                    // a hub without the feature
        #expect(older.runtimes.isEmpty)
    }

    @Test func aDefaultIsSentWithBothKeysAndAnEmptyOneTakesItAway() throws {
        let set = try JSONSerialization.jsonObject(with: DefaultModelsClient.body(
            runtime: "claude", value: ModelDefault(model: "opus"), requestID: "r", database: "db")) as! [String: Any]
        let fact = ((set["runtime_facts"] as! [String: Any])["claude"] as! [String: Any])["default_model"] as! [String: Any]
        #expect(fact["model"] as? String == "opus")
        #expect(fact["effort"] is NSNull)
        #expect(set["request_id"] as? String == "r" && set["db"] as? String == "db")
        let cleared = try JSONSerialization.jsonObject(with: DefaultModelsClient.body(
            runtime: "codex", value: ModelDefault(), requestID: "r", database: "db")) as! [String: Any]
        #expect(((cleared["runtime_facts"] as! [String: Any])["codex"] as! [String: Any])["default_model"] is NSNull)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ModelDefault(effort: "high"))) as! [String: Any]
        #expect(encoded["model"] is NSNull && encoded["effort"] as? String == "high")
    }

    @Test func anAgentFollowsTheDefaultOnlyWhereItsServerTakesIt() throws {
        let codex = try reading("codex", [luna, terra])
        let chosen = ModelDefault(model: "gpt-5.6-terra", effort: "ultra")
        func runs(_ value: ModelDefault?, _ model: String? = nil, _ effort: String? = nil, machine: RuntimeModels? = nil,
                  runtime: String = "codex", takes: Bool = true) -> ModelDefault {
            DefaultModels.session(value, model: model, effort: effort, machine: machine ?? codex, runtime: runtime, takes: takes)
        }
        #expect(runs(chosen) == chosen)
        // its own model: only the default's effort, where that model offers it
        #expect(runs(chosen, "gpt-6-luna") == ModelDefault(model: "gpt-6-luna"))
        #expect(runs(ModelDefault(effort: "high"), "gpt-6-luna") == ModelDefault(model: "gpt-6-luna", effort: "high"))
        // its own effort stays its own where the model it gets offers it, and gives way where it does not
        #expect(runs(chosen, nil, "low") == ModelDefault(model: "gpt-5.6-terra", effort: "low"))
        #expect(runs(ModelDefault(model: "gpt-6-luna"), nil, "ultra") == ModelDefault(model: "gpt-6-luna"))
        #expect(runs(ModelDefault(model: "gpt-6-luna", effort: "high"), nil, "ultra") == ModelDefault(model: "gpt-6-luna", effort: "high"))
        #expect(runs(nil, nil, "ultra") == ModelDefault())                          // the list's default has no ultra
        #expect(runs(nil, "gpt-5.6-terra", "ultra") == ModelDefault(model: "gpt-5.6-terra", effort: "ultra"))
        // a model that its server does not list, a helper that does not take defaults yet, another runtime's list
        #expect(runs(ModelDefault(model: "gpt-9")) == ModelDefault())
        #expect(runs(chosen, takes: false) == ModelDefault())
        #expect(runs(chosen, runtime: "claude") == ModelDefault())
        #expect(runs(chosen, machine: try reading("codex", [luna], ok: false)) == ModelDefault())
        #expect(runs(chosen, "gpt-6-luna", "low", takes: false) == ModelDefault(model: "gpt-6-luna", effort: "low"))
        // Claude: a full name it takes unlisted, and an effort with its own default model
        let claudeList = try reading("claude", [claude("opus")])
        #expect(runs(ModelDefault(model: "claude-opus-5-5", effort: "max"), machine: claudeList, runtime: "claude")
                == ModelDefault(model: "claude-opus-5-5", effort: "max"))
        #expect(runs(ModelDefault(effort: "high"), machine: claudeList, runtime: "claude") == ModelDefault(effort: "high"))
        #expect(runs(nil, machine: claudeList, runtime: "claude") == ModelDefault())
    }

    @Test func theTeamReadingCarriesTheDefaults() throws {
        let line: [String: Any] = ["agent": "manager", "role": "manager", "reports_to": NSNull(), "machine": "hub",
                                   "runtime": "claude"]
        var fields: [String: Any] = ["db": "db", "revision": String(repeating: "b", count: 40),
                                     "sha256": String(repeating: "a", count: 64), "lines": [line], "open_tasks": [:]]
        #expect(try decode(TeamSnapshot.self, fields).default_models.isEmpty)
        fields["default_models"] = ["claude": ["model": "opus", "effort": "high"]]
        #expect(try decode(TeamSnapshot.self, fields).default_models == ["claude": ModelDefault(model: "opus", effort: "high")])
        fields["default_models"] = ["claude": "opus"]               // a shape it cannot read never hides the team
        #expect(try decode(TeamSnapshot.self, fields).default_models.isEmpty)
    }
}
