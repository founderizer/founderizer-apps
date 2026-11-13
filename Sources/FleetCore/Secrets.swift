import CryptoKit
import Foundation

/// One secret that the owner adds to the vault (owner feature `secrets`), of one of two kinds and without a name to
/// type. A login: the address of its sign-in page, a user name, a password and an optional authenticator seed; Fleet
/// shows it as "host · user name". An API key: a variable name, the key and an optional service address; Fleet shows it
/// by its variable name. The vault item is the value that every Fleet vault reads, `{username, password, url[, totp]}`:
/// an API key has an empty user name and the key as its password, and it has no `url` without a service address (an
/// agent can then only read it). The title, which is the item's name and the catalog's title, comes from the fields.
/// The rules are those of the vaults and no others: a password has no length rule and no character rule, and it is
/// kept exactly as typed. It is not Codable on purpose: a value must not reach a draft, the outbox or a log through a
/// general encoder. `value()` gives the item value for the vault writer, and nothing else reads the secret fields.
public struct LoginSecret: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case login, apiKey = "api_key" }
    public var kind = Kind.login
    /// A login's sign-in page; an API key's service address, which it can be without.
    public var url = ""
    /// A login's user name. An API key has none.
    public var username = ""
    /// A login's password, or the API key.
    public var password = ""
    /// An authenticator seed (base32) or an `otpauth://` address; empty for a login without one. An API key has none.
    public var totp = ""
    /// An API key's variable name, for example OPENAI_API_KEY. Fleet writes it in capital letters.
    public var env = ""
    public init() {}

    /// The longest item value this form takes: what still seals into a copy the hub carries (`AgeSeal.maxCopy`).
    /// The Mac vault itself reads 65_536 bytes, but a secret is sealed for the vault of every machine that gets it,
    /// and the hub refuses the whole delivery over its own limit — so the shorter of the two is the rule.
    public static let maxValueBytes = AgeSeal.longestSealed(within: AgeSeal.maxCopy)
    /// The longest title of a login in the hub's catalog.
    public static let maxLabel = 60

    private var trimmed: (username: String, url: String, totp: String, env: String) {
        (username.trimmingCharacters(in: .whitespacesAndNewlines), url.trimmingCharacters(in: .whitespacesAndNewlines),
         totp.trimmingCharacters(in: .whitespacesAndNewlines), env.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

    /// The title: "host · user name" for a login, cut to the catalog's length; the variable name for an API key.
    public var title: String {
        let fields = trimmed
        guard kind == .login else { return fields.env }
        let full = "\(URLComponents(string: fields.url)?.host?.lowercased() ?? fields.url) · \(fields.username)"
        return full.unicodeScalars.count <= Self.maxLabel ? full
            : String(String.UnicodeScalarView(full.unicodeScalars.prefix(Self.maxLabel - 1))) + "…"
    }

    /// The variable name of an API key, for the catalog; nil for a login.
    public var variable: String? { kind == .apiKey ? trimmed.env : nil }

    /// Why a vault cannot read this secret, or nil. No text repeats a value.
    public var problem: String? {
        let fields = trimmed
        switch kind {
        case .login:
            if fields.username.isEmpty { return String(l10n: "Give the user name.") }
            if password.isEmpty { return String(l10n: "Give the password.") }
            if !Self.isAddress(fields.url) { return String(l10n: "Give an address that starts with http:// or https://, with a host and no user name.") }
            if !fields.totp.isEmpty && !Self.isSeed(fields.totp) {
                return String(l10n: "The authenticator seed can have only the letters A to Z and the digits 2 to 7, or be an otpauth:// address with such a secret.")
            }
        case .apiKey:
            if !Self.isVariable(fields.env) {
                return String(l10n: "Give a variable name of 1 to \(Self.maxLabel) characters: the letters A to Z, the digits and _, with a letter first.")
            }
            if Self.isReserved(fields.env) { return String(l10n: "\(fields.env) is a name that a session sets itself. Give another name.") }
            if password.isEmpty { return String(l10n: "Give the key.") }
            if !fields.url.isEmpty && !Self.isAddress(fields.url) {
                return String(l10n: "Give a service address that starts with http:// or https://, with a host and no user name, or no address.")
            }
        }
        guard let line = try? line(fields), line.count <= Self.maxValueBytes else {
            return String(l10n: "This secret is too long: a vault's sealed copy takes at most \(Self.maxValueBytes) bytes.")
        }
        return nil
    }

    /// The item value: one JSON object, for the vault writer only.
    public func value() throws -> Data {
        guard problem == nil else { throw HubError.invalidResponse }
        return try line(trimmed)
    }

    private func line(_ fields: (username: String, url: String, totp: String, env: String)) throws -> Data {
        var item = ["username": kind == .login ? fields.username : "", "password": password]
        if kind == .login || !fields.url.isEmpty { item["url"] = fields.url }
        if kind == .login && !fields.totp.isEmpty { item["totp"] = fields.totp }
        return try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The same reading as the Mac vault: the scheme in lower case, a host, and no user part.
    static func isAddress(_ text: String) -> Bool {
        guard let address = URL(string: text), let parts = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return false }
        return ["https", "http"].contains(parts.scheme ?? "") && parts.host?.isEmpty == false && parts.user == nil && parts.password == nil
    }

    /// A variable name as the hub takes it: A to Z, the digits and _, a letter first, at most 60 characters.
    public static func isVariable(_ text: String) -> Bool { text.range(of: "^[A-Z][A-Z0-9_]{0,59}$", options: .regularExpression) != nil }

    /// A name that the start of a session sets or that its runtime reads itself. The hub refuses it for an API key.
    public static func isReserved(_ text: String) -> Bool {
        text.range(of: "^(?:(?:FLEET|BWS|LD|DYLD|ANTHROPIC|CLAUDE|CODEX)_[A-Z0-9_]*|PATH|HOME|SHELL|USER|LOGNAME|TMPDIR|TERM|PWD|IFS|ENV|"
                       + "BASH_ENV|ZDOTDIR|NODE_OPTIONS|PYTHONPATH|PYTHONHOME)$", options: .regularExpression) != nil
    }

    /// A seed that the vaults can make a code from: base32 letters and digits after the vaults' own clean-up (no white
    /// space, "-" or "="), or an `otpauth://` address with such a `secret`. The vaults give a seed no length rule.
    static func isSeed(_ value: String) -> Bool {
        var seed = value
        if value.hasPrefix("otpauth://") {
            seed = URLComponents(string: value.replacingOccurrences(of: "+", with: " "))?.queryItems?.first { $0.name == "secret" }?.value ?? ""
        }
        let clean = seed.uppercased().unicodeScalars.filter {
            !($0.properties.isWhitespace || (0x1c...0x1f).contains($0.value) || $0 == "-" || $0 == "=")
        }
        return !clean.isEmpty && clean.allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) }
    }
}

/// One secret of the hub's catalog (`team.json` `logins`): its title, its kind and, for an API key, its variable name.
/// `protected`: the hub has a fingerprint of the value, so it blocks and masks it in texts. `grants`: the agents that
/// the owner gave it, `{agent: "use" | "read"}` (feature `secret_grants`). A title gives no access.
public struct TeamLogin: Decodable, Equatable, Sendable {
    public let title: String
    public let protected: Bool?
    /// `login` or `api_key`; nil from an older hub: a login.
    public let kind: String?
    public let env: String?
    public let grants: [String: String]?

    public init(title: String, protected: Bool?, kind: String? = nil, env: String? = nil, grants: [String: String]? = nil) {
        self.title = title; self.protected = protected; self.kind = kind; self.env = env; self.grants = grants
    }

    public var isAPIKey: Bool { kind == "api_key" }
    /// What Fleet shows: an API key by its variable name, a login by its title ("host · user name").
    public var name: String { isAPIKey ? env ?? title : title }
}

/// **What the hub's catalog has under the name of a secret that Add secret saves.** An API key is known by its
/// variable name, among the API keys only: the list takes no second key of one name (the owner, 13 November 2026:
/// "having 2 keys named the same should not be possible"), so the one that is there is the key whose value the save
/// replaces. A login is known by its title, among all entries, and can stand two times, as before.
public enum SecretNameHeld: Equatable, Sendable {
    /// Nothing of that name: a new secret.
    case none
    /// One API key of that variable name: the save replaces its value, under its own reference.
    case key(String, TeamLogin)
    /// Two or more API keys of that name, from before the list refused a second one: the form cannot know which.
    case twice
    /// A login, and the list has that title: a second one, as before.
    case second

    /// `but`: the reference of the form's own save that the hub did not confirm, which is no other secret.
    public static func of(_ title: String, kind: LoginSecret.Kind, in catalog: [String: TeamLogin], but: String? = nil) -> SecretNameHeld {
        if kind == .apiKey {
            let keys = catalog.filter { $0.value.isAPIKey && $0.value.name == title && $0.key != but }.sorted { $0.key < $1.key }
            return keys.isEmpty ? .none : keys.count == 1 ? .key(keys[0].key, keys[0].value) : .twice
        }
        return catalog.contains { $0.value.name == title && $0.key != but } ? .second : .none
    }
}

/// **"Who can use it" when Add secret replaces the value of a key.** The key has its agents already, so the rows show
/// each agent's level of now, and a level that the owner does not touch stays as it is: only a row that he set himself,
/// or that a request proposes, makes a step. A row that he sets to no access takes the key back from that agent, as on
/// the key's own page. (The coordinator's follow-up of 13 November 2026: the rows said "No access" for an agent that
/// had the key.)
public enum SecretReplaceAccess {
    /// A level of the catalog's grants (`"use"`, `"read"`), or nil for none and for a word that the app does not know.
    static func level(_ text: String?) -> SecretGrant? { text.flatMap(SecretGrant.init(rawValue:)) }

    /// The higher of two levels: reads it is more than uses it, and each is more than none.
    static func higher(_ one: SecretGrant?, _ other: SecretGrant?) -> SecretGrant? {
        one == .read || other == .read ? .read : one ?? other
    }

    /// The rows of the form at the Save that shows the orange line, and the agents whose row counts as set by the
    /// owner from then on.
    ///
    /// - What was set before the levels were shown never takes a level down: each row said "No access" then, also
    ///   for an agent that had the key, so nothing that was set then was a choice against a level of now. A row that
    ///   he set himself to a level (`touched`), and a row that a request proposes (`proposed`), show the higher of
    ///   that level and the level of now. A row that he set to no access then does not count as set.
    /// - He takes a key back, or a level down, in a row that shows the level of now: such a change stays as he made
    ///   it (`changes`).
    /// - Each other agent of `holders` shows its level of now (`now`: the catalog entry's grants), or none.
    /// - A row of `set` that is no holder's (the door's, in a request) stays as it is.
    ///
    /// `raised` has his own pick for each row of his that shows a higher level than he picked. That higher level is
    /// this key's, and no pick of his: when the name names this key no more, his pick comes back (`own`), so that a
    /// new key never gets a level that the form put into a row.
    public static func rows(now: [String: String]?, holders: [String], set: [String: SecretGrant], touched: Set<String>,
                            proposed: Set<String> = [])
        -> (rows: [String: SecretGrant], touched: Set<String>, raised: [String: SecretGrant]) {
        var rows = set, raised: [String: SecretGrant] = [:]
        let kept = touched.filter { set[$0] != nil }
        for agent in holders {
            let held = level(now?[agent])
            rows[agent] = kept.contains(agent) || proposed.contains(agent) ? higher(set[agent], held) : held
            if kept.contains(agent), let pick = set[agent], rows[agent] != pick { raised[agent] = pick }
        }
        return (rows, kept, raised)
    }

    /// The rows as the owner and the request set them, when the name is no longer the key's whose levels the rows
    /// show: a row that he set is his pick again where the form had raised it (`raised`) and stays as it is
    /// otherwise, a row that the request proposes is its proposal again (`proposal`), and each other agent's row is
    /// empty. A row that is no holder's stays as it is.
    public static func own(rows: [String: SecretGrant], holders: [String], touched: Set<String>, raised: [String: SecretGrant],
                           proposal: [String: SecretGrant], proposed: Set<String>) -> [String: SecretGrant] {
        var own = rows
        for agent in holders {
            if touched.contains(agent) {
                if let pick = raised[agent] { own[agent] = pick }
            } else {
                own[agent] = proposed.contains(agent) ? proposal[agent] : nil
            }
        }
        return own
    }

    /// The steps of the Save that replaces: one for each agent of `holders` whose row is set (by the owner, `set`, or
    /// by a request's proposal, `proposed`) to another level than its level of now, in the order of `holders`.
    /// `grant` nil takes the key back. A row that is not set makes no step, also when the agent's level changed
    /// somewhere else since the rows were shown. A proposal still takes no level down here: `now` is read again at
    /// this Save, and an agent whose level went up meanwhile keeps it. A row of his that the form raised (`raised`:
    /// his own pick) gives the agent at most what he picked: the higher level in the row was the agent's own, and
    /// when the agent has it no more at this Save, the row's level is nobody's choice.
    public static func changes(now: [String: String]?, holders: [String], rows: [String: SecretGrant], set: Set<String>,
                               proposed: Set<String> = [], raised: [String: SecretGrant] = [:]) -> [(agent: String, grant: SecretGrant?)] {
        holders.compactMap { agent in
            let held = level(now?[agent])
            if set.contains(agent), raised[agent] == nil { return rows[agent] == held ? nil : (agent, rows[agent]) }
            guard set.contains(agent) || proposed.contains(agent) else { return nil }
            let wanted = higher(raised[agent] ?? rows[agent], held)
            return wanted == held ? nil : (agent, wanted)
        }
    }
}

extension LoginSecret {
    /// The most titles that the hub's catalog holds.
    public static let maxCatalog = 256

    /// A login reference in the hub's one spelling: `bws://<uuid>` in lower case.
    public static func isReference(_ text: String) -> Bool {
        text.range(of: "^bws://[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }
}

/// `GET /ui/secrets/salts`: the salts for the fingerprints of one login reference. A salt is no secret. Fleet Vault's
/// writer makes the fingerprints from them; a save into the central vault makes them here, in the form's memory, and
/// the central vault makes them again from what it opens and keeps the value only when the two agree.
public struct SecretSalts: Decodable, Equatable, Sendable {
    public let login: String
    public let password: String
    public let totp: String
    public var isValid: Bool {
        LoginSecret.isReference(login) && [password, totp].allSatisfy { $0.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }
    }
    /// The salts as the writer takes them.
    public func data() throws -> Data { try JSONSerialization.data(withJSONObject: ["password": password, "totp": totp], options: [.sortedKeys]) }
}

/// One salted fingerprint of a login's value, as the vault writer gives it and the hub takes it. It is not the value.
public struct SecretFingerprint: Equatable, Sendable {
    public let kind: String
    public let hash: String
    public let len: Int
    public init(kind: String, hash: String, len: Int) { self.kind = kind; self.hash = hash; self.len = len }

    /// The hub's rule for one registration: one to three items, at most one `password` and two `totp`, each with a
    /// hash of 64 lowercase hex characters and a length of 8 or more.
    public static func areValid(_ items: [SecretFingerprint]) -> Bool {
        (1...3).contains(items.count) && items.filter { $0.kind == "password" }.count <= 1 && items.filter { $0.kind == "totp" }.count <= 2 &&
            items.allSatisfy { ["password", "totp"].contains($0.kind) && $0.len >= 8 &&
                $0.hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    }

    /// The fingerprints of one item value (`LoginSecret.value()`), exactly as every vault makes them (`vault.py`
    /// `fingerprints`): the password, the seed as typed, and the seed in its canonical form when that differs, each
    /// SHA-256 of its salt and the value, and each only when it has 8 or more characters and no white space, because
    /// only such a value can be found in a text. A length is Python's, in code points. The central vault makes them
    /// again from what it opens and refuses a value whose own fingerprints are not these, so one rule in two languages
    /// must give one answer. Nothing of the value is in the result.
    public static func of(_ value: Data, salts: SecretSalts) throws -> [SecretFingerprint] {
        guard let item = try? JSONSerialization.jsonObject(with: value) as? [String: Any],
              let password = item["password"] as? String, !password.isEmpty else { throw HubError.invalidResponse }
        var values = [("password", password)]
        if let totp = item["totp"] as? String, !totp.isEmpty {
            values.append(("totp", totp))
            let seed = canonicalSeed(totp)
            if !seed.unicodeScalars.elementsEqual(totp.unicodeScalars) { values.append(("totp", seed)) }
        }
        return values.filter { $0.1.unicodeScalars.count >= 8 && !$0.1.unicodeScalars.contains(where: isWhitespace) }.map { kind, text in
            let digest = SHA256.hash(data: Data(((kind == "password" ? salts.password : salts.totp) + text).utf8))
            return SecretFingerprint(kind: kind, hash: digest.map { String(format: "%02x", $0) }.joined(), len: text.unicodeScalars.count)
        }
    }

    /// Python's white space (`str.isspace`, `\s`): Unicode's, and the four ASCII separators U+001C to U+001F.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1c...0x1f).contains(scalar.value)
    }

    /// `vault.py`'s `canonical_seed`: the `secret` of an `otpauth://` address, read as Python's `urlsplit` and
    /// `parse_qs` read it, or the value itself; then without white space, "=" and "-", in upper case.
    static func canonicalSeed(_ value: String) -> String {
        var seed = value
        if value.hasPrefix("otpauth://") {
            // urlsplit drops tabs and line ends anywhere; the fragment goes at the first "#", and the query starts at
            // the first "?" before it. parse_qs keeps the "&" pairs that have a "=" and something after it, reads "+"
            // as a space and then the %-escapes as UTF-8, and the first value of `secret` wins.
            let address = String(String.UnicodeScalarView(value.unicodeScalars.filter { !["\t", "\r", "\n"].contains($0) }))
            let head = address.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let query = head.firstIndex(of: "?").map { head[head.index(after: $0)...] } ?? ""
            seed = ""
            for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
                guard let equals = pair.firstIndex(of: "="), pair.index(after: equals) < pair.endIndex,
                      unescaped(pair[..<equals]) == "secret" else { continue }
                seed = unescaped(pair[pair.index(after: equals)...])
                break
            }
        }
        let kept = seed.unicodeScalars.filter { !isWhitespace($0) && $0 != "=" && $0 != "-" }
        return String(String.UnicodeScalarView(kept)).uppercased()
    }

    /// One part of a query as Python's `unquote_plus` reads it: "+" is a space, a "%" with two hex digits is one byte,
    /// any other "%" stays as it is, and the bytes are UTF-8, each broken sequence read as U+FFFD.
    private static func unescaped(_ part: Substring) -> String {
        let bytes = Array(part.replacingOccurrences(of: "+", with: " ").utf8)
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var out: [UInt8] = [], index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let high = digit(bytes[index + 1]), let low = digit(bytes[index + 2]) {
                out.append(high << 4 | low); index += 3
            } else {
                out.append(bytes[index]); index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// The two owner commands of Add secret (1.3 commands with a `request_id`). They are not `OwnerCommand` cases on
/// purpose: Fleet sends them at once and never keeps them in the outbox. The vault writer's journal is the record
/// that lets Fleet continue after a restart.
public enum SecretCommand {
    /// `POST /ui/secrets/fingerprints`. No value, salt or title is in it.
    public static func fingerprints(requestID: UUID, database: String, login: String, items: [SecretFingerprint]) throws -> Data {
        guard LoginSecret.isReference(login), SecretFingerprint.areValid(items) else { throw HubError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: [
            "request_id": requestID.uuidString.lowercased(), "db": database, "login": login,
            "fingerprints": items.map { ["kind": $0.kind, "hash": $0.hash, "len": $0.len] as [String: Any] }], options: [.sortedKeys])
    }

    /// `POST /ui/team/logins`: the title of one reference, on the `team.json` that has this hash.
    public static func title(requestID: UUID, database: String, sha256: String, login: String, title: String) throws -> Data {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LoginSecret.isReference(login), sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (1...LoginSecret.maxLabel).contains(title.unicodeScalars.count), !title.contains(where: \.isNewline) else { throw HubError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: [
            "request_id": requestID.uuidString.lowercased(), "db": database, "base_sha256": sha256, "login": login, "title": title],
            options: [.sortedKeys])
    }

    /// `POST /ui/team/logins` with `delete`: one reference leaves the catalog, on the `team.json` that has this hash. The
    /// value stays in the vaults. The hub refuses while a grant, a profile or a project lists the reference.
    public static func removal(requestID: UUID, database: String, sha256: String, login: String) throws -> Data {
        guard LoginSecret.isReference(login), sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw HubError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: [
            "request_id": requestID.uuidString.lowercased(), "db": database, "base_sha256": sha256, "login": login, "delete": true],
            options: [.sortedKeys])
    }
}

/// The receipt of a secrets command. `stored` and `known` are of a fingerprints command; `sha256`, `changed` and
/// `deleted` are of a title command.
public struct SecretReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let login: String
    public let stored: Int?
    public let known: Int?
    public let sha256: String?
    public let changed: Bool?
    public let deleted: Bool?
    public func matches(requestID: UUID, client: String, login: String) -> Bool {
        ok && request_id == requestID.uuidString.lowercased() && self.client == client && self.login == login
    }
}

/// One agent's grant of one secret (feature `secret_grants`). `use`: the agent's vault uses the secret for the agent
/// (`sign_in`, `call_api`), and the agent never sees it. `read`: an API key that the agent also reads, by its variable
/// name, in the environment of its sessions.
public enum SecretGrant: String, Equatable, Sendable { case use, read }

extension SecretCommand {
    /// `POST /ui/secrets/add`: after the writer made the item, its fingerprints and its catalog entry in one command.
    /// No value and no salt is in it. `variable` for an API key only.
    public static func add(requestID: UUID, database: String, login: String, title: String, kind: LoginSecret.Kind, variable: String?,
                           fingerprints items: [SecretFingerprint]) throws -> Data {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LoginSecret.isReference(login), (1...LoginSecret.maxLabel).contains(title.unicodeScalars.count), !title.contains(where: \.isNewline),
              (kind == .apiKey) == (variable != nil), variable.map({ LoginSecret.isVariable($0) && !LoginSecret.isReserved($0) }) ?? true,
              items.isEmpty || SecretFingerprint.areValid(items) else { throw HubError.invalidResponse }
        var body: [String: Any] = ["request_id": requestID.uuidString.lowercased(), "db": database, "login": login, "title": title,
                                   "kind": kind.rawValue, "fingerprints": items.map { ["kind": $0.kind, "hash": $0.hash, "len": $0.len] as [String: Any] }]
        body["env"] = variable
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// `POST /ui/secrets/grant`: one agent's grant of one secret. nil takes the grant back.
    public static func grant(requestID: UUID, database: String, login: String, agent: String, grant: SecretGrant?) throws -> Data {
        guard LoginSecret.isReference(login), agent.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil else {
            throw HubError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: ["request_id": requestID.uuidString.lowercased(), "db": database, "login": login,
                                                           "agent": agent, "grant": grant.map { $0.rawValue as Any } ?? NSNull()], options: [.sortedKeys])
    }
}

/// The receipt of `POST /ui/secrets/add`: the fingerprints that were new and known, and whether the catalog changed.
public struct SecretAddReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let login: String
    public let stored: Int
    public let known: Int
    public let changed: Bool
}

/// The receipt of `POST /ui/secrets/grant`. `vault`: the agent's vault access, when the grant had something to do
/// with it: turned on, or still off with the reasons (`missing`, the codes of `vault_grant`).
public struct SecretGrantReceipt: Decodable, Sendable {
    public struct Access: Decodable, Equatable, Sendable {
        public let before: String
        public let after: String
        public let missing: [String]?
    }
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let login: String
    public let agent: String
    public let grant: String?
    public let changed: Bool
    public let vault: Access?
}

/// The two commands of the Secrets page, sent at once and never kept in the outbox, as the other commands of Add
/// secret: the hub's receipt is the record, and the same click again gives the same result.
public final class SecretsClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20      // a change commits team.json at the hub
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    /// The hub step of a made item: its fingerprints, then its catalog entry, in one command and one commit.
    public func add(hub: URL, database: String, client: String, login: String, title: String, kind: LoginSecret.Kind, variable: String?,
                    fingerprints: [SecretFingerprint]) async throws -> SecretAddReceipt {
        let id = UUID()
        let body = try SecretCommand.add(requestID: id, database: database, login: login, title: title, kind: kind, variable: variable,
                                         fingerprints: fingerprints)
        let receipt = try JSONDecoder().decode(SecretAddReceipt.self, from: await command("ui/secrets/add", hub: hub, client: client, body: body))
        guard receipt.ok, receipt.request_id == id.uuidString.lowercased(), receipt.client == client, receipt.login == login,
              receipt.stored >= 0, receipt.known >= 0, receipt.stored + receipt.known == fingerprints.count else { throw HubError.invalidResponse }
        return receipt
    }

    /// One agent's grant of one secret; nil takes it back.
    public func grant(hub: URL, database: String, client: String, login: String, agent: String, grant: SecretGrant?) async throws -> SecretGrantReceipt {
        let id = UUID()
        let body = try SecretCommand.grant(requestID: id, database: database, login: login, agent: agent, grant: grant)
        let receipt = try JSONDecoder().decode(SecretGrantReceipt.self, from: await command("ui/secrets/grant", hub: hub, client: client, body: body))
        guard receipt.ok, receipt.request_id == id.uuidString.lowercased(), receipt.client == client, receipt.login == login,
              receipt.agent == agent, receipt.grant == grant?.rawValue else { throw HubError.invalidResponse }
        return receipt
    }

    /// One read of the Secrets routes: the hub's own words on a refusal.
    private func read(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Unexpected HTTP response."
            throw HubError.refusal(response.statusCode, String(message.prefix(500)))
        }
        guard data.count <= 1_048_576 else { throw HubError.invalidResponse }
        return data
    }

    private func command(_ route: String, hub: URL, client: String, body: Data) async throws -> Data {
        var request = URLRequest(url: hub.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Unexpected HTTP response."
            throw HubError.refusal(response.statusCode, String(message.prefix(500)))
        }
        return data
    }
}

/// One agent's permission to make new logins with `create_login` (owner feature `login_create`). It is off until the
/// owner turns it on, and a project task needs the project's `create_logins` too. The vault of the agent's machine
/// makes the password; the agent gets the login's reference only. The permission gives no use of another login.
public struct LoginCreateControl: Equatable, Sendable {
    public static let feature = "login_create"
    public enum Action: Equatable, Sendable { case grant, revoke }
    public let status: String?
    public let action: Action?
    /// Why the permission cannot be given now, in ordinary words, in the hub's order.
    public let reasons: [String]

    /// `role`, `permitted` (`vault_create`) and `grant` (`vault_create_grant`) come from the agent's team line;
    /// `offered`: the hub has `login_create`. Without the feature nothing shows and nothing is sent.
    public init(role: String?, permitted: Bool?, offered: Bool, grant: VaultGrant?) {
        guard offered, ["worker", "lead"].contains(role ?? ""), let permitted else { status = nil; action = nil; reasons = []; return }
        if permitted {
            status = "Can save new logins."; action = .revoke; reasons = []
        } else {
            status = "Cannot save new logins."
            action = grant?.ready == true ? .grant : nil
            reasons = grant?.ready == false ? (grant?.missing ?? []).map(Self.reason) : []
        }
    }

    /// The hub's `vault_create_grant.missing` codes as facts.
    public static func reason(_ code: String) -> String {
        switch code {
        case "no_broker_access": return "This agent does not use its server's vault."
        case "helper_without_login_create": return "Founderizer on its server is not updated for new logins yet."
        case "broker_status_unknown": return "Founderizer has no recent vault status from its server."
        case "broker_without_creates": return "Set up this server's vault to save new logins."
        default: return "Founderizer cannot give this permission now."
        }
    }
}

/// A login that an agent made with `create_login`, or a key that it saved with `save_key` (`created_logins` of
/// `GET /ui/team`). `login` is null until the vault reported the item. `labelled`: the owner's catalog has the
/// reference. A made login gives no grant for a later task: the owner adds it to a profile, and to a project's
/// logins, as for every login.
public struct CreatedLogin: Decodable, Equatable, Identifiable, Sendable {
    public let login: String?
    public let label: String
    public let username: String
    /// The address where the login is used. It is the saved item's address.
    public let url: String
    /// `create` (the vault made the password) or `capture` (the vault read a key from a page). nil from a hub that
    /// does not give it: such a row is a create.
    public let kind: String?
    /// Only for a capture: the page that showed the key, when the agent gave it. nil: the key was read on `url`.
    public let source_url: String?
    public let agent: String
    public let task: String
    public let project: String?
    /// `waiting`, `created`, `unknown` or `failed`.
    public let state: String
    public let created_at: Double
    public let labelled: Bool
    public let protected: Bool
    public var id: String { login ?? "\(agent)/\(task)/\(created_at)/\(label)" }
    public var isCapture: Bool { kind == "capture" }
    /// The page that showed the key, only when it is another address than the one where the key is used. What
    /// counts for the use is the origin (scheme, host and port), not the path: only when the page has another
    /// origin than `url` does the task that saved the key get no use of it there without the owner's grant.
    public var sourcePage: String? { source_url == url ? nil : source_url }
}

// MARK: secret requests and deliveries (owner features `secret_requests` and `secret_deliveries`)

/// What one secret request asks for (owner feature `secret_requests`): an API key by its variable name, or a login
/// for a sign-in page, the agents that the agent who asked proposes and how each would hold it, and after the
/// answer the reference that answered it. It names a secret and never holds a value. A field the app cannot read is
/// left out rather than failing the fleet's state.
public struct NeedSecret: Decodable, Equatable, Sendable {
    public let kind: LoginSecret.Kind
    /// An API key's variable name.
    public let env: String?
    /// A login's sign-in page, or the address an agent calls with an API key, with https://.
    public let site: String?
    /// The proposal: `use` lets the agent's vault use it for the agent, `read` puts an API key into its sessions.
    public let give: [String: SecretGrant]
    /// The reference of the secret that answered the request.
    public let saved: String?

    public init(kind: LoginSecret.Kind, env: String? = nil, site: String? = nil, give: [String: SecretGrant] = [:], saved: String? = nil) {
        self.kind = kind; self.env = env; self.site = site; self.give = give; self.saved = saved
    }

    private enum Keys: String, CodingKey { case kind, env, site, give, saved }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: Keys.self)
        // The hub's own default: a request that names no kind asks for an API key.
        kind = (try? data.decodeIfPresent(String.self, forKey: .kind)).flatMap { LoginSecret.Kind(rawValue: $0) } ?? .apiKey
        env = (try? data.decodeIfPresent(String.self, forKey: .env)).flatMap { LoginSecret.isVariable($0) ? $0 : nil }
        site = (try? data.decodeIfPresent(String.self, forKey: .site)).flatMap { LoginSecret.isAddress($0) ? $0 : nil }
        give = ((try? data.decodeIfPresent([String: String].self, forKey: .give)) ?? [:])
            .compactMapValues(SecretGrant.init(rawValue:))
        saved = (try? data.decodeIfPresent(String.self, forKey: .saved)).flatMap { LoginSecret.isReference($0) ? $0 : nil }
    }

    /// What the request asks for, in a few words: "the API key STRIPE_SECRET_KEY", "a login for dashboard.stripe.com".
    public var asked: String {
        if kind == .apiKey { return "the API key \(env ?? "")" }
        return site.flatMap { URLComponents(string: $0)?.host }.map { "a login for \($0)" } ?? "a login"
    }

    /// Whether a saved secret's title fits this request: an API key by its variable name, a login by its host. A save
    /// that does not fit is never offered as its answer.
    public func fits(title: String) -> Bool {
        switch kind {
        case .apiKey: return env != nil && title == env
        case .login:
            let host = site.flatMap { URLComponents(string: $0)?.host?.lowercased() }
            return host.map { title.hasPrefix($0 + " · ") } ?? title.contains(" · ")
        }
    }
}

extension SecretCommand {
    /// `POST /ui/needs/<id>/secret`: the answer of one secret request, with the reference of the secret that answers
    /// it, or a decline with the owner's own words or none. No value is in it, and the words that reach the agent are
    /// the hub's own.
    public static func answer(requestID: UUID, database: String, login: String?, decline: String?) throws -> Data {
        guard (login == nil) != (decline == nil), login.map(LoginSecret.isReference) ?? true,
              decline.map({ $0.count <= 300 && !$0.contains(where: \.isNewline) }) ?? true else { throw HubError.invalidResponse }
        var body: [String: Any] = ["request_id": requestID.uuidString.lowercased(), "db": database]
        body["login"] = login
        body["decline"] = decline?.trimmingCharacters(in: .whitespaces)
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// The receipt of `POST /ui/needs/<id>/secret`: the words that the agent got, which are the hub's own.
public struct SecretAnswerReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let need: Int
    public let login: String?
    public let answer: String
}

extension SecretsClient {
    /// The answer of one secret request with a secret of the catalog. The same `requestID` again gives the same
    /// answer, so a retry after no reply is safe.
    public func answer(hub: URL, database: String, client: String, need: Int, requestID: UUID, login: String) async throws -> SecretAnswerReceipt {
        try await answer(hub: hub, database: database, client: client, need: need, requestID: requestID, login: login, decline: nil)
    }

    /// The owner says no to one secret request, with his own words or none.
    public func decline(hub: URL, database: String, client: String, need: Int, requestID: UUID, words: String) async throws -> SecretAnswerReceipt {
        try await answer(hub: hub, database: database, client: client, need: need, requestID: requestID, login: nil, decline: words)
    }

    private func answer(hub: URL, database: String, client: String, need: Int, requestID: UUID, login: String?,
                        decline: String?) async throws -> SecretAnswerReceipt {
        let body = try SecretCommand.answer(requestID: requestID, database: database, login: login, decline: decline)
        let receipt = try JSONDecoder().decode(SecretAnswerReceipt.self, from: await command("ui/needs/\(need)/secret", hub: hub, client: client, body: body))
        guard receipt.ok, receipt.request_id == requestID.uuidString.lowercased(), receipt.client == client, receipt.need == need,
              receipt.login == login else { throw HubError.invalidResponse }
        return receipt
    }
}
