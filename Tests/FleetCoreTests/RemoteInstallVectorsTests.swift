import Foundation
import Testing
@testable import FleetCore

/// **The vectors of an install from the owner's computer** (windows-app-plan-v2.md, 5.6, piece L3): what the Windows
/// app's library (`windows/Founderizer.Setup/Install`) must send to a server and read from it, made by FleetCore's own
/// code for fixed example inputs.
///
/// - `remote-install.json`: each step of `InstallPlan.hub`, `.join`, `.check`, `.restart` and `.update`, with each
///   program that the step runs on the server, its standard input (as `MachineInstaller.perform` gives it), who runs
///   it (`login` or `root`), and the command that `ssh` gets for it (`InstallPlan.arguments`' last word) for root, for
///   a user that becomes root with `sudo -n`, and for one whose `sudo` takes the password on its first line. And
///   `ServerCheck.script`.
/// - `install-reads.json`: example outputs and what the Mac reads from them (`ClaimCode`, `NetworkSignIn`,
///   `InstallPlan.privateAddress`, `InstallCause`, `InstallRetry`, `InstallPhases`, `VerifyChecklist`, `ServerCheck`),
///   and the words of the stops.
///
/// The words are English on a Mac of any language: no table of the apps' words reaches them. With
/// `FOUNDERIZER_VECTORS_OUT` set, the test writes the two files into that folder (`app/vectors/make_vectors.py` does,
/// and its `--check` compares); without it, the test holds the committed files equal to what FleetCore gives now.
struct RemoteInstallVectorsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")
    static let programsFile = "remote-install.json"
    static let readsFile = "install-reads.json"
    static let madeBy = "app/Tests/FleetCoreTests/RemoteInstallVectorsTests.swift"

    // MARK: - The example inputs (no real key, code or address)

    static let authKey = "tskey-auth-kEXAMPLE01-NOTAKEYNOTAKEYNOTAKEY"
    static let code = "7KMQ2PRJ4TVW"
    static let asRoot = InstallTarget(host: "203.0.113.10")
    static let throughSudo = InstallTarget(host: "203.0.113.10", user: "admin", port: 2222, becomeRoot: true)
    static let hubAt = "http://100.64.0.1:8765"
    static func joinLine(tags: String?) -> String {
        let up = "tailscale up" + (tags.map { " --advertise-tags=\($0)" } ?? "") + " --accept-dns=false"
        return "command -v tailscale >/dev/null || { curl -fsSL https://tailscale.com/install.sh | sh; }; "
            + "tailscale status >/dev/null 2>&1 || \(up); { curl -fsS \(hubAt)/join || { echo Founderizer join stopped: "
            + "This machine cannot reach the Founderizer hub at \(hubAt). Check that Tailscale is connected, and run the "
            + "line again. >&2; echo; echo exit 1; }; } | FLEET_JOIN=\(code) sh"
    }

    /// Each plan of the file: its name, its inputs as the Windows test gives them again, and the plan.
    static func plans() -> [(String, [String: Any], InstallPlan)] {
        let source = InstallPlan.defaultSource
        func hub(_ name: String, key: String?, manager: String? = nil, one: Bool = false, shape: ServersStep? = nil,
                 runtime: String? = nil) -> (String, [String: Any], InstallPlan) {
            let inputs: [String: Any] = ["job": "hub", "host": asRoot.host, "user": asRoot.user, "port": asRoot.port,
                                         "source": source, "auth_key": orNull(key), "manager_name": orNull(manager),
                                         "one_server": one, "shape": orNull(shape?.rawValue),
                                         "runtime": orNull(runtime)]
            return (name, inputs, InstallPlan.hub(target: asRoot, source: source, authKey: key, managerName: manager,
                                                  oneServer: one, shape: shape, runtime: runtime))
        }
        func join(_ name: String, key: String?, tags: String?) -> (String, [String: Any], InstallPlan) {
            let line = joinLine(tags: tags)
            let inputs: [String: Any] = ["job": "join", "host": asRoot.host, "user": asRoot.user, "port": asRoot.port,
                                         "line": line, "code": code, "auth_key": orNull(key)]
            return (name, inputs, InstallPlan.join(target: asRoot, line: line, code: code, authKey: key))
        }
        func machine(_ job: String, _ machine: MachineCheckout, agent: String? = nil, _ plan: InstallPlan)
            -> (String, [String: Any], InstallPlan) {
            var inputs: [String: Any] = ["job": job, "host": asRoot.host, "user": asRoot.user, "port": asRoot.port,
                                         "machine": machine.rawValue]
            if let agent { inputs["agent"] = agent }
            return ("\(job), \(machine.rawValue)" + (agent.map { ", agent \($0)" } ?? ""), inputs, plan)
        }
        var all = [
            hub("hub, with a key", key: authKey),
            hub("hub, on the private network already", key: nil),
            hub("hub, one server, a named manager on Codex", key: authKey, manager: "Juno", one: true, runtime: "codex"),
            hub("hub, two servers, a name that the installer refuses", key: nil, manager: "Bad name", shape: .two),
            hub("hub, one per agent, a runtime that only one server takes", key: nil, manager: "hub", shape: .each,
                runtime: "codex"),
            hub("hub, one server, a runtime that the installer refuses", key: nil, one: true, shape: .two,
                runtime: "gemini"),
            hub("hub, one server, a manager name with a reserved start", key: nil, manager: "vault-1", one: true,
                runtime: "claude"),
            // A name that the installer takes, as nearly every first run sends it: `--manager-name` in the plan and the
            // run, before `--runtime` on one server.
            hub("hub, two servers, a manager named juno", key: nil, manager: "juno", shape: .two),
            hub("hub, one server, a manager named juno on Codex", key: authKey, manager: "juno", one: true,
                runtime: "codex"),
            join("join, with a key", key: authKey, tags: "tag:founderizer"),
            join("join, a sign-in with the line's tags", key: nil, tags: "tag:founderizer,tag:web"),
            join("join, a sign-in with no tags", key: nil, tags: nil),
            join("join, tags that this app would not write", key: nil, tags: "tag:Bad"),
        ]
        for checkout in MachineCheckout.allCases {
            all.append(machine("check", checkout, InstallPlan.check(target: asRoot, machine: checkout)))
        }
        all.append(machine("restart", .hub, InstallPlan.restart(target: asRoot, machine: .hub)))
        all.append(machine("restart", .linuxWorker, InstallPlan.restart(target: asRoot, machine: .linuxWorker)))
        all.append(machine("update", .linuxWorker, agent: "wren",
                           InstallPlan.update(target: asRoot, machine: .linuxWorker, agent: "wren")))
        return all
    }

    /// One program of a step, with its input and the command that `ssh` gets for it from each of the three targets.
    static func program(_ plan: InstallPlan, _ text: String, input: String?, runs: InstallPlan.Runs) -> [String: Any] {
        func wire(_ target: InstallTarget, _ runs: InstallPlan.Runs) -> String {
            plan.arguments(for: text, reaching: target, runs: runs).last!
        }
        return ["program": text, "input": orNull(input), "runs": runs == .login ? "login" : "root",
                "as_root": wire(asRoot, runs),
                "through_sudo": wire(throughSudo, runs),
                "with_password": wire(throughSudo, runs == .login ? .login : .rootWithPassword)]
    }

    /// A step as the file has it: its action and its parameters, and its programs in the order they run.
    static func step(_ plan: InstallPlan, _ step: InstallStep, key: String?) -> [String: Any] {
        var out: [String: Any] = ["id": step.id, "title": step.title, "says": step.says]
        var programs: [[String: Any]] = []
        switch step.action {
        case .check(let every, let within):
            out["action"] = "check"; out["every"] = every; out["within"] = within
            programs.append(program(plan, "/bin/sh -s", input: ServerCheck.script, runs: .login))
        case .run(let text):
            out["action"] = "run"
            programs.append(program(plan, text, input: nil, runs: .root))
        case .join(let line):
            // The installer puts the word that leaves the line's checks to the plan's own step before the line.
            out["action"] = "join"; out["line"] = line
            programs.append(program(plan, InstallPlan.verifyLater + line, input: nil, runs: .root))
        case .sendAuthKey(let text):
            out["action"] = "send_auth_key"
            programs.append(program(plan, text, input: key, runs: .root))
        case .detach(let text):
            out["action"] = "detach"
            programs.append(program(plan, text, input: nil, runs: .root))
        case .waitFor(let text, let mark, let every, let within):
            out["action"] = "wait_for"; out["mark"] = mark; out["every"] = every; out["within"] = within
            programs.append(program(plan, text, input: nil, runs: .root))
        case .waitForClaim(let text, let every, let within):
            out["action"] = "wait_for_claim"; out["mark"] = ClaimCode.logMark; out["every"] = every
            out["within"] = within
            programs.append(program(plan, text, input: nil, runs: .root))
        case .signIn(let start, let check, let every, let within):
            out["action"] = "sign_in"; out["every"] = every; out["within"] = within
            programs.append(program(plan, start, input: nil, runs: .root))
            programs.append(program(plan, check, input: nil, runs: .root))
        case .claim:
            out["action"] = "claim"
        case .verify(let text):
            out["action"] = "verify"
            programs.append(program(plan, text, input: nil, runs: .root))
        }
        out["programs"] = programs
        return out
    }

    static func programsDocument() -> [String: Any] {
        let plans: [[String: Any]] = plans().map { name, inputs, plan in
            ["name": name, "inputs": inputs, "job": plan.job.rawValue, "installs": plan.installs,
             "redactions": plan.redactions,
             "steps": plan.steps.map { step(plan, $0, key: inputs["auth_key"] as? String) }]
        }
        return ["about": "Each step of the Mac's install plans (FleetCore/MachineInstall.swift) for fixed example inputs: "
                    + "each program that the step runs on the server, in order, with its standard input, who runs it, and "
                    + "the command that ssh gets for it: as root (as_root), as a user that becomes root with sudo -n "
                    + "(through_sudo), and as one whose sudo reads the password from the first line of its input "
                    + "(with_password). The targets: root at 203.0.113.10:22, and admin at 203.0.113.10:2222. The Windows "
                    + "app's IRemote gets the command as its program.",
                "made_by": madeBy, "check_script": ServerCheck.script, "plans": plans,
                "targets": ["as_root": ["host": asRoot.host, "user": asRoot.user, "port": asRoot.port],
                            "through_sudo": ["host": throughSudo.host, "user": throughSudo.user,
                                             "port": throughSudo.port]]]
    }

    // MARK: - The reads

    static func claimCodes() -> [String: Any] {
        let logs = [
            "FLEET_CLAIM=ABCD-EFGH-JKLM sh -c \"$(curl -fsS http://100.64.0.7:8765/claim)\"",
            "Founderizer step 12: the owner claim\nFLEET_CLAIM=abcd-efgh-jklm sh -c \"$(curl -fsS http://100.99.1.2:8765/claim)\"\nwaiting",
            "FLEET_CLAIM=ABCD-EFGH-JKLM sh -c \"$(curl -fsS http://100.64.0.7:8765/claim)\"\n"
                + "FLEET_CLAIM=MNPQ-RSTU-VWXY sh -c \"$(curl -fsS http://100.64.0.10:8765/claim)\"",
            "FLEET_CLAIM=MNPQ-RSTU-VWXY sh -c \"$(curl -fsS http://100.64.0.10:8765/claim)\"\n"
                + "FLEET_CLAIM=ABCD-EFGH-JKLM sh -c \"$(curl -fsS http://203.0.113.9:8765/claim)\"",
            "FLEET_CLAIM=ABCD-EFGH-IJKO sh -c \"$(curl -fsS http://100.64.0.7:8765/claim)\"",
            "FLEET_CLAIM=ABCD-EFGH-JKLM sh -c \"$(curl -fsS https://100.64.0.7:8765/claim)\"",
            "FLEET_CLAIM=ABCD-EFGH-JKLM sh -c \"$(curl -fsS http://100.128.0.1:8765/claim)\"",
            "FLEET_CLAIM=ABCD-EFGH-JKLM sh -c \"$(curl -fsS http://100.64.0.7:8765/claim/more)\"",
            "FLEET_CLAIM=ABCD-EFGH-JKLM sh -c \"$(curl -fsS http://100.64.0.7:123456/claim)\"",
            "this hub belongs to the Mac at 100.64.0.2 already, so no code was made",
            "",
        ]
        let found: [[String: Any]] = logs.map { log in
            let read = ClaimCode.found(in: log)
            return ["log": log, "code": orNull(read?.code), "claim": orNull(read?.claim.absoluteString)]
        }
        let given = ["abcd efgh jklm", "ABCD-EFGH-JKLM", "ABCDEFGHJKL", "ABCDEFGHJKLMN", " abcd-efgh-jklm\n", "IIII-OOOO-1111",
                     "abcd-efgh-jkl0"]
        let read: [[String: Any]] = given.map { ["given": $0, "code": orNull(ClaimCode.read($0))] }
        let hosts = ["100.64.0.1", "100.127.255.255", "100.128.0.1", "10.0.0.1", "100.64.0", "fd7a::1",
                     "100.64.0.1.5", "a.b.c.d", "100.064.0.1"]
        let privates: [[String: Any]] = hosts.map { ["host": $0, "private": ClaimCode.isPrivateAddress($0)] }
        return ["found": found, "read": read, "grouped": [["code": code, "grouped": ClaimCode.grouped(code)]],
                "private": privates, "log_mark": ClaimCode.logMark, "alphabet": ClaimCode.alphabet]
    }

    static func signIns() -> [String: Any] {
        let cases: [[String]] = [
            ["fleet-machine-name=web-1", "To authenticate, visit:", "https://login.tailscale.com/a/abc123def456"],
            ["fleet-machine-name=Web_1", "https://login.tailscale.com/a/abc123def456"],
            ["fleet-machine-name=web-1", "https://login.tailscale.com/a/abc"],
            ["fleet-machine-name=web-1", "https://evil.example/a/abc123def456"],
            ["fleet-machine-name=web-1", "https://login.tailscale.com/a/abc123def456",
             "https://login.tailscale.com/a/zzz999yyy888"],
            ["fleet-machine-name=web-1", "fleet-on-network", "100.64.0.9"],
            ["fleet-machine-name=web-1", "fleet-sign-in-ended 0"],
            ["fleet-machine-name=web-1", "timeout waiting for Tailscale service to enter a Running state", "fleet-sign-in-ended 1"],
            ["fleet-machine-name=web-1", "requested tags [tag:founderizer] are invalid or not permitted", "fleet-sign-in-ended 1"],
            ["fleet-machine-name=web-1", "backend error: something", "fleet-sign-in-ended 1"],
            ["fleet-machine-name=web-1"],
            [],
        ]
        let read: [[String: Any]] = cases.map { lines in
            let found = NetworkSignIn.found(in: lines)
            var reading: [String: Any]
            switch NetworkSignIn.read(lines) {
            case .on: reading = ["state": "on"]
            case .ended(let says): reading = ["state": "ended", "says": says]
            case .waiting(let link): reading = ["state": "waiting", "url": orNull(link?.url.absoluteString)]
            }
            return ["lines": lines, "url": orNull(found?.url.absoluteString), "server": orNull(found?.server),
                    "reading": reading]
        }
        let lines = [joinLine(tags: "tag:founderizer"), joinLine(tags: "tag:founderizer,tag:web"), joinLine(tags: nil),
                     joinLine(tags: "tag:Bad"), joinLine(tags: "tag:a;rm"), "tailscale up --advertise-tags=tag:x,tag:y-2",
                     "tailscale up --advertise-tags="]
        let tags: [[String: Any]] = lines.map { ["line": $0, "tags": NetworkSignIn.tags(inLine: $0)] }
        return ["read": read, "tags": tags,
                "words": ["not_on_network": NetworkSignIn.notOnNetwork, "not_approved": NetworkSignIn.notApproved,
                          "not_started": NetworkSignIn.notStarted]]
    }

    static func planReads() -> [String: Any] {
        let addresses: [[String]] = [["Tailscale is up", "100.64.0.9"], ["100.64.0.9", "100.64.0.10"], ["203.0.113.9"],
                                     ["100.64.0.9 ", "fd7a:115c:a1e0::9"], [], ["100.128.0.1"]]
        let says = ["This machine is not on your private network. Give the Tailscale key of your fleet.",
                    "Founderizer install stopped: No Tailscale auth key came in.",
                    "Founderizer join stopped: Tailscale did not join with that auth key.",
                    "Founderizer join stopped: The join code expired.", ""]
        let stops: [[String]] = [["a", "Founderizer install stopped: Could not clone."], ["Fleet join stopped: x", "b"],
                                 ["Fleet install stopped: one", "Founderizer join stopped: two"], ["nothing", "here"], []]
        return ["private_address": addresses.map { ["lines": $0, "address": orNull(InstallPlan.privateAddress(in: $0))] },
                "needs_network_key": says.map { ["says": $0, "needs": InstallPlan.needsNetworkKey($0)] },
                "stop_line": stops.map { ["lines": $0, "line": orNull(InstallPlan.stopLine(in: $0))] },
                "stop_marks": InstallPlan.stopMarks, "hub_systems": InstallPlan.hubSystems,
                "join_systems": InstallPlan.joinSystems]
    }

    static func causes() -> [[String: Any]] {
        var sentences = InstallCause.rows.map { $0.whole ? $0.part : "Founderizer \($0.part) here." }
        sentences += ["Timed out", "  timed out \n", "The hub timed out at noon.", "Something we do not know.", "",
                      "Could not clone the Founderizer repository from its address: git did not finish.",
                      "The packages of this system could not be installed: apt-get did not finish.",
                      "The OS user fleet-wren could not be made.", "This system is Fedora 40."]
        return sentences.map { ["sentence": $0, "cause": InstallCause.of(sentence: $0).rawValue] }
    }

    static func retries() -> [String: Any] {
        func decision(_ stop: InstallRecord.Stop, _ cause: InstallCause?, _ job: InstallJob, _ step: String?,
                      tries: Int = 1, key: Bool = false, sudo: Bool = false) -> [String: Any] {
            let made = InstallRetry.decision(stop: stop, cause: cause, job: job, step: step, tries: tries,
                                             needsNetworkKey: key, usedSudoPassword: sudo)
            var out: [String: Any] = ["stop": stop.rawValue, "cause": orNull(cause?.rawValue), "job": job.rawValue,
                                      "step": orNull(step), "tries": tries, "needs_network_key": key,
                                      "used_sudo_password": sudo]
            if let made {
                var wait: [String: Any] = ["kind": "nothing"]
                if case .reads(let count, let until) = made.wait { wait = ["kind": "reads", "count": count, "until_answer": until] }
                out["retry"] = ["wait": wait, "fresh_code": made.freshCode]
            } else {
                out["retry"] = NSNull()
            }
            return out
        }
        var cases: [[String: Any]] = []
        for job in InstallJob.allCases {
            for cause in [nil] + InstallCause.allCases.map({ Optional($0) }) { cases.append(decision(.installerStopped, cause, job, "join")) }
            for step in [nil, "read", "network", "code", "plan", "start", "wait_claim", "join", "verify"] {
                cases.append(decision(.serverUnreached, nil, job, step))
            }
            for stop in InstallRecord.Stop.allCases where ![InstallRecord.Stop.installerStopped, .serverUnreached].contains(stop) {
                cases.append(decision(stop, nil, job, "code"))
            }
        }
        cases.append(decision(.installerStopped, .hubBusy, .join, "join", tries: 2))
        cases.append(decision(.installerStopped, .hubBusy, .join, "join", tries: 3))
        cases.append(decision(.installerStopped, .privateNetwork, .join, "network", key: true))
        cases.append(decision(.installerStopped, .packages, .hub, "code", sudo: true))
        cases.append(decision(.serverUnreached, nil, .hub, "code", tries: 3))
        let codes: [[String: Any]] = [(1000.0, 400.0), (1000.0, 401.0), (1000.0, 399.0), (1000.0, 1000.0), (500.0, 0.0)].map {
            ["expires_at": $0.0, "now": $0.1, "keeps": InstallRetry.keepsCode(expiresAt: $0.0, now: $0.1)]
        }
        return ["decisions": cases, "keeps_code": codes, "most": InstallRetry.most,
                "code_left_at_least": InstallRetry.codeLeftAtLeast, "read_every": InstallRetry.readEvery]
    }

    static func phases() -> [String: Any] {
        typealias Reported = (String, InstallProgress.State, [String])
        let hub = InstallPlan.hub(target: asRoot, source: InstallPlan.defaultSource, authKey: nil).steps.map(\.id)
        let join = InstallPlan.join(target: asRoot, line: joinLine(tags: nil), code: code, authKey: nil).steps.map(\.id)
        let restart = InstallPlan.restart(target: asRoot, machine: .hub).steps.map(\.id)
        let cases: [(String, [Reported], [String], Double)] = [
            ("nothing reported yet", [], hub, 0),
            ("the network runs", [("read", .done, []), ("network", .running, [])], hub, 20),
            ("the wait for the code", [("read", .done, []), ("network", .done, []), ("code", .done, []), ("plan", .done, []),
                                       ("start", .done, []), ("wait_claim", .running, [])], hub, 10),
            ("the security updates", [("read", .done, []), ("network", .done, []), ("code", .done, []), ("plan", .done, []),
                                      ("start", .done, []), ("wait_claim", .done, []), ("claim", .done, []),
                                      ("wait_ready", .running, ["Founderizer step 13: the firewall",
                                                                "Founderizer step 14: security updates"])], hub, 300),
            ("the installer's own checks", [("read", .done, []), ("network", .done, []), ("code", .done, []),
                                            ("plan", .done, []), ("start", .done, []), ("wait_claim", .done, []),
                                            ("claim", .done, []),
                                            ("wait_ready", .running, ["Founderizer step 15: verify the hub"])], hub, 700),
            ("the wait with no step yet", [("read", .done, []), ("network", .done, []), ("code", .done, []), ("plan", .done, []),
                                           ("start", .done, []), ("wait_claim", .done, []), ("claim", .done, []),
                                           ("wait_ready", .running, ["apt says something"])], hub, 0),
            ("the claim runs", [("read", .done, []), ("network", .done, []), ("code", .done, []), ("plan", .done, []),
                                ("start", .done, []), ("wait_claim", .done, []), ("claim", .running, [])], hub, 4),
            ("the checks run", hub.dropLast().map { ($0, InstallProgress.State.done, [String]()) }
                + [("verify", InstallProgress.State.running, [String]())], hub, 30),
            ("every step done", hub.map { ($0, InstallProgress.State.done, [String]()) }, hub, 0),
            ("a join past its estimate", [("read", .done, []), ("network", .done, []), ("join", .running, [])], join, 500),
            ("a join inside its estimate, with a heading that the app does not count",
             [("read", .done, []), ("network", .done, []), ("join", .running, ["Founderizer step 3: base packages"])],
             join, 359),
            ("the hub's hardening after its security updates",
             [("read", .done, []), ("network", .done, []), ("code", .done, []), ("plan", .done, []), ("start", .done, []),
              ("wait_claim", .done, []), ("claim", .done, []),
              ("wait_ready", .running, ["Founderizer step 17: this server's own hardening"])], hub, 620),
            ("a join's checks", [("read", .done, []), ("network", .done, []), ("join", .done, []), ("verify", .running, [])],
             join, 20),
            ("a heading past the installer's count", [("read", .done, []), ("network", .done, []), ("code", .done, []),
                                                      ("plan", .done, []), ("start", .done, []), ("wait_claim", .done, []),
                                                      ("claim", .done, []),
                                                      ("wait_ready", .running, ["Founderizer step 99: a new part"])],
             hub, 0),
            ("a step that failed", [("read", .done, []), ("network", .failed, [])], join, 50),
            ("a negative time", [("read", .running, [])], join, -5),
            ("a step that the plan does not know", [("read", .done, []), ("network", .done, []), ("other", .running, [])],
             join, 10),
            ("a restart has no network step", [("mark", .done, [])], restart, 0),
        ]
        let read: [[String: Any]] = cases.map { name, reported, planned, running in
            let progress = reported.map { InstallProgress(step: $0.0, title: $0.0, says: "", state: $0.1, lines: $0.2) }
            var out: [String: Any] = ["name": name, "planned": planned, "running_for": running,
                                      "reported": reported.map { ["step": $0.0, "state": $0.1.rawValue, "lines": $0.2] }]
            if let phases = InstallPhases(steps: progress, planned: planned, runningFor: running) {
                out["phases"] = ["current": phases.current, "minutes_left": orNull(phases.minutesLeft),
                                 "status": orNull(phases.status), "parts": phases.parts, "step": orNull(phases.step)]
            } else {
                out["phases"] = NSNull()
            }
            return out
        }
        let lines = ["Founderizer step 14: security updates", "Founderizer step 3:   the code  ", "Founderizer step 4:",
                     "Founderizer step x: no", "  Founderizer step 5: indented", "Founderizer step 15: verify"]
        return ["cases": read, "names": InstallPhases.names, "seconds": InstallPhases.seconds,
                "other_step": InstallPhases.otherStep, "installer_headings": InstallPhases.installerHeadings,
                "heading_lines": ["hub": headingLines(InstallPhases.hubHeadings, join: false),
                                  "join": headingLines(InstallPhases.joinHeadings, join: true)],
                "installer_step": lines.map { ["line": $0, "words": orNull(InstallPhases.installerStep($0))] }]
    }

    /// The one table of lines (F4 piece 4): each heading's start of words, with the line that it gives in a running
    /// step of its install.
    static func headingLines(_ table: [(words: String, line: InstallPhases.HeadingLine)], join: Bool) -> [[String: Any]] {
        table.map { row in
            let step = InstallProgress(step: join ? "join" : "wait_ready", title: "", says: "", state: .running,
                                       lines: ["Founderizer step 1: " + row.words])
            return ["words": row.words, "line": orNull(InstallPhases.status(step, join: join))]
        }
    }

    static func checklists() -> [String: Any] {
        let ok = "{\"check\": \"services\", \"state\": \"ok\", \"says\": \"Running.\"}"
        let signIn = "{\"check\": \"runtime_signed_in\", \"state\": \"fail\", \"says\": \"Not signed in.\", \"fix\": \"Sign in.\"}"
        let firewall = "{\"check\": \"firewall\", \"state\": \"fail\", \"says\": \"Off.\", \"fix\": \"Turn it on.\", \"command\": \"ufw enable\"}"
        let clock = "{\"check\": \"clock\", \"state\": \"fail\", \"says\": \"Behind.\", \"fix\": \"Sync it.\"}"
        let disk = "{\"check\": \"disk\", \"state\": \"warn\", \"says\": \"80% full.\", \"fix\": \"Free some space.\"}"
        let team = "{\"check\": \"team\", \"state\": \"ok\", \"says\": \"Read.\"}"
        let newer = "{\"check\": \"new_check\", \"state\": \"ok\", \"says\": \"New.\"}"
        let outputs = [
            "Founderizer step 15: verify\n[\n  \(ok),\n  \(signIn)\n]\nNOT READY: runtime_signed_in",
            "[\(ok), \(team), \(newer)]",
            "[\(newer), \(firewall), \(ok)]\nREADY",
            "[\(firewall), \(clock)]",
            "[\(ok), \(disk)]",
            "[\(ok), \(disk), {\"check\": \"tailnet\", \"state\": \"warn\", \"says\": \"Slow.\", \"fix\": \"Look.\"}]",
            "[]",
            "[\(ok), {\"check\": \"clock\", \"state\": \"maybe\", \"says\": \"x\"}]",
            "[\(ok), \(ok)]",
            "[{\"check\": \"services\", \"state\": \"ok\", \"says\": \"Running.\", \"fix\": \"none\"}]",
            "[{\"check\": \"Services\", \"state\": \"ok\", \"says\": \"Running.\"}]",
            "Traceback (most recent call last):\n  File \"fleet.py\", line 3, in <module>\n    x = [a for a in b]\nNameError: name 'b' is not defined",
            "printed \"check\" with [1, 2] and no list",
            "[[{\"check\": \"services\", \"state\": \"ok\", \"says\": \"Running.\"}]]",
            "start [ { not json } ] then [\(ok)]",
            "",
        ]
        let read: [[String: Any]] = outputs.map { output in
            var out: [String: Any] = ["output": output, "holds_list": VerifyChecklist.holdsList(output)]
            if let list = VerifyChecklist.read(output: output) {
                out["read"] = ["ids": list.checks.map(\.check), "line": list.line, "ready": list.isReady,
                               "only_needs_sign_in": list.onlyNeedsSignIn, "summary": list.summary,
                               "said": list.said.map(\.check), "our_own_passed": list.ourOwnPassed,
                               "fixes": list.checks.map { orNull($0.fix) },
                               "commands": list.checks.map { orNull($0.command) }]
            } else {
                out["read"] = NSNull()
            }
            return out
        }
        let titles = (VerifyChecklist.ids + ["new_check", "a_b"]).map { ["id": $0, "title": VerifyChecklist.title($0)] }
        return ["outputs": read, "titles": titles, "ids": VerifyChecklist.ids, "ready_line": VerifyChecklist.readyLine]
    }

    static func serverChecks() -> [String: Any] {
        let ready = MachineInstallTests.ready
        func reading(_ text: String) -> Any {
            guard let r = ServerCheck.read(text) else { return NSNull() }
            let tailscale: String, tailnet: Any
            switch r.tailscale {
            case .none: tailscale = "none"; tailnet = NSNull()
            case .loggedOut: tailscale = "loggedout"; tailnet = NSNull()
            case .running(let name): tailscale = "running"; tailnet = orNull(name)
            }
            return ["user": r.user, "uid": r.uid, "sudo": r.sudo.rawValue, "system": r.system, "version": r.version,
                    "system_name": r.systemName, "arch": r.arch, "memory_mb": orNull(r.memoryMB),
                    "disk_free_mb": orNull(r.diskFreeMB), "systemd": r.systemd, "ipv4_route": r.ipv4Route,
                    "reach": r.reach.mapValues(\.rawValue), "cloud_init": r.cloudInit.rawValue, "dpkg_lock": r.dpkgLock,
                    "listeners": r.listeners.map { ["proto": $0.proto, "port": $0.port, "process": $0.process] },
                    "firewall": r.firewall.rawValue, "tailscale": tailscale, "tailnet": tailnet]
        }
        func with(_ changes: [String]) -> String {
            let keys = Set(changes.map { String($0.split(separator: "=", maxSplits: 1)[0]) })
            return (ready.filter { !keys.contains(String($0.split(separator: "=", maxSplits: 1)[0])) } + changes)
                .joined(separator: "\n")
        }
        let outputs = [
            ready.joined(separator: "\n"),
            (ready + ["listen=tcp/80/nginx", "listen=tcp/80/nginx", "listen=udp/41641/-", "listen=tcp/x/y", "listen=tcp/0/z",
                      "listen=sctp/9/a", "listen=tcp/8080/", "reach=evil.example yes", "reach=github.com maybe",
                      "sudo: a password is required", "tailnet=owner@example.com", "=novalue", "user=second"])
                .joined(separator: "\r\n").replacingOccurrences(of: "tailscale=none", with: "tailscale=running"),
            with(["tailscale=running", "tailnet="]),
            with(["tailscale=loggedout", "sudo=password", "uid=1000", "user=admin", "memory_mb=", "disk_free_mb=x"]),
            with(["cloud_init=weird", "ufw=active", "dpkg_lock=yes", "systemd=no", "ipv4_route=no"]),
            ready.dropLast().joined(separator: "\n"),
            with(["uid=zero"]),
            with(["user="]),
            "  user=root  \n uid=0\nend=yes",
            "",
        ]
        struct Verdicting { let name: String; let changes: [String]; let job: InstallJob; let port: Int; let holds: Bool; let tailnet: String? }
        let verdicts: [Verdicting] = [
            .init(name: "ready for a join", changes: [], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "ready for a hub", changes: [], job: .hub, port: 22, holds: false, tailnet: nil),
            .init(name: "Debian 13", changes: ["os_id=debian", "os_version=13", "os_name=Debian GNU/Linux"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "another system, hub", changes: ["os_id=centos", "os_version=9"], job: .hub, port: 22, holds: false, tailnet: nil),
            .init(name: "another system, join", changes: ["os_id=ubuntu", "os_version=20.04"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "a 32-bit Arm", changes: ["arch=armv7l"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "an unknown kind", changes: ["arch="], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "Arm", changes: ["arch=aarch64", "memory_mb=7900"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "no systemd", changes: ["systemd=no"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "a user with no sudo", changes: ["user=ada", "uid=1000", "sudo=none"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "a small server for agents", changes: ["memory_mb=950"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "enough for a hub", changes: ["memory_mb=1910"], job: .hub, port: 22, holds: false, tailnet: nil),
            .init(name: "a small disk", changes: ["disk_free_mb=900"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "no IPv4 route", changes: ["ipv4_route=no"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "no GitHub", changes: ["reach=github.com no"], job: .hub, port: 22, holds: false, tailnet: nil),
            .init(name: "no GitHub and no Tailscale", changes: ["reach=github.com no", "reach=tailscale.com no"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "no AI for a join", changes: ["reach=claude.ai no", "reach=chatgpt.com no"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "no AI for a hub", changes: ["reach=claude.ai no", "reach=chatgpt.com no"], job: .hub, port: 22, holds: false, tailnet: nil),
            .init(name: "one AI for a join", changes: ["reach=claude.ai no"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "nothing to fetch with", changes: ["reach=github.com none", "reach=tailscale.com none"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "another tailnet", changes: ["tailscale=running", "tailnet=other.example"], job: .join, port: 22, holds: false, tailnet: "fleet.example"),
            .init(name: "the same tailnet", changes: ["tailscale=running", "tailnet=Fleet.Example"], job: .join, port: 22, holds: false, tailnet: "fleet.example"),
            .init(name: "a tailnet with no name of ours", changes: ["tailscale=running", "tailnet=other.example"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "a sudo that asks", changes: ["user=admin", "uid=1000", "sudo=password"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "a sudo that asks, with its password", changes: ["user=admin", "uid=1000", "sudo=password"], job: .join, port: 22, holds: true, tailnet: nil),
            .init(name: "a sudo that asks nothing", changes: ["user=admin", "uid=1000", "sudo=nopasswd"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "still starting", changes: ["cloud_init=running"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "installing updates", changes: ["dpkg_lock=yes"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "a sudo that asks while starting", changes: ["user=admin", "uid=1000", "sudo=password", "cloud_init=running"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "ports that stay open", changes: ["listen=tcp/80/nginx", "listen=tcp/443/caddy", "listen=tcp/2222/sshd", "listen=udp/53/dns", "listen=tcp/9000/ssh"], job: .join, port: 2222, holds: false, tailnet: nil),
            .init(name: "SSH on another port", changes: ["listen=tcp/2222/-"], job: .join, port: 2222, holds: false, tailnet: nil),
            .init(name: "no port but SSH", changes: ["listen=tcp/22/sshd"], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "memory not read", changes: ["memory_mb="], job: .join, port: 22, holds: false, tailnet: nil),
            .init(name: "a hub on a plan sold as 1 GB", changes: ["memory_mb=957"], job: .hub, port: 22, holds: false, tailnet: nil),
        ]
        let judged: [[String: Any]] = verdicts.map { v in
            let output = with(v.changes)
            var out: [String: Any] = ["name": v.name, "output": output, "job": v.job.rawValue, "ssh_port": v.port,
                                      "holds_sudo_password": v.holds, "tailnet": orNull(v.tailnet)]
            guard let read = ServerCheck.read(output) else { out["verdict"] = NSNull(); return out }
            switch ServerCheck.verdict(read, job: v.job, sshPort: v.port, holdsSudoPassword: v.holds, tailnet: v.tailnet) {
            case .ready(let summary, let changes): out["verdict"] = ["kind": "ready", "summary": summary, "changes": changes]
            case .wait(let says): out["verdict"] = ["kind": "wait", "says": says]
            case .needsPassword(let need): out["verdict"] = ["kind": "needs_password", "need": need.rawValue]
            case .stop(let says): out["verdict"] = ["kind": "stop", "says": says]
            }
            return out
        }
        let unreachedCases: [(String, String)] = [
            ("refused", "ssh: connect to host 203.0.113.9 port 22: connection refused"),
            ("no_answer", "ssh: connect to host 203.0.113.9 port 2222: operation timed out"),
            ("not_found", "ssh: could not resolve hostname vps.example: nodename nor servname provided"),
            ("closed", "kex_exchange_identification: connection closed by remote host"),
            ("closed", "connection reset by 203.0.113.9 port 22"),
            ("other", "something else"),
        ]
        let unreached: [[String: Any]] = unreachedCases.map { kind, said in ["kind": kind, "said": said, "server": "203.0.113.9",
                               "words": ServerCheck.unreached("203.0.113.9", said: said)] }
        let dropped = FleetReach.dropped("ssh: connect to host 100.64.0.9 port 22: operation timed out", host: "100.64.0.9",
                                         place: nil)
        return ["script_keys_sample": ready, "readings": outputs.map { ["output": $0, "reading": reading($0)] },
                "verdicts": judged, "unreached": unreached,
                "words": ["title": ServerCheck.title, "not_root": ServerCheck.notRoot("ada"),
                          "unreached": ServerCheck.unreached("203.0.113.9"),
                          "key_refused": ServerCheck.keyRefused("203.0.113.9"),
                          "host_key_changed": ServerCheck.hostKeyChanged("203.0.113.9"),
                          "no_answer": ServerCheck.noAnswer("203.0.113.9"),
                          "dropped_on_the_private_network": orNull(dropped)],
                "hosts": ServerCheck.hosts]
    }

    static func errors() -> [[String: Any]] {
        let cases: [(String, InstallError)] = [
            ("an installer's stop", .step("The plan", "Founderizer install stopped: Could not clone the Founderizer repository from its address: git did not finish. Check the address, then run the line again.")),
            ("a join's stop in the old brand", .step("Join the fleet", "Fleet join stopped:   the join code expired.")),
            ("a stop mark with no reason", .step("Join the fleet", "Founderizer join stopped:")),
            ("a hub that serves another computer", .step("Wait for the link code", MachineInstaller.notThisMacs)),
            ("a server that printed no user", .step(ServerCheck.title, "It did not answer which user this is.")),
            ("an address off the network", .step("Claim the hub", MachineInstaller.notOnYourNetwork)),
            ("a refused code", .step("Claim the hub", "The hub refused the link code.")),
            ("a link not approved", .step("The private network", NetworkSignIn.notApproved)),
            ("Tailscale not started", .step("The private network", NetworkSignIn.notStarted)),
            ("a join that did not reach the checks", .step("Join the fleet", "The join did not reach the checks of this server.")),
            ("the systems of an install", .step(ServerCheck.title, InstallPlan.hubSystems)),
            ("a program's own words", .step("The Founderizer code", "fatal: unable to access 'https://github.com/': timed out")),
            ("a status with no words", .step("The plan", "The server answered 2.")),
            ("not root", .notRoot("ada")),
            ("too long", .timedOut("Wait for the link code")),
            ("no link code", .noClaimCode),
            ("no checklist", .noChecklist),
            ("the check stopped", .checkStopped("This server does not run systemd, and this install needs a full VPS that does.")),
            ("a sudo password", .needsPassword(.sudo)),
            ("an SSH password", .needsPassword(.ssh)),
            ("a step that cannot start", .cannotStart("The hub gave no join line.")),
        ]
        return cases.map { name, error in
            ["name": name, "description": orNull(error.errorDescription), "plain": error.plain(host: "203.0.113.9", place: nil),
             "plain_with_no_host": error.plain(host: "", place: nil), "stop": InstallRecord.Stop.of(error).rawValue,
             "cause": orNull(InstallCause.of(error)?.rawValue),
             "kept_words": orNull(InstallRecord.words(of: error, host: "203.0.113.9"))]
        }
    }

    static func readsDocument() -> [String: Any] {
        ["about": "Example outputs of a server, a log or an installer, and what the Mac's FleetCore reads from them; and "
            + "the words of an install's stops, with \"Mac\" where the Windows app says \"PC\".",
         "made_by": madeBy, "claim_code": claimCodes(), "network_sign_in": signIns(), "plan": planReads(),
         "install_cause": causes(), "install_retry": retries(), "install_phases": phases(),
         "verify_checklist": checklists(), "server_check": serverChecks(), "install_errors": errors(),
         "stops": InstallRecord.Stop.allCases.map(\.rawValue), "causes": InstallCause.allCases.map(\.rawValue),
         "step_ids": InstallRecord.stepIDs]
    }

    /// A value, or JSON's null.
    static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    static func encoded(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    @Test("The install's vectors are what FleetCore gives now")
    func theInstallVectorsAreTheCommittedFiles() throws {
        let made = try Localized.$bundle.withValue(WordsVectorsTests.noTable) {
            [Self.programsFile: try Self.encoded(Self.programsDocument()), Self.readsFile: try Self.encoded(Self.readsDocument())]
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
