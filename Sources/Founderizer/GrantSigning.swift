import FleetCore
import Foundation

/// **The owner's signature of each grant** (owner feature `signed_grants`, DevOps plan V4). The central vault seals a
/// secret for a server only when the owner signed a grant of it to an agent there, or signed it into the grantable
/// pool, and only to a server whose key the owner pinned. The server of a grant is the one that the hub names for the
/// agent at the moment of the Give: a hub that is broken into can name another machine there, and the vault then seals
/// the secret to it only while the owner pinned its key, also with a pin that he signs later (the vault manager's
/// choice C50). This Mac holds the owner key, so each control that gives a secret or takes it back also signs that
/// change and sends it through the hub, which passes it on as it is (`POST /ui/vault/grant`).
///
/// **The clock.** A give, a `pool` and a replace sign nothing while this Mac's clock and the hub's are more than an
/// hour apart (`VaultPlan.clockProblem`, as for a pin): their time comes from `GrantClock`, which follows the last
/// time that this Mac signed, and the central vault keeps a statement only when it is newer than its record and not
/// from more than a day ahead. A take-back and an `unpool` do not wait for it: their hub step came first, and an end
/// only narrows. The check passes while the store has no clock of the hub. The link tools sign through `send`, whose
/// desks are the lane "Agent install"'s, and they do not check the clock yet.
///
/// The order keeps the vault the narrower of the two: a grant is signed before the hub's grant, and its end after
/// it, so the vault seals no secret that `team.json` does not give while each end reaches the vault. An end that the
/// vault refuses (from a clock 23 hours or more behind, from owner API 1.217 more than a day ahead, or older than a
/// record that the vault holds from ahead), or that is not sent, leaves the vault's grant until a later end reaches
/// it. A hub that does not offer `signed_grants` takes nothing here, and its controls work as before.
@MainActor
enum GrantSigning {
    static let feature = "signed_grants"

    /// A stop, in the owner's words, shown where the control shows its other problems.
    struct Stop: LocalizedError {
        let errorDescription: String?
        init(_ says: String) { errorDescription = says }
    }

    static func offered(_ store: FleetStore) -> Bool { store.state?.ui_features?.contains(feature) == true }

    /// **A stop while this Mac's clock and the hub's are more than an hour apart**, in the pin's own words
    /// (`VaultPlan.clockProblem`, against the hub's clock of the store's last state read): a statement's time follows
    /// this Mac's clock, so with a clock that is wrong it would be refused by the vault, or end a record too early.
    static func checkClock(_ store: FleetStore) throws {
        if let problem = VaultPlan.clockProblem(hubTime: store.state?.time, readAt: store.lastSuccess?.timeIntervalSince1970) {
            throw Stop(problem)
        }
    }

    /// The signed statement of one agent's grant of one secret: `grant` with the agent's machine for a use or a read,
    /// `ungrant` for nil. The machine is the one the hub's team names for the agent now, so a hub that is broken into
    /// can name another machine, which gets the secret only while the owner pinned its key (`OwnerStatement.grant`).
    /// A give waits for the clock (`checkClock`); a take-back does not: its hub step came first, and an end only
    /// narrows, so a stop here would leave the vault's grant that the list no longer has.
    static func grant(_ level: SecretGrant?, login: String, agent: String, store: FleetStore, hub: URL, database: String) async throws {
        guard offered(store) else { return }
        if level != nil { try checkClock(store) }
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
    /// be read, or it made no signature. It has no words: no view gets it, only the link tools `grant_secret`,
    /// `share_secret` and `answer_secret_request` (`LinkTools.grantDesk`, `LinkTools.shareDesk`,
    /// `LinkTools.answerDesk`), which have their own.
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

    /// **One statement of one secret's place in the grantable pool, made, signed with the owner key of this Mac and
    /// sent**, for the link tool `share_secret` (`LinkTools.shareDesk`): `pool` while the fleet manager may give it,
    /// `unpool` when only the owner gives it, under the fleet id that the caller gives. It does not look at the
    /// store's features: the tool must know that a statement was signed and sent.
    ///
    /// **Two ends, which the tool must tell apart**, as for `send(grantOn:...)`: `NotSigned` (the key could not be
    /// read, or it made no signature), before anything is sent; and every other error, the send's own
    /// (`VaultClient.grant`), after which the outcome can be unknown.
    static func send(pool inPool: Bool, login: String, fleet: String, client: String, hub: URL,
                     database: String) async throws {
        let made: (statement: String, signature: String)
        do {
            guard let key = OwnerKeychain.key(fleet: fleet) else { throw NotSigned() }
            made = try signed(pool: inPool, login: login, fleet: fleet, key: key)
        } catch {
            throw NotSigned()
        }
        _ = try await VaultClient().grant(hub: hub, database: database, client: client, statement: made.statement,
                                          signature: made.signature)
    }

    /// The signed statement of one secret's place in the grantable pool: `pool` while the fleet manager may give it,
    /// `unpool` when only the owner gives it. A `pool` waits for the clock; an `unpool` does not, as a take-back.
    static func pool(_ inPool: Bool, login: String, store: FleetStore, hub: URL, database: String) async throws {
        guard offered(store) else { return }
        if inPool { try checkClock(store) }
        let (fleet, key) = try await owner(hub: hub, database: database)
        let made = try signed(pool: inPool, login: login, fleet: fleet, key: key)
        _ = try await VaultClient().grant(hub: hub, database: database, client: store.installation,
                                          statement: made.statement, signature: made.signature)
    }

    /// **The statement of one secret's place in the grantable pool, and its signature, with the key that the caller
    /// gives**: `pool` or `unpool`, at this Mac's next time for the fleet (`GrantClock.next`). It reads no key and
    /// sends nothing: `pool` above gives it the key of its one read (`owner`), and `send(pool:...)` the key that it
    /// read itself.
    private static func signed(pool inPool: Bool, login: String, fleet: String,
                               key: any OwnerKey) throws -> (statement: String, signature: String) {
        let at = GrantClock.next(fleet: fleet)
        let statement = inPool ? OwnerStatement.pool(fleet: fleet, login: login, at: at)
                               : OwnerStatement.unpool(fleet: fleet, login: login, at: at)
        return (statement, try key.sign(statement))
    }

    /// The owner's signed replace of one secret's value (owner feature `secret_replace`): the statement about this
    /// very sealed copy and its signature, for the intake that carries the copy. The central vault puts a new value
    /// under a reference that it holds only with them, so a Mac that cannot sign sends no replace.
    static func replace(login: String, sealed: String, store: FleetStore, hub: URL,
                        database: String) async throws -> (statement: String, signature: String) {
        try checkClock(store)
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
