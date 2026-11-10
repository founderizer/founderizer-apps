import Foundation

/// What to tell the owner when this Mac cannot reach their hub, and what they can do about it.
///
/// A hub is their own machine on their own private network, so every failure here has an everyday cause: the
/// machine is asleep, this Mac is off the network, the address is wrong, or the hub serves somebody else's pages.
/// None of that is said by `URLError`'s own words, and a line like "the resource could not be loaded because the
/// App Transport Security policy requires the use of a secure connection" should never reach a person.
public struct HubReach: Equatable, Sendable {
    /// The one line that says what happened.
    public let says: String
    /// The one thing to do about it, or nil when there is nothing to do but wait.
    public let next: String?

    public init(says: String, next: String? = nil) {
        self.says = says; self.next = next
    }

    /// The owner's words for one failed read of a hub.
    public static func words(_ error: Error, hub: URL?) -> HubReach {
        let at = hub.map { " at \(address(of: $0))" } ?? ""
        if let refusal = error as? HubError {
            switch refusal {
            case .invalidAddress:
                return HubReach(says: "That is not a hub address.",
                                next: "An address looks like http://100.84.1.2:8765 — the private address of your "
                                    + "hub, and its port.")
            case .refusal(let status, _) where status == 403:
                // Never the hub's own words in brackets (fix round 3, item 50): "(owner only)" ended this line.
                return HubReach(says: "Your hub answered\(at), and it does not serve its pages to this Mac.",
                                next: "A hub serves the owner's own address only. Claim it from this Mac, or add "
                                    + "this Mac to the same private network.")
            case .refusal(let status, _) where status == 404:
                return HubReach(says: "Something answered\(at), but it is not a Founderizer hub.",
                                next: "Check the address and the port.")
            case .refusal(_, let message):
                // No status code in a line of his (review B8, fix round 2): "(503)" said nothing to him.
                return HubReach(says: "Your hub refused this read.", next: message)
            case .invalidResponse:
                return HubReach(says: "Your hub answered something this app could not read.",
                                next: "It may run an older Founderizer. Update it from Updates on its own server.")
            case .unavailable:
                // The address is on System status, where he can change it: an error line says what failed, in a
                // few plain words, and no host or port (the owner's "avoid as much text as possible").
                return HubReach(says: "Your hub did not answer.", next: nil)
            }
        }
        let reason = error as? URLError
        switch reason?.code {
        case .some(.appTransportSecurityRequiresSecureConnection):
            return HubReach(says: "This Mac refused to open a plain connection to your hub\(at).",
                            next: "This is a setting of this app, not of your hub. Tell us, and we will put it right.")
        case .some(.cannotFindHost), .some(.dnsLookupFailed):
            return HubReach(says: "This Mac cannot find your hub\(at).",
                            next: "Check the address, and that this Mac is on the same private network.")
        case .some(.cannotConnectToHost), .some(.networkConnectionLost):
            return HubReach(says: "Your hub did not answer.", next: "Check that its server is on.")
        case .some(.notConnectedToInternet):
            return HubReach(says: "This Mac has no network.", next: "Connect it, and this app reads again by itself.")
        case .some(.timedOut):
            return HubReach(says: "Your hub took too long to answer\(at).",
                            next: "It may be busy or asleep. This app reads again by itself.")
        case .some(.secureConnectionFailed), .some(.serverCertificateUntrusted):
            return HubReach(says: "The connection to your hub could not be secured\(at).",
                            next: "Check the address: a hub on your own private network is plain http.")
        default:
            return HubReach(says: "This Mac could not read your hub\(at).",
                            next: "Check that the server is on, and that this Mac is on the same private network.")
        }
    }

    /// **Which failed reach of a hub the first run tries again by itself** (review A4, fix round 2): one the hub or the
    /// connection refused at once, three times more, two seconds apart. One that timed out already waited — 30 seconds
    /// for a claim, 10 for a read — and is not tried again: four of them kept "Checking your fleet" up for 2 min 16 s.
    public static let triesAgain = 3
    public static let pause: Duration = .seconds(2)

    /// True for a failure worth another try two seconds later: a connection refused, lost or not made, or a hub that is
    /// starting (5xx). Not a time-out, a cancel, or an answer that says what it will say again.
    public static func worthAgain(_ error: Error) -> Bool {
        switch error {
        case let reason as URLError: return reason.code != .timedOut && reason.code != .cancelled
        case HubError.refusal(let status, _): return status >= 500
        case HubError.unavailable: return true
        default: return false
        }
    }

    /// The two lines as one, for a place that has room for one.
    public var line: String { [says, next].compactMap { $0 }.joined(separator: " ") }

    /// How the words name a hub: its host and its port.
    static func address(of hub: URL) -> String {
        hub.host.map { host in hub.port.map { "\(host):\($0)" } ?? host } ?? hub.absoluteString
    }

    /// **The same line without " at host:port"** (T-18, fix round 2): on the first run's claim and address steps the
    /// address is the one he just pasted, and saying it again only made the line longer.
    public static func withoutAddress(_ line: String, hub: URL) -> String {
        line.replacingOccurrences(of: " at \(address(of: hub))", with: "")
    }

    /// **One short break says nothing** (the owner, 27 October 2026: "show the connection notice only after several
    /// failed reads in a row, and never for one short break"). A Mac that wakes up and a hub that restarts for its
    /// update are back before the third read in a row fails; the app reads every three seconds, so a hub that stays
    /// away is said within about six, before the reading counts as old. A hub that never answered is said at once.
    public static let failedReadsBeforeNotice = 3

    /// The failed reads in a row so far say it to the owner now.
    public static func tells(failedReads: Int, answeredBefore: Bool) -> Bool {
        failedReads > 0 && (!answeredBefore || failedReads >= failedReadsBeforeNotice)
    }
}
