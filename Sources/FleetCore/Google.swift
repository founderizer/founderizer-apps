import Foundation
import Network

// Gmail and Drive for the agents (owner feature `google`; UI-API.md "Google Drive and Gmail"). In an agent's
// Integrations section, the owner connects an account for one service: the app opens a listener on 127.0.0.1, the hub
// gives the consent address of its one client for that service, the browser comes back to the listener with a code,
// and the hub exchanges it and keeps the account's refresh token. No token reaches the app. Gmail and Drive are
// independent: each worker and lead has each from its own account, at its own level.

/// One service of the agents, with its own account and level.
public enum GoogleService: String, CaseIterable, Identifiable, Sendable {
    case gmail, drive

    public var id: String { rawValue }
    public var title: String { self == .drive ? "Drive" : "Gmail" }
    /// The short name of the scope that the account must have granted for the service (`scopes` of `GET /ui/team`).
    public var scope: String { self == .drive ? "drive" : "gmail.modify" }
    /// The levels of the service, from the least access. A level has the tools of the levels before it.
    public var levels: [GoogleLevel] { self == .drive ? [.read, .write, .writeShared] : [.read, .write, .send] }

    /// What one level gives an agent, in words; nil is no access.
    public func words(_ level: GoogleLevel?) -> String {
        switch (self, level) {
        case (.drive, .read?): String(l10n: "Searches and reads the files")
        case (.drive, .write?): String(l10n: "Also makes and changes files that nobody else sees")
        case (.drive, .writeShared?): String(l10n: "Also changes shared files and folders")
        case (.gmail, .read?): String(l10n: "Searches and reads the email")
        case (.gmail, .write?): String(l10n: "Also drafts, labels, archives and trashes")
        case (.gmail, .send?): String(l10n: "Also sends email from this account")
        default: String(l10n: "No access")
        }
    }

    /// **The notice before Google's page** (the owner's "Yes, both as drawn" of 16 November 2026): Settings › Apps shows
    /// it at every Connect account, between the press and the browser, with Cancel and Continue (`GoogleConnectNotice`).
    /// Google's Workspace User Data and Developer Policy asks for "a disclosure of your data access, collection, use, and
    /// sharing" inside the application, which must "accompany and immediately precede a request for user consent": who
    /// asks (Founderizer), for what (the email or the files of one account), where the access stays (the hub), what the
    /// agents do with it, who else reads it (the AI provider of each agent), and that Founderizer's servers never
    /// receive it.
    public var notice: String {
        switch self {
        case .gmail: String(l10n: "Google will ask you to give Founderizer access to the email of one account. Your hub keeps this access on your server. The agents that you give the account search, read, draft, label, archive, trash and send its email, as far as their level allows, and send what they read to the AI provider that they run on, and to the people and apps that their tasks reach. Founderizer's servers never receive your email.")
        case .drive: String(l10n: "Google will ask you to give Founderizer access to the Google Drive of one account. Your hub keeps this access on your server. The agents that you give the account search, read, make, change, move and trash its files, as far as their level allows, and send what they read to the AI provider that they run on, and to the people and apps that their tasks reach. Founderizer's servers never receive your files.")
        }
    }
}

/// **The steps of one Connect of Settings › Apps before the browser opens** (the owner's "Yes, both as drawn" of 16
/// November 2026): Connect account shows the notice (`GoogleService.notice`) and starts nothing; only its Continue starts
/// the Connect; Cancel, another page and another hub end it with no Connect. Google's policy: the disclosure "must
/// accompany and immediately precede a request for user consent", the consent must "require affirmative user action",
/// and it "must not interpret navigation away from the disclosure ... as consent". So the notice shows at every Connect,
/// and nothing that is not Continue goes on to Google's page.
public struct GoogleConnectNotice: Equatable, Sendable {
    public private(set) var shows = false

    public init() {}

    /// Connect account: the notice. Nothing while a Connect is on its way.
    public mutating func press(connecting: Bool) {
        if !connecting { shows = true }
    }

    /// Continue: one consent, while the notice shows, and nil otherwise. It is the one way to a Connect: the start of a
    /// Connect takes it (`GoogleClient.connect`), and nothing else makes one.
    public mutating func proceed() -> GoogleConsent? {
        defer { shows = false }
        return shows ? GoogleConsent() : nil
    }

    /// Cancel, another page or another hub: no Connect.
    public mutating func dismiss() { shows = false }
}

/// **The owner's Continue on the notice before Google's page**, as a value: `GoogleClient.connect` needs one, and only
/// `GoogleConnectNotice.proceed()` makes one, so no code of the app can open Google's consent page without the notice
/// and its Continue in front of it.
public struct GoogleConsent: Sendable {
    fileprivate init() {}
}

/// **What is left of one Google account in the fleet after its Disconnect, taken away** (`ResourceList.cleanup`): one
/// write at a time, each against a new reading (`read`), so no write goes against an old version of `team.json`. A write
/// that a newer version refused (409) reads again; any other refusal, and a failed reading, stop at once. At most
/// `rounds` writes, the 409s among them, then one more reading: nothing left is success, else the last refusal. The
/// app's Disconnect calls it after `POST /ui/google/disconnect` (`AccessSettings`).
public enum GoogleDisconnect {
    /// Four writes (two services, each with its agents and its standing) and four refusals.
    public static let rounds = 8

    public static func clear(account: String, rounds: Int = rounds,
                             read: @Sendable () async throws -> ResourceList,
                             write: @Sendable (GoogleCleanup, _ sha256: String) async throws -> Void) async throws {
        var last: Error = HubError.invalidResponse
        var budget = rounds, round = 0
        while round < budget {
            round += 1
            let list = try await read()
            if round == 1 { budget += list.cleanup(account: account).filter { if case .folder = $0 { true } else { false } }.count }
            guard let next = list.cleanup(account: account).first else { return }
            do {
                try await write(next, list.sha256)
            } catch let HubError.refusal(refusal) where refusal.status == 409 && refusal.code.map({ $0 == "team_changed" }) ?? true {
                // A newer version of team.json: read it again. Another 409 (a folder that the hub cannot read) stops.
                last = HubError.refusal(refusal)
            }
        }
        if try await read().cleanup(account: account).isEmpty { return }
        throw last
    }
}

/// The answer of `GoogleClient.saveFolder`: the folder as the account reads it (no holders: the next reading of the
/// resources has them), and {agent: account} for each agent whose Drive of another account the write took the place of.
public struct GoogleFolderSaved: Equatable, Sendable {
    public let folder: DriveFolder
    public let tookPlaceOf: [String: String]
}

/// What is left of one Google account in the fleet after the hub's Disconnect, one write at a time (the owner's "Yes,
/// both as drawn" of 16 November 2026: "The agents that have it lose it", and the account leaves the list).
public enum GoogleCleanup: Equatable, Sendable {
    /// Every agent's level of this service from the account: `POST /ui/team/google` with an empty map.
    case access(GoogleService)
    /// The fleet manager's standing for this service of the account: `POST /ui/resources` with no policy.
    case standing(GoogleService)
    /// Every agent's level of one folder of the account's Drive (owner API 1.255): `POST /ui/team/google` with the folder
    /// and an empty map.
    case folder(String)
}

extension ResourceList {
    /// The writes that are left for one account after its Disconnect, Gmail first: the agents that hold a service of it,
    /// then the standing of that service. Google's revoke ends both services of the account, so both go, whichever
    /// page the Disconnect was on. Empty when nothing of it is left: the account then leaves the list.
    public func cleanup(account: String) -> [GoogleCleanup] {
        let email = account.lowercased()
        return GoogleService.allCases.flatMap { service -> [GoogleCleanup] in
            guard let item = resource("\(service.rawValue):\(email)") else { return [] }
            return (item.holders.isEmpty ? [] : [.access(service)]) + (item.folders ?? []).map { .folder($0.id) }
                + (item.grant == nil ? [] : [.standing(service)])
        }
    }
}

/// The level of one agent in one service, as team.json keeps it.
public enum GoogleLevel: String, Codable, CaseIterable, Sendable {
    case read, write, writeShared = "write_shared", send

    public var title: String {
        switch self {
        case .read: String(l10n: "Read")
        case .write: String(l10n: "Write")
        case .writeShared: String(l10n: "Write shared")
        case .send: String(localized: "Send (a Google level)", defaultValue: "Send", bundle: Localized.bundle, locale: Localized.digits)
        }
    }
    /// Write shared and Send reach other people as the owner, without asking.
    public var reachesOthers: Bool { self == .writeShared || self == .send }
}

/// One service of one agent: the account that it comes from, and the level.
public struct GoogleGrant: Decodable, Equatable, Sendable {
    public let account: String
    public let level: GoogleLevel
}

/// One write of one agent's service: from one account at a level; nil takes it from that account.
public struct GoogleChange: Equatable, Sendable {
    public let agent: String
    public let service: GoogleService
    public let account: String
    public let level: GoogleLevel?
}

public enum Google {
    public static let feature = "google"
    public static let reachesOthers = String(l10n: "Reaches other people, as you, without asking.")
    /// **What the Disconnect of a Google account does, in the place of its button after a press** (the owner's "Yes,
    /// both as drawn" of 16 November 2026). Google's revoke "removes all OAuth 2.0 scopes previously granted to a
    /// project" and ends the tokens "for all clients registered under that project": both services of the account end,
    /// in every fleet that connected it with the same Google app (UI-API.md, "One Google account in two fleets").
    public static let disconnectWords = String(l10n: "Google ends this account's Gmail and Google Drive access in every fleet that connected it. The agents that have it lose it.")

    /// The address that the browser comes back to: the listener of this Connect.
    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/" }

    /// The access map of one account and one service after one agent's choice: a level gives the agent that service
    /// from this account (the hub replaces another account of that service), and nil takes it from this account.
    public static func access(_ current: [String: GoogleLevel], agent: String, to choice: GoogleLevel?) -> [String: GoogleLevel] {
        var result = current
        result[agent] = choice
        return result
    }
}

/// The parts of `GET /ui/team` for Gmail and Drive: each line's `google` and the accounts. Both are optional, so a hub
/// without the feature still decodes.
public struct GoogleSnapshot: Decodable, Sendable {
    public struct Line: Decodable, Identifiable, Sendable {
        public let agent: String
        public let role: String
        /// {service: grant}; `{}` when the agent has neither.
        public let google: [String: GoogleGrant]?
        public var id: String { agent }
        public func grant(_ service: GoogleService) -> GoogleGrant? { google?[service.rawValue] }
    }
    /// One account: connected at the hub, or named in team.json. The hub never gives a token.
    public struct Account: Decodable, Equatable, Identifiable, Sendable {
        public let email: String
        public let connected: Bool
        /// The short names of the granted scopes.
        public let scopes: [String]?
        /// Its refused refresh, or nil.
        public let problem: String?
        public var id: String { email }

        /// Why the hub cannot use this account for one service, in words; nil when it can.
        public func reason(for service: GoogleService) -> String? {
            if problem != nil { return String(l10n: "The saved access of \(email) stopped working. Connect it again.") }
            if !connected { return String(l10n: "\(email) is not connected. Connect it again.") }
            if !(scopes ?? []).contains(service.scope) { return String(l10n: "\(email) does not allow \(service.title). Connect it again.") }
            return nil
        }
    }
    /// The hub's client and accounts. The hub never gives the client secret.
    public struct Setup: Decodable, Equatable, Sendable {
        /// The hub has its client: without it, Connect cannot start.
        public let client: Bool
        /// Sorted by email.
        public let accounts: [Account]
    }
    public let db: String
    public let sha256: String
    public let lines: [Line]
    /// nil on a hub without the feature.
    public let google: Setup?

    /// {agent: level} of one service from one account.
    public func access(_ service: GoogleService, account: String) -> [String: GoogleLevel] {
        Dictionary(uniqueKeysWithValues: lines.compactMap { line in
            line.grant(service).flatMap { $0.account == account ? (line.agent, $0.level) : nil }
        })
    }

    // MARK: one agent, one service

    public func grant(agent: String, _ service: GoogleService) -> GoogleGrant? { lines.first { $0.agent == agent }?.grant(service) }

    /// Why the agent cannot use its account for one service now, in words; nil when it can, or when it has no account.
    public func reason(agent: String, _ service: GoogleService) -> String? {
        guard let grant = grant(agent: agent, service) else { return nil }
        return google?.accounts.first { $0.email == grant.account }.map { $0.reason(for: service) }
            ?? String(l10n: "\(grant.account) is not connected. Connect it again.")
    }

    /// The write after a Connect of one service: the agent gets it from `account`, at its level when it had the service,
    /// else at Read. The hub replaces an earlier account of that service. nil when nothing changes.
    public func connect(agent: String, _ service: GoogleService, account: String) -> GoogleChange? {
        let grant = grant(agent: agent, service)
        guard grant?.account != account else { return nil }
        return GoogleChange(agent: agent, service: service, account: account, level: grant?.level ?? .read)
    }

    /// The write that takes one service from an agent. nil when it does not have it.
    public func remove(agent: String, _ service: GoogleService) -> GoogleChange? {
        grant(agent: agent, service).map { GoogleChange(agent: agent, service: service, account: $0.account, level: nil) }
    }

    /// The write of a new level of one service, from its account. nil when nothing changes or the agent has no account.
    public func change(agent: String, _ service: GoogleService, to level: GoogleLevel) -> GoogleChange? {
        guard let grant = grant(agent: agent, service), grant.level != level else { return nil }
        return GoogleChange(agent: agent, service: service, account: grant.account, level: level)
    }

    /// The access map of the change's account and service, with the change: what `POST /ui/team/google` sends.
    public func access(after change: GoogleChange) -> [String: GoogleLevel] {
        Google.access(access(change.service, account: change.account), agent: change.agent, to: change.level)
    }

    /// A connected account that no agent uses for any service. Nothing in the app disconnects such an account by itself
    /// since 18 October 2026 ("The account is the unit"): the owner ends an account with Disconnect on its card
    /// (`AccessSettings`), which takes it from its agents too (`ResourceList.cleanup`).
    public func unused(_ email: String) -> Bool {
        google?.accounts.contains { $0.email == email && $0.connected } == true
            && !lines.contains { line in GoogleService.allCases.contains { line.grant($0)?.account == email } }
    }

    public func validate(database: String) throws {
        guard db == database, sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              (google?.accounts ?? []).allSatisfy({ $0.email.contains("@") }),
              lines.allSatisfy({ line in
                  (line.google ?? [:]).allSatisfy { key, grant in
                      grant.account.contains("@") && GoogleService(rawValue: key)?.levels.contains(grant.level) == true
                  }
              })
        else { throw HubError.invalidResponse }
    }
}

/// Why a Connect stopped, in one sentence.
public enum GoogleConnectError: LocalizedError, Equatable, Sendable {
    case wrongState, timeLimit
    /// The error code of the consent page, such as `access_denied`.
    case denied(String)

    public var errorDescription: String? {
        switch self {
        case .wrongState: String(l10n: "This answer is not for this Connect. Start Connect again.")
        case .timeLimit: String(l10n: "No answer came within 10 minutes. Start Connect again.")
        case .denied(let reason): String(l10n: "The access was not given (\(reason)). Start Connect again.")
        }
    }
}

/// The browser's request to the listener: Google's answer, or another request.
public enum GoogleCallback: Equatable, Sendable {
    case code(String, state: String)
    case error(String, state: String)
    /// Another path or method, or a query without `state`, or without `code` and `error`.
    case other

    /// Reads one HTTP request line, such as `GET /?state=…&code=… HTTP/1.1`. Google's error code keeps only letters,
    /// digits, `_`, `-` and `.`, so that the page and the app can show it.
    public static func parse(_ requestLine: String) -> GoogleCallback {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/"),
              let target = URLComponents(string: "http://127.0.0.1" + parts[1]), target.path == "/" else { return .other }
        func value(_ name: String) -> String? {
            (target.queryItems ?? []).first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let state = value("state") else { return .other }
        if let error = value("error") {
            let safe = String(String.UnicodeScalarView(error.unicodeScalars.filter {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0))
            }).prefix(100))
            return .error(safe.isEmpty ? "unknown" : safe, state: state)
        }
        if let code = value("code") { return .code(code, state: state) }
        return .other
    }
}

/// The listener's answer to one request: its status and page, and the end of the Connect (nil: it waits on).
public struct GoogleAnswer: Equatable, Sendable {
    public let status: Int
    public let page: String
    /// The code, or why the Connect stopped.
    public let end: Result<String, GoogleConnectError>?

    /// What the listener does with one request line, for the `state` that the hub gave.
    public static func to(_ requestLine: String, state expected: String) -> GoogleAnswer {
        let wrong = GoogleAnswer(status: 400, page: String(l10n: "This answer is not for the Connect that Founderizer started. Start Connect again in Founderizer."),
                                 end: .failure(.wrongState))
        switch GoogleCallback.parse(requestLine) {
        case .other:
            return GoogleAnswer(status: 404, page: String(l10n: "Not found."), end: nil)
        case .code(let code, let state):
            guard state == expected else { return wrong }
            return GoogleAnswer(status: 200, page: String(l10n: "Founderizer is connected. You can close this tab."), end: .success(code))
        case .error(let error, let state):
            guard state == expected else { return wrong }
            let failure = GoogleConnectError.denied(error)
            return GoogleAnswer(status: 200, page: String(l10n: "\(failure.errorDescription ?? "") You can close this tab."), end: .failure(failure))
        }
    }

    /// The whole HTTP answer, with `Connection: close`.
    public var response: Data {
        let html = #"<!doctype html><meta charset="utf-8"><title>Founderizer</title>"#
            + #"<p style="font: 15px -apple-system, sans-serif; margin: 40px">\#(page)</p>"#
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
        return Data(("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\n"
                     + "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + html).utf8)
    }
}

/// The listener of one Connect, on 127.0.0.1 only, on a port that the system chooses. It answers each request with one
/// short page and closes the connection. Google's answer ends it; another request gets 404, and it waits on.
public final class GoogleLoopback: Sendable {
    public let port: UInt16
    public var redirectURI: String { Google.redirectURI(port: port) }
    private let listener: NWListener
    private let requests: AsyncStream<(String, NWConnection)>
    private let feed: AsyncStream<(String, NWConnection)>.Continuation

    private init(listener: NWListener, port: UInt16, requests: AsyncStream<(String, NWConnection)>,
                 feed: AsyncStream<(String, NWConnection)>.Continuation) {
        self.listener = listener; self.port = port; self.requests = requests; self.feed = feed
    }

    public static func open() async throws -> GoogleLoopback {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "founderizer.google-loopback")
        let (requests, feed) = AsyncStream.makeStream(of: (String, NWConnection).self)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            requestLine(connection, Data()) { line in
                if let line { feed.yield((line, connection)) } else { connection.cancel() }
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return GoogleLoopback(listener: listener, port: port, requests: requests, feed: feed)
    }

    /// Waits for Google's answer to this Connect, answers the browser, and stops. A wrong `state`, an error from Google,
    /// the time limit or a cancel stops the Connect.
    public func code(state: String, limit: Duration = .seconds(600)) async throws -> String {
        defer { stop() }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await (line, connection) in self.requests {
                    let answer = GoogleAnswer.to(line, state: state)
                    connection.send(content: answer.response, completion: .contentProcessed { _ in connection.cancel() })
                    if let end = answer.end { return try end.get() }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: limit)
                throw GoogleConnectError.timeLimit
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public func stop() {
        listener.cancel()
        feed.finish()
    }

    /// The first line of the request, without its line end; nil after 8 KiB or a closed connection.
    private static func requestLine(_ connection: NWConnection, _ buffer: Data, _ done: @escaping @Sendable (String?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = String(decoding: buffer[..<end], as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                done(line)
            } else if error != nil || complete || buffer.count >= 8192 {
                done(nil)
            } else {
                requestLine(connection, buffer, done)
            }
        }
    }
}

/// The start of a Connect: the consent address to open in the browser, and the `state` that Google must give back.
public struct GoogleConnectStart: Sendable {
    public let url: URL
    public let state: String
    /// Whose Google app the Connect signs in to: `founderizer` (Founderizer's own: the hub's release brings its ID,
    /// and founderizer.com its secret) or
    /// `own` (a client of the hub's own file); nil from a hub from before Founderizer's Google app.
    public let app: String?
    /// Whether Google has verified Founderizer's app; nil for another app.
    public let verified: Bool?

    public init(url: URL, state: String, app: String? = nil, verified: Bool? = nil) {
        self.url = url; self.state = state; self.app = app; self.verified = verified
    }

    /// **The one line under the wait while Google has not verified Founderizer's app** (the owner's "Yes, as drawn"
    /// of 15 November 2026): Google then shows its warning page first, whose big button is "Back to safety". A
    /// release says when Google has verified the app, and the line goes by itself.
    public var hint: String? {
        app == "founderizer" && verified == false
            ? String(l10n: "If Google says that it has not verified Founderizer, press Advanced, then Go to Founderizer.")
            : nil
    }
}

/// The four writes, without the command fields.
enum GoogleCommand {
    /// `account`: the email of an account to connect again, or nil for a new account.
    case connect(redirectURI: String, service: GoogleService, account: String?)
    case finish(state: String, code: String)
    case disconnect(account: String)
    case access(sha256: String, account: String, service: GoogleService, access: [String: GoogleLevel],
                folder: String? = nil)

    var route: String {
        switch self {
        case .connect: "ui/google/connect"
        case .finish: "ui/google/finish"
        case .disconnect: "ui/google/disconnect"
        case .access: "ui/team/google"
        }
    }

    var fields: [String: Any] {
        switch self {
        case .connect(let redirectURI, let service, let account):
            var fields: [String: Any] = ["redirect_uri": redirectURI, "service": service.rawValue]
            if let account { fields["account"] = account }
            return fields
        case .finish(let state, let code): return ["state": state, "code": code]
        case .disconnect(let account): return ["account": account]
        case .access(let sha256, let account, let service, let access, let folder):
            var fields: [String: Any] = ["base_sha256": sha256, "account": account, "service": service.rawValue,
                                         "access": access.mapValues(\.rawValue)]
            if let folder { fields["folder"] = folder }     // owner API 1.255: a link of a folder or its id
            return fields
        }
    }
}

/// `GET /ui/team` for an agent's Integrations section, and the four writes. A change of access goes against the team.json version
/// that the section read (`base_sha256`), as on the GitHub page.
public final class GoogleClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The finish: the hub exchanges the code and reads the email at Google, and after a changed secret of
        // Founderizer's app it reads founderizer.com and exchanges once more, each call up to 30 seconds.
        configuration.timeoutIntervalForRequest = 160
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: NoGoogleRedirect(), delegateQueue: nil)
    }

    public func read(hub: URL, database: String) async throws -> GoogleSnapshot {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/team"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let snapshot = try JSONDecoder().decode(GoogleSnapshot.self, from: await perform(request))
        try snapshot.validate(database: database)
        return snapshot
    }

    /// Starts a Connect of one service with the hub's client: of any account, or with `account` (a login hint) of that
    /// account again. The hub asks for that service's permission, and in a fleet with accounts of an own client for
    /// their services too (owner API 1.185). Fleet opens only the consent page on accounts.google.com, and only with the
    /// owner's Continue on the notice before it (`consent`, from `GoogleConnectNotice.proceed()`).
    public func connect(hub: URL, database: String, client: String, redirectURI: String, service: GoogleService,
                        account: String?, consent: GoogleConsent) async throws -> GoogleConnectStart {
        let receipt = try await write(.connect(redirectURI: redirectURI, service: service, account: account),
                                      hub: hub, database: database, client: client)
        guard let address = receipt.url, let url = URL(string: address), url.scheme == "https", url.host == "accounts.google.com",
              let state = receipt.state, !state.isEmpty else { throw HubError.invalidResponse }
        return GoogleConnectStart(url: url, state: state, app: receipt.app, verified: receipt.verified)
    }

    /// Gives the hub Google's code. The answer is the email of the account that Google gave, and whether that account
    /// was connected before.
    public func finish(hub: URL, database: String, client: String, state: String,
                       code: String) async throws -> (email: String, replaced: Bool) {
        let receipt = try await write(.finish(state: state, code: code), hub: hub, database: database, client: client)
        guard receipt.connected == true, let email = receipt.email, email.contains("@") else { throw HubError.invalidResponse }
        return (email, receipt.replaced == true)
    }

    /// Removes one account's token at the hub. Its grants in team.json stay. The answer says whether Google confirmed
    /// the revoke.
    public func disconnect(hub: URL, database: String, client: String, account: String) async throws -> Bool {
        let receipt = try await write(.disconnect(account: account), hub: hub, database: database, client: client)
        guard receipt.connected == false else { throw HubError.invalidResponse }
        return receipt.revoked == true
    }

    /// Who has one service from one account: an agent that `access` names gets it from this account, an agent that it
    /// does not name loses it from this account, and an empty map takes it from every agent.
    public func saveAccess(hub: URL, database: String, client: String, sha256: String, account: String, service: GoogleService,
                           access: [String: GoogleLevel]) async throws {
        _ = try await write(.access(sha256: sha256, account: account, service: service, access: access),
                            hub: hub, database: database, client: client)
    }

    /// **One folder of a Drive account for some agents** (owner API 1.255, `drive_folders`): `folder` is its link or its
    /// id, and `access` the levels of that folder alone. The answer names the folder as the account reads it, and the
    /// agents whose Drive of another account this write took the place of.
    public func saveFolder(hub: URL, database: String, client: String, sha256: String, account: String, folder: String,
                           access: [String: GoogleLevel]) async throws -> GoogleFolderSaved {
        let receipt = try await write(.access(sha256: sha256, account: account, service: .drive, access: access,
                                              folder: folder), hub: hub, database: database, client: client)
        guard let id = receipt.folder else { throw HubError.invalidResponse }
        return GoogleFolderSaved(folder: DriveFolder(id: id, link: "https://drive.google.com/drive/folders/\(id)",
                                                     name: receipt.name, shared: receipt.shared),
                                 tookPlaceOf: receipt.took_place_of ?? [:])
    }

    static func body(_ command: GoogleCommand, requestID: String, database: String) throws -> Data {
        try IntegrationsClient.body(command.fields, requestID: requestID, database: database)
    }

    private struct Receipt: Decodable {
        let ok: Bool
        let request_id: String
        let client: String
        let url: String?
        let state: String?
        let app: String?
        let verified: Bool?
        let email: String?
        let connected: Bool?
        let replaced: Bool?
        let revoked: Bool?
        /// POST /ui/team/google with a folder (owner API 1.255).
        let folder: String?
        let name: String?
        let shared: Bool?
        let took_place_of: [String: String]?
    }

    private func write(_ command: GoogleCommand, hub: URL, database: String, client: String) async throws -> Receipt {
        let requestID = UUID().uuidString.lowercased()
        var request = URLRequest(url: hub.appendingPathComponent(command.route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try Self.body(command, requestID: requestID, database: database)
        let receipt = try JSONDecoder().decode(Receipt.self, from: await perform(request))
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client else { throw HubError.invalidResponse }
        return receipt
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
        return data
    }

}

private final class NoGoogleRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
