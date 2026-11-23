import Foundation

/// **This Mac's guard of a Mac server's pin, until root on that Mac signs its vault key** (VAULT.md limit 10). The
/// owner's Mac reads a Mac server's vault key in the agents' own SSH session, where a program of that user can answer
/// in Fleet Vault's place, and the hub's bound key is the only other word. So a hub that is broken into, with one agent
/// of that Mac, could move the pin of that Mac to the agent's key. This Mac keeps its own record of the key that it last
/// signed for each Mac server (`MacVaultPins`). With a key in that record, it signs that key only, and only when the
/// read key and the hub's bound key are that key too. Each other key stops the trust step with its existing words:
/// before the read when the hub binds another key, and after it when the read gives another key.
///
/// - With no key in the record, the step is as before (a first pin), and the record then takes the key that it signed.
/// - Try again reads again and keeps the record, so it passes when the hub binds the record's key again. Only Remove
///   server on this Mac clears the record, and the Add server after it gives that server a first pin.
/// - A Mac server is each server that the hub's list or this Mac's own Tailscale names a Mac, and each server whose key
///   the record holds, so the hub's word alone never takes the guard away. A Linux server is not touched: its key is
///   read as root, and this rule gives it the step of before.
public struct MacVaultPin: Equatable, Sendable {
    /// The guard covers this server.
    public let covered: Bool
    /// This Mac's record of the key that it last signed for the server, or nil.
    public let record: String?

    /// `kind`: the hub's word for the server (its list of servers); `os`: this Mac's Tailscale's (`MacNetwork.Peer`).
    public init(kind: String?, os: Set<String>, record: String?) {
        covered = kind == "mac" || os.contains("macOS") || record != nil
        self.record = record
    }

    /// The trust step may read the server's key now. False when the record holds another key than the hub's bound key:
    /// then no SSH session opens.
    public func mayRead(bound: String) -> Bool { record.map { $0 == bound } ?? true }

    /// The key that this Mac signs after the read, or nil for the stop: the read key must be the hub's bound key, as for
    /// each server, and the record's key where the record holds one.
    public func signs(found: String, bound: String) -> String? {
        guard found == bound, record.map({ $0 == found }) ?? true else { return nil }
        return found
    }

    /// The record takes the key that this Mac signed: for a server that the guard covers only.
    public var keeps: Bool { covered }

    /// **The first run's seed**: the key that the record takes for a Mac server that this Mac pinned before it kept a
    /// record, with no signature. Only when the record holds no key, and the hub's pin, the hub's bound key and the read
    /// key are one key. The read key is in the condition because the hub names the other two: without it, a hub that is
    /// broken into at that run would put a key of its own into the record.
    public static func seed(record: String?, pinned: String?, bound: String?, found: String?) -> String? {
        guard record == nil, let pinned, pinned == bound, pinned == found else { return nil }
        return pinned
    }

    /// The servers whose seed read is due now, in the hub's order. `VaultPlan` gives a trusted server with a fresh pin
    /// no step until its re-sign, so the seed has a read of its own: for each server that the hub reports trusted, with
    /// no key in the record, that the owner did not remove on this Mac, and with no seed of this run that ended
    /// (`seedEnded`) or that failed in the last `VaultTries.wait`, at most `VaultTries.most` in a row. Whether it is a Mac
    /// server the read step finds out before it opens an SSH session. While the record of the removed servers is not
    /// known, no seed is due.
    public static func seedsDue(_ reading: VaultReading, records: [String: String], removed: Set<String>,
                                removedKnown: Bool, tries: [String: VaultTries], now: Double) -> [String] {
        guard removedKnown, reading.central?.ok == true else { return [] }
        return reading.machines.filter { machine in
            machine.isTrusted && CentralVault.isMachine(machine.machine) && records[machine.machine] == nil
                && !removed.contains(machine.machine) && (tries[machine.machine]?.isDue(at: now) ?? true)
        }.map(\.machine)
    }

    /// A seed that read its server, or found that it is not a Mac server: no other seed of that server in this run.
    public static func seedEnded(at now: Double) -> VaultTries {
        VaultTries(failures: VaultTries.most, last: now, reason: "")
    }
}

/// **This Mac's record of the key that it last signed for each Mac server** (`MacVaultPin`), by hub address, fleet and
/// machine, as `CentralVaultPins` keeps the central vault's key: public keys, in this Mac's defaults.
public enum MacVaultPins {
    static let key = "macVaultPins"

    /// One change of this Mac that touches the record of one server.
    public enum Change: Equatable, Sendable {
        /// This Mac signed a pin of this key for a server that the guard covers (`MacVaultPin.keeps`).
        case signed(String)
        /// The first run's seed found this key (`MacVaultPin.seed`), and nothing was signed.
        case seeded(String)
        /// Add server for it on this Mac. Try again on its row runs this change first (`CentralVaultModel.retry`), so
        /// the record stays: else a hub that is broken into, with one agent of that Mac, makes the row show, and the
        /// owner's press pins the agent's key.
        case added
        /// Remove server on this Mac: the one change that clears the record.
        case removed
    }

    /// The record's key for a server after `change`.
    public static func record(after change: Change, of earlier: String?) -> String? {
        switch change {
        case .signed(let key), .seeded(let key): key
        case .added: earlier
        case .removed: nil
        }
    }

    /// The record of one fleet at one hub address, by machine. A value that is not a vault key is not a record.
    public static func records(hub: URL, fleet: String, in defaults: UserDefaults = AppDefaults.store) -> [String: String] {
        let all = defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        return (all[name(hub, fleet)] ?? [:]).filter { CentralVault.recipient($0.value) != nil }
    }

    /// The record after one change of this Mac for `machine`. A change that leaves the record as it is writes nothing:
    /// Add server's page makes its change every few seconds while it shows a server that joined.
    public static func note(_ change: Change, machine: String, hub: URL, fleet: String,
                            in defaults: UserDefaults = AppDefaults.store) {
        var all = defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        var fleets = all[name(hub, fleet)] ?? [:]
        let after = record(after: change, of: fleets[machine])
        guard after != fleets[machine] else { return }
        fleets[machine] = after
        all[name(hub, fleet)] = fleets.isEmpty ? nil : fleets
        defaults.set(all, forKey: key)
    }

    private static func name(_ hub: URL, _ fleet: String) -> String { "\(hub.absoluteString)|\(fleet)" }
}
