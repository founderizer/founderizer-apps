import FleetCore
import Foundation

/// **The owner's signature of each grant** (owner feature `signed_grants`, DevOps plan V4). The central vault seals a
/// secret for a server only when the owner signed a grant of it to an agent there, or signed it into the grantable
/// pool, so a hub that is broken into cannot send a secret to a server the owner did not give it to. This Mac holds the
/// owner key, so each control that gives a secret or takes it back also signs that change and sends it through the
/// hub, which passes it on as it is (`POST /ui/vault/grant`).
///
/// The order keeps the vault the narrower of the two: a grant is signed before the hub's grant, and its end after
/// it, so at no moment does the vault seal a secret that `team.json` does not give. A hub that does not offer
/// `signed_grants` takes nothing here, and its controls work as before.
@MainActor
enum GrantSigning {
    static let feature = "signed_grants"

    /// A stop, in the owner's words, shown where the control shows its other problems.
    struct Stop: LocalizedError {
        let errorDescription: String?
        init(_ says: String) { errorDescription = says }
    }

    static func offered(_ store: FleetStore) -> Bool { store.state?.ui_features?.contains(feature) == true }

    /// The signed statement of one agent's grant of one secret: `grant` with the agent's machine for a use or a read,
    /// `ungrant` for nil. The machine is the one the hub's team names for the agent now.
    static func grant(_ level: SecretGrant?, login: String, agent: String, store: FleetStore, hub: URL, database: String) async throws {
        guard offered(store) else { return }
        let (fleet, key) = try await owner(hub: hub, database: database)
        var machine: String?
        if level != nil {
            // The door is no agent of the team: its grant names its own pinned key, and never a machine the hub names.
            if agent == DoorAccess.holder {
                machine = DoorAccess.holder
            } else {
                let team = try await HubClient().team(hub: hub, database: database)
                guard let placed = team.members.first(where: { $0.agent == agent })?.placement?.machine, CentralVault.isMachine(placed) else {
                    throw Stop(String(l10n: "The hub names no server for \(agent.agentLabel), so Founderizer signed nothing."))
                }
                machine = placed
            }
        }
        let made = try signed(grantOn: machine, login: login, agent: agent, fleet: fleet, key: key)
        _ = try await VaultClient().grant(hub: hub, database: database, client: store.installation, statement: made.statement,
                                          signature: made.signature)
    }

    /// **The statement of one agent's grant of one secret, and its signature, with the key that the caller gives**:
    /// `grant` for a machine, `ungrant` for nil, at this Mac's next time for the fleet (`GrantClock.next`). It
    /// reads no key and sends nothing: `grant` above gives it the key of its one read (`owner`), and `send` below
    /// the key that it read itself.
    private static func signed(grantOn machine: String?, login: String, agent: String, fleet: String,
                               key: any OwnerKey) throws -> (statement: String, signature: String) {
        let at = GrantClock.next(fleet: fleet)
        let statement = machine.map { OwnerStatement.grant(fleet: fleet, login: login, agent: agent, machine: $0, at: at) }
            ?? OwnerStatement.ungrant(fleet: fleet, login: login, agent: agent, at: at)
        return (statement, try key.sign(statement))
    }

    /// **The error of `send` that says "not signed, and nothing was sent"**: the owner key of this Mac could not
    /// be read, or it made no signature. It has no words: no view gets it, only the link tool `grant_secret`
    /// (`LinkTools.grantDesk`), which has its own.
    struct NotSigned: Error {}

    /// **One statement of one agent's grant of one secret, made, signed with the owner key of this Mac and sent**,
    /// for the link tool `grant_secret` (`LinkTools.grantDesk`): `grant` for the machine that the caller gives,
    /// `ungrant` for nil, under the fleet id that the caller gives. It does not look at the store's features and
    /// it does not read the team: the tool must know that a statement was signed and sent, for the machine of its
    /// own one read.
    ///
    /// **Two ends, which the tool must tell apart.** `NotSigned`: the key could not be read (this Mac holds none,
    /// the Mac is locked, or macOS did not let the app read it), or the key made no signature; both come before
    /// anything is sent. Every other error is the send's own (`VaultClient.grant`), after which the outcome can
    /// be unknown.
    static func send(grantOn machine: String?, login: String, agent: String, fleet: String, client: String, hub: URL,
                     database: String) async throws {
        let made: (statement: String, signature: String)
        do {
            guard let key = OwnerKeychain.key(fleet: fleet) else { throw NotSigned() }
            made = try signed(grantOn: machine, login: login, agent: agent, fleet: fleet, key: key)
        } catch {
            throw NotSigned()
        }
        _ = try await VaultClient().grant(hub: hub, database: database, client: client, statement: made.statement,
                                          signature: made.signature)
    }

    /// The signed statement of one secret's place in the grantable pool: `pool` while the fleet manager may give it,
    /// `unpool` when only the owner gives it.
    static func pool(_ inPool: Bool, login: String, store: FleetStore, hub: URL, database: String) async throws {
        guard offered(store) else { return }
        let (fleet, key) = try await owner(hub: hub, database: database)
        let at = GrantClock.next(fleet: fleet)
        let statement = inPool ? OwnerStatement.pool(fleet: fleet, login: login, at: at)
                               : OwnerStatement.unpool(fleet: fleet, login: login, at: at)
        _ = try await VaultClient().grant(hub: hub, database: database, client: store.installation, statement: statement,
                                          signature: key.sign(statement))
    }

    /// The owner's signed replace of one secret's value (owner feature `secret_replace`): the statement about this
    /// very sealed copy and its signature, for the intake that carries the copy. The central vault puts a new value
    /// under a reference that it holds only with them, so a Mac that cannot sign sends no replace.
    static func replace(login: String, sealed: String, hub: URL, database: String) async throws -> (statement: String, signature: String) {
        let (fleet, key) = try await owner(hub: hub, database: database)
        let statement = OwnerStatement.replace(fleet: fleet, login: login, sha256: OwnerStatement.checksum(sealed),
                                               at: GrantClock.next(fleet: fleet))
        return (statement, try key.sign(statement))
    }

    /// This fleet's id, as the hub names it, and the owner key this Mac holds for it.
    private static func owner(hub: URL, database: String) async throws -> (String, any OwnerKey) {
        guard let fleet = try await VaultClient().reading(hub: hub, database: database)?.fleetID else {
            throw Stop(String(l10n: "The hub did not say which fleet this is, so Founderizer signed nothing."))
        }
        guard let key = OwnerKeychain.key(fleet: fleet) else {
            throw Stop(String(l10n: "This Mac holds no owner key for this fleet, so it cannot sign the change."))
        }
        return (fleet, key)
    }
}

/// **The read grant of an agent on a key** (the AI providers build, spec 3.1 step 4): the owner's signed grant first,
/// then the hub's, as `GrantSigning` says, so that the vault never seals a key that team.json does not give. A
/// signature that fails stops it, and the hub's grant is not written (review M4). The add calls it after the agent
/// exists, and the agent's setup page calls it again under the hood when its check found no key.
@MainActor
enum ModelAccountGrant {
    static func give(_ secret: String, to agent: String, store: FleetStore, hub: URL, database: String) async throws {
        try await GrantSigning.grant(.read, login: secret, agent: agent, store: store, hub: hub, database: database)
        _ = try await SecretsClient().grant(hub: hub, database: database, client: store.installation, login: secret,
                                           agent: agent, grant: .read)
    }
}
