import FleetCore
import Foundation
import os
import Security

/// **Why this Mac's writer key does not work, for sure**: the causes after which a store card sends step `no_writer`,
/// so that the hub asks the owner for a new key first. A network fault is none of them.
public enum StoreWriterCause: Equatable, Sendable {
    /// Bitwarden's `invalid_client` at the sign-in, or a 401 of a route directly after a fresh sign-in.
    case tokenRefused
    /// A 404 of `GET projects/<project>` directly after a good sign-in: the token lost the project.
    case lostProject
    /// `write: false` for the project.
    case readOnly
    /// The keychain's answer that the item is not there (`errSecItemNotFound`): a new Mac has no other way out.
    case noKey
    /// Bitwarden answered the sign-in, and the token cannot write this store: its key does not open the payload, its
    /// JWT names another organization or none, or the kept text is no token. None of them comes from the network.
    case tokenUnusable
}

/// **The writer check of a store card**, when the card opens and after a refused create.
public enum StoreWriterCheck: Equatable, Sendable {
    case works
    case definite(StoreWriterCause)
    /// No answer, a timeout, a 5xx, a locked keychain or any other status: the card says that Bitwarden does not
    /// answer, with Try again, and sends nothing.
    case noAnswer
}

/// The way of the writer key, the owner's choice (section 5 of the design).
public enum StoreWriterWay: Sendable {
    /// The token writes the project that the cluster's store reads.
    case wholeProject
    /// The token writes one project of its own, and not the store's.
    case ownProject
}

/// **The check of a writer card's key before anything is kept**, in the words of the form's message line.
public enum StoreWriterCard: Equatable, Sendable {
    /// The key works; `writeProject` is the project that it writes (the store's own in Whole project).
    case works(writeProject: String)
    /// "This key does not open Bitwarden Secrets Manager. Nothing was kept."
    case notSecretsManager
    /// "This key is of another Bitwarden organization than the cluster's store. Nothing was kept."
    case otherOrganization
    /// Whole project: "This key cannot write the project of the cluster's store. …"
    case cannotWrite
    /// Own project: "This key must write one project of its own, and not the project of the cluster's store. …"
    case notOwnProject
    /// "Bitwarden did not answer. Nothing was kept."
    case noAnswer
}

/// **The writer key on this Mac**: the Bitwarden token with which the Mac writes one project, in this Mac's keychain
/// only (this device, not synchronized). The hub, the central vault and the list of secrets never get it.
public enum StoreWriter {
    /// The keychain item of the writer keys (`StoreWriterKeychain`).
    public static var item: FleetKeychainItem { StoreWriterKeychain.item }

    /// The writer check of a store card: the keychain's key for `account`, a fresh sign-in and `canWrite(project)`.
    /// It gives the store too, signed in, when the key works.
    public static func check(account: String, region: String, organization: String, project: String,
                             keychain: @Sendable (String) -> Result<Data, FleetKeychainItem.Failure> = { StoreWriter.item.lookup(fleet: $0) },
                             store make: @Sendable (String, String, String) -> (any StoreProvider)? = {
                                 BitwardenStore(token: $0, region: $1, organization: $2)
                             }) async -> (check: StoreWriterCheck, store: (any StoreProvider)?) {
        let data: Data
        switch keychain(account) {
        case .success(let found): data = found
        case .failure(let failure):
            return (failure.status == errSecItemNotFound ? .definite(.noKey) : .noAnswer, nil)
        }
        guard let token = String(data: data, encoding: .utf8), let store = make(token, region, organization) else {
            return (.definite(.tokenUnusable), nil)
        }
        let checked = await check(store, project: project)
        return (checked, checked == .works ? store : nil)
    }

    /// The writer check with a store at hand: a fresh sign-in, then `canWrite(project)`. So a 404 or a 401 of the
    /// project's route comes directly after a good sign-in, and counts.
    public static func check(_ store: any StoreProvider, project: String) async -> StoreWriterCheck {
        switch await store.signIn() {
        case .ok: break
        case .failed(.tokenRefused): return .definite(.tokenRefused)
        case .failed(.otherOrganization), .failed(.tokenUnusable): return .definite(.tokenUnusable)
        case .failed: return .noAnswer
        }
        switch await store.canWrite(project: project) {
        case .writes: return .works
        case .readOnly: return .definite(.readOnly)
        case .noAccess: return .definite(.lostProject)
        case .failed(.tokenRefused): return .definite(.tokenRefused)
        case .failed: return .noAnswer
        }
    }

    /// **The check of a writer card**: a fresh sign-in, then, Whole project, `canWrite(storeProject)`; Own project,
    /// `writable()` must give exactly one project, and not `storeProject`. That one is the write project.
    public static func card(_ store: any StoreProvider, way: StoreWriterWay, storeProject: String) async -> StoreWriterCard {
        switch await store.signIn() {
        case .ok: break
        case .failed(.otherOrganization): return .otherOrganization
        case .failed(.tokenRefused), .failed(.tokenUnusable), .failed(.refused): return .notSecretsManager
        case .failed: return .noAnswer
        }
        switch way {
        case .wholeProject:
            switch await store.canWrite(project: storeProject) {
            case .writes: return .works(writeProject: storeProject)
            case .readOnly, .noAccess, .failed(.refused): return .cannotWrite
            case .failed(.tokenRefused): return .notSecretsManager
            case .failed: return .noAnswer
            }
        case .ownProject:
            switch await store.writable() {
            case .projects(let ids): return ids.count == 1 && ids[0] != storeProject ? .works(writeProject: ids[0]) : .notOwnProject
            case .noAccess, .failed(.refused): return .notOwnProject
            case .failed(.tokenRefused): return .notSecretsManager
            case .failed: return .noAnswer
            }
        }
    }
}

/// **When a store card sends step `no_writer`**: only from a build signed with the Developer ID, only after a definite
/// cause, and one time for each card in this run of the app. So a network fault never removes the writer row and
/// closes the owner's card, and a card that sent it once does not send it again.
public final class NoWriterLedger: Sendable {
    public static let shared = NoWriterLedger()

    private let developerID: Bool
    private let sent = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    public init(developerID: Bool = FleetKeychainItem.developerIDSigned) { self.developerID = developerID }

    /// True, one time, when the card of `need` sends `no_writer` after `check`; it counts that send.
    public func sends(need: Int, after check: StoreWriterCheck) -> Bool {
        guard developerID, case .definite = check else { return false }
        return sent.withLock { $0.insert(need).inserted }
    }
}
