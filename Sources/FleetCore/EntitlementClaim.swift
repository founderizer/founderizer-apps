import Foundation

/// The key of the old subscription, which today's website still hands over with its link (PRODUCT.md 4.5).
///
/// **Founderizer has no subscription and no account since 10 November 2026, and no screen asks for this key.** Our
/// release channel and our notification relay of today still answer only a fleet whose hub holds a token, so the one
/// trade stays, with nothing on the screen (`ClaimFromLink` in the app): the app sends the key and this fleet's own id
/// to the website, which answers with the signed token of 4.2, and the app gives that token to the hub. Our side
/// learns nothing about the fleet beyond the sixteen hex characters of its id. This file goes when the open channel
/// answers every fleet.
public enum ClaimKey {
    /// Enough of a key to send: 10 to 64 characters of letters, digits, spaces and hyphens. The website is the judge
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

    /// Where the key of the website's link waits until a fleet answers that can take it (`ClaimFromLink` in the app).
    public static let waiting = FleetKeychainItem(service: "com.founderizer.claim-key", label: "claim key")

    /// The key that the website's Open Founderizer button hands over, `founderizer://claim?key=FZ-…` (the onboarding of
    /// 4 November 2026). Any other link, and a key that `toSend` would not send, give nil.
    public static func fromLink(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "founderizer", url.host()?.lowercased() == "claim",
              let given = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "key" })?.value else { return nil }
        return toSend(given)
    }
}

/// The id of one fleet (PRODUCT.md 4.2): sixteen random hex characters, derived from no address, no name and no
/// account. It identifies a fleet to us and tells us nothing about its owner.
public enum FleetID {
    public static func isValid(_ id: String) -> Bool {
        id.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil
    }

    /// A new id, made here when the hub has none yet. The hub then takes the id the token names, which is how
    /// `store_entitlement` is written: the installer makes the id, the claim carries it, and the token brings it
    /// back. An id this app made is kept for that one hub, so a second attempt sends the same id and not a new one.
    public static func make() -> String {
        (0..<8).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }
}

/// What the website answers a claim with: the token, kept exactly as given, and its claims.
public struct ClaimedEntitlement: Decodable, Equatable, Sendable {
    public let token: String
    public let fleet: String
    public let plan: String?
    public let until: Double?
    public let machines: Int?
    public let agents: Int?

    /// The shape of 4.2 on the wire is the hub's to judge, so the app checks only what it must before it passes the
    /// token on: a token of a sane size, for the fleet it asked about.
    public func isFor(fleet id: String) -> Bool {
        fleet == id && FleetID.isValid(fleet) && (16...4000).contains(token.utf8.count) &&
            !token.contains(where: { $0.isWhitespace })
    }
}

/// Why a trade did not go. No screen says it: the trade is tried again by itself, a bounded number of times.
public enum ClaimError: Error, Equatable, Sendable {
    case notAKey
    case notOurSite
    /// The website's status.
    case refused(Int)
    case unreadable
}

/// The one call that trades a claim key for the signed entitlement (`POST /api/entitlement/claim`).
///
/// The address is the release channel the hub itself names, so a fleet pointed at another host needs no change
/// here. The call carries the key and the fleet id, and nothing else of the owner's: no email, no address, no name.
public struct ClaimCall: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    public func claim(key: String, fleet: String, channel: String) async throws -> ClaimedEntitlement {
        guard let key = ClaimKey.toSend(key) else { throw ClaimError.notAKey }
        guard FleetID.isValid(fleet) else { throw ClaimError.unreadable }
        guard let site = URL(string: channel), site.scheme == "https", site.host != nil else {
            throw ClaimError.notOurSite
        }
        var request = URLRequest(url: site.appendingPathComponent("api/entitlement/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["claim_key": key, "fleet": fleet],
                                                      options: [.sortedKeys])
        let (data, answer) = try await session.data(for: request)
        guard let http = answer as? HTTPURLResponse, data.count <= 65_536 else { throw ClaimError.unreadable }
        guard http.statusCode == 200 else { throw ClaimError.refused(http.statusCode) }
        guard let claimed = try? JSONDecoder().decode(ClaimedEntitlement.self, from: data),
              claimed.isFor(fleet: fleet) else { throw ClaimError.unreadable }
        return claimed
    }
}
