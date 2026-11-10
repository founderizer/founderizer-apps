import Foundation

// The standing duties of an agent (UI-API.md 1.13, owner feature `responsibilities`). A duty has no "done": it is
// two things, a sentence in the owner's own words and the one agent that holds it. The sentence is the whole duty:
// it says what the agent answers for, what it does itself and what it brings to the owner first. One event of it is
// a case with a key, and one key has at most one open case. What the agent did about a case is a list of records in
// its own words, which is what the owner reads afterwards.
//
// The app reads all of it and writes none of it. The owner's own path is a message to the manager, which writes the
// duty with its `set_duty` tool (owner direction, 16 October 2026); these screens are where he reads what exists,
// what is not in order, and what was done about one event, step by step.

public enum Duties {
    /// `ui_features` of a hub that serves the duties.
    public static let feature = "responsibilities"

    /// Why a duty is not in order, in the hub's order of precedence. The hub's 15-minute sweep writes one of these
    /// with the words that go beside it; these are the short names for the ones it does not describe.
    public static func markerWords(_ kind: String) -> String {
        switch kind {
        case "step_open": "A required step has no record"
        case "watch_broken": "A watch has stopped"
        case "no_watch": "Nothing watches for its events"
        case "queue": "It is at its open-case limit"
        case "repeat": "The same event came back"
        case "no_review": "Its duties were last put in order days ago"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Why a duty is not in order now, from the hub's sweep. `detail` is the hub's own sentence about this duty.
public struct DutyMarker: Decodable, Equatable, Sendable {
    public let kind: String
    public let since: Double?
    public let detail: String?

    /// The one line to show. The hub's own words where it wrote them, and the short name of the reason otherwise.
    public var says: String {
        let words = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return words.isEmpty ? Duties.markerWords(kind) : words
    }
}

/// One wake-up rule that watches for a duty's events: a check, a schedule, or a rule the agent made itself.
public struct DutyWatch: Decodable, Equatable, Identifiable, Sendable {
    /// The check of a watch as the hub keeps it: the condition is the object of a value-form check (`{"op", "value"}`),
    /// and null for a check that prints lines (plan P4), which has none.
    public struct Check: Decodable, Equatable, Sendable {
        public let path: String?
        public let sha256: String
        public let condition: TriggerCheck.Condition?
        public let repeat_minutes: Int?
    }

    /// The watch's last run. Its value is the number a value-form check printed, or null.
    public struct Run: Decodable, Equatable, Sendable {
        public let id: Int
        public let state: String
        public let reason: String?
        public let value: Double?
        public let task: Int?
        public let created: Double
    }

    public let trigger: Int
    public let kind: String
    public let state: String
    public let paused_by: String?
    public let paused_reason: String?
    public let needs: String?
    public let next_due: Double?
    public let failures: Int?
    public let check: Check?
    public let last_run: Run?
    public var id: Int { trigger }

    /// A watch that is not running is one of the reasons a duty is not in order, so it is said plainly. The hub's
    /// rules are `active`, `paused`, `done` or `deleted`, and only the first one watches for anything.
    public var isRunning: Bool { state == "active" }
    /// What this watch is, in one word the owner can read: the hub's `kind` without its jargon.
    public var words: String {
        switch kind {
        case "check": "A check"
        case "own": "The agent's own rule"
        default: "A schedule"
        }
    }
}

/// One event of a duty, and everything that was done about it.
public struct DutyCase: Decodable, Equatable, Identifiable, Sendable {
    /// One record of the case: one real step of the work, under a label the agent chose itself.
    public struct Step: Decodable, Equatable, Identifiable, Sendable {
        public let key: String
        public let text: String
        public let task: Int?
        public let by: String
        public let at: Double
        public var id: String { key }
    }

    public struct Job: Decodable, Equatable, Sendable {
        public let id: Int
        public let state: String
    }

    public let id: Int
    public let ref: String
    public let responsibility: Int
    public let key: String?
    public let title: String
    public let source: String
    public let state: String
    public let opened: Double
    public let opened_by: String
    public let first_step: Double?
    public let closed: Double?
    public let closed_by: String?
    public let outcome: String?
    public let note: String?
    public let repeated: Bool
    /// What the agent did, in its own words and in the order it recorded them. This is the case as it happened.
    public let steps: [Step]
    public let tasks: [Job]

    public var isOpen: Bool { state == "open" }
    public func record(_ key: String) -> Step? { steps.first { $0.key == key } }
}

/// One standing duty of one agent.
public struct Duty: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let agent: String
    /// The first sentence of `text`, which the hub derives: a duty has no title of its own to fill in.
    public let title: String
    /// The duty itself, in the owner's words. Nothing else carries what the agent may do and what it must ask.
    public let text: String
    public let state: String
    public let revision: Int
    public let created: Double?
    public let updated: Double?
    public let created_by: String?
    public let watch: [DutyWatch]
    public let open_cases: Int
    public let cases_30d: Int
    public let repeats_30d: Int
    public let last_case: DutyCase?
    public let cases: [DutyCase]
    public let marker: DutyMarker?

    /// `R-1`, as the hub and the agents write it.
    public var ref: String { "R-\(id)" }

    /// Who wrote this duty: an agent by name, or the owner himself.
    public var writer: String {
        switch created_by {
        case "owner", nil: "you"
        case let name?: name.agentLabel
        }
    }
    public var isActive: Bool { state == "active" }
    /// Nothing the sweep found wrong with it. A paused or retired duty is not "not in order"; it is stopped.
    public var isInOrder: Bool { marker == nil }
    /// Nothing watches for this duty's events, so nothing can open a case but the agent itself.
    public var hasNoWatch: Bool { watch.isEmpty }
}

/// `GET /ui/responsibilities`: every duty, with the hub's own limits.
public struct DutyList: Decodable, Sendable {
    public struct Limits: Decodable, Sendable {
        public let duties_per_agent: Int
        public let watches_per_duty: Int
        public let repeat_days: Int
    }

    public let db: String
    public let limits: Limits
    public let responsibilities: [Duty]

    /// The duties that are not in order, worst first, then every other active one. A retired duty is history and
    /// comes last, because the owner is reading what runs now.
    public var ordered: [Duty] {
        responsibilities.sorted { first, second in
            func rank(_ duty: Duty) -> Int {
                if duty.state == "retired" { return 3 }
                if !duty.isInOrder { return 0 }
                return duty.isActive ? 1 : 2
            }
            return rank(first) == rank(second) ? first.id < second.id : rank(first) < rank(second)
        }
    }

    /// Every duty that the sweep found something wrong with: what the owner looks at first.
    public var notInOrder: [Duty] { responsibilities.filter { !$0.isInOrder && $0.state != "retired" } }

    public func of(_ agent: String) -> [Duty] { ordered.filter { $0.agent == agent } }

    public func validate(database: String) throws {
        guard db == database, responsibilities.count <= 4096,
              Set(responsibilities.map(\.id)).count == responsibilities.count else { throw HubError.invalidResponse }
    }
}

/// `GET /ui/responsibilities/<id>`: one duty, its cases newest first, and what was done to the duty itself.
public struct DutyDetail: Decodable, Sendable {
    public struct HistoryRow: Decodable, Equatable, Identifiable, Sendable {
        public let id: Int
        public let ts: Double
        public let by: String
        public let kind: String
        public let detail: String?
    }

    public let db: String
    public let responsibility: Duty
    public let cases: [DutyCase]
    /// The `before` of the next page, or nil when these are all of them.
    public let next: Int?
    public let history: [HistoryRow]

    public var open: [DutyCase] { cases.filter(\.isOpen) }
    public var closed: [DutyCase] { cases.filter { !$0.isOpen } }
}

/// What the hub answered after a write.
public struct DutyReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let responsibility: Duty?
}

public final class DutiesClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    public func read(hub: URL, database: String) async throws -> DutyList {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/responsibilities"),
                                  resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let list = try JSONDecoder().decode(DutyList.self, from: await perform(parts.url!))
        try list.validate(database: database)
        return list
    }

    /// One duty with its cases. `before` is a case id, for the page after the one in hand.
    public func duty(_ id: Int, hub: URL, database: String, before: Int? = nil, limit: Int = 50) async throws
        -> DutyDetail {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/responsibilities/\(id)"),
                                  resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database), .init(name: "limit", value: String(limit))]
            + (before.map { [URLQueryItem(name: "before", value: String($0))] } ?? [])
        let detail = try JSONDecoder().decode(DutyDetail.self, from: await perform(parts.url!))
        guard detail.db == database else { throw HubError.invalidResponse }
        return detail
    }

    /// `pause`, `resume`, `retire` or `reopen`. The manager writes the duty itself (`set_duty`); the owner's app
    /// only reads it and stops or starts it.
    public func state(_ id: Int, action: String, revision: Int, hub: URL, database: String,
                      client: String) async throws -> DutyReceipt {
        try await write("ui/responsibilities/\(id)/state", ["action": action, "base_revision": revision],
                        hub: hub, database: database, client: client)
    }

    private func write(_ route: String, _ fields: [String: Any], hub: URL, database: String,
                       client: String) async throws -> DutyReceipt {
        let requestID = UUID().uuidString.lowercased()
        var body = fields
        body["request_id"] = requestID
        body["db"] = database
        var request = URLRequest(url: hub.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Unexpected HTTP response."
            throw HubError.refusal(response.statusCode, String(message.prefix(500)))
        }
        let receipt = try JSONDecoder().decode(DutyReceipt.self, from: data)
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client else {
            throw HubError.invalidResponse
        }
        return receipt
    }

    private func perform(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Unexpected HTTP response."
            throw HubError.refusal(response.statusCode, String(message.prefix(500)))
        }
        return data
    }

    private struct ErrorBody: Decodable { let error: String }
}
