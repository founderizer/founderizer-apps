import Foundation
import Testing
@testable import FleetCore

/// The join's hardening, put right again by the owner's Mac (`ServerHardening`): when a round runs the program, how
/// often, and what the program does on a server. The program runs here in this Mac's `/bin/sh` and in dash, the
/// `/bin/sh` of Debian and Ubuntu, under a folder that stands for the server's root, with stand-ins for `systemctl` and
/// for `sshd`. The stand-in for `sshd` refuses every check while `/run/sshd` is missing, as sshd does: the cause of
/// 14 November 2026.
struct ServerHardeningTests {
    /// The hub's clock in the list, and this Mac's clock for the tries.
    static let time: Double = 1_000_000

    /// One server as `/ui/servers` lists it: by default a Linux server that joined, with no agent, and a current reading
    /// of its own service that says `ssh` and `npm`.
    private func server(_ name: String = "app-1", kind: String = "linux", joined: Bool = true, hub: Bool = false,
                        source: String = "server", reportedAt: Double = time - 60, stale: Bool = false,
                        ssh: Bool? = false, npm: Bool? = true, job: String? = nil) throws -> ServerEntry {
        var security: [String: Any] = ["firewall": "active", "tailscale": true, "unattended_upgrades": true]
        if let ssh { security["ssh_keys_only"] = ssh }
        if let npm { security["npm_rule"] = npm }
        var entry: [String: Any] = [
            "name": name, "kind": kind, "hub": hub, "joined": joined, "agents": [], "address": "100.80.1.7",
            "available": true, "why": [],
            "reading": ["source": source, "os": ["name": "Ubuntu 24.04"], "runtimes": [:], "reported_at": reportedAt,
                        "stale": stale, "security": security] as [String: Any]]
        if let job {
            entry["job"] = ["id": 4, "kind": "install", "agent": "dev-lead", "state": job, "created": Self.time - 100,
                            "updated": Self.time - 50] as [String: Any]
        }
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    /// The hub's own row as `/ui/servers` gives it from owner API 1.170: no kind, no service and no reading of one, and
    /// the hub's own reading of its server in `hardening`, by default read a minute ago and two hours after the hub's
    /// claim. `own: false` is a row with no such key (a hub on a Mac, or a hub from before 1.170); `service` gives the
    /// hub's server a service of its own, with a reading that says `ssh` and `npm` (`FLEET_HUB_SERVER=shared`).
    private func hubRow(ssh: Bool? = false, npm: Bool? = true, at: Double? = time - 60, claimed: Double? = time - 7200,
                        own: Bool = true, kind: String? = nil, service: (ssh: Bool?, npm: Bool?)? = nil,
                        job: String? = nil) throws -> ServerEntry {
        var entry: [String: Any] = [
            "name": "hub", "hub": true, "joined": service != nil, "agents": ["manager"], "address": "100.80.1.2",
            "available": false, "why": service == nil ? ["hub_machine", "no_service"] : ["hub_machine"]]
        if let kind { entry["kind"] = kind }
        if own {
            var hardening: [String: Any] = [:]
            if let ssh { hardening["ssh_keys_only"] = ssh }
            if let npm { hardening["npm_rule"] = npm }
            if let at { hardening["at"] = at }
            if let claimed { hardening["claimed_at"] = claimed }
            entry["hardening"] = hardening
        }
        if let service {
            var security: [String: Any] = ["firewall": "active", "tailscale": true, "unattended_upgrades": true]
            if let ssh = service.ssh { security["ssh_keys_only"] = ssh }
            if let npm = service.npm { security["npm_rule"] = npm }
            entry["reading"] = ["source": "server", "os": ["name": "Ubuntu 24.04"], "runtimes": [:],
                                "reported_at": Self.time - 60, "stale": false, "security": security] as [String: Any]
        }
        if let job {
            entry["job"] = ["id": 9, "kind": "install", "agent": "dev-lead", "state": job, "created": Self.time - 100,
                            "updated": Self.time - 50] as [String: Any]
        }
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    private func join(_ server: String?, created: Double) throws -> JoinState {
        var entry: [String: Any] = ["name": "", "kind": "linux", "created": created, "expires_at": created + 3600,
                                    "state": server == nil ? "open" : "joined"]
        if let server { entry["server"] = server }
        return try JSONDecoder().decode(JoinState.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    private func read(_ server: ServerEntry, join: JoinState? = nil) -> ServerHardening.Reading {
        ServerHardening.reading(of: server, join: join, at: Self.time)
    }

    // MARK: when a round runs the program

    @Test func theProgramRunsOnlyOnTheFaultInTwoRoundsInARow() throws {
        let memory = ServerHardening.Memory()
        for faulty in [try server(ssh: false), try server(ssh: true, npm: false), try server(ssh: nil, npm: false)] {
            #expect(read(faulty) == .faulty)
            #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: false, now: Self.time) == .seen)
            #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: true, now: Self.time) == .run)
        }
        // A reading that says nothing never runs it, also in a second round.
        #expect(read(try server(ssh: nil, npm: nil)) == .unread)
        #expect(read(try server(ssh: nil, npm: true)) == .unread)
        #expect(ServerHardening.step(.unread, memory: memory, seenBefore: true, now: Self.time) == .nothing)
    }

    @Test func aServerThatReadsTrueIsSettledAndThenLeftAlone() throws {
        #expect(read(try server(ssh: true, npm: true)) == .holds)
        #expect(read(try server(ssh: true, npm: nil)) == .holds)
        var memory = ServerHardening.Memory()
        #expect(ServerHardening.step(.holds, memory: memory, seenBefore: false, now: Self.time) == .settle)
        memory.settled = true
        // Somebody lets passwords in later: that is a choice, and this Mac does not act on it.
        for seenBefore in [false, true] {
            #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: seenBefore, now: Self.time) == .nothing)
            #expect(ServerHardening.step(.holds, memory: memory, seenBefore: seenBefore, now: Self.time) == .nothing)
        }
    }

    @Test func whatTheSweepDoesNotReadAtAll() throws {
        #expect(!ServerHardening.applies(to: try server(kind: "mac")))      // a Mac that joined as a server
        #expect(!ServerHardening.applies(to: try server(hub: true)))       // the hub's own machine, with no reading of
                                                                            // the hub's own of it (hubRow below)
        #expect(!ServerHardening.applies(to: try server(joined: false)))
        #expect(ServerHardening.applies(to: try server()))
        for unread in [try server(kind: "mac"), try server(hub: true), try server(joined: false),
                       try server(source: "agent"), try server(stale: true),
                       try server(reportedAt: Self.time - 700), try server(job: "running"), try server(job: "queued"),
                       try server(job: "needs_owner")] {
            #expect(read(unread) == .unread)
        }
        #expect(read(try server(job: "done")) == .faulty)
        #expect(read(try server(job: "failed")) == .faulty)
    }

    @Test func aServerIsNotReadInTheHourAfterItsJoin() throws {
        let faulty = try server()
        #expect(read(faulty, join: try join("app-1", created: Self.time - 3599)) == .unread)
        #expect(read(faulty, join: try join("app-1", created: Self.time - 3600)) == .faulty)
        // The join of another server, or a code that no server has used yet, says nothing of this one.
        #expect(read(faulty, join: try join("app-2", created: Self.time - 60)) == .faulty)
        #expect(read(faulty, join: try join(nil, created: Self.time - 60)) == .faulty)
    }

    // MARK: the hub's own server

    /// A hub installed before release 2026.11.441 had no hardening of its own, and its server has no service that
    /// reads it: the hub's own reading of it (`hardening`) takes it into the same rounds as a joined server.
    @Test func theHubsOwnServerRunsTheProgramOnAFaultThatTheHubReads() throws {
        let memory = ServerHardening.Memory()
        for faulty in [try hubRow(ssh: false), try hubRow(ssh: true, npm: false), try hubRow(ssh: nil, npm: false)] {
            #expect(ServerHardening.applies(to: faulty))
            #expect(read(faulty) == .faulty)
            #expect(ServerHardening.step(read(faulty), memory: memory, seenBefore: false, now: Self.time) == .seen)
            #expect(ServerHardening.step(read(faulty), memory: memory, seenBefore: true, now: Self.time) == .run)
        }
        // One that holds is settled, as a joined server is.
        for holds in [try hubRow(ssh: true, npm: true), try hubRow(ssh: true, npm: nil)] {
            #expect(read(holds) == .holds)
            #expect(ServerHardening.step(read(holds), memory: memory, seenBefore: true, now: Self.time) == .settle)
        }
    }

    /// The cases where the hub's own server is left alone: a hub on a Mac or from before 1.170 (no reading of the
    /// hub's own), a hub whose OpenSSH does not run (null), the hour after the hub's claim, a reading that is not
    /// current, and an open job of a service there.
    @Test func theHubsOwnServerIsLeftAloneWhereTheHubsReadingSaysNothing() throws {
        for alone in [try hubRow(own: false), try hubRow(kind: "mac")] {
            #expect(!ServerHardening.applies(to: alone))
            #expect(read(alone) == .unread)
        }
        // OpenSSH does not run there (Tailscale's own SSH): never a run, and never settled.
        for silent in [try hubRow(ssh: nil, npm: nil), try hubRow(ssh: nil, npm: true)] {
            #expect(read(silent) == .unread)
            #expect(ServerHardening.step(read(silent), memory: ServerHardening.Memory(), seenBefore: true,
                                         now: Self.time) == .nothing)
        }
        // The hour after the hub's claim: its install hardens it after the claim.
        #expect(read(try hubRow(claimed: Self.time - 3599)) == .unread)
        #expect(read(try hubRow(claimed: Self.time - 3600)) == .faulty)
        #expect(read(try hubRow(claimed: nil)) == .unread)
        // Only a current reading: read in the last ten minutes.
        #expect(read(try hubRow(at: Self.time - 599)) == .faulty)
        #expect(read(try hubRow(at: Self.time - 600)) == .unread)
        #expect(read(try hubRow(at: nil)) == .unread)
        #expect(read(try hubRow(job: "running")) == .unread)
        #expect(read(try hubRow(job: "done")) == .faulty)
    }

    /// A hub whose own server also has a service, with a reading of its own (`FLEET_HUB_SERVER=shared`): the hub's
    /// own reading decides, as it does for the hub's watch, so the two never disagree. And a hub from before 1.170 with
    /// such a service leaves that server alone, as this app did before.
    @Test func aHubWithAServiceOfItsOwnIsReadByTheHubsOwnReadingAlone() throws {
        #expect(read(try hubRow(ssh: true, npm: true, service: (ssh: false, npm: false))) == .holds)
        #expect(read(try hubRow(ssh: false, npm: true, service: (ssh: true, npm: true))) == .faulty)
        #expect(read(try hubRow(ssh: nil, npm: nil, service: (ssh: false, npm: false))) == .unread)
        let before = try hubRow(own: false, service: (ssh: false, npm: false))
        #expect(!ServerHardening.applies(to: before))
        #expect(read(before) == .unread)
    }

    /// A reading of the hub's own that cannot be read loses its facts and never the list (`ServerList`).
    @Test func aHubsReadingThatCannotBeReadSaysNothing() throws {
        let bads: [Any] = ["yes", 7, ["ssh_keys_only": "no", "npm_rule": 1, "at": "now", "claimed_at": [1]],
                           ["ssh_keys_only": false, "at": Self.time - 60]]
        for bad in bads {
            let list: [String: Any] = [
                "db": "test-generation", "time": Self.time, "desired_revision": NSNull(), "join": NSNull(),
                "servers": [["name": "hub", "hub": true, "joined": false, "agents": [], "address": "100.80.1.2",
                             "available": false, "why": ["hub_machine"], "hardening": bad] as [String: Any]]]
            let decoded = try JSONDecoder().decode(ServerList.self, from: JSONSerialization.data(withJSONObject: list))
            #expect(decoded.servers.count == 1)
            #expect(read(try #require(decoded.servers.first)) == .unread)
        }
    }

    @Test func itStopsAfterSixTriesAndANewLaunchDoesNotStartAgain() throws {
        var memory = ServerHardening.Memory(), now = Self.time
        for try_ in 1...6 {
            #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: true, now: now) == .run, "try \(try_)")
            memory.failed(at: now, reason: "ssh refused, npm held")
            #expect(memory.failures == try_)
            // Not again before ten minutes.
            #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: true, now: now + 599) == .wait)
            now += 600
        }
        #expect(memory.tries?.givenUp == true)
        for later in [now, now + 86400, now + 365 * 86400] {
            #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: true, now: later) == .wait)
        }
        // What this Mac keeps is the same after a new launch: no seventh try.
        let kept = try JSONDecoder().decode(ServerHardening.Memory.self, from: JSONEncoder().encode(memory))
        #expect(kept == memory)
        #expect(ServerHardening.step(.faulty, memory: kept, seenBefore: true, now: now + 86400) == .wait)
        // A reading that holds still settles it, and nothing runs after that.
        #expect(ServerHardening.step(.holds, memory: kept, seenBefore: true, now: now) == .settle)
    }

    /// A try that found no connection to the server ran nothing there. It has the wait and the six tries of a run, but
    /// for one launch only, and it is not in what this Mac keeps: a new launch looks again, and the six runs are whole.
    @Test func aTryThatFoundNoConnectionIsNotOneOfTheKeptRuns() throws {
        let memory = ServerHardening.Memory()
        var unreached: VaultTries?, now = Self.time
        for try_ in 1...6 {
            #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: true, now: now, unreached: unreached) == .run,
                    "try \(try_)")
            unreached = VaultTries.failed(after: unreached, at: now, reason: "noConnection")
            // Not again before ten minutes.
            #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: true, now: now + 599, unreached: unreached) == .wait)
            now += 600
        }
        // Six tries with no connection: no seventh in this launch.
        #expect(unreached?.givenUp == true)
        for later in [now, now + 86400] {
            #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: true, now: later, unreached: unreached) == .wait)
        }
        // The kept count has none of them, so a new launch looks again at once, and a connection that is found
        // then has all six runs.
        #expect(memory == ServerHardening.Memory() && memory.tries == nil)
        #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: true, now: now) == .run)
        // The tries with no connection change no other step: the first sight of a fault, a reading that holds or
        // says nothing, and a settled server.
        #expect(ServerHardening.step(.faulty, memory: memory, seenBefore: false, now: now, unreached: unreached) == .seen)
        #expect(ServerHardening.step(.holds, memory: memory, seenBefore: true, now: now, unreached: unreached) == .settle)
        #expect(ServerHardening.step(.unread, memory: memory, seenBefore: true, now: now, unreached: unreached) == .nothing)
        var settled = memory
        settled.settled = true
        #expect(ServerHardening.step(.faulty, memory: settled, seenBefore: true, now: now, unreached: nil) == .nothing)
        // A run that failed keeps its own wait, also when a connection was found again.
        var ran = memory
        ran.failed(at: now, reason: "ssh=not-yet npm=held")
        #expect(ServerHardening.step(.faulty, memory: ran, seenBefore: true, now: now + 599, unreached: nil) == .wait)
        #expect(ServerHardening.step(.faulty, memory: ran, seenBefore: true, now: now + 600, unreached: nil) == .run)
    }

    /// The builds before the fix of 15 November 2026 kept a try with no connection as a run, with the reason
    /// `noConnection`. A Mac that found no connection to a hub's server with no agent spent its six tries in an hour
    /// and then left that server for good. That kept count starts again; a count of real runs, and a settled server,
    /// stay as they are.
    @Test func aCountThatAnEarlierBuildKeptForNoConnectionStartsAgain() throws {
        // What such a build wrote after six tries, read back as a new launch reads it.
        let old = try JSONDecoder().decode(ServerHardening.Memory.self, from: Data(
            #"{"failures": 6, "last": 999400, "reason": "noConnection", "settled": false}"#.utf8))
        #expect(old.tries?.givenUp == true)
        #expect(ServerHardening.step(.faulty, memory: old, seenBefore: true, now: Self.time + 86400) == .wait)
        #expect(old.ofRuns == ServerHardening.Memory())
        #expect(ServerHardening.step(.faulty, memory: old.ofRuns, seenBefore: true, now: Self.time) == .run)
        // One such try, a minute ago: no wait is left of it either.
        var one = ServerHardening.Memory()
        one.failed(at: Self.time - 60, reason: "noConnection")
        #expect(ServerHardening.step(.faulty, memory: one.ofRuns, seenBefore: true, now: Self.time) == .run)
        // Six runs that left the fault stay six: no seventh.
        var runs = ServerHardening.Memory()
        for at in stride(from: Self.time - 3600, to: Self.time, by: 600) { runs.failed(at: at, reason: "ssh=not-yet npm=held") }
        #expect(runs.failures == 6 && runs.ofRuns == runs)
        #expect(ServerHardening.step(.faulty, memory: runs.ofRuns, seenBefore: true, now: Self.time + 86400) == .wait)
        // Other reasons of a try are not this one: a command that ran out of time, a hub that did not answer.
        for reason in ["", "timedOut", "noConnection ", "NoConnection", "invalidResponse"] {
            var other = ServerHardening.Memory()
            other.failed(at: Self.time, reason: reason)
            #expect(other.ofRuns == other, "\(reason)")
        }
        // No run can keep that reason, whatever the server printed: a count of runs never starts again by it.
        for output in ["\(ServerHardening.started)\nnoConnection", "\(ServerHardening.started)\nnoConnection\n",
                       "\(ServerHardening.mark) ssh=noConnection npm=noConnection", ServerHardening.started] {
            guard case .failed(let said) = ServerHardening.outcome(output) else { Issue.record("\(output)"); continue }
            var ran = ServerHardening.Memory()
            ran.failed(at: Self.time, reason: said)
            #expect(ran.ofRuns == ran, "\(output)")
        }
        // A settled server stays settled, whatever its last reason was.
        var settled = old
        settled.settled = true
        #expect(settled.ofRuns == settled)
        #expect(ServerHardening.step(.faulty, memory: settled.ofRuns, seenBefore: true, now: Self.time) == .nothing)
    }

    /// What this Mac kept of a server is read with the count of the runs alone, also from the bytes of an earlier
    /// build; nothing kept, and bytes that do not read, are a new memory.
    @Test func whatThisMacKeptIsReadWithTheCountOfTheRunsAlone() throws {
        #expect(ServerHardening.Memory.kept(nil) == ServerHardening.Memory())
        #expect(ServerHardening.Memory.kept(Data("no JSON".utf8)) == ServerHardening.Memory())
        let old = Data(#"{"failures": 6, "last": 999400, "reason": "noConnection", "settled": false}"#.utf8)
        #expect(try JSONDecoder().decode(ServerHardening.Memory.self, from: old).failures == 6)
        #expect(ServerHardening.Memory.kept(old) == ServerHardening.Memory())
        let refused = Data(#"{"failures": 6, "last": 999400, "reason": "the program did not end: Host key verification failed.", "settled": false}"#.utf8)
        #expect(try JSONDecoder().decode(ServerHardening.Memory.self, from: refused).failures == 6)
        #expect(ServerHardening.Memory.kept(refused) == ServerHardening.Memory())
        var runs = ServerHardening.Memory()
        for at in [Self.time - 1200, Self.time - 600] { runs.failed(at: at, reason: "ssh not-yet, npm held") }
        #expect(ServerHardening.Memory.kept(try JSONEncoder().encode(runs)) == runs)
        var settled = ServerHardening.Memory()
        settled.settled = true
        #expect(ServerHardening.Memory.kept(try JSONEncoder().encode(settled)) == settled)
    }

    // MARK: one round, one server

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private struct NoConnection: Error {}
    private struct NotStarted: Error {}

    private static let target = InstallTarget(host: "100.64.0.2")
    private static let held = "\(ServerHardening.mark) ssh=keys-only npm=held"
    private static let notYet = "\(ServerHardening.mark) ssh=not-yet npm=held"
    /// What the program prints first, as a server gives it: an empty line, and its first line.
    private static let begun = "\n\(ServerHardening.started)\n"
    /// What `ssh` of OpenSSH 10 says on this Mac before the output of each server that has no such key exchange.
    private static let warning = "** WARNING: connection is not using a post-quantum key exchange algorithm.\r\n"
        + "** This session may be vulnerable to \"store now, decrypt later\" attacks.\r\n"
        + "** The server may need to be upgraded. See https://openssh.com/pq.html\r\n"
    /// What `ssh` and `sudo` say when they start nothing on the server: a host key that this Mac does not know, a
    /// user that it cannot log in as, a server that refuses the connection or does not answer, and a `sudo` that asks
    /// for a password.
    private static let refusals = [
        "Host key verification failed.\r\n",
        "deploy@100.64.0.2: Permission denied (publickey).\r\n",
        "ssh: connect to host 100.64.0.2 port 22: Connection refused\r\n",
        "ssh: connect to host 100.64.0.2 port 22: Operation timed out\r\n",
        warning + "sudo: a password is required\n",
    ]

    /// One round for one server (`ServerHardening.turn`), with the count of its looks for a connection and of its
    /// runs. `found`: the connection, or nil for a server with none. `output`: what `ssh` printed, or nil for an
    /// `ssh` that did not start on this Mac.
    private func turn(_ reading: ServerHardening.Reading = .faulty, memory: inout ServerHardening.Memory,
                      unreached: inout VaultTries?, seenBefore: Bool = true, now: Double = time,
                      found: InstallTarget? = target, output: String? = held) async
        -> (turn: ServerHardening.Turn, looks: Int, runs: Int) {
        let looks = Count(), runs = Count()
        let turn = await ServerHardening.turn(reading, memory: &memory, unreached: &unreached, seenBefore: seenBefore,
            now: now, connection: {
                looks.add()
                guard let found else { throw NoConnection() }
                return found
            }, run: { target in
                runs.add()
                guard let output, target == found else { throw NotStarted() }
                return output
            })
        return (turn, looks.value, runs.value)
    }

    /// The fault in a second round in a row: the connection, then the program over it, and a server that the run
    /// settled. Every other reading asks for no connection at all.
    @Test func aRoundRunsTheProgramOverTheConnectionThatItFinds() async {
        var memory = ServerHardening.Memory(), unreached: VaultTries?
        // The first sight of the fault: seen, and nothing is asked or run.
        var did = await turn(memory: &memory, unreached: &unreached, seenBefore: false)
        #expect(did.turn == ServerHardening.Turn(seen: true) && did.looks == 0 && did.runs == 0)
        #expect(memory == ServerHardening.Memory() && unreached == nil)
        // A reading that says nothing, and one that holds: no connection is asked for, and the second settles.
        did = await turn(.unread, memory: &memory, unreached: &unreached)
        #expect(did.turn == ServerHardening.Turn() && did.looks == 0 && memory == ServerHardening.Memory())
        var holds = ServerHardening.Memory()
        did = await turn(.holds, memory: &holds, unreached: &unreached)
        #expect(did.turn == ServerHardening.Turn() && did.looks == 0 && did.runs == 0 && holds.settled)
        // The second round: one look, one run over the connection that it found, and the server is settled.
        did = await turn(memory: &memory, unreached: &unreached, output: "reloaded\n\n  \(Self.held)  \n")
        #expect(did.looks == 1 && did.runs == 1)
        #expect(did.turn == ServerHardening.Turn(seen: true, lines: ["reloaded", Self.held, "its hardening is in order"]))
        #expect(memory.settled && memory.failures == 0 && unreached == nil)
        // A settled server: nothing again, whatever it reads.
        did = await turn(memory: &memory, unreached: &unreached)
        #expect(did.turn == ServerHardening.Turn() && did.looks == 0 && did.runs == 0)
        // A server where no account has a key is left as the join leaves it, and settled too.
        var noKey = ServerHardening.Memory()
        did = await turn(memory: &noKey, unreached: &unreached, output: "\(ServerHardening.mark) ssh=no-key npm=held")
        #expect(did.runs == 1 && noKey.settled)
    }

    /// The fault of 15 November 2026 as one round saw it: no connection to the server. Nothing runs, nothing of the
    /// try is in what this Mac keeps, and the tries have their wait and their six for this launch. A new launch looks
    /// again, and a connection that is found then gets the run.
    @Test func aRoundThatFindsNoConnectionKeepsNothingOfIt() async {
        var memory = ServerHardening.Memory(), unreached: VaultTries?, now = Self.time
        for try_ in 1...6 {
            let did = await turn(memory: &memory, unreached: &unreached, now: now, found: nil)
            #expect(did.looks == 1 && did.runs == 0 && did.turn.seen, "try \(try_)")
            #expect(memory == ServerHardening.Memory(), "try \(try_)")
            #expect(unreached == VaultTries(failures: try_, last: now, reason: "NoConnection()"), "try \(try_)")
            // The log has one line, at the sixth.
            #expect(did.turn.lines == (try_ == 6 ? ["nothing ran there in 6 tries (NoConnection()): left until this app starts again"] : []))
            // Not again before ten minutes: no look.
            let early = await turn(memory: &memory, unreached: &unreached, now: now + 599, found: nil)
            #expect(early.looks == 0 && early.turn == ServerHardening.Turn(seen: true), "try \(try_)")
            now += 600
        }
        // No seventh look in this launch, also where a connection is there now.
        var did = await turn(memory: &memory, unreached: &unreached, now: now + 86400)
        #expect(did.looks == 0 && did.runs == 0 && unreached?.failures == 6)
        // A new launch has no such tries: it looks at once, finds the connection, and the program runs.
        unreached = nil
        did = await turn(memory: &memory, unreached: &unreached, now: now)
        #expect(did.looks == 1 && did.runs == 1 && memory.settled && unreached == nil)
    }

    /// **An `ssh` that started nothing on the server is not one of the kept runs** (the case that stayed open on 15
    /// November 2026). Until then six such tries, ten minutes apart, left the server for good, also after the owner
    /// made the login work. Now each is a try of this launch, as a try with no connection is: nothing of it is in what
    /// this Mac keeps, the six are the most for one launch, and a new launch tries again with all six runs whole.
    @Test func anSshThatStartedNothingIsCountedForThisLaunchOnly() async {
        // Six tries: each refusal of `ssh` and `sudo`, and an `ssh` that did not start on this Mac (nil).
        let tries: [String?] = Array(Self.refusals.prefix(3)) + [nil] + Array(Self.refusals.suffix(2))
        let reasons = ["the program did not start: Host key verification failed.",
                       "the program did not start: deploy@100.64.0.2: Permission denied (publickey).",
                       "the program did not start: ssh: connect to host 100.64.0.2 port 22: Connection refused",
                       "NotStarted()",
                       "the program did not start: ssh: connect to host 100.64.0.2 port 22: Operation timed out",
                       "the program did not start: sudo: a password is required"]
        var memory = ServerHardening.Memory(), unreached: VaultTries?, now = Self.time
        for (index, output) in tries.enumerated() {
            let did = await turn(memory: &memory, unreached: &unreached, now: now, output: output)
            #expect(did.looks == 1 && did.runs == 1 && did.turn.seen, "try \(index + 1)")
            // Nothing of it is in what this Mac keeps.
            #expect(memory == ServerHardening.Memory(), "try \(index + 1)")
            #expect(unreached == VaultTries(failures: index + 1, last: now, reason: reasons[index]), "try \(index + 1)")
            // Not again before ten minutes: no look for a connection, and no `ssh`.
            let early = await turn(memory: &memory, unreached: &unreached, now: now + 599)
            #expect(early.looks == 0 && early.runs == 0 && early.turn == ServerHardening.Turn(seen: true), "try \(index + 1)")
            // The log has what `ssh` said, and at the sixth try that this launch leaves the server.
            switch index {
            case 0: #expect(did.turn.lines == ["Host key verification failed."])
            case 3: #expect(did.turn.lines == [])
            case 5: #expect(did.turn.lines == [
                "** WARNING: connection is not using a post-quantum key exchange algorithm.",
                "** This session may be vulnerable to \"store now, decrypt later\" attacks.",
                "** The server may need to be upgraded. See https://openssh.com/pq.html",
                "sudo: a password is required",
                "nothing ran there in 6 tries (the program did not start: sudo: a password is required): "
                    + "left until this app starts again"])
            default: #expect(did.turn.lines.count == 1, "try \(index + 1)")
            }
            now += 600
        }
        // No seventh try in this launch, also where the login works now.
        #expect(unreached?.givenUp == true)
        var did = await turn(memory: &memory, unreached: &unreached, now: now + 86400)
        #expect(did.looks == 0 && did.runs == 0 && unreached?.failures == 6 && memory == ServerHardening.Memory())
        // What this Mac keeps is as it was before the first try, so a new launch tries at once. The owner made the
        // login work: the program runs, and a run that leaves the fault is the first of the six kept runs.
        unreached = nil
        did = await turn(memory: &memory, unreached: &unreached, now: now, output: Self.begun + Self.notYet)
        #expect(did.looks == 1 && did.runs == 1 && unreached == nil)
        #expect(memory.failures == 1 && memory.last == now && memory.reason == "ssh not-yet, npm held")
        // And a run that settles the server after such tries settles it.
        var other = ServerHardening.Memory(), otherUnreached: VaultTries?
        _ = await turn(memory: &other, unreached: &otherUnreached, output: Self.refusals[0])
        did = await turn(memory: &other, unreached: &otherUnreached, now: Self.time + 600, output: Self.begun + Self.held)
        #expect(other.settled && other.failures == 0 && otherUnreached?.failures == 1)
        #expect(did.turn.lines == [Self.held, "its hardening is in order"])
    }

    /// **A run that started on the server and did not end is one of the six kept runs**: the connection broke while
    /// the program ran, or the program was stopped. Its output has the program's first line and no last line. The
    /// program ran in part, so the sixth such run is the last for good, also after a new launch.
    @Test func aRunThatStartedAndDidNotEndIsOneOfTheSixKeptRuns() async {
        let broken = [Self.begun,
                      Self.begun + "Connection to 100.64.0.2 closed by remote host.\r\n",
                      Self.warning + Self.begun + "client_loop: send disconnect: Broken pipe\r\n",
                      "Last login: Sun Nov 15" + Self.begun,
                      Self.begun + "line 2: Bad configuration option: Foo\n",
                      Self.begun + "Timeout, server 100.64.0.2 not responding.\r\n"]
        let reasons = ["nothing", "Connection to 100.64.0.2 closed by remote host.",
                       "client_loop: send disconnect: Broken pipe", "Last login: Sun Nov 15",
                       "line 2: Bad configuration option: Foo", "Timeout, server 100.64.0.2 not responding."]
        var memory = ServerHardening.Memory(), unreached: VaultTries?, now = Self.time
        for (index, output) in broken.enumerated() {
            let did = await turn(memory: &memory, unreached: &unreached, now: now, output: output)
            #expect(did.looks == 1 && did.runs == 1 && did.turn.seen, "try \(index + 1)")
            #expect(memory.failures == index + 1 && memory.last == now && !memory.settled, "try \(index + 1)")
            #expect(memory.reason == "the program started and did not end: " + reasons[index], "try \(index + 1)")
            // It is no try of this launch alone.
            #expect(unreached == nil, "try \(index + 1)")
            #expect((did.turn.lines.last == "left after 6 tries (\(memory.reason))") == (index == 5), "try \(index + 1)")
            now += 600
        }
        #expect(memory.tries?.givenUp == true)
        // No seventh, in this launch and after a new one (what is kept is read back with the count of the runs).
        let kept = ServerHardening.Memory.kept(try? JSONEncoder().encode(memory))
        #expect(kept == memory && kept.failures == 6)
        var again = kept
        unreached = nil
        let did = await turn(memory: &again, unreached: &unreached, now: now + 86400, output: Self.begun + Self.held)
        #expect(did.looks == 0 && did.runs == 0 && again == kept)
    }

    /// **The tries that ran nothing are one count for the launch**, whatever each of them was, and nothing ends that
    /// count: not a connection that is found, and not a run between two such tries. So six are the most for one
    /// launch, also where a try that reads as "did not start" did run on the server.
    @Test func theTriesThatRanNothingAreOneCountForTheLaunch() async {
        var memory = ServerHardening.Memory(), unreached: VaultTries?
        _ = await turn(memory: &memory, unreached: &unreached, found: nil)
        #expect(unreached?.failures == 1)
        // Ten minutes later the connection is on record, and this Mac cannot log in with it: the second such try.
        var did = await turn(memory: &memory, unreached: &unreached, now: Self.time + 600, output: Self.refusals[1])
        #expect(did.looks == 1 && did.runs == 1 && memory == ServerHardening.Memory())
        #expect(unreached?.failures == 2 && unreached?.last == Self.time + 600)
        // And an `ssh` that did not start on this Mac: the third.
        did = await turn(memory: &memory, unreached: &unreached, now: Self.time + 1200, output: nil)
        #expect(did.looks == 1 && did.runs == 1 && memory == ServerHardening.Memory())
        let three = VaultTries(failures: 3, last: Self.time + 1200, reason: "NotStarted()")
        #expect(unreached == three)
        // Then the login works: the run leaves the fault, and that is a kept run. The other count stays as it is.
        did = await turn(memory: &memory, unreached: &unreached, now: Self.time + 1800, output: Self.begun + Self.notYet)
        #expect(did.looks == 1 && did.runs == 1 && unreached == three)
        #expect(memory.failures == 1 && memory.last == Self.time + 1800 && memory.reason == "ssh not-yet, npm held")
        // The run's own wait holds now, with no look for a connection.
        let early = await turn(memory: &memory, unreached: &unreached, now: Self.time + 2399)
        #expect(early.looks == 0 && early.turn == ServerHardening.Turn(seen: true))
        // A run that started and did not end is a kept run too, and leaves the other count as it is.
        did = await turn(memory: &memory, unreached: &unreached, now: Self.time + 2400, output: Self.begun)
        #expect(did.runs == 1 && unreached == three)
        #expect(memory.failures == 2 && memory.reason == "the program started and did not end: nothing")
        // After a kept run, a try that runs nothing leaves the kept count as it is. Its own wait holds then, where
        // the wait of the kept run is over.
        did = await turn(memory: &memory, unreached: &unreached, now: Self.time + 3000, output: Self.refusals[0])
        #expect(did.runs == 1 && memory.failures == 2 && memory.last == Self.time + 2400)
        #expect(unreached?.failures == 4 && unreached?.last == Self.time + 3000)
        let waits = await turn(memory: &memory, unreached: &unreached, now: Self.time + 3599)
        #expect(waits.looks == 0 && waits.turn == ServerHardening.Turn(seen: true))
        // Two more such tries, with a kept run between them: the sixth is the last of this launch, although only
        // three of the six kept runs are spent, and although the login works after it.
        did = await turn(memory: &memory, unreached: &unreached, now: Self.time + 3600, output: Self.refusals[0])
        #expect(unreached?.failures == 5 && did.turn.lines == ["Host key verification failed."])
        did = await turn(memory: &memory, unreached: &unreached, now: Self.time + 4200, output: Self.begun + Self.notYet)
        #expect(memory.failures == 3 && unreached?.failures == 5)
        did = await turn(memory: &memory, unreached: &unreached, now: Self.time + 4800, found: nil)
        #expect(did.looks == 1 && did.runs == 0 && unreached?.givenUp == true && memory.failures == 3)
        #expect(did.turn.lines == ["nothing ran there in 6 tries (NoConnection()): left until this app starts again"])
        for later in [Self.time + 5400, Self.time + 86400] {
            did = await turn(memory: &memory, unreached: &unreached, now: later, output: Self.begun + Self.held)
            #expect(did.looks == 0 && did.runs == 0 && !memory.settled && memory.failures == 3, "\(later)")
        }
        // A new launch has none of those tries and three kept runs: it runs the program at once.
        unreached = nil
        did = await turn(memory: &memory, unreached: &unreached, now: Self.time + 5400, output: Self.begun + Self.held)
        #expect(did.looks == 1 && did.runs == 1 && memory.settled && unreached == nil)
    }

    /// The log gets the last six lines of what the program printed, with no empty line and without the program's
    /// first line, and then what the run came to. A line of `ssh` itself ends with a carriage return too.
    @Test func theLogGetsTheLastSixLinesOfARun() async {
        var memory = ServerHardening.Memory(), unreached: VaultTries?
        let output = (1...8).map { "line \($0)" }.joined(separator: "\n\n") + "\n" + Self.held + "\n"
        var did = await turn(memory: &memory, unreached: &unreached, output: output)
        #expect(did.turn.lines == ["line 4", "line 5", "line 6", "line 7", "line 8", Self.held, "its hardening is in order"])
        var other = ServerHardening.Memory()
        did = await turn(memory: &other, unreached: &unreached, output: Self.warning + Self.begun + "reloaded\n" + Self.held + "\n")
        #expect(did.turn.lines == ["** WARNING: connection is not using a post-quantum key exchange algorithm.",
                                   "** This session may be vulnerable to \"store now, decrypt later\" attacks.",
                                   "** The server may need to be upgraded. See https://openssh.com/pq.html",
                                   "reloaded", Self.held, "its hardening is in order"])
    }

    /// A run that started and did not settle the server is one of the six that this Mac keeps, whether a part of it
    /// failed or it did not end: the sixth is the last for good.
    @Test func aRunThatLeavesTheFaultIsOneOfTheSixKeptRuns() async {
        // Two tries of this launch ran nothing before: no kept run changes that count, also not the sixth.
        let two = VaultTries(failures: 2, last: Self.time - 600, reason: "NoConnection()")
        var memory = ServerHardening.Memory(), unreached: VaultTries? = two, now = Self.time
        let outputs = [Self.notYet, Self.begun, Self.begun + "Connection to 100.64.0.2 closed by remote host.\r\n",
                       Self.begun + Self.notYet, Self.begun, Self.notYet]
        for (try_, output) in outputs.enumerated() {
            let did = await turn(memory: &memory, unreached: &unreached, now: now, output: output)
            #expect(did.looks == 1 && did.runs == 1 && did.turn.seen, "try \(try_ + 1)")
            #expect(memory.failures == try_ + 1 && memory.last == now && !memory.settled && unreached == two, "try \(try_ + 1)")
            #expect((did.turn.lines.last == "left after 6 tries (ssh not-yet, npm held)") == (try_ == 5), "try \(try_ + 1)")
            now += 600
        }
        #expect(memory.tries?.givenUp == true)
        // No seventh, in this launch and after a new one (what is kept is read back).
        let kept = ServerHardening.Memory.kept(try? JSONEncoder().encode(memory))
        #expect(kept == memory)
        var again = kept
        let did = await turn(memory: &again, unreached: &unreached, now: now + 86400)
        #expect(did.looks == 0 && did.runs == 0 && again == kept)
    }

    /// The builds before this one kept an `ssh` that started nothing as a run, in the words that they also had
    /// for a run that broke ("the program did not end: …"). A Mac that could not log in to a server spent its six
    /// tries in an hour and then left that server for good. That kept count starts again; a count in this build's
    /// words stays, and no run of this build can keep the earlier words.
    @Test func aCountThatAnEarlierBuildKeptForAnSshThatStartedNothingStartsAgain() async throws {
        for said in ["Host key verification failed.", "deploy@100.64.0.2: Permission denied (publickey).",
                     "sudo: a password is required", "nothing"] {
            // What such a build wrote after six tries, read back as a new launch reads it.
            let bytes = try JSONSerialization.data(withJSONObject: [
                "failures": 6, "last": 999_400, "reason": "the program did not end: " + said, "settled": false] as [String: Any])
            let old = try JSONDecoder().decode(ServerHardening.Memory.self, from: bytes)
            #expect(old.tries?.givenUp == true, "\(said)")
            #expect(ServerHardening.step(.faulty, memory: old, seenBefore: true, now: Self.time + 86400) == .wait, "\(said)")
            #expect(old.ofRuns == ServerHardening.Memory() && ServerHardening.Memory.kept(bytes) == ServerHardening.Memory(), "\(said)")
            #expect(ServerHardening.step(.faulty, memory: old.ofRuns, seenBefore: true, now: Self.time) == .run, "\(said)")
            // A settled server stays settled, whatever its last reason was.
            var settled = old
            settled.settled = true
            #expect(settled.ofRuns == settled, "\(said)")
        }
        // A count of two such tries, the last a minute ago, starts again too, and no wait is left of it.
        var two = ServerHardening.Memory()
        for at in [Self.time - 660, Self.time - 60] { two.failed(at: at, reason: "the program did not end: Host key verification failed.") }
        #expect(two.failures == 2 && ServerHardening.step(.faulty, memory: two, seenBefore: true, now: Self.time) == .wait)
        #expect(two.ofRuns == ServerHardening.Memory())
        #expect(ServerHardening.step(.faulty, memory: ServerHardening.Memory.kept(try JSONEncoder().encode(two)),
                                     seenBefore: true, now: Self.time) == .run)
        // The words are the first words of the reason: a reason that only has them later is not one of those.
        for reason in ["ssh refused, npm held: the program did not end: x", "The program did not end: x",
                       "the program did not end", "the program started and did not end: nothing",
                       "the program did not start: Host key verification failed."] {
            var other = ServerHardening.Memory()
            for at in stride(from: Self.time - 3600, to: Self.time, by: 600) { other.failed(at: at, reason: reason) }
            #expect(other.failures == 6 && other.ofRuns == other, "\(reason)")
        }
        // No run of this build keeps the earlier words or `noConnection`, whatever `ssh` or the server printed: what a
        // round keeps is read back as it is, so six kept runs stay six.
        let said = ["the program did not end: x", "noConnection", "\(ServerHardening.mark) ssh=the program did not end: x",
                    "\(ServerHardening.mark) the program did not end: x", ""]
        for output in said + said.map({ Self.begun + $0 }) + Self.refusals + [Self.begun, Self.notYet] {
            var memory = ServerHardening.Memory(), unreached: VaultTries?
            for index in 0..<6 {
                _ = await turn(memory: &memory, unreached: &unreached, now: Self.time + Double(index) * 600, output: output)
            }
            #expect(memory.failures == 0 || memory.failures == 6, "\(output)")
            #expect((memory.failures == 0) == (unreached?.failures == 6), "\(output)")
            #expect(ServerHardening.Memory.kept(try JSONEncoder().encode(memory)) == memory, "\(output)")
        }
    }

    // MARK: what a run said

    @Test func theRunsLastLineSaysWhatItCameTo() {
        #expect(ServerHardening.outcome("founderizer-hardening ssh=keys-only npm=made\n") == .holds)
        #expect(ServerHardening.outcome("Warning: ...\nfounderizer-hardening ssh=keys-only npm=held") == .holds)
        #expect(ServerHardening.outcome("founderizer-hardening ssh=off npm=held") == .holds)
        #expect(ServerHardening.outcome("founderizer-hardening ssh=no-key npm=made") == .leftAsItIs)
        #expect(ServerHardening.outcome("Bad configuration option: Foo\nfounderizer-hardening ssh=refused npm=held")
                == .failed("ssh refused, npm held: Bad configuration option: Foo"))
        #expect(ServerHardening.outcome("founderizer-hardening ssh=keys-only npm=failed")
                == .failed("ssh keys-only, npm failed"))
        #expect(ServerHardening.outcome("founderizer-hardening ssh=not-yet npm=held") == .failed("ssh not-yet, npm held"))
        #expect(ServerHardening.outcome("not-founderizer-hardening ssh=keys-only npm=held") != .holds)
        // The program's first line changes none of those: the last line says what the run came to, and the first
        // line is not in the words of a part that failed.
        #expect(ServerHardening.outcome(Self.begun + "founderizer-hardening ssh=keys-only npm=made\n") == .holds)
        #expect(ServerHardening.outcome(Self.begun + "founderizer-hardening ssh=no-key npm=made") == .leftAsItIs)
        #expect(ServerHardening.outcome(Self.begun + "Bad configuration option: Foo\nfounderizer-hardening ssh=refused npm=held")
                == .failed("ssh refused, npm held: Bad configuration option: Foo"))
        #expect(ServerHardening.outcome(Self.begun + Self.notYet) == .failed("ssh not-yet, npm held"))
    }

    /// **Output with no last line: the program's first line says whether anything ran on the server.** With it, the
    /// program started and did not end. Without it, the program did not start: `ssh`'s status is 255 in both cases,
    /// so only the program's own line can say which.
    @Test func theProgramsFirstLineSaysWhetherItStarted() {
        // No line of the program: it did not start.
        #expect(ServerHardening.outcome("sudo: a password is required\n")
                == .notStarted("the program did not start: sudo: a password is required"))
        #expect(ServerHardening.outcome("") == .notStarted("the program did not start: nothing"))
        #expect(ServerHardening.outcome("\n \n") == .notStarted("the program did not start: nothing"))
        #expect(Self.refusals.map(ServerHardening.outcome) == [
            "Host key verification failed.", "deploy@100.64.0.2: Permission denied (publickey).",
            "ssh: connect to host 100.64.0.2 port 22: Connection refused",
            "ssh: connect to host 100.64.0.2 port 22: Operation timed out", "sudo: a password is required",
        ].map { .notStarted("the program did not start: " + $0) })
        // The first line and no last line: it started and did not end.
        #expect(ServerHardening.outcome(Self.begun) == .failed("the program started and did not end: nothing"))
        #expect(ServerHardening.outcome(ServerHardening.started) == .failed("the program started and did not end: nothing"))
        #expect(ServerHardening.outcome(Self.begun + "Connection to 100.64.0.2 closed by remote host.\r\n")
                == .failed("the program started and did not end: Connection to 100.64.0.2 closed by remote host."))
        // After what `ssh` says first, with its line ends, and with spaces around it.
        #expect(ServerHardening.outcome(Self.warning + Self.begun) == .failed(
            "the program started and did not end: ** The server may need to be upgraded. See https://openssh.com/pq.html"))
        #expect(ServerHardening.outcome("  \(ServerHardening.started) \r\n") == .failed("the program started and did not end: nothing"))
        // The line is the program's own only when it is alone on its line. A server that prints the command that it
        // refused, or the line among other words, did not start the program.
        for other in ["printf '\\n%s\\n' \(ServerHardening.started) || exit 1", "x \(ServerHardening.started)",
                      "\(ServerHardening.started) x", "\(ServerHardening.started)-x",
                      "fatal: unrecognized command 'printf '\\n%s\\n' \(ServerHardening.started) || exit 1'",
                      ServerHardening.mark, "\(ServerHardening.mark)-start", ServerHardening.started.uppercased(),
                      "rejected: " + ServerHardening.program().replacingOccurrences(of: "\n", with: " ")] {
            guard case .notStarted = ServerHardening.outcome(other) else { Issue.record("\(other)"); continue }
        }
        // A server that prints the whole program back, each line on its own, started nothing either: the program's
        // text has that line only among the words of its first command.
        guard case .notStarted = ServerHardening.outcome("refused:\n" + ServerHardening.program()) else {
            Issue.record("the program's own text reads as its first line"); return
        }
        // The first line is no last line.
        #expect(!ServerHardening.started.hasPrefix(ServerHardening.mark + " "))
    }

    // MARK: the program on a server

    /// The shells that run it as `/bin/sh`: this Mac's, and the one of Debian and Ubuntu.
    static let shells = ["/bin/sh", "/bin/dash"]

    /// A server's root under a new folder: sshd's folder, root's key, `/run` without `sshd` in it, and the stand-ins.
    private struct Root {
        let folder: URL
        var root: URL { folder.appendingPathComponent("root") }
        var bin: URL { folder.appendingPathComponent("bin") }
        var sshd: URL { root.appendingPathComponent("etc/ssh/sshd_config.d") }
        var file: URL { root.appendingPathComponent("etc/ssh/sshd_config.d/10-fleet-hardening.conf") }
        var npmrc: URL { root.appendingPathComponent("etc/npmrc") }

        init(key: Bool = true) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("hardening-" + UUID().uuidString)
            let files = FileManager.default
            for made in ["root/etc/ssh/sshd_config.d", "root/root/.ssh", "root/home/deploy/.ssh", "root/run", "bin"] {
                try files.createDirectory(at: folder.appendingPathComponent(made), withIntermediateDirectories: true)
            }
            try "# no key here\n\n".write(to: root.appendingPathComponent("home/deploy/.ssh/authorized_keys"),
                                          atomically: true, encoding: .utf8)
            if key {
                try "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOfThisServer00000000000000000000 owner@example\n"
                    .write(to: root.appendingPathComponent("root/.ssh/authorized_keys"), atomically: true, encoding: .utf8)
            }
            // systemctl: OpenSSH runs from its socket, unless `ssh-off` is there. It is the first command that the
            // program starts: with `stops-here`, it stops the program's shell there, as a connection that breaks does.
            try stand("systemctl", """
                [ -e '\(root.path)/stops-here' ] && { kill -KILL "$PPID"; exit 1; }
                case "$1" in is-active) if [ -e '\(root.path)/ssh-off' ]; then printf 'inactive\\ninactive\\n'
                else printf 'inactive\\nactive\\n'; fi;; esac
                """)
            // sshd: nothing it checks answers without /run/sshd; `sshd-refuses` makes it refuse sshd's files; -T says
            // the three settings of the first file in its folder that sets them.
            try stand("sshd", """
                [ -d '\(root.path)/run/sshd' ] || { echo 'Missing privilege separation directory: /run/sshd' >&2; exit 255; }
                [ -e '\(root.path)/sshd-refuses' ] && { echo 'line 2: Bad configuration option: Foo' >&2; exit 255; }
                if [ "$1" = -T ]; then
                  if grep -qx 'PasswordAuthentication no' '\(file.path)' 2>/dev/null; then
                    printf 'passwordauthentication no\\nkbdinteractiveauthentication no\\nx11forwarding no\\n'
                  else printf 'passwordauthentication yes\\nkbdinteractiveauthentication no\\nx11forwarding yes\\n'; fi
                fi
                exit 0
                """)
        }

        private func stand(_ name: String, _ text: String) throws {
            let path = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + text + "\n").write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        func mark(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }

        /// The program in one shell, with the stand-ins first in its PATH. `before`: a command in front of it, for
        /// what root's login shell prints before the program begins. `gone`: both outputs go to a pipe that nobody
        /// reads, as after the server closed them, and nothing is given back. `ignoring`: the signal of a write to such
        /// a pipe is ignored, so the write fails and the shell lives. `throughSudo`: in the words that go through
        /// `sudo -n -i` (`InstallPlan.throughSudo`), where the program is the text of an `eval`.
        func run(_ shell: String, before: String = "", gone: Bool = false, ignoring: Bool = false,
                 throughSudo: Bool = false) throws -> (status: Int32, output: String) {
            let child = Process(), output = Pipe()
            let text = before + ServerHardening.program(root: root.path)
            let program = throughSudo ? InstallPlan.throughSudo(text) : text
            child.executableURL = URL(fileURLWithPath: ignoring ? "/bin/sh" : shell)
            child.arguments = ignoring ? ["-c", #"trap '' PIPE; exec "$0" -c "$1""#, shell, program] : ["-c", program]
            child.standardOutput = output
            child.standardError = output
            if gone {
                let nowhere = Pipe()
                try nowhere.fileHandleForReading.close()
                child.standardOutput = nowhere.fileHandleForWriting
                child.standardError = nowhere.fileHandleForWriting
                try output.fileHandleForWriting.close()
            }
            child.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = bin.path + ":/usr/bin:/bin"
            child.environment = environment
            try child.run()
            let said = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            return (child.terminationStatus, String(decoding: said, as: UTF8.self))
        }

        func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        func mode(_ url: URL) throws -> Int {
            try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
        }
        /// The files of sshd's folder: no new file of the program's stays behind.
        func folderFiles() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: sshd.path).sorted() }
        /// Nothing of the server changed: no file of sshd's, no folder for it, and no file of npm's.
        func isAsItWas() throws -> Bool {
            try folderFiles() == [] && !FileManager.default.fileExists(atPath: root.appendingPathComponent("run/sshd").path)
                && !FileManager.default.fileExists(atPath: npmrc.path)
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    /// The fault of 14 November 2026: no file in sshd's folder and no `/run/sshd`. The program makes the folder, puts
    /// the join's own file in place and says that SSH takes keys only; a second run changes nothing.
    @Test func theProgramPutsTheJoinsFileInPlaceWhereSshdsFolderWasMissing() throws {
        for shell in Self.shells {
            let server = try Root()
            defer { server.remove() }
            let first = try server.run(shell)
            #expect(first.status == 0 && ServerHardening.outcome(first.output) == .holds, "\(shell): \(first.output)")
            #expect(first.output == "\nfounderizer-hardening-started\nfounderizer-hardening ssh=keys-only npm=made\n",
                    "\(shell): \(first.output)")
            #expect(server.text(server.file) == ServerHardening.sshdText)
            #expect(try server.mode(server.file) == 0o644)
            #expect(try server.mode(server.root.appendingPathComponent("run/sshd")) == 0o755)
            #expect(server.text(server.npmrc) == "min-release-age=7\n")
            #expect(try server.folderFiles() == ["10-fleet-hardening.conf"])
            let second = try server.run(shell)
            #expect(second.output.hasSuffix("founderizer-hardening ssh=keys-only npm=held\n"), "\(shell): \(second.output)")
            #expect(server.text(server.file) == ServerHardening.sshdText)
            #expect(server.text(server.npmrc) == "min-release-age=7\n")
            #expect(try server.folderFiles() == ["10-fleet-hardening.conf"])
        }
    }

    /// **The program says that it started before it starts any command.** A run that stops at its first command, as
    /// one whose connection broke there, has printed its first line and nothing else: it reads as a run that started
    /// and did not end, and it changed nothing on the server. So does one that began after words of root's login shell
    /// with no new line. A whole run after such words still says what it came to.
    @Test func theProgramSaysThatItStartedBeforeItStartsAnyCommand() throws {
        for shell in Self.shells {
            let server = try Root()
            defer { server.remove() }
            try server.mark("stops-here")
            let stopped = try server.run(shell)
            #expect(stopped.status != 0 && stopped.output == "\nfounderizer-hardening-started\n", "\(shell): \(stopped.output)")
            #expect(ServerHardening.outcome(stopped.output) == .failed("the program started and did not end: nothing"))
            let login = try server.run(shell, before: "printf 'Last login: Sun Nov 15'; ")
            #expect(login.output == "Last login: Sun Nov 15\nfounderizer-hardening-started\n", "\(shell): \(login.output)")
            #expect(ServerHardening.outcome(login.output)
                    == .failed("the program started and did not end: Last login: Sun Nov 15"))
            #expect(try server.isAsItWas())
            try FileManager.default.removeItem(at: server.root.appendingPathComponent("stops-here"))
            let whole = try server.run(shell, before: "printf 'Last login: Sun Nov 15'; ")
            #expect(whole.status == 0 && ServerHardening.outcome(whole.output) == .holds, "\(shell): \(whole.output)")
        }
        // The line is the program's first, before the line that names its paths: no command comes before it.
        #expect(ServerHardening.program().hasPrefix("printf '\\n%s\\n' founderizer-hardening-started || exit 1\nr=''; "))
    }

    /// **A program whose output the server closed already changes nothing there.** This Mac's `ssh` ends after two
    /// minutes. Where a server's login was slower than that and its sshd then closed the output, the program begins
    /// with nobody to read it, and this Mac has read that try as one that started nothing. The program's first write
    /// then fails, and the program ends there: by the signal of such a write, which ends each program (that half says
    /// nothing of the program's own `exit`), or, where that signal is ignored, by its own `exit`. In its own words,
    /// and in the words that go through `sudo`. No test here can show the other case, an output that the server still
    /// holds open: there the write does not fail, and the program runs on (`ServerHardening.started`).
    @Test func aProgramWhoseOutputGoesNowhereChangesNothing() throws {
        for shell in Self.shells {
            for (ignoring, throughSudo) in [(false, false), (true, false), (false, true), (true, true)] {
                let server = try Root()
                defer { server.remove() }
                let ran = try server.run(shell, gone: true, ignoring: ignoring, throughSudo: throughSudo)
                #expect(ran.status != 0 && (!ignoring || ran.status == 1),
                        "\(shell), ignoring \(ignoring), through sudo \(throughSudo): \(ran.status)")
                #expect(try server.isAsItWas(), "\(shell), ignoring \(ignoring), through sudo \(throughSudo)")
                // The same server with its output read: the program runs to its end.
                let read = try server.run(shell, ignoring: ignoring, throughSudo: throughSudo)
                #expect(ServerHardening.outcome(read.output) == .holds, "\(shell): \(read.output)")
                #expect(try !server.isAsItWas())
            }
        }
    }

    /// A file that sshd refuses is taken back: the earlier one in its place, or none where there was none.
    @Test func aFileThatSshdRefusesIsTakenBack() throws {
        for shell in Self.shells {
            let server = try Root()
            defer { server.remove() }
            try FileManager.default.createDirectory(at: server.root.appendingPathComponent("run/sshd"),
                                                    withIntermediateDirectories: false)
            try server.mark("sshd-refuses")
            let none = try server.run(shell)
            #expect(ServerHardening.outcome(none.output)
                    == .failed("ssh refused, npm made: line 2: Bad configuration option: Foo"), "\(shell): \(none.output)")
            #expect(try server.folderFiles() == [])
            let earlier = "X11Forwarding no\n"
            try earlier.write(to: server.file, atomically: true, encoding: .utf8)
            let kept = try server.run(shell)
            #expect(kept.output.hasSuffix("founderizer-hardening ssh=refused npm=held\n"), "\(shell): \(kept.output)")
            #expect(server.text(server.file) == earlier)
            #expect(try server.folderFiles() == ["10-fleet-hardening.conf"])
        }
    }

    /// No account with a key: password login stays, as the join leaves it, and the server is settled.
    @Test func aServerWhereNoAccountHasAKeyKeepsPasswordLogin() throws {
        for shell in Self.shells {
            let server = try Root(key: false)
            defer { server.remove() }
            let ran = try server.run(shell)
            #expect(ServerHardening.outcome(ran.output) == .leftAsItIs, "\(shell): \(ran.output)")
            #expect(try server.folderFiles() == [])
        }
    }

    /// Where OpenSSH does not run, no password lets anybody in through it, and nothing of sshd's is written.
    @Test func aServerWithNoOpenSSHHasNothingToTake() throws {
        let server = try Root()
        defer { server.remove() }
        try server.mark("ssh-off")
        let ran = try server.run("/bin/sh")
        #expect(ran.output.hasSuffix("founderizer-hardening ssh=off npm=made\n"), "\(ran.output)")
        #expect(try server.folderFiles() == [])
    }

    /// A `min-release-age` line of the owner's own stays as it is, also one of fewer days; a file without one gets the
    /// line after its last one, on a line of its own.
    @Test func npmsFileKeepsTheOwnersOwnLine() throws {
        for shell in Self.shells {
            let server = try Root()
            defer { server.remove() }
            let own = "registry=https://registry.example.com\nmin-release-age=3\n"
            try own.write(to: server.npmrc, atomically: true, encoding: .utf8)
            #expect(try server.run(shell).output.hasSuffix("npm=held\n"))
            #expect(server.text(server.npmrc) == own)
            try "registry=https://registry.example.com".write(to: server.npmrc, atomically: true, encoding: .utf8)
            #expect(try server.run(shell).output.hasSuffix("npm=made\n"))
            #expect(server.text(server.npmrc) == "registry=https://registry.example.com\nmin-release-age=7\n")
        }
    }

    /// On a server the program writes the join's own paths.
    @Test func onAServerTheProgramWritesTheJoinsOwnPaths() {
        let program = ServerHardening.program()
        #expect(program.contains("\nr=''; d=\"$r/etc/ssh/sshd_config.d\"; f=\"$r/etc/ssh/sshd_config.d/10-fleet-hardening.conf\""))
        #expect(program.contains("m=\"$r/etc/npmrc\""))
        #expect(!program.contains("/home/fleet/fleet-server"), "root runs no code that the service's user can change")
    }

    /// The file's text, its place and npm's line are the join's own (`hubsetup.py`), where this repository has it: the
    /// public copy of the apps does not.
    static let hubsetup = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hubsetup.py")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: ServerHardeningTests.hubsetup.path)))
    func theFileAndTheLineAreTheJoinsOwn() throws {
        let source = try String(contentsOf: Self.hubsetup, encoding: .utf8)
        let block = try #require(source.range(of: #"SSHD_TEXT = \((?:\s*"(?:[^"\\]|\\.)*")+\)"#, options: .regularExpression))
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let text = String(source[block])
        let joined = literal.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }.joined().replacingOccurrences(of: "\\n", with: "\n")
        #expect(joined == ServerHardening.sshdText)
        #expect(source.contains("SSHD_DIR = \"\(ServerHardening.sshdFolder)\""))
        #expect(source.contains("SSHD_HARDENING = SSHD_DIR + \"/10-fleet-hardening.conf\""))
        #expect(source.contains("NPMRC = \"\(ServerHardening.npmrc)\""))
        #expect(source.contains("NPM_RULE = \"\(ServerHardening.npmRule)\""))
    }
}
