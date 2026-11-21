import Foundation
import Testing
@testable import FleetCore

/// **The vectors of the first run and the agent setup on the owner's computer** (windows-app-plan-v2.md, 5.6, piece L4):
/// what the Windows app's library (`windows/Founderizer.Setup/FirstRun` and `Agents`, `windows/Founderizer.Owner/Reads`)
/// must say and decide, made by FleetCore's own code for fixed example inputs.
///
/// - `setup-words.json`: each sentence of the first run and of the agent setup that FleetCore holds, with its slots
///   filled by examples: the slider's steps, the counts, the steps on Back's line, the build page's rows, the agent
///   setup's pages and its words of a stop, a machine's sign-in and its line, the words of Start again, the hand-over,
///   the manager's first pages, and the manager's name. The readings it decides from are example answers of the hub's
///   routes (`GET /ui/servers`, `GET /ui/machines`), which the C# decodes too. A sentence that only a view file of the
///   Mac holds is not here: the writer reaches FleetCore alone.
/// - `remote-password.json`: the program that puts the app's key on a server with a password once (`PasswordOnce.addKey`,
///   the command of the call and its marks), and the proof of the key alone.
///
/// The words are English on a Mac of any language. With `FOUNDERIZER_VECTORS_OUT` set, the test writes the two files into
/// that folder (`app/vectors/make_vectors.py` does, and its `--check` compares); without it, it holds the committed files
/// equal to what FleetCore gives now.
struct SetupWordsVectorsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")
    static let wordsFile = "setup-words.json"
    static let passwordFile = "remote-password.json"
    static let madeBy = "app/Tests/FleetCoreTests/SetupWordsVectorsTests.swift"

    static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - The example readings, as the hub sends them

    /// One machine of `GET /ui/machines`, with the fields that the Mac requires and the ones that the setup reads.
    static func machine(runtime: String = "claude", signedIn: Bool? = false, login: String? = nil, stale: Bool = false) -> String {
        let signed = signedIn.map { $0 ? "true" : "false" } ?? "null"
        return """
        {"agent": "juno", "machine": "worker-1", "role": "manager", "update": {"state": "current"}, "security": {},
         "runtime": {"name": "\(runtime)", "version": "2.1.0", "signed_in": \(signed)}, "os": {"name": "Ubuntu 24.04"},
         "reported_at": 1763700000, "stale": \(stale)\(login.map { ", \"login\": \($0)" } ?? "")}
        """
    }

    static func login(_ state: String, runtime: String = "claude", url: String? = nil, code: String? = nil, wants: Bool = true,
                      detail: String? = nil, timedOut: Bool? = nil) -> String {
        var fields = ["\"id\": 7", "\"runtime\": \"\(runtime)\"", "\"state\": \"\(state)\"", "\"started_at\": 1763700000",
                      "\"updated_at\": 1763700060", "\"wants_code\": \(wants)"]
        if let url { fields.append("\"url\": \"\(url)\"") }
        if let code { fields.append("\"shows_code\": \"\(code)\"") }
        if let detail { fields.append("\"detail\": \"\(detail)\"") }
        if let timedOut { fields.append("\"timed_out\": \(timedOut)") }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    static func job(_ state: String, kind: String = "install", runtime: String = "claude", step: String? = nil,
                    detail: String? = nil, timedOut: Bool? = nil, prompt: String? = nil) -> String {
        var fields = ["\"id\": 12", "\"kind\": \"\(kind)\"", "\"agent\": \"juno\"", "\"runtime\": \"\(runtime)\"",
                      "\"state\": \"\(state)\"", "\"created\": 1763700000", "\"updated\": 1763700060"]
        if let step { fields.append("\"step\": \"\(step)\"") }
        if let detail { fields.append("\"detail\": \"\(detail)\"") }
        if let timedOut { fields.append("\"timed_out\": \(timedOut)") }
        if let prompt { fields.append("\"prompt\": \(prompt)") }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// A `GET /ui/servers` of one hub's server and one other, with the kept step and the hub's own server's state.
    static func servers(kept: String?, hubShared: Bool?, hubJoined: Bool, hubAvailable: Bool) -> String {
        let shape = kept.map { "\"shape\": {\"step\": \"\($0)\"}, " } ?? ""
        let shared = hubShared.map { "\"hub_shared\": \($0), " } ?? ""
        return """
        {"db": "db-1", "time": 1763700100, \(shape)\(shared)"servers": [
          {"name": "worker-1", "hub": true, "joined": \(hubJoined), "agents": [], "available": \(hubAvailable), "why": []},
          {"name": "worker-2", "hub": false, "joined": true, "agents": [], "available": true, "why": []}]}
        """
    }

    // MARK: - setup-words.json

    static let hubPlan = InstallPlan.hub(target: InstallTarget(host: "server"), source: "", authKey: nil).steps.map(\.id)
    static let joinPlan = InstallPlan.join(target: InstallTarget(host: "server"), line: "", code: "", authKey: nil).steps.map(\.id)

    static func row(_ row: FleetBuildRow) -> [String: Any] {
        ["words": orNull(row.words), "minutes": orNull(row.minutes), "parts": orNull(row.parts), "owners_turn": row.ownersTurn]
    }

    static func pageName(_ page: AgentSetupPage) -> [String: Any] {
        switch page {
        case .name: ["page": "name"]
        case .servers: ["page": "servers"]
        case .server: ["page": "server"]
        case .provider: ["page": "provider"]
        case .installing(let runtime): ["page": "installing", "runtime": runtime]
        case .switching(let runtime): ["page": "switching", "runtime": runtime]
        case .signIn(let runtime): ["page": "signIn", "runtime": runtime]
        case .activate: ["page": "activate"]
        }
    }

    static func wordsDocument() throws -> [String: Any] {
        let steps = ServersStep.allCases.map { step -> [String: Any] in
            ["step": step.rawValue, "fact": step.fact, "risk": step.risk, "means": step.means, "first_press": step.firstPress,
             "managers_own_server": step.managersOwnServer, "words": ServersSketch.words(step)]
        }
        let counts = [(1, 0), (2, 0), (4, 0), (6, 1), (3, 2)].map { servers, macs -> [String: Any] in
            let count = FleetCount(servers: servers, macs: macs)
            return ["servers": servers, "macs": macs, "server_words": count.serverWords, "words": count.words]
        }
        let pages = ["welcome", "errorReports", "name", "aiProvider", "servers", "network", "key", "cloud", "token", "vps",
                     "machine", "building", "installing", "done"]
        let firstRunOf = pages.flatMap { page in [true, false].map { named -> [String: Any] in
            ["page": page, "named": named, "step": orNull(FirstRunSteps.of(page: page, named: named)?.name)]
        } }
        let setupPages: [AgentSetupPage] = [.name, .servers, .server, .provider, .installing(runtime: "claude"),
                                            .switching(runtime: "codex"), .signIn(runtime: "claude"), .activate]
        let managerCurrent = setupPages.map { page -> [String: Any] in
            pageName(page).merging(["current": ManagerSetupSteps.current(page)]) { first, _ in first }
        }
        let phases = InstallPhases(steps: [], planned: hubPlan, runningFor: 0)
        let rows: [[String: Any]] = [
            ["name": "building", "row": row(.building(joining: false, plan: hubPlan))],
            ["name": "joining", "row": row(.building(joining: true, plan: hubPlan))],
            ["name": "waits for the hub", "row": row(.waitsForHub(plan: joinPlan))],
            ["name": "starting after a build", "row": row(.starting(plan: joinPlan, afterBuild: true))],
            ["name": "starting", "row": row(.starting(plan: hubPlan, afterBuild: false))],
            ["name": "setting up", "row": row(.settingUp("Claude Code"))],
            ["name": "sign-in", "row": row(.signIn)],
            ["name": "ready", "row": row(.ready)],
        ] + (phases.map { [["name": "installing", "row": row(.installing($0, afterBuild: true))]] } ?? [])

        let machines: [(String, String)] = [
            ("signed out, no attempt", machine()),
            ("signed in", machine(signedIn: true)),
            ("a sign-in that waits for a code", machine(login: login("needs_owner", url: "https://claude.ai/oauth/authorize?code=true"))),
            ("Codex's device code", machine(runtime: "codex", login: login("needs_owner", runtime: "codex",
                                                                           url: "https://auth.openai.com/codex/device", code: "KDRT-7QXP", wants: false))),
            ("a link of another host", machine(login: login("needs_owner", url: "https://claude.ai.example.com/oauth"))),
            ("a link with a port", machine(login: login("needs_owner", url: "https://claude.ai:443/oauth"))),
            ("a link over http", machine(login: login("needs_owner", url: "http://claude.ai/oauth"))),
            ("a sign-in that failed", machine(login: login("failed", detail: "Claude Code did not sign in. Start it again."))),
            ("a sign-in that only waited", machine(login: login("failed", detail: "No code came back in 14 minutes.", timedOut: true))),
            ("signing out", machine(login: login("signing_out"))),
            ("starting", machine(login: login("starting"))),
            ("the code on its way", machine(login: login("signing_in"))),
            ("a stale reading", machine(signedIn: true, stale: true)),
        ]
        var signIns: [[String: Any]] = []
        for (name, json) in machines {
            let status = try decode(MachineStatus.self, json)
            let line = status.signInLine(working: false)
            let said = status.signInLine(working: false, alreadySaid: true)
            signIns.append(["name": name, "machine": try JSONSerialization.jsonObject(with: Data(json.utf8)),
                            "line": orNull(line.map { ["says": $0.says, "warn": $0.warn] }),
                            "line_already_said": orNull(said.map { ["says": $0.says, "warn": $0.warn] }),
                            "summary": orNull(status.login?.summary), "reason": orNull(status.login?.reason),
                            "link": orNull(status.login?.signInURL?.absoluteString), "device_code": orNull(status.login?.deviceCode),
                            "waits_for_code": status.login?.waitsForCode ?? false,
                            "signed_in": AgentSetupFlow.signedIn(runtime: "claude", machine: status),
                            "page": pageName(AgentSetupFlow.page(runtime: "claude", job: nil, machine: status, switchingTo: nil)),
                            "stopped": orNull(AgentSetupFlow.stopped(runtime: "claude", job: nil, machine: status))])
        }
        let codes = ["abc", "abcd", "ABCD-1234", "code#state_part.two-3", " padded-code ", "with space", "😀emoji", "-dash-first",
                     String(repeating: "a", count: 201), String(repeating: "a", count: 202)]
            .map { given -> [String: Any] in ["given": given, "code": orNull(MachineLogin.code(given))] }

        let jobs: [(String, String, String?)] = [
            ("an install that runs", job("running", step: "runtime"), nil),
            ("an install that waits for the sign-in", job("needs_owner", step: "sign_in",
                prompt: "{\"kind\": \"open_url\", \"purpose\": \"codex_login\", \"url\": \"https://auth.openai.com/codex/device\", \"code\": \"KDRT-7QXP\"}"), nil),
            ("an install that failed offline", job("failed", detail: "Claude Code did not install: npm could not reach the registry (ETIMEDOUT)."), nil),
            ("an install that failed", job("failed", detail: "The server's service did not start. Try again in Founderizer."), nil),
            ("an install that only waited", job("failed", detail: "Claude Code did not sign in within 15 minutes.", timedOut: true), nil),
            ("an install that failed with no words", job("failed"), nil),
            ("a preparation of the other provider that failed", job("failed", kind: "prepare", runtime: "codex"), "codex"),
            ("a preparation of the other provider", job("running", kind: "prepare", runtime: "codex", step: "runtime"), "codex"),
            ("a queued install", job("queued"), nil),
        ]
        var setups: [[String: Any]] = []
        for (name, json, switching) in jobs {
            let entry = try decode(ServerJob.self, json)
            let bar = AgentSetupFlow.installBar(entry, onMac: false)
            setups.append(["name": name, "job": try JSONSerialization.jsonObject(with: Data(json.utf8)),
                           "switching_to": orNull(switching),
                           "page": pageName(AgentSetupFlow.page(runtime: "claude", job: entry, machine: nil, switchingTo: switching)),
                           "stopped": orNull(AgentSetupFlow.stopped(runtime: "claude", job: entry, machine: nil)),
                           "start_claude": "\(AgentSetupFlow.start(chosen: "claude", runtime: "claude", job: entry, machine: nil))",
                           "start_codex": "\(AgentSetupFlow.start(chosen: "codex", runtime: "claude", job: entry, machine: nil))",
                           "bar": orNull(bar.map { ["steps": $0.steps, "running": orNull($0.running)] })])
        }
        let noJobBar = AgentSetupFlow.installBar(nil, onMac: false)!
        let checks: [(String, String)] = [
            ("one failed with words", "{\"check\": 3, \"checked_at\": 1763700000, \"revision\": \"abc\", \"items\": [{\"kind\": \"machine\", \"ref\": \"runtime_signed_in\", \"state\": \"fail\", \"detail\": \"Claude Code is not signed in.\", \"required\": true}]}"),
            ("one failed with no words", "{\"check\": 3, \"checked_at\": 1763700000, \"revision\": \"abc\", \"items\": [{\"kind\": \"machine\", \"ref\": \"vault_broker\", \"state\": \"fail\", \"detail\": \" \", \"required\": true}]}"),
            ("all passed", "{\"check\": 3, \"checked_at\": 1763700000, \"revision\": \"abc\", \"items\": [{\"kind\": \"machine\", \"ref\": \"tailscale\", \"state\": \"ok\", \"detail\": \"\", \"required\": true}, {\"kind\": \"machine\", \"ref\": \"browser\", \"state\": \"fail\", \"detail\": \"No browser.\", \"required\": false}]}"),
        ]
        let blockers = try checks.map { name, json -> [String: Any] in
            ["name": name, "verify": try JSONSerialization.jsonObject(with: Data(json.utf8)),
             "blocker": orNull(AgentSetupFlow.blocker(try decode(MachineVerification.self, json)))]
        }
        let offline = [("worker-1", "Codex did not install (ETIMEDOUT)."), (nil, "npm: EAI_AGAIN registry"), ("worker-1", "no network words")]
            .map { server, detail -> [String: Any] in
                ["server": orNull(server), "detail": detail, "words": orNull(AgentSetupFlow.offline(detail, runtime: "codex", server: server))]
            }

        let featuresAll = [FleetShapeHub.kept, FleetShapeHub.later, FleetShapeHub.rename]
        let starts: [(String, [String], Bool, String?)] = [
            ("a hub with no parts", [], false, servers(kept: nil, hubShared: nil, hubJoined: false, hubAvailable: false)),
            ("not read yet", featuresAll, false, nil),
            ("no kept step, a hub that renames", featuresAll, false, servers(kept: nil, hubShared: nil, hubJoined: false, hubAvailable: false)),
            ("no kept step, named", featuresAll, true, servers(kept: nil, hubShared: nil, hubJoined: false, hubAvailable: false)),
            ("no kept step, a hub that does not rename", Array(featuresAll.prefix(2)), false, servers(kept: nil, hubShared: nil, hubJoined: false, hubAvailable: false)),
            ("two kept", featuresAll, false, servers(kept: "two", hubShared: false, hubJoined: false, hubAvailable: false)),
            ("one kept, the hub's server not shared", featuresAll, false, servers(kept: "one", hubShared: false, hubJoined: false, hubAvailable: false)),
            ("one kept, the hub's server with no service", featuresAll, false, servers(kept: "one", hubShared: true, hubJoined: false, hubAvailable: false)),
            ("one kept, the hub's server joined, not free", featuresAll, false, servers(kept: "one", hubShared: true, hubJoined: true, hubAvailable: false)),
            ("one kept, the hub's server ready", featuresAll, false, servers(kept: "one", hubShared: true, hubJoined: true, hubAvailable: true)),
            ("a step this app does not know", featuresAll, false, servers(kept: "three", hubShared: nil, hubJoined: false, hubAvailable: false)),
        ]
        var managerStarts: [[String: Any]] = []
        for (name, features, named, json) in starts {
            let list = try json.map { try decode(ServerList.self, $0) }
            let start = ManagerSetupStart.page(features: features, named: named, list: list)
            let shown: [String: Any] = switch start {
            case .name: ["start": "name"]
            case .servers: ["start": "servers"]
            case .sharing(let root): ["start": "sharing", "root_step": root]
            case .onHub(let hub): ["start": "onHub", "server": hub]
            case .server: ["start": "server"]
            case .unread: ["start": "unread"]
            }
            let pagesOf = [(nil as String?, nil as String?, false), ("claude", nil, false), ("claude", "worker-2", false),
                           ("claude", "worker-2", true)].map { provider, placeOn, refused -> [String: Any] in
                ["provider": orNull(provider), "place_on": orNull(placeOn), "refused": refused,
                 "page": pageName(start.page(renaming: false, provider: provider, placeOn: placeOn, refused: refused))]
            }
            managerStarts.append(["name": name, "features": features, "named": named,
                                  "servers": orNull(try json.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }),
                                  "start": shown, "pages": pagesOf,
                                  "renaming": pageName(start.page(renaming: true, provider: "claude", placeOn: nil, refused: false))])
        }
        let handovers = [("claude", false, "claude", false, true, false), ("claude", true, "claude", true, true, false),
                         ("claude", true, "codex", true, true, false), ("claude", true, "claude", false, true, false),
                         ("claude", true, "claude", true, false, false), ("claude", true, "claude", true, true, true),
                         (nil, false, "claude", false, true, false)]
            .map { chosen, placed, runtime, one, writes, asked -> [String: Any] in
                let shown: Any = switch FirstRunHandover.of(chosen: chosen, placed: placed, runtime: runtime, installedOneServer: one,
                                                           writes: writes, asked: asked) {
                case .keep(let provider): ["keep": provider]
                case .signIn(let provider): ["sign_in": provider]
                case .none: "none"
                }
                return ["chosen": orNull(chosen), "placed": placed, "runtime": runtime, "installed_one_server": one,
                        "writes": writes, "asked": asked, "handover": shown]
            }
        let names = ["Juno", " juno ", "Ada-2", "a", "manager", "hub", "vault-1", "login-x", "Zoë", "two words",
                     String(repeating: "n", count: 26), String(repeating: "n", count: 27), "9lives"]
            .map { typed -> [String: Any] in ["typed": typed, "agent_name": orNull(ManagerName.agentName(typed)), "shown": ManagerName.shown(typed)] }

        let startAgain: [String: Any] = [
            "fixed": ["start": StartAgain.Words.start, "starting": StartAgain.Words.starting, "press": StartAgain.Words.press,
                      "still_costs": StartAgain.Words.stillCosts],
            "deleted_at": CloudProvider.allCases.map { ["provider": $0.rawValue, "words": StartAgain.Words.deletedAt($0)] },
            "firewalls": CloudProvider.allCases.flatMap { provider in [1, 2].map { count -> [String: Any] in
                ["provider": provider.rawValue, "count": count, "words": StartAgain.Words.firewalls(count, at: provider),
                 "made_for": StartAgain.Words.madeFor(count, at: provider),
                 "title": StartAgain.Words.title(of: .firewalls(provider, servers: Array(repeating: StartAgain.Server(
                    provider: provider, serverID: "1", name: "worker-1", use: .hub), count: count)))]
            } },
            "machines": [["worker-1"], ["worker-1", "worker-2"], ["worker-1", "worker-2", "worker-3"]].map { names -> [String: Any] in
                ["names": names, "words": StartAgain.Words.machines(names), "title": StartAgain.Words.title(of: .machines(names.count))]
            },
            "server_title": StartAgain.Words.title(of: .server(StartAgain.Server(provider: .hetzner, serverID: "1", name: "worker-1", use: .hub))),
            "app_title": StartAgain.Words.title(of: .app),
            "states": StartAgain.Step.State.allCases.map { ["state": $0.rawValue, "words": StartAgain.Words.word(of: $0)] },
            "details": [StartAgain.Server(provider: .hetzner, serverID: "1", name: "worker-1", use: .hub, type: "cx23"),
                        StartAgain.Server(provider: .digitalOcean, serverID: "2", name: "worker-2", use: .agent, type: "s-1vcpu-2gb"),
                        StartAgain.Server(provider: .vultr, serverID: "3", name: "worker-3", use: .agent)]
                .map { ["provider": $0.provider.rawValue, "use": $0.use.rawValue, "type": orNull($0.type),
                        "detail": StartAgain.Words.detail(of: $0)] },
            "sentences": ["Hetzner refused", "Done.", "Really?", "  spaced  "].map { ["words": $0, "sentence": StartAgain.Words.sentence($0)] },
        ]
        return ["about": "The sentences and the rules of the first run and of the agent setup that FleetCore holds, for fixed "
                    + "examples, with \"Mac\" where the Windows app says \"PC\". The readings are example answers of the hub.",
                "made_by": madeBy, "servers_steps": steps, "fleet_counts": counts, "first_run_steps": FirstRunSteps.names,
                "first_run_step_of": firstRunOf, "manager_setup_steps": ManagerSetupSteps.names,
                "manager_setup_current": managerCurrent, "build_rows": rows, "hub_plan": hubPlan, "join_plan": joinPlan,
                "sign_ins": signIns, "codes": codes, "setups": setups, "install_bar_no_job": noJobBar.steps,
                "blockers": blockers, "offline": offline, "installing": AgentSetupFlow.installing("Claude Code", on: "worker-2"),
                "provider_names": ["claude", "codex", "grok", "gemini"].map { ["runtime": $0, "name": providerName($0)] },
                "manager_starts": managerStarts, "handovers": handovers, "manager_names": names, "start_again": startAgain]
    }

    // MARK: - remote-password.json

    static let publicLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExamp founderizer"

    static func passwordDocument() -> [String: Any] {
        ["about": "The program that puts the app's own key on a server with a password given once (FleetCore's "
            + "PasswordOnce), for a fixed public line: its text, the command that the server gets, and the marks it prints; "
            + "and the proof that the key alone opens the server.",
         "made_by": madeBy, "public_line": publicLine, "add_key": PasswordOnce.addKey(publicLine),
         "command": "/bin/sh -c " + InstallPlan.quote(PasswordOnce.addKey(publicLine)),
         "key_added": PasswordOnce.keyAdded, "sudo_mark": PasswordOnce.sudoMark, "key_works": PasswordOnce.keyWorks,
         "works": "echo \(PasswordOnce.keyWorks)"]
    }

    static func encoded(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    @Test("The setup's vectors are what FleetCore gives now")
    func theSetupVectorsAreTheCommittedFiles() throws {
        let made = try Localized.$bundle.withValue(WordsVectorsTests.noTable) {
            [Self.wordsFile: try Self.encoded(Self.wordsDocument()), Self.passwordFile: try Self.encoded(Self.passwordDocument())]
        }
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            for (name, data) in made { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
            return
        }
        for (name, data) in made.sorted(by: { $0.key < $1.key }) {
            let committed = try Data(contentsOf: Self.folder.appendingPathComponent(name))
            #expect(committed == data, "app/vectors/\(name) is not what FleetCore gives: run app/vectors/make_vectors.py")
        }
    }
}
