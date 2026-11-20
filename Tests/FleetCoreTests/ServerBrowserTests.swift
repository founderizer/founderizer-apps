import Foundation
import Testing
@testable import FleetCore

/// The agents' browser parts on a Linux server, put in place and taken away by the owner's Mac (`ServerBrowser`): the
/// contract's bytes, which devops's checker on the fleet's workers holds too; the ports and the table; what a round does
/// with a server; how often; and the program on a server, in this Mac's `/bin/sh` and in dash (the `/bin/sh` of
/// Ubuntu), under a folder that stands for the server's root, with stand-ins for the commands that need root or Linux.
struct ServerBrowserTests {
    static let time: Double = 1_000_000
    typealias Ports = ServerBrowser.Ports

    // MARK: the contract

    /// The pinned files of devops's `scripts/fleet-browser/README.md`, Chrome's own source text of
    /// `contract/google-chrome.sources`, and Google's key as `gpg --export` gives it from its published file: a change of
    /// one of them here without the same change there is a critical alert on every worker that has the parts.
    @Test func theBytesAreTheOnesThatDevopsPins() {
        #expect(ServerBrowser.hash(ServerBrowser.unitText) == "db6d3babc9f9a7f89e1b7013973afddac88157d84049f8595fa023e738e4c00d")
        #expect(ServerBrowser.hash(ServerBrowser.dropinText) == "11463a3174710b69b83579c5336f18251fee018246339328069b5422036685db")
        #expect(ServerBrowser.hash(ServerBrowser.defaultText) == "fa648bc9a17ed58b5769bc5ba1f3fb7cd384932d4c2873408384311366133b6f")
        #expect(ServerBrowser.hash(ServerBrowser.originText) == "daafc56e17cc22bce24ab827ea3e6eae989858a09e31e8a19fd9b5195c324e79")
        #expect(ServerBrowser.hash(ServerBrowser.fixedText) == "7618e54ad9d546b4ecc5fdae51f54d88fb265765d4b27039f9fe5e8422bcc889")
        #expect(ServerBrowser.hash(ServerBrowser.sourceText) == "4377e894b3e7956b74d467118164b7023e9b0f0f4c151e464d00991e30f924ac")
        #expect(ServerBrowser.keyData.count == 14_444)
        #expect(ServerBrowser.hash(ServerBrowser.keyData) == "0631021cd0efb5ebe428b09b003e4dc45f9c8cd1c47befd5196906768eff96e0")
    }

    /// The generated policy is this app's own lists (plan 04, D12) in the shape that devops's checker takes: one JSON
    /// object of printable ASCII with a final new line, `URLBlocklist` with at least the providers' sign-in sites of 17
    /// November 2026, and each host of `URLAllowlist` under one of them.
    @Test func thePolicyIsThisAppsListsInTheShapeOfTheContract() throws {
        let text = ServerBrowser.policyText
        #expect(text.hasSuffix("}\n") && text.utf8.allSatisfy { (0x20...0x7e).contains($0) || $0 == 0x0a })
        let policy = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String]])
        #expect(Set(policy.keys) == ["URLBlocklist", "URLAllowlist"])
        #expect(policy["URLBlocklist"] == ["file://*", "chrome://password-manager"] + ProviderSites.sites)
        #expect(policy["URLAllowlist"] == ProviderSites.keySites)
        #expect(Set(["claude.ai", "claude.com", "chatgpt.com", "auth.openai.com", "x.ai"])
                    .isSubset(of: policy["URLBlocklist"] ?? []))
        for host in ProviderSites.keySites {
            #expect(ProviderSites.sites.contains { host.hasSuffix("." + $0) }, "\(host)")
        }
    }

    /// devops's `contract/table.nft` for its `contract/ports` and `contract/passwd` (fleet 1000, fleet-vault 1001,
    /// fleet-alpha 1002, fleet-beta 1003), byte for byte. Without a broker the table lets fewer users in, and a row
    /// whose user has no uid makes no table. Each rule holds for local traffic only, and the last rule closes every
    /// port of both ranges that no row holds: the port of an agent whose row went, while its Chrome still runs, is open
    /// to no other user, and a connection to another host on such a port is left alone.
    @Test func theTableIsTheContractsTable() {
        let rows = [Ports(user: "fleet-alpha", devtools: 9311, screen: 5911),
                    Ports(user: "fleet-beta", devtools: 9312, screen: 5912)]
        let uids = ["fleet-alpha": 1002, "fleet-beta": 1003]
        #expect(ServerBrowser.portsText(rows) == "fleet-alpha 9311 5911\nfleet-beta 9312 5912\n")
        #expect(ServerBrowser.table(rows, uids: uids, broker: 1001, worker: 1000) ==
            "# Founderizer writes this table whole from /etc/fleet-browser/ports (plan 04, D11).\n"
            + "table inet fleet_browser\ndelete table inet fleet_browser\ntable inet fleet_browser {\n\tchain out {\n"
            + "\t\ttype filter hook output priority 0; policy accept;\n"
            + "\t\toifname \"lo\" tcp dport 9311 meta skuid != { 0, 1001, 1002 } reject with tcp reset\n"
            + "\t\toifname \"lo\" tcp dport 5911 meta skuid != { 0, 1000 } reject with tcp reset\n"
            + "\t\toifname \"lo\" tcp sport { 9311, 5911 } meta skuid != 1002 drop\n"
            + "\t\toifname \"lo\" tcp dport { 9311, 5911 } accept\n"
            + "\t\toifname \"lo\" tcp dport 9312 meta skuid != { 0, 1001, 1003 } reject with tcp reset\n"
            + "\t\toifname \"lo\" tcp dport 5912 meta skuid != { 0, 1000 } reject with tcp reset\n"
            + "\t\toifname \"lo\" tcp sport { 9312, 5912 } meta skuid != 1003 drop\n"
            + "\t\toifname \"lo\" tcp dport { 9312, 5912 } accept\n"
            + "\t\toifname \"lo\" tcp flags & (syn | ack) == syn tcp dport { 5910-5999, 9300-9399 } reject with tcp reset\n"
            + "\t}\n}\n")
        #expect(ServerBrowser.table(rows, uids: uids, broker: nil, worker: 1000)?
                    .contains("\t\toifname \"lo\" tcp dport 9311 meta skuid != { 0, 1002 } reject with tcp reset\n") == true)
        #expect(ServerBrowser.table(rows, uids: ["fleet-alpha": 1002], broker: 1001, worker: 1000) == nil)
    }

    /// A row that stays keeps its place and its ports, and a new agent takes ports that no row had, so that a port
    /// given up in this step goes to nobody else in it. A full range gives no more rows.
    @Test func portsStayAndANewAgentTakesPortsThatNobodyHad() {
        let current = [Ports(user: "fleet-a", devtools: 9300, screen: 5910),
                       Ports(user: "fleet-b", devtools: 9301, screen: 5911),
                       Ports(user: "fleet-c", devtools: 9302, screen: 5912)]
        #expect(ServerBrowser.assign(current, wanted: ["fleet-c", "fleet-d", "fleet-a"])
                == [current[0], current[2], Ports(user: "fleet-d", devtools: 9303, screen: 5913)])
        let full = (0..<90).map { Ports(user: "fleet-a\($0)", devtools: 9300 + $0, screen: 5910 + $0) }
        #expect(ServerBrowser.assign(full, wanted: full.map(\.user) + ["fleet-new"]) == full)
    }

    // MARK: what a round does

    private func agent(_ name: String, can: [String] = ["shell", "browser"]) throws -> FleetAgent {
        try JSONDecoder().decode(FleetAgent.self, from: JSONSerialization.data(withJSONObject: [
            "name": name, "role": "worker", "runtime": "claude", "can": can] as [String: Any]))
    }

    private func task(owner: String, state: String = "working", works: Bool? = nil) throws -> FleetTask {
        let json = "{\"id\": 7, \"title\": \"The shop page\", \"details\": \"\", \"done_when\": \"\", \"needs\": \"\", "
            + "\"goal\": \"\", \"owner\": \"\(owner)\", \"requester\": \"manager\", \"state\": \"\(state)\", "
            + "\"created\": 100, \"attempt\": 1, \"restarts\": 0, \"nudge_level\": 0, \"stop_sent\": 0"
            + (works.map { ", \"works\": \($0)" } ?? "") + "}"
        return try JSONDecoder().decode(FleetTask.self, from: Data(json.utf8))
    }

    /// A Linux server that joined, with alpha (fleet-alpha, 1002) and beta (fleet-beta, 1003) on it, the service's
    /// user fleet (1000), the broker 1001, and by default none of the parts.
    private func server(state: String? = "missing", ports: [[String: Any]] = [], files: [String: String] = [:],
                        missing: [String] = ServerBrowser.packages, unit: String? = "inactive", added: Bool = false,
                        broker: Int? = 1001, job: String? = nil, hub: Bool = false, source: String = "server",
                        reportedAt: Double = time - 60, users: [String: Any]? = nil, browser: Bool = true,
                        kept: Bool? = nil, chrome: String? = nil) throws -> ServerEntry {
        var parts: [String: Any] = ["state": state as Any, "missing": missing, "files": files, "unit": unit as Any,
                                    "ports": ports, "added": added, "worker": 1000, "chrome": chrome as Any]
        if let broker { parts["broker"] = broker }
        if let kept { parts["proof_kept"] = kept }
        var reading: [String: Any] = ["source": source, "os": ["name": "Ubuntu 24.04"], "runtimes": [:],
                                      "reported_at": reportedAt, "stale": false, "user": "fleet",
                                      "agents": users ?? ["alpha": ["user": "fleet-alpha", "uid": 1002],
                                                          "beta": ["user": "fleet-beta", "uid": 1003]]]
        if browser { reading["browser"] = parts }
        var entry: [String: Any] = ["name": hub ? "hub" : "app-1", "hub": hub, "joined": !hub, "kind": "linux",
                                    "agents": ["alpha", "beta"], "address": "100.80.1.7", "available": true,
                                    "why": [], "reading": reading]
        if let job {
            entry["job"] = ["id": 4, "kind": "install", "agent": "beta", "state": job, "created": Self.time - 100,
                            "updated": Self.time - 50] as [String: Any]
        }
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    private func work(_ server: ServerEntry, _ agents: [FleetAgent], tasks: [FleetTask] = [],
                      join: JoinState? = nil) -> ServerBrowser.Work? {
        ServerBrowser.work(for: server, agents: agents, tasks: tasks, join: join, at: Self.time)
    }

    /// The files that the step leaves for these rows and this table.
    private func inPlace(_ want: ServerBrowser.Want) -> [String: String] {
        ["unit": ServerBrowser.hash(ServerBrowser.unitText), "dropin": ServerBrowser.hash(ServerBrowser.dropinText),
         "default": ServerBrowser.hash(ServerBrowser.defaultText),
         "origin": ServerBrowser.hash(ServerBrowser.originText), "fixed": ServerBrowser.hash(ServerBrowser.fixedText),
         "policy": ServerBrowser.hash(ServerBrowser.policyText),
         "ports": ServerBrowser.hash(ServerBrowser.portsText(want.rows)), "table": ServerBrowser.hash(want.table),
         "source": String(repeating: "5", count: 64), "key": String(repeating: "6", count: 64)]
    }

    /// An agent with the Browser and Shell boxes gets its ports and the parts; once the reading says that they are as
    /// the step leaves them, a round does nothing; and each thing that differs puts them in place again.
    @Test func aRoundPutsInPlaceWhatDiffersAndNothingElse() throws {
        let agents = [try agent("alpha"), try agent("beta", can: ["shell"])]
        guard case .install(let want)? = work(try server(), agents) else {
            Issue.record("a missing part puts nothing in place"); return
        }
        #expect(want.rows == [Ports(user: "fleet-alpha", devtools: 9300, screen: 5910)])
        #expect(want.uids == ["fleet-alpha": 1002] && want.broker == 1001 && want.worker == "fleet" && want.workerID == 1000)
        let row: [String: Any] = ["user": "fleet-alpha", "devtools": 9300, "screen": 5910]
        let ready = { (files: [String: String], state: String, missing: [String], unit: String, broker: Int?) in
            try self.server(state: state, ports: [row], files: files, missing: missing, unit: unit, added: true,
                            broker: broker, kept: true)
        }
        let files = inPlace(want)
        #expect(work(try ready(files, "ready", [], "active", 1001), agents) == .nothing)
        // A live proof that the service could not keep for the agents' helpers: its folder is made again.
        guard case .install = work(try server(state: "ready", ports: [row], files: files, missing: [], unit: "active",
                                              added: true, kept: false), agents) else {
            Issue.record("a proof that no helper can read leaves the parts as they are"); return
        }
        // The table gone (the live proof), a policy of older lists, a unit that stopped, a package that went, the
        // source that went, and a broker that came after the parts.
        var older = files, noSource = files
        older["policy"] = String(repeating: "7", count: 64)
        noSource["source"] = nil
        for case let server in [try ready(files, "table_missing", [], "active", 1001),
                                try ready(older, "ready", [], "active", 1001),
                                try ready(files, "missing", [], "failed", 1001),
                                try ready(files, "missing", ["libatomic1"], "active", 1001),
                                try ready(noSource, "missing", [], "active", 1001),
                                try ready(files, "ready", [], "active", 1009)] {
            guard case .install = work(server, agents) else { Issue.record("\(server)"); continue }
        }
        // x86 Ubuntu 24.04 and 26.04 only: nothing anywhere else.
        #expect(work(try server(state: "unsupported"), agents) == .nothing)
    }

    /// Only an agent with both boxes and a user of its own wants the parts; with none left, the parts go, and a server
    /// without them stays as it is.
    @Test func whoWantsTheParts() throws {
        // A closed agent (plan 04, D2), an agent that runs as the service's user, and one whose user is not made yet.
        let users: [String: Any] = ["alpha": ["user": "fleet", "uid": 1000], "beta": ["user": NSNull(), "uid": NSNull()]]
        #expect(ServerBrowser.wanted(on: try server(), agents: [try agent("alpha", can: ["browser"])]) == [])
        #expect(ServerBrowser.wanted(on: try server(users: users), agents: [try agent("alpha"), try agent("beta")]) == [])
        #expect(ServerBrowser.wanted(on: try server(), agents: [try agent("beta"), try agent("alpha")])
                == ["fleet-alpha", "fleet-beta"])
        // His untick of the last box: the parts go, recorded or not, and a server with none of them stays as it is.
        let closed = [try agent("alpha", can: ["shell"]), try agent("beta", can: ["shell"])]
        #expect(work(try server(added: true), closed) == .remove)
        #expect(work(try server(files: ["policy": String(repeating: "7", count: 64)]), closed) == .remove)
        #expect(work(try server(ports: [["user": "fleet-alpha", "devtools": 9300, "screen": 5910]]), closed) == .remove)
        #expect(work(try server(), closed) == .nothing)
        // What a removal leaves where Chrome stays (the server had it, or a package of its own needs it): its own
        // files, and nothing of the parts. The removal is over.
        let left = ["source": String(repeating: "5", count: 64), "key": String(repeating: "6", count: 64),
                    "default": ServerBrowser.hash(ServerBrowser.defaultText)]
        #expect(work(try server(files: left, missing: [], chrome: "157.0.8103.78-1"), closed) == .nothing)
        // An agent with both boxes that the reading does not name (a service that started again under another name
        // and reads no agent yet, or a reading from before the agent came): the round does nothing, and takes no
        // parts and no ports away.
        let unnamed: [String: Any] = ["beta": ["user": "fleet-beta", "uid": 1003]]
        #expect(ServerBrowser.wanted(on: try server(users: unnamed), agents: [try agent("alpha")]) == nil)
        #expect(work(try server(ports: [["user": "fleet-alpha", "devtools": 9300, "screen": 5910]], added: true,
                                users: [:]), [try agent("alpha")]) == nil)
    }

    /// A round says nothing about a server that is not of this sweep or not now: an open job of its service, a task
    /// that makes the step wait (`works` not false; a hub that does not send it: its state alone), the hub's own
    /// server, a reading of an agent's helper or an old one, the hour after its join, and a reading without the parts
    /// (a server before owner API 1.224). The step does not wait for a task in state working whose `works` is false.
    @Test func whatARoundDoesNotRead() throws {
        let agents = [try agent("alpha")]
        #expect(work(try server(job: "running"), agents) == nil)
        #expect(work(try server(), agents, tasks: [try task(owner: "beta")]) == nil)
        #expect(work(try server(), agents, tasks: [try task(owner: "beta", state: "completed")]) != nil)
        #expect(work(try server(), agents, tasks: [try task(owner: "beta", works: true)]) == nil)
        #expect(work(try server(), agents, tasks: [try task(owner: "beta", works: false)]) != nil)
        #expect(work(try server(hub: true), agents) == nil)
        #expect(work(try server(source: "agent"), agents) == nil)
        #expect(work(try server(reportedAt: Self.time - 3600), agents) == nil)
        #expect(work(try server(browser: false), agents) == nil)
        let joined = try JSONDecoder().decode(JoinState.self, from: JSONSerialization.data(withJSONObject: [
            "name": "", "kind": "linux", "created": Self.time - 600, "expires_at": Self.time + 3000, "state": "joined",
            "server": "app-1"] as [String: Any]))
        #expect(work(try server(), agents, join: joined) == nil)
    }

    // MARK: how often

    private func turn(_ work: ServerBrowser.Work?, _ memory: inout ServerBrowser.Memory, _ unreached: inout VaultTries?,
                      seen: Bool, at now: Double, says output: String?) async -> ServerBrowser.Turn {
        await ServerBrowser.turn(work, memory: &memory, unreached: &unreached, seenBefore: seen, now: now,
                                 connection: { InstallTarget(host: "100.80.1.7") },
                                 run: { _, _ in
                                     guard let output else { throw CancellationError() }
                                     return output
                                 })
    }

    /// The same want in two rounds in a row runs the program; each start is a try, ten minutes apart and six at most
    /// for one want; a step that still runs is none; a new want starts the count again, and a reading that matches
    /// the want ends it. A try that ran nothing on the server counts for this launch only.
    @Test func theSameWantInTwoRoundsRunsAndEachStartIsATry() async throws {
        guard case .install(let want)? = work(try server(), [try agent("alpha")]) else { return }
        let install = ServerBrowser.Work.install(want), begun = "\n\(ServerBrowser.started)\n"
        var memory = ServerBrowser.Memory(), unreached: VaultTries?
        #expect(await turn(install, &memory, &unreached, seen: false, at: Self.time, says: nil)
                == ServerBrowser.Turn(seen: true))
        #expect(memory == ServerBrowser.Memory(digest: want.digest))
        let started = await turn(install, &memory, &unreached, seen: true, at: Self.time,
                                 says: begun + "founderizer-browser started \(want.digest) apt-busy\n")
        #expect(memory.failures == 1 && memory.reason == "the step before said: \(want.digest) apt-busy")
        #expect(started.lines == ["a step to put in place the parts started; the step before it said: "
                                  + "\(want.digest) apt-busy"])
        // Five minutes on: no try is due. Ten minutes on, a step that still runs is no try.
        #expect(await turn(install, &memory, &unreached, seen: true, at: Self.time + 300, says: nil).lines.isEmpty)
        _ = await turn(install, &memory, &unreached, seen: true, at: Self.time + 600,
                       says: begun + "founderizer-browser running \(want.digest) running\n")
        #expect(memory.failures == 1)
        // Six starts, and then the want is left until it changes.
        var sixth = ServerBrowser.Turn()
        for round in 1...5 {
            sixth = await turn(install, &memory, &unreached, seen: true, at: Self.time + 600 * Double(round + 1),
                               says: begun + "founderizer-browser started \(want.digest) ok\n")
        }
        #expect(memory.failures == 6 && memory.tries?.givenUp == true)
        #expect(sixth.lines.last == "left after 6 tries (the step before said: \(want.digest) ok) until the want changes")
        #expect(await turn(install, &memory, &unreached, seen: true, at: Self.time + 99_999,
                           says: begun + "founderizer-browser started\n") == ServerBrowser.Turn(seen: true))
        #expect(memory.failures == 6)
        // A new want starts the count again; a reading that matches the want ends it.
        _ = await turn(.remove, &memory, &unreached, seen: false, at: Self.time + 99_999, says: nil)
        #expect(memory == ServerBrowser.Memory(digest: "remove"))
        _ = await turn(.nothing, &memory, &unreached, seen: true, at: Self.time + 99_999, says: nil)
        #expect(memory == ServerBrowser.Memory())
        // A try whose ssh started nothing is this launch's, never the kept count's.
        _ = await turn(install, &memory, &unreached, seen: true, at: Self.time, says: "sudo: a password is required\n")
        #expect(memory.failures == 0 && unreached?.failures == 1)
        _ = await turn(install, &memory, &unreached, seen: true, at: Self.time + 600, says: nil)
        #expect(memory.failures == 0 && unreached?.failures == 2)
    }

    @Test func theLastLineSaysWhatTheProgramDid() {
        let begun = "\n\(ServerBrowser.started)\n"
        #expect(ServerBrowser.outcome(begun + "founderizer-browser started\n") == .started(""))
        #expect(ServerBrowser.outcome(begun + "founderizer-browser started 0a1b remove ok\n") == .started("0a1b remove ok"))
        #expect(ServerBrowser.outcome(begun + "founderizer-browser running 0a1b running\n") == .running("0a1b running"))
        #expect(ServerBrowser.outcome(begun + "Failed to start transient service unit\nfounderizer-browser failed\n")
                == .failed("no step started: Failed to start transient service unit"))
        #expect(ServerBrowser.outcome(begun + "Connection closed.\n")
                == .failed("the program started and did not end: Connection closed."))
        guard case .notStarted = ServerBrowser.outcome("sudo: a password is required\n") else {
            Issue.record("an ssh that started nothing reads as a run"); return
        }
        guard case .notStarted = ServerBrowser.outcome("refused:\n" + ServerBrowser.program(.remove)) else {
            Issue.record("the program's own text reads as its first line"); return
        }
    }

    // MARK: the program on a server

    /// A server's root under a new folder, with stand-ins: `dpkg-query` and `apt-get` keep the installed packages in
    /// `status` (Chrome brings `libnss3`, which nothing needs once Chrome is gone), `id` reads `users` (and says root
    /// where the mark `as-root` is), `systemd-run` runs the step at once in the shell of the test, and each command goes
    /// into `ran`. A mark makes a stand-in behave as a server can: `apt-busy`, `install-breaks` (dpkg fails after it
    /// unpacked the packages), `drop-alpha` (fleet-alpha is deleted while the packages come), `lock-busy`, `xvfb-needed`
    /// (a package of the server's own needs xvfb), `ffmpeg-needs-xvfb`, `sim-silent` (apt's simulation says nothing)
    /// and `dpkg-fails` (dpkg cannot list its packages, once); `held` lists the packages on hold, `half` the ones that
    /// dpkg left half configured.
    private struct Root {
        let folder: URL
        let shell: String
        var root: URL { folder.appendingPathComponent("root") }
        var bin: URL { folder.appendingPathComponent("bin") }
        func at(_ path: String) -> URL { root.appendingPathComponent(String(path.dropFirst())) }

        init(shell: String, installed: [String] = ["nftables", "xauth"]) throws {
            self.shell = shell
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("browser-" + UUID().uuidString)
            for made in ["root/etc/default", "root/etc/apt/sources.list.d", "root/etc/apt/apt.conf.d",
                         "root/usr/share/keyrings", "root/etc/systemd/system", "root/var/lib", "bin"] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(made),
                                                        withIntermediateDirectories: true)
            }
            let here = folder.path
            try put("status", installed.sorted().map { $0 + "\n" }.joined())
            try put("users", "fleet 1000\nfleet-vault 1001\nfleet-alpha 1002\nfleet-beta 1003\n")
            try stand("systemd-run", """
                echo "systemd-run $*" >> '\(here)/ran'
                [ -e '\(here)/systemd-run-fails' ] && { echo 'Failed to start transient service unit' >&2; exit 1; }
                while [ $# -gt 1 ]; do shift; done
                exec \(shell) "$1"
                """)
            try stand("systemctl", """
                echo "systemctl $*" >> '\(here)/ran'
                case "$*" in 'disable --now'*) [ ! -e '\(here)/root\(ServerBrowser.dropinPath)' ] \
                || echo 'the drop-in was there at the disable' >> '\(here)/ran';; esac
                [ "$*" = daemon-reload ] && [ -e '\(here)/reload-fails' ] && exit 1
                [ "$*" = 'is-active --quiet fleet-browser-step.service' ] && { [ -e '\(here)/step-runs' ]; exit; }
                if [ "$1 $2" = 'is-active --quiet' ]; then case "$3" in user@*.service)
                  u=${3#user@}; u=${u%.service}       # each user's own systemd runs, but fleet-vault's (1001)
                  [ "$u" != 1001 ] && awk -v u="$u" '$2 == u {f = 1} END {exit !f}' '\(here)/users'; exit;;
                esac; fi
                case "$*" in *'--machine=fleet-beta@.host stop '*) rm -f '\(here)/beta-listens';; esac
                exit 0
                """)
            try stand("nft", "echo \"nft $*\" >> '\(here)/ran'")
            try stand("ss", """
                echo "ss $*" >> '\(here)/ran'
                [ ! -e '\(here)/ss-fails' ] || exit 1
                echo 'LISTEN 0 10 127.0.0.1:8080 0.0.0.0:*'
                [ ! -e '\(here)/listens' ] || printf 'LISTEN 0 10 127.0.0.1:9311 0.0.0.0:*\\nLISTEN 0 5 [::1]:5911 [::]:*\\n'
                [ ! -e '\(here)/beta-listens' ] || echo 'LISTEN 0 10 127.0.0.1:9312 0.0.0.0:*'
                """)
            try stand("getent", """
                [ "$1" = passwd ] && awk '{print $1 ":x:" $2 ":" $2 "::/home/" $1 ":/bin/sh"}' '\(here)/users'
                """)
            try stand("chown", "echo \"chown $*\" >> '\(here)/ran'")
            try stand("flock", "echo \"flock $*\" >> '\(here)/ran'; [ ! -e '\(here)/lock-busy' ]")
            try stand("id", """
                [ "$#" = 1 ] && [ "$1" = -u ] && { if [ -e '\(here)/as-root' ]; then echo 0; else echo 501; fi; exit 0; }
                [ "$#" = 2 ] && [ "$1" = -u ] && awk -v u="$2" '$1 == u {print $2; f = 1} END {exit !f}' '\(here)/users'
                [ "$#" = 2 ] && [ "$1" = -gn ] && echo "$2"
                """)
            try stand("dpkg-query", """
                shift 2
                [ $# -gt 0 ] || [ ! -e '\(here)/dpkg-fails' ] || { rm -f '\(here)/dpkg-fails'; echo 'dpkg-query: error: parsing file' >&2; exit 2; }
                [ $# -gt 0 ] || set -- $(cat '\(here)/status')
                for p; do grep -qxF "$p" '\(here)/status' || continue
                  w='ii '; ! grep -qxF "$p" '\(here)/held' 2>/dev/null || w='hi '
                  ! grep -qxF "$p" '\(here)/half' 2>/dev/null || w='iF '
                  printf '%s\\tamd64\\t%s\\n' "$p" "$w"; done
                exit 0
                """)
            try stand("apt-get", """
                echo "apt-get $*" >> '\(here)/ran'
                [ -e '\(here)/apt-busy' ] && { echo 'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 4242 (unattended-upgr)'; exit 100; }
                s=; [ "$1" = -s ] && { s=1; shift; }
                [ -z "$s" ] || [ ! -e '\(here)/sim-silent' ] || exit 0
                while [ "${1#-}" != "$1" ]; do [ "$1" = -o ] && shift; shift; done
                c=$1; shift
                case "$c" in
                  install) o=; for p; do [ -z "$o" ] || { o=; continue; }; case "$p" in -o) o=1;; -*) ;;
                    *) echo "$p" >> '\(here)/status'
                    [ "$p" != google-chrome-stable ] || echo libnss3 >> '\(here)/status';; esac; done
                    sort -u '\(here)/status' -o '\(here)/status'
                    [ ! -e '\(here)/drop-alpha' ] || grep -v '^fleet-alpha ' '\(here)/users' > '\(here)/users.new'
                    [ ! -e '\(here)/drop-alpha' ] || mv '\(here)/users.new' '\(here)/users'
                    [ ! -e '\(here)/install-breaks' ] || { echo 'E: Sub-process /usr/bin/dpkg returned an error code (1)'; exit 100; };;
                  purge|remove) for p; do case "$p" in -*) ;; *)
                    if [ -n "$s" ]; then echo "$( [ "$c" = purge ] && echo Purg || echo Remv ) $p [1.0]"
                      [ "$p" != xvfb ] || [ ! -e '\(here)/xvfb-needed' ] || echo 'Remv owner-tool [2.0]'
                      [ "$p" != xvfb ] || [ ! -e '\(here)/ffmpeg-needs-xvfb' ] || echo 'Remv ffmpeg [6.1]'
                    else grep -vxF "$p" '\(here)/status' > '\(here)/status.new'; mv '\(here)/status.new' '\(here)/status'
                    fi;; esac; done;;
                  autoremove) [ -n "$s" ] && grep -qxF libnss3 '\(here)/status' \
                    && ! grep -qxF google-chrome-stable '\(here)/status' && echo 'Remv libnss3:amd64 [3.98]';;
                esac
                exit 0
                """)
        }

        func put(_ name: String, _ text: String) throws {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func mark(_ name: String) throws { try Data().write(to: folder.appendingPathComponent(name)) }
        func unmark(_ name: String) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        private func stand(_ name: String, _ text: String) throws {
            let path = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + text + "\n").write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        /// The program in the test's shell, after `umask 077` (a root login that keeps all to itself), with the
        /// stand-ins first in its PATH and in the step's: all that it said.
        func run(_ work: ServerBrowser.Work) throws -> String {
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: shell)
            child.arguments = ["-c", "umask 077\n" + ServerBrowser.program(work, root: root.path,
                                                                           path: bin.path + ":/usr/bin:/bin")]
            child.standardOutput = output
            child.standardError = output
            child.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = bin.path + ":/usr/bin:/bin"
            child.environment = environment
            try child.run()
            let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            child.waitUntilExit()
            return said
        }

        func text(_ path: String) -> String? { try? String(contentsOf: at(path), encoding: .utf8) }
        func data(_ path: String) -> Data? { try? Data(contentsOf: at(path)) }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: at(path).path) }
        func mode(_ path: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: at(path).path)[.posixPermissions] as? NSNumber)?.intValue
        }
        func changed(_ path: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: at(path).path))?[.modificationDate] as? Date
        }
        var result: String? { text("/var/lib/fleet-browser/result") }
        var record: String? { text("/var/lib/fleet-browser/added") }
        var status: [String] {
            ((try? String(contentsOf: folder.appendingPathComponent("status"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        var ran: [String] {
            ((try? String(contentsOf: folder.appendingPathComponent("ran"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    private func want(_ rows: [Ports] = [Ports(user: "fleet-alpha", devtools: 9300, screen: 5910)],
                      broker: Int? = 1001) -> ServerBrowser.Want {
        let uids = ["fleet-alpha": 1002, "fleet-beta": 1003].filter { user, _ in rows.contains { $0.user == user } }
        return ServerBrowser.Want(rows: rows, table: ServerBrowser.table(rows, uids: uids, broker: broker, worker: 1000)!,
                                  uids: uids, broker: broker, worker: "fleet", workerID: 1000)
    }

    private static let partPaths = [ServerBrowser.unitPath, ServerBrowser.dropinPath, ServerBrowser.defaultPath,
                                    ServerBrowser.originPath,
                                    ServerBrowser.fixedPath, ServerBrowser.policyPath, ServerBrowser.sourcePath,
                                    ServerBrowser.keyPath, ServerBrowser.portsPath, ServerBrowser.tablePath,
                                    "/var/lib/fleet-browser/added"]

    /// An install on a server with none of the parts, by a login whose umask keeps all to itself: each file whole with
    /// the contract's bytes (a policy staged beside `managed/`, never in it), the packages that were missing, a record
    /// of each package that came, but `libatomic1`, and of each of Chrome's own files that the step made, the live
    /// proof's folder of the worker user that it can enter, the table's unit enabled and loaded, and `ok`. A second
    /// run finds it all in place and changes no file.
    @Test(arguments: ["/bin/sh", "/bin/dash"]) func anInstallPutsEachPartInPlaceInTheContractsOrder(shell: String) throws {
        let server = try Root(shell: shell)
        defer { server.remove() }
        try server.mark("as-root")
        let want = want()
        let said = try server.run(.install(want))
        #expect(said.hasSuffix("founderizer-browser started \n"), "\(said)")
        #expect(server.result == "\(want.digest) ok\n")
        for (path, text) in [(ServerBrowser.unitPath, ServerBrowser.unitText), (ServerBrowser.dropinPath, ServerBrowser.dropinText),
                             (ServerBrowser.defaultPath, ServerBrowser.defaultText),
                             (ServerBrowser.originPath, ServerBrowser.originText), (ServerBrowser.fixedPath, ServerBrowser.fixedText),
                             (ServerBrowser.policyPath, ServerBrowser.policyText), (ServerBrowser.sourcePath, ServerBrowser.sourceText),
                             (ServerBrowser.portsPath, "fleet-alpha 9300 5910\n"), (ServerBrowser.tablePath, want.table)] {
            #expect(server.text(path) == text, "\(path)")
            #expect(server.mode(path) == 0o644, "\(path)")
        }
        #expect(server.data(ServerBrowser.keyPath) == ServerBrowser.keyData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.at("/etc/opt/chrome/policies/managed").path).sorted()
                == ["fleet-fixed.json", "fleet-providers.json"])
        #expect(server.mode("/var/lib/fleet-browser") == 0o755 && server.mode("/var/lib/fleet-browser/proof") == 0o755)
        #expect(server.ran.contains("chown fleet: \(server.root.path)/var/lib/fleet-browser/proof"))
        // The lock: of root and the worker user's group, which no agent can open, and so no agent can hold.
        #expect(server.mode(ServerBrowser.lockPath) == 0o640)
        #expect(server.ran.contains("chown root:fleet \(server.root.path)\(ServerBrowser.lockPath)"))
        let packages = ServerBrowser.packages.filter { !["nftables", "xauth"].contains($0) }
        #expect(server.record == (
            ["file \(ServerBrowser.defaultPath)", "file \(ServerBrowser.sourcePath)", "file \(ServerBrowser.keyPath)"]
            + (packages + ["libnss3"]).filter { $0 != "libatomic1" }.map { "package " + $0 }
            + packages.filter { $0 != "libatomic1" }.map { "requested " + $0 }).sorted().joined(separator: "\n") + "\n")
        #expect(server.status.contains("libatomic1") && !server.exists("/var/lib/fleet-browser/step/before"))
        #expect(server.ran.contains("systemctl enable fleet-browser-ports.service"))
        #expect(server.ran.contains("systemctl reload-or-restart fleet-browser-ports.service"))
        #expect(server.ran.contains { $0.contains(" install -y --no-install-recommends --no-remove ")
                                      && $0.contains("Dpkg::Options::=--force-confold") })
        // Again: the step before said ok, nothing to install, and no file is written again.
        let before = Self.partPaths.map(server.changed)
        #expect(try server.run(.install(want)).hasSuffix("founderizer-browser started \(want.digest) ok\n"))
        #expect(Self.partPaths.map(server.changed) == before)
        #expect(server.ran.filter { $0.hasPrefix("apt-get") && $0.contains(" install ") }.count == 1)
    }

    /// What stops the step, and what it keeps for the next one: a package system that another program holds (the
    /// policies are in place and the ports not yet); an install that breaks after dpkg unpacked the packages (each one
    /// is recorded all the same); an agent deleted while the packages came (the users are read again under the lock,
    /// so its ports are not written back); a lock that the root helper holds; users that changed before the step; and
    /// a step that still runs, beside which no second one starts.
    @Test(arguments: ["/bin/sh", "/bin/dash"]) func whatStopsTheStepAndWhatItKeeps(shell: String) throws {
        let want = want()
        let server = try Root(shell: shell)
        defer { server.remove() }
        try server.mark("apt-busy")
        _ = try server.run(.install(want))
        #expect(server.result == "\(want.digest) apt-busy\n")
        #expect(server.text(ServerBrowser.policyPath) == ServerBrowser.policyText && !server.exists(ServerBrowser.portsPath))
        #expect(server.record?.contains("package") != true)
        server.unmark("apt-busy")
        try server.mark("install-breaks")
        #expect(try server.run(.install(want)).hasSuffix("founderizer-browser started \(want.digest) apt-busy\n"))
        #expect(server.result == "\(want.digest) install-failed\n")
        #expect(server.record?.contains("requested google-chrome-stable\n") == true)
        #expect(server.record?.contains("package libnss3\n") == true && !server.exists(ServerBrowser.portsPath))
        server.unmark("install-breaks")
        try server.mark("reload-fails")         // systemd did not read the drop-in: the step says so, never ok
        _ = try server.run(.install(want))
        #expect(server.result == "\(want.digest) table-failed\n")
        server.unmark("reload-fails")
        // A package that the server's own people install after that step is never recorded as the step's.
        try server.put("status", (server.status + ["owner-tool"]).sorted().map { $0 + "\n" }.joined())
        try server.mark("drop-alpha")
        _ = try server.run(.install(want))
        #expect(server.result == "\(want.digest) ok\n", "nothing was missing any more: the users stayed")
        #expect(server.record?.contains("owner-tool") == false)
        let deleted = try Root(shell: shell)
        defer { deleted.remove() }
        try deleted.mark("drop-alpha")
        _ = try deleted.run(.install(want))
        #expect(deleted.result == "\(want.digest) users-changed\n" && !deleted.exists(ServerBrowser.portsPath))
        #expect(deleted.record?.contains("requested xvfb\n") == true)
        let locked = try Root(shell: shell, installed: ServerBrowser.packages)
        defer { locked.remove() }
        try locked.mark("lock-busy")
        _ = try locked.run(.install(want))
        #expect(locked.result == "\(want.digest) lock-busy\n" && !locked.exists(ServerBrowser.portsPath))
        // A lock that cannot be made or opened at all (dash ends at a failed `exec`): the step still says why it
        // stopped, and the next run does not read it as a step that ended with no word.
        locked.unmark("lock-busy")
        try FileManager.default.removeItem(at: locked.at(ServerBrowser.lockPath))
        try FileManager.default.createDirectory(at: locked.at(ServerBrowser.lockPath), withIntermediateDirectories: true)
        _ = try locked.run(.install(want))
        #expect(locked.result == "\(want.digest) write-failed\n")
        // dpkg that cannot list its packages: no list, so no package of the server's is recorded as the step's.
        let unlisted = try Root(shell: shell)
        defer { unlisted.remove() }
        try unlisted.mark("dpkg-fails")
        _ = try unlisted.run(.install(want))
        #expect(unlisted.result == "\(want.digest) write-failed\n" && unlisted.record?.contains("package") != true)
        let changed = try Root(shell: shell)
        defer { changed.remove() }
        try changed.put("users", "fleet 1000\nfleet-vault 1001\nfleet-alpha 1009\n")
        _ = try changed.run(.install(want))
        #expect(changed.result == "\(want.digest) users-changed\n")
        #expect(!changed.exists(ServerBrowser.policyPath) && !changed.exists(ServerBrowser.keyPath))
        try changed.mark("step-runs")
        #expect(try changed.run(.install(want)).hasSuffix("founderizer-browser running \(want.digest) users-changed\n"))
    }

    /// The untick of the last box, in the contract's order: the table's unit and the table go before any package (so
    /// that `nft` is still there to take the table away); Chrome goes with `purge` and the other packages that the
    /// step asked for with `remove`, each only where apt's simulation names it and no package of the server's own,
    /// and what came with them once nothing needs it; then the policies, Chrome's files that the step made, the record
    /// and the live proof's folder. A package that the server had before stays, and so does one that a package of
    /// its own needs now.
    /// A server with no nftables gets it from the step, and keeps it at the removal: other parts of the fleet use it
    /// too, and the removal of the package would stop `nftables.service`, whose stop flushes every table.
    @Test(arguments: ["/bin/sh", "/bin/dash"]) func nftablesStaysAfterTheRemoval(shell: String) throws {
        let server = try Root(shell: shell, installed: ["xauth"])
        defer { server.remove() }
        _ = try server.run(.install(want()))
        #expect(server.status.contains("nftables"))
        #expect(!(server.record ?? "").contains("nftables"), "\(server.record ?? "")")
        _ = try server.run(.remove)
        #expect(server.result == "remove ok\n" && server.status.contains("nftables"), "\(server.status)")
        // a record from before nftables was kept names it: the removal leaves it all the same
        let old = try Root(shell: shell, installed: ["xauth"])
        defer { old.remove() }
        _ = try old.run(.install(want()))
        try ((old.record ?? "") + "package nftables\nrequested nftables\n")
            .write(to: old.at("/var/lib/fleet-browser/added"), atomically: true, encoding: .utf8)
        _ = try old.run(.remove)
        #expect(old.result == "remove ok\n" && old.status.contains("nftables"), "\(old.status) \(old.ran)")
    }

    /// Another part of the fleet keeps its own drop-in for `nftables.service` beside the table's (the outgoing gate):
    /// a removal takes away the table's file alone, and the folder stays with the other file.
    @Test(arguments: ["/bin/sh", "/bin/dash"]) func aRemovalLeavesAnotherPartsDropIn(shell: String) throws {
        let server = try Root(shell: shell)
        defer { server.remove() }
        _ = try server.run(.install(want()))
        let other = "/etc/systemd/system/nftables.service.d/founderizer-egress.conf"
        try "[Service]\nExecStartPost=-/usr/sbin/nft -f /etc/founderizer-egress/table.nft\n"
            .write(to: server.at(other), atomically: true, encoding: .utf8)
        _ = try server.run(.remove)
        #expect(server.result == "remove ok\n")
        #expect(!server.exists(ServerBrowser.dropinPath) && server.exists(other))
    }

    @Test(arguments: ["/bin/sh", "/bin/dash"]) func aRemovalTakesAwayOnlyWhatTheStepAdded(shell: String) throws {
        let server = try Root(shell: shell)
        defer { server.remove() }
        _ = try server.run(.install(want()))
        try server.mark("xvfb-needed")
        _ = try server.run(.remove)
        #expect(server.result == "remove ok\n")
        #expect(server.status == ["libatomic1", "nftables", "xauth", "xvfb"], "\(server.status) \(server.ran)")
        let ran = server.ran, firstPackage = ran.firstIndex { $0.contains(" purge -y") || $0.contains(" remove -y") }
        #expect(ran.contains("apt-get -q -o Dpkg::Use-Pty=0 purge -y google-chrome-stable"))
        #expect(ran.filter { $0.contains(" purge ") && !$0.hasPrefix("apt-get -s") }.count == 1)
        #expect(ran.firstIndex(of: "systemctl disable --now fleet-browser-ports.service").map { $0 < firstPackage! } == true)
        #expect(ran.firstIndex(of: "nft delete table inet fleet_browser").map { $0 < firstPackage! } == true)
        for path in Self.partPaths + ["/var/lib/fleet-browser/proof", "/etc/fleet-browser",
                                      "/etc/systemd/system/nftables.service.d"] {
            #expect(!server.exists(path), "\(path)")
        }
        // the drop-in went before the unit's stop: an event of nftables.service in between loads no table again
        #expect(!ran.contains("the drop-in was there at the disable"))
        // the units of every agent user stopped before the table went, also of fleet-beta, which no line of the ports
        // file named (the S3b review, rounds 4 and 5); and a Chrome that such a stop ends holds nothing: the stops come
        // before the look at the listeners (round 6). A user whose own systemd does not run, fleet-vault here, gets no
        // stop, which would start one for it (round 7).
        #expect(ran.contains("systemctl is-active --quiet user@1001.service")
                && !ran.contains("systemctl --user --machine=fleet-vault@.host stop fleet_browser.service fleet_vnc.service"))
        for user in ["fleet-alpha", "fleet-beta"] {
            #expect(ran.firstIndex(of: "systemctl --user --machine=\(user)@.host stop fleet_browser.service fleet_vnc.service")
                    .map { $0 < ran.firstIndex(of: "nft delete table inet fleet_browser")! } == true, "\(ran)")
        }
        // while anything still listens on a port of either range, here ports that no line of the ports file names, the
        // removal ends with those ports before it takes the table away: a Chrome that an open task keeps never listens
        // with no rule. The ports file goes empty first, so that no browser starts meanwhile.
        let stopped = try Root(shell: shell)
        defer { stopped.remove() }
        _ = try stopped.run(.install(want()))
        try stopped.mark("beta-listens")
        _ = try stopped.run(.remove)
        #expect(stopped.result == "remove ok\n" && !stopped.exists(ServerBrowser.tablePath), "\(stopped.ran)")
        let running = try Root(shell: shell)
        defer { running.remove() }
        _ = try running.run(.install(want()))
        try running.mark("listens")
        _ = try running.run(.remove)
        // The ports file is empty and the table has no line, its last rule alone and loaded: no browser starts, every
        // port of both ranges is closed, and devops's checker takes that pair (the S3b review, round 6).
        #expect(running.result == "remove units-running 5911 9311\n"
                && running.text(ServerBrowser.portsPath) == "" && running.text(ServerBrowser.tablePath) == ServerBrowser.emptyTable
                && !running.ran.contains("nft delete table inet fleet_browser"), "\(running.ran)")
        #expect(running.ran.filter { $0 == "systemctl reload-or-restart fleet-browser-ports.service" }.count == 2)
        #expect(ServerBrowser.emptyTable.hasSuffix(
            "\t\toifname \"lo\" tcp flags & (syn | ack) == syn tcp dport { 5910-5999, 9300-9399 } reject with tcp reset\n\t}\n}\n")
            && !ServerBrowser.emptyTable.contains("meta skuid"))
        // An `ss` that does not answer reads as a port that may be held: the table stays.
        try running.mark("ss-fails")
        _ = try running.run(.remove)
        #expect(running.result == "remove ss-failed\n" && running.text(ServerBrowser.tablePath) == ServerBrowser.emptyTable)
        running.unmark("ss-fails")
        running.unmark("listens")
        _ = try running.run(.remove)
        #expect(running.result == "remove ok\n" && !running.exists(ServerBrowser.tablePath))
        // A step that was ended after it listed the packages and before it recorded what came: the next step, here a
        // removal, records against that list first, and takes those packages away too.
        let ended = try Root(shell: shell)
        defer { ended.remove() }
        try FileManager.default.createDirectory(at: ended.at("/var/lib/fleet-browser/step"),
                                                withIntermediateDirectories: true)
        try "nftables\nxauth\n".write(to: ended.at("/var/lib/fleet-browser/step/before"), atomically: true, encoding: .utf8)
        try ended.put("status", "libnss3\nnftables\nxauth\nxvfb\n")
        _ = try ended.run(.remove)
        #expect(ended.result == "remove ok\n" && ended.status == ["nftables", "xauth"], "\(ended.status)")
        // A package that the step added and that the server's people put on hold stays, and so does one whose removal
        // would take it along; one that dpkg left half configured goes; and the removal ends.
        let held = try Root(shell: shell)
        defer { held.remove() }
        _ = try held.run(.install(want()))
        try held.put("held", "ffmpeg\n")
        try held.put("half", "openbox\n")
        try held.mark("ffmpeg-needs-xvfb")
        _ = try held.run(.remove)
        #expect(held.result == "remove ok\n" && held.status.contains("ffmpeg") && held.status.contains("xvfb"))
        #expect(!held.status.contains("openbox") && !held.status.contains("x11vnc"))
        // A Chrome that the server had before stays with its source and key, and without the fleet's policies; and
        // a simulation that says nothing removes nothing.
        let had = try Root(shell: shell, installed: ["google-chrome-stable", "nftables", "xauth"])
        defer { had.remove() }
        _ = try had.run(.install(want()))
        try had.mark("sim-silent")
        _ = try had.run(.remove)
        #expect(had.result == "remove ok\n" && had.status.contains("google-chrome-stable") && had.status.contains("xvfb"))
        #expect(!had.exists(ServerBrowser.fixedPath) && !had.exists(ServerBrowser.policyPath))
        #expect(had.exists(ServerBrowser.sourcePath) && had.exists(ServerBrowser.keyPath))
    }
}
