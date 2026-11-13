import Foundation

/// The connected apps of the hub's remote MCP address (UI-API.md, version 1.133; hub feature `connected_apps`): the
/// owner's own Claude or ChatGPT app reads the fleet, and acts in it at the level of the owner's one-time code. The Mac
/// shows the open connections and makes the code. It asks these routes only of a hub that names the feature.
public enum ConnectedApps {
    /// The hub feature that carries the two groups, in `ui_features`.
    public static let feature = "connected_apps"
    /// The hub feature that lets the Mac read `GET /ui/connect` before `connected_apps` is there (UI-API.md, version
    /// 1.151): while it can offer Turn on, and while it waits for the feature to be ready.
    public static let offer = "connect_offer"
    /// The two levels of a code and of a connection, in the hub's words.
    public static let levels = ["read", "act"]

    /// A level in the owner's words: "Read" or "Act".
    public static func levelWord(_ level: String) -> String { level == "act" ? "Act" : "Read" }

    /// The muted detail of one connection: its level and its last use, or the time since it was made before a first
    /// use ("Read · 2 h ago").
    public static func detail(_ connection: AppConnection, now: Double) -> String {
        "\(levelWord(connection.level)) · \(activityAge(connection.last_used ?? connection.created, now: now))"
    }

    /// A one-time code of the hub: three groups of four letters or digits with a dash between two ("ABCD-EFGH-JKLM"),
    /// or two groups from a hub before the security review. The app shows it as the hub gives it.
    public static func isCode(_ code: String) -> Bool {
        code.range(of: "^[A-Z0-9]{4}(-[A-Z0-9]{4}){1,2}$", options: .regularExpression) != nil
    }
}

/// One open connection of `GET /ui/connect`. `name` is the name that the hub chose (Claude, ChatGPT, Claude Code, the
/// app's own name, or "App"), never the app's own claim for Claude or ChatGPT. `last_used` is nil before the first call.
public struct AppConnection: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let level: String
    public let last_used: Double?
    public let created: Double

    var isValid: Bool {
        id > 0 && !name.isEmpty && name.count <= 64 && ConnectedApps.levels.contains(level) && created.isFinite
            && (last_used?.isFinite ?? true)
    }
}

/// `GET /ui/connect?db=`: whether the feature is on, whether the Mac may offer Turn on here (`canTurnOn`, UI-API.md
/// version 1.151), why it is on and does not work (`stopped`), the public address, the open connections (oldest first)
/// and the gate. `address` is nil while the hub
/// does not know its name. The answer carries no code and no token.
public struct ConnectState: Decodable, Equatable, Sendable {
    public let db: String
    public let on: Bool
    /// The hub's `can_turn_on`: absent on a hub before version 1.151.
    let can_turn_on: Bool?
    /// The feature is allowed in the hub's release, the hub runs on Linux, and the feature is off. False on a hub that
    /// does not give the field.
    public var canTurnOn: Bool { can_turn_on ?? false }
    /// Why the feature is on and no connected app can reach the hub now, in the hub's own words (`capp_stopped`): its
    /// socket stays closed, or no gate forwards to it. Nil while it is off, while it works, and on a hub that does not
    /// give the field. The Mac reads it only to choose its own sentence (`ConnectGate.stop`); no row shows these words.
    public let stopped: String?
    public let address: String?
    public let connections: [AppConnection]
    public let gate: Gate?

    public struct Gate: Decodable, Equatable, Sendable {
        public let version: String?
        public let ok: Bool
    }

    public func validate(database: String) throws {
        guard db == database, Set(connections.map(\.id)).count == connections.count,
              connections.allSatisfy(\.isValid),
              address.map(Self.isAddress) ?? true else { throw HubError.invalidResponse }
    }

    /// The hub's public MCP address: `https://<a DNS name>/mcp`, and nothing else.
    static func isAddress(_ address: String) -> Bool {
        guard let parts = URLComponents(string: address), parts.scheme == "https", let host = parts.host,
              !host.isEmpty, parts.port == nil, parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil else { return false }
        return parts.path == "/mcp"
    }
}

/// `POST /ui/connect/code`: one code for one sign-in at this level, ten minutes, once. The hub keeps only its SHA-256,
/// so a repeat of the same request gives `code` nil. The app keeps the code in the page's state only.
public struct ConnectCode: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let code: String?
    public let level: String
    public let expires: Double
    public let replayed: Bool
}

/// `POST /ui/connect/settings`: `hub.connect` in one commit of team.json. `on: false` also ended every connection
/// (`revoked` of them).
public struct ConnectSettings: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let on: Bool
    public let revoked: Int
}

/// `POST /ui/connect/<id>/revoke`: the connection ended. Its next call of the MCP address gets 401.
public struct ConnectRevoke: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let id: Int
    public let revoked: Bool
}
