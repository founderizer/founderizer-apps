import FleetCore
import Foundation
import os

/// **The servers that this Mac made, to the hub, signed** (F17's SP1, `ServerMade`; the owner's rule of 22 November
/// 2026: "my mac is just a client ... we can't rely on the current mac!"). Each server that this Mac made for the
/// fleet becomes a record of the hub that this Mac's owner key signed, so that another device, and later the fleet's
/// keeper, knows the fleet's servers when this Mac is gone.
///
/// **Nothing of it is on a page.** It looks from the fleet's own poll, once a minute at most, only on a hub that keeps
/// the records (`ServerMade.feature`), and it ends: once a round did all that it had, the hub is asked no more in this
/// start of the app, but for a server that this run makes or another generation of the hub (`ServerMade.Pace`). A round
/// that waits is tried again after ten minutes, with one line in the log and no row. The rules of a round are
/// FleetCore's (`ServerMade.sweep`), the one of the fleet that this Mac pinned with them.
@MainActor
final class ServerMadeModel {
    /// What the hub says of its fleet (`VaultReading`): the fleet's id, and the machine of the hub.
    struct Said {
        var fleet: String?
        var machine: String?
    }

    let hub: URL
    private let key: @Sendable (String) -> (any OwnerKey)?
    private let said: @MainActor (FleetStore) -> Said
    private var pace = ServerMade.Pace()
    private var work: Task<Void, Never>?
    private var logged: String?
    /// The app forgot this fleet: no round runs, and one that ran writes nothing more.
    private(set) var stopped = false

    private static let log = Logger(subsystem: "com.founderizer.app", category: "server-made")

    /// `key`, `said`: for a test.
    init(hub: URL, key: @escaping @Sendable (String) -> (any OwnerKey)? = { OwnerKeychain.key(fleet: $0) },
         said: @escaping @MainActor (FleetStore) -> Said = { store in
             let reading = store.vaultModel().reading
             return Said(fleet: reading?.fleetID, machine: reading?.hub?.machine)
         }) {
        self.hub = hub; self.key = key; self.said = said
    }

    /// A round runs now.
    var working: Bool { work != nil }

    func stop() {
        stopped = true
        work?.cancel()
        work = nil
    }

    /// Called from the fleet's own poll: between two looks it is two dates compared. No look while the vault's reading
    /// names no fleet yet (the first polls of a start): such a round would only wait its ten minutes.
    func tick(store: FleetStore, now: Date = Date()) {
        let fresh = ServerMade.Fresh.holds(hub: hub)
        guard work == nil, !stopped, pace.due(now, fresh: fresh), store.hub == hub, store.isFresh,
              let database = store.state?.db, store.state?.ui_features?.contains(ServerMade.feature) == true else { return }
        let named = said(store)
        guard let fleet = named.fleet else { return }
        pace.look(at: now)
        let name = "\(database)|\(fleet)"
        guard pace.runs(name, fresh: fresh) else { return }
        let hub = hub, client = store.installation, key = key, files = pace.files(name)
        let clock = VaultPlan.clockProblem(hubTime: store.state?.time, readAt: store.lastSuccess?.timeIntervalSince1970)
        work = Task {
            let outcome = await Self.round(hub: hub, database: database, client: client, said: named, clock: clock,
                                           files: files, key: key)
            guard !stopped else { return }
            work = nil
            pace.ended(name, done: outcome.done, files: files, freshLeft: ServerMade.Fresh.holds(hub: hub), at: now)
            note(outcome)
        }
    }

    private func note(_ outcome: ServerMade.Outcome) {
        let line = "server records: \(outcome.signed) signed, \(outcome.sent) sent, \(outcome.refused) refused"
            + (outcome.waits.map { "; waits: \($0)" } ?? "")
        guard line != logged, outcome.signed + outcome.sent + outcome.refused > 0 || outcome.waits != nil else { return }
        logged = line
        Self.log.notice("\(line, privacy: .public)")
    }

    nonisolated private static func round(hub: URL, database: String, client: String, said: Said, clock: String?,
                                          files: ServerMade.FileRead,
                                          key: @escaping @Sendable (String) -> (any OwnerKey)?) async -> ServerMade.Outcome {
        await ServerMade.sweep(ServerMade.Sweep(
            hub: hub, named: said.fleet, hubMachine: said.machine, clock: clock, fileRead: files, key: key,
            listing: { try await HubClient().madeServers(hub: hub, database: database) },
            send: { try await HubClient().keepMadeServer(hub: hub, database: database, client: client, signed: $0) },
            swept: { try await HubClient().keepMadeSwept(hub: hub, database: database, client: client, by: $0) },
            files: {
                ServerMade.Files(builds: BuildRecords.shared.all(), unswept: BuildRecords.shared.unswept(),
                                 made: MadeServers.unswept(hub: hub))
            },
            lists: { await Self.lists() },
            move: { old in
                BuildRecords.shared.sweep(old.builds)
                MadeServers.sweep(old.entries, hub: hub)
            }))
    }

    /// Each provider's list whose token this Mac holds, read at once, as "Start again" reads them
    /// (`StartAgainView.read`); `waits` when a list did not come for a fault of the moment (`ServerMade.listWaits`). A
    /// provider whose token this Mac does not hold, or whose token it refuses, is in no list and is not waited for.
    nonisolated static func lists() async -> (listed: [CloudProvider: [CloudExisting]], waits: Bool) {
        let providers = CloudProvider.allCases.filter { CloudServers(provider: $0).isHeld }
        var listed: [CloudProvider: [CloudExisting]] = [:], waits = false
        // Each read gives its list, or whether its fault is of the moment: an error itself does not cross tasks.
        await withTaskGroup(of: (CloudProvider, [CloudExisting]?, Bool).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider, try await CloudServers(provider: provider).servers(), false) } catch {
                        return (provider, nil, ServerMade.listWaits(error))
                    }
                }
            }
            for await (provider, servers, waiting) in group {
                if let servers { listed[provider] = servers }
                if waiting { waits = true }
            }
        }
        return (listed, waits)
    }
}
