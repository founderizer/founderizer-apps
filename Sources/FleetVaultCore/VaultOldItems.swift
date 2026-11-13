import Foundation

/// The Keychain items of the store that this vault opened before the fleet's own store became its only store (the
/// owner's choice of 11 November 2026). No code of the vault reads or writes these item names any more, so the vault
/// deletes them. A delete asks for no value (`VaultKeychain.remove`), so the vault never reads an item before it
/// deletes it, and an item that is not there counts as deleted: each cleanup is safe to run again.
///
/// The items of the fleet's own store are not these names and stay as they are: the store key (`store`), the handover
/// key (`age`), the journal of made logins (`writes`) and the journal of requests (`calls`). An agent name has no `.`,
/// so the account of one item (`<agent>.<item>`) is never the account of another item.
public enum VaultOldItems {
    /// The owner's Mac: the old writer of Add secret kept its write token and its project ID under its own account in
    /// the vault's group. No agent name starts with `_`, so no worker item has this account.
    static let writerAccount = "_writer"
    static let writerItems = ["token", "project"]
    /// A worker Mac: its machine token, and the project of its old one-time setup for new logins.
    static let workerItems = ["token", "write-project"]

    /// `FleetVault writer`, which launchd starts in the owner's login session: deletes the old writer's items. True
    /// when each one is gone, also when it was gone already.
    public static func removeWriterItems() -> Bool {
        remove(writerItems, with: firstGeneration(writerAccount).rawRemove)
    }

    /// A worker vault at its start: deletes its old machine token and its old setup item. True when both are gone.
    public static func removeWorkerItems(agent: String) -> Bool {
        remove(workerItems, with: firstGeneration(agent).rawRemove)
    }

    /// These items are of the service of builds 1 to 14 (key generation 1), and the cleanup waits for no move.
    static func firstGeneration(_ agent: String) -> VaultKeychain {
        VaultKeychain(agent: agent, generation: 1, backend: VaultSystemKeychain(), guarded: false)
    }

    /// Each item once, in this order, with `delete` and nothing else: this code has no way to read an item.
    static func remove(_ items: [String], with delete: (String) throws -> Void) -> Bool {
        var gone = true
        for item in items {
            do { try delete(item) } catch { gone = false }
        }
        return gone
    }

    /// True when this Mac's protected configuration is the owner's (`"role": "owner"`). The owner's Mac runs no agent,
    /// and its vault has nothing to do.
    public static var isOwnerMac: Bool { (try? VaultBroker.protectedConfiguration()).map(isOwner) ?? false }

    static func isOwner(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["role"] as? String == "owner"
    }
}
