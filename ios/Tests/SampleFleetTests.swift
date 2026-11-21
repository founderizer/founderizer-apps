import FleetCore
import Foundation
import Network
import SwiftUI
import Testing
import UIKit
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

/// **A hub with three requests of pictures** (owner feature `need_pictures`, owner API 1.285): request 7 has three options
/// and a picture for each, request 8 three options and two pictures, request 9 three options that combine (`multi`) and
/// a picture for each. It gives each picture's bytes and takes an answer to each request with the hub's receipt, and it
/// keeps the body of each answer and the number of each picture that was read, in order. While `holdsPictures` is set,
/// it holds the bytes of each picture, and while `holdsAnswers` is set its receipt of each answer, until `release`.
private final class PictureHub: LoopbackHub, @unchecked Sendable {
    /// Three small pictures, one colour each, drawn here: no photo, logo or name.
    static let pictures: [Data] = [UIColor.brown, UIColor.orange, UIColor.systemTeal].map { colour in
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
    static let ids = [71, 72, 73]
    private var bodies: [(path: String, body: [String: Any])] = []
    private var pictureReads: [Int] = []
    private var picturesHeld = false
    private var answersHeld = false
    private var held: [(connection: NWConnection, reply: Data)] = []

    init() { super.init(label: "founderizer.check.picture-hub") }

    /// The answers that came, by route, in order.
    var answers: [(path: String, body: [String: Any])] { lock.withLock { bodies } }
    /// The number of each picture that the phone read, in the order that the reads came.
    var reads: [Int] { lock.withLock { pictureReads } }
    var holdsPictures: Bool {
        get { lock.withLock { picturesHeld } }
        set { lock.withLock { picturesHeld = newValue } }
    }
    var holdsAnswers: Bool {
        get { lock.withLock { answersHeld } }
        set { lock.withLock { answersHeld = newValue } }
    }

    /// The bytes and receipts that it holds go, and it holds nothing more.
    func release() {
        let going = lock.withLock { () -> [(connection: NWConnection, reply: Data)] in
            picturesHeld = false
            answersHeld = false
            defer { held = [] }
            return held
        }
        for (connection, reply) in going { send(reply, on: connection) }
    }

    override func answer(_ request: Request, on connection: NWConnection) {
        note("\(request.method) \(request.path)")
        switch (request.method, request.path) {
        case ("GET", "/ui/mobile"):
            send(Self.reply(200, Self.fleet), on: connection)
        case ("GET", let path) where path.hasPrefix("/ui/attachments/"):
            guard let id = Int(path.dropFirst("/ui/attachments/".count)), let index = Self.ids.firstIndex(of: id) else {
                return send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
            }
            let bytes = Self.pictures[index]
            let head = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(bytes.count)\r\n"
                + "Connection: close\r\n\r\n"
            let holds = lock.withLock { pictureReads.append(id); return picturesHeld }
            reply(Data(head.utf8) + bytes, on: connection, holds: holds)
        case ("POST", "/ui/needs/7"), ("POST", "/ui/needs/8"), ("POST", "/ui/needs/9"):
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let holds = lock.withLock { bodies.append((request.path, fields)); return answersHeld }
            let receipt: [String: Any] = ["ok": true, "request_id": fields["request_id"] as? String ?? "",
                                          "client": request.headers["x-fleet-client"] ?? "", "event_id": 101,
                                          "created": 1_800_000_100, "replayed": false]
            let body = (try? JSONSerialization.data(withJSONObject: receipt)).map { String(decoding: $0, as: UTF8.self) }
            reply(Self.reply(200, body ?? "{}"), on: connection, holds: holds)
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    /// The reply goes now, or waits for `release`.
    private func reply(_ data: Data, on connection: NWConnection, holds: Bool) {
        let now = lock.withLock { () -> Bool in
            // (a release between the hold's read and this line lets it go now)
            guard holds, picturesHeld || answersHeld else { return true }
            held.append((connection, data))
            return false
        }
        if now { send(data, on: connection) }
    }

    /// One picture as the hub gives it with an item.
    private static func picture(_ index: Int) -> [String: Any] {
        ["id": ids[index], "name": "ad-\(index + 1).png", "mime": "image/png", "size": pictures[index].count,
         "sha256": MessageAttachment.digest(pictures[index]), "created": 1_799_999_000, "kept": NSNull()]
    }

    /// The hub's compact read: requests 7, 8 and 9, all of the manager's.
    private static let fleet: String = {
        let options = ["Dark, the bottle", "Orange, big words", "Blue, the morning"]
        func card(_ id: Int, pictures: [[String: Any]], multi: Bool = false) -> [String: Any] {
            ["id": id, "by": "manager", "title": "Pick the ad for the launch", "why": "Three versions of the launch ad.",
             "todo": "", "raised": 1_799_999_000 + id, "answer": NSNull(), "answered": NSNull(), "options": options,
             "pictures": pictures, "multi": multi]
        }
        let fleet: [String: Any] = [
            "schema_version": 1, "db": "gen-pictures", "time": 1_800_000_000,
            "ui_features": ["mobile", "need_options", "need_pictures"], "agents": [],
            "needs": [card(7, pictures: (0..<3).map(picture)), card(8, pictures: (0..<2).map(picture)),
                      card(9, pictures: (0..<3).map(picture), multi: true)],
            "tasks": [], "recent": [], "holds": [], "outcomes": [],
        ]
        return (try? JSONSerialization.data(withJSONObject: fleet)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }()
}

/// **A request's card of the app in a window of the check**, with each of its parts as VoiceOver finds it: the check
/// presses a part as VoiceOver does (`accessibilityActivate`), which runs that part's own action, and reads which parts
/// the card has by their identifiers, and their state by their traits. Each test closes its window (`close`).
@MainActor private final class CardWindow {
    let window: UIWindow

    /// **SwiftUI gives its views' parts to an accessibility client only while accessibility is on**: in a test process
    /// nothing turns it on, and the card had no part at all. The system's own switches for an automation client turn it
    /// on (as KIF does) while a window of a check stands, and `close` turns them off again: a test host that ended
    /// before its exit left them on in the simulator.
    private static func accessibility(_ on: Bool) {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard let library = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW)
                ?? dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return }
        for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
            if let set = dlsym(library, name) { unsafeBitCast(set, to: (@convention(c) (Int32) -> Void).self)(on ? 1 : 0) }
        }
    }

    init(_ card: some View) {
        Self.accessibility(true)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 1600)
        window.rootViewController = UIHostingController(rootView: card)
        window.isHidden = false
        window.layoutIfNeeded()
    }

    /// Every element under the window that names an identifier, by it.
    var parts: [String: NSObject] {
        var found: [String: NSObject] = [:]
        for next in elements {
            // (SwiftUI's parts answer the identifier's message, and are no UIAccessibilityIdentification)
            let selector = NSSelectorFromString("accessibilityIdentifier")
            let named = next.responds(to: selector) ? next.perform(selector)?.takeUnretainedValue() as? String : nil
            if let id = named, !id.isEmpty { found[id] = next }
        }
        return found
    }

    /// The actions "Copy …" of each element under the window that has one, in each element's order: VoiceOver's copy
    /// of a request's values (`CardValueWords`).
    var copies: [[UIAccessibilityCustomAction]] {
        elements.compactMap { element in
            let copies = (element.accessibilityCustomActions ?? []).filter { $0.name.hasPrefix("Copy ") }
            return copies.isEmpty ? nil : copies
        }
    }

    /// Every element under the window, the window first.
    private var elements: [NSObject] {
        var found: [NSObject] = []
        var waiting: [NSObject] = [window]
        var seen = Set<ObjectIdentifier>()
        while let next = waiting.popLast() {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            found.append(next)
            if let view = next as? UIView { waiting += view.subviews }
            if let children = next.accessibilityElements as? [NSObject] {
                waiting += children
            } else {
                let count = next.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    waiting += (0..<count).compactMap { next.accessibilityElement(at: $0) as? NSObject }
                }
            }
        }
        return found
    }

    /// Presses the part with this identifier, as VoiceOver does: true when it took the press.
    func press(_ id: String) -> Bool { parts[id]?.accessibilityActivate() == true }

    /// The names of VoiceOver's actions of the part with this identifier, in their order.
    func actions(of id: String) -> [String] { (parts[id]?.accessibilityCustomActions ?? []).map(\.name) }

    /// Runs the action of this name of the part with this identifier, as VoiceOver does: true when it took it.
    func perform(_ name: String, of id: String) -> Bool {
        guard let action = parts[id]?.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
        return Self.perform(action)
    }

    /// Runs an action of an element as VoiceOver does: true when it took it.
    static func perform(_ action: UIAccessibilityCustomAction) -> Bool {
        if let handler = action.actionHandler { return handler(action) }
        guard let target = action.target as? NSObject else { return false }
        _ = target.perform(action.selector, with: action)
        return true
    }

    /// The part with this identifier has this trait now (a tick `.selected`, a Send that takes no press `.notEnabled`).
    func has(_ id: String, _ trait: UIAccessibilityTraits) -> Bool { parts[id]?.accessibilityTraits.contains(trait) == true }

    /// The picture that a press opened stands at full screen over the card.
    var opened: Bool { window.rootViewController?.presentedViewController != nil }

    func close() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        Self.accessibility(false)
    }
}

extension SampleFleetTests {
    /// Runs `body` with a store that read the picture hub, and leaves nothing of it: no key, no reading, no request.
    @MainActor private static func withPictureHub(_ body: (MobileStore, PictureHub) async throws -> Void) async throws {
        try await withoutHub {
            try await keepingReadings {
                let hub = PictureHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let holder = DeviceKey(account: "device-key-picture-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        try? Outbox(file: support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                    let opened = FileManager.default.temporaryDirectory.appendingPathComponent("attachments")
                    for (id, number) in zip(PictureHub.ids, 1...) {
                        try? FileManager.default.removeItem(at: opened.appendingPathComponent("\(id)-ad-\(number).png"))
                    }
                }
                store.addressText = address
                await store.connect()
                try #require(store.canWrite && store.openNeeds.map(\.id).sorted() == [7, 8, 9])
                // A press that still waits goes to this hub before the check cleans up: one that went after it stayed
                // in the simulator's Outbox, and each later check of a store found a request there. A press's own task
                // starts on the next turn of the main actor, so the check gives it that turn before it looks.
                var failure: Error?
                do { try await body(store, hub) } catch { failure = error }
                hub.release()
                try? await Task.sleep(for: .milliseconds(300))
                for _ in 0..<60 where !store.waitingPresses.isEmpty || store.sending {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let failure { throw failure }
            }
        }
    }

    /// **A request whose pictures are not one for each option draws the card of before** (owner feature `need_pictures`):
    /// no picture can be known to stand over its own option, so none stands, and the options are the rows of before. A
    /// hub that does not name the feature gets the card of before too. The bug that this stops: two pictures over the
    /// first two of three options, and he picks an ad by the picture of another.
    @MainActor @Test("a request with three options and two pictures draws the card of before", .timeLimit(.minutes(1)))
    func picturesThatAreNotOneForEachOptionDrawNone() async throws {
        try await Self.withPictureHub { store, _ in
            let three = try #require(store.openNeeds.first { $0.id == 7 })
            let two = try #require(store.openNeeds.first { $0.id == 8 })
            #expect(NeedPictures.drawn(three, features: store.features)?.map(\.id) == PictureHub.ids)
            #expect(NeedPictures.drawn(two, features: store.features) == nil)
            #expect(NeedPictures.drawn(three, features: store.features.subtracting(["need_pictures"])) == nil)

            let window = CardWindow(NeedCard(store: store, need: two, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            let parts = Set(window.parts.keys)
            #expect(Set(parts.filter { $0.hasPrefix("need-option-8-") })
                    == ["need-option-8-0", "need-option-8-1", "need-option-8-2"])
            #expect(!parts.contains { $0.hasPrefix("need-picture-") })
        }
    }

    /// **A press of the picture opens it at full screen and answers nothing; a press of its words is the answer**
    /// (owner feature `need_pictures`): the words send `choice` with their option's index, as a press of an option does.
    /// A press while the picture's own read runs opens it when its bytes come. The bugs that this stops: a look at a
    /// picture answers the request, with an ad that he did not mean to pick; a press while the card reads the picture
    /// opens nothing.
    @MainActor @Test("a press of the picture answers nothing, and a press of its words sends that option",
                     .timeLimit(.minutes(1)))
    func aPictureOpensAndItsWordsAnswer() async throws {
        try await Self.withPictureHub { store, hub in
            let need = try #require(store.openNeeds.first { $0.id == 7 })
            hub.holdsPictures = true
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Self.until { hub.reads == [71] }
            try #require(hub.reads == [71], "the card did not read its first picture")
            #expect(Set(window.parts.keys.filter { $0.hasPrefix("need-picture-7-") })
                    == ["need-picture-7-0", "need-picture-7-1", "need-picture-7-2"])

            // the first picture, while the card reads it: it opens when its bytes come, and no answer goes or waits
            #expect(window.press("need-picture-7-0"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.opened)
            hub.release()
            try await Self.until { window.opened }
            #expect(window.opened, "the picture did not open")
            try await Task.sleep(for: .milliseconds(500))
            #expect(hub.answers.isEmpty && store.pending == nil && store.waitingPresses.isEmpty)
            window.window.rootViewController?.dismiss(animated: false)

            // the second option's words: the answer with that option's index, and nothing else
            #expect(window.press("need-option-7-1"))
            try await Self.until { !hub.answers.isEmpty }
            let answer = try #require(hub.answers.first)
            #expect(hub.answers.count == 1 && answer.path == "/ui/needs/7")
            #expect(answer.body["choice"] as? Int == 1 && answer.body["answer"] == nil && answer.body["choices"] == nil)
        }
    }

    /// **The ticked options go as one answer, each once, in their order, and nothing changes them while the Send waits**
    /// (owner feature `need_pictures`, a request whose options combine): behind another answer on its way, his Send
    /// waits, after its wait with Undo (`MobileStore.hold`); the card stands folded with his answer meanwhile, so no tick
    /// and no Send takes a press until it went, and the hub gets `choices` and no words. The bug that this stops: he
    /// changes the ticks while the Send waits, the card shows the new ones, and the old ones go.
    @MainActor @Test("ticked options go as one answer, and nothing changes them while the Send waits", .timeLimit(.minutes(1)))
    func tickedOptionsGoAsOneAnswer() async throws {
        try await Self.withPictureHub { store, hub in
            let need = try #require(store.openNeeds.first { $0.id == 9 })
            store.answerWait = .milliseconds(100)
            // another answer on its way, whose receipt the hub holds
            hub.holdsAnswers = true
            store.press(needID: 7, choice: 0)
            try await Self.until { hub.answers.count == 1 }
            try #require(hub.answers.first?.path == "/ui/needs/7" && store.sending)

            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("need-tick-9-2") && window.press("need-tick-9-0"))
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.press("need-send-ticked-9"))
            try await Task.sleep(for: .milliseconds(400))
            try #require(store.waitingPresses[9] == .ticked([0, 2]), "the Send did not wait behind the other answer")

            // while it waits: the card stands folded with his two options, and no tick or Send is there to press
            let parts = Set(window.parts.keys)
            #expect(!parts.contains { $0.hasPrefix("need-tick-9-") } && !parts.contains("need-send-ticked-9"))
            #expect(!parts.contains("need-undo-9"), "the Send that waits for the hub still offered Undo")

            // the other answer's receipt: the Send goes, with the indexes of the ticked options
            hub.release()
            try await Self.until { hub.answers.count == 2 }
            let answer = try #require(hub.answers.last)
            #expect(answer.path == "/ui/needs/9")
            #expect(answer.body["choices"] as? [Int] == [0, 2])
            #expect(answer.body["answer"] == nil && answer.body["choice"] == nil)
        }
    }

    /// **A card reads its pictures one after another, in the order of its options** (owner feature `need_pictures`):
    /// each read has the client's limit of 15 seconds. The bug that this stops: six large pictures read at once on a slow
    /// link, each ends "Not loaded", and he has no picture to choose by.
    @MainActor @Test("a card reads its pictures one after another, in the order of its options", .timeLimit(.minutes(1)))
    func aCardReadsItsPicturesInTurn() async throws {
        try await Self.withPictureHub { store, hub in
            let need = try #require(store.openNeeds.first { $0.id == 7 })
            hub.holdsPictures = true
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Self.until { !hub.reads.isEmpty }
            try await Task.sleep(for: .milliseconds(500))
            #expect(hub.reads == [71], "the card read more than one picture at a time")
            hub.release()
            try await Self.until { hub.reads.count == 3 }
            #expect(hub.reads == PictureHub.ids)
        }
    }
}

extension SampleFleetTests {
    /// **Each value that the agent put in inline code on a request's card has VoiceOver's "Copy <value>", which copies
    /// the value exactly; the door's script, his own answer and a chat's message have none** (`NeedWords`,
    /// `CardValueWords`; the owner's "Yes, as drawn" of 21 November 2026 to a chip with a copy icon on each value). The
    /// action is the chip's own copy, as VoiceOver gives it. The bugs that this stops: a chip in the script that the
    /// phone signs, which shows its words as the agent's values; a chip on his own words; a chip in every message of a
    /// chat; and a copy with a character added or cut.
    @MainActor @Test("a card's values copy exactly, and the door's script, his answer and a chat have no copy",
                     .timeLimit(.minutes(1)))
    func aCardsValuesCopyExactly() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            func need(_ fields: [String: Any]) throws -> OwnerNeed {
                try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: fields))
            }
            let script = "echo `hostname`\nsystemctl reload nginx\n"
            let call = DoorCall.hash(target: "web-1", action: DoorCall.run, arguments: [], content: Data(script.utf8))
            let door = try need([
                "id": 7, "by": "manager", "title": DoorCall.title(host: "web-1"), "raised": 20, "todo": "",
                "why": "The certificate of `web-1` ends on Friday.", "options": DoorCall.answers(host: "web-1"),
                "door_call": call, "door_fleet": "fleet-1", "door_host": "web-1", "door_script": script,
                "details": DoorCall.details(script: script),
            ])
            let words = try need(["id": 8, "by": "manager", "title": "Paste the key", "raised": 21,
                                  "why": "The shop's mail key ends today.",
                                  "todo": "Paste `ABCD-1234-EFGH` into the box and tap `Save key`."])
            let answered = try need(["id": 9, "by": "manager", "title": "Which server?", "raised": 22, "todo": "",
                                     "why": "Pick the server for `the-shop`.", "options": ["Yes", "No"],
                                     "answer": "Use `staging-2` instead.", "answered": 30])
            try #require(NeedScript.text(door) != nil && NeedOptions.asksInWords(words) && !answered.isOpen)

            /// The names of the copies in a window of `view`, by element, after a press of `opening` when it is set.
            @MainActor func copies(_ view: some View, opening: String? = nil) async throws -> [[String]] {
                let window = CardWindow(view)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(300))
                if let opening {
                    #expect(window.press(opening))
                    try await Task.sleep(for: .milliseconds(300))
                }
                return window.copies.map { $0.map { $0.name } }
            }
            #expect(try await copies(NeedCard(store: store, need: door, header: true)) == [["Copy web-1"]])
            #expect(try await copies(NeedCard(store: store, need: answered, header: true), opening: "need-folded-9")
                    == [["Copy the-shop"]])
            #expect(try await copies(ReplyText(text: "Run `fleet doctor` first.")).isEmpty)

            // the two values of What it wants, in their order; the first's copy puts its characters, and only them, on
            // the system's pasteboard
            let window = CardWindow(NeedCard(store: store, need: words, header: true))
            defer {
                window.close()
                UIPasteboard.general.items = []
            }
            try await Task.sleep(for: .milliseconds(300))
            let found = window.copies
            try #require(found.map { $0.map { $0.name } } == [["Copy ABCD-1234-EFGH", "Copy Save key"]])
            UIPasteboard.general.string = "nothing copied"
            #expect(CardWindow.perform(found[0][0]))
            try await Task.sleep(for: .milliseconds(100))
            #expect(UIPasteboard.general.string == "ABCD-1234-EFGH")
        }
    }
}

extension SampleFleetTests {
    /// **His press waits 5 seconds with Undo, and then goes once** (the owner's "Yes, 5 seconds (Recommended)" of 21
    /// November 2026; `MobileStore.hold`): the card stands folded with his answer and Undo, nothing reaches the Outbox or
    /// the hub for the 5 seconds, then the answer goes as a press went before, once, and Undo after it does nothing. The
    /// bugs that this stops: an answer that goes before he could take it back, one that never goes, and an Undo after
    /// the send that takes back an answer that went.
    @MainActor @Test("a press waits 5 seconds with Undo on its folded card, then goes once", .timeLimit(.minutes(1)))
    func aPressWaitsFiveSecondsThenGoesOnce() async throws {
        try await Self.withPictureHub { store, hub in
            let need = try #require(store.openNeeds.first { $0.id == 8 })
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            let pressed = ContinuousClock.now
            #expect(window.press("need-option-8-1"))
            try await Task.sleep(for: .milliseconds(400))
            // folded, with Undo at the end of its line, and nothing saved or sent
            let parts = Set(window.parts.keys)
            #expect(parts.contains("need-undo-8") && !parts.contains("need-option-8-1"))
            #expect(store.pending == nil && hub.answers.isEmpty)
            try await Task.sleep(until: pressed + .milliseconds(4_700))
            #expect(store.pending == nil && hub.answers.isEmpty, "the answer went before its 5 seconds")
            try await Self.until { !hub.answers.isEmpty }
            #expect(ContinuousClock.now - pressed >= .seconds(5))
            let answer = try #require(hub.answers.first, "the answer never went")
            #expect(answer.path == "/ui/needs/8" && answer.body["choice"] as? Int == 1)
            // Undo after the send does nothing: no Undo stands, and nothing more goes
            try await Self.until { store.pending == nil && !store.sending }
            #expect(!window.parts.keys.contains("need-undo-8") && store.heldAnswer(to: 8) == nil)
            store.undo(needID: 8)
            try await Task.sleep(for: .milliseconds(600))
            #expect(hub.answers.count == 1)
        }
    }

    /// **The app's leave of the front sends every held answer at once, one after the other, and the end of their wait
    /// sends nothing more** (`MobileStore.setForeground`, `releaseHeldAnswers`): an app that ends in the background
    /// must not lose one. The bugs that this stops: an answer waits in memory and ends with the app; two answers that
    /// the leave lets go in one moment each see the store free, and the second ends with nothing sent and no sign (the
    /// review of 21 November 2026); the end of the wait sends one again.
    @MainActor @Test("the leave of the front sends each held answer at once, and each only once", .timeLimit(.minutes(1)))
    func theLeaveSendsAHeldAnswerOnce() async throws {
        try await Self.withPictureHub { store, hub in
            let pressed = ContinuousClock.now
            store.hold(needID: 8, choice: 2)
            store.hold(needID: 7, choice: 1)
            try #require(store.heldAnswer(to: 8) != nil && store.heldAnswer(to: 7) != nil && hub.answers.isEmpty)
            store.setForeground(false)
            try await Self.until { hub.answers.count == 2 }
            #expect(ContinuousClock.now - pressed < .seconds(3), "the leave did not send them at once")
            #expect(Set(hub.answers.map(\.path)) == ["/ui/needs/7", "/ui/needs/8"], "a held answer was lost")
            #expect(hub.answers.first { $0.path == "/ui/needs/8" }?.body["choice"] as? Int == 2)
            #expect(hub.answers.first { $0.path == "/ui/needs/7" }?.body["choice"] as? Int == 1)
            // past the end of their wait, and an Undo
            try await Task.sleep(until: pressed + .milliseconds(6_000))
            store.undo(needID: 8)
            try await Task.sleep(for: .milliseconds(300))
            #expect(hub.answers.count == 2, "an answer went twice")
            #expect(store.pending == nil && store.heldAnswer(to: 8) == nil && store.heldAnswer(to: 7) == nil)
        }
    }

    /// **Undo opens the card as it was, and nothing goes** (his "A click on Undo opens the card again as it was";
    /// `MobileStore.undo`): the options that he ticked are ticked again, his own words stay in his field, and the words
    /// that the agent's row put there give their place back to his. The bugs that this stops: an Undo that sends anyway,
    /// that leaves the card folded, that loses his ticks, or that leaves the agent's words in his field.
    @MainActor @Test("Undo opens the card as it was, with his ticks and his words, and nothing goes", .timeLimit(.minutes(1)))
    func undoOpensTheCardAsItWas() async throws {
        try await Self.withPictureHub { store, hub in
            store.answerWait = .seconds(2)
            defer {
                store.setAnswerDraft("", for: 7)
                store.setAnswerDraft("", for: 8)
            }
            let need = try #require(store.openNeeds.first { $0.id == 9 })
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            let pressed = ContinuousClock.now
            #expect(window.press("need-tick-9-2") && window.press("need-tick-9-0"))
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.press("need-send-ticked-9"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.parts.keys.contains("need-send-ticked-9"), "the card did not fold with his answer")
            #expect(window.press("need-undo-9"), "the folded card had no Undo")
            try await Task.sleep(for: .milliseconds(600))
            #expect(window.has("need-tick-9-0", .selected) && window.has("need-tick-9-2", .selected))
            #expect(!window.has("need-tick-9-1", .selected) && !window.parts.keys.contains("need-undo-9"))

            // his words with Send stay his; the agent's words give his own back
            store.setAnswerDraft("Use the blue one", for: 8)
            store.holdSend(needID: 8)
            try #require(store.heldAnswer(to: 8) != nil)
            store.undo(needID: 8)
            #expect(store.answerDraft(for: 8) == "Use the blue one")
            store.setAnswerDraft("My own words", for: 7)
            store.hold(needID: 7, words: "Orange, big words")
            #expect(store.answerDraft(for: 7) == "Orange, big words" && store.heldAnswer(to: 7) != nil)
            store.undo(needID: 7)
            #expect(store.answerDraft(for: 7) == "My own words")
            try await Task.sleep(until: pressed + .milliseconds(3_500))
            #expect(hub.answers.isEmpty && store.pending == nil, "an answer went after Undo")
        }
    }
}

/// **A hub with answered cards whose tasks stand as each of the marks** (owner features `need_marks` and
/// `task_controls`): card 21's task 41 works, card 22's task 42 works under his requested Pause, card 23 has no task,
/// card 24's task 44 holds his confirmed pause, and card 25's task 45 asks for his input. It takes a task's control with
/// the hub's receipt and holds that task from then on in its read, and it keeps each control's route and body, in order.
private final class MarkHub: LoopbackHub, @unchecked Sendable {
    /// How it takes a control: with its receipt, with the hub's refusal of a task that ended, by a cut connection
    /// before it takes it, as a hub that went away, or by a cut connection after it took it, as a receipt that was lost.
    /// A repeat of a control that it took gets its receipt, as the hub's record answers it.
    enum Mode { case answers, refuses, cuts, takesThenCuts }
    private var bodies: [(path: String, body: [String: Any])] = []
    private var paused: Set<Int> = []
    private var took: Set<String> = []
    private var taking = Mode.answers

    init() { super.init(label: "founderizer.check.mark-hub") }

    /// The controls that came, by route, in order, a refused and a cut one too.
    var controls: [(path: String, body: [String: Any])] { lock.withLock { bodies } }

    var mode: Mode {
        get { lock.withLock { taking } }
        set { lock.withLock { taking = newValue } }
    }

    override func answer(_ request: Request, on connection: NWConnection) {
        note("\(request.method) \(request.path)")
        switch (request.method, request.path) {
        case ("GET", "/ui/mobile"):
            send(Self.reply(200, fleet()), on: connection)
        case ("POST", let path) where path.hasPrefix("/ui/tasks/") && path.hasSuffix("/control"):
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let task = Int(path.dropFirst("/ui/tasks/".count).dropLast("/control".count)) ?? 0
            let id = fields["request_id"] as? String ?? ""
            let mode = lock.withLock { () -> Mode in
                bodies.append((path, fields))
                if took.contains(id) { return .answers }
                if taking == .answers || taking == .takesThenCuts {
                    paused.insert(task)
                    took.insert(id)
                }
                return taking
            }
            if mode == .cuts || mode == .takesThenCuts { return connection.cancel() }
            if mode == .refuses {
                return send(Self.reply(409, #"{"error": "T-\#(task) is completed"}"#), on: connection)
            }
            let receipt: [String: Any] = [
                "ok": true, "request_id": fields["request_id"] as? String ?? "", "replayed": false, "changed": true,
                "client": request.headers["x-fleet-client"] ?? "",
                "hold": ["id": 90 + task, "task": task, "kind": "pause", "state": "requested", "attempt": 1],
            ]
            send(Self.reply(200, Self.text(receipt)), on: connection)
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    private static func text(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The hub's compact read: the five answered cards of the agent atlas and their tasks.
    private func fleet() -> String {
        let held = lock.withLock { paused }
        func head(_ id: Int, state: String = "working") -> [String: Any] {
            ["id": id, "title": "Write the launch page \(id)", "state": state, "owner": "atlas", "requester": "manager",
             "attempt": 1, "created": 1_799_990_000, "started": 1_799_990_100, "last_activity": 1_799_999_900,
             "works": true]
        }
        func card(_ id: Int, task: Int?) -> [String: Any] {
            var card: [String: Any] = [
                "id": id, "by": "atlas", "title": "Which page goes first?", "why": "Two pages are ready.", "todo": "",
                "raised": 1_799_990_000 + id, "answer": "The pricing page", "answered": 1_799_995_000,
                "options": ["The pricing page", "The blog"], "chosen": 0,
            ]
            if let task { card["task"] = task }
            return card
        }
        let holds: [[String: Any]] = [["id": 1, "task": 42, "kind": "pause", "state": "requested", "attempt": 1],
                                      ["id": 2, "task": 44, "kind": "pause", "state": "stopped", "attempt": 1]]
            + held.sorted().map { ["id": 90 + $0, "task": $0, "kind": "pause", "state": "requested", "attempt": 1] }
        return Self.text([
            "schema_version": 1, "db": "gen-marks", "time": 1_800_000_000,
            "ui_features": ["mobile", "need_options", "need_marks", "task_controls"],
            "agents": [["name": "atlas", "role": "worker", "runtime": "claude", "open_tasks": 4, "usage": []]],
            "needs": [], "answered_needs": [card(21, task: 41), card(22, task: 42), card(23, task: nil),
                                            card(24, task: 44), card(25, task: 45)],
            "tasks": [head(41), head(42), head(44), head(45, state: "input-required")], "recent": [],
            "holds": holds, "outcomes": [],
        ] as [String: Any])
    }
}

extension SampleFleetTests {
    /// Runs `body` with a store that read the mark hub, and leaves nothing of it: no key, no reading, no request.
    @MainActor private static func withMarkHub(_ body: (MobileStore, MarkHub) async throws -> Void) async throws {
        try await withoutHub {
            try await keepingReadings {
                let hub = MarkHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let holder = DeviceKey(account: "device-key-mark-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        try? Outbox(file: support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                store.addressText = address
                await store.connect()
                try #require(store.canWrite && (store.snapshot?.answered_needs ?? []).count == 5)
                var failure: Error?
                do { try await body(store, hub) } catch { failure = error }
                for _ in 0..<60 where store.sending { try? await Task.sleep(for: .milliseconds(50)) }
                if let failure { throw failure }
            }
        }
    }

    /// **Pause stands at the end of an answered card's line only while its task works with nothing holding it, and its
    /// press sends the task's one Pause** (his "Both (Recommended)" of 21 November 2026; `MobileStore.pausable`,
    /// `pause(task:)`): the hub takes it from the phone's own key, and once the read has the hold, Pause goes. The bugs
    /// that this stops: a Pause on a task that his Pause or the hub holds already, or on a card with no task, and a Pause
    /// that goes twice or to another task.
    @MainActor @Test("Pause stands only while the card's task works, and sends one Pause of that task",
                     .timeLimit(.minutes(1)))
    func pauseStandsWhileTheTaskWorks() async throws {
        try await Self.withMarkHub { store, hub in
            let cards = Dictionary((store.snapshot?.answered_needs ?? []).map { ($0.id, $0) }) { first, _ in first }
            #expect([21, 22, 23, 24, 25].map { cards[$0].flatMap(store.pausable) } == [41, nil, nil, nil, nil])
            for id in [22, 23, 24, 25] {
                let window = CardWindow(NeedCard(store: store, need: try #require(cards[id])))
                try await Task.sleep(for: .milliseconds(200))
                #expect(!window.actions(of: "need-folded-\(id)").contains("Pause"), "card \(id) offers Pause")
                window.close()
            }

            let window = CardWindow(NeedCard(store: store, need: try #require(cards[21])))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.perform("Pause", of: "need-folded-21"), "the working task's card has no Pause")
            try await Self.until { !hub.controls.isEmpty && store.pending == nil && !store.sending }
            let control = try #require(hub.controls.first)
            #expect(control.path == "/ui/tasks/41/control" && control.body["action"] as? String == "pause")
            // the read after the receipt holds the task: Pause goes, and nothing more is sent
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.actions(of: "need-folded-21").contains("Pause") && store.pausable(cards[21]!) == nil)
            #expect(hub.controls.count == 1)
        }
    }

    /// **A Pause that does not go says so on its card, and holds nothing behind it with no sign** (two reviews of 21
    /// November 2026): the hub's refusal (a task that ended between two reads) ends it by itself, so the phone writes
    /// again, and its card says why, in the phone's words, until his Discard gives the card its Pause back; one that the
    /// hub did not take goes nowhere by itself, and its card says "Not sent" with Try again, which sends the same
    /// request; one whose receipt was lost, while the reading has its task's hold, goes again by itself once and is
    /// confirmed. The bugs that this stops: a refused Pause that waits for a Discard that only Settings offers, or that
    /// ends with no words; an unsent Pause that goes by itself a day later; a Pause that did not go behind a card that
    /// looks as if nothing happened; a Try again that sends a second Pause.
    @MainActor @Test("a Pause that does not go says so on its card, and only a lost receipt goes again by itself",
                     .timeLimit(.minutes(1)))
    func aPauseThatDoesNotGoSaysSo() async throws {
        try await Self.withMarkHub { store, hub in
            let cards = Dictionary((store.snapshot?.answered_needs ?? []).map { ($0.id, $0) }) { first, _ in first }
            let window = CardWindow(NeedCard(store: store, need: try #require(cards[21])))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))

            // refused: it leaves the Outbox by itself, its card says why with Discard, and Discard gives Pause back
            hub.mode = .refuses
            #expect(window.perform("Pause", of: "need-folded-21"))
            try await Self.until { !hub.controls.isEmpty && !store.sending }
            #expect(hub.controls.count == 1 && store.pending == nil && store.canWrite, "the refused Pause still waits")
            try await Task.sleep(for: .milliseconds(300))
            let refusal = window.parts["need-pause-words-21"]?.accessibilityLabel ?? ""
            #expect(refusal.contains("T-41 is completed"), "the refused Pause has no words on its card: \(refusal)")
            #expect(!window.actions(of: "need-folded-21").contains("Pause"))
            #expect(window.press("need-pause-discard-21"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.parts["need-pause-words-21"] == nil && window.actions(of: "need-folded-21").contains("Pause"))

            // not taken, and no hold in the reading: nothing goes by itself; its card says "Not sent" with Try again
            hub.mode = .cuts
            #expect(window.perform("Pause", of: "need-folded-21"))
            try await Self.until { hub.controls.count == 2 && !store.sending }
            await store.refresh()
            try await Task.sleep(for: .milliseconds(500))
            #expect(hub.controls.count == 2, "a Pause that the hub never took went again by itself")
            let waiting = try #require(store.pending, "the unsent Pause left the Outbox")
            #expect(window.parts["need-pause-words-21"]?.accessibilityLabel == "Not sent")
            #expect(!window.actions(of: "need-folded-21").contains("Pause"))
            hub.mode = .answers
            #expect(window.press("need-pause-retry-21"), "the unsent Pause's card has no Try again")
            try await Self.until { store.pending == nil && !store.sending }
            let sent = hub.controls.filter { $0.path == "/ui/tasks/41/control" }.compactMap { $0.body["request_id"] as? String }
            #expect(sent.count == 3 && sent.suffix(2).allSatisfy { $0 == waiting.requestID.uuidString.lowercased() },
                    "Try again sent a second Pause")

            // taken, and its receipt lost: the reading has the task's hold, so the same request goes again, once
            hub.mode = .takesThenCuts
            await store.pause(task: 45)
            try await Self.until { store.pending == nil && !store.sending }
            let replayed = hub.controls.filter { $0.path == "/ui/tasks/45/control" }.compactMap { $0.body["request_id"] as? String }
            #expect(replayed.count == 2 && Set(replayed).count == 1, "a lost receipt was not confirmed by its own request")
            #expect(store.pending == nil && store.canWrite)
        }
    }

    /// **A press of the mark opens the card's own task** (his "Yes, open task" and "Gray pause, as the row" of 21
    /// November 2026; `MobileStore.taskOpened`): the work mark, the orange mark and the gray mark of his pause, each its
    /// task's page, over the chat, and from Needs you in Tasks; the check opens nothing. The bugs that this stops: a press
    /// that opens another task (the card's own number, or another card's task), and a check that opens a task.
    @MainActor @Test("a press of the card's mark opens its own task, and the check opens none", .timeLimit(.minutes(1)))
    func theMarkOpensItsOwnTask() async throws {
        try await Self.withMarkHub { store, _ in
            let cards = Dictionary((store.snapshot?.answered_needs ?? []).map { ($0.id, $0) }) { first, _ in first }
            for (id, task) in [(21, 41), (24, 44), (25, 45), (22, nil), (23, nil)] as [(Int, Int?)] {
                store.chatRoute = [.chat("atlas")]
                let window = CardWindow(NeedCard(store: store, need: try #require(cards[id])))
                try await Task.sleep(for: .milliseconds(200))
                if let task {
                    #expect(window.perform("Open the task", of: "need-folded-\(id)"), "card \(id)'s mark opens nothing")
                    #expect(store.chatRoute == [.chat("atlas"), .task(task)], "card \(id) opened another task")
                } else {
                    #expect(!window.actions(of: "need-folded-\(id)").contains("Open the task"),
                            "card \(id)'s check opens a task")
                }
                window.close()
            }
            // on Needs you, in Tasks
            store.tab = .needs
            let window = CardWindow(NeedCard(store: store, need: try #require(cards[24]), header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.perform("Open the task", of: "need-folded-24"))
            #expect(store.tab == .tasks && store.taskRoute == [44])
        }
    }
}

/// **A hub that gives this phone a key for a code, and asks for it on each read and each answer** (owner devices,
/// MOBILE-APP.md 7): a request with no key gets the hub's refusal `device_key_required`, which is for good. Its read has
/// three open requests of the manager's, each with three options. While `holdsAnswers` is set it holds the receipt of
/// each answer until `letGo`. It keeps each answer's route and whether it came with the key, in order.
private final class KeyHub: LoopbackHub, @unchecked Sendable {
    static let key = "a-key-of-the-leave-check"
    private var bodies: [(path: String, keyed: Bool)] = []
    private var files: [Bool] = []
    private var holding = false
    private var held: [(connection: NWConnection, reply: Data)] = []

    init() { super.init(label: "founderizer.check.key-hub") }

    /// The answers that came, by route, in order, with whether each had the key.
    var answers: [(path: String, keyed: Bool)] { lock.withLock { bodies } }
    /// The files that came up, in order: whether each had the key.
    var uploads: [Bool] { lock.withLock { files } }
    /// The receipts that it holds now.
    var heldCount: Int { lock.withLock { held.count } }
    var holdsAnswers: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }

    /// The receipts that it holds go; it holds the next ones while `holdsAnswers` is set.
    func letGo() {
        let going = lock.withLock { () -> [(connection: NWConnection, reply: Data)] in
            defer { held = [] }
            return held
        }
        for (connection, reply) in going { send(reply, on: connection) }
    }

    override func stop() {
        let left = lock.withLock { () -> [NWConnection] in
            defer { held = [] }
            return held.map(\.connection)
        }
        for connection in left { connection.cancel() }
        super.stop()
    }

    private static let refusal = #"{"error": "device key required", "auth": "device_key_required"}"#

    override func answer(_ request: Request, on connection: NWConnection) {
        let keyed = request.headers["authorization"] == "Bearer \(Self.key)"
        note("\(request.method) \(request.path)")
        switch (request.method, request.path) {
        case ("POST", "/ui/owner/enroll"):
            send(Self.reply(200, #"{"device": "phone-check", "label": "iPhone", "key": "\#(Self.key)"}"#), on: connection)
        case ("GET", "/ui/mobile"):
            send(keyed ? Self.reply(200, Self.fleet) : Self.reply(403, Self.refusal), on: connection)
        case ("POST", "/ui/attachments"):
            lock.withLock { files.append(keyed) }
            guard keyed else { return send(Self.reply(403, Self.refusal), on: connection) }
            let file: [String: Any] = ["id": 61, "name": request.headers["x-fleet-name"] ?? "file",
                                       "mime": request.headers["content-type"] ?? "", "size": request.body.count,
                                       "sha256": MessageAttachment.digest(request.body), "created": 1_800_000_200,
                                       "kept": NSNull()]
            send(Self.reply(200, (try? JSONSerialization.data(withJSONObject: file))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"), on: connection)
        case ("POST", let path) where path.hasPrefix("/ui/needs/"):
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let holds = lock.withLock { () -> Bool in
                bodies.append((path, keyed))
                return holding
            }
            guard keyed else { return send(Self.reply(403, Self.refusal), on: connection) }
            let receipt: [String: Any] = ["ok": true, "request_id": fields["request_id"] as? String ?? "",
                                          "client": request.headers["x-fleet-client"] ?? "", "event_id": 101,
                                          "created": 1_800_000_100, "replayed": false]
            let reply = Self.reply(200, (try? JSONSerialization.data(withJSONObject: receipt))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}")
            let now = lock.withLock { () -> Bool in
                guard holds else { return true }
                held.append((connection, reply))
                return false
            }
            if now { send(reply, on: connection) }
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    /// The hub's compact read: requests 7, 8 and 9 of the manager's.
    private static let fleet: String = {
        func card(_ id: Int) -> [String: Any] {
            ["id": id, "by": "manager", "title": "Which day goes the newsletter?", "why": "The draft is ready.", "todo": "",
             "raised": 1_799_999_000 + id, "answer": NSNull(), "answered": NSNull(),
             "options": ["Monday", "Tuesday", "Friday"]]
        }
        let fleet: [String: Any] = [
            "schema_version": 1, "db": "gen-key", "time": 1_800_000_000, "ui_features": ["mobile", "need_options"],
            "agents": [], "needs": [card(7), card(8), card(9)], "tasks": [], "recent": [], "holds": [], "outcomes": [],
        ]
        return (try? JSONSerialization.data(withJSONObject: fleet)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }()
}

extension SampleFleetTests {
    /// **Answers that wait as the app leaves the front go with this phone's key, the key goes once each of them started,
    /// and no answer ever goes without it** (`MobileStore.lockKeyAtTheLeave`, `canWrite`; the review of 21 November
    /// 2026). A request with no key is refused for good, and the phone then asks to be enrolled again. The bugs that this
    /// stops: the key kept only for the first answer, so the second goes later with none; a press that waits and goes
    /// with no key once the key is locked; the key kept in memory until each send's receipt came.
    @MainActor @Test("answers that wait at the leave go with the key, which goes once they started, and none goes without it",
                     .timeLimit(.minutes(1)))
    func answersAtTheLeaveGoWithTheKey() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = KeyHub()
                defer { hub.stop() }
                let address = try await hub.start()
                // A key of the check's own: the key of an enrolled phone is never touched.
                let holder = DeviceKey(account: "device-key-leave-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        try? Outbox(file: Self.support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                await store.openLink(try #require(URL(string: "fleet://enroll?hub=\(address)&code=ABCD-2345")))
                try #require(store.keyState == .ready && store.canWrite && store.openNeeds.map(\.id) == [9, 8, 7])

                // two answers wait at the leave, and the hub holds each receipt: the second waits behind the first,
                // with the key in hand for it
                hub.holdsAnswers = true
                store.hold(needID: 7, choice: 0)
                store.hold(needID: 8, choice: 1)
                store.setForeground(false)
                store.lockKeyAtTheLeave()
                try await Self.until { hub.answers.count == 1 }
                #expect(store.keyState == .ready && store.waitingPresses[8] != nil, "the key went before the second answer")
                hub.letGo()
                try await Self.until { hub.answers.count == 2 }
                // the second started with the key: the key goes, while its receipt is still on its way (within a second:
                // the client's own limit of 15 seconds would end that send, and the key with it)
                for _ in 0..<50 where store.keyState != .locked { try await Task.sleep(for: .milliseconds(20)) }
                #expect(store.keyState == .locked && hub.heldCount == 1, "the key stayed until the sends ended")
                // iOS's time in the background lasts until that receipt has come, and ends with it
                #expect(store.holdsBackgroundTime, "the background time ended before the last answer's receipt")
                hub.holdsAnswers = false
                hub.letGo()
                try await Self.until { !store.sending && store.pending == nil }
                for _ in 0..<50 where store.holdsBackgroundTime { try await Task.sleep(for: .milliseconds(20)) }
                #expect(!store.holdsBackgroundTime, "the background time outlived the sends")

                // with the key locked, the page says so, though its reading is current: every write waits for the key
                #expect(store.keyWords != nil && store.unavailableWords == store.keyWords,
                        "a write waits for the key with no reason on the page")
                // an answer waits for it and nothing goes; with the key back (a new code here, Face ID in the app) it
                // goes
                store.hold(needID: 9, choice: 2)
                store.releaseHeld(9)
                try await Task.sleep(for: .milliseconds(800))
                #expect(hub.answers.count == 2 && store.waitingPresses[9] != nil, "an answer went with the key locked")
                #expect(await store.enroll(code: "ABCD-2345") == nil)
                try await Self.until { hub.answers.count == 3 && !store.sending }
                #expect(hub.answers.map(\.path) == ["/ui/needs/7", "/ui/needs/8", "/ui/needs/9"])
                #expect(hub.answers.filter { !$0.keyed }.isEmpty, "an answer went without the key")
                #expect(!store.needsEnrollment)
            }
        }
    }

    /// Runs `body` with a store that this hub enrolled with a key of the check's own, and leaves nothing of it: no
    /// key, no reading, no request, no file.
    @MainActor private static func withKeyHub(_ body: (MobileStore, KeyHub) async throws -> Void) async throws {
        try await withoutHub {
            try await keepingReadings {
                let staged = UserDefaults.standard.object(forKey: "stagedFiles")
                defer {
                    if let staged { UserDefaults.standard.set(staged, forKey: "stagedFiles") }
                    else { UserDefaults.standard.removeObject(forKey: "stagedFiles") }
                }
                let hub = KeyHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let holder = DeviceKey(account: "device-key-keyhub-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        try? Outbox(file: support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                await store.openLink(try #require(URL(string: "fleet://enroll?hub=\(address)&code=ABCD-2345")))
                try #require(store.keyState == .ready && store.canWrite && store.openNeeds.map(\.id) == [9, 8, 7])
                try await body(store, hub)
            }
        }
    }

    /// **Where iOS gives no time in the background, the first answer that waits goes into the Outbox and is not sent**
    /// (`MobileStore.keepFirstUnsent`; the review of 21 November 2026): an end of the app there does not lose it, and at
    /// the return his Try again sends it, with the key. The bugs that this stops: with no time to send, the first answer
    /// waits in memory only and goes with the app; it goes with no key.
    @MainActor @Test("with no background time the first held answer waits in the Outbox, unsent, for Try again",
                     .timeLimit(.minutes(1)))
    func noBackgroundTimeKeepsTheFirstAnswer() async throws {
        try await Self.withKeyHub { store, hub in
            store.backgroundTimeRefused = true
            store.hold(needID: 7, choice: 0)
            store.hold(needID: 8, choice: 1)
            store.setForeground(false)
            store.lockKeyAtTheLeave()
            try await Task.sleep(for: .milliseconds(500))
            let kept = try #require(store.pending, "the first answer is only in memory")
            #expect(kept.needID == 7 && kept.choice == 0 && kept.refusal == nil && !store.sending && hub.answers.isEmpty)
            #expect(store.keyState == .locked && store.waitingPresses[8] != nil)
            // a start of the app finds it
            #expect(MobileStore(deviceKey: DeviceKey(account: "device-key-keyhub-check")).pending?.requestID == kept.requestID)
            // the return, with the key: it says "Not sent", and his Try again sends it, then the one behind it goes
            #expect(await store.enroll(code: "ABCD-2345") == nil)
            #expect(store.waitsUnsent(for: 7) && store.canRetry)
            await store.retry()
            try await Self.until { hub.answers.count == 2 && !store.sending && store.pending == nil }
            #expect(hub.answers.map(\.path) == ["/ui/needs/7", "/ui/needs/8"])
            #expect(hub.answers.filter { !$0.keyed }.isEmpty, "an answer went without the key")
        }
    }

    /// **A file waits for this phone's key, and goes up with it** (`MobileStore.upload`; the review of 21 November
    /// 2026). The bug that this stops: a file that he picked, or sent again, goes up with no key, the hub refuses the
    /// phone for good, and its row says to add this phone again with a new code.
    @MainActor @Test("a file waits for this phone's key, and goes up with it", .timeLimit(.minutes(1)))
    func aFileWaitsForTheKey() async throws {
        try await Self.withKeyHub { store, hub in
            let composer = MobileStore.stageKey(need: 7)
            defer { for file in store.stagedFiles(for: composer) { store.removeStaged(file, for: composer) } }
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            store.lockKey()
            let staging = Task { await store.stage(picture, name: "plan.png", mime: "image/png", for: composer) }
            try await Task.sleep(for: .milliseconds(800))
            #expect(hub.uploads.isEmpty && store.readyFiles(for: composer).isEmpty, "a file went up with the key locked")
            #expect(await store.enroll(code: "ABCD-2345") == nil)
            await staging.value
            #expect(hub.uploads == [true], "the file did not go up with the key")
            #expect(store.readyFiles(for: composer) == [61] && store.authProblem == nil)
        }
    }
}
