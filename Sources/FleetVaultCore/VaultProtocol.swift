import Foundation
import CoreFoundation
import CryptoKit

public enum VaultFailure: String, Error, Sendable, CaseIterable {
    case request = "The vault request is not supported."
    case configuration = "The vault configuration is not valid or is not protected."
    case keychain = "The vault Keychain item is not available. Open Founderizer Vault to set it up."
    case dependency = "The signed vault programs are not available."
    case hub = "The hub did not confirm this vault job."
    case protection = "The login could not be protected in messages, so it was not used."
    case provider = "Bitwarden refused this login. Check the token and its access."
    case login = "The vault login is not valid."
    // A model provider's own site (`VaultProviderSites`): this vault uses and makes no login there, whoever saved it.
    case modelProvider = "This login is for a model provider's own site, and Fleet uses and makes none: the owner signs in to their own account in their own session."
    case handover = "The handover could not be opened or locked."
    case browser = "Chrome did not confirm the sign-in. Check the page and its permissions."
    case socket = "The vault connection could not start."
    case unscopedCopy = "This sealed copy does not say where it comes from, so it is not used in a project."
    case relabelledCopy = "This sealed copy was made for another handover, so it is not used."
    case sourceMismatch = "The hub and the copy name different source logins, so the login is not handed over."
    // Shared broker callers (protocol 2 `callers`): the exact answers of the contract, the same as the Linux broker's.
    case caller = "the caller fields are not valid"
    case key = "the hub did not accept this agent's key"
    // `create`: a login that the vault makes for an agent's task. One fixed sentence each, without a value.
    case creates = "This machine's vault is not set up to save logins."
    case saveRefused = "Bitwarden refused this save and made nothing."
    case saveUnknown = "The vault could not confirm that Bitwarden saved the login. It is not sent again."
    case saveUnregistered = "The login is saved, but the hub did not register it."
    case notMadeHere = "This vault did not make this login for that request, so it does not use it."
    // The fleet's own store on this Mac, in its own words: a broker opens one store or the other, so no sentence of
    // one store is ever said about the other (`vault.py`'s `says()`).
    case store = "This Mac's vault store could not be opened. Nothing was changed."
    case storeMissing = "This machine's vault store has no such login."
    case storeBusy = "The vault store is in use, so nothing was saved."
    case storeCreates = "This machine's vault has no store of its own yet."
    case storeRefused = "The vault store refused this save and made nothing."
    case storeUnknown = "The vault could not confirm that its store saved the login. It is not sent again."
    case storeNoWrite = "The vault store could not be opened for a save. Nothing was made."
    // `capture`: a key that the vault reads from one field of a Chrome page.
    case captureTab = "No Chrome tab shows that address."
    case captureTabs = "More than one Chrome tab shows that address. Close all but one."
    case captureField = "The selector does not match exactly one field on that page."
    case captureEmpty = "The field is empty."
    case captureUse = "This key was read on another address than the one where it is used. The task that saved it cannot use it there without the owner's grant."
    // `request`: one request that the vault sends with a saved value. "Nothing was sent" is said only when it is certain.
    case callAddress = "This login's address is not HTTPS. Nothing was sent."
    case callHeader = "This saved value cannot be sent as a header. Nothing was sent."
    case callUnreachable = "The service could not be reached. Nothing was sent."
    case callStopped = "This task's requests were stopped. Nothing was sent."
    case callUnknown = "The request may have been sent. Its answer is not known. It is not sent again."
    case callCanceled = "The request was stopped before its answer. The service can have received it. It is not sent again."
    case callRepeated = "This request was already started. It is not sent again."
    // `cancel`: the end of a task attempt's requests, with the proof that their processes are gone.
    case cancelUnproved = "The vault cannot prove that its request ended."
    // `deposit`: a key or a login that the owner typed into Founderizer, sealed there to this machine's vault key.
    case depositBitwarden = "This machine's vault opens a Bitwarden project, so it takes no delivered secret."
    case depositCopy = "The delivered copy cannot be opened with this machine's vault key."
    case depositItem = "The delivered copy holds no valid key or login."
    case depositValue = "The hub did not confirm that this copy holds the value the owner saved, so it was not kept."
    case storeOther = "This machine's vault store holds another value under this reference, so nothing was saved."
    // `withdraw`: a delivered secret leaves this machine's store when no agent of the machine holds it any more. The
    // same sentences as the Linux broker's.
    case withdrawBitwarden = "This machine's vault opens a Bitwarden project, so it holds no delivered secret."
    case withdrawNotDelivered = "This login was not delivered here, so it is not removed."
}

/// The agent that a job acts for at the hub (protocol 2 `callers`): the calling agent with its key, or for a request
/// without caller fields the configured store agent without a credential. The key stays in memory for that one
/// request: no text, mirror or answer of the broker contains it.
public struct VaultCaller: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let agent: String
    let key: String?
    init(agent: String, key: String?) { self.agent = agent; self.key = key }
    /// The header of this caller's hub calls, or nil for a request without a credential.
    var authorization: String? { key.map { "Bearer " + $0 } }
    public var description: String { "VaultCaller(\(agent))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["agent": agent], displayStyle: .struct) }

    /// Byte checks, not a pattern: `$` also matches before a final line end, and a line end must never reach a header.
    static func isAgent(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (2...31).contains(bytes.count) && (0x61...0x7a).contains(bytes[0]) &&
            bytes.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2d }
    }
    static func isKey(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 43 && bytes.allSatisfy {
            (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2d || $0 == 0x5f
        }
    }
}

public struct VaultRequest: Equatable, Sendable {
    public enum Operation: String, Sendable { case status, chrome, signin, handover, probe, create, capture, request, cancel, read, deposit, withdraw }
    public let operation: Operation
    public let job: Int?
    /// The calling agent of a job request on a shared broker, or nil for a request without caller fields.
    public let caller: VaultCaller?
    /// Only for `cancel`: the task attempt whose requests end. A `cancel` names no job.
    let scope: VaultCallScope?

    public init(data: Data) throws {
        guard data.count <= 8192,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.integer(object["v"]) == 2,
              let op = object["op"] as? String, let operation = Operation(rawValue: op) else {
            throw VaultFailure.request
        }
        // A job request may name its caller with both fields or neither; `status` never has them, and a save
        // (`create`, `capture`), a `request`, a `cancel`, a `deposit` and a `withdraw` always. A `read` (owner feature
        // secrets) names no job, the job of a `deposit` (owner feature central_vault) is the number of its delivery, and
        // the job of a `withdraw` (helper feature secret_withdrawals) is the number of its withdrawal.
        let callerFields: Set<String> = ["agent", "agent_key"], keys = Set(object.keys)
        let expected: Set<String>
        switch operation {
        case .status, .read, .chrome: expected = ["v", "op"]
        case .cancel: expected = ["v", "op", "db", "task", "attempt"]
        default: expected = ["v", "op", "job"]
        }
        guard keys.subtracting(operation == .status ? [] : callerFields) == expected else { throw VaultFailure.request }
        let job = Self.integer(object["job"])
        guard [.status, .cancel, .read, .chrome].contains(operation) || (job != nil && job! > 0) else { throw VaultFailure.request }
        var caller: VaultCaller?
        if !keys.isDisjoint(with: callerFields) {
            guard keys.isSuperset(of: callerFields), let agent = object["agent"] as? String, VaultCaller.isAgent(agent),
                  let key = object["agent_key"] as? String, VaultCaller.isKey(key) else { throw VaultFailure.caller }
            caller = VaultCaller(agent: agent, key: key)
        }
        guard ![.create, .capture, .request, .cancel, .deposit, .withdraw].contains(operation) || caller != nil else { throw VaultFailure.caller }
        var scope: VaultCallScope?
        if operation == .cancel {
            guard let caller, let db = object["db"] as? String, db.range(of: generationPattern, options: .regularExpression) != nil,
                  let task = taskText(object["task"]), let attempt = Self.integer(object["attempt"]), attempt > 0,
                  let named = VaultCallScope(db: db, task: task, attempt: attempt, caller: caller) else { throw VaultFailure.request }
            scope = named
        }
        self.operation = operation; self.job = job; self.caller = caller; self.scope = scope
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue > -9_007_199_254_740_991, number.doubleValue < 9_007_199_254_740_991 else { return nil }
        return number.intValue
    }
}

/// What a login that the vault made is bound to: the request, the hub generation, the agent, the task, its attempt,
/// the project and the input. The hub confirms all of it for the job, and again (`created_by`) when a sign-in uses
/// that login in the task that made it. Two kinds of save: `create` (the vault makes the password) and `capture`
/// (the vault reads a key that a service shows in one field of a Chrome page, which `selector` names).
struct VaultCreation: Equatable, Sendable {
    /// What this broker says in a sign-in confirmation: it checks the creation of a made login in its own journal.
    static let version = 1
    enum Kind: String, Sendable { case create, capture }
    var kind = Kind.create
    /// Only for `capture`: the CSS selector of the one field that holds the key.
    var selector: String?
    /// Only for `capture` (`source_url`): the page that shows the key, when it is not on `url`. `url` is the address
    /// where the key is used, and it is the saved item's address.
    var source: String?
    let requestID: String
    let db: String
    let agent: String
    let task: String
    let attempt: Int
    let project: String?
    let label: String
    let username: String
    let url: String

    init(requestID: String, db: String, agent: String, task: String, attempt: Int, project: String?, label: String, username: String, url: String) {
        self.requestID = requestID; self.db = db; self.agent = agent; self.task = task; self.attempt = attempt
        self.project = project; self.label = label; self.username = username; self.url = url
    }

    /// From the hub's fields. The agent, the task and the project are those of the job that carries the fields. A
    /// capture has its selector; a create has none. Fields without `kind` are those of a create.
    init(fields: [String: Any], agent: String, task: String, project: String?) throws {
        func line(_ value: Any?, _ length: ClosedRange<Int>) -> String? {
            guard let text = value as? String, length.contains(text.unicodeScalars.count),
                  text == text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
            else { return nil }
            return text
        }
        guard let id = (fields["request_id"] as? String).flatMap(VaultWriter.canonical),
              let db = fields["db"] as? String, db.range(of: generationPattern, options: .regularExpression) != nil,
              let attempt = VaultRequest.integer(fields["attempt"]), attempt > 0,
              let label = line(fields["label"], 1...60), let username = line(fields["username"], 1...200), let url = line(fields["url"], 1...500),
              let address = URL(string: url), let parts = URLComponents(url: address, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme ?? ""), parts.host?.isEmpty == false, parts.user == nil, parts.password == nil
        else { throw VaultFailure.hub }
        self.init(requestID: id, db: db, agent: agent, task: task, attempt: attempt, project: project, label: label, username: username, url: url)
        guard let kind = fields["kind"] == nil ? .create : (fields["kind"] as? String).flatMap(Kind.init(rawValue:)) else { throw VaultFailure.hub }
        self.kind = kind
        let given = fields["selector"].flatMap { $0 is NSNull ? nil : $0 }
        let page = fields["source_url"].flatMap { $0 is NSNull ? nil : $0 }
        switch kind {
        case .create: guard given == nil, page == nil else { throw VaultFailure.hub }
        case .capture:
            guard let selector = line(given, 1...500) else { throw VaultFailure.hub }
            self.selector = selector
            if let page {
                // The same form as `url`.
                guard let source = line(page, 1...500), let address = URL(string: source),
                      let parts = URLComponents(url: address, resolvingAgainstBaseURL: false), ["https", "http"].contains(parts.scheme ?? ""),
                      parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else { throw VaultFailure.hub }
                self.source = source
            }
        }
    }

    /// The hash that the journal keeps with the save. A capture adds its kind and its selector, and its page when the
    /// page has its own address, so the same request cannot change from one kind to the other, to another field or
    /// to another page. The hash of a create, and of a capture without a page address, has the same fields as before.
    var binding: String {
        var fields: [String: Any] = ["db": db, "agent": agent, "task": task, "attempt": attempt, "project": project ?? NSNull(),
                                     "label": label, "username": username, "url": url]
        if kind == .capture { fields["kind"] = kind.rawValue; fields["selector"] = selector ?? "" }
        if kind == .capture, let source { fields["source_url"] = source }
        let canonical = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    /// The item value with a new password. It is made only for the one create call.
    func value(random: (Int) throws -> [UInt8] = VaultGenerator.secureBytes) throws -> Data {
        try value(password: VaultGenerator.password(random: random))
    }

    /// The item value with a given secret, exactly as it is: a key that the vault read from a page.
    func value(password: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["username": username, "password": password, "url": url],
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The origin of the address where the login is used, as the vault compares it with a page's `location.origin`.
    var origin: String? { URL(string: url).map(VaultLogin.origin(of:)) }

    /// The origin of the page that a capture reads: that of `source_url`, or of `url` without one.
    var readOrigin: String? { URL(string: source ?? url).map(VaultLogin.origin(of:)) }

    /// False for a key that was read on another origin than the one where it is used. The task that saved such a key
    /// gets no use of it from its own save: a capture must not send a site's key to an address that the agent chose.
    /// The owner's grant in a profile and a project is then the way, as for every login.
    var usesItsSource: Bool { origin != nil && origin == readOrigin }
}

/// The hub's confirmation of one save job (`create` or `capture`): a new login that the vault makes for the calling
/// agent's task. For a create the vault generates the password; for a capture it reads the key from the page. Every
/// field comes from this answer, never from the request.
struct VaultCreateJob: Equatable, Sendable {
    let id: Int
    let creation: VaultCreation
    /// The note of the item, by which the vault finds it again: `fleet-create:<agent>:<request_id>`. It is the one
    /// form of a login that a worker's vault makes; the owner's Add secret has its own form.
    var mark: String { Self.mark(agent: creation.agent, requestID: creation.requestID) }

    static func mark(agent: String, requestID: String) -> String { "fleet-create:" + agent + ":" + requestID }

    init(id: Int, creation: VaultCreation) { self.id = id; self.creation = creation }

    init(data: Data, request: VaultRequest, agent: String) throws {
        guard [.create, .capture].contains(request.operation), data.count <= 131_072,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true, object["kind"] as? String == request.operation.rawValue,
              let id = VaultRequest.integer(object["job"]), id == request.job,
              let taskValue = object["task"], let task = (taskValue as? String) ?? VaultRequest.integer(taskValue).map(String.init),
              !task.isEmpty, task.count < 64,
              let project = optionalText(object["project"], projectPattern) else { throw VaultFailure.hub }
        let creation = try VaultCreation(fields: object, agent: agent, task: task, project: project)
        // The hub's mark must be the one of this agent and this request.
        guard object["mark"] as? String == Self.mark(agent: agent, requestID: creation.requestID) else { throw VaultFailure.hub }
        self.init(id: id, creation: creation)
    }
}

/// The task attempt of a request: the hub generation, the agent, the task and its attempt, with the hash of the agent
/// key that came with it. The key itself is not kept. A `cancel` acts only on requests of an equal scope, so only a
/// caller with the same agent key ends a request or stops the requests of an attempt.
struct VaultCallScope: Equatable, Sendable {
    let db: String
    let agent: String
    let task: String
    let attempt: Int
    let key: String

    init?(db: String, task: String, attempt: Int, caller: VaultCaller) {
        guard let key = caller.key else { return nil }
        self.db = db; agent = caller.agent; self.task = task; self.attempt = attempt
        self.key = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The same task attempt, with any key.
    func isAttempt(of other: VaultCallScope) -> Bool {
        db == other.db && agent == other.agent && task == other.task && attempt == other.attempt
    }
}

/// The hub's fields of one `request` job: what the vault sends, and what the request is bound to. Every field comes
/// from the hub's confirmation, never from the request line. The address is not a field: the vault sends only to the
/// origin of the saved login.
struct VaultCall: Equatable, Sendable {
    enum Auth: Equatable, Sendable { case bearer, basic, header(String) }
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    /// The most bytes of a body that is sent, and of an answer that is shown.
    static let maxBody = 65_536
    let requestID: String
    let db: String
    let attempt: Int
    let method: String
    let path: String
    let auth: Auth
    let body: Data?

    init(fields: [String: Any]) throws {
        guard let id = (fields["request_id"] as? String).flatMap(VaultWriter.canonical),
              let db = fields["db"] as? String, db.range(of: generationPattern, options: .regularExpression) != nil,
              let attempt = VaultRequest.integer(fields["attempt"]), attempt > 0,
              let method = fields["method"] as? String, Self.methods.contains(method),
              let path = fields["path"] as? String, Self.isPath(path),
              let auth = (fields["auth"] as? String).flatMap(Self.auth) else { throw VaultFailure.hub }
        var body: Data?
        if let given = fields["body"], !(given is NSNull) {
            guard let text = given as? String, text.utf8.count <= Self.maxBody else { throw VaultFailure.hub }
            if !text.isEmpty { body = Data(text.utf8) }
        }
        requestID = id; self.db = db; self.attempt = attempt; self.method = method; self.path = path; self.auth = auth
        self.body = body
    }

    /// One `/`, then visible ASCII without `\` and `#`. A path cannot name another host: it comes after the origin.
    static func isPath(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (1...2000).contains(bytes.count) && bytes[0] == 0x2f && (bytes.count == 1 || bytes[1] != 0x2f) &&
            bytes.allSatisfy { (0x21...0x7e).contains($0) && $0 != 0x5c && $0 != 0x23 }
    }

    /// `bearer`, `basic` or `header:<Name>`. The name is not one that the request's own framing uses.
    static func auth(_ text: String) -> Auth? {
        if text == "bearer" { return .bearer }
        if text == "basic" { return .basic }
        guard text.hasPrefix("header:") else { return nil }
        let name = String(text.dropFirst(7)), bytes = Array(name.utf8)
        func letter(_ byte: UInt8) -> Bool { (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte) }
        guard (1...64).contains(bytes.count), letter(bytes[0]),
              bytes.allSatisfy({ letter($0) || (0x30...0x39).contains($0) || $0 == 0x2d || $0 == 0x5f }),
              !["host", "authorization", "content-type", "content-length", "transfer-encoding", "connection"].contains(name.lowercased())
        else { return nil }
        return .header(name)
    }

    /// What the curl child gets on its pipes. `lead` is the first config line of a request with a body: curl reads the
    /// body to its end at that line, before it has an address or a value. The config starts with no permitted protocol,
    /// the address is in its line before the last, and only the last line permits one. A config that is cut short thus
    /// sends nothing, or the complete request.
    struct Plan: Sendable {
        let lead: Data?
        let body: Data?
        let config: Data
        /// The forms of the login's protected values that an answer must not show.
        let forms: [Data]
    }

    /// `limit`: the seconds that the transfer can take. `plain`: the hosts that can be reached without TLS (the hub's
    /// private range, as in the vault's configuration).
    func plan(for login: VaultLogin, limit: Int = 60, plain: (String) -> Bool = VaultConfiguration.privateHost) throws -> Plan {
        let origin = login.origin
        guard let parts = URLComponents(string: origin), let scheme = parts.scheme, let host = parts.host, !host.isEmpty,
              origin.utf8.allSatisfy({ (0x21...0x7e).contains($0) && $0 != 0x22 && $0 != 0x5c }) else { throw VaultFailure.login }
        guard scheme == "https" || (scheme == "http" && plain(host)) else { throw VaultFailure.callAddress }
        var basic: String?
        let header: String
        switch auth {
        case .basic:
            // Base64 carries every value, so this form has no rule for the value.
            let token = Data((login.username + ":" + login.password).utf8).base64EncodedString()
            basic = token
            header = "Authorization: Basic " + token
        case .bearer, .header:
            // The value is a header line as it is. A line end or another control character cannot be in one.
            guard !login.password.utf8.contains(where: { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7f }) else { throw VaultFailure.callHeader }
            if case .header(let name) = auth { header = name + ": " + login.password } else { header = "Authorization: Bearer " + login.password }
        }
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\t", with: "\\t") + "\""
        }
        var lines = ["proto = \"-all\"", "silent", "globoff", "http1.1", "noproxy = \"*\"", "max-redirs = 0", "max-time = \(limit)",
                     "connect-timeout = \(min(limit, 15))", "request = \"\(method)\"", "header = \"Accept: application/json\""]
        if body != nil { lines.append("header = \"Content-Type: application/json\"") }
        else if ["POST", "PUT", "PATCH"].contains(method) { lines.append("header = \"Content-Length: 0\"") }
        lines += ["header = " + quoted(header), "write-out = \"%{stderr}fleet %{http_code}\\n\"", "url = " + quoted(origin + path),
                  "proto = \"=\(scheme)\""]
        return Plan(lead: body == nil ? nil : Data("data-binary = \"@-\"\n".utf8), body: body,
                    config: Data((lines.joined(separator: "\n") + "\n").utf8), forms: VaultAnswer.forms(of: login, basic: basic))
    }
}

struct VaultProbeJob: Sendable {
    let id: Int
    let logins: [String]
    init(data: Data, request: VaultRequest) throws {
        guard request.operation == .probe, data.count <= 131_072,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true, object["kind"] as? String == "probe",
              let id = VaultRequest.integer(object["job"]), id == request.job,
              let logins = object["logins"] as? [String], logins.count <= 256,
              Set(logins.map { $0.lowercased() }).count == logins.count,
              logins.allSatisfy({ $0.range(of: "^bws://[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil }) else {
            throw VaultFailure.hub
        }
        self.id = id; self.logins = logins
    }
}

struct VaultProbeResult: Encodable, Equatable, Sendable {
    enum Reason: String, Encodable, Sendable { case ok, bad_format, not_found, no_token, timeout, error }
    let login: String
    let reason: Reason
    var state: String { reason == .ok ? "readable" : "not_readable" }
    enum CodingKeys: String, CodingKey { case login, state, reason }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(login, forKey: .login)
        try fields.encode(state, forKey: .state)
        try fields.encode(reason, forKey: .reason)
    }
    /// An API key (owner feature secrets) has an empty user name.
    static func inspect(login: String, value: Data) -> Self {
        guard value.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any],
              object["username"] == nil || object["username"] is String,
              let password = object["password"] as? String, !password.isEmpty else {
            return Self(login: login, reason: .bad_format)
        }
        return Self(login: login, reason: .ok)
    }
}

/// Which store a vault of this Mac opens: the fleet's own encrypted file on this machine, or a Bitwarden Secrets
/// Manager project. A configuration names one of the two and never both, because then no answer would say which one
/// holds a login. `status` answers this word, so `fleet.py check <agent>` says which store the broker opens.
public enum VaultBackend: String, Codable, Sendable {
    case store, bitwarden
    /// The one word that a configuration of the fleet's own store carries: `"store": "fleet"`.
    public static let fleetStore = "fleet"
}

public struct VaultConfiguration: Codable, Sendable {
    public let agent: String
    public let hub: URL
    /// A Bitwarden project's region, or nil when this vault opens the fleet's own store.
    public let region: String?
    /// `"fleet"` when this vault opens the fleet's own store on this machine, else nil.
    public let store: String?
    public let socket: String
    public let workerUID: UInt32
    enum CodingKeys: String, CodingKey { case agent, hub, region, store, socket; case workerUID = "worker_uid" }

    public var backend: VaultBackend { store == nil ? .bitwarden : .store }
    /// The Bitwarden region of a vault that opens a Bitwarden project. A vault of the fleet's own store has none and
    /// reaches no Bitwarden, so asking for it is a mistake of the caller and not a refusal of the owner's.
    public func bitwardenRegion() throws -> String {
        guard let region else { throw VaultFailure.configuration }
        return region
    }

    public init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["region", "store"].contains(where: { Set(object.keys) == ["agent", "hub", $0, "socket", "worker_uid"] }),
              let config = try? JSONDecoder().decode(Self.self, from: data),
              config.agent.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil,
              config.region == nil || ["eu", "us"].contains(config.region!),
              config.store == nil || config.store == VaultBackend.fleetStore,
              let parts = URLComponents(url: config.hub, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && Self.privateHost(host)),
              config.socket == NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock",
              config.workerUID > 0 else {
            throw VaultFailure.configuration
        }
        self = config
    }

    /// An address of the private range of the hub (100.64.0.0/10): the one place that the vault reaches without TLS.
    static func privateHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { part -> UInt8? in
            guard let byte = UInt8(part), String(byte) == part else { return nil }
            return byte
        }
        return bytes.count == 4 && bytes[0] == 100 && (64...127).contains(bytes[1])
    }
}

private let projectPattern = "^[a-z][a-z0-9-]{1,30}$"
private let secretPattern = "^bws://[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
private let generationPattern = "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"

/// A task as the hub names it: a text, or a number that becomes its text.
private func taskText(_ value: Any?) -> String? {
    guard let value, let task = (value as? String) ?? VaultRequest.integer(value).map(String.init), !task.isEmpty, task.count < 64 else { return nil }
    return task
}

/// A field that is a text of `pattern`, or JSON null or absent (nil). Anything else is not valid.
private func optionalText(_ value: Any?, _ pattern: String) -> String?? {
    guard let value, !(value is NSNull) else { return .some(nil) }
    guard let text = value as? String, text.range(of: pattern, options: .regularExpression) != nil else { return nil }
    return .some(text)
}

public struct VaultJob: Sendable {
    public let id: Int
    public let login: String
    public let task: String
    public let target: String?
    public let recipient: String?
    /// Owner API 1.10 provenance: the project of the job's task and the job's source login (both nil outside a project
    /// or for a copy made before 1.10).
    public let project: String?
    public let source: String?
    let fingerprintSalts: [String: String]
    /// Set when the hub allows this sign-in only because a `create` job of the same task made the login. The vault
    /// then uses the login only when its own journal has that creation with this reference.
    let createdBy: VaultCreation?

    public init(data: Data, request: VaultRequest) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true, object["kind"] as? String == request.operation.rawValue,
              let id = VaultRequest.integer(object["job"]), id == request.job,
              let login = object["login"] as? String,
              login.range(of: "^(bws://[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}|sealed:[0-9]{1,9})$", options: .regularExpression) != nil,
              let taskValue = object["task"],
              let task = (taskValue as? String) ?? VaultRequest.integer(taskValue).map(String.init),
              !task.isEmpty, task.count < 64,
              let salts = object["fingerprint_salts"] as? [String: String],
              ["password", "totp"].allSatisfy({ salts[$0]?.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }) else {
            throw VaultFailure.hub
        }
        guard let project = optionalText(object["project"], projectPattern),
              let source = optionalText(object["source"], secretPattern) else { throw VaultFailure.hub }
        let target = object["target"] as? String
        let recipient = object["recipient"] as? String
        if request.operation == .handover {
            guard let target, target.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil,
                  let recipient, recipient.range(of: "^age1[0-9a-z]{58}$", options: .regularExpression) != nil else {
                throw VaultFailure.hub
            }
        }
        self.id = id; self.login = login; self.task = task; self.target = target; self.recipient = recipient
        self.project = project; self.source = source
        fingerprintSalts = salts
        if let made = object["created_by"], !(made is NSNull) {
            // Only a sign-in or a request of the maker itself: the agent comes with the fields and must be the job's caller.
            guard [.signin, .request].contains(request.operation), let fields = made as? [String: Any], let agent = fields["agent"] as? String,
                  VaultCaller.isAgent(agent) else { throw VaultFailure.hub }
            createdBy = try VaultCreation(fields: fields, agent: agent, task: task, project: project)
        } else { createdBy = nil }
    }
}

/// The hub's record of a sealed copy (`GET /sealed/<n>`, owner API 1.10): the handover job that made it, the project
/// of that job's task, and its source login. Each is nil for a copy made before 1.10.
public struct SealedRecord: Equatable, Sendable {
    public let job: Int?
    public let project: String?
    public let source: String?
    public init(job: Int?, project: String?, source: String?) { self.job = job; self.project = project; self.source = source }
    init(object: [String: Any]) throws {
        let job: Int?
        if object["job"] == nil || object["job"] is NSNull { job = nil }
        else if let value = VaultRequest.integer(object["job"]), value > 0 { job = value }
        else { throw VaultFailure.handover }
        guard let project = optionalText(object["project"], projectPattern),
              let source = optionalText(object["source"], secretPattern) else { throw VaultFailure.handover }
        self.init(job: job, project: project, source: source)
    }
}

/// Provenance inside a sealed copy (vault protocol 2 addition, owner API 1.10). Only the sending broker opened the
/// login, so only it can put the job, project and source into the copy. The receiving broker checks them against the
/// hub's record before any use, so a copy that is sent again under another job, project or source is refused.
enum VaultProvenance {
    static let version = 1

    static func stamp(job: Int, project: String?, source: String?) -> [String: Any] {
        ["v": version, "job": job, "project": project ?? NSNull(), "source": source ?? NSNull()]
    }

    /// The source login of an opened copy, or a refusal. `usingProject`: the project of the job that uses the copy.
    /// A copy without provenance (made before 1.10) is used only when neither the copy nor the using job has a project.
    static func check(payload: Data, record: SealedRecord, usingProject: String?) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw VaultFailure.login }
        guard let made = object["fleet"], !(made is NSNull) else {
            guard record.project == nil, usingProject == nil else { throw VaultFailure.unscopedCopy }
            return nil
        }
        func same(_ value: Any?, _ expected: String?) -> Bool {
            if let expected { return (value as? String) == expected }
            return value is NSNull
        }
        guard let fleet = made as? [String: Any], Set(fleet.keys) == ["v", "job", "project", "source"],
              VaultRequest.integer(fleet["v"]) == version,
              record.job.map({ VaultRequest.integer(fleet["job"]) == $0 }) ?? (fleet["job"] is NSNull),
              same(fleet["project"], record.project), same(fleet["source"], record.source),
              record.project == usingProject else { throw VaultFailure.relabelledCopy }
        return record.source
    }
}

// This value never has an Encodable conformance: only explicit sealed handovers serialize it. An API key (owner feature
// secrets) is a login with an empty user name.
public struct VaultLogin: Sendable {
    let username: String
    let password: String
    let url: URL
    let totp: String?
    let label: String

    public init(data: Data, label: String) throws {
        guard data.count <= 65536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["username"] == nil || object["username"] is String,
              let password = object["password"] as? String, !password.isEmpty,
              let raw = object["url"] as? String, let url = URL(string: raw),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme ?? ""), parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil,
              object["totp"] == nil || object["totp"] is String else { throw VaultFailure.login }
        username = object["username"] as? String ?? ""; self.password = password; self.url = url
        self.totp = object["totp"] as? String; self.label = label
    }

    var origin: String { Self.origin(of: url) }

    static func origin(of url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.host = parts.host?.lowercased()
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string!
    }

    func sealedPayload(provenance: [String: Any]) throws -> Data {
        var object: [String: Any] = ["username": username, "password": password, "url": url.absoluteString, "fleet": provenance]
        if let totp { object["totp"] = totp }
        return try JSONSerialization.data(withJSONObject: object)
    }

    var secret: VaultSecret { VaultSecret(password: password, totp: totp) }
    var protectedValues: [(kind: String, value: String)] { secret.protectedValues }
}

/// The model providers' own sign-in sites, with their subdomains. It is the list `PROVIDER_SITES` of the fleet's
/// `hub.py`, `vault.py` and `fleet.py`, which a test there keeps equal, so a change to one is a change to all four.
/// Fleet holds no provider credential: the owner signs in to their own account in their own session, through the
/// provider's own flow, and that is the condition on which Anthropic permits an operator to host Claude Code. So this
/// vault signs in with, hands over, sends a request with and makes no login on one of them, whoever saved it. An API
/// key of a provider's paid API (console.anthropic.com, platform.claude.com, platform.openai.com) is no such login
/// and stays allowed.
enum VaultProviderSites {
    static let sites = ["claude.ai", "claude.com", "chatgpt.com", "auth.openai.com", "x.ai"]
    /// An API console under one of the sites, where a key is read (`PROVIDER_KEY_SITES`): it stays allowed.
    static let keySites = ["platform.claude.com"]

    /// True for one of the sites or a subdomain of one, in any case and with or without a final dot, unless it is a
    /// console of `keySites` (`provider_site`).
    static func contains(host: String?) -> Bool {
        var name = (host ?? "").lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        func under(_ site: String) -> Bool { name == site || name.hasSuffix("." + site) }
        return sites.contains(where: under) && !keySites.contains(where: under)
    }

    /// The same for the host of an address. No address, or one without a host, is none of them.
    static func contains(address: String?) -> Bool {
        contains(host: address.flatMap { URLComponents(string: $0)?.host })
    }

    /// The login itself, when its address is on none of these sites.
    static func checked(_ login: VaultLogin) throws -> VaultLogin {
        guard !contains(host: URLComponents(url: login.url, resolvingAgainstBaseURL: false)?.host) else { throw VaultFailure.modelProvider }
        return login
    }
}

/// The secret values of an item: a login's password and seed, or an API key (owner feature secrets), which can have
/// no address and is only read. It is never Encodable.
struct VaultSecret: Sendable {
    let password: String
    let totp: String?

    init(password: String, totp: String?) { self.password = password; self.totp = totp }

    /// An item's value: an object with a password that is not empty and an optional seed. No other field is read.
    init(data: Data) throws {
        guard data.count <= 65536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let password = object["password"] as? String, !password.isEmpty,
              object["totp"] == nil || object["totp"] is String else { throw VaultFailure.login }
        self.init(password: password, totp: object["totp"] as? String)
    }

    var protectedValues: [(kind: String, value: String)] {
        var values = [(kind: "password", value: password)]
        if let totp, !totp.isEmpty {
            values.append(("totp", totp))
            let seed = VaultBrowser.canonicalSeed(totp)
            if !seed.utf8.elementsEqual(totp.utf8) { values.append(("totp", seed)) }
        }
        // The owner permits short values without message filtering.
        return values.filter { $0.value.unicodeScalars.count >= 8 }
    }
}

/// One delivery of the hub's (owner feature `central_vault`): the copy that the central vault sealed to
/// this machine's pinned vault key, with the secret's reference, its name and kind, and the salts of its fingerprints.
/// The helper names only the delivery's number; everything here comes from the hub's answer, never from the request.
struct VaultDeposit: Sendable {
    let id: Int
    /// The reference, in lower case: it names one value in every vault of the fleet.
    let login: String
    let title: String
    /// `login` or `api_key`.
    let item: String
    let ciphertext: Data
    let salts: [String: String]

    init(data: Data, request: VaultRequest) throws {
        guard request.operation == .deposit, let job = request.job,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true, object["kind"] as? String == "deposit", VaultRequest.integer(object["job"]) == job,
              let login = object["login"] as? String, login.range(of: secretPattern, options: .regularExpression) != nil,
              let title = object["title"] as? String, VaultLocalStore.isPlainLine(title, 200),
              let item = object["item"] as? String, ["login", "api_key"].contains(item),
              let text = object["ciphertext"] as? String, text.hasPrefix(VaultLocalStore.armour + "\n"), text.utf8.count <= 65_536,
              let salts = object["fingerprint_salts"] as? [String: String],
              ["password", "totp"].allSatisfy({ salts[$0]?.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil })
        else { throw VaultFailure.hub }
        id = job; self.login = login.lowercased(); self.title = title; self.item = item
        ciphertext = Data(text.utf8); self.salts = salts
    }

    /// The id of the reference in this machine's store.
    var storeID: String { String(login.dropFirst(6)) }

    /// The value in an opened copy, as this machine's store keeps it, and its secret values, whose fingerprints the hub
    /// compares with the owner's (`vault.py`'s `delivered`): a login needs its address, and an API key without one
    /// keeps only its password and its seed. Nothing else of the copy is kept, and no refusal says what it held.
    static func value(_ payload: Data, item: String) throws -> (stored: String, secret: VaultSecret) {
        guard payload.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw VaultFailure.depositItem
        }
        var kept: [String: Any]
        if item == "api_key" && object["url"] == nil {
            guard let secret = try? VaultSecret(data: payload) else { throw VaultFailure.depositItem }
            kept = ["password": secret.password]
            if let totp = secret.totp, !totp.isEmpty { kept["totp"] = totp }
        } else {
            guard let login = try? VaultLogin(data: payload, label: "delivery"), let address = object["url"] as? String else {
                throw VaultFailure.depositItem
            }
            kept = ["username": login.username, "password": login.password, "url": address]
            if let totp = login.totp { kept["totp"] = totp }
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: encoded, encoding: .utf8), let secret = try? VaultSecret(data: encoded) else {
            throw VaultFailure.depositItem
        }
        return (text, secret)
    }
}

/// One withdrawal of the hub's (helper feature `secret_withdrawals`): a secret that the owner's vault delivered into
/// this machine's store, and that no agent of this machine holds any more. The helper names only the withdrawal's
/// number; the reference comes from the hub's answer, never from the request.
struct VaultWithdrawal: Sendable {
    let id: Int
    /// The reference, in lower case.
    let login: String

    init(data: Data, request: VaultRequest) throws {
        guard request.operation == .withdraw, let job = request.job,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true, object["kind"] as? String == "withdraw", VaultRequest.integer(object["job"]) == job,
              let login = object["login"] as? String, login.range(of: secretPattern, options: .regularExpression) != nil
        else { throw VaultFailure.hub }
        id = job; self.login = login.lowercased()
    }

    /// The id of the reference in this machine's store.
    var storeID: String { String(login.dropFirst(6)) }
}

/// One API key of the hub's answer to a `read` (owner feature secrets): its reference, its variable name, and the salts
/// of its fingerprints.
struct VaultRead: Equatable, Sendable {
    let login: String
    let env: String
    let salts: [String: String]

    /// The hub's answer: at most 32 keys, each with a reference, a variable name of its own and the two salts.
    static func list(_ data: Data) throws -> [VaultRead] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == true,
              let secrets = object["secrets"] as? [[String: Any]], secrets.count <= 32 else { throw VaultFailure.hub }
        let reads = try secrets.map { item -> VaultRead in
            guard let login = item["login"] as? String, login.range(of: secretPattern, options: .regularExpression) != nil,
                  let env = item["env"] as? String, env.range(of: "^[A-Z][A-Z0-9_]{0,59}$", options: .regularExpression) != nil,
                  let salts = item["fingerprint_salts"] as? [String: String],
                  ["password", "totp"].allSatisfy({ salts[$0]?.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil })
            else { throw VaultFailure.hub }
            return VaultRead(login: login.lowercased(), env: env, salts: salts)
        }
        guard Set(reads.map(\.env)).count == reads.count else { throw VaultFailure.hub }
        return reads
    }
}
