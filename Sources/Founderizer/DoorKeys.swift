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
        guard let database = store.state?.db else { throw Stop("No current status of this hub. Nothing was sent.") }
        let hub = store.hub, client = store.installation
        guard let reading = try await VaultClient().reading(hub: hub, database: database), let fleet = reading.fleetID,
              let recipient = reading.trusted(pin: CentralVaultPins.recipient(hub: hub, fleet: fleet)) else {
            throw Stop("The central vault does not answer with the key this Mac pinned. Nothing was sent.")
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
            throw Stop("The central vault takes a value only with a fingerprint, and this one has none: it has fewer than "
                       + "8 characters or holds white space. Nothing was sent.")
        }
        _ = try await SecretsClient().add(hub: hub, database: database, client: client, login: reference, title: secret.title,
                                          kind: .apiKey, variable: secret.variable, fingerprints: prints)
        _ = try await VaultClient().intake(hub: hub, database: database, client: client, login: reference, ciphertext: sealed)
        try await GrantSigning.grant(.use, login: reference, agent: DoorAccess.holder, store: store, hub: hub, database: database)
        _ = try await SecretsClient().grant(hub: hub, database: database, client: client, login: reference,
                                            agent: DoorAccess.holder, grant: .use)
        return reference
    }
}
