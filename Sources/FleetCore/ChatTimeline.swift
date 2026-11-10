import Foundation

public enum ChatEntry: Identifiable, Equatable, Sendable {
    case message(OwnerMessage), report(ManagerReport)
    public var id: String {
        switch self { case .message(let item): "message-\(item.id)"; case .report(let item): "report-\(item.id)" }
    }
    public var created: Double {
        switch self { case .message(let item): item.created; case .report(let item): item.created }
    }
    public var agent: String {
        switch self { case .message(let item): item.chatRecipient; case .report(let item): item.chatAgent }
    }
}

/// Rebuild only when chat data changes, not for every heartbeat or usage refresh.
public struct ChatTimeline: Sendable {
    private var messages: [OwnerMessage] = []
    private var reports: [ManagerReport] = []
    private var rows: [String: [ChatEntry]] = [:]
    public init() {}
    public mutating func update(messages: [OwnerMessage], reports: [ManagerReport]) -> Bool {
        guard self.messages != messages || self.reports != reports else { return false }
        self.messages = messages; self.reports = reports
        let entries = messages.map(ChatEntry.message) + reports.map(ChatEntry.report)
        rows = Dictionary(grouping: entries, by: \.agent).mapValues { $0.sorted { ($0.created, $0.id) < ($1.created, $1.id) } }
        return true
    }
    public func entries(for agent: String, limit: Int = 60) -> [ChatEntry] {
        Array((rows[agent] ?? []).suffix(max(0, limit)))
    }
    public func count(for agent: String) -> Int { rows[agent]?.count ?? 0 }
}

/// **His words on their way, drawn from the request that the outbox saved before the POST** (fix round 3, item 11; D-6,
/// B-MOT-14): his bubble and the empty field in the frame he sends a message, and a request's card folded in the frame
/// he answers it, until the reading that holds the hub's own copy, which takes their place by the request's id. The
/// field emptied with the hub's receipt and his message came only with the reading after it: one and two round trips
/// after Return on his hub, with an empty field and no message between the two.
public enum WordsOnTheirWay {
    /// The saved request of a message or an answer that `belongs` to the chat or the card that asks, as said: `pending`
    /// while it is on its way or waits for its receipt — not a command, not a correction, and not one that the hub
    /// refused, which is his to change or discard — else `kept`, the one that view saw go, once the hub's `receipt`
    /// confirmed it: the store lets a request go with its receipt, a round trip before the reading that holds the hub's
    /// copy. Only on the request's own hub and generation.
    public static func request(pending: PendingRequest?, kept: PendingRequest?, receipt: SendReceipt?, hub: URL,
                               database: String?, where belongs: (PendingRequest) -> Bool) -> PendingRequest? {
        func here(_ request: PendingRequest) -> Bool {
            request.hub == hub && request.database == database && request.command == nil
                && request.replacesRequestID == nil && belongs(request)
        }
        if let pending, pending.refusal == nil, here(pending) { return pending }
        if let kept, here(kept), receipt?.matches(kept) == true { return kept }
        return nil
    }

    /// His message to `agent` on its way, until `messages`, the fleet's reading, hold the hub's copy of it.
    public static func message(to agent: String, pending: PendingRequest?, kept: PendingRequest?, receipt: SendReceipt?,
                               hub: URL, database: String?, messages: [OwnerMessage]) -> PendingRequest? {
        guard let request = request(pending: pending, kept: kept, receipt: receipt, hub: hub, database: database,
                                    where: { $0.needID == nil && ($0.recipient ?? "manager") == agent }),
              !messages.contains(where: {
                  $0.request_id.caseInsensitiveCompare(request.requestID.uuidString) == .orderedSame
              })
        else { return nil }
        return request
    }

    /// His answer to `need` on its way, while the reading still has the request open.
    public static func answer(to need: OwnerNeed, pending: PendingRequest?, kept: PendingRequest?, receipt: SendReceipt?,
                              hub: URL, database: String?) -> PendingRequest? {
        guard need.isOpen else { return nil }
        return request(pending: pending, kept: kept, receipt: receipt, hub: hub, database: database,
                       where: { $0.needID == need.id })
    }

    /// What a field shows of `draft`: nothing while the draft is the words on their way, which the store clears itself
    /// with the hub's receipt; words he writes meanwhile are his next draft.
    public static func field(_ draft: String, sending request: PendingRequest?) -> String {
        guard let request, draft.trimmingCharacters(in: .whitespacesAndNewlines) == request.text else { return draft }
        return ""
    }
}

extension OwnerMessage {
    /// **His message as the request that carries it says it, before the hub's copy is read** (`WordsOnTheirWay`): under
    /// the request's own id, which the hub's copy keeps, so that copy takes its place where it stands. Its time is this
    /// Mac's until the hub's comes; its files come with the hub's copy.
    public init(onItsWay request: PendingRequest) {
        request_id = request.requestID.uuidString.lowercased()
        recipient = request.recipient
        replaces_request_id = request.replacesRequestID
        kind = request.needID == nil ? "message" : "answer"
        need_id = request.needID
        text = request.text
        event_id = 0
        created = request.createdAt.timeIntervalSince1970
        read_at = nil
        edited = nil
        client = request.client
        origin = nil
        attachments = nil
    }
}
