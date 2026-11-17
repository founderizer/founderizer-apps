import Foundation

/// **The key swap's own step on each Linux server** (Part B of the changed key swap, app patch 2; the design agreed by
/// the manager on 16 November 2026, with its four changes). The vault program of each server has its own root step,
/// `vault.py configure` (VAULT.md, "The switch"). This Mac runs it over its SSH connection, as root, one server at a
/// time, and sends what the step read to the hub (`POST /ui/servers/<server>/key-swap-reading`).
///
/// Two steps, each with its own answer: first the owner keys and the fleet (`--swap keep`, which never switches, and
/// whose answer is the reading), then the switch (`--swap on` or `--swap off`), only when the table wants it and only
/// after a keys step whose answer holds each key and the fleet. A put-back of the switch (`"undone": true`) holds each
/// switch to on, on every server, until that hold ends. Everything here is pure, so that what the app does without
/// asking is written in one place and tested there; the model runs it, and keeps the record on the disk.
public enum KeySwapPlan {
    /// The hub's feature of the two records and the reading's route (owner API 1.183): without it, no step runs.
    public static let feature = "key_swap_reading"
    /// A step that failed is tried again after this long, at most `most` times in a row (the owner's rule C3).
    public static let wait: Double = 600
    public static let most = 6
    /// Then one try each hour, for ever (C3).
    public static let hourly: Double = 3600
    /// A server that the lock of another step stopped is tried after the others, for this long.
    public static let lockedFor: Double = 60

    /// **What the table wants on one server** (the design, section 3), or nil for a row that gets no step: a Mac, a row
    /// that has not joined, the hub's own machine, a server that the owner removed on this Mac, and a row whose key
    /// swap fields this app cannot read (a hub before them). `central` is false when this Mac has no list of the owner
    /// keys: then only the reading runs, and no switch (change 4).
    public static func wanted(_ row: KeySwapServer, central: Bool, removed: Set<String> = []) -> KeySwapWanted? {
        guard row.kind == "linux", row.joined, !row.hub, !removed.contains(row.name), let word = row.word else { return nil }
        let swaps = word
        switch row.wish {
        case .off?:
            return KeySwapWanted(switchTo: swaps && central ? .off : nil, waitsForTheOwner: false)
        case .on?:
            return KeySwapWanted(switchTo: !swaps && central ? .on : nil, waitsForTheOwner: false)
        case nil:
            guard let waits = row.waits else { return KeySwapWanted(switchTo: nil, waitsForTheOwner: false) }
            if !waits.isEmpty && !swaps { return KeySwapWanted(switchTo: nil, waitsForTheOwner: true) }
            return KeySwapWanted(switchTo: !swaps && central ? .on : nil, waitsForTheOwner: false)
        }
    }

    /// The rows that can get a step, in the order of the roll-out: no agent first, then by the number of agents, then
    /// by name (the design, section 2).
    public static func order(_ rows: [KeySwapServer]) -> [KeySwapServer] {
        rows.sorted { ($0.agents.count, $0.name) < ($1.agents.count, $1.name) }
    }

    /// A put-back's hold stands on this server: its program and the owner's wish are those of the hold.
    public static func holds(_ row: KeySwapServer, _ record: KeySwapRecord?) -> Bool {
        guard let record, let hold = record.hold else { return false }
        return record.program == hold.program && row.wish?.rawValue == hold.wish
    }

    /// **The one step to run now**, or nil (the design, sections 2 to 4). A row needs a step when it has no reading
    /// on record, when the table wants a switch that the word does not say, when the central vault's owner keys or
    /// fleet are not all in this Mac's last good keys step there, when the hub's release has another `vault.py` than
    /// the one of its last step (at most once in `wait`), or when its pin's weekly re-sign is due. It runs when its
    /// tries let it. While a put-back's hold stands on any server, no step switches to on (change 2): the keys steps
    /// and the readings go on, and a switch to off, which the owner wished, goes on too.
    public static func next(_ rows: [KeySwapServer], facts: KeySwapFacts) -> KeySwapStep? {
        let central = facts.central
        let held = rows.contains { holds($0, facts.records[$0.name]) }
        var later: KeySwapStep?
        for row in order(rows) {
            guard let wanted = wanted(row, central: central != nil, removed: facts.removed) else { continue }
            let record = facts.records[row.name]
            var switchTo = wanted.switchTo
            if switchTo == .on && held { switchTo = nil }
            let keysMissing = central.map { central in
                !Set(central.ownerKeys).isSubset(of: Set(record?.keys ?? [])) || record?.fleet != central.fleet
            } ?? false
            let newProgram = facts.hubProgram.map { program in
                record?.program != program && facts.now - (record?.at ?? 0) >= wait
            } ?? false
            let needs = row.readAt == nil || switchTo != nil || keysMissing || newProgram
                || facts.resignDue.contains(row.name)
            guard needs, record?.tries?.isDue(at: facts.now) ?? true else { continue }
            let step = KeySwapStep(server: row.name, keys: central?.ownerKeys ?? [], fleet: central?.fleet,
                                   then: switchTo)
            if let locked = record?.lockedAt, facts.now - locked < lockedFor {
                later = later ?? step           // after the others' turn
                continue
            }
            return step
        }
        return later
    }

    /// The switch may follow the keys step: the step's answer holds each owner key of the central vault and a fleet
    /// (agreed point 1 of the manager's read: a switch never runs on a vault that the keys step did not reach). The
    /// answer says only whether the vault has a fleet (`configure_answer`: `"fleet": true`); after a keys step that
    /// sent `--fleet F`, that fleet is F, because `configure` refuses a vault of another fleet.
    public static func switchMayFollow(_ answer: KeySwapAnswer, central: KeySwapCentral?) -> Bool {
        guard let central, case .done(_, _, let keys, let hasFleet) = answer.outcome else { return false }
        return keys >= central.ownerKeys.count && hasFleet
    }

    /// What one answer does to this Mac's record of a server: a good one ends its tries; a put-back counts a try and
    /// holds that server's program (and so each switch to on); each other stop counts a try, but the lock, which is
    /// another step's, counts none and only sends the server after the others. `keys` and `fleet`: what the keys step
    /// sent, kept after a good answer that holds them.
    public static func record(_ answer: KeySwapAnswer, after earlier: KeySwapRecord?, wish: KeySwapWish?,
                              keys: [String], fleet: String?, at now: Double) -> KeySwapRecord {
        var record = earlier ?? KeySwapRecord()
        record.at = now
        if let program = answer.program { record.program = program }
        if record.hold.map({ $0.program != record.program || $0.wish != wish?.rawValue }) == true { record.hold = nil }
        record.lockedAt = nil
        record.atOnce = nil
        switch answer.outcome {
        case .done(_, _, let held, let hasFleet):
            record.tries = nil
            if held >= keys.count && (fleet == nil || hasFleet) {
                record.keys = keys
                record.fleet = fleet
            }
        case .stopped(let reason, let undone):
            if reason.hasPrefix(KeySwapAnswer.lockWords) {
                record.lockedAt = now
                return record
            }
            record.tries = KeySwapTries.failed(after: record.tries, at: now, reason: KeySwapWords.notSwitchedOn(reason))
            if undone, let program = record.program {
                record.hold = KeySwapHold(program: program, wish: wish?.rawValue, reason: reason, at: now)
            }
            record.atOnce = showsAtOnce(answer) ? true : nil
        case .olderProgram:
            record.tries = KeySwapTries.failed(after: record.tries, at: now, reason: KeySwapWords.olderProgram)
        case .unread:
            record.tries = KeySwapTries.failed(after: record.tries, at: now,
                                               reason: KeySwapWords.notSwitchedOn(answer.serverWords ?? ""))
        }
        return record
    }

    /// A step that stopped before it reached the server (no connection on record, Tailscale naming another machine):
    /// a try, with the words of that stop.
    public static func record(stop words: String, after earlier: KeySwapRecord?, at now: Double) -> KeySwapRecord {
        var record = earlier ?? KeySwapRecord()
        record.lockedAt = nil
        record.atOnce = nil
        record.tries = KeySwapTries.failed(after: record.tries, at: now, reason: KeySwapWords.notSwitchedOn(words))
        return record
    }

    /// The server rows that the key swap's stops give: each server of the hub's rows whose record has a row, in the
    /// hub's order, and never one that the owner removed on this Mac (`CentralVaultSection`).
    public static func needs(_ rows: [KeySwapServer], records: [String: KeySwapRecord], removed: Set<String>) -> [VaultServerNeed] {
        rows.compactMap { row in
            guard !removed.contains(row.name), let reason = rowReason(records[row.name]) else { return nil }
            return VaultServerNeed(machine: row.name, reason: reason)
        }
    }

    /// The words of the server's row on the Secrets page, or nil for no row: after six tries in a row (C3), or at once
    /// for a put-back and for a late fault on a server that swapped before. The words are the owner's approved
    /// sentences (C47), with the step's own reason in the first.
    public static func rowReason(_ record: KeySwapRecord?) -> String? {
        guard let record, let tries = record.tries, tries.givenUp || record.atOnce == true else { return nil }
        return tries.reason
    }

    /// A stop that shows its row at once, and not after six tries (the design, section 4): a put-back, and a late
    /// fault on a server that swapped before (its keys with a site then reach no session until it is repaired).
    public static func showsAtOnce(_ answer: KeySwapAnswer) -> Bool {
        guard case .stopped(let reason, let undone) = answer.outcome else { return false }
        return undone || reason.contains(KeySwapAnswer.keptPartWords)
    }

    /// The reason as the hub takes it: one line of at most `KeySwapAnswer.hubLimit` characters (`KEY_SWAP_REASON` of
    /// `hub.py`, measured as Python measures a string), or nil for none. The app keeps the whole reason for its row.
    public static func hubReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let line = reason.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.unicodeScalars.count > KeySwapAnswer.hubLimit else { return line }
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars.prefix(KeySwapAnswer.hubLimit - 1) { scalars.append(scalar) }
        return String(scalars).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// What the table wants on one server.
public struct KeySwapWanted: Equatable, Sendable {
    /// The switch that the table wants and that may run now, or nil: the keys step and the reading only.
    public let switchTo: KeySwapSwitch?
    /// An agent there reads a key that has a site, the word is off and the owner gave no wish: the app does not switch,
    /// and the hub asks the fleet manager for the owner's word (the Needs-you item).
    public let waitsForTheOwner: Bool
}

public enum KeySwapSwitch: String, Equatable, Sendable { case on, off }

/// The owner's wish for one server (`key_swap_wish`): on, off, or none (the rule).
public enum KeySwapWish: String, Equatable, Sendable { case on, off }

/// The one step that the plan gives now: the keys step with these keys and fleet (none of each: the reading alone),
/// then the switch when `then` is set and the keys step's answer lets it (`KeySwapPlan.switchMayFollow`).
public struct KeySwapStep: Equatable, Sendable {
    public let server: String
    public let keys: [String]
    public let fleet: String?
    public let then: KeySwapSwitch?
}

/// The owner keys and the fleet of the central vault, read as root on the hub's server from its own configuration,
/// never from the hub: the public keys and the fleet's ID only.
public struct KeySwapCentral: Equatable, Sendable {
    public let ownerKeys: [String]
    public let fleet: String
    public init?(ownerKeys: [String], fleet: String) {
        guard !ownerKeys.isEmpty, ownerKeys.allSatisfy(KeySwapRemote.isOwnerKey), CentralVault.isFleet(fleet) else { return nil }
        self.ownerKeys = ownerKeys; self.fleet = fleet
    }
}

/// What this Mac knows, beside the hub's rows.
public struct KeySwapFacts: Equatable, Sendable {
    /// The central vault's owner keys and fleet, or nil when they could not be read (change 4).
    public var central: KeySwapCentral?
    /// The SHA-256 of the `vault.py` of the hub's release (`program` of `GET /ui/vault`), or nil.
    public var hubProgram: String?
    /// This Mac's record of each server, by name (`KeySwapState`).
    public var records: [String: KeySwapRecord]
    /// The servers that the owner removed on this Mac (`VaultRemovals`).
    public var removed: Set<String>
    /// The servers whose pin's weekly re-sign is due in this round (`VaultPlan.pinRefresh`).
    public var resignDue: Set<String>
    public var now: Double

    public init(central: KeySwapCentral?, hubProgram: String? = nil, records: [String: KeySwapRecord] = [:],
                removed: Set<String> = [], resignDue: Set<String> = [], now: Double) {
        self.central = central; self.hubProgram = hubProgram; self.records = records
        self.removed = removed; self.resignDue = resignDue; self.now = now
    }
}

/// **This Mac's record of one server**, kept on the disk (change 3), so that a start of the app, also after its own
/// update, is never one more put-back.
public struct KeySwapRecord: Codable, Equatable, Sendable {
    /// The SHA-256 of the server's installed `vault.py`, read at this Mac's last step there.
    public var program: String?
    /// The owner keys and the fleet of the last keys step whose answer held them.
    public var keys: [String]?
    public var fleet: String?
    /// When this Mac's last step there ended.
    public var at: Double?
    public var tries: KeySwapTries?
    public var hold: KeySwapHold?
    /// The lock of another step stopped the last try: the server goes after the others' turn.
    public var lockedAt: Double?
    /// The last stop shows its row at once (`KeySwapPlan.showsAtOnce`), not after six tries.
    public var atOnce: Bool?

    public init(program: String? = nil, keys: [String]? = nil, fleet: String? = nil, at: Double? = nil,
                tries: KeySwapTries? = nil, hold: KeySwapHold? = nil, lockedAt: Double? = nil, atOnce: Bool? = nil) {
        self.program = program; self.keys = keys; self.fleet = fleet; self.at = at
        self.tries = tries; self.hold = hold; self.lockedAt = lockedAt; self.atOnce = atOnce
    }
}

/// The tries of one server's step (C3): 10 minutes apart, at most 6 in a row, then one each hour, for ever.
public struct KeySwapTries: Codable, Equatable, Sendable {
    public var failures: Int
    public var last: Double
    public var reason: String

    public init(failures: Int, last: Double, reason: String) { self.failures = failures; self.last = last; self.reason = reason }

    /// Six in a row failed: the server's row shows, and the tries go on each hour.
    public var givenUp: Bool { failures >= KeySwapPlan.most }

    public func isDue(at now: Double) -> Bool { now - last >= (givenUp ? KeySwapPlan.hourly : KeySwapPlan.wait) }

    public static func failed(after earlier: KeySwapTries?, at now: Double, reason: String) -> KeySwapTries {
        KeySwapTries(failures: (earlier?.failures ?? 0) + 1, last: now, reason: reason)
    }
}

/// A put-back's hold: the program and the owner's wish that it stands for. It ends at a new program on that server,
/// at a change of the wish, and at the owner's Try again, which takes it away.
public struct KeySwapHold: Codable, Equatable, Sendable {
    public let program: String
    public let wish: String?
    public let reason: String
    public let at: Double
}

/// The tries of the central vault's update to one program of the hub's release.
public struct KeySwapUpdate: Codable, Equatable, Sendable {
    /// The SHA-256 of the `vault.py` of the hub's release that these tries were for: another program starts them again.
    public let program: String
    public let tries: KeySwapTries
    public init(program: String, tries: KeySwapTries) { self.program = program; self.tries = tries }
}

/// **The three sentences that the owner approved for the two rows of Settings › Secrets** (C47, 16 November 2026:
/// "Yes, as shown"). Another sentence needs a new yes. A reason's own last full stop goes, so a sentence ends with one.
public enum KeySwapWords {
    /// The server's row: the key swap's step stopped there.
    public static func notSwitchedOn(_ reason: String) -> String {
        let said = trimmed(reason)
        return String(l10n: "The key swap is not switched on: \(said.isEmpty ? "no output" : said).")
    }

    /// The server's row: its vault program has no `configure` yet.
    public static var olderProgram: String {
        String(l10n: "This server's vault program is older than the hub's release. The server brings it up to date by itself.")
    }

    /// The Founderizer Vault row: the central vault's update gave up after six tries.
    public static func centralBehind(_ reason: String) -> String {
        String(l10n: "The central vault does not run the program of the hub's release yet: \(trimmed(reason)).")
    }

    static func trimmed(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// **This Mac's records, by fleet and server**, in a file of the app's own folder, as `VaultRemovals` is: names,
/// checksums, public keys, times and the steps' own reasons; no secret.
public struct KeySwapState: Codable, Equatable, Sendable {
    public private(set) var fleets: [String: [String: KeySwapRecord]]

    public init(fleets: [String: [String: KeySwapRecord]] = [:]) { self.fleets = fleets }

    private enum Keys: String, CodingKey { case fleets, updates }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        fleets = try keys.decode([String: [String: KeySwapRecord]].self, forKey: .fleets)
        updates = try keys.decodeIfPresent([String: KeySwapUpdate].self, forKey: .updates) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(fleets, forKey: .fleets)
        try keys.encode(updates, forKey: .updates)
    }

    public func records(fleet: String) -> [String: KeySwapRecord] { fleets[fleet] ?? [:] }

    public mutating func set(_ record: KeySwapRecord?, server: String, fleet: String) {
        fleets[fleet, default: [:]][server] = record
        if fleets[fleet]?.isEmpty == true { fleets[fleet] = nil }
    }

    /// The owner's Try again on a server's row: its tries and its hold go, so the step runs once more now.
    public mutating func tryAgain(server: String, fleet: String) {
        fleets[fleet]?[server]?.tries = nil
        fleets[fleet]?[server]?.hold = nil
        fleets[fleet]?[server]?.lockedAt = nil
        fleets[fleet]?[server]?.atOnce = nil
    }

    /// The tries of the central vault's own update to one program of the hub's release, by fleet (the design, section
    /// 8): kept on the disk too, so its row and its hourly tries outlive a start of the app.
    public private(set) var updates: [String: KeySwapUpdate] = [:]

    public func update(fleet: String) -> KeySwapUpdate? { updates[fleet] }

    public mutating func setUpdate(_ update: KeySwapUpdate?, fleet: String) { updates[fleet] = update }

    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Founderizer/key-swap.json")
    }

    /// The records in `file`, or none when there is no file or it cannot be read: the same as a new Mac's. Only a
    /// regular file of at most `KeptFile.largestRecord` bytes is read, with no wait (`KeptFile`): a named pipe, a
    /// folder or a larger file in its place is a file that cannot be read.
    public static func load(_ file: URL = Self.file) -> KeySwapState {
        guard let data = KeptFile.bytes(of: file, atMost: KeptFile.largestRecord),
              let state = try? JSONDecoder().decode(Self.self, from: data) else {
            return KeySwapState()
        }
        return state
    }

    /// Writes the records to `file` in one step, so a stop in the middle leaves them before or after.
    public func save(_ file: URL = Self.file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

/// **One row of `GET /ui/servers`, as the key swap's plan reads it** (owner API 1.183, feature `key_swap_reading`).
/// It reads only what the plan needs, and a value that it cannot read is nil, never the list: the plan then gives
/// that row no step.
public struct KeySwapServer: Decodable, Equatable, Sendable {
    public let name: String
    public let kind: String?
    public let joined: Bool
    public let hub: Bool
    public let agents: [String]
    /// `key_swap`, the word: the app's last root reading found that the vault swaps keys.
    public let word: Bool?
    /// `key_swap_wish`: the owner's own wish, or nil for none (the rule).
    public let wish: KeySwapWish?
    /// `key_swap_waits`: each agent there that reads a key that the switch would turn into a placeholder.
    public let waits: [KeySwapWait]?
    /// `key_swap_reason` and `key_swap_read_at`: the hub's record of the last reading.
    public let reason: String?
    public let readAt: Double?

    public init(name: String, kind: String?, joined: Bool, hub: Bool = false, agents: [String] = [], word: Bool?,
                wish: KeySwapWish? = nil, waits: [KeySwapWait]? = [], reason: String? = nil, readAt: Double? = nil) {
        self.name = name; self.kind = kind; self.joined = joined; self.hub = hub; self.agents = agents
        self.word = word; self.wish = wish; self.waits = waits; self.reason = reason; self.readAt = readAt
    }

    private enum Keys: String, CodingKey {
        case name, kind, joined, hub, agents, key_swap, key_swap_wish, key_swap_waits, key_swap_reason, key_swap_read_at
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        name = try keys.decode(String.self, forKey: .name)
        kind = try? keys.decodeIfPresent(String.self, forKey: .kind)
        joined = (try? keys.decodeIfPresent(Bool.self, forKey: .joined)) == true
        hub = (try? keys.decodeIfPresent(Bool.self, forKey: .hub)) == true
        agents = (try? keys.decodeIfPresent([String].self, forKey: .agents)) ?? []
        word = try? keys.decodeIfPresent(Bool.self, forKey: .key_swap)
        // A wish that this app does not know is no wish that it may act on: the row then gets no switch.
        let said = try? keys.decodeIfPresent(String.self, forKey: .key_swap_wish)
        wish = said.flatMap(KeySwapWish.init(rawValue:))
        let known = said == nil || wish != nil
        waits = known ? (try? keys.decodeIfPresent([KeySwapWait].self, forKey: .key_swap_waits)) : nil
        reason = try? keys.decodeIfPresent(String.self, forKey: .key_swap_reason)
        readAt = try? keys.decodeIfPresent(Double.self, forKey: .key_swap_read_at)
    }
}

/// One agent of a server with the keys that the switch would turn into placeholders there.
public struct KeySwapWait: Decodable, Equatable, Sendable {
    public let agent: String
    public let keys: [String]
    public init(agent: String, keys: [String]) { self.agent = agent; self.keys = keys }
}

/// The rows of `GET /ui/servers`, for the plan.
public struct KeySwapRows: Decodable, Sendable {
    public let db: String?
    public let servers: [KeySwapServer]
}

/// The hub's receipt of one reading (`POST /ui/servers/<server>/key-swap-reading`, owner API 1.183).
public struct KeySwapReadingReceipt: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let server: String
    public let key_swap: Bool
    public let changed: Bool
}

/// **The two calls of the key swap's step to the hub**: the servers' rows, and one reading. As `VaultClient`, with a
/// session of its own and the owner Mac's key on each request (`URLSession.hubData`).
public final class KeySwapClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    /// `GET /ui/servers`, read for the plan only.
    public func rows(hub: URL, database: String) async throws -> [KeySwapServer] {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/servers"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.hubData(for: request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
        guard data.count <= 2_097_152 else { throw HubError.invalidResponse }
        let rows = try JSONDecoder().decode(KeySwapRows.self, from: data)
        guard rows.db == database else { throw HubError.invalidResponse }
        return rows.servers
    }

    /// `POST /ui/servers/<server>/key-swap-reading`: what the step read, against the version `sha256` of team.json.
    /// The reason goes as the hub takes it (`KeySwapPlan.hubReason`).
    public func reading(hub: URL, database: String, client: String, server: String, sha256: String, swaps: Bool,
                        reason: String?, requestID: UUID = UUID()) async throws -> KeySwapReadingReceipt {
        guard server.range(of: Servers.machinePattern, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
        var request = URLRequest(url: hub.appendingPathComponent("ui/servers/\(server)/key-swap-reading"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        let fields: [String: Any] = ["request_id": requestID.uuidString.lowercased(), "db": database, "base_sha256": sha256,
                                     "swaps": swaps, "reason": KeySwapPlan.hubReason(reason) ?? NSNull()]
        request.httpBody = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
        let receipt = try JSONDecoder().decode(KeySwapReadingReceipt.self, from: data)
        guard receipt.ok, receipt.request_id == requestID.uuidString.lowercased(), receipt.client == client,
              receipt.server == server else { throw HubError.invalidResponse }
        return receipt
    }
}

/// **The texts of the two root steps, and the reading of their answers** (VAULT.md, "The switch"). Each runs as root
/// over this Mac's SSH connection with the strict check of the host key (`CentralVaultRemote.arguments`).
public enum KeySwapRemote {
    /// The installed program, which no user can change: `configure` runs only as it.
    public static let program = "/usr/local/lib/fleet-vault/vault.py"

    /// The read of the central vault's own configuration on the hub's server, as root: only its owner keys and its
    /// fleet leave the machine, on one line (`/etc/fleet-vault-central/vault.json`, root's file with no secret in it).
    public static let central = #"python3 -I -c 'import json; c = json.load(open("/etc/fleet-vault-central/vault.json")); "#
        + #"print(json.dumps({"owner_keys": c.get("owner_keys"), "fleet": c.get("fleet")}))'"#

    /// The owner keys and the fleet in what `central` printed, or nil.
    public static func central(in output: String) -> KeySwapCentral? {
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            return KeySwapCentral(ownerKeys: object["owner_keys"] as? [String] ?? [], fleet: object["fleet"] as? String ?? "")
        }
        return nil
    }

    /// An owner key as `configure` takes it: the base64 of an uncompressed P-256 point (65 bytes, 0x04 first).
    public static func isOwnerKey(_ key: String) -> Bool {
        guard let point = Data(base64Encoded: key) else { return false }
        return point.count == 65 && point.first == 0x04
    }

    /// The keys step: the checksum of the installed program, then `configure --swap keep` with each owner key and the
    /// fleet (none of them: the reading alone). Nil for a key or a fleet that is not one, or for one without the other.
    public static func keys(_ keys: [String], fleet: String?) -> String? {
        // configure takes the keys and the fleet together, or neither (the reading alone)
        guard keys.allSatisfy(isOwnerKey), fleet.map(CentralVault.isFleet) ?? true, keys.isEmpty == (fleet == nil) else {
            return nil
        }
        let added = keys.map { " --add-owner-key " + InstallPlan.quote($0) }.joined()
        return "sha256sum \(program); python3 -I \(program) configure --swap keep" + added
            + (fleet.map { " --fleet " + InstallPlan.quote($0) } ?? "")
    }

    /// The switch: the checksum of the installed program, then `configure --swap on` or `--swap off`, with no key and no
    /// fleet (the keys step put them there). The checksum is the program that a put-back's hold stands for.
    public static func turn(_ to: KeySwapSwitch) -> String {
        "sha256sum \(program); python3 -I \(program) configure --swap \(to.rawValue)"
    }
}

/// **What one root step answered**: the checksum of the installed program when the step printed it, and the step's
/// own JSON line.
public struct KeySwapAnswer: Equatable, Sendable {
    /// `KEY_SWAP_REASON` of `hub.py`: the hub takes a reason of at most this many characters.
    public static let hubLimit = 300
    /// The start of the lock's sentence in `vault.py` (`configure_lock`): another step changes the vault now.
    static let lockWords = "Another step changes this machine's vault now"
    /// The words of a late fault on a server that swapped before (`vault.py`, `configure`).
    static let keptPartWords = "The configuration keeps the part, which it had before this step"

    public enum Outcome: Equatable, Sendable {
        /// `ok: true`: the state ("there", "made"), whether the broker that runs now swaps, the number of owner keys
        /// that the vault holds, and whether it has a fleet (`configure_answer` prints a boolean, never the ID).
        case done(state: String, swaps: Bool, ownerKeys: Int, fleet: Bool)
        /// `ok: false`: the step's own reason, and whether it put the configuration of before back.
        case stopped(reason: String, undone: Bool)
        /// The program has no `configure`: one older than the hub's release, which the server brings up to date itself.
        case olderProgram
        /// No line of the step: the connection's own words are in `serverWords`.
        case unread
    }

    public let program: String?
    public let outcome: Outcome
    /// The last line that the server printed, for an answer that has no JSON line.
    public let serverWords: String?

    /// The answer in what the step printed: its last JSON line with `ok`, and the line of `sha256sum` for the program.
    /// `status`: the exit status of the connection, which is the reason when nothing else says one, so the row's
    /// sentence never ends with an empty reason.
    public static func read(_ output: String, status: Int32? = nil) -> KeySwapAnswer {
        let exit = status.map { "exit status \($0)" } ?? "no output"
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let program = lines.lazy.compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[1] == KeySwapRemote.program,
                  parts[0].range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
            return String(parts[0])
        }.first
        for line in lines.reversed() where line.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ok = object["ok"] as? Bool else { continue }
            if ok {
                guard let swaps = object["swaps"] as? Bool, let keys = object["owner_keys"] as? Int,
                      let state = object["state"] as? String else { break }
                return KeySwapAnswer(program: program, outcome: .done(state: state, swaps: swaps, ownerKeys: keys,
                                                                      fleet: object["fleet"] as? Bool == true), serverWords: nil)
            }
            let said = (object["reason"] as? String).map { String($0.prefix(2000)) } ?? ""
            let reason = said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? exit : said
            return KeySwapAnswer(program: program, outcome: .stopped(reason: reason, undone: object["undone"] as? Bool == true),
                                 serverWords: nil)
        }
        // argparse of a program from before `configure`: "invalid choice: 'configure'".
        if lines.contains(where: { $0.contains("invalid choice: 'configure'") }) {
            return KeySwapAnswer(program: program, outcome: .olderProgram, serverWords: nil)
        }
        let last = lines.last(where: { !$0.isEmpty }).map { String($0.prefix(300)) }
        return KeySwapAnswer(program: program, outcome: .unread, serverWords: last ?? exit)
    }
}
