import Foundation
import Testing
@testable import FleetCore

/// **The key swap's plan on a fleet's own rows** (app patch 2, the design's section 5). It runs only with
/// `FOUNDERIZER_LIVE_KEY_SWAP_ROWS`, the path of a saved `GET /ui/servers` answer (or of rows of that shape) outside
/// this repository, and prints one line for each server: what the table wants there, in the order of the roll-out,
/// with the list of owner keys taken as read. With `FOUNDERIZER_LIVE_KEY_SWAP_EXPECT`, the path of the expected lines,
/// it also checks them. A fleet's own names never enter this repository: they are in the two files only.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOUNDERIZER_LIVE_KEY_SWAP_ROWS"] != nil))
struct KeySwapLiveRowsTests {
    /// The lines: each row that can get a step, in the roll-out's order, then each other row by name.
    static func lines(_ rows: [KeySwapServer]) -> [String] {
        let stepped = KeySwapPlan.order(rows).compactMap { row -> String? in
            guard let wanted = KeySwapPlan.wanted(row, central: true) else { return nil }
            let words = wanted.waitsForTheOwner ? "step 1 only; does not switch; the item"
                : wanted.switchTo.map { "step 1, then \($0.rawValue)" } ?? "step 1 only"
            return "\(row.name): \(words)"
        }
        let others = rows.filter { KeySwapPlan.wanted($0, central: true) == nil }.map(\.name).sorted()
            .map { "\($0): nothing" }
        return stepped + others
    }

    @Test func thePlanOnAFleetsOwnRows() throws {
        let environment = ProcessInfo.processInfo.environment
        let rows = try JSONDecoder().decode(KeySwapRows.self, from: Data(contentsOf: URL(fileURLWithPath:
            environment["FOUNDERIZER_LIVE_KEY_SWAP_ROWS"]!))).servers
        let lines = Self.lines(rows)
        for line in lines { print("key swap plan: \(line)") }
        if let expected = environment["FOUNDERIZER_LIVE_KEY_SWAP_EXPECT"] {
            let wanted = try String(contentsOfFile: expected, encoding: .utf8)
                .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            #expect(lines == wanted)
        }
    }
}

/// **The key swap's two steps on a rented test server** (app patch 2, the design's section 7; C44, the second
/// rental). It runs only with `FOUNDERIZER_LIVE_KEY_SWAP_RIG`, the path of the rig's file outside this repository:
///
///     {"server": {"name": "<its name on the test hub>", "host": "…", "user": "root", "port": 22, "identity": "…"},
///      "hub": {"host": "…", "user": "root", "port": 22, "identity": "…"},
///      "owner_py": "/root/owner.py", "second_key": "<a made-up owner key>"}
///
/// It drives this app's own code (the steps' texts, `CentralVaultRemote.arguments` with the strict check of the host
/// key, the reading of each answer, the record of a put-back) over SSH, as root, on the rig only: the rig's host keys
/// must be in this Mac's known_hosts first. Each reading goes to the test hub through the scripted owner there
/// (`owner.py reading`). Only made-up keys are on the rig. The cases run in their order, on one server.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FOUNDERIZER_LIVE_KEY_SWAP_RIG"] != nil),
       .timeLimit(.minutes(20)))
struct KeySwapLiveRigTests {
    struct Machine: Decodable { let name: String?; let host: String; let user: String; let port: Int; let identity: String? }
    struct Rig: Decodable { let server: Machine; let hub: Machine; let owner_py: String; let second_key: String }

    static var rig: Rig {
        get throws {
            try JSONDecoder().decode(Rig.self, from: Data(contentsOf: URL(fileURLWithPath:
                ProcessInfo.processInfo.environment["FOUNDERIZER_LIVE_KEY_SWAP_RIG"]!)))
        }
    }

    static func target(_ machine: Machine) -> InstallTarget {
        InstallTarget(host: machine.host, user: machine.user, port: machine.port, identityFile: machine.identity,
                      becomeRoot: machine.user != "root")
    }

    /// One root program on a machine of the rig, as the app runs its vault's steps.
    static func run(_ machine: Machine, _ program: String) async throws -> String {
        try await LocalShell.run("/usr/bin/ssh", CentralVaultRemote.arguments(target: target(machine), program: program),
                                 timeout: 600).output
    }

    /// The central vault's owner keys and fleet, read as root on the test hub from its own file, as the app reads them.
    static func central(_ rig: Rig) async throws -> KeySwapCentral {
        let text = try await run(rig.hub, "cat /etc/fleet-vault-central/vault.json")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let central = KeySwapCentral(ownerKeys: object?["owner_keys"] as? [String] ?? [], fleet: object?["fleet"] as? String ?? "")
        return try #require(central)
    }

    static func step(_ rig: Rig, _ program: String?) async throws -> KeySwapAnswer {
        KeySwapAnswer.read(try await run(rig.server, try #require(program)))
    }

    /// The reading to the test hub, and the hub's word after it.
    static func told(_ rig: Rig, swaps: Bool, reason: String? = nil) async throws -> Bool {
        let name = try #require(rig.server.name)
        let said = KeySwapPlan.hubReason(reason).map { " " + InstallPlan.quote($0) } ?? ""
        _ = try await run(rig.hub, "python3 \(rig.owner_py) reading \(name) \(swaps)\(said)")
        let rows = try await run(rig.hub, "python3 \(rig.owner_py) servers")
        return rows.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("\(name) ") && $0.contains("'key_swap': True") }
    }

    static func swaps(_ answer: KeySwapAnswer) -> Bool? {
        if case .done(_, let swaps, _, _) = answer.outcome { return swaps }
        return nil
    }

    /// The hub's `program` (`GET /ui/vault`) and the server's `sha256sum` of the same release's `vault.py` have one
    /// form: if they did not, `newProgram` would give each server a step each 10 minutes for ever.
    @Test func theHubsProgramAndTheServersChecksumHaveOneForm() async throws {
        let rig = try Self.rig
        let program = try await Self.run(rig.hub, "python3 \(rig.owner_py) program")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(program.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "\(program)")
        let answer = try await Self.step(rig, KeySwapRemote.keys([], fleet: nil))
        #expect(answer.program == program, "\(answer)")
    }

    @Test func theFirstStepOnAServerWithNoFleetAndNoKey() async throws {
        let rig = try Self.rig, central = try await Self.central(rig)
        let answer = try await Self.step(rig, KeySwapRemote.keys(central.ownerKeys, fleet: central.fleet))
        #expect(KeySwapPlan.switchMayFollow(answer, central: central), "\(answer)")
        #expect(answer.program != nil)
        #expect(try await Self.told(rig, swaps: Self.swaps(answer) ?? false) == (Self.swaps(answer) ?? false))
    }

    @Test func theSwitchOnAndTheSameStepsAgain() async throws {
        let rig = try Self.rig, central = try await Self.central(rig)
        let on = try await Self.step(rig, KeySwapRemote.turn(.on))
        #expect(Self.swaps(on) == true, "\(on)")
        #expect(try await Self.told(rig, swaps: true))
        let again = try await Self.step(rig, KeySwapRemote.keys(central.ownerKeys, fleet: central.fleet))
        if case .done(let state, true, let held, let hasFleet) = again.outcome {
            #expect(state == "there" && held >= central.ownerKeys.count && hasFleet)                 // nothing restarted
        } else { Issue.record("\(again)") }
        let onAgain = try await Self.step(rig, KeySwapRemote.turn(.on))
        if case .done(let state, true, _, _) = onAgain.outcome { #expect(state == "there") } else { Issue.record("\(onAgain)") }
    }

    @Test func aSecondOwnerKeyIsOnlyAdded() async throws {
        let rig = try Self.rig, central = try await Self.central(rig)
        let more = try await Self.step(rig, KeySwapRemote.keys(central.ownerKeys + [rig.second_key], fleet: central.fleet))
        #expect(KeySwapPlan.switchMayFollow(more, central: central), "\(more)")
        let fewer = try await Self.step(rig, KeySwapRemote.keys(central.ownerKeys, fleet: central.fleet))
        if case .done(let state, _, let held, _) = fewer.outcome {
            #expect(state == "there" && held == central.ownerKeys.count + 1)            // nothing taken away
        } else { Issue.record("\(fewer)") }
    }

    @Test func aLatePutBackHoldsAndTryAgainEndsIt() async throws {
        let rig = try Self.rig, central = try await Self.central(rig)
        let name = try #require(rig.server.name)
        #expect(Self.swaps(try await Self.step(rig, KeySwapRemote.turn(.off))) == false)
        // the proxy's port taken by another listener: its start fails after the configuration changed
        _ = try await Self.run(rig.server, "nohup python3 -c 'import socket, time; s = socket.socket(); "
            + "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((\"127.0.0.1\", 876)); s.listen(); "
            + "time.sleep(900)' >/dev/null 2>&1 & echo $! > /root/kb-port-holder")
        let back = try await Self.step(rig, KeySwapRemote.turn(.on))
        _ = try await Self.run(rig.server, "kill $(cat /root/kb-port-holder) 2>/dev/null; rm -f /root/kb-port-holder")
        guard case .stopped(let reason, true) = back.outcome else {
            Issue.record("no put-back: \(back)")
            return
        }
        #expect(KeySwapPlan.showsAtOnce(back))
        var state = KeySwapState()
        let record = KeySwapPlan.record(back, after: nil, wish: nil, keys: central.ownerKeys, fleet: central.fleet,
                                        at: Date().timeIntervalSince1970)
        #expect(record.hold != nil)
        state.set(record, server: name, fleet: central.fleet)
        let row = KeySwapServer(name: name, kind: "linux", joined: true, word: false, readAt: Date().timeIntervalSince1970)
        let facts = KeySwapFacts(central: central, records: state.records(fleet: central.fleet), now: Date().timeIntervalSince1970 + 7200)
        #expect(KeySwapPlan.next([row], facts: facts)?.then == nil)                     // held: no switch to on
        #expect(try await Self.told(rig, swaps: false, reason: reason) == false)
        state.tryAgain(server: name, fleet: central.fleet)                              // the owner's Try again
        let again = KeySwapFacts(central: central, records: state.records(fleet: central.fleet), now: Date().timeIntervalSince1970)
        #expect(KeySwapPlan.next([row], facts: again)?.then == .on)
        #expect(Self.swaps(try await Self.step(rig, KeySwapRemote.turn(.on))) == true)
        #expect(try await Self.told(rig, swaps: true))
    }

    @Test func offAndTheReading() async throws {
        let rig = try Self.rig
        let off = try await Self.step(rig, KeySwapRemote.turn(.off))
        #expect(Self.swaps(off) == false, "\(off)")
        #expect(try await Self.told(rig, swaps: false) == false)
    }

    @Test func anOlderProgramIsNoFailureOfTheStep() async throws {
        let rig = try Self.rig, central = try await Self.central(rig)
        // a program from before `configure`, put in place on the rig only, and the installed one put back after it
        let installed = KeySwapRemote.program
        _ = try await Self.run(rig.server, "cp -p \(installed) /root/kb-vault-kept.py && printf '%s\\n' "
            + "'import argparse' 'p = argparse.ArgumentParser(prog=\"vault.py\")' 's = p.add_subparsers(dest=\"cmd\")' "
            + "'s.add_parser(\"read\")' 'p.parse_args()' > \(installed)")
        let older = try await Self.step(rig, KeySwapRemote.keys(central.ownerKeys, fleet: central.fleet))
        _ = try await Self.run(rig.server, "cp -p /root/kb-vault-kept.py \(installed) && rm -f /root/kb-vault-kept.py")
        #expect(older.outcome == .olderProgram, "\(older)")
        let back = try await Self.step(rig, KeySwapRemote.keys(central.ownerKeys, fleet: central.fleet))
        #expect(KeySwapPlan.switchMayFollow(back, central: central), "\(back)")
    }
}
