import Foundation

/// **The services whose key the guide's setup asks for, with the three things that the model never gives** (spec
/// section 3.4, `ask_secret`, and its section 2, row 10): the page where the owner makes the key, the address that the
/// key is used at, and the variable's name. The secret's form saves the address with the key, and the hub sends a key
/// only to its saved address. So an address from the model would become the place where the vault sends the key: the
/// model names the service only, and this table gives the rest.
///
/// A service that the table does not have is not asked for in the setup: the hand-over names it, and its agent asks for
/// it later with its own request, which the owner answers on Needs you.
///
/// **Each entry was read on the service's own pages on 14 November 2026**, and its comment names them. The first list
/// is short: payment services for which one key is the access (the manager's job "Watch the money"). Paddle is not in
/// it: its own pages give the place of its keys as a path in its app, and no address of that page.
public enum GuideServices {
    public struct Service: Codable, Equatable, Sendable {
        /// The service's name, as the owner types it and as the step's title shows it.
        public let name: String
        /// The page where the owner makes the key: the step's one link. Its host is the step's first line.
        public let makePage: String
        /// The address that the key is used at: the form saves it with the key.
        public let address: String
        /// The variable's name of the key in the fleet's list.
        public let variable: String

        /// The host of the page where the owner makes the key ("dashboard.stripe.com").
        public var makeHost: String { URLComponents(string: makePage)?.host ?? "" }
    }

    public static let all = [
        // docs.stripe.com/keys (the keys are at dashboard.stripe.com/apikeys) and docs.stripe.com/api/authentication
        // (the API is at https://api.stripe.com). Stripe has restricted keys, which do only what the job needs.
        Service(name: "Stripe", makePage: "https://dashboard.stripe.com/apikeys", address: "https://api.stripe.com",
                variable: "STRIPE_API_KEY"),
        // docs.lemonsqueezy.com/guides/developer-guide/getting-started: the keys are at
        // app.lemonsqueezy.com/settings/api, and the API is at https://api.lemonsqueezy.com/v1/.
        Service(name: "Lemon Squeezy", makePage: "https://app.lemonsqueezy.com/settings/api",
                address: "https://api.lemonsqueezy.com", variable: "LEMONSQUEEZY_API_KEY"),
        // docs.mollie.com/reference/authentication (the keys are at
        // my.mollie.com/dashboard/developers/api-access-tokens) and docs.mollie.com/reference/create-payment (the API
        // is at https://api.mollie.com/v2).
        Service(name: "Mollie", makePage: "https://my.mollie.com/dashboard/developers/api-access-tokens",
                address: "https://api.mollie.com", variable: "MOLLIE_API_KEY"),
    ]

    /// The service of a name, with no difference of case or of spaces ("lemon squeezy", "LemonSqueezy").
    public static func find(_ name: String) -> Service? {
        func bare(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
        return all.first { bare($0.name) == bare(name) }
    }
}
