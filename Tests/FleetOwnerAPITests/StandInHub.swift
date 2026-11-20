import Foundation
@testable import FleetOwnerAPI

/// One request that the stand-in hub got: as it came, with its path and query still escaped.
struct Seen: Sendable {
    let method: String
    let path: String
    let query: String?
    let headers: [String: String]
    let body: JSONValue?
    /// The body's bytes as they came, or nil for none.
    var bytes: Data? = nil

    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
}

/// **A stand-in for the hub that opens no port**: a `URLProtocol` that answers each request of a session whose
/// configuration holds it. Each test has its own hub, found by the host of its address (`h<uuid>.example.com`), so tests
/// that run at the same time never see each other's requests.
final class StandInProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var hubs: [String: StandInHub] = [:]
    private static let lock = NSLock()

    static func add(_ hub: StandInHub) {
        lock.lock(); defer { lock.unlock() }
        hubs[hub.host] = hub
    }

    static func remove(_ hub: StandInHub) {
        lock.lock(); defer { lock.unlock() }
        hubs[hub.host] = nil
    }

    static func hub(_ host: String) -> StandInHub? {
        lock.lock(); defer { lock.unlock() }
        return hubs[host]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopLock = NSLock()
    private var stoppedValue = false
    private var stopped: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stoppedValue }

    override func stopLoading() {
        stopLock.lock()
        stoppedValue = true
        stopLock.unlock()
    }

    override func startLoading() {
        guard let url = request.url, let hub = Self.hub(url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let seen = Seen(method: request.httpMethod ?? "GET", path: parts?.percentEncodedPath ?? url.path,
                        query: parts?.percentEncodedQuery, headers: request.allHTTPHeaderFields ?? [:],
                        body: body.flatMap { JSONValue.parse($0) }, bytes: body)
        if let code = hub.failWith?(seen) {
            hub.note(seen)
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        if let (code, given, part) = hub.endless?(seen) {
            // A body with no end: the same part again and again, until the client ends the request.
            hub.note(seen)
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: given)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // On a thread of its own, so that the client's cancel reaches stopLoading. Each part goes only after the
            // client took the one before (the task's count of bytes received), so the parts sent past the limit do
            // not hang on the load of this Mac. A bound, so that a regression fails and does not hang: 2,000 parts,
            // and a client that stops taking parts and does not end the request gets the end of the answer after one
            // wait of 5 seconds, so the test ends in seconds whatever the program does (and fails for a wrong one).
            let me = self
            DispatchQueue.global().async {
                for index in 0..<2_000 {
                    let end = Date().addingTimeInterval(5)
                    while !me.stopped, (me.task?.countOfBytesReceived ?? 0) < Int64(index * part.count) {
                        if Date() >= end {
                            me.client?.urlProtocolDidFinishLoading(me)
                            return
                        }
                        usleep(200)
                    }
                    if me.stopped { return }
                    me.client?.urlProtocol(me, didLoad: part)
                    hub.sentPart()
                }
                me.client?.urlProtocolDidFinishLoading(me)
            }
            return
        }
        let status: Int, data: Data
        var headers: [String: String]
        if let given = hub.full?(seen) {
            hub.note(seen)
            (status, headers, data) = given
        } else if let given = hub.raw?(seen) {
            hub.note(seen)
            (status, headers, data) = (given.0, ["Content-Type": given.1], given.2)
        } else {
            let (code, answer) = hub.respond(seen)
            (status, headers, data) = (code, ["Content-Type": "application/json"], Data(answer.dumps().utf8))
        }
        if headers.isEmpty { headers = ["X-Stand-In": "1"] }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The stand-in hub's state and answers: a generation, a team.json SHA-256, the features it lists, the revision of a
/// goal, duty or rule, and a page for each other read. `answer` can take a request first, for one test's refusal.
final class StandInHub: @unchecked Sendable {
    /// A made-up name of its own, or the address that a test gives it (a number, for a test of this Mac's key, whose
    /// file is found by a name's lookup: no test asks a resolver).
    let host: String
    var base: String { "http://\(host):8765" }
    private let lock = NSLock()
    private var seenList: [Seen] = []
    private var dbValue = "g1"
    private var featuresValue: [String]
    var sha = "sha-1"
    var revision: JSONValue = .int(12)
    var state: [String: JSONValue] = [:]
    var answer: (@Sendable (Seen) -> (Int, JSONValue)?)?
    /// An answer that is no JSON: its status, its Content-Type and its bytes.
    var raw: (@Sendable (Seen) -> (Int, String, Data)?)?
    /// A whole answer: its status, its headers and its bytes (the parity check's recorded answers).
    var full: (@Sendable (Seen) -> (Int, [String: String], Data)?)?
    /// An answer whose body has no end: its status, its headers, and the part that it sends again and again.
    var endless: (@Sendable (Seen) -> (Int, [String: String], Data)?)?
    private var partsValue = 0
    /// How many parts of an endless body were sent.
    var parts: Int { lock.lock(); defer { lock.unlock() }; return partsValue }
    func sentPart() { lock.lock(); partsValue += 1; lock.unlock() }
    /// A request that fails with this error of URLSession, as a network that broke.
    var failWith: (@Sendable (Seen) -> URLError.Code?)?

    func note(_ request: Seen) {
        lock.lock()
        seenList.append(request)
        lock.unlock()
    }

    init(features: [String], host: String? = nil) {
        self.host = host ?? "h\(UUID().uuidString.lowercased().prefix(12)).example.com"
        featuresValue = features
        StandInProtocol.add(self)
    }

    deinit { StandInProtocol.remove(self) }

    var seen: [Seen] { lock.lock(); defer { lock.unlock() }; return seenList }
    var db: String {
        get { lock.lock(); defer { lock.unlock() }; return dbValue }
        set { lock.lock(); dbValue = newValue; lock.unlock() }
    }
    var features: [String] {
        get { lock.lock(); defer { lock.unlock() }; return featuresValue }
        set { lock.lock(); featuresValue = newValue; lock.unlock() }
    }

    func respond(_ request: Seen) -> (Int, JSONValue) {
        lock.lock()
        seenList.append(request)
        let db = dbValue, features = featuresValue
        lock.unlock()
        if let answer, let given = answer(request) { return given }
        let stale: (Int, JSONValue) = (409, .object(["error": .string("hub generation changed; refresh state")]))
        if request.method == "POST" {
            if request.body?["db"] != .string(db) { return stale }
            return (200, .object(["ok": .bool(true), "route": .string(request.path)]))
        }
        if request.path == "/ui/state" {
            var answer = state
            answer["db"] = .string(db)
            answer["ui_features"] = .array(features.map(JSONValue.string))
            return (200, .object(answer))
        }
        if !(request.query ?? "").hasPrefix("db=\(db)") { return stale }
        if request.path == "/ui/team" { return (200, .object(["sha256": .string(sha), "lines": .array([])])) }
        let parts = request.path.split(separator: "/").map(String.init)
        if parts.count == 3, let thing = ["goals": "goal", "responsibilities": "responsibility",
                                         "triggers": "trigger"][parts[1]] {
            return (200, .object([thing: .object(["id": .int(Int64(parts[2]) ?? 0), "revision": revision])]))
        }
        return (200, .object(["page": .string(request.path)]))
    }
}

/// What every test of the tools needs: the table that `owner_mcp.py --dump-tools` prints (a committed copy, which
/// test_owner_mcp.Table holds to that print), a scratch home and the tools on a stand-in hub.
enum Fixture {
    static let table: OwnerTable = {
        let url = Bundle.module.url(forResource: "owner-tools", withExtension: "json", subdirectory: "Fixtures")!
        return try! OwnerTable.load(from: url)
    }()

    static var everyFeature: [String] { Array(Set(table.tools.compactMap(\.feature))).sorted() }

    static func home() -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("owner-api-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    static func transport() -> SessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StandInProtocol.self]
        return SessionTransport(configuration: configuration, timeout: 10)
    }

    /// The tools on `hub`, or on the address of the `setting`. Nothing here reads the app's real setting.
    static func tools(_ hub: StandInHub?, home: URL, setting: String?? = nil, ownBuild: Int? = nil,
                      started: @escaping @Sendable () -> Int? = { nil }, table: OwnerTable = Fixture.table,
                      now: @escaping @Sendable () -> Date = { Date() }, relay: ProgramRelay? = nil) -> OwnerTools {
        let address: String? = setting ?? hub?.base
        let context = OwnerContext(hubSetting: { address }, transport: transport(), home: home,
                                   userAgent: "founderizer-cli/test", ownBuild: ownBuild, startedBuild: started,
                                   clientLabel: { "founderizer-cli/1/test" }, now: now, relay: relay)
        return OwnerTools(table: table, context: context)
    }

    /// The table with one tool changed.
    static func table(changing name: String, _ change: (OwnerTable.Tool) -> OwnerTable.Tool) -> OwnerTable {
        let t = table
        return OwnerTable(tools: t.tools.map { $0.name == name ? change($0) : $0 }, instructions: t.instructions,
                          protocolVersion: t.protocolVersion, supported: t.supported, pages: t.pages,
                          pageQuery: t.pageQuery, pageWords: t.pageWords, pageInPath: t.pageInPath,
                          historyWords: t.historyWords, costsWords: t.costsWords, mediaTypes: t.mediaTypes, version: t.version)
    }
}

extension OwnerTools {
    /// One call whose answer is the hub's JSON: the data mark and the JSON after it.
    func json(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        let (text, isError) = call(name, .object(arguments))
        guard !isError else { throw OwnerRefusal(text) }
        let mark = OwnerTools.dataMark + "\n"
        guard text.hasPrefix(mark), let value = JSONValue.parse(String(text.dropFirst(mark.count))) else {
            throw OwnerRefusal("no data mark: \(text)")
        }
        return value
    }

    func refused(_ name: String, _ arguments: [String: JSONValue] = [:]) -> String? {
        let (text, isError) = call(name, .object(arguments))
        return isError ? text : nil
    }
}
