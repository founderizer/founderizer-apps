import Foundation

/// **The connection to each server of the hub's list, for one round of a step that this Mac runs by itself as root
/// there** (the owner's access line and the join's hardening: `OwnerAccessSweep` in the app). Such a step reaches a
/// server with the connection that this Mac keeps from an install, else with the fleet's own record of that server.
///
/// The record of a server that an agent runs on is in the list of machines (`GET /ui/machines`). The hub's own server
/// need run no agent, and then that list does not name it: the hub's record of its own server is in the vault's page
/// (`GET /ui/vault`, `HubClient.ownServer`). 15 November 2026: both steps read the list only, so the server of a hub
/// that was installed by hand, with no agent on it and no install connection on this Mac, got no access line and no
/// run of its hardening, although the fleet had its connection on record.
///
/// A server that joined and runs no agent yet was in neither page (measured on the same day: on a second Mac of the
/// owner, or on a Mac after a restore, both steps ended there with "no connection"). Its record is on its own row of
/// the list of servers (`ServerEntry.reach`, owner API 1.173), which each step has in hand, so it costs no read. A
/// hub from before that version sends no record on a row, and a row's value that this app cannot use as a connection
/// says nothing either: then the two pages decide as before.
///
/// **The rule for the pages is the key step's** (`OwnerKeyPlan.record`), and this type has no second one: the list
/// first, then the server's own row, then the hub's own page, and a page that did not answer says nothing. The hub's
/// own page names the hub's own server and no other, so it is not read for another server, and not for a server
/// whose row has its record.
///
/// The list is read once in a round, at the first server that needs it. A read of it that did not answer is made again
/// for the next server.
///
/// A page that the owner opens takes the record from the same pages in the same order, out of what the app holds
/// already and with no read of its own (`held`).
public actor ServerRecords {
    /// Why a step ran nothing on a server.
    public enum Unreached: Error, Equatable, Sendable {
        /// This Mac keeps no connection to the server, and the fleet's record of it is known and is none.
        case noConnection
        /// This Mac keeps no connection to the server, and a page of the hub that holds the fleet's record of it did
        /// not answer.
        case recordNotRead
    }

    private let machines: @Sendable () async -> [MachineStatus]?
    private let own: @Sendable () async throws -> VaultHub?
    private var list: [MachineStatus]?

    /// `machines`: the list of machines, or nil when it did not answer. `own`: the hub's record of its own server, nil
    /// when the hub names none; it throws when the page did not answer.
    public init(machines: @escaping @Sendable () async -> [MachineStatus]?,
                own: @escaping @Sendable () async throws -> VaultHub?) {
        self.machines = machines
        self.own = own
    }

    /// The fleet's record of one server of the hub's list. `isHub`: the list of servers says that it is the hub's own
    /// server (`ServerEntry.hub`). `row`: what the server's own row of that list says of its record
    /// (`ServerEntry.reach`), nil when it says nothing.
    public func record(of server: String, isHub: Bool, row: MachineReach? = nil) async -> OwnerKeyPlan.Record {
        if list == nil { list = await machines() }
        let list = list
        if isHub { return await OwnerKeyPlan.record(server: server, row: row, machines: { list }, own: own) }
        return OwnerKeyPlan.record(server: server, listed: list.flatMap { MachineReach.of(server, in: $0) },
                                   listRead: list != nil, row: row, own: nil, ownRead: true)
    }

    /// **The connection to one server**, or why there is none (`Unreached`). `kept`: the connection that this Mac keeps
    /// for it from an install, and with one no page is read.
    public func connection(to server: ServerEntry, kept: InstallTarget?) async throws -> InstallTarget {
        var record: MachineReach?
        if kept == nil {
            switch await self.record(of: server.name, isHub: server.hub, row: server.reach) {
            case .reach(let reach): record = reach
            case .none: throw Unreached.noConnection
            case .unknown: throw Unreached.recordNotRead
            }
        }
        guard let target = Self.target(server, kept: kept, record: record) else { throw Unreached.noConnection }
        return target
    }

    /// **The fleet's record of one server, out of the pages that the app holds already**, for a page that the owner
    /// opens: no read, and the same pages in the same order as a step's (`OwnerKeyPlan.named`). What the first page
    /// that names the server says, whole or not; nil when none names it, which is another answer than a record that
    /// is none. `machines`: the list of machines that the app keeps, which can be empty. `own`: the hub's record of
    /// its own server in the vault's page that the app keeps; it is asked only for the hub's own server, and only
    /// when neither the list nor the server's row names that server.
    public static func held(of server: ServerEntry, machines: [MachineStatus],
                            own: @autoclosure () -> VaultHub?) -> MachineReach? {
        let listed = MachineReach.of(server.name, in: machines), row = server.reach
        return OwnerKeyPlan.named(server: server.name, listed: listed, row: row,
                                  own: listed == nil && row == nil && server.hub ? own() : nil)
    }

    /// **How this Mac reaches one server as root**: the connection that it keeps for it from its install, at the
    /// private address that the fleet reports (a public address lets no SSH in once the installer has run), else the
    /// fleet's own record of the server. A kept user who is not root becomes root with `sudo -n`, so nothing waits for a
    /// password. A record that is not a whole connection, or not one that `ssh` can take, is none.
    ///
    /// **A record's user other than root is none for a root step** (`rootOnly`; the validation of 23 November 2026,
    /// M1): that user owns its `~/.ssh/authorized_keys`, so a line there with a forced command prints what it likes
    /// for the whole session, the `sudo` and root's read included, and the hub writes that record (`hub.sh` records the
    /// hub's own user, `fleet`, for its server). `rootOnly` false only for a step that reads as that user anyway (this
    /// Mac's key registration reads the proof file as its owner, `OwnerMacKeyRegistration`).
    public static func target(_ server: ServerEntry, kept: InstallTarget?, record: MachineReach?,
                              rootOnly: Bool = true) -> InstallTarget? {
        if var kept {
            kept.becomeRoot = kept.user != "root"
            return MachineReach(address: server.address).reaching(kept)
        }
        guard let known = record?.onRecord, known.user == "root" || !rootOnly else { return nil }
        let target = InstallTarget(host: known.address, user: known.user, port: known.port, becomeRoot: known.user != "root")
        return target.isValid ? target : nil
    }
}
