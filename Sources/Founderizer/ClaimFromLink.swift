import Foundation
import FleetCore

/// **The key that today's website still hands over with its Open Founderizer button** (`founderizer://claim?key=FZ-…`,
/// `ClaimKey.fromLink`; the onboarding of 4 November 2026).
///
/// Founderizer has no subscription and no account since 10 November 2026, and no screen of this app speaks of one.
/// Our release channel and our notification relay of today still answer only a fleet whose hub holds a token, so this
/// trade stays, with nothing on the screen, until the open channel answers every fleet. Then it goes, with
/// `EntitlementClaim.swift` and `HubClient.storeEntitlement`.
///
/// The key waits in this Mac's keychain until a fleet answers that holds no token yet, is traded once for that fleet's
/// token, which the hub keeps, and goes. A fleet that already holds a token is never given another by a link.
@MainActor
final class ClaimFromLink {
    static let item = ClaimKey.waiting
    static let account = "from-the-website"
    /// A trade that did not go is tried again ten minutes later, six times at most, and then the key goes (the rule of
    /// what sets itself up: bounded, and never in a loop). A fleet that has its token is asked again in ten minutes,
    /// so a key for the next fleet waits without a request every few seconds.
    static let spacing: TimeInterval = 600, tries = 6
    /// While no key waits, the keychain is looked at once a minute and not at each reading of the fleet.
    static let idle: TimeInterval = 60
    /// The ids that this Mac made for hubs that had none, by hub (`fleetID`).
    private static let fleetKey = "fleetIdsByHub"

    private var tried = 0, next = Date.distantPast, running = false

    func take(_ url: URL, store: FleetStore) {
        guard let key = ClaimKey.fromLink(url) else { return }
        try? Self.item.keep(Data(key.utf8), fleet: Self.account)
        tried = 0
        next = .distantPast
        tryNow(store: store)
    }

    /// Called after each reading of the fleet's state.
    func tryNow(store: FleetStore) {
        guard !running, Date() >= next, store.canWrite else { return }
        guard Self.item.isHeld(fleet: Self.account) else {
            next = Date().addingTimeInterval(Self.idle)
            return
        }
        running = true
        Task { [self] in
            defer { running = false }
            guard let data = Self.item.read(fleet: Self.account), let key = String(data: data, encoding: .utf8),
                  let database = store.state?.db else { return }
            let hub = store.hub
            guard let release = try? await HubClient().releases(hub: hub, database: database),
                  store.hub == hub, store.state?.db == database, !release.entitlement.have_token else {
                next = Date().addingTimeInterval(Self.spacing)
                return
            }
            if await trade(key: key, release: release, hub: hub, database: database, client: store.installation) {
                Self.item.remove(fleet: Self.account)
                return
            }
            tried += 1
            if tried >= Self.tries { Self.item.remove(fleet: Self.account) }
            next = Date().addingTimeInterval(Self.spacing)
        }
    }

    /// The trade (PRODUCT.md 4.5): the website gives this fleet's signed token for the key, and the hub keeps that
    /// token. The app holds the token for the length of this one call and keeps nothing of it. True when the hub took it.
    private func trade(key: String, release: ReleaseState, hub: URL, database: String, client: String) async -> Bool {
        let fleet = release.entitlement.fleet ?? fleetID(hub: hub)
        guard let answer = try? await ClaimCall().claim(key: key, fleet: fleet, channel: release.channel) else { return false }
        return (try? await HubClient().storeEntitlement(token: answer.token, hub: hub, database: database,
                                                         client: client)) != nil
    }

    /// This fleet's own id (PRODUCT.md 4.2). The hub's id is used whenever it has one; otherwise this Mac makes one and
    /// keeps it for that hub, so a second attempt carries the same id and not a new one. The hub then takes the id from
    /// the token it is given.
    private func fleetID(hub: URL) -> String {
        var all = (UserDefaults.standard.dictionary(forKey: Self.fleetKey) as? [String: String]) ?? [:]
        if let kept = all[hub.absoluteString], FleetID.isValid(kept) { return kept }
        let made = FleetID.make()
        all[hub.absoluteString] = made
        UserDefaults.standard.set(all, forKey: Self.fleetKey)
        return made
    }
}
