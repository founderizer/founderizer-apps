import Foundation
import Testing
@testable import FleetCore

/// **The vectors of the root jobs of the owner's computer** (windows-app-plan-v2.md, 5.6, piece L6): what the Windows
/// app's library (`windows/Founderizer.Setup/RootJobs`) sends to a server as root by itself and how it reads the
/// answer, made by FleetCore's own code for fixed example inputs.
///
/// - The owner's access line (`OwnerAccess.install` and `isInPlace`).
/// - The join's hardening (`ServerHardening`): its program, how a round reads a server, what one round does with it
///   (`step`), and what a run's output came to (`outcome`).
/// - The agents' browser parts (`ServerBrowser`): the contract's texts, Google's key, the table, the ports, what a
///   round does with a server (`work`), the program of each work, and what a run's output came to.
///
/// Each program also comes as the command that `ssh` gets for a user that becomes root with `sudo -n`
/// (`InstallPlan.arguments`' last word). The words are English on a Mac of any language. With
/// `FOUNDERIZER_VECTORS_OUT` set, the test writes the file into that folder (`app/vectors/make_vectors.py` does, and
/// its `--check` compares); without it, the test holds the committed file equal to what FleetCore gives now.
struct RootVectorsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")
    static let file = "remote-root.json"
    static let madeBy = "app/Tests/FleetCoreTests/RootVectorsTests.swift"
    /// The hub's clock in the lists, and the owner's computer's clock for the tries.
    static let time: Double = 1_000_000
    static let throughSudo = InstallTarget(host: "100.80.1.7", user: "admin", port: 2222, becomeRoot: true)

    /// The command that `ssh` gets for `program` as root, for a user that becomes root with `sudo -n`.
    static func wire(_ program: String) -> String {
        InstallPlan(job: .join, target: throughSudo, steps: [], redactions: [])
            .arguments(for: program, reaching: throughSudo, runs: .root).last!
    }

    static func program(_ text: String) -> [String: Any] { ["program": text, "through_sudo": wire(text)] }

    static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    struct Missing: Error {}

    /// The value, or a stop of the writer: an example input that FleetCore does not take.
    static func must<T>(_ value: T?) throws -> T {
        guard let value else { throw Missing() }
        return value
    }

    static func tries(_ tries: VaultTries?) -> Any {
        tries.map { ["failures": $0.failures, "last": $0.last, "reason": $0.reason] as [String: Any] } ?? NSNull()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - the owner's access line

    static func accessDocument() throws -> [String: Any] {
        let key = try must(OwnerAccessKey(seed: Data((1...32).map { UInt8($0) })))
        let outputs = ["founderizer-owner-access-in-place", "  founderizer-owner-access-in-place  \n",
                       "Welcome to Ubuntu\nfounderizer-owner-access-in-place\n", "", "sudo: a password is required",
                       "founderizer-owner-access-in-place-not"]
        return ["public_line": key.publicLine, "fingerprint": key.fingerprint, "root_keys": OwnerAccess.rootKeys,
                "in_place": OwnerAccess.inPlace, "program": program(OwnerAccess.install(key)),
                "outputs": outputs.map { ["output": $0, "in_place": OwnerAccess.isInPlace($0)] as [String: Any] }]
    }

    // MARK: - the join's hardening

    /// A Linux server that joined, as `/ui/servers` lists it, with a current reading of its own service.
    static func server(_ name: String = "app-1", kind: String = "linux", joined: Bool = true, hub: Bool = false,
                       source: String = "server", reportedAt: Double = time - 60, stale: Bool = false,
                       ssh: Bool? = false, npm: Bool? = true, job: String? = nil) -> [String: Any] {
        var security: [String: Any] = ["firewall": "active", "tailscale": true, "unattended_upgrades": true]
        if let ssh { security["ssh_keys_only"] = ssh }
        if let npm { security["npm_rule"] = npm }
        var entry: [String: Any] = [
            "name": name, "kind": kind, "hub": hub, "joined": joined, "agents": [], "address": "100.80.1.7",
            "available": true, "why": [],
            "reading": ["source": source, "os": ["name": "Ubuntu 24.04"], "runtimes": [:], "reported_at": reportedAt,
                        "stale": stale, "security": security] as [String: Any]]
        if let job {
            entry["job"] = ["id": 4, "kind": "install", "agent": "dev-lead", "state": job, "created": time - 100,
                            "updated": time - 50] as [String: Any]
        }
        return entry
    }

    /// The hub's own row, with the hub's own reading of its server in `hardening` (owner API 1.170).
    static func hubRow(ssh: Bool? = false, npm: Bool? = true, at: Double? = time - 60, claimed: Double? = time - 7200,
                       own: Bool = true, kind: String? = nil) -> [String: Any] {
        var entry: [String: Any] = [
            "name": "hub", "hub": true, "joined": false, "agents": ["manager"], "address": "100.80.1.2",
            "available": false, "why": ["hub_machine", "no_service"]]
        if let kind { entry["kind"] = kind }
        if own {
            var hardening: [String: Any] = [:]
            if let ssh { hardening["ssh_keys_only"] = ssh }
            if let npm { hardening["npm_rule"] = npm }
            if let at { hardening["at"] = at }
            if let claimed { hardening["claimed_at"] = claimed }
            entry["hardening"] = hardening
        }
        return entry
    }

    static func join(_ server: String?, created: Double) -> [String: Any] {
        var entry: [String: Any] = ["name": "", "kind": "linux", "created": created, "expires_at": created + 3600,
                                    "state": server == nil ? "open" : "joined"]
        if let server { entry["server"] = server }
        return entry
    }

    static func word(_ reading: ServerHardening.Reading) -> String {
        switch reading {
        case .unread: "unread"
        case .holds: "holds"
        case .faulty: "faulty"
        }
    }

    static func word(_ step: ServerHardening.Step) -> String {
        switch step {
        case .nothing: "nothing"
        case .settle: "settle"
        case .seen: "seen"
        case .wait: "wait"
        case .run: "run"
        }
    }

    static func hardeningDocument() throws -> [String: Any] {
        let rows: [(String, [String: Any], [String: Any]?)] = [
            ("a server whose SSH lets passwords in", server(ssh: false), nil),
            ("a server whose npm has no seven-day rule", server(ssh: true, npm: false), nil),
            ("npm alone says the fault", server(ssh: nil, npm: false), nil),
            ("a server whose hardening holds", server(ssh: true, npm: true), nil),
            ("SSH holds and npm says nothing", server(ssh: true, npm: nil), nil),
            ("a reading that says nothing", server(ssh: nil, npm: nil), nil),
            ("npm alone holds", server(ssh: nil, npm: true), nil),
            ("a Mac that joined as a server", server(kind: "mac"), nil),
            ("a server that did not join", server(joined: false), nil),
            ("the reading of an agent's helper", server(source: "agent"), nil),
            ("a stale reading", server(stale: true), nil),
            ("a reading that is too old", server(reportedAt: time - 700), nil),
            ("a reading from the future", server(reportedAt: time + 6), nil),
            ("an open job", server(job: "running"), nil),
            ("a queued job", server(job: "queued"), nil),
            ("a job that needs the owner", server(job: "needs_owner"), nil),
            ("a job that is done", server(job: "done"), nil),
            ("a job that failed", server(job: "failed"), nil),
            ("the hour after its join", server(), join("app-1", created: time - 600)),
            ("an hour after its join", server(), join("app-1", created: time - 3600)),
            ("the hour after another server's join", server(), join("app-2", created: time - 600)),
            ("the hub's own server with a fault", hubRow(), nil),
            ("the hub's own server that holds", hubRow(ssh: true, npm: true), nil),
            ("the hub's own server in the hour after its claim", hubRow(claimed: time - 600), nil),
            ("the hub's own server with no claim kept", hubRow(claimed: nil), nil),
            ("the hub's own server read too long ago", hubRow(at: time - 700), nil),
            ("the hub's own server with no reading of its own", hubRow(own: false), nil),
            ("the hub on a Mac", hubRow(kind: "mac"), nil),
        ]
        var readings: [[String: Any]] = []
        for (name, row, join) in rows {
            let entry = try decode(ServerEntry.self, row)
            let state = try join.map { try decode(JoinState.self, $0) }
            readings.append(["name": name, "server": row, "join": orNull(join), "time": time,
                             "applies": ServerHardening.applies(to: entry),
                             "reading": word(ServerHardening.reading(of: entry, join: state, at: time))])
        }
        func memory(failures: Int = 0, last: Double = 0, settled: Bool = false) -> ServerHardening.Memory {
            var memory = ServerHardening.Memory()
            for _ in 0..<failures { memory.failed(at: last, reason: "ssh refused, npm made") }
            memory.settled = settled
            return memory
        }
        let steps: [(String, ServerHardening.Reading, ServerHardening.Memory, Bool, Double, VaultTries?)] = [
            ("the fault in a first round", .faulty, memory(), false, time, nil),
            ("the fault in a second round", .faulty, memory(), true, time, nil),
            ("a reading that says nothing", .unread, memory(), true, time, nil),
            ("a reading that holds", .holds, memory(), false, time, nil),
            ("a settled server with a fault", .faulty, memory(settled: true), true, time, nil),
            ("a settled server that holds", .holds, memory(settled: true), true, time, nil),
            ("a run nine minutes ago", .faulty, memory(failures: 1, last: time - 540), true, time, nil),
            ("a run ten minutes ago", .faulty, memory(failures: 1, last: time - 600), true, time, nil),
            ("five runs", .faulty, memory(failures: 5, last: time - 600), true, time, nil),
            ("six runs", .faulty, memory(failures: 6, last: time - 6000), true, time, nil),
            ("a try that ran nothing a minute ago", .faulty, memory(), true, time,
             VaultTries(failures: 1, last: time - 60, reason: "no connection")),
            ("a try that ran nothing ten minutes ago", .faulty, memory(), true, time,
             VaultTries(failures: 1, last: time - 600, reason: "no connection")),
            ("six tries that ran nothing", .faulty, memory(), true, time,
             VaultTries(failures: 6, last: time - 6000, reason: "no connection")),
        ]
        let stepsOut: [[String: Any]] = steps.map { name, reading, memory, seen, now, unreached in
            ["name": name, "reading": word(reading), "seen_before": seen, "now": now, "unreached": tries(unreached),
             "memory": ["failures": memory.failures, "last": memory.last, "reason": memory.reason, "settled": memory.settled],
             "step": word(ServerHardening.step(reading, memory: memory, seenBefore: seen, now: now, unreached: unreached))]
        }
        let started = ServerHardening.started
        let outputs = [
            "\n\(started)\nfounderizer-hardening ssh=keys-only npm=made\n",
            "\(started)\nfounderizer-hardening ssh=off npm=held",
            "\(started)\nfounderizer-hardening ssh=no-key npm=made\n",
            "\(started)\nsshd: line 3: Bad configuration option\nfounderizer-hardening ssh=refused npm=made\n",
            "\(started)\nfounderizer-hardening ssh=keys-only npm=failed\n",
            "\(started)\nfounderizer-hardening ssh=not-yet npm=held\n",
            "\(started)\nfounderizer-hardening\n",
            "\(started)\nfounderizer-hardening ssh=keys-only npm=made\nfounderizer-hardening ssh=refused npm=held\n",
            "\(started)\n",
            "\(started)\nsome words of the server\n",
            "Host key verification failed.\n",
            "sudo: a password is required\n",
            "",
            "  \(started)  \r\n  founderizer-hardening ssh=keys-only npm=held  \r\n",
        ]
        let outcomes: [[String: Any]] = outputs.map { output in
            var out: [String: Any] = ["output": output]
            switch ServerHardening.outcome(output) {
            case .holds: out["outcome"] = "holds"
            case .leftAsItIs: out["outcome"] = "left_as_it_is"
            case .failed(let said): out["outcome"] = "failed"; out["said"] = said
            case .notStarted(let said): out["outcome"] = "not_started"; out["said"] = said
            }
            return out
        }
        return ["join_grace": ServerHardening.joinGrace, "started": started, "program": program(ServerHardening.program()),
                "readings": readings, "steps": stepsOut, "outcomes": outcomes,
                "tries": ["wait": VaultTries.wait, "most": VaultTries.most]]
    }

    // MARK: - the agents' browser parts

    static func agent(_ name: String, can: [String] = ["shell", "browser"]) -> [String: Any] {
        ["name": name, "role": "worker", "runtime": "claude", "can": can]
    }

    static func task(owner: String, state: String = "working", works: Bool? = nil) -> [String: Any] {
        var task: [String: Any] = ["id": 7, "title": "The shop page", "details": "", "done_when": "", "needs": "",
                                   "goal": "", "owner": owner, "requester": "manager", "state": state, "created": 100,
                                   "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
        if let works { task["works"] = works }
        return task
    }

    /// A Linux server that joined, with alpha (fleet-alpha, 1002) and beta (fleet-beta, 1003) on it, the service's
    /// user fleet (1000, or `worker` and `workerID`), the broker 1001, and by default none of the parts.
    static func browserServer(state: String? = "missing", ports: [[String: Any]] = [], files: [String: String] = [:],
                              missing: [String] = ServerBrowser.packages, unit: String? = "inactive", added: Bool = false,
                              broker: Int? = 1001, job: String? = nil, hub: Bool = false, source: String = "server",
                              reportedAt: Double = time - 60, users: [String: Any]? = nil, browser: Bool = true,
                              kept: Bool? = nil, chrome: String? = nil, worker: String = "fleet",
                              workerID: Int = 1000) -> [String: Any] {
        var parts: [String: Any] = ["state": orNull(state), "missing": missing, "files": files, "unit": orNull(unit),
                                    "ports": ports, "added": added, "worker": workerID, "chrome": orNull(chrome)]
        if let broker { parts["broker"] = broker }
        if let kept { parts["proof_kept"] = kept }
        var reading: [String: Any] = ["source": source, "os": ["name": "Ubuntu 24.04"], "runtimes": [:],
                                      "reported_at": reportedAt, "stale": false, "user": worker,
                                      "agents": users ?? ["alpha": ["user": "fleet-alpha", "uid": 1002],
                                                          "beta": ["user": "fleet-beta", "uid": 1003]]]
        if browser { reading["browser"] = parts }
        var entry: [String: Any] = ["name": hub ? "hub" : "app-1", "hub": hub, "joined": !hub, "kind": "linux",
                                    "agents": ["alpha", "beta"], "address": "100.80.1.7", "available": true,
                                    "why": [], "reading": reading]
        if let job {
            entry["job"] = ["id": 4, "kind": "install", "agent": "beta", "state": job, "created": time - 100,
                            "updated": time - 50] as [String: Any]
        }
        return entry
    }

    static func ports(_ rows: [ServerBrowser.Ports]) -> [[String: Any]] {
        rows.map { ["user": $0.user, "devtools": $0.devtools, "screen": $0.screen] }
    }

    static func want(_ want: ServerBrowser.Want) -> [String: Any] {
        ["rows": ports(want.rows), "table": want.table, "uids": want.uids, "broker": orNull(want.broker),
         "worker": want.worker, "worker_id": want.workerID, "digest": want.digest]
    }

    static func work(_ work: ServerBrowser.Work?) -> Any {
        switch work {
        case nil: NSNull()
        case .nothing?: "nothing"
        case .remove?: "remove"
        case .install(let wanted)?: ["install": want(wanted)]
        }
    }

    static func browserDocument() throws -> [String: Any] {
        func hash(_ text: String) -> String { ServerBrowser.hash(text) }
        let row: [String: Any] = ["user": "fleet-alpha", "devtools": 9300, "screen": 5910]
        // The files as the step leaves them for alpha alone (rows and table of the first case).
        let alpha = [ServerBrowser.Ports(user: "fleet-alpha", devtools: 9300, screen: 5910)]
        let alphaTable = try must(ServerBrowser.table(alpha, uids: ["fleet-alpha": 1002, "fleet-beta": 1003],
                                                          broker: 1001, worker: 1000))
        let inPlace: [String: String] = [
            "unit": hash(ServerBrowser.unitText), "dropin": hash(ServerBrowser.dropinText),
            "default": hash(ServerBrowser.defaultText), "origin": hash(ServerBrowser.originText),
            "fixed": hash(ServerBrowser.fixedText), "policy": hash(ServerBrowser.policyText),
            "ports": hash(ServerBrowser.portsText(alpha)), "table": hash(alphaTable),
            "source": String(repeating: "5", count: 64), "key": String(repeating: "6", count: 64)]
        var older = inPlace, noSource = inPlace
        older["policy"] = String(repeating: "7", count: 64)
        noSource["source"] = nil
        let both = [agent("alpha"), agent("beta", can: ["shell"])]
        let closed = [agent("alpha", can: ["shell"]), agent("beta", can: ["shell"])]
        let left = ["source": String(repeating: "5", count: 64), "key": String(repeating: "6", count: 64),
                    "default": hash(ServerBrowser.defaultText)]
        let cases: [(String, [String: Any], [[String: Any]], [[String: Any]], [String: Any]?)] = [
            ("alpha wants the parts, and none is there", browserServer(), both, [], nil),
            ("the parts in place", browserServer(state: "ready", ports: [row], files: inPlace, missing: [], unit: "active",
                                                  added: true, kept: true), both, [], nil),
            ("a live proof that no helper can read", browserServer(state: "ready", ports: [row], files: inPlace, missing: [],
                                                                   unit: "active", added: true, kept: false), both, [], nil),
            ("the table gone", browserServer(state: "table_missing", ports: [row], files: inPlace, missing: [],
                                             unit: "active", added: true, kept: true), both, [], nil),
            ("a policy of older lists", browserServer(state: "ready", ports: [row], files: older, missing: [],
                                                      unit: "active", added: true, kept: true), both, [], nil),
            ("a unit that stopped", browserServer(state: "missing", ports: [row], files: inPlace, missing: [],
                                                  unit: "failed", added: true, kept: true), both, [], nil),
            ("a package that went", browserServer(state: "missing", ports: [row], files: inPlace, missing: ["libatomic1"],
                                                  unit: "active", added: true, kept: true), both, [], nil),
            ("the source that went", browserServer(state: "missing", ports: [row], files: noSource, missing: [],
                                                   unit: "active", added: true, kept: true), both, [], nil),
            ("a broker that came after the parts", browserServer(state: "ready", ports: [row], files: inPlace, missing: [],
                                                                  unit: "active", added: true, broker: 1009, kept: true),
             both, [], nil),
            ("no broker", browserServer(broker: nil), both, [], nil),
            ("a reading's row of port 22: alpha takes free ports, beta keeps its row",
             browserServer(ports: [["user": "fleet-alpha", "devtools": 22, "screen": 5910],
                                   ["user": "fleet-beta", "devtools": 9305, "screen": 5915]]),
             [agent("beta"), agent("alpha")], [], nil),
            ("a reading's port past 32 bits is no row, and alpha keeps its row",
             browserServer(ports: [["user": "fleet-alpha", "devtools": 9305, "screen": 5915],
                                   ["user": "fleet-beta", "devtools": 4_294_967_318, "screen": 5911]]),
             [agent("beta"), agent("alpha")], [], nil),
            ("a reading's port that a 16-bit number reads as 9300 is no row",
             browserServer(ports: [["user": "fleet-alpha", "devtools": 74836, "screen": 5910]]), both, [], nil),
            ("a worker user that is not the service's own", browserServer(worker: "ubuntu"), both, [], nil),
            ("a worker uid of an agent's user", browserServer(workerID: 1002), both, [], nil),
            ("the service's own user with uid 0", browserServer(workerID: 0), both, [], nil),
            ("both agents want the parts, alpha has its ports", browserServer(ports: [row]),
             [agent("beta"), agent("alpha")], [], nil),
            ("x86 Ubuntu only", browserServer(state: "unsupported"), both, [], nil),
            ("no agent wants them, and some were added", browserServer(added: true), closed, [], nil),
            ("no agent wants them, and a policy is there",
             browserServer(files: ["policy": String(repeating: "7", count: 64)]), closed, [], nil),
            ("no agent wants them, and a row is there", browserServer(ports: [row]), closed, [], nil),
            ("no agent wants them, and none is there", browserServer(), closed, [], nil),
            ("Chrome stays after a removal", browserServer(files: left, missing: [], chrome: "157.0.8103.78-1"), closed,
             [], nil),
            ("an agent that the reading does not name", browserServer(users: ["beta": ["user": "fleet-beta", "uid": 1003]]),
             [agent("alpha")], [], nil),
            ("a reading that names no agent", browserServer(ports: [row], added: true, users: [:]), [agent("alpha")], [], nil),
            ("a closed agent", browserServer(), [agent("alpha", can: ["browser"])], [], nil),
            ("an agent that runs as the service's user, and one with no user yet",
             browserServer(users: ["alpha": ["user": "fleet", "uid": 1000], "beta": ["user": NSNull(), "uid": NSNull()]]),
             [agent("alpha"), agent("beta")], [], nil),
            ("a user that is no agent's user",
             browserServer(users: ["alpha": ["user": "admin", "uid": 1002], "beta": ["user": "fleet-beta", "uid": 1003]]),
             [agent("alpha"), agent("beta")], [], nil),
            ("a value of another shape for the agents", browserServer(users: ["alpha": "fleet-alpha"]), [agent("alpha")],
             [], nil),
            ("an open job", browserServer(job: "running"), both, [], nil),
            ("a task that works", browserServer(), both, [task(owner: "beta")], nil),
            ("a task that is over", browserServer(), both, [task(owner: "beta", state: "completed")], nil),
            ("a task that says it works", browserServer(), both, [task(owner: "beta", works: true)], nil),
            ("a task that does nothing now", browserServer(), both, [task(owner: "beta", works: false)], nil),
            ("a task of an agent on another server", browserServer(), both, [task(owner: "gamma")], nil),
            ("the hub's own server", browserServer(hub: true), both, [], nil),
            ("the reading of an agent's helper", browserServer(source: "agent"), both, [], nil),
            ("an old reading", browserServer(reportedAt: time - 3600), both, [], nil),
            ("a reading without the parts", browserServer(browser: false), both, [], nil),
            ("the hour after its join", browserServer(), both, [], join("app-1", created: time - 600)),
        ]
        var works: [[String: Any]] = []
        var programs: [[String: Any]] = []
        for (name, row, agents, tasks, join) in cases {
            let entry = try decode(ServerEntry.self, row)
            let fleet = try agents.map { try decode(FleetAgent.self, $0) }
            let jobs = try tasks.map { try decode(FleetTask.self, $0) }
            let state = try join.map { try decode(JoinState.self, $0) }
            let found = ServerBrowser.work(for: entry, agents: fleet, tasks: jobs, join: state, at: time)
            works.append(["name": name, "server": row, "agents": agents.map { ["name": $0["name"]!, "can": $0["can"]!] },
                          "tasks": tasks.map { ["owner": $0["owner"]!, "state": $0["state"]!, "works": orNull($0["works"])] },
                          "join": orNull(join), "time": time, "work": work(found),
                          "wanted": orNull(ServerBrowser.wanted(on: entry, agents: fleet))])
            if case .install? = found, programs.count < 2 {
                programs.append(["name": name, "work": work(found), "program": program(ServerBrowser.program(found!))])
            }
        }
        programs.append(["name": "the removal", "work": "remove", "program": program(ServerBrowser.program(.remove))])
        let tables: [(String, [ServerBrowser.Ports], [String: Int], Int?)] = [
            ("two agents and a broker", [.init(user: "fleet-alpha", devtools: 9311, screen: 5911),
                                         .init(user: "fleet-beta", devtools: 9312, screen: 5912)],
             ["fleet-alpha": 1002, "fleet-beta": 1003], 1001),
            ("no broker", [.init(user: "fleet-alpha", devtools: 9311, screen: 5911)], ["fleet-alpha": 1002], nil),
            ("a user with no uid", [.init(user: "fleet-alpha", devtools: 9311, screen: 5911),
                                    .init(user: "fleet-beta", devtools: 9312, screen: 5912)], ["fleet-alpha": 1002], 1001),
            ("no row", [], [:], nil),
        ]
        let current = [ServerBrowser.Ports(user: "fleet-a", devtools: 9300, screen: 5910),
                       ServerBrowser.Ports(user: "fleet-b", devtools: 9301, screen: 5911),
                       ServerBrowser.Ports(user: "fleet-c", devtools: 9302, screen: 5912)]
        let full = (0..<90).map { ServerBrowser.Ports(user: "fleet-a\($0)", devtools: 9300 + $0, screen: 5910 + $0) }
        let assigns: [([ServerBrowser.Ports], [String])] = [
            (current, ["fleet-c", "fleet-d", "fleet-a"]), (full, full.map(\.user) + ["fleet-new"]), ([], ["fleet-x", "fleet-y"]),
            (current, []),
        ]
        let started = ServerBrowser.started
        let outputs = [
            "\(started)\nfounderizer-browser started\n",
            "\n\(started)\nfounderizer-browser started 0123456789abcdef ok\n",
            "\(started)\nfounderizer-browser running 0123456789abcdef running\n",
            "\(started)\nFailed to start transient service unit\nfounderizer-browser failed 0123456789abcdef users-changed\n",
            "\(started)\nfounderizer-browser failed\n",
            "\(started)\n",
            "\(started)\nsome words\n",
            "Host key verification failed.\n",
            "",
        ]
        let outcomes: [[String: Any]] = outputs.map { output in
            var out: [String: Any] = ["output": output]
            switch ServerBrowser.outcome(output) {
            case .started(let before): out["outcome"] = "started"; out["said"] = before
            case .running(let before): out["outcome"] = "running"; out["said"] = before
            case .failed(let said): out["outcome"] = "failed"; out["said"] = said
            case .notStarted(let said): out["outcome"] = "not_started"; out["said"] = said
            }
            return out
        }
        return [
            "texts": ["unit": ServerBrowser.unitText, "dropin": ServerBrowser.dropinText,
                      "default": ServerBrowser.defaultText, "origin": ServerBrowser.originText,
                      "fixed": ServerBrowser.fixedText, "source": ServerBrowser.sourceText,
                      "policy": ServerBrowser.policyText, "key": ServerBrowser.keyData.base64EncodedString(),
                      "empty_table": ServerBrowser.emptyTable],
            "parts": ServerBrowser.parts, "packages": ServerBrowser.packages, "kept_packages": ServerBrowser.keptPackages,
            "sites": ProviderSites.sites, "key_sites": ProviderSites.keySites, "started": started,
            "tables": tables.map { name, rows, uids, broker in
                ["name": name, "rows": ports(rows), "uids": uids, "broker": orNull(broker), "worker": 1000,
                 "table": orNull(ServerBrowser.table(rows, uids: uids, broker: broker, worker: 1000)),
                 "ports_text": ServerBrowser.portsText(rows)] as [String: Any]
            },
            "assign": assigns.map { current, wanted in
                ["current": ports(current), "wanted": wanted, "rows": ports(ServerBrowser.assign(current, wanted: wanted))]
                    as [String: Any]
            },
            "works": works, "programs": programs, "outcomes": outcomes,
        ]
    }

    // MARK: - how a root job reaches a server

    static func target(_ target: InstallTarget?) -> Any {
        target.map { ["host": $0.host, "user": $0.user, "port": $0.port, "become_root": $0.becomeRoot] as [String: Any] }
            ?? NSNull()
    }

    /// `ServerRecords.target`: the kept connection (at the fleet's private address where it was public), else the fleet's
    /// record, whose user other than root is none for a root step.
    static func targetsDocument() throws -> [[String: Any]] {
        let entry = try decode(ServerEntry.self, server())
        let cases: [(String, InstallTarget?, MachineReach?, Bool)] = [
            ("kept as root, at a public address", InstallTarget(host: "203.0.113.10"), nil, true),
            ("kept as another user", InstallTarget(host: "100.80.1.7", user: "admin", port: 2222), nil, true),
            ("kept, with a record too", InstallTarget(host: "100.80.1.7", user: "admin"),
             MachineReach(address: "100.80.1.3", user: "root", port: 22), true),
            ("a record of root", nil, MachineReach(address: "100.80.1.7", user: "root", port: 22), true),
            ("a record of another user, for a root step", nil, MachineReach(address: "100.80.1.7", user: "fleet", port: 22), true),
            ("a record of another user, for the key registration", nil,
             MachineReach(address: "100.80.1.7", user: "fleet", port: 2222), false),
            ("a record with no user", nil, MachineReach(address: "100.80.1.7"), true),
            ("a record with a port out of range", nil, MachineReach(address: "100.80.1.7", user: "root", port: 0), true),
            ("a record with a user that is no user", nil, MachineReach(address: "100.80.1.7", user: "Root User", port: 22), false),
            ("a record with no address", nil, MachineReach(address: nil, user: "root", port: 22), true),
            ("no record", nil, nil, true),
        ]
        return cases.map { item -> [String: Any] in
            let (name, kept, record, rootOnly) = item
            return ["name": name, "address": orNull(entry.address), "kept": target(kept),
                    "record": record.map { ["address": orNull($0.address), "user": orNull($0.user), "port": orNull($0.port)] as [String: Any] }
                        ?? NSNull(),
                    "root_only": rootOnly,
                    "target": target(ServerRecords.target(entry, kept: kept, record: record, rootOnly: rootOnly))]
        }
    }

    static func document() throws -> [String: Any] {
        ["about": "The root jobs of the owner's computer (windows-app-plan-v2.md, 5.6, piece L6), made by FleetCore's own "
            + "code: the owner's access line, the join's hardening and the agents' browser parts.",
         "made_by": madeBy, "access": try accessDocument(), "hardening": try hardeningDocument(),
         "browser": try browserDocument(), "targets": try targetsDocument()]
    }

    static func encoded(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    @Test("The root jobs' vectors are what FleetCore gives now")
    func theRootVectorsAreTheCommittedFile() throws {
        let made = try Localized.$bundle.withValue(WordsVectorsTests.noTable) { try Self.encoded(Self.document()) }
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            try made.write(to: URL(fileURLWithPath: out).appendingPathComponent(Self.file))
            return
        }
        let committed = try Data(contentsOf: Self.folder.appendingPathComponent(Self.file))
        #expect(committed == made, "app/vectors/\(Self.file) is not what FleetCore gives: run app/vectors/make_vectors.py")
    }
}
