import FleetCore
import Foundation

/// **A key that the door holds** (owner feature `server_access`, DevOps plan C5). The door's provider tokens and GitHub
/// App keys are normal secrets of the central vault with the door as their holder: the vault seals each one to the
/// door's pinned key, the hub carries only that sealed copy, and only the door's own OS user opens it. A request for one
/// (`request_secret` naming the door) comes through the request form that the owner has now, and Save there gives it to
/// the door. The GitHub App key comes through the rows of the GitHub App that he has now (`GitHubAppSection`).
@MainActor
enum DoorKeys {
    struct Stop: LocalizedError {
        let errorDescription: String?
        init(_ says: String) { errorDescription = says }
    }

    /// The fleet has a door: the hub offers server access, and this Mac's own Tailscale shows the door's device.
    static func hasDoor(_ store: FleetStore) async -> Bool {
        guard store.state?.ui_features?.contains(ServerGrantCommand.feature) == true else { return false }
        return await DoorSyncModel.door() != nil
    }

    /// One value into the central vault as an API key that only the door holds: sealed here to the vault's key that
    /// this Mac pinned, registered with the hub, sent, and given to the door with the owner's signed grant. The value
    /// is in memory for this call only. Gives the secret's reference. reference: the one that an earlier try of the same
    /// key registered (`DoorKeyReference`), so that a try that failed after the hub step leaves no second catalog entry.
    static func put(_ value: String, variable: String, store: FleetStore, reference: String? = nil) async throws -> String {
        guard let database = store.state?.db else { throw Stop(String(l10n: "No current status of this hub. Nothing was sent.")) }
        // The give to the door at the end waits for the clock (GrantSigning.checkClock) on a hub that takes signed
        // grants: checked first, so a stop sends no value and makes no catalog entry that no grant names.
        if GrantSigning.offered(store) { try GrantSigning.checkClock(store) }
        let hub = store.hub, client = store.installation
        guard let reading = try await VaultClient().reading(hub: hub, database: database), let fleet = reading.fleetID,
              let recipient = reading.trusted(pin: CentralVaultPins.recipient(hub: hub, fleet: fleet)) else {
            throw Stop(String(l10n: "The central vault does not answer with the key this Mac pinned. Nothing was sent."))
        }
        var secret = LoginSecret()
        secret.kind = .apiKey
        secret.env = variable
        secret.password = value
        if let problem = secret.problem { throw Stop(problem) }
        let item = try secret.value()
        let sealed = try AgeSeal.seal(item, to: recipient)
        let reference = reference ?? DoorKeyReference.make()
        let salts = try await HubClient().secretSalts(hub: hub, database: database, login: reference)
        // The central vault takes a value only with its fingerprint: without one, the hub step makes a catalog entry
        // that can never hold the value (6 November 2026: an App key in PEM form, at every round of the door's sync).
        let prints = try SecretFingerprint.of(item, salts: salts)
        guard SecretFingerprint.areValid(prints) else {
            throw Stop(String(l10n: "The central vault takes a value only with a fingerprint, and this one has none: it has fewer than 8 characters or holds white space. Nothing was sent."))
        }
        _ = try await SecretsClient().add(hub: hub, database: database, client: client, login: reference, title: secret.title,
                                          kind: .apiKey, variable: secret.variable, fingerprints: prints)
        _ = try await VaultClient().intake(hub: hub, database: database, client: client, login: reference, ciphertext: sealed)
        try await GrantSigning.grant(.use, login: reference, agent: DoorAccess.holder, store: store, hub: hub, database: database)
        _ = try await SecretsClient().grant(hub: hub, database: database, client: client, login: reference,
                                            agent: DoorAccess.holder, grant: .use)
        return reference
    }

    /// **A GitHub App's key to the door, at its own place in the catalog** (`GitHubAppKey.place`): the entry that holds
    /// this very key, when there is one, and else a new entry under a name that no key of the catalog has. So the
    /// successor of an App's key stands beside the old key until the hub takes that one out of the catalog and the
    /// door, after GitHub refuses it (`hub.py` `door_key_retire`), and a save that is tried again makes no second
    /// entry. Gives the secret's reference. reference: as for `put`.
    static func putGitHubApp(_ pem: String, owner: String, store: FleetStore, reference: String? = nil) async throws -> String {
        guard let database = store.state?.db else { throw Stop(String(l10n: "No current status of this hub. Nothing was sent.")) }
        let hub = store.hub, value = GitHubAppKey.vaultValue(pem)
        // The hub's answer always has the list, also an empty one: a read with none is no reading of it, and a save
        // that took it for an empty list asked for the plain name again.
        guard let catalog = try? await HubClient().team(hub: hub, database: database).logins else {
            throw Stop(String(l10n: "No current status of this hub. Nothing was sent."))
        }
        var secret = LoginSecret()
        secret.kind = .apiKey
        secret.env = GitHubAppKey.variable(owner: owner)
        secret.password = value
        if let problem = secret.problem { throw Stop(problem) }
        let item = try secret.value()
        // A hub from before the comparison (owner feature secret_compare) cannot tell; a hub that has it and does not
        // answer stops the save, so that no call that failed stands for "not this key".
        let compares = store.state?.ui_features?.contains("secret_compare") == true
        let place = try await GitHubAppKey.place(owner: owner, catalog: catalog, kept: reference) { held in
            guard compares else { return nil }
            // The fingerprints of this key with the salts of that entry: the hub says whether they are the entry's own.
            let prints = try SecretFingerprint.of(item, salts: try await HubClient().secretSalts(hub: hub, database: database, login: held))
            guard SecretFingerprint.areValid(prints) else { return nil }
            return try await HubClient().secretSame(hub: hub, database: database, login: held, fingerprints: prints)
        }
        switch place {
        case .held(let held, let variable): return try await put(value, variable: variable, store: store, reference: held)
        case .new(let variable): return try await put(value, variable: variable, store: store, reference: reference)
        }
    }
}
