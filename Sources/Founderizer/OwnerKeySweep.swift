import FleetCore
import Foundation
import Observation
import os

/// **This Mac's key for its hub, registered by itself** (`OwnerMacKey`; the owner's answers of 14 November 2026: "By
/// itself, over SSH", and "One row in System status" for the Mac that cannot).
///
/// A hub from before the key knows this Mac by its address alone, and so does a VM or a container on this Mac. So
/// when the hub can take a key and this Mac has none that the hub takes, this Mac registers one through the SSH
/// connection that it has to the hub's own server (`OwnerMacKeyRegistration`): the proof is that connection, which
/// a guest behind the Mac does not have. The same steps give the Mac a new key when its file is lost, or when
/// another key took its place.
///
/// **Nothing of it is on a page while it works** (the owner, 24 October 2026: "this should be automatically setup,
/// even under the hood if we dont need anything!"). When it runs is `OwnerKeyPlan.step`, with no reads of its own: a
/// try that failed comes again after ten minutes, six times at most (`VaultTries`), and a registration that went
/// through is not made again for ten minutes. A Mac that has no SSH connection to the hub's server, or whose second
/// try in a row failed, says so in one block of System status (`cannot`), with the line to run on the hub's server.
@MainActor @Observable
final class OwnerKeyModel {
    let hub: URL
    @ObservationIgnored private var working = false
    private var tries: VaultTries?
    @ObservationIgnored private var remembered = false
    /// A page of the hub did not answer the read that keeps the connection: not before this time again.
    @ObservationIgnored private var rememberAfter = 0.0
    @ObservationIgnored private var registered: Double?
    /// This Mac could not register its key by itself, and the hub knows it by its address alone.
    private(set) var cannot = false

    private static let keptKey = "ownerKeyHubServer"
    private static let log = Logger(subsystem: "com.founderizer.app", category: "owner-key")

    init(hub: URL) { self.hub = hub }

    /// Called from the fleet's own poll. While the hub takes this Mac's key it is one small file read, off the main
    /// actor (`OwnerMacKey.holding`).
    func tick(store: FleetStore, now: Date = Date()) {
        guard !working, store.hub == hub, !store.hubIsUnset else { return }
        working = true
        Task {
            await step(store, holding: await OwnerMacKey.holding(hub: hub), now: now)
            working = false
        }
    }

    private func step(_ store: FleetStore, holding: OwnerMacKey.Holding, now: Date) async {
        guard store.hub == hub, !store.hubIsUnset else { return }
        let refused = OwnerMacKey.refused(hub: hub) != nil, held = holding == .key
        if held && !refused {
            tries = nil
            if cannot { cannot = false }
        }
        switch OwnerKeyPlan.step(held: held, known: holding != .unknown, refused: refused,
                                 takesKeys: store.state?.ui_features?.contains(OwnerMacKey.feature) == true,
                                 fresh: store.isFresh, remembered: remembered, tries: tries, registered: registered,
                                 now: now.timeIntervalSince1970) {
        case .nothing: return
        case .remember:
            // Once in each run: the connection to the hub's server, kept for a day on which this Mac has lost its
            // key and so reads no list of servers. A read that failed is tried again ten minutes later.
            guard now.timeIntervalSince1970 >= rememberAfter else { return }
            if await hubServer(store) == .unknown {
                rememberAfter = Date().timeIntervalSince1970 + VaultTries.wait
            } else {
                remembered = true
            }
        case .register:
            await round(store)
        }
    }

    private func round(_ store: FleetStore) async {
        let hub = hub, now = Date().timeIntervalSince1970
        let reach = await hubServer(store)
        do {
            guard case .target(let target) = reach else { throw OwnerMacKeyRegistration.Failure.noValue }
            try await OwnerMacKeyRegistration.run(hub: hub, post: { target, body in
                    try await OwnerMacKeyRegistration.post(hub: target, body: body)
                },
                read: { program in
                    // As the user that this Mac logs in as, which is enough when that user runs the hub. Else as
                    // root, which reads the file as its owner (`OwnerMacKeyRegistration.program`).
                    let own = try? await LocalShell.run("/usr/bin/ssh", OwnerMacKeyRegistration.arguments(
                        target: target, program: program, asRoot: false), timeout: 60).output
                    if let own, OwnerMacKeyRegistration.value(own) != nil || !target.becomeRoot { return own }
                    return try await LocalShell.run("/usr/bin/ssh", OwnerMacKeyRegistration.arguments(
                        target: target, program: program, asRoot: true), timeout: 60).output
                })
            tries = nil
            cannot = false
            registered = now
            Self.log.notice("this Mac registered its key for the hub")
            await store.refresh()
        } catch OwnerMacKeyRegistration.Failure.noAnswer {
            // The hub can have registered the key, which waits in its file: the next read carries it, and the hub's
            // answer to that read decides. No second registration follows before ten minutes.
            registered = now
            Self.log.notice("no answer came to this Mac's key registration: its key waits for the hub's next answer")
            await store.refresh()
        } catch {
            let failed = VaultTries.failed(after: tries, at: now, reason: String(describing: error))
            tries = failed
            if OwnerKeyPlan.cannot(reach: reach, failures: failed.failures) { cannot = true }
            Self.log.notice("this Mac could not register its key for the hub: \(String(describing: error), privacy: .public)")
        }
    }

    /// **How this Mac reaches the hub's own server**: as `OwnerAccessModel` reaches each server, from the hub's list
    /// while this Mac reads it, and kept for the time when it does not (a Mac whose key the hub refuses reads no
    /// list). The fleet's record of that server is in the list of machines when an agent runs there, and else in the
    /// hub's record of its own server (`OwnerKeyPlan.record`). `.none` when the list of servers names no server of the
    /// hub, when the record is known to be no connection, and when it is not one that `ssh` can take: a read of the
    /// record that failed says nothing (`.unknown`).
    private func hubServer(_ store: FleetStore) async -> OwnerKeyPlan.Reach {
        if store.hub == hub, store.isFresh, let database = store.state?.db,
           let list = try? await HubClient().servers(hub: hub, database: database) {
            guard let server = list.servers.first(where: { $0.hub }) else { return Self.kept(hub: hub).map { .target($0) } ?? .none }
            var record: MachineReach?
            if InstallTargets.target(machine: server.name, hub: hub) == nil {
                // The hub's own server need run no agent, and then the list of machines does not name it: the hub's
                // own record of that server is in the vault's page (`OwnerKeyPlan.record`).
                let hub = hub
                let found = await OwnerKeyPlan.record(server: server.name,
                    machines: { try? await HubClient().machines(hub: hub, database: database).machines },
                    own: { try await HubClient().ownServer(hub: hub, database: database) })
                guard case .reach(let reach) = found else {
                    return OwnerKeyPlan.reach(without: found, kept: Self.kept(hub: hub))
                }
                record = reach
            }
            if let target = OwnerAccessModel.target(server, hub: hub, record: record) {
                Self.keep(target, hub: hub)
                return .target(target)
            }
            return Self.kept(hub: hub).map { .target($0) } ?? .none
        }
        return Self.kept(hub: hub).map { .target($0) } ?? .unknown
    }

    private struct Kept: Codable {
        var host: String
        var user: String
        var port: Int
        var identityFile: String?
        var becomeRoot: Bool
    }

    /// The connection is kept by the hub's host and port, as the key's own file is (`OwnerMacKey.name`), so the
    /// address with and without its last "/" is one hub. It holds no secret: a host, a user, a port and a key's path.
    private static func name(_ hub: URL) -> String { OwnerMacKey.name(hub: hub) ?? hub.absoluteString }

    static func keep(_ target: InstallTarget, hub: URL, defaults: UserDefaults = .standard) {
        var all = (defaults.data(forKey: keptKey).flatMap { try? JSONDecoder().decode([String: Kept].self, from: $0) }) ?? [:]
        all[name(hub)] = Kept(host: target.host, user: target.user, port: target.port,
                              identityFile: target.identityFile, becomeRoot: target.becomeRoot)
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: keptKey) }
    }

    static func kept(hub: URL, defaults: UserDefaults = .standard) -> InstallTarget? {
        guard let all = defaults.data(forKey: keptKey).flatMap({ try? JSONDecoder().decode([String: Kept].self, from: $0) }),
              let kept = all[name(hub)] else { return nil }
        let target = InstallTarget(host: kept.host, user: kept.user, port: kept.port, identityFile: kept.identityFile,
                                   becomeRoot: kept.becomeRoot)
        return target.isValid ? target : nil
    }
}
