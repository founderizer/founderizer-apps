import Foundation
import Testing
@testable import FleetCore

/// Add agent on an existing machine (owner API 1.12). Synthetic data only: no hub, no executor run, no machine.
struct AgentPlacementTests {
    /// The contract's example: a machine whose only agent has no key yet.
    private let worker4: [String: Any] = [
        "address": "100.96.1.50", "agents": ["worker4"], "ssh": ["user": "root", "port": 22], "worker_user": "fleet",
        "runtimes": ["codex": ["version": "codex-cli 0.160.0", "signed_in": true]],
        "add_agent": ["ready": false, "missing": ["agent_without_key:worker4"]]]

    private func machine(ready: Bool, missing: [String] = [], agents: [String] = ["studio"], runtimes: [String: Any] = [:]) -> [String: Any] {
        ["address": "100.96.100.4", "agents": agents, "ssh": ["user": "sam", "port": 22], "worker_user": "sam",
         "runtimes": runtimes, "add_agent": ["ready": ready, "missing": missing]]
    }

    private func team(_ machines: Any?) throws -> TeamSnapshot {
        var object: [String: Any] = [
            "db": "db", "revision": String(repeating: "b", count: 40), "sha256": String(repeating: "a", count: 64), "open_tasks": [:],
            "lines": [["agent": "manager", "role": "manager", "reports_to": NSNull()], ["agent": "studio", "role": "worker", "reports_to": "manager"]]]
        if let machines { object["machines"] = machines }
        let snapshot = try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        try snapshot.validate(database: "db")
        return snapshot
    }

    private func event(_ fields: String) throws -> SetupEvent { try JSONDecoder().decode(SetupEvent.self, from: Data(fields.utf8)) }

    @Test func theTeamCarriesItsMachinesAndAnUnreadableEntryNeverHidesTheTeam() throws {
        #expect(try team(nil).machines == nil)                                        // a hub before 1.12
        let reported = try #require(try team(["worker4": worker4]).machines?["worker4"])
        #expect(reported.ssh == TeamMachine.SSH(user: "root", port: 22) && reported.worker_user == "fleet" && reported.agents == ["worker4"])
        #expect(reported.runtimes["codex"] == TeamMachine.Runtime(version: "codex-cli 0.160.0", signed_in: true))
        #expect(reported.add_agent == TeamMachine.Readiness(ready: false, missing: ["agent_without_key:worker4"]))
        let broken = try team(["worker4": ["agents": "worker4"]])
        #expect(broken.machines == nil && broken.lines.count == 2)
    }

    @Test func onlyTheHubsReadinessDecidesAndMixedRolesCanShareAMachine() throws {
        let machines = try #require(try team([
            "worker4": worker4,
            "hub": machine(ready: true, agents: ["manager", "shop-pm"], runtimes: ["claude": ["version": "2.1.296", "signed_in": true]]),
            "lab": machine(ready: false),
            "old": ["agents": ["old"], "runtimes": [:]],
            "-x": machine(ready: true)]).machines)
        let choices = AgentPlacement.choices(machines)
        #expect(choices.map(\.machine) == ["-x", "hub", "lab", "old", "worker4"])
        let hub = try #require(choices.first { $0.machine == "hub" })
        #expect(hub.isReady && hub.agents == ["manager", "shop-pm"] && hub.preferredRuntime == "claude")   // no role or project filter
        #expect(choices.first { $0.machine == "worker4" }?.reasons == ["Worker4 has no agent key yet."])
        for name in ["lab", "old"] {
            #expect(choices.first { $0.machine == name }?.reasons == ["Founderizer has not confirmed that this server can take another agent."])
        }
        #expect(choices.first { $0.machine == "-x" }?.reasons == ["Founderizer cannot use this server name."])
    }

    @Test func aReadyMachineWithNoRuntimeReadingStaysReadyAndTheExecutorChecksTheChoice() throws {
        let machines = try #require(try team(["mac-studio": machine(ready: true)]).machines)
        let studio = try #require(AgentPlacement.choices(machines).first)
        #expect(studio.isReady && studio.preferredRuntime == nil)
        #expect(studio.runtimes == ["codex", "claude"].map { PlacementChoice.RuntimeOption(runtime: $0, signedIn: nil) })
        #expect(studio.runtimes.allSatisfy { $0.status == "Status unknown. Setup checks this server." })
        #expect(AgentPlacement.problem(name: "seo", on: studio, existing: ["manager", "studio"], resume: false) == nil)
    }

    @Test func eachRuntimeShowsWhatItsMachineReportedAndNothingMore() throws {
        let machines = try #require(try team(["mac-studio": machine(ready: true, runtimes: [
            "codex": ["version": "codex-cli 0.160.0", "signed_in": false],
            "claude": ["version": "2.1.296", "signed_in": NSNull()],
            "grok": ["signed_in": true]])]).machines)
        let studio = try #require(AgentPlacement.choices(machines).first)
        #expect(studio.runtimes.map(\.runtime) == ["codex", "claude"])                    // only what the executor supports
        #expect(studio.runtimes[0].status == "Not signed in. Setup checks again.")
        #expect(studio.runtimes[1].status == "Status unknown. Setup checks this server.")   // a version alone is not a sign-in
        #expect(studio.preferredRuntime == nil)                                        // no runtime is known to be signed in
        let both = try #require(try team(["vps": machine(ready: true, runtimes: [
            "codex": ["signed_in": false], "claude": ["signed_in": true]])]).machines)
        let vps = try #require(AgentPlacement.choices(both).first)
        #expect(vps.preferredRuntime == "claude" && vps.runtimes[1].status == "Signed in.")
    }

    @Test func theReasonsAreOrdinaryWordsAndAskForNoAccessChange() {
        let codes = ["no_ssh", "ssh_user_not_allowed", "worker_user_unknown", "agent_without_key:worker4", "helper_without_agent_key:vps",
                     "legacy_windows:manager", "helper_offline:studio", "broker_machine", "owner_address", "a_new_code:x"]
        let texts = codes.map(AgentPlacement.reason)
        #expect(Set(texts).count == texts.count)
        #expect(texts[5] == "Manager has sessions from before the update. Founderizer keeps them working until their next normal start.")
        #expect(texts[7] == "Its vault broker cannot use agent keys yet.")
        #expect(texts[9] == "This server is not ready for another agent.")
        #expect(AgentPlacement.reason("legacy_windows_unknown:studio") == "Founderizer could not check the sessions of Studio. It checks again when Studio next reports.")
        // His words for a helper (review B11, fix round 2): Founderizer on a server, and a silent one "is not answering".
        #expect(texts[4] == "Founderizer on Vps's server does not use agent keys yet.")
        #expect(texts[6] == "Studio is not answering.")
        for text in texts + [AgentPlacement.reason("legacy_windows_unknown:studio")] { #expect(!text.contains("helper")) }
        for text in texts {
            #expect(!text.contains("_") && !text.contains(":"))
            for word in ["permission", "sign in", "sign-in", "log in", "login", "grant", "sudo", "install"] {
                #expect(!text.lowercased().contains(word))
            }
        }
    }

    @Test func addAgentNeedsTheHubFeatureAndAnExecutorThatSupportsIt() throws {
        let current = try JSONDecoder().decode(SetupExecutor.self, from: Data(#"{"v": 1, "type": "version", "executor": "1.0.0"}"#.utf8))
        let next = try JSONDecoder().decode(SetupExecutor.self, from: Data(#"{"v": 1, "type": "version", "executor": "1.1.0", "capabilities": ["existing_machine"]}"#.utf8))
        let other = try JSONDecoder().decode(SetupExecutor.self, from: Data(#"{"v": 2, "type": "version", "executor": "2.0.0", "capabilities": ["existing_machine"]}"#.utf8))
        #expect(!current.supportsExistingMachine && next.supportsExistingMachine && !other.supportsExistingMachine)
        #expect(AgentPlacement.isOffered(features: ["machines", "agent_auth"], executor: next))
        #expect(!AgentPlacement.isOffered(features: ["machines"], executor: next))
        #expect(!AgentPlacement.isOffered(features: ["agent_auth"], executor: current))
        #expect(!AgentPlacement.isOffered(features: ["agent_auth"], executor: nil))
        #expect(!AgentPlacement.isOffered(features: nil, executor: next))
        #expect(try JSONDecoder().decode(SetupExecutor.self, from: JSONEncoder().encode(next)) == next)   // the helper's checked copy
    }

    @Test func anExistingMachineRunSendsOnlyTheContractArguments() throws {
        var config = ServerConfiguration()
        config.existingMachine = "mac-studio"; config.name = "seo"; config.runtime = "claude"
        try config.validate()                                                          // no host, port or login
        #expect(Array(config.arguments.prefix(3)) == ["run", "--json", "--auth"] && config.arguments.contains("--hub") && config.arguments.contains("--repo"))
        #expect(Array(config.arguments.suffix(6)) == ["--existing-machine", "mac-studio", "--name", "seo", "--runtime", "claude"])
        for refused in ["--host", "--port", "--login", "--runtime-version", "--tailscale", "--tailscale-tag", "--config"] {
            #expect(!config.arguments.contains(refused))
        }
        config.auth = "identity"; config.identityFile = "/Users/owner/.ssh/sam key"
        try config.validate()
        #expect(Array(config.arguments.suffix(2)) == ["--identity-file", "/Users/owner/.ssh/sam key"])
        let sent = try JSONDecoder().decode(ServerConfiguration.self, from: JSONEncoder().encode(config))   // through the setup helper
        #expect(sent.existingMachine == "mac-studio" && sent.arguments == config.arguments)
        for bad in ["-oProxyCommand=id", "mac studio", "", "../x"] {
            config.existingMachine = bad
            #expect(throws: SetupError.self) { try config.validate() }
        }
    }

    @Test func aSavedSetupResumesByNameWithoutAReadyMachine() throws {
        // After the app quits during a run, the half-installed agent can be registered and its machine not ready.
        let waiting = PlacementChoice(machine: "mac-studio", agents: ["seo", "studio"], runtimes: [], reasons: ["The helper of Seo is offline."])
        let existing: Set<String> = ["manager", "seo", "studio"]
        #expect(AgentPlacement.problem(name: "seo", on: nil, existing: existing, resume: true) == nil)
        #expect(AgentPlacement.problem(name: "seo", on: waiting, existing: existing, resume: true) == nil)
        #expect(AgentPlacement.problem(name: "seo", on: waiting, existing: existing, resume: false) == "Select a ready server.")
        #expect(AgentPlacement.problem(name: "../seo", on: nil, existing: [], resume: true)?.hasPrefix("Use a name") == true)
        var config = ServerConfiguration()
        config.name = "seo"; config.resume = true                                     // the form sends only the name
        try config.validate()
        #expect(Array(config.arguments.prefix(3)) == ["run", "--json", "--auth"] && Array(config.arguments.suffix(2)) == ["--resume", "seo"])
        for absent in ["--existing-machine", "--host", "--port", "--login", "--name", "--runtime"] { #expect(!config.arguments.contains(absent)) }
        config.existingMachine = "mac-studio"                                         // a machine selected before the switch
        try config.validate()
        #expect(Array(config.arguments.suffix(2)) == ["--resume", "seo"] && !config.arguments.contains("--existing-machine"))
        config.auth = "identity"; config.identityFile = "/Users/owner/.ssh/sam key"
        try config.validate()
        #expect(Array(config.arguments.suffix(4)) == ["--resume", "seo", "--identity-file", "/Users/owner/.ssh/sam key"])
    }

    @Test func theResultNamesTheAddedAgentAndOnlyAValidName() throws {
        var timeline = SetupTimeline()
        try timeline.append(event(#"{"v":1,"run":"one","seq":1,"type":"step","id":"agent_key","title":"Create the agent key","status":"done"}"#))
        let ok = #"{"v":1,"run":"one","seq":2,"type":"result","status":"ok","summary":"Added seo.","machine":{"name":"mac-studio","host":"100.96.100.4","port":22,"login":"sam","worker_user":"sam"},"agent":{"name":"seo","machine":"mac-studio","runtime":"claude","checkout":"~/fleet-seo","service":"fleet-seo","registration_commit":"0123456789abcdef0123456789abcdef01234567","active":false,"vault":"none"}}"#
        #expect(throws: SetupError.self) { try timeline.append(event(ok.replacingOccurrences(of: #""name":"seo""#, with: #""name":"../seo""#))) }
        #expect(try JSONDecoder().decode(SetupEvent.self, from: JSONEncoder().encode(event(ok))) == event(ok))   // through the setup helper
        try timeline.append(event(ok))
        let agent = try #require(timeline.result?.agent)
        #expect(agent.name == "seo" && agent.active == false && agent.vault == "none" && timeline.result?.machine?.worker_user == "sam")
    }

    @Test func aNewAgentNeedsAReadyMachineAndAnUnusedValidName() {
        let options = ["codex", "claude"].map { PlacementChoice.RuntimeOption(runtime: $0, signedIn: nil) }
        let ready = PlacementChoice(machine: "mac-studio", agents: ["studio"], runtimes: options, reasons: [])
        let waiting = PlacementChoice(machine: "worker4", agents: ["worker4"], runtimes: options, reasons: ["Worker4 has no agent key yet."])
        let existing: Set<String> = ["manager", "studio", "worker4"]
        #expect(AgentPlacement.problem(name: "seo", on: ready, existing: existing, resume: false) == nil)
        #expect(AgentPlacement.problem(name: "seo", on: nil, existing: existing, resume: false) == "Select a ready server.")
        #expect(AgentPlacement.problem(name: "seo", on: waiting, existing: existing, resume: false) == "Select a ready server.")
        #expect(AgentPlacement.problem(name: "studio", on: ready, existing: existing, resume: false) == "An agent with this name exists.")
        for bad in ["s", "SEO", "seo_1", "1seo", "-seo", String(repeating: "a", count: 32)] {
            #expect(AgentPlacement.problem(name: bad, on: ready, existing: existing, resume: false)?.hasPrefix("Use a name") == true)
        }
    }
}
