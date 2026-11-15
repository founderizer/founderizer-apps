import FleetCore
import Foundation
import Observation
import os

/// **The owner's access key on the fleet's servers, put there by itself** (`OwnerAccessKey`; the owner's yes of 10
/// November 2026 to a key in the copy, for a Mac that is lost). The key's public half must be a line of root's
/// `authorized_keys` on each Linux server before the Mac is lost, so this Mac puts it there over the SSH connection
/// that it already has to each of them: on a hub's own server and on every Linux server, within a quarter of an hour
/// of the server's first reading. That connection is the one that this Mac keeps from an install, else the fleet's
/// own record of the server (`connection`), also for a hub's own server that runs no agent.
///
/// **Nothing of it is on a page** (the owner, 24 October 2026: "this should be automatically setup, even under the hood
/// if we dont need anything!"). A server that this Mac cannot reach as root is tried again after ten minutes, six
/// times at most (`VaultTries`), and then left: its line is missing, and nothing else of the fleet changes. A Mac that
/// joined as a server gets none: its agents run as a person's own user, and that Mac has no root line to give. This Mac
/// knows a server by its name and its private address (`OwnerAccessMarks`), so a new server that has the name of a
/// removed server gets its line too.
@MainActor @Observable
final class OwnerAccessModel {
    let hub: URL
    private var working = false
    private var lastRound: Date?
    private var tries: [String: VaultTries] = [:]

    /// How long this Mac waits between two rounds over the servers.
    static let every: TimeInterval = 900
    private static let keptKey = "ownerAccessInPlace"

    init(hub: URL) { self.hub = hub }

    /// Called from the fleet's own poll. Until a round is due it is two dates compared.
    func tick(store: FleetStore, now: Date = Date()) {
        guard !working, store.hub == hub, store.isFresh, store.state?.db != nil,
              lastRound.map({ now.timeIntervalSince($0) >= Self.every }) ?? true else { return }
        lastRound = now
        working = true
        Task {
            await round(store)
            working = false
        }
    }

    /// One round: the fleet's id from the vault's reading, the key that this Mac keeps for that fleet (made now when it
    /// keeps none), and each Linux server that has not got its line yet.
    private func round(_ store: FleetStore) async {
        guard store.hub == hub, store.isFresh, let database = store.state?.db,
              let fleet = (try? await VaultClient().reading(hub: hub, database: database))?.fleetID,
              let list = try? await HubClient().servers(hub: hub, database: database),
              let key = try? OwnerAccessKeychain.kept(fleet: fleet) else { return }
        let now = Date().timeIntervalSince1970
        let records = Self.records(hub: hub, database: database)
        for server in list.servers where server.hub || server.kind == "linux" {
            // A new server with the name of a removed one has another address, so its mark and its tries are its own.
            let mark = OwnerAccessMarks.name(server.name, address: server.address, hub: hub)
            let step = Self.marks().step(server.name, address: server.address, hub: hub, fingerprint: key.fingerprint)
            guard step != .inPlace, tries[mark].map({ $0.isDue(at: now) }) ?? true, store.hub == hub else { continue }
            do {
                let target = try await Self.connection(to: server, hub: hub, records: records)
                let answer = try await LocalShell.run("/usr/bin/ssh", CentralVaultRemote.arguments(
                    target: target, program: OwnerAccess.install(key)), timeout: 60)
                guard OwnerAccess.isInPlace(answer.output) else { throw NotInPlace() }
                Self.keep(key.fingerprint, for: server, hub: hub)
                tries[mark] = nil
            } catch {
                tries[mark] = step.failed(after: tries[mark], at: now, reason: String(describing: error))
            }
        }
    }

    /// The program ran on the server, and its output does not say that the line is in the file.
    private struct NotInPlace: Error {}

    /// One round's reads of the fleet's records of its servers (`ServerRecords`): the list of machines, and the
    /// hub's record of its own server.
    static func records(hub: URL, database: String) -> ServerRecords {
        ServerRecords(machines: { try? await HubClient().machines(hub: hub, database: database).machines },
                      own: { try await HubClient().ownServer(hub: hub, database: database) })
    }

    /// **The connection to one server for a step of this file**, or why there is none (`ServerRecords.Unreached`):
    /// the one that this Mac keeps from an install, else the fleet's own record of the server. That record is in the
    /// list of machines for a server that an agent runs on, and in the hub's record of its own server for a hub's
    /// server with no agent (`ServerRecords`, with the rule of this Mac's key).
    static func connection(to server: ServerEntry, hub: URL, records: ServerRecords) async throws -> InstallTarget {
        try await records.connection(to: server, kept: InstallTargets.target(machine: server.name, hub: hub))
    }

    /// **How this Mac reaches one server as root** (`ServerRecords.target`): the connection that it keeps for it from
    /// its install, else the fleet's own record of the server, which the caller gives.
    static func target(_ server: ServerEntry, hub: URL, record: MachineReach?) -> InstallTarget? {
        ServerRecords.target(server, kept: InstallTargets.target(machine: server.name, hub: hub), record: record)
    }

    /// The fingerprint of the key whose line this Mac put on each server, by the hub's address, the server's name and
    /// its private address (`OwnerAccessMarks`).
    static func marks(defaults: UserDefaults = .standard) -> OwnerAccessMarks {
        OwnerAccessMarks((defaults.dictionary(forKey: keptKey) as? [String: String]) ?? [:])
    }

    static func keep(_ fingerprint: String, for server: ServerEntry, hub: URL, defaults: UserDefaults = .standard) {
        var marks = Self.marks(defaults: defaults)
        marks.keep(fingerprint, for: server.name, address: server.address, hub: hub)
        defaults.set(marks.all, forKey: keptKey)
    }
}

/// **The join's hardening of each Linux server, put right by this Mac by itself** (`ServerHardening`; the owner's "Yes,
/// all of it" of 14 November 2026, after a join kept password login and the fleet's manager asked the owner for a
/// root command), and of the hub's own server, by the hub's own reading of it. It reaches a server as
/// `OwnerAccessModel` does, with the same connection (`OwnerAccessModel.connection`), and runs this app's own program
/// as root there; a server that it has no such connection to gets no run, and a try that ran nothing on the server
/// (no connection, or an `ssh` that did not start the program) is counted for this launch only (`unreached`). What
/// one round does with one server is `ServerHardening.turn`, which has the tests. **Nothing of it is on a page:** what
/// each run said goes to the log only.
@MainActor @Observable
final class ServerHardeningModel {
    let hub: URL
    private var working = false
    private var lastRound: Date?
    /// The servers whose fault the last round read (`memoryName`): a second round in a row runs the program.
    private var seen: Set<String> = []
    /// The tries of this launch that ran nothing on a server (`memoryName`): no connection to it, or an `ssh` that did
    /// not start the program there. They are not in what this Mac keeps of the server (`ServerHardening.Memory`), and
    /// a new launch tries again.
    private var unreached: [String: VaultTries] = [:]

    /// How long this Mac waits between two rounds: two rounds in a row are five minutes apart at least.
    static let every: TimeInterval = 300
    private static let keptKey = "serverHardening"
    private static let log = Logger(subsystem: "com.founderizer.app", category: "server-hardening")

    init(hub: URL) { self.hub = hub }

    /// Called from the fleet's own poll. Until a round is due it is two dates compared.
    func tick(store: FleetStore, now: Date = Date()) {
        guard !working, store.hub == hub, store.isFresh, store.state?.db != nil,
              lastRound.map({ now.timeIntervalSince($0) >= Self.every }) ?? true else { return }
        lastRound = now
        working = true
        Task {
            await round(store)
            working = false
        }
    }

    /// One round: the hub's list of servers, and for each Linux server that joined and for the hub's own server, what
    /// its reading says (the hub's own, on the hub's own server) and what this Mac kept of it.
    private func round(_ store: FleetStore) async {
        guard store.hub == hub, store.isFresh, let database = store.state?.db,
              let list = try? await HubClient().servers(hub: hub, database: database) else { return }
        let records = OwnerAccessModel.records(hub: hub, database: database)
        var seenNow: Set<String> = []
        for server in list.servers where ServerHardening.applies(to: server) {
            guard store.hub == hub else { return }
            let name = Self.memoryName(server, hub: hub), hub = hub
            let kept = Self.memory(name)
            var memory = kept, tries = unreached[name]
            let turn = await ServerHardening.turn(
                ServerHardening.reading(of: server, join: list.join, at: list.time), memory: &memory, unreached: &tries,
                seenBefore: seen.contains(name), now: Date().timeIntervalSince1970,
                connection: { try await OwnerAccessModel.connection(to: server, hub: hub, records: records) },
                run: { target in
                    try await LocalShell.run("/usr/bin/ssh", CentralVaultRemote.arguments(
                        target: target, program: ServerHardening.program()), timeout: 120).output
                })
            unreached[name] = tries
            if turn.seen { seenNow.insert(name) }
            for line in turn.lines {
                Self.log.notice("\(server.name, privacy: .public): \(line, privacy: .public)")
            }
            if memory != kept { Self.keep(memory, for: name) }
        }
        seen = seenNow
    }

    /// What this Mac kept of one server, by the hub's address, the server's name and its private address: a new server
    /// with the name of an earlier one has another address, and starts with nothing kept.
    static func memoryName(_ server: ServerEntry, hub: URL) -> String {
        "\(hub.absoluteString) \(server.name) \(server.address ?? "")"
    }

    /// The count in it is of the runs alone (`ServerHardening.Memory.kept`).
    static func memory(_ name: String, defaults: UserDefaults = .standard) -> ServerHardening.Memory {
        ServerHardening.Memory.kept((defaults.dictionary(forKey: keptKey) as? [String: Data])?[name])
    }

    static func keep(_ memory: ServerHardening.Memory, for name: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: keptKey) as? [String: Data]) ?? [:]
        guard all[name].flatMap({ try? JSONDecoder().decode(ServerHardening.Memory.self, from: $0) }) != memory else { return }
        all[name] = try? JSONEncoder().encode(memory)
        defaults.set(all, forKey: keptKey)
    }
}
