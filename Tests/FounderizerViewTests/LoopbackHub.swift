import Darwin
import Foundation

/// **A stand-in hub on 127.0.0.1 for a view test that needs the hub's answer**: the app writes only within a moment of
/// one (`FleetStore.canWrite`). It keeps each request's method, path, query, request id, body and time, so a test reads
/// what the app sent and when. `stop` ends it. Synthetic data only.
///
/// **Each route has one way to get its answer** (the supervisor's note of 23 November 2026, when F14 met F21's table):
/// - `GET /ui/state` gets the reading that it holds (`give(_:)`, `give(last:)`), and nothing else: the table refuses
///   that route. A read can wait (`slowState`), and the reads right after a restore's answer can get a 503
///   (`give(restore:body:thenState:failing:)`).
/// - Every other route gets its answer from one table, by "<method> <path>" (`answer(_:_:with:)`): the answer of each
///   later request of that route, made from the request when it arrives. Every other way to give an answer writes into
///   that table: `give(_:at:)` a `GET`'s, `give(restore:)` and `give(restore:body:thenState:failing:)` the next answers
///   of `POST /ui/restore`, one for each request in order and then a 404, and `give(copy:fields:between:)` the copy of
///   `GET /ui/backup`. A route with no answer in the table gets a 404.
/// - Two things change how an answer goes, not what it is. `give(copy:fields:between:)` sends `GET /ui/backup`'s answer
///   with its header fields, in parts of 64 KiB, and runs `between` after the first part, until a later
///   `answer(_:_:with:)` of that route gives an answer that goes whole. A route that holds
///   (`holdRestores`, and the reads after `give(last:)`) gives a request no answer until the app's side gives it up
///   (`restoresCut`) or this hub stops; its answer is made all the same when it arrives, so a restore's answer moves
///   the reading then.
final class LoopbackHub: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: String
        let at: Date
        /// What follows the path's `?`, or "".
        var query = ""
        /// Its `X-Fleet-Request-Id`, or "".
        var id = ""
    }

    let port: Int
    private let lock = NSLock()
    private var kept: [Request] = []
    private var reading: Data
    /// The answers that a test gave, by "<method> <path>".
    private var answers: [String: @Sendable (Request) -> (status: Int, body: Data)] = [:]
    /// The answers of the next `POST /ui/restore`s, one for each, with the reading that each gives from its moment on
    /// and how many `GET /ui/state` fail right after it.
    private var restores: [(status: Int, body: Data, state: Data?, failing: Int)] = []
    /// How a route's answer goes when it is not sent whole: its header fields, and a moment after its first part.
    private var inParts: [String: (fields: [String: String], between: (@Sendable () -> Void)?)] = [:]
    /// How many more requests of a route get their answer; each later one is held.
    private var answering: [String: Int] = [:]
    /// How many held requests of a route the app's side gave up.
    private var cuts: [String: Int] = [:]
    private var stateWait: Double = 0
    private var stateFails = 0
    private var stopped = false
    private let listener: Int32

    private static let state = "GET /ui/state", restore = "POST /ui/restore", backup = "GET /ui/backup"
    private static let notHere = Data(#"{"error":"not here"}"#.utf8)

    /// How many restores the app's side gave up before their answer (it closed the connection while this hub held it).
    var restoresCut: Int { lock.withLock { cuts[Self.restore] ?? 0 } }
    var requests: [Request] { lock.withLock { kept } }
    var address: String { "http://127.0.0.1:\(port)" }

    init(state: Data) throws {
        reading = state
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listener = listener
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 16) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        guard ready else { Darwin.close(listener); throw POSIXError(.EADDRINUSE) }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in
            while true {
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { return }         // `stop` closed the listener
                if lock.withLock({ !answering.isEmpty }) {      // a request that is held holds no other
                    Thread.detachNewThread { [self] in answer(peer) }
                } else {
                    answer(peer)
                }
            }
        }
    }

    /// The reading that the next `GET /ui/state` gives.
    func give(_ state: Data) { lock.withLock { reading = state } }

    /// The reading that the next `GET /ui/state` gives, in one step with this: it is the last one that this hub
    /// answers. Each later read is held, so a look that comes after that read never gets its reading.
    func give(last state: Data) { lock.withLock { reading = state; answering[Self.state] = 1 } }

    /// How long each `GET /ui/state` waits before its answer, from now on: a test's slow read.
    func slowState(_ seconds: Double) { lock.withLock { stateWait = seconds } }

    /// What the next `GET` of this path (without its query) gives: a knowledge file's text, say.
    func give(_ answer: Data, at path: String) { self.answer("GET", path) { _ in (status: 200, body: answer) } }

    /// The answer of every later request of this method to this path, made from that request (it is in `requests`
    /// already): a receipt names the request's own id.
    func answer(_ method: String, _ path: String, with make: @escaping @Sendable (Request) -> (status: Int, body: Data)) {
        let route = "\(method) \(path)"
        precondition(route != Self.state, "GET /ui/state gets the reading: give(_:)")
        lock.withLock { answers[route] = make; inParts[route] = nil }     // a new answer goes whole
    }

    /// Each `POST /ui/restore` is held from now on: a send that is on its way for as long as a test needs.
    func holdRestores() { lock.withLock { answering[Self.restore] = 0 } }

    /// What each later `GET /ui/backup` gives: a 200 with `body`, sent in parts with these header fields; `between`
    /// runs after the first part, before the rest (a test's moment while a copy arrives).
    func give(copy body: Data, fields: [String: String], between: (@Sendable () -> Void)? = nil) {
        lock.withLock {                                 // the answer and its way in one step
            answers[Self.backup] = { _ in (status: 200, body: body) }
            inParts[Self.backup] = (fields, between)
        }
    }

    /// The answers of the next `POST /ui/restore`s, one for each, in order: a status and its JSON body.
    func give(restore answers: [(status: Int, body: Data)]) {
        lock.withLock { restores += answers.map { ($0.status, $0.body, nil, 0) } }
        answerRestores()
    }

    /// The answer of the next `POST /ui/restore` but those given already, and the reading that `GET /ui/state` gives
    /// from the moment of that answer on: a restore that lands while its send goes up. The `failing` reads of
    /// `GET /ui/state` right after that answer get a 503: a hub that just started and does not answer a read yet.
    func give(restore status: Int, body: Data, thenState state: Data, failing: Int = 0) {
        lock.withLock { restores.append((status, body, state, failing)) }
        answerRestores()
    }

    /// `POST /ui/restore`'s answer in the table: the next of `restores`, or a 404 when none is left.
    private func answerRestores() {
        answer("POST", "/ui/restore") { [weak self] _ in
            guard let self else { return (status: 404, body: LoopbackHub.notHere) }
            return lock.withLock {
                guard !restores.isEmpty else { return (status: 404, body: LoopbackHub.notHere) }
                let next = restores.removeFirst()
                if let state = next.state { reading = state }
                stateFails += next.failing
                return (status: next.status, body: next.body)
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        Darwin.close(listener)
    }

    private func answer(_ peer: Int32) {
        defer { Darwin.close(peer) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), yes: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        var head: Range<Data.Index>?
        var length = 0
        while head == nil || data.count < head!.upperBound + length {
            let count = recv(peer, &buffer, buffer.count, 0)
            if count <= 0 { return }
            data.append(contentsOf: buffer[..<count])
            if head == nil, let found = data.range(of: Data("\r\n\r\n".utf8)) {
                head = found
                let fields = String(decoding: data[..<found.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                length = fields.compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    return parts.count == 2 && parts[0].lowercased() == "content-length"
                        ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
            }
        }
        guard let head else { return }
        let lines = String(decoding: data[..<head.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let words = (lines.first ?? "").split(separator: " ")
        let method = words.first.map(String.init) ?? "", target = words.dropFirst().first.map(String.init) ?? ""
        let parts = target.split(separator: "?", maxSplits: 1)
        let path = String(parts.first ?? ""), query = parts.count == 2 ? String(parts[1]) : ""
        let body = String(decoding: data[head.upperBound...], as: UTF8.self)
        let id = lines.dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "x-fleet-request-id"
                ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        }.first ?? ""
        let request = Request(method: method, path: path, body: body, at: Date(), query: query, id: id)
        let route = "\(method) \(path)"
        // In one step with its record: the reading of a read, whether this request is held, and how its answer goes.
        let read = route == Self.state
        let (state, make, held, sending): (Data?, (@Sendable (Request) -> (status: Int, body: Data))?, Bool,
                                           (fields: [String: String], between: (@Sendable () -> Void)?)?)
            = lock.withLock {
                kept.append(request)
                var held = false
                if let left = answering[route] {
                    if left == 0 { held = true } else { answering[route] = left - 1 }
                }
                return (read ? reading : nil, read ? nil : answers[route], held, inParts[route])
            }
        let given = make?(request)          // made when it arrives, also for a request that is held
        if held {
            var byte: UInt8 = 0
            while !lock.withLock({ stopped }) {
                let there = recv(peer, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if there == 0 || (there < 0 && errno != EAGAIN) {          // the app's side went: no answer
                    lock.withLock { cuts[route, default: 0] += 1 }
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return
        }
        var answer = given ?? state.map { (status: 200, body: $0) } ?? (status: 404, body: Self.notHere)
        if state != nil {
            if case let wait = lock.withLock({ stateWait }), wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let failing = lock.withLock {
                guard stateFails > 0 else { return false }
                stateFails -= 1
                return true
            }
            if failing { answer = (status: 503, body: Data(#"{"error":"starting"}"#.utf8)) }
        }
        let fields = ["HTTP/1.1 \(answer.status) Answer",
                      "Content-Type: \(sending == nil ? "application/json" : "application/zip")",
                      "Content-Length: \(answer.body.count)", "Connection: close"]
            + (sending?.fields ?? [:]).map { "\($0.key): \($0.value)" } + ["", ""]
        let start = Data(fields.joined(separator: "\r\n").utf8)
        guard let sending else {
            Self.sendAll(start + answer.body, to: peer)
            return
        }
        Self.sendAll(start, to: peer)
        for from in stride(from: 0, to: answer.body.count, by: 65_536) {     // a copy comes in more than one write
            Self.sendAll(answer.body.subdata(in: from..<min(from + 65_536, answer.body.count)), to: peer)
            if from == 0 { sending.between?() }
        }
    }

    /// All of `data` to `peer`, in as many sends as the socket takes, or until the peer goes.
    private static func sendAll(_ data: Data, to peer: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var at = 0
            while at < raw.count {
                let sent = send(peer, base + at, raw.count - at, 0)
                if sent <= 0 { return }
                at += sent
            }
        }
    }
}
