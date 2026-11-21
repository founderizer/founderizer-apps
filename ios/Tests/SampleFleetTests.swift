import FleetCore
import Foundation
import Network
import Testing
@testable import FleetMobile

/// The sample fleet (`SampleFleet.swift`): what a phone with no hub can look at, read through the phone's own client
/// as a hub's answers, with every write refused in the hub's words and nothing of it kept.
@Suite("The sample fleet", .serialized)
struct SampleFleetTests {
    private let client = MobileClient(answering: SampleHub.host, with: SampleHub.self)
    private let began = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("reads as a hub answers it, every time in the day before it began and in its order")
    func reads() async throws {
        SampleHub.begin(at: began)
        let read = try #require(try await client.snapshot(at: SampleHub.address, key: nil, database: nil, etag: nil))
        let fleet = read.snapshot
        #expect(fleet.db == SampleHub.database)
        #expect(fleet.time == began.timeIntervalSince1970)
        #expect(fleet.agents.map(\.title) == ["Fleet Manager", "Customer Support", "Developer", "DevOps", "Marketing"])
        #expect(fleet.needs.count == 2)
        #expect(fleet.tasks.count == 3 && fleet.recent.count == 3)
        let times = fleet.agents.compactMap { $0.last?.ts } + fleet.needs.map(\.raised)
            + (fleet.tasks + fleet.recent).map(\.created)
        #expect(times.count == 13)
        #expect(times.allSatisfy { $0 <= fleet.time && $0 > fleet.time - 86_400 })
        // A task is asked, then started, then busy or delivered, and none of it after the sample began.
        for task in fleet.tasks {
            let started = try #require(task.started), active = try #require(task.last_activity)
            #expect(task.created <= started && started <= active && active <= fleet.time, "\(task.title)")
        }
        for task in fleet.recent {
            let started = try #require(task.started), delivered = try #require(task.delivered)
            #expect(task.created <= started && started <= delivered && delivered <= fleet.time, "\(task.title)")
        }
        // What would call the network from a sample is not in its features.
        let features = Set(fleet.ui_features ?? [])
        #expect(features.isDisjoint(with: ["push", "sealed_push", "live_changes", "recovery_copy"]))
        #expect(features.isSuperset(of: ["mobile", "direct_chat"]))
        // An unchanged sample answers 304, as an unchanged fleet does.
        #expect(try await client.snapshot(at: SampleHub.address, key: nil, database: fleet.db, etag: read.etag) == nil)
    }

    @Test("has every chat and every task, and nothing after their cursors")
    func pages() async throws {
        SampleHub.begin(at: began)
        let fleet = try #require(try await client.snapshot(at: SampleHub.address, key: nil, database: nil, etag: nil))
            .snapshot
        for agent in fleet.agents {
            let page = try await client.chat(at: SampleHub.address, key: nil, database: fleet.db, agent: agent.name,
                                             since: nil)
            #expect(!page.items.isEmpty, "\(agent.name)")
            #expect(page.cursor == page.items.last?.ts)
            let after = try await client.chat(at: SampleHub.address, key: nil, database: fleet.db, agent: agent.name,
                                              since: page.cursor)
            #expect(after.items.isEmpty && after.cursor == page.cursor)
        }
        for head in fleet.tasks + fleet.recent {
            let page = try await client.task(at: SampleHub.address, key: nil, database: fleet.db, id: head.id, since: 0)
            #expect(page.task.title == head.title)
            let after = try await client.task(at: SampleHub.address, key: nil, database: fleet.db, id: head.id,
                                              since: page.cursor)
            #expect(after.notes.isEmpty && after.cursor == page.cursor)
        }
    }

    @Test("refuses every write in the hub's words")
    func refuses() throws {
        var post = URLRequest(url: SampleHub.address.appendingPathComponent("ui/messages"))
        post.httpMethod = "POST"
        let answer = SampleHub.answer(post)
        #expect(answer.status == 409)
        let response = try #require(HTTPURLResponse(url: post.url!, statusCode: answer.status, httpVersion: nil,
                                                    headerFields: nil))
        do {
            _ = try MobileClient.check(response, data: answer.body)
            Issue.record("a write in the sample was taken")
        } catch let error as MobileError {
            #expect(error.notSentWords == "Not sent: This is a sample.")
            #expect(error.isDefinitive)
        }
        // A route that the sample does not have is not found, as on a hub.
        #expect(SampleHub.answer(URLRequest(url: SampleHub.address.appendingPathComponent("ui/owner/devices"))).status
            == 404)
    }

    @MainActor @Test("a phone with no hub reads nothing and says nothing about a hub")
    func noHub() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            #expect(store.hasNoHub && store.addressText.isEmpty)
            await store.refresh()
            #expect(store.lastRead == nil && store.readError == nil)
            #expect(store.unavailableWords == nil && !store.readsTheHub)
            #expect(store.keyWords == nil && !store.keyIsHeldBack)
        }
    }

    @MainActor @Test("opens, refuses a message and a file, and leaves nothing of itself behind")
    func store() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            try #require(store.pending == nil, "the simulator holds a request of its own")
            let before = Self.keptState()
            store.startSample()
            store.chatRoute = [.chat("wren")]
            await store.refresh()
            #expect(store.sample && store.hub == SampleHub.address && !store.hasNoHub)
            #expect(store.agents.count == 5 && store.unavailableWords == nil && !store.keyIsHeldBack)
            #expect(store.hasRead(chat: "wren"))
            store.setDraft("Ship it on Monday.", for: "theo")
            store.setAnswerDraft("Refund it", for: 1)
            store.setDraft("Offer the customer a voucher instead.", for: "wren")
            await store.send(to: "wren")
            // The request is marked as refused, and its line is made from the refusal's fields when it is read.
            #expect(store.pending?.refusal != nil && store.pending?.notSentLine == "Not sent: This is a sample.")
            // It was kept as the hub's refusal: its status and its words, the sample's own, and no code.
            #expect(store.pending?.hubRefusal == HubRefusal(status: 409, hubWords: SampleHub.refusal))
            let composer = MobileStore.stageKey(agent: "wren")
            await store.stage(Data("x".utf8), name: "note.txt", mime: "text/plain", for: composer)
            #expect(store.fileError == "Not sent: This is a sample.")
            #expect(store.stagedFiles(for: composer).isEmpty)
            // Nothing of it was written to this phone: drafts, answers, seen marks, files, readings, chats.
            #expect(Self.keptState() == before)
            store.leaveSample()
            #expect(!store.sample && store.hasNoHub && store.pending == nil && store.snapshot == nil)
            #expect(store.draft(for: "theo").isEmpty && store.answerDraft(for: 1).isEmpty)
            #expect(try Outbox(file: Self.support.appendingPathComponent("pending.json")).load() == nil)
            #expect(Self.keptState() == before)
        }
    }

    @MainActor @Test("a start after a launch that ended inside the sample finds nothing of it")
    func endedInside() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            try #require(store.pending == nil, "the simulator holds a request of its own")
            store.startSample()
            await store.refresh()
            store.setDraft("Offer the customer a voucher instead.", for: "wren")
            await store.send(to: "wren")
            // The request is marked as refused, and its line is made from the refusal's fields when it is read.
            #expect(store.pending?.refusal != nil && store.pending?.notSentLine == "Not sent: This is a sample.")
            // No Leave: the app ends inside the sample, and starts again.
            let next = MobileStore()
            #expect(next.pending == nil && !next.sample && next.hasNoHub)
            #expect(try Outbox(file: Self.support.appendingPathComponent("pending.json")).load() == nil)
        }
    }

    @MainActor @Test("a hub of his own ends the sample, and the sample's address is no hub")
    func connect() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            store.startSample()
            store.addressText = "http://sample.founderizer.invalid"
            await store.connect()
            #expect(store.sample && store.addressError != nil)
            store.addressText = "http://127.0.0.1:9"
            await store.connect()
            #expect(!store.sample && store.hub == URL(string: "http://127.0.0.1:9/"))
        }
    }

    /// **The Mac's code link joins with no line about the phone's key** (`MobileStore.openLink`). A recording on an
    /// iPhone 18 Pro (11 November 2026) showed "The hub wants this phone's key and the phone sent none" over Chats for
    /// the quarter second of the enrolment: the phone read the hub with no key before it had one.
    @MainActor @Test("the Mac's code link joins a phone with no hub, and no line about its key shows at any moment",
                     .timeLimit(.minutes(1)))
    func linkJoins() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = LinkHub()
                defer { hub.stop() }
                let address = try await hub.start()
                // A key of the check's own: the key of an enrolled phone is never touched.
                let holder = DeviceKey(account: "device-key-link-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                #expect(store.hasNoHub && store.keyState == .none)
                store.chatRoute = [.settings, .enroll]
                let link = try #require(URL(string: "fleet://enroll?hub=\(address)&code=ABCD-2345"))
                let join = Task { await store.openLink(link) }
                // The enrolment is on its way, and the hub holds its answer: the phone is at the hub and says nothing
                // about its key.
                for await request in hub.requests where request == "POST /ui/owner/enroll" { break }
                #expect(store.hub.absoluteString == address + "/" && !store.hasNoHub)
                #expect(store.unavailableWords == nil && store.authProblem == nil && store.readError == nil)
                hub.answerEnrolment()
                await join.value
                // No read went before the key, so the hub had no read to refuse.
                #expect(hub.log == ["POST /ui/owner/enroll", "GET /ui/mobile with the key"])
                #expect(store.keyState == .ready && store.lastRead != nil && store.snapshot?.db == "gen-link")
                #expect(store.unavailableWords == nil && store.authProblem == nil && store.readError == nil)
                #expect(store.tab == .chats && store.chatRoute.isEmpty)
            }
        }
    }

    /// Where the store keeps its files on this phone.
    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FleetMobile")

    /// Everything that the store keeps between launches, apart from the outbox: a check compares it before and after.
    @MainActor private static func keptState() -> NSDictionary {
        var kept: [String: Any] = [:]
        for key in ["agentDrafts", "answerDrafts", "mobileRepliesSeen", "stagedFiles"] {
            kept[key] = UserDefaults.standard.object(forKey: key) ?? "none"
        }
        for name in ["snapshot.json", "chats.json"] {
            kept[name] = (try? Data(contentsOf: support.appendingPathComponent(name))) ?? "none"
        }
        return kept as NSDictionary
    }

    /// Runs `body` on a phone with no hub address saved, and puts back the one that the simulator had.
    @MainActor private static func withoutHub(_ body: () async throws -> Void) async throws {
        let saved = UserDefaults.standard.string(forKey: "hubAddress")
        UserDefaults.standard.removeObject(forKey: "hubAddress")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "hubAddress") }
            else { UserDefaults.standard.removeObject(forKey: "hubAddress") }
        }
        try await body()
    }

    /// Runs `body` and puts back what a read of a hub writes to this phone: the fleet and the chats that it keeps, and
    /// the replies that it saw.
    @MainActor private static func keepingReadings(_ body: () async throws -> Void) async throws {
        let files = ["snapshot.json", "chats.json"].map { support.appendingPathComponent($0) }
        let kept = files.map { try? Data(contentsOf: $0) }
        let seen = UserDefaults.standard.object(forKey: "mobileRepliesSeen")
        defer {
            for (file, data) in zip(files, kept) {
                if let data { try? data.write(to: file, options: .atomic) }
                else { try? FileManager.default.removeItem(at: file) }
            }
            if let seen { UserDefaults.standard.set(seen, forKey: "mobileRepliesSeen") }
            else { UserDefaults.standard.removeObject(forKey: "mobileRepliesSeen") }
        }
        try await body()
    }

    /// Waits until `done` holds: it looks again every 20 ms, and the event ends the wait, not a time. The bound, 20 s
    /// inside the test's own limit, only makes a regression fail at the expectation that follows, in place of a hang.
    @MainActor private static func until(_ done: () -> Bool) async throws {
        for _ in 0..<1_000 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }
}

/// **A hub on this Mac's loopback**, for a check of the phone's own client: it listens on the loopback alone, takes each
/// request once its head and its whole body are here, and answers it as its kind says (`answer`). Each answer closes its
/// connection, and the hub keeps the requests that its kind notes, in order.
private class LoopbackHub: @unchecked Sendable {
    /// Each request that the hub notes, as it comes.
    let requests: AsyncStream<String>
    private let arrived: AsyncStream<String>.Continuation
    private let queue: DispatchQueue
    let lock = NSLock()
    private var listener: NWListener?
    private var seen: [String] = []

    init(label: String) {
        queue = DispatchQueue(label: label)
        let made = AsyncStream.makeStream(of: String.self)
        requests = made.stream
        arrived = made.continuation
    }

    /// Every request so far, in order.
    var log: [String] { lock.withLock { seen } }

    /// Starts listening on the loopback alone, and gives the hub's address.
    func start() async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.take(connection) }
        listener.start(queue: queue)
        lock.withLock { self.listener = listener }
        var tries = 0
        while (listener.port?.rawValue ?? 0) == 0, tries < 150 {
            tries += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let port = listener.port?.rawValue, port != 0 else { throw URLError(.cannotConnectToHost) }
        return "http://127.0.0.1:\(port)"
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
        arrived.finish()
    }

    /// One whole request, which the hub's kind answers. A hub of no kind cuts it.
    func answer(_ request: Request, on connection: NWConnection) { connection.cancel() }

    private func take(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, bytes: Data())
    }

    private func read(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] piece, _, done, error in
            guard let self, error == nil else { return connection.cancel() }
            let all = bytes + (piece ?? Data())
            if let request = Request(all) { return self.answer(request, on: connection) }
            if done || all.count > 1_000_000 { return connection.cancel() }
            self.read(connection, bytes: all)
        }
    }

    func note(_ request: String) {
        lock.withLock { seen.append(request) }
        arrived.yield(request)
    }

    func send(_ reply: Data, on connection: NWConnection) {
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func reply(_ status: Int, _ body: String) -> Data {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Refused")\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }

    /// One request, once its head and its whole body are here.
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        init?(_ bytes: Data) {
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let lines = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            guard first.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard bytes.count - end.upperBound >= length else { return nil }
            method = String(first[0])
            path = String(first[1].split(separator: "?").first ?? "")
            self.headers = headers
            body = Data(bytes[end.upperBound...].prefix(length))
        }
    }
}

/// **A hub for the Mac's code link** (`MobileStore.openLink`): it refuses a read with no key in the hub's words for an
/// owner device, gives a key for the code, and answers a read that carries that key. It holds its answer to the
/// enrolment until the check has looked at the phone, and it keeps every request, in order.
private final class LinkHub: LoopbackHub, @unchecked Sendable {
    static let key = "a-key-that-the-check-hub-gave"
    /// The enrolment's connection and its answer, until the check lets the answer go.
    private var held: (connection: NWConnection, reply: Data)?
    private var letGo = false

    init() { super.init(label: "founderizer.check.link-hub") }

    override func stop() {
        let held = lock.withLock { () -> NWConnection? in
            defer { self.held = nil }
            return self.held?.connection
        }
        held?.cancel()
        super.stop()
    }

    /// The answer to the enrolment goes.
    func answerEnrolment() {
        let held = lock.withLock { () -> (connection: NWConnection, reply: Data)? in
            letGo = true
            defer { self.held = nil }
            return self.held
        }
        if let held { send(held.reply, on: held.connection) }
    }

    override func answer(_ request: Request, on connection: NWConnection) {
        let route = "\(request.method) \(request.path)"
        switch route {
        case "GET /ui/mobile":
            let keyed = request.headers["authorization"] == "Bearer \(Self.key)"
            note(route + (keyed ? " with the key" : " with no key"))
            send(keyed ? Self.reply(200, Self.fleet)
                       : Self.reply(403, #"{"error": "device key required", "auth": "device_key_required"}"#),
                 on: connection)
        case "POST /ui/owner/enroll":
            note(route)
            let reply = Self.reply(200, #"{"device": "phone-check", "label": "iPhone", "key": "\#(Self.key)"}"#)
            let now = lock.withLock { () -> Bool in
                if letGo { return true }
                held = (connection, reply)
                return false
            }
            if now { send(reply, on: connection) }
        default:
            note(route)
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    /// The hub's compact read of a fleet with nothing in it.
    private static let fleet = #"{"schema_version": 1, "db": "gen-link", "time": 1800000000, "ui_features": ["mobile"], "#
        + #""agents": [], "needs": [], "tasks": [], "recent": [], "holds": [], "outcomes": []}"#
}

/// **A hub with one card that takes his message under it** (Needs clarification on every card, owner feature
/// `need_clarify`): it answers a read with that card, and his message under it as `mode` says: with the hub's receipt of
/// the command, whose talk has the message; by a cut connection before it takes the message, as a hub that went away;
/// by a cut connection after it took the message, as an answer that was lost on its way back; or with the hub's
/// refusal. A repeat of a request that it took gets that request's first result, as the hub's own record answers it.
/// Its read has the messages that it took only while `readsTalk` is set: else they have not reached that read yet.
private final class TalkHub: LoopbackHub, @unchecked Sendable {
    enum Mode { case answers, cutsBefore, cutsAfter, refuses }
    private var answering = Mode.answers
    private var reading = false
    private var ids: [String] = []
    /// The messages that it took, by request, in order.
    private var taken: [(id: String, text: String)] = []

    init() { super.init(label: "founderizer.check.talk-hub") }

    var mode: Mode {
        get { lock.withLock { answering } }
        set { lock.withLock { answering = newValue } }
    }

    var readsTalk: Bool {
        get { lock.withLock { reading } }
        set { lock.withLock { reading = newValue } }
    }

    /// The request number of each message that came, a cut one too, in order.
    var messages: [String] { lock.withLock { ids } }

    override func answer(_ request: Request, on connection: NWConnection) {
        let route = "\(request.method) \(request.path)"
        note(route)
        switch route {
        case "GET /ui/mobile":
            send(Self.reply(200, fleet()), on: connection)
        case "POST /ui/needs/7/talk":
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            guard let id = fields["request_id"] as? String, let text = fields["text"] as? String else {
                return send(Self.reply(400, #"{"error": "request_id and text are required"}"#), on: connection)
            }
            let (mode, lines) = lock.withLock { () -> (Mode, [(id: String, text: String)]) in
                ids.append(id)
                let known = taken.contains { $0.id == id }
                if !known && (answering == .answers || answering == .cutsAfter) { taken.append((id, text)) }
                return (known ? .answers : answering, taken)
            }
            switch mode {
            case .cutsBefore, .cutsAfter:
                connection.cancel()
            case .refuses:
                send(Self.reply(409, #"{"error": "this request takes no message now"}"#), on: connection)
            case .answers:
                let talk = Self.talk(lines.prefix { $0.id != id } + lines.filter { $0.id == id })
                let receipt: [String: Any] = ["need": 7, "talk": talk, "ok": true, "request_id": id,
                                              "client": request.headers["x-fleet-client"] ?? "", "replayed": false]
                let body = (try? JSONSerialization.data(withJSONObject: receipt)).map { String(decoding: $0, as: UTF8.self) }
                send(Self.reply(200, body ?? "{}"), on: connection)
            }
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    /// The talk's lines of these messages, his, a minute apart.
    private static func talk(_ lines: [(id: String, text: String)]) -> [[String: Any]] {
        lines.enumerated().map { ["who": "owner", "text": $1.text, "ts": 1_800_000_060 + 60 * $0] }
    }

    /// The hub's compact read: one open card of the manager's, with three options, that takes his message under it.
    private func fleet() -> String {
        let talk = readsTalk ? lock.withLock { Self.talk(taken) } : []
        let card: [String: Any] = [
            "id": 7, "by": "manager", "title": "Refund an order from 45 days ago?",
            "why": "A customer asks for a refund 15 days after the 30-day window.", "todo": "", "raised": 1_799_999_000,
            "answer": NSNull(), "answered": NSNull(), "options": ["Refund it", "Offer a 20% voucher", "Say no, politely"],
            "clarify": true, "talk": talk,
        ]
        let fleet: [String: Any] = [
            "schema_version": 1, "db": "gen-talk", "time": 1_800_000_000,
            "ui_features": ["mobile", "need_options", "need_clarify"], "agents": [], "needs": [card], "tasks": [],
            "recent": [], "holds": [], "outcomes": [],
        ]
        return (try? JSONSerialization.data(withJSONObject: fleet)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension SampleFleetTests {
    /// **A press on the words that an item's agent recommends waits as a press on an option waits** (owner feature
    /// `need_recommended`; two reviews of 20 November 2026): behind the item's own answer that waits unsent it is
    /// dropped, so his Discard of that answer sends nothing in its place. The press waited in a task of its own, and
    /// the agent's words went by themselves after the Discard.
    @MainActor @Test("a press on the agent's words is dropped behind the item's own refused answer, and Discard sends nothing")
    func aPressOnTheAgentsWordsIsDroppedBehindARefusedAnswer() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            try #require(store.pending == nil, "the simulator holds a request of its own")
            store.startSample()
            defer { store.leaveSample() }
            await store.refresh()
            try #require(store.canWrite && store.openNeeds.contains(where: { $0.id == 1 }))

            let words = "Offer a 20% voucher"
            store.press(needID: 1, words: words)
            // the words stand in the field at once, as if he had typed them, and the sample refuses them
            #expect(store.answerDraft(for: 1) == words)
            for _ in 0..<60 where store.pending?.refusal == nil { try await Task.sleep(for: .milliseconds(50)) }
            try #require(store.pending?.refusal != nil && store.waitsUnsent(for: 1))

            // a second press while that answer waits unsent does not wait behind it, and it leaves his field as it
            // is: only Try again moves that answer
            store.setAnswerDraft("Ask the customer first", for: 1)
            store.press(needID: 1, words: words)
            #expect(store.waitingPresses[1] == nil)
            #expect(store.answerDraft(for: 1) == "Ask the customer first")
            store.discardRefused()
            #expect(store.pending == nil)
            try await Task.sleep(for: .milliseconds(800))
            #expect(store.pending == nil, "a press that waited went after the Discard")
        }
    }
}

extension SampleFleetTests {
    /// **His message under a card goes once, as the hub's command** (Needs clarification on every card, owner feature
    /// `need_clarify`): words that look like a key never reach the Outbox or the hub; a message whose send the hub cut
    /// waits unsent with its words, and a press on the card's options behind it is dropped, as behind the card's own
    /// answer; Try again sends the same request, whose receipt is a command's; the message stands in the card from that
    /// receipt; a message whose receipt was lost is confirmed by the next read that has it in the card's talk, and an
    /// older line of his with the same words sends nothing by itself; and the Discard of a refused message gives its
    /// words back to the card's field, never to the manager's chat. Read as an answer's receipt, which has an event and
    /// a time, every message that the hub took waited as "Not sent", and so did each Try again, with every later write
    /// of the phone behind it; a press behind the message waited with no end, and the card said "Sending…" in place of
    /// its "Not sent"; a lost receipt left his message in the talk and in the field at once, under "Not sent".
    @MainActor @Test("a message under a card goes once as the hub's command, and a press does not wait behind it",
                     .timeLimit(.minutes(1)))
    func aMessageUnderACardGoesOnceAsTheHubsCommand() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = TalkHub()
                defer { hub.stop() }
                let address = try await hub.start()
                // A key of the check's own, which holds none: the reads go with no key, and an enrolled phone's key is
                // never touched.
                let holder = DeviceKey(account: "device-key-talk-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                try #require(store.pending == nil, "the simulator holds a request of its own")
                // whatever this check leaves in the Outbox goes with it
                defer {
                    if let left = store.pending {
                        try? Outbox(file: Self.support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                store.addressText = address
                await store.connect()
                let card = try #require(store.openNeeds.first)
                try #require(store.canWrite && card.id == 7 && card.clarifies(features: Array(store.features)))
                let chatDraft = store.draft(for: "manager")

                // a key in his words: nothing is saved, and nothing goes
                await store.talk(needID: 7, words: "Use this one: " + "sk-" + "ant-api03-" + String(repeating: "EXAMPLE", count: 4))
                #expect(store.pending == nil && hub.messages.isEmpty)

                // a send that the hub cut: the message waits unsent with its words, no read looks for it in a chat,
                // and a press on the card is dropped
                let first = "Is it the same customer as last month?"
                store.setClarifyDraft(first, for: 7)
                hub.mode = .cutsBefore
                await store.talk(needID: 7, words: first)
                try #require(store.pending?.talkNeed == 7 && store.pending?.refusal == nil && hub.messages.count == 1)
                await store.refresh()
                #expect(store.waitsUnsent(for: 7) && store.clarifyKept(for: 7) == first && store.readError == nil)
                #expect(hub.log.allSatisfy { $0 == "GET /ui/mobile" || $0 == "POST /ui/needs/7/talk" })
                store.press(needID: 7, choice: 1)
                #expect(store.waitingPresses[7] == nil)

                // Try again: the same request, which the hub's receipt confirms, and the card shows it from that
                // receipt, before a read has it
                hub.mode = .answers
                await store.retry()
                #expect(store.pending == nil && store.sendError == nil)
                #expect(hub.messages.count == 2 && Set(hub.messages).count == 1)
                let talk = store.talk(of: try #require(store.openNeeds.first))
                #expect(talk.map(\.text) == [first] && talk.allSatisfy(\.fromOwner))
                #expect(store.clarifyDraft(for: 7).isEmpty && store.talkReceipts[7] == 1)

                // a receipt that was lost: the next read has the message in the card's talk, and that request goes
                // once more, which the hub's first result confirms
                hub.readsTalk = true
                hub.mode = .cutsAfter
                let second = "And the voucher, does it end this month?"
                await store.talk(needID: 7, words: second)
                // (it goes again in a task of the store's own, and that send ends with a read: until both ended, the
                // store takes no message, and on a slow Mac the next step's message was dropped)
                try await Self.until { store.pending == nil && !store.sending }
                #expect(store.pending == nil && store.talkReceipts[7] == 2)
                #expect(hub.messages.count == 4 && Set(hub.messages).count == 2)
                #expect(store.talk(of: try #require(store.openNeeds.first)).map(\.text) == [first, second])

                // the same words again, cut before the hub took them: his older line with those words is no sign that
                // the hub has them, so no read sends them by itself, and his Try again does
                try #require(store.canWrite)
                hub.mode = .cutsBefore
                await store.talk(needID: 7, words: second)
                // The send's own read has his line with those words. A read that sends them by itself does it in a
                // task of its own, which begins at the first wait of the store after it: the wait of one more read.
                // So, when that read ended and no send is on its way, each send of a read is at the hub.
                await store.refresh()
                try await Self.until { !store.sending }
                #expect(hub.messages.count == 5 && store.pending?.talkNeed == 7 && store.pending?.refusal == nil)
                hub.mode = .answers
                await store.retry()
                #expect(store.pending == nil && hub.messages.count == 6)

                // a refused message: its Discard gives its words back to the card's field, which a start of the app
                // emptied, and never to the manager's chat
                hub.mode = .refuses
                let third = "Can you ask them first?"
                await store.talk(needID: 7, words: third)
                try #require(store.pending?.refusal != nil)
                store.setClarifyDraft("", for: 7)
                store.discardRefused()
                #expect(store.pending == nil && store.clarifyDraft(for: 7) == third)
                #expect(store.draft(for: "manager") == chatDraft)
            }
        }
    }
}
