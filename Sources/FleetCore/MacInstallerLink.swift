import CryptoKit
import Foundation

/// Adding **a Mac that stays on** (PRODUCT.md 2 and P3): the notarized installer runs on that Mac and shows a link
/// code; the owner types that code into the app once, and the app does the rest.
///
/// The app is the one that holds the fleet: it asks its hub for the one-time join line and sends it to the installer
/// over the local network, with the Tailscale key only when that Mac is not on the private network yet. So nothing
/// is typed on the Mac itself — no address, no line, no console — and the link code is what proves to the installer
/// that the order came from the owner's own app. The code never crosses the network: it is the key of the link
/// (`MacLinkSeal`).
public struct MacInstallOrder: Codable, Equatable, Sendable {
    /// The link code the installer showed, which is the whole of the authorization.
    public let code: String
    /// The hub this machine joins, and the name the fleet knows it by. A hub with `server_names` names it by its name in
    /// Tailscale instead; the app still sends a name the hub allows, because the installer's older copies refuse one
    /// that is not.
    public let hub: String
    public let name: String
    /// The one-time join line the hub gave for this machine. The installer runs it unchanged.
    public let line: String
    /// The owner's own Tailscale auth key, only when that Mac is not on their private network yet.
    public let authKey: String?
    /// The first agent of this Mac, which the hub adds by itself once this Mac has joined (`mac_setup`). It names the
    /// wait for it on that Mac: the owner's app need not stay open.
    public let agent: String?

    public init(code: String, hub: String, name: String, line: String, authKey: String? = nil, agent: String? = nil) {
        self.code = code; self.hub = hub; self.name = name; self.line = line; self.authKey = authKey; self.agent = agent
    }

    /// What may be sent, and what the installer takes: a link code of the right shape, a plain hub address on the
    /// fleet's own private network, a name the hub allows, and a join line of this one exact shape, because it runs as
    /// root on that Mac (`Installer/setup.sh` reads it the same way).
    public var isValid: Bool {
        guard ClaimCode.read(code) != nil, name.range(of: Servers.namePattern, options: .regularExpression) != nil,
              let address = URL(string: hub), address.scheme == "http" || address.scheme == "https",
              let host = address.host, !line.contains("\n"), line.utf8.count <= 1000 else { return false }
        return line.range(of: "^curl -fsS http://[0-9A-Za-z.:-]+/join \\| FLEET_JOIN=[A-Z0-9-]+ sh$",
                          options: .regularExpression) != nil && line.contains(host)
    }
}

/// One step of the install on that Mac, as the installer reports it.
public struct MacInstallStep: Codable, Equatable, Sendable, Identifiable {
    public let step: String
    public let title: String
    /// `running`, `done` or `failed`.
    public let state: String
    public let says: String
    public var id: String { step }

    public init(step: String, title: String, state: String, says: String) {
        self.step = step; self.title = title; self.state = state; self.says = says
    }
}

/// Where the install on that Mac stands, which the app reads until it ends.
public struct MacInstallState: Codable, Equatable, Sendable {
    /// `waiting` (for the owner's order), `running`, `done` or `failed`.
    public let state: String
    /// One line for the owner, written by the installer.
    public let says: String
    public let steps: [MacInstallStep]
    /// What `verify` answered on that Mac, at the end (PRODUCT.md 4.1).
    public let verify: [VerifyCheck]?
    /// What this Mac still needs before it can join: Homebrew, Tailscale, a newer macOS. Each with its own fix.
    public let missing: [VerifyCheck]?
    /// This installer reads the owner's choice of AI from the hub. An older one answers nothing here.
    public let choice: Bool?

    public init(state: String, says: String, steps: [MacInstallStep] = [], verify: [VerifyCheck]? = nil,
                missing: [VerifyCheck]? = nil) {
        self.state = state; self.says = says; self.steps = steps; self.verify = verify; self.missing = missing
        choice = true
    }

    public var isRunning: Bool { state == "running" }
    public var isDone: Bool { state == "done" }
    public var failed: Bool { state == "failed" }
    /// The machine's own checklist, when the install reached it.
    public var checklist: VerifyChecklist? {
        verify.map { VerifyChecklist(checks: $0, readAt: Date().timeIntervalSince1970) }
    }
}

/// **The link is sealed with the link code** (the review of 31 October 2026: the order carried the owner's Tailscale key
/// over the local network in the clear). The code stands on that Mac's screen and in the owner's own hands, and never
/// on the network: both sides make one key from it, and every body in both directions is sealed with that key, so
/// that nobody on the network reads the order, or writes a state that the app takes for that Mac's.
public enum MacLinkSeal {
    static func key(_ code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: Data("founderizer-mac-link".utf8), outputByteCount: 32)
    }

    public static func seal(_ body: Data, code: String) throws -> Data {
        try ChaChaPoly.seal(body, using: key(code)).combined
    }

    /// The body, or nil when it was not sealed with this code.
    public static func open(_ sealed: Data, code: String) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed) else { return nil }
        return try? ChaChaPoly.open(box, using: key(code))
    }
}

public enum MacLinkError: LocalizedError, Equatable, Sendable {
    case notAnAddress
    case refused(String)
    case unreachable
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .notAnAddress: return "Give the address the installer shows on that Mac, and its link code."
        case .refused(let says): return says
        case .unreachable: return "This Mac cannot reach the installer on that Mac. Check the address it shows."
        case .unreadable: return "The installer on that Mac answered something this app could not read."
        }
    }
}

/// The app's half of the link: the order to that Mac's installer, and the state it answers until the install ends.
///
/// It is HTTP on the local network, because the Mac being installed is not on the fleet's private network yet — that
/// is what this install is for. Every body is sealed with the link code (`MacLinkSeal`), and the installer accepts
/// three wrong seals before it stops, so a code cannot be guessed on the way.
public struct MacInstallerClient: Sendable {
    public static let port = 8767
    /// Reads of `/state` in a row that may fail before the link counts as lost: that Mac's firewall starts during the
    /// install, and its network stops for some seconds then.
    public static let unreadTries = 40
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    /// The address of one installer: what the owner read off that Mac's screen, with the port when they gave none.
    public static func address(_ given: String, port: Int = MacInstallerClient.port) -> URL? {
        let text = given.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "http://", with: "")
        guard !text.isEmpty, !text.contains("/"), text.count <= 120 else { return nil }
        let parts = text.split(separator: ":")
        guard let host = parts.first, !host.isEmpty, parts.count <= 2 else { return nil }
        let chosen = parts.count == 2 ? Int(parts[1]) ?? 0 : port
        guard (1...65535).contains(chosen) else { return nil }
        return URL(string: "http://\(host):\(chosen)")
    }

    /// `POST /install`: the order. The installer answers at once; the install itself takes minutes and `state` holds
    /// where it stands.
    public func send(_ order: MacInstallOrder, to installer: URL) async throws -> MacInstallState {
        guard order.isValid, let code = ClaimCode.read(order.code) else { throw MacLinkError.notAnAddress }
        return try await answer("install", try JSONEncoder().encode(order), code: code, from: installer)
    }

    /// `POST /state`: where the install on that Mac stands. Only the owner's own app can seal this request.
    public func state(code: String, from installer: URL) async throws -> MacInstallState {
        guard let code = ClaimCode.read(code) else { throw MacLinkError.notAnAddress }
        return try await answer("state", Data("{}".utf8), code: code, from: installer)
    }

    private func answer(_ route: String, _ body: Data, code: String, from installer: URL) async throws -> MacInstallState {
        var request = URLRequest(url: installer.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MacLinkSeal.seal(body, code: code)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw MacLinkError.unreachable }
        guard let http = response as? HTTPURLResponse, data.count <= 262_144 else { throw MacLinkError.unreadable }
        guard http.statusCode == 200 else {
            // A refusal comes before the seal is known to be right, so it is the one answer in the clear. It carries
            // nothing of the order, and it changes nothing here.
            let said = try? JSONDecoder().decode(MacInstallState.self, from: data)
            throw MacLinkError.refused(said?.says ?? "The installer on that Mac refused this (\(http.statusCode)).")
        }
        guard let opened = MacLinkSeal.open(data, code: code),
              let state = try? JSONDecoder().decode(MacInstallState.self, from: opened) else {
            throw MacLinkError.unreadable
        }
        return state
    }
}
