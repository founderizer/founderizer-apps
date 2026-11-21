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
                let answer = try await SSHRun.run(CentralVaultRemote.arguments(
                    target: target, program: OwnerAccess.install(key)), to: target, timeout: 60)
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
    /// This launch's records of the system packages' turn (`ServerLibraries`), by the name in `seen`: its failed runs,
    /// which a new launch does not have, so that each launch tries a server again.
    private var librariesRuns: [String: ServerHardening.Memory] = [:]

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
                    try await SSHRun.run(CentralVaultRemote.arguments(
                        target: target, program: ServerHardening.program()), to: target, timeout: 120).output
                })
            unreached[name] = tries
            if turn.seen { seenNow.insert(name) }
            for line in turn.lines {
                Self.log.notice("\(server.name, privacy: .public): \(line, privacy: .public)")
            }
            if memory != kept { Self.keep(memory, for: name) }
            // The system packages of the fleet's pinned tools (`ServerLibraries`), with a record of their own: a run
            // that failed counts for this launch only (`librariesRuns`), and this Mac keeps a server once settled.
            guard store.hub == hub else { return }
            let librariesName = Self.librariesMark + name, librariesRecord = ServerLibraries.record(name)
            let keptLibraries = Self.memory(librariesRecord, key: ServerLibraries.keptKey)
            var libraries = librariesRuns[librariesName] ?? keptLibraries, librariesTries = unreached[librariesName]
            let librariesTurn = await ServerHardening.turn(
                ServerLibraries.reading(of: server, join: list.join, at: list.time), memory: &libraries,
                unreached: &librariesTries, seenBefore: seen.contains(librariesName), now: Date().timeIntervalSince1970,
                started: ServerLibraries.started, outcome: { ServerLibraries.outcome($0) },
                settledLine: "its system libraries need nothing more",
                connection: { try await OwnerAccessModel.connection(to: server, hub: hub, records: records) },
                run: { target in
                    try await SSHRun.run(CentralVaultRemote.arguments(
                        target: target, program: ServerLibraries.program()), to: target,
                                         timeout: ServerLibraries.runTime).output
                })
            unreached[librariesName] = librariesTries
            librariesRuns[librariesName] = libraries
            if librariesTurn.seen { seenNow.insert(librariesName) }
            for line in librariesTurn.lines {
                Self.log.notice("\(server.name, privacy: .public): libraries: \(line, privacy: .public)")
            }
            if libraries.settled, !keptLibraries.settled {
                Self.keep(libraries, for: librariesRecord, key: ServerLibraries.keptKey)
            }
            // The server's own programs after SSH, npm and the system packages (`parts`), each with a record and a
            // count of its own: a server whose SSH and npm were settled long ago still gets them.
            for part in Self.parts {
                guard store.hub == hub else { return }
                let partName = part.mark + name, keptPart = Self.memory(name, key: part.key)
                var record = keptPart, partTries = unreached[partName]
                let program = part.program
                let partTurn = await ServerHardening.turn(
                    part.reading(server, list.join, list.time), memory: &record, unreached: &partTries,
                    seenBefore: seen.contains(partName), now: Date().timeIntervalSince1970,
                    started: part.started, outcome: part.outcome, settledLine: part.settled,
                    connection: { try await OwnerAccessModel.connection(to: server, hub: hub, records: records) },
                    run: { target in
                        try await SSHRun.run(CentralVaultRemote.arguments(
                            target: target, program: program), to: target, timeout: 120).output
                    })
                unreached[partName] = partTries
                if partTurn.seen { seenNow.insert(partName) }
                for line in partTurn.lines {
                    Self.log.notice("\(server.name, privacy: .public): \(part.log, privacy: .public): \(line, privacy: .public)")
                }
                if record != keptPart { Self.keep(record, for: name, key: part.key) }
            }
            // The agents' browser parts (`ServerBrowser`), with a record and a count of its own, and only from a whole
            // state of the hub: its agents and their tasks say what the parts are for and when the step may run.
            guard store.hub == hub, let state = store.state else { return }
            let browserName = Self.browserMark + name, keptBrowser = Self.browserMemory(name)
            var browser = keptBrowser, browserTries = unreached[browserName]
            let work = ServerBrowser.work(for: server, agents: state.agents, tasks: state.tasks, join: list.join,
                                          at: list.time)
            let seenKey = work?.digest.map { browserName + " " + $0 }
            let browserTurn = await ServerBrowser.turn(
                work, memory: &browser, unreached: &browserTries, seenBefore: seenKey.map(seen.contains) ?? false,
                now: Date().timeIntervalSince1970,
                connection: { try await OwnerAccessModel.connection(to: server, hub: hub, records: records) },
                run: { target, program in
                    try await SSHRun.run(CentralVaultRemote.arguments(
                        target: target, program: program), to: target, timeout: 120).output
                })
            unreached[browserName] = browserTries
            if browserTurn.seen, let seenKey { seenNow.insert(seenKey) }
            for line in browserTurn.lines {
                Self.log.notice("\(server.name, privacy: .public): browser: \(line, privacy: .public)")
            }
            if browser != keptBrowser { Self.keepBrowser(browser, for: name) }
            // The public SSH check (`PublicSSHCheck`), once a day: it reads, logs one line and changes nothing.
            guard store.hub == hub else { return }
            let now = Date().timeIntervalSince1970
            if PublicSSHCheck.due(next: Self.publicCheckDue(name), now: now) {
                let check = await PublicSSHCheck.check(
                    connection: { try await OwnerAccessModel.connection(to: server, hub: hub, records: records) },
                    run: { target, program in
                        try await SSHRun.run(CentralVaultRemote.arguments(target: target, program: program), to: target,
                                             timeout: 60).output
                    })
                Self.log.notice("\(server.name, privacy: .public): public SSH: \(check.line, privacy: .public)")
                Self.keepPublicCheck(PublicSSHCheck.next(read: check.read, now: now), for: name)
            }
        }
        seen = seenNow
    }

    /// When the next public SSH check of each server is due (`PublicSSHCheck.next`), by `memoryName`. Its result is
    /// the round's log line, and nothing else keeps it.
    private static let publicCheckKey = "publicSSHCheck"

    static func publicCheckDue(_ name: String, defaults: UserDefaults = .standard) -> Double? {
        (defaults.dictionary(forKey: publicCheckKey) as? [String: Double])?[name]
    }

    static func keepPublicCheck(_ next: Double, for name: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: publicCheckKey) as? [String: Double]) ?? [:]
        all[name] = next
        defaults.set(all, forKey: publicCheckKey)
    }

    /// The mark of the system packages' turn (`ServerLibraries`) in `seen`, `unreached` and `librariesRuns`.
    private static let librariesMark = "libraries "

    /// One program of the server's own beside its SSH and npm: what this model keeps of a server for it, the same shape
    /// as for SSH and npm under a key of its own (`key`), and in `seen` and `unreached` the server's name after `mark`.
    private struct Part: Sendable {
        let key: String, mark: String, log: String, started: String, settled: String, program: String
        let reading: @Sendable (ServerEntry, JoinState?, Double) -> ServerHardening.Reading
        let outcome: @Sendable (String) -> ServerHardening.Outcome
    }

    /// The memory reserve and limit (`ServerMemory`, with the key and the mark of the version before this list), and the
    /// restart of a server that stops (`ServerRestart`).
    private static let parts = [
        Part(key: "serverMemoryLimit", mark: "memory-limit ", log: "memory", started: ServerMemory.started,
             settled: "its memory limit is in order", program: ServerMemory.program(),
             reading: { ServerMemory.reading(of: $0, join: $1, at: $2) }, outcome: { ServerMemory.outcome($0) }),
        Part(key: ServerRestart.keptKey, mark: "restart ", log: "restart", started: ServerRestart.started,
             settled: "its restart settings are in order", program: ServerRestart.program(),
             reading: { ServerRestart.reading(of: $0, join: $1, at: $2) }, outcome: { ServerRestart.outcome($0) }),
    ]

    /// What this model keeps of a server's browser parts (`ServerBrowser.Memory`) under a key of its own, and in
    /// `seen` and `unreached` the server's name after this mark.
    private static let keptBrowserKey = "serverBrowser"
    private static let browserMark = "browser "

    static func browserMemory(_ name: String, defaults: UserDefaults = .standard) -> ServerBrowser.Memory {
        ServerBrowser.Memory.kept((defaults.dictionary(forKey: keptBrowserKey) as? [String: Data])?[name])
    }

    static func keepBrowser(_ memory: ServerBrowser.Memory, for name: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: keptBrowserKey) as? [String: Data]) ?? [:]
        all[name] = try? JSONEncoder().encode(memory)
        defaults.set(all, forKey: keptBrowserKey)
    }

    /// What this Mac kept of one server, by the hub's address, the server's name and its private address: a new server
    /// with the name of an earlier one has another address, and starts with nothing kept.
    static func memoryName(_ server: ServerEntry, hub: URL) -> String {
        "\(hub.absoluteString) \(server.name) \(server.address ?? "")"
    }

    /// The count in it is of the runs alone (`ServerHardening.Memory.kept`).
    static func memory(_ name: String, defaults: UserDefaults = .standard,
                       key: String = keptKey) -> ServerHardening.Memory {
        ServerHardening.Memory.kept((defaults.dictionary(forKey: key) as? [String: Data])?[name])
    }

    static func keep(_ memory: ServerHardening.Memory, for name: String, defaults: UserDefaults = .standard,
                     key: String = keptKey) {
        var all = (defaults.dictionary(forKey: key) as? [String: Data]) ?? [:]
        guard all[name].flatMap({ try? JSONDecoder().decode(ServerHardening.Memory.self, from: $0) }) != memory else { return }
        all[name] = try? JSONEncoder().encode(memory)
        defaults.set(all, forKey: key)
    }
}
