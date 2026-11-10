import FleetCore
import Foundation
import Observation

/// **The owner's access key on the fleet's servers, put there by itself** (`OwnerAccessKey`; the owner's yes of 10
/// November 2026 to a key in the copy, for a Mac that is lost). The key's public half must be a line of root's
/// `authorized_keys` on each Linux server before the Mac is lost, so this Mac puts it there over the SSH connection
/// that it already has to each of them: on a hub's own server and on every Linux server, within a quarter of an hour
/// of the server's first reading.
///
/// **Nothing of it is on a page** (the owner, 24 October 2026: "this should be automatically setup, even under the hood
/// if we dont need anything!"). A server that this Mac cannot reach as root is tried again after ten minutes, six
/// times at most (`VaultTries`), and then left: its line is missing, and nothing else of the fleet changes. A Mac that
/// joined as a server gets none: its agents run as a person's own user, and that Mac has no root line to give.
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
        var machines: [MachineStatus]?
        for server in list.servers where server.hub || server.kind == "linux" {
            guard Self.kept(server.name, hub: hub) != key.fingerprint, tries[server.name].map({ $0.isDue(at: now) }) ?? true,
                  store.hub == hub else { continue }
            do {
                if machines == nil, InstallTargets.target(machine: server.name, hub: hub) == nil {
                    machines = try await HubClient().machines(hub: hub, database: database).machines
                }
                guard let target = Self.target(server, hub: hub, record: machines.flatMap { MachineReach.of(server.name, in: $0) })
                else { throw Unreached.noConnection }
                let answer = try await LocalShell.run("/usr/bin/ssh", CentralVaultRemote.arguments(
                    target: target, program: OwnerAccess.install(key)), timeout: 60)
                guard OwnerAccess.isInPlace(answer.output) else { throw Unreached.notInPlace }
                Self.keep(key.fingerprint, for: server.name, hub: hub)
                tries[server.name] = nil
            } catch {
                tries[server.name] = VaultTries.failed(after: tries[server.name], at: now, reason: String(describing: error))
            }
        }
    }

    private enum Unreached: Error { case noConnection, notInPlace }

    /// **How this Mac reaches one server as root**: the connection that it keeps for it from its install, at the
    /// private address that the fleet reports (a public address lets no SSH in once the installer has run), else the
    /// fleet's own record of the server. A user who is not root becomes root with `sudo -n`, so nothing waits for a
    /// password.
    static func target(_ server: ServerEntry, hub: URL, record: MachineReach?) -> InstallTarget? {
        if var kept = InstallTargets.target(machine: server.name, hub: hub) {
            kept.becomeRoot = kept.user != "root"
            return MachineReach(address: server.address).reaching(kept)
        }
        guard let known = record?.onRecord else { return nil }
        let target = InstallTarget(host: known.address, user: known.user, port: known.port, becomeRoot: known.user != "root")
        return target.isValid ? target : nil
    }

    /// The fingerprint of the key whose line this Mac put on a server, by the hub's address and the server's name.
    static func kept(_ machine: String, hub: URL, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: keptKey) as? [String: String])?[name(machine, hub: hub)]
    }

    static func keep(_ fingerprint: String, for machine: String, hub: URL, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: keptKey) as? [String: String]) ?? [:]
        all[name(machine, hub: hub)] = fingerprint
        defaults.set(all, forKey: keptKey)
    }

    private static func name(_ machine: String, hub: URL) -> String { "\(hub.absoluteString) \(machine)" }
}
