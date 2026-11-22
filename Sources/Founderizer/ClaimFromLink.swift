import Foundation
import FleetCore

/// **The key of the platform's Open Founderizer button** (`founderizer://claim?key=FZ-…`, `ClaimKey.fromLink`): the key
/// of a purchase of Founderizer for Teams (teams-design-1-shop-and-licence.md, 3.11).
///
/// The key waits in this Mac's keychain until the fleet's hub takes it (`ClaimGiving`): a hub that lists
/// `teams_claim`, of a fleet whose Teams is not on. The hub trades it at the platform and keeps the licence; this app
/// asks the platform nothing. No screen shows the key or the trade.
@MainActor
final class ClaimFromLink {
    static let item = ClaimKey.waiting
    static let account = "from-the-website"

    private let giving = ClaimGiving(place: ClaimFromLink.keychain(ClaimFromLink.item, account: ClaimFromLink.account))

    private static func keychain(_ item: FleetKeychainItem, account: String) -> ClaimGiving.Place {
        ClaimGiving.Place(isHeld: { item.isHeld(fleet: account) },
                          read: { item.read(fleet: account).flatMap { String(data: $0, encoding: .utf8) } },
                          remove: { item.remove(fleet: account) })
    }

    func take(_ url: URL, store: FleetStore) {
        guard let key = ClaimKey.fromLink(url) else { return }
        try? Self.item.keep(Data(key.utf8), fleet: Self.account)
        giving.fresh()
        tryNow(store: store)
    }

    /// Called after each reading of the fleet's state.
    func tryNow(store: FleetStore) {
        giving.look(state: store.state, hub: store.hub, client: store.installation, canWrite: store.canWrite)
    }
}
