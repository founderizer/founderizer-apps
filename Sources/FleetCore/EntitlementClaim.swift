import Foundation

/// **The key of a purchase of Founderizer for Teams** (teams-design-1-shop-and-licence.md, 3.11), which the platform's
/// thanks page and account page hand over with one link, `founderizer://claim?key=FZ-…` (`fromLink`). The key works
/// one time, for 30 days.
///
/// The app keeps the key in this Mac's keychain until the fleet's hub can take it, and gives it to the hub
/// (`POST /ui/teams/claim`, `HubClient.claimTeams`, through `ClaimGiving`). The hub trades it at the platform with its
/// own fleet id and keeps the licence. The app asks the platform nothing and reads no token: to pass the key to its
/// hub is the one thing that it does for the licence (the rule for the apps, J4). No screen shows the key or the trade.
public enum ClaimKey {
    /// Enough of a key to send: 10 to 64 characters of letters, digits, spaces and hyphens. The platform is the judge
    /// of a key.
    public static func isPlausible(_ given: String) -> Bool {
        let key = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.range(of: "^[A-Za-z0-9][A-Za-z0-9 -]{8,62}[A-Za-z0-9]$", options: .regularExpression) != nil
    }

    /// The key as it is sent: the paste, with the spaces at its ends taken off and nothing else changed.
    public static func toSend(_ given: String) -> String? {
        let key = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlausible(key) ? key : nil
    }

    /// Where the key of the link waits until the fleet's hub takes it (`ClaimFromLink` in the app).
    public static let waiting = FleetKeychainItem(service: "com.founderizer.claim-key", label: "claim key")

    /// The key that the platform's Open Founderizer button hands over, `founderizer://claim?key=FZ-…`. Any other link,
    /// and a key that `toSend` would not send, give nil.
    public static func fromLink(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "founderizer", url.host()?.lowercased() == "claim",
              let given = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "key" })?.value else { return nil }
        return toSend(given)
    }

    /// The hub's feature of `POST /ui/teams/claim`.
    public static let feature = "teams_claim"

    /// **Whether the key goes to the hub of this reading now**: only to a hub that lists `teams_claim`, and only while
    /// this fleet's Teams is not on. A hub of an older release has no such route, so the key waits there for the hub's
    /// update, with no try counted, and is not lost. A fleet whose Teams is on gets no second key: a key that the owner
    /// opened for the next fleet would be spent on this one, which holds its licence already. A fleet whose licence
    /// ended (`on` false) takes a new key.
    public static func goesTo(_ state: HubState) -> Bool {
        state.ui_features?.contains(feature) == true && state.teams?.on != true
    }
}

/// The id of one fleet (PRODUCT.md 4.2): sixteen hex characters, which the hub makes and keeps, derived from no
/// address, no name and no account. It identifies a fleet to us and tells us nothing about its owner.
public enum FleetID {
    public static func isValid(_ id: String) -> Bool {
        id.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil
    }
}

/// **What the hub holds of this fleet's licence of Founderizer for Teams**: the field `teams` of `GET /ui/state`
/// (teams-design-1-shop-and-licence.md, 3.12). A hub sends it only while it holds a token that our key signed with plan
/// `teams`, so a fleet with no licence, and a hub of an older release, have none. It says nothing of a Teams part: a
/// part's own name in `ui_features` says that.
public struct TeamsLicence: Decodable, Equatable, Sendable {
    /// Teams is on: from the moment that the hub kept the token until the platform's signed word that its licence ended.
    public let on: Bool
    /// The end of the paid period that the token names, in epoch seconds.
    public let until: Double?
    /// What the platform last said: the subscription renews at `until`. nil when it is not known.
    public let renews: Bool?
    /// The time of the signed word that the licence ended, or nil.
    public let ended: Double?
}

/// The hub's answer to a claim (`POST /ui/teams/claim`): the receipt of an owner command, with the field `teams` as the
/// hub holds it after the trade.
public struct TeamsClaimReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let replayed: Bool?
    public let teams: TeamsLicence?
}

/// **A refusal of the hub's claim route** (`HubClient.claimTeams`): the hub's refusal, and the platform's code when the
/// platform refused the key itself, else nil.
public struct TeamsClaimRefused: Error, Sendable {
    public let refusal: HubRefusal
    public let keyCode: String?

    /// The platform's codes after which the key is never taken (UI-API.md 1.300), `gone` among them: the closed
    /// shop's own answer that it takes no key, which would else send the key each ten minutes for ever. `too_many` and
    /// `unavailable` are not (the coordinator's D65).
    public static let keyCodes: Set<String> = ["unknown_key", "expired_key", "not_live", "test_shop", "used_key",
                                               "fleet_taken", "incomplete", "unreadable", "gone"]

    public init(refusal: HubRefusal, keyCode: String?) {
        self.refusal = refusal
        self.keyCode = keyCode
    }

    /// The key's code of a 4xx answer of the claim route (`claim_error`), or nil for any other answer.
    static func keyCode(status: Int, body: Data) -> String? {
        guard (400..<500).contains(status),
              let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = sent["claim_error"] as? String, keyCodes.contains(code) else { return nil }
        return code
    }
}

/// **The turn that gives a waiting key to the fleet's hub**, once after each reading of the fleet (`ClaimFromLink` in
/// the app holds one, with this Mac's keychain as its place).
///
/// The key goes only to a hub that takes it now (`ClaimKey.goesTo`). While the hub does not take it, the key waits and
/// no try is counted. A give that the platform refused for the key itself (`TeamsClaimRefused.keyCode`) is tried again
/// ten minutes later, six times at most, and then the key goes (the rule of what sets itself up: bounded, and never in
/// a loop). Any other failure (a 502, a 503, no answer, a refusal of the hub's own) counts nothing, and the key waits
/// for the next try ten minutes later: an outage changes nothing and must not lose the key (the coordinator's D65).
/// Once the hub took the key, the key goes from this Mac: the platform takes a key one time, and the hub keeps the
/// licence.
@MainActor
public final class ClaimGiving {
    /// Where the key waits: this Mac's keychain in the app (`ClaimKey.waiting`), a place of its own in a test.
    public struct Place: Sendable {
        let isHeld: @Sendable () -> Bool
        let read: @Sendable () -> String?
        let remove: @Sendable () -> Void

        /// `isHeld` reads no value, so that a look each minute costs no prompt; `read` runs only when a key is held.
        public init(isHeld: @escaping @Sendable () -> Bool, read: @escaping @Sendable () -> String?,
                    remove: @escaping @Sendable () -> Void) {
            self.isHeld = isHeld
            self.read = read
            self.remove = remove
        }
    }

    public static let spacing: TimeInterval = 600, tries = 6
    /// While no key waits, the place is looked at once a minute and not at each reading of the fleet.
    public static let idle: TimeInterval = 60

    private let place: Place
    private let hubClient: HubClient
    /// The gives of the waiting key that did not go.
    public private(set) var tried = 0
    private var next = Date.distantPast, running = false

    public init(place: Place, hubClient: HubClient = HubClient()) {
        self.place = place
        self.hubClient = hubClient
    }

    /// A new key came with a link: its count starts again, and the next look gives it.
    public func fresh() {
        tried = 0
        next = .distantPast
    }

    /// One look after a reading of the fleet: `state` is that reading, of the hub at `hub`, and `canWrite` says that
    /// the app writes to that hub now. The give runs in the task that this returns; nil when no key went.
    @discardableResult
    public func look(state: HubState?, hub: URL, client: String, canWrite: Bool) -> Task<Void, Never>? {
        guard !running, canWrite, let state, ClaimKey.goesTo(state), Date() >= next else { return nil }
        guard place.isHeld(), let key = place.read() else {
            next = Date().addingTimeInterval(Self.idle)
            return nil
        }
        running = true
        let database = state.db
        return Task { [self] in
            defer { running = false }
            var took = false, refused = false
            do {
                _ = try await hubClient.claimTeams(key: key, hub: hub, database: database, client: client)
                took = true
            } catch let refusal as TeamsClaimRefused {
                refused = refusal.keyCode != nil
            } catch {}
            // A new link while this key was on its way: the new key waits, with a count of its own (`fresh`).
            guard place.read() == key else { return }
            if took {
                place.remove()
                return
            }
            next = Date().addingTimeInterval(Self.spacing)
            guard refused else { return }
            tried += 1
            if tried >= Self.tries { place.remove() }
        }
    }
}
