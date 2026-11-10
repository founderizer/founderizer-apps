import Foundation

/// The hub's answer to `POST /ui/attachments/<id>/keep` (UI-API.md 1.31). `kept` is nil after a press that let the
/// file go; `going` says whether the hub's next sweep would then take it, which is false while it is kept and false
/// for a file whose message still has its ninety days.
public struct AttachmentKeepReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let attachment: Int
    public let kept: MessageAttachment.Kept?
    public let going: Bool
}

public enum HubError: LocalizedError, Sendable {
    case invalidAddress, invalidResponse, refusal(Int, String), unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an HTTP or HTTPS hub address without a path or login."
        case .invalidResponse: "The hub response does not match API version 1."
        case .refusal(let status, let message): "Hub refused the request (\(status)): \(message)"
        case .unavailable: "The hub is unavailable. The last received state is shown."
        }
    }

    /// A refusal that another send of the same request cannot change: bad input, no access, nothing of that name,
    /// too large, the wrong type, registered login text, or a hub that is not serving. 409 is **not** one of them,
    /// and used to be: see `conflict`.
    public var definitiveRefusal: Bool {
        if case .refusal(let status, _) = self {
            return [400, 403, 404, 413, 415, 422, 503].contains(status)
        }
        return false
    }

    /// A 409. It is a refusal, but not one of the final kind, and that is why it is its own question.
    ///
    /// The hub answers 409 to a write whose `base_revision` or `base_sha256` is no longer the current one, and it
    /// keeps the current one: so the same command against the current base is exactly what the owner meant, and a
    /// save that was dropped here cost him his typing for nothing. It answers 409 to other things as well — a
    /// changed generation, a request UUID used again with another body, an action the state does not allow now —
    /// and no retry settles those. Nothing in the status tells the two apart, and the words are prose this app does
    /// not read, so the sender decides by reading the base again: a base that moved was the stale one.
    public var conflict: Bool {
        if case .refusal(409, _) = self { return true }
        return false
    }

    /// What a refusal that carried no words of its own is called, in one place, so a screen can tell it from a
    /// sentence the hub actually wrote.
    public static let unexplained = "Unexpected HTTP response."

    /// The hub's own sentence for a request it refused, or nil when it gave none.
    ///
    /// Every owner route writes `{"error": "<one line for the owner>"}` beside the status, for the owner to read.
    /// A screen that reports a failed read shows this where the hub wrote one, and its own words only where it did
    /// not — because "HTTP 403" and "HTTP 503" are the same sentence to him, and the hub had written two.
    public static func said(_ error: Error) -> String? {
        guard case HubError.refusal(_, let words) = error else { return nil }
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty || said == unexplained ? nil : said
    }
}

/// **One read of a route at a time** (the fix round of 29 October 2026): a GET that is asked for while the same GET
/// is on its way gets that one's answer, and no second request goes. Settings › Apps asked `/ui/team` six times and
/// `/ui/resources` eight times in 0.6 s as it opened, and Manager's chat four routes twice each: every page and list
/// that draws a reading read it for itself. Each duplicate added to every read's time on the owner's hub.
///
/// A caller that is cancelled stops waiting at once, with `CancellationError`, as it would have with a read of its
/// own; the read goes on while another caller waits for it, and stops when none does. Nothing is kept: a read that
/// starts after the answer came is a new read. **A read never joins one that began before a write of this Mac was
/// answered** (`HubWrites`): a page that reads right after its own save must see what it saved.
final class HubReads: @unchecked Sendable {
    static let shared = HubReads()

    /// What one read answered: the bytes, and the response where the read keeps it.
    struct Answer: @unchecked Sendable {
        let data: Data
        let response: HTTPURLResponse?
    }

    /// One read on its way and the callers that wait for it.
    private final class Flight: @unchecked Sendable {
        var waiters: [UUID: CheckedContinuation<Answer, Error>] = [:]
        var task: Task<Void, Never>?
        /// The writes answered before it began (`writes`).
        let after: Int
        init(after: Int) { self.after = after }
    }

    private let lock = NSLock()
    private var flights: [String: Flight] = [:]
    /// The read each caller waits for, also one that a newer read of its address has replaced in `flights`.
    private var waiting: [UUID: (key: String, flight: Flight)] = [:]
    /// The writes of this Mac that the hub answered so far.
    private var writes = 0
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        observer = center.addObserver(forName: HubWrites.answered, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.writes += 1 }
        }
    }

    /// The reads on their way now, for the tests.
    var inFlight: Int { lock.withLock { flights.count } }

    /// **The read a request is, for sharing**: a GET of the hub, by its address and its time limits, whichever client
    /// makes it and whatever it accepts (every `/ui` route answers JSON). A write is no read and shares nothing.
    ///
    /// **Only reads with the same time limits share** (review A5, fix round 2): a read runs in the session of the client
    /// that began it, so a 60-second read of `/ui/team` that joined a 10-second one gave up after 10 seconds, and a
    /// 10-second read that joined a 60-second one waited 60.
    static func key(_ request: URLRequest, in session: URLSessionConfiguration) -> String? {
        guard (request.httpMethod ?? "GET") == "GET", let url = request.url else { return nil }
        let limits = [request.timeoutInterval, session.timeoutIntervalForRequest, session.timeoutIntervalForResource]
        return "GET \(url.absoluteString) " + limits.map { String(format: "%g", $0) }.joined(separator: "/")
    }

    /// The answer of the read `key`: the one on its way, or a new one that `read` makes.
    func share(_ key: String, _ read: @escaping @Sendable () async throws -> Answer) async throws -> Answer {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Answer, Error>) in
                lock.lock()
                // Only a read that began after the last answered write is this read's answer too.
                let running = flights[key].flatMap { $0.after == writes ? $0 : nil }
                let flight = running ?? Flight(after: writes)
                flight.waiters[id] = waiter
                flights[key] = flight
                waiting[id] = (key, flight)
                lock.unlock()
                if running == nil {
                    let task = Task { [weak self] in
                        let result: Result<Answer, Error>
                        do { result = .success(try await read()) } catch { result = .failure(error) }
                        self?.finish(flight, key: key, with: result)
                    }
                    // Every caller may have gone before the read had its task: then nobody waits for it.
                    let orphan = lock.withLock { () -> Bool in
                        guard !flight.waiters.isEmpty else { return true }
                        flight.task = task
                        return false
                    }
                    if orphan { task.cancel() }
                }
                // A caller that was cancelled before it waited leaves at once.
                if Task.isCancelled { leave(id) }
            }
        } onCancel: {
            leave(id)
        }
    }

    private func finish(_ flight: Flight, key: String, with result: Result<Answer, Error>) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Answer, Error>] in
            if flights[key] === flight { flights[key] = nil }
            for id in flight.waiters.keys { waiting[id] = nil }
            defer { flight.waiters = [:] }
            return Array(flight.waiters.values)
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    /// One caller stops waiting. The last one to go stops the read itself.
    private func leave(_ id: UUID) {
        let gone = lock.withLock { () -> (waiter: CheckedContinuation<Answer, Error>, stop: Task<Void, Never>?)? in
            guard let (key, flight) = waiting.removeValue(forKey: id),
                  let waiter = flight.waiters.removeValue(forKey: id) else { return nil }
            guard flight.waiters.isEmpty else { return (waiter, nil) }
            if flights[key] === flight { flights[key] = nil }
            return (waiter, flight.task)
        }
        gone?.stop?.cancel()
        gone?.waiter.resume(throwing: CancellationError())
    }
}

/// **One read of a page reading at a time, by its name** (`FleetStore.read`, fix round 2): a list that asks for a
/// reading while it is read gets that read's answer, whatever it decodes. Settings › Apps draws one reading of the
/// resources in four lists, and each list read it for itself. **A read never joins one that began before a write of
/// this Mac was answered** (`HubWrites`, review A7), as `HubReads` never does: a list read right after his save took
/// the read that began during it, and showed what stood before the save until its next read.
@MainActor public final class PageReads {
    private var reads: [String: (task: Task<any Sendable, Error>, after: Int)] = [:]
    private let writes = WriteCount()
    private var observer: NSObjectProtocol?

    public init(center: NotificationCenter = .default) {
        let writes = writes
        // Counted where the answer comes, before the writer goes on, so a read the writer starts next sees it.
        observer = center.addObserver(forName: HubWrites.answered, object: nil, queue: nil) { _ in writes.add() }
    }

    /// The answer of the read `key`: the one on its way when it began after the last answered write, else a new one.
    public func read<Value: Sendable>(_ key: String, _ read: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let after = writes.value
        if let running = reads[key], running.after == after {
            guard let value = try await running.task.value as? Value else { throw HubError.invalidResponse }
            return value
        }
        let task = Task<any Sendable, Error> { try await read() }
        reads[key] = (task, after)
        defer { if reads[key]?.task == task { reads[key] = nil } }
        guard let value = try await task.value as? Value else { throw HubError.invalidResponse }
        return value
    }
}

/// The answered writes of this Mac, counted from any thread.
final class WriteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class HubClient: Sendable {
    /// **The address of no hub**, for an app that was never linked to one. It was the owner's own hub, so a new
    /// customer's Mac and phone read his private address first. A name under `.invalid` never resolves (RFC 2606), so
    /// a new app reads no one's fleet and opens on its first run at once; an app that was linked keeps its own address
    /// in `hubAddress`, so his own Mac and phone do not change (the onboarding of 4 November 2026).
    public static let defaultAddress = "http://fleet.invalid:8765"

    /// **One session for every `HubClient`.** The app makes a client wherever it talks to the hub, more than seventy
    /// places, and each one used to make a session of its own with a delegate. A session with a delegate lives until
    /// it is invalidated, and none of them ever was, so every client stayed in memory for as long as the app ran. The
    /// configuration and the delegate are the same for all of them, so one session serves them all.
    private static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()
    private let session: URLSession
    /// The reads it shares (`HubReads`): the app's one, or a test's own, so no other suite's write reaches the test.
    private let reads: HubReads

    public init() {
        session = Self.shared
        reads = .shared
    }

    init(reads: HubReads) {
        session = Self.shared
        self.reads = reads
    }

    public static func address(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme, ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url
        else { throw HubError.invalidAddress }
        return url.appendingPathComponent("")
    }

    public func state(at hub: URL) async throws -> HubState {
        try await stateReading(at: hub).state
    }

    /// The state and the bytes it was read from, so the Mac can keep its last reading on disk and draw it at the
    /// next launch, before the hub answers.
    public func stateReading(at hub: URL) async throws -> (state: HubState, data: Data) {
        var request = URLRequest(url: hub.appendingPathComponent("ui/state"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await perform(request)
        return (try HubState.decode(data), data)
    }

    public func send(_ pending: PendingRequest) async throws -> SendReceipt {
        var request = URLRequest(url: pending.hub.appendingPathComponent(pending.route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try pending.body()
        request.setValue(pending.client, forHTTPHeaderField: "X-Fleet-Client")
        let receipt = try JSONDecoder().decode(SendReceipt.self, from: await perform(request))
        guard receipt.matches(pending) else { throw HubError.invalidResponse }
        return receipt
    }

    /// `POST /ui/attachments` (owner feature `attachments`): one file, before the message that carries it. Its own
    /// number makes it idempotent, so a send that is repeated is one file on the hub and never a second one.
    public func upload(_ data: Data, name: String, mime: String, requestID: UUID, client: String, hub: URL,
                       database: String) async throws -> MessageAttachment {
        guard MessageAttachment.types[mime] != nil else { throw AttachmentError.type }
        guard !data.isEmpty, data.count <= MessageAttachment.sizeLimit else { throw AttachmentError.tooLarge }
        var parts = URLComponents(url: hub.appendingPathComponent("ui/attachments"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.setValue(requestID.uuidString.lowercased(), forHTTPHeaderField: "X-Fleet-Request-Id")
        request.setValue(MessageAttachment.safeName(name, mime: mime), forHTTPHeaderField: "X-Fleet-Name")
        request.httpBody = data
        let file = try JSONDecoder().decode(MessageAttachment.self, from: await perform(request))
        try file.validate()
        guard file.mime == mime, file.matches(data) else { throw AttachmentError.bytes }
        return file
    }

    /// `POST /ui/attachments/<id>/keep` (owner feature `attachment_knowledge`, UI-API.md 1.31): the hub keeps this
    /// file past the ninety days, or stops keeping it. It writes no knowledge file either way, which is the whole
    /// point of it: a screenshot, a mockup, a zip or a PDF cannot become one, and this is how the owner keeps that
    /// kind. `keep: false` is the way back, and it leaves a knowledge file the file already has exactly as it is.
    public func keep(_ file: MessageAttachment, _ keep: Bool, client: String, hub: URL,
                     database: String) async throws -> AttachmentKeepReceipt {
        try file.validate()
        let requestID = UUID().uuidString.lowercased()
        var request = URLRequest(url: hub.appendingPathComponent("ui/attachments/\(file.id)/keep"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["request_id": requestID, "db": database,
                                                                       "keep": keep])
        let receipt = try JSONDecoder().decode(AttachmentKeepReceipt.self, from: await perform(request))
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client, receipt.attachment == file.id,
              (receipt.kept != nil) == keep else { throw HubError.invalidResponse }
        return receipt
    }

    /// `GET /ui/attachments/<id>`: the bytes of one file of a message, with their count and their SHA-256 checked
    /// before anything is shown or opened.
    public func attachment(_ file: MessageAttachment, hub: URL, database: String) async throws -> Data {
        try file.validate()
        var parts = URLComponents(url: hub.appendingPathComponent("ui/attachments/\(file.id)"),
                                  resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: MessageAttachment.sizeLimit)
        guard file.matches(data) else { throw AttachmentError.bytes }
        return data
    }

    public func command(_ pending: PendingRequest) async throws -> ControlReceipt {
        guard let command = pending.command else { throw HubError.invalidResponse }
        switch command {
        case .machineUpdate(let agent), .machineCheck(let agent):
            guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
        case .ownerDevice(let device, _, _), .ownerDeviceCode(let device):
            // The code route carries the device in its path.
            guard OwnerDevices.isName(device) else { throw HubError.invalidResponse }
        default: break
        }
        var request = URLRequest(url: pending.hub.appendingPathComponent(pending.route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(pending.client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try pending.body()
        let receipt = try JSONDecoder().decode(ControlReceipt.self, from: await perform(request))
        guard receipt.matches(pending) else { throw HubError.invalidResponse }
        return receipt
    }

    /// The base that a command's subject carries **now**: the `team.json` version, or the goal's or schedule's own
    /// revision.
    ///
    /// This is what tells one 409 from another. The hub refuses a write against a base that is no longer current,
    /// and it also refuses a changed generation, a request UUID used again with another body, and an action the
    /// state does not allow — all with 409 and all in prose this app does not read. So the sender asks the hub what
    /// the base is: a base that moved was the stale one, and a base that did not means the refusal was something
    /// else and no retry settles it.
    public func currentBase(for command: OwnerCommand, hub: URL, database: String) async throws -> OwnerCommand.Base? {
        switch command {
        case .goalState(let id, _, _):
            return .revision(try await goal(hub: hub, database: database, id: id).goal.revision)
        case .triggerState(let id, _, _):
            return .revision(try await trigger(hub: hub, database: database, id: id).trigger.revision)
        default:
            guard case .file = command.base else { return nil }
            return .file(sha256: try await team(hub: hub, database: database).sha256)
        }
    }

    public func health(hub: URL, database: String) async throws -> FleetHealth {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/health"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 1_048_576)
        let result = try JSONDecoder().decode(FleetHealth.self, from: data)
        try result.validate(database: database)
        return result
    }

    public func machines(hub: URL, database: String) async throws -> MachineList {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/machines"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 1_048_576)
        let list = try JSONDecoder().decode(MachineList.self, from: data)
        try list.validate(database: database)
        return list
    }

    public func team(hub: URL, database: String) async throws -> TeamSnapshot {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/team"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 1_048_576)
        let result = try JSONDecoder().decode(TeamSnapshot.self, from: data)
        try result.validate(database: database)
        return result
    }

    /// `GET /ui/owner/devices` (owner feature `mobile`): the owner's own devices beside this Mac, each with its
    /// address, whether it has a key, its last read, its last contact and its open code's time. It carries no key and
    /// no code.
    public func ownerDevices(hub: URL, database: String) async throws -> OwnerDeviceList {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/owner/devices"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let list = try JSONDecoder().decode(OwnerDeviceList.self, from: await perform(request))
        try list.validate(database: database)
        return list
    }

    /// `GET /ui/servers` (owner feature `servers`): the servers, their readings, availability and newest jobs.
    public func servers(hub: URL, database: String) async throws -> ServerList {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/servers"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 2_097_152)
        let list = try JSONDecoder().decode(ServerList.self, from: data)
        try list.validate(database: database)
        return list
    }

    /// `POST /ui/servers/join`: a one-time join code for one new server, with the line for that server. The hub gives
    /// the code once and keeps only its SHA-256; a new code cancels the open one. The app keeps the code in the page only.
    /// `name` is the server's name on a hub from before `server_names`; a hub with it names the server by its name in
    /// Tailscale at the join, so it is sent none (nil) and answers the label "". `agent` is the first agent of a Mac,
    /// on a hub with `mac_setup`, which adds it by itself once that Mac has joined.
    public func joinCode(hub: URL, database: String, client: String, requestID: UUID = UUID(), name: String?,
                         kind: String, agent: String? = nil, ai: ServerAI? = nil) async throws -> JoinCode {
        guard name.map({ $0.range(of: Servers.namePattern, options: .regularExpression) != nil }) ?? true,
              Servers.kinds.contains(kind) else { throw HubError.invalidResponse }
        var fields: [String: Any] = name.map { ["name": $0, "kind": kind] } ?? ["kind": kind]
        if let agent { fields["agent"] = agent; fields["runtime"] = ai?.runtime ?? "claude" }
        if agent != nil, let ai { fields["chatgpt"] = ai.hasChatGPT }
        let answer = try JSONDecoder().decode(JoinCode.self, from: await ownerCommand(
            "ui/servers/join", hub: hub, database: database, client: client, requestID: requestID, fields: fields))
        guard answer.ok, answer.request_id.lowercased() == requestID.uuidString.lowercased(), answer.name == name ?? "",
              answer.kind == kind, answer.expires_at.isFinite else { throw HubError.invalidResponse }
        return answer
    }

    /// `POST /ui/servers/<server>/agents`: a new agent on an available server, against the version `sha256` of
    /// team.json; or the install again of the agent on it whose install failed.
    public func addServerAgent(hub: URL, database: String, client: String, requestID: UUID = UUID(), server: String,
                               sha256: String, agent: String, runtime: String, role: String,
                               reportsTo: String?) async throws -> ServerAgentReceipt {
        guard server.range(of: Servers.machinePattern, options: .regularExpression) != nil,
              agent.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              ["codex", "claude"].contains(runtime), ["worker", "lead"].contains(role) else { throw HubError.invalidResponse }
        let fields: [String: Any] = ["base_sha256": sha256, "agent": agent, "runtime": runtime, "role": role,
                                     "reports_to": reportsTo.map { $0 as Any } ?? NSNull()]
        let receipt = try JSONDecoder().decode(ServerAgentReceipt.self, from: await ownerCommand(
            "ui/servers/\(server)/agents", hub: hub, database: database, client: client, requestID: requestID, fields: fields))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased(), receipt.agent == agent,
              receipt.server == server, receipt.job > 0 else { throw HubError.invalidResponse }
        return receipt
    }

    /// `POST /ui/servers/<server>/prepare`: the server's own service prepares `runtime` for an agent on it, before the
    /// owner switches the agent: it installs that provider when the server has none and signs it in. It changes no
    /// agent; the switch stays its own command. A failed preparation goes again with a new request.
    public func prepareServerRuntime(hub: URL, database: String, client: String, requestID: UUID = UUID(), server: String,
                                     agent: String, runtime: String) async throws -> ServerPrepareReceipt {
        guard server.range(of: Servers.machinePattern, options: .regularExpression) != nil,
              agent.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil,
              RuntimeSwitch.runtimes.contains(runtime) else { throw HubError.invalidResponse }
        let receipt = try JSONDecoder().decode(ServerPrepareReceipt.self, from: await ownerCommand(
            "ui/servers/\(server)/prepare", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["agent": agent, "runtime": runtime]))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased(), receipt.agent == agent,
              receipt.server == server, receipt.runtime == runtime, receipt.job > 0 else { throw HubError.invalidResponse }
        return receipt
    }

    /// `POST /ui/servers/<server>/remove`: a server with no agent leaves Fleet. It can join again with a new line.
    public func removeServer(hub: URL, database: String, client: String, requestID: UUID = UUID(), server: String,
                             sha256: String) async throws -> ServerRemoval {
        guard server.range(of: Servers.machinePattern, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
        let removal = try JSONDecoder().decode(ServerRemoval.self, from: await ownerCommand(
            "ui/servers/\(server)/remove", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["base_sha256": sha256]))
        guard removal.ok, removal.removed, removal.server == server,
              removal.request_id.lowercased() == requestID.uuidString.lowercased() else { throw HubError.invalidResponse }
        return removal
    }

    // ---- how a machine is reached, on record (owner feature `machine_access`)

    /// `POST /ui/team/access`: put one machine's connection on record in `team.json`, against the version `sha256`
    /// of it that the page read. The hub refuses an old version (409), so a write that got no answer is safe to
    /// make again from a new reading.
    public func recordMachineAccess(hub: URL, database: String, client: String, requestID: UUID = UUID(),
                                    machine: String, sha256: String,
                                    form: MachineAccessForm) async throws -> MachineAccessReceipt {
        guard machine.range(of: Servers.machinePattern, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let port = form.portNumber, form.isValid else { throw HubError.invalidResponse }
        return try await accessCommand(hub: hub, database: database, client: client, requestID: requestID,
                                       machine: machine,
                                       fields: ["base_sha256": sha256, "machine": machine,
                                                "ssh_user": form.trimmedUser, "ssh_port": port,
                                                "screen_sharing": form.screenSharing])
    }

    /// The same route with `delete`: the record goes. A connection that is gone must be recordable as gone, because
    /// an entry left standing says the fleet can reach a machine it cannot.
    public func forgetMachineAccess(hub: URL, database: String, client: String, requestID: UUID = UUID(),
                                    machine: String, sha256: String) async throws -> MachineAccessReceipt {
        guard machine.range(of: Servers.machinePattern, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw HubError.invalidResponse
        }
        return try await accessCommand(hub: hub, database: database, client: client, requestID: requestID,
                                       machine: machine,
                                       fields: ["base_sha256": sha256, "machine": machine, "delete": true])
    }

    private func accessCommand(hub: URL, database: String, client: String, requestID: UUID, machine: String,
                               fields: [String: Any]) async throws -> MachineAccessReceipt {
        let receipt = try JSONDecoder().decode(MachineAccessReceipt.self, from: await ownerCommand(
            "ui/team/access", hub: hub, database: database, client: client, requestID: requestID, fields: fields))
        guard receipt.ok, receipt.machine == machine,
              receipt.request_id.lowercased() == requestID.uuidString.lowercased() else {
            throw HubError.invalidResponse
        }
        return receipt
    }

    // ---- the release channel (owner features `releases` and `entitlement`)

    /// `GET /ui/releases`: this fleet's revision, what the channel last said, and the releases it knows with their
    /// update runs. It is the whole Updates screen in one read.
    public func releases(hub: URL, database: String) async throws -> ReleaseState {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/releases"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 1_048_576)
        let state = try JSONDecoder().decode(ReleaseState.self, from: data)
        try state.validate(database: database)
        return state
    }

    /// `POST /ui/releases/check`: ask the channel now. It records what it learned and changes nothing else.
    public func checkReleases(hub: URL, database: String, client: String,
                              requestID: UUID = UUID()) async throws -> ReleaseReceipt {
        try await releaseCommand("check", hub: hub, database: database, client: client, requestID: requestID,
                                 fields: [:])
    }

    /// `POST /ui/releases/update`: the owner's one click. It answers as soon as the run has started, because the run
    /// takes minutes; the next read of `/ui/releases` carries its state and, when it failed, the reason.
    public func updateRelease(hub: URL, database: String, client: String,
                              requestID: UUID = UUID()) async throws -> ReleaseReceipt {
        try await releaseCommand("update", hub: hub, database: database, client: client, requestID: requestID,
                                 fields: [:])
    }

    /// `POST /ui/releases/auto`: opt in to automatic updates, or out again. A held release is not taken even with
    /// this on, because the hold is inside the signed manifest.
    public func automaticReleases(_ on: Bool, hub: URL, database: String, client: String,
                                  requestID: UUID = UUID()) async throws -> ReleaseReceipt {
        try await releaseCommand("auto", hub: hub, database: database, client: client, requestID: requestID,
                                 fields: ["automatic": on])
    }

    /// `POST /ui/releases/entitlement`: the token the website issued for this fleet (PRODUCT.md 4.2). Only
    /// `ClaimFromLink` calls it, and it goes with it when our open channel answers every fleet.
    ///
    /// The token is a bearer credential. It is in this one request body and in nothing else the app keeps: no
    /// command label, no note, no record, and the hub keeps only its SHA-256 in the owner's own command record.
    public func storeEntitlement(token: String, hub: URL, database: String, client: String,
                                 requestID: UUID = UUID()) async throws -> ReleaseReceipt {
        guard (16...4000).contains(token.utf8.count), !token.contains(where: \.isWhitespace) else {
            throw HubError.invalidResponse
        }
        return try await releaseCommand("entitlement", hub: hub, database: database, client: client,
                                        requestID: requestID, fields: ["token": token])
    }

    private func releaseCommand(_ press: String, hub: URL, database: String, client: String, requestID: UUID,
                                fields: [String: Any]) async throws -> ReleaseReceipt {
        let receipt = try JSONDecoder().decode(ReleaseReceipt.self, from: await ownerCommand(
            "ui/releases/\(press)", hub: hub, database: database, client: client, requestID: requestID, fields: fields))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased() else {
            throw HubError.invalidResponse
        }
        return receipt
    }

    func ownerCommand(_ route: String, hub: URL, database: String, client: String, requestID: UUID,
                      fields: [String: Any]) async throws -> Data {
        var request = URLRequest(url: hub.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields.merging(
            ["request_id": requestID.uuidString.lowercased(), "db": database]) { _, new in new }, options: [.sortedKeys])
        return try await perform(request)
    }

    /// `GET /ui/secrets/salts` (owner feature `secrets`): the salts for the fingerprints of one login reference.
    public func secretSalts(hub: URL, database: String, login: String) async throws -> SecretSalts {
        guard LoginSecret.isReference(login) else { throw HubError.invalidResponse }
        var parts = URLComponents(url: hub.appendingPathComponent("ui/secrets/salts"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database), .init(name: "login", value: login)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let salts = try JSONDecoder().decode(SecretSalts.self, from: await perform(request))
        guard salts.isValid, salts.login == login else { throw HubError.invalidResponse }
        return salts
    }

    /// `POST /ui/secrets/fingerprints`: the hub then blocks and masks the login's values in texts. It answers how many
    /// fingerprints are new and how many it had; the two cover every item that was sent.
    public func registerFingerprints(hub: URL, database: String, client: String, requestID: UUID = UUID(), login: String,
                                     items: [SecretFingerprint]) async throws -> SecretReceipt {
        let body = try SecretCommand.fingerprints(requestID: requestID, database: database, login: login, items: items)
        let receipt = try await secretCommand("ui/secrets/fingerprints", hub: hub, client: client, body: body)
        guard receipt.matches(requestID: requestID, client: client, login: login), let stored = receipt.stored, let known = receipt.known,
              stored >= 0, known >= 0, stored + known == items.count else { throw HubError.invalidResponse }
        return receipt
    }

    /// `POST /ui/team/logins`: the title of one login reference in the catalog. A title gives no access.
    public func saveLoginTitle(hub: URL, database: String, client: String, requestID: UUID = UUID(), sha256: String, login: String,
                               title: String) async throws -> SecretReceipt {
        let body = try SecretCommand.title(requestID: requestID, database: database, sha256: sha256, login: login, title: title)
        let receipt = try await secretCommand("ui/team/logins", hub: hub, client: client, body: body)
        guard receipt.matches(requestID: requestID, client: client, login: login), receipt.deleted != true,
              receipt.sha256?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
        return receipt
    }

    /// `POST /ui/team/logins` with `delete`: one login reference leaves the catalog. Its value stays in Bitwarden.
    public func removeLogin(hub: URL, database: String, client: String, requestID: UUID = UUID(), sha256: String,
                            login: String) async throws -> SecretReceipt {
        let body = try SecretCommand.removal(requestID: requestID, database: database, sha256: sha256, login: login)
        let receipt = try await secretCommand("ui/team/logins", hub: hub, client: client, body: body)
        guard receipt.matches(requestID: requestID, client: client, login: login), receipt.deleted == true else {
            throw HubError.invalidResponse
        }
        return receipt
    }

    private func secretCommand(_ route: String, hub: URL, client: String, body: Data) async throws -> SecretReceipt {
        var request = URLRequest(url: hub.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = body
        return try JSONDecoder().decode(SecretReceipt.self, from: await perform(request))
    }

    public func profiles(hub: URL, database: String) async throws -> ProfileList {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/profiles"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 2_097_152)
        let list = try JSONDecoder().decode(ProfileList.self, from: data)
        try list.validate(database: database)
        return list
    }

    /// `GET /ui/notes/<agent>` (owner feature `agent_notes`): one agent's own working notes and every version of
    /// them. There is no write beside it, here or on the hub: these are not the owner's words.
    public func notes(hub: URL, database: String, agent: String) async throws -> AgentNotes {
        guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw HubError.invalidResponse
        }
        var parts = URLComponents(url: hub.appendingPathComponent("ui/notes/\(agent)"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await boundedArtifactRead(request, limit: 1_048_576)
        let notes = try JSONDecoder().decode(AgentNotes.self, from: data)
        try notes.validate(database: database, agent: agent)
        return notes
    }

    /// `GET /ui/memory/<agent>` (owner feature `agent_memory`): the lessons of one agent that stand, newest first,
    /// each with the hub's own evidence. There is no write beside it, here or on the hub: these are the agent's.
    public func memory(hub: URL, database: String, agent: String) async throws -> AgentMemory {
        guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw HubError.invalidResponse
        }
        var parts = URLComponents(url: hub.appendingPathComponent("ui/memory/\(agent)"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await boundedArtifactRead(request, limit: 4_194_304)
        let memory = try JSONDecoder().decode(AgentMemory.self, from: data)
        try memory.validate(database: database, agent: agent)
        return memory
    }

    public func goal(hub: URL, database: String, id: Int) async throws -> GoalDetail {
        guard id > 0 else { throw HubError.invalidResponse }
        var parts = URLComponents(url: hub.appendingPathComponent("ui/goals/\(id)"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 2_097_152)
        let detail = try JSONDecoder().decode(GoalDetail.self, from: data)
        try detail.validate(database: database, goalID: id)
        return detail
    }

    public func triggerChecks(hub: URL, database: String) async throws -> TriggerCheckCatalog {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/checks"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 2_097_152)
        let catalog = try JSONDecoder().decode(TriggerCheckCatalog.self, from: data)
        try catalog.validate(database: database)
        return catalog
    }

    public func capacity(hub: URL, database: String) async throws -> CapacityReport {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/capacity"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 2_097_152)
        let report = try JSONDecoder().decode(CapacityReport.self, from: data)
        try report.validate(database: database)
        return report
    }

    public func triggers(hub: URL, database: String) async throws -> TriggerList {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/triggers"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 2_097_152)
        let list = try JSONDecoder().decode(TriggerList.self, from: data)
        try list.validate(database: database)
        return list
    }

    public func trigger(hub: URL, database: String, id: Int, before: Int? = nil) async throws -> TriggerDetail {
        guard id > 0, before == nil || before! > 0 else { throw HubError.invalidResponse }
        var parts = URLComponents(url: hub.appendingPathComponent("ui/triggers/\(id)"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database), .init(name: "limit", value: "50")]
        if let before { parts.queryItems!.append(.init(name: "before", value: String(before))) }
        let (data, _) = try await boundedArtifactRead(URLRequest(url: parts.url!), limit: 2_097_152)
        let detail = try JSONDecoder().decode(TriggerDetail.self, from: data)
        try detail.validate(database: database, id: id, before: before)
        return detail
    }

    /// `limit`: the events of one page, at most the hub's 500 (`RuntimePage.validate`). **A thread's first read takes the
    /// hub's whole page** (fix round 3b), so a long task opens in one round trip: at 200 a page, the capture's live task
    /// took three or four, and its thread came 4.9 s after a click on a hub that answers a page in 1.2–1.6 s.
    public func events(hub: URL, database: String, task: Int, after: Int, limit: Int = 200) async throws -> RuntimePage {
        let limit = min(max(limit, 1), RuntimePage.most)
        var parts = URLComponents(url: hub.appendingPathComponent("ui/tasks/\(task)/events"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database), .init(name: "after", value: String(after)),
                            .init(name: "limit", value: String(limit))]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 3 MiB for 200 events, and as much for each event of a larger page.
        let (data, _) = try await boundedArtifactRead(request, limit: max(3, (3 * limit + 199) / 200) * 1024 * 1024)
        let page = try JSONDecoder().decode(RuntimePage.self, from: data)
        try page.validate(database: database, task: task, after: after)
        return page
    }

    public func artifacts(in context: ArtifactContext) async throws -> ArtifactList {
        var request = URLRequest(url: try context.listURL())
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await boundedArtifactRead(request, limit: 256 * 1024, checkedOutputs: true, shared: false)
        return try ArtifactList.decode(data, context: context)
    }

    public func desktop(in context: DesktopContext) async throws -> DesktopFrame {
        var request = URLRequest(url: try context.url())
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await boundedArtifactRead(request, limit: 1_500_000, shared: false)
        return try JSONDecoder().decode(DesktopFrame.self, from: data)
    }

    public func artifact(_ artifact: CheckedArtifact, in context: ArtifactContext) async throws -> ArtifactPayload {
        var request = URLRequest(url: try context.fileURL(artifact))
        request.setValue(artifact.mime, forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, _) = try await boundedArtifactRead(request, limit: artifact.bytes, checkedOutputs: true, shared: false) { response in
            try ArtifactValidation.response(response, artifact: artifact, context: context)
        }
        return try ArtifactValidation.payload(data, artifact: artifact)
    }

    /// A bounded read of the hub. **An identical read on its way shares its answer** (`HubReads`), unless the caller
    /// checks the answer in a way of its own (`shared: false`: a checked output, a desktop frame).
    private func boundedArtifactRead(_ request: URLRequest, limit: Int, checkedOutputs: Bool = false, shared: Bool = true,
                                     validate: @escaping @Sendable (HTTPURLResponse) throws -> Void = { _ in }) async throws -> (Data, HTTPURLResponse) {
        guard shared, let key = HubReads.key(request, in: session.configuration), let url = request.url else {
            return try await transferRead(request, limit: limit, checkedOutputs: checkedOutputs, validate: validate)
        }
        let answer = try await reads.share(key) { [self] in
            let (data, response) = try await transferRead(request, limit: limit, checkedOutputs: checkedOutputs,
                                                          validate: validate)
            return HubReads.Answer(data: data, response: response)
        }
        // An answer that another client's read of the same address and limits brought keeps this read's own bound.
        guard answer.data.count <= limit else { throw ArtifactError.size }
        guard let response = answer.response ?? HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw HubError.invalidResponse
        }
        return (answer.data, response)
    }

    private func transferRead(_ request: URLRequest, limit: Int, checkedOutputs: Bool,
                              validate: @Sendable (HTTPURLResponse) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        // A separate ephemeral session lets every failure/cancellation stop the transfer immediately.
        let transfer = URLSession(configuration: session.configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { transfer.invalidateAndCancel() }
        let (bytes, response) = try await transfer.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw ArtifactError.identity }
        if response.statusCode != 200 {
            throw Self.readRefusal(status: response.statusCode, body: await Self.refusalBody(bytes), checkedOutputs: checkedOutputs)
        }
        guard response.expectedContentLength <= limit else { throw ArtifactError.size }
        try validate(response)
        var data = Data()
        data.reserveCapacity(min(limit, 256 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw ArtifactError.size }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        // A read of the hub that is on its way already is the answer to the same read now (`HubReads`); a write never is.
        guard let key = HubReads.key(request, in: session.configuration) else { return try await send(request) }
        return try await reads.share(key) { [self] in
            HubReads.Answer(data: try await send(request), response: nil)
        }.data
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, Self.words(in: data)) }
        return data
    }

    /// The error for a read the hub refused. **Every status carries the hub's own sentence**, which this path used
    /// to throw away: a 403 and a 503 both reached the owner as a bare number, on all ten screens that read through
    /// it, while the hub had written him a line about each.
    ///
    /// `checkedOutputs` is the one exception, and only the two reads of a task's checked outputs ask for it, because
    /// that screen **acts** on two statuses: 409 says the list it holds is no longer the hub's, so `ArtifactPreview`
    /// empties it, and 422 that the hub blocked text carrying a registered login. Everywhere else a 409 means the
    /// hub's generation changed — the hub writes "hub generation changed; refresh state" — and the outputs' sentence,
    /// "The checked output list changed. Reload checked outputs.", was the wrong one on the other eight screens.
    ///
    /// The flag is why `ArtifactError.stale` keeps no words of its own: `Desktop` throws it for a screenshot that is
    /// too old, which is no refusal and has no sentence to carry, and words on that case would still leave the eight
    /// screens showing the outputs' line unless each one read the payload.
    static func readRefusal(status: Int, body: Data, checkedOutputs: Bool) -> Error {
        switch status {
        case 409 where checkedOutputs: return ArtifactError.stale
        case 422 where checkedOutputs: return ArtifactError.refusedText
        default: return HubError.refusal(status, words(in: body))
        }
    }

    /// The `{"error": ...}` line of a refusal, or `HubError.unexplained` when it carried none.
    static func words(in body: Data) -> String {
        let said = ((try? JSONDecoder().decode(ErrorBody.self, from: body))?.error ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? HubError.unexplained : String(said.prefix(500))
    }

    /// The refusal's own body, bounded: the hub writes one line, and a body that will not read must not hide the
    /// status behind it.
    private static func refusalBody(_ bytes: URLSession.AsyncBytes) async -> Data {
        var body = Data()
        body.reserveCapacity(4096)
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 8192 { break }
            }
        } catch {}
        return body
    }

    struct ErrorBody: Decodable { let error: String }
}
