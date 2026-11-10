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
        let statement: String
        if level != nil {
            // The door is no agent of the team: its grant names its own pinned key, and never a machine the hub names.
            let machine: String
            if agent == DoorAccess.holder {
                machine = DoorAccess.holder
            } else {
                let team = try await HubClient().team(hub: hub, database: database)
                guard let placed = team.members.first(where: { $0.agent == agent })?.placement?.machine, CentralVault.isMachine(placed) else {
                    throw Stop("The hub names no server for \(agent.agentLabel), so Founderizer signed nothing.")
                }
                machine = placed
            }
            statement = OwnerStatement.grant(fleet: fleet, login: login, agent: agent, machine: machine, at: GrantClock.next(fleet: fleet))
        } else {
            statement = OwnerStatement.ungrant(fleet: fleet, login: login, agent: agent, at: GrantClock.next(fleet: fleet))
        }
        _ = try await VaultClient().grant(hub: hub, database: database, client: store.installation, statement: statement,
                                          signature: key.sign(statement))
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

    /// This fleet's id, as the hub names it, and the owner key this Mac holds for it.
    private static func owner(hub: URL, database: String) async throws -> (String, any OwnerKey) {
        guard let fleet = try await VaultClient().reading(hub: hub, database: database)?.fleetID else {
            throw Stop("The hub did not say which fleet this is, so Founderizer signed nothing.")
        }
        guard let key = OwnerKeychain.key(fleet: fleet) else {
            throw Stop("This Mac holds no owner key for this fleet, so it cannot sign the change.")
        }
        return (fleet, key)
    }
}
