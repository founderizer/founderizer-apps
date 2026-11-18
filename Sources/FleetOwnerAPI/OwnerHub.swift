import Darwin
import Foundation

/// Something the agent must be told instead of a result. Its text is the whole answer and holds no secret.
public struct OwnerRefusal: Error, Sendable, Equatable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

/// A tool that could not be sent at all, as Python's `KeyError` or `ValueError` in `call_tool`: "<tool> could not be
/// sent: 'agent'".
struct NotSent: Error {
    let reason: String
}

/// One answer of the owner API: its status, the JSON it gave (or nil), its raw bytes and its headers.
public struct HubAnswer: Sendable {
    public let status: Int
    public let data: JSONValue?
    public let raw: Data
    /// The headers, by their names in lower case.
    public let headers: [String: String]

    public init(status: Int, data: JSONValue?, raw: Data, headers: [String: String]) {
        self.status = status
        self.data = data
        self.raw = raw
        self.headers = headers
    }

    /// The hub's `error`, as Python's f-string writes it, or nil.
    public var error: String? {
        guard let said = data?["error"], !said.isNull else { return nil }
        return said.pythonText
    }

    /// The hub's `auth`, the code of a 403 that is about a credential, or nil.
    public var auth: String? { data?["auth"]?.string }
}

/// **This Mac's own key for a hub** (`hub.py`, owner feature `owner_key`): the hub knows the owner's Mac by its
/// address and this key, both, so that a VM or a container on the Mac, which leaves through the Mac's address, is not
/// the owner. One file for each hub address, `<address>_<port>` in `~/.founderizer/owner-keys` by the hub's numeric
/// address, which the Founderizer app or a claim wrote and only this user reads (`OwnerMacKey` in FleetCore,
/// `owner_key_place` in `owner_mcp.py`: the same name). This program only reads it, at each call, and gives it to
/// no tool. A call that carries it goes to that number (`find`, `numbered`).
public enum OwnerComputerKey {
    /// `<host>_<port>` of a hub's address, or nil for an address with no host.
    public static func name(base: String) -> String? {
        guard let (host, port) = parts(base) else { return nil }
        return name(host: host, port: port)
    }

    static func parts(_ base: String) -> (host: String, port: Int)? {
        guard let url = URL(string: base.contains("://") ? base : "http://" + base),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return (host, url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
    }

    static func name(host: String, port: Int) -> String {
        let letters = host.unicodeScalars.map { scalar -> Character in
            let plain = (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar == "." || scalar == "-"
            return plain ? Character(scalar) : "-"
        }
        return String(letters) + "_\(port)"
    }

    static func key(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), data.count <= 256,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil else { return nil }
        return text
    }

    /// The numeric address of a host name through the system's own lookup, or nil (`chosen`).
    public static let systemLookup: @Sendable (String) -> String? = { host in
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0, let found else { return nil }
        defer { freeaddrinfo(found) }
        var all: [String] = [], next: UnsafeMutablePointer<addrinfo>? = found
        while let one = next {
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(one.pointee.ai_addr, one.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0,
                           NI_NUMERICHOST) == 0 {
                all.append(String(cString: text).lowercased())
            }
            next = one.pointee.ai_next
        }
        return chosen(all)
    }

    /// The one address of a name's addresses that names its key's file, the same one for the same set in any order:
    /// an address of the fleet's private network first (100.64.0.0/10), else the lowest IPv4 address, else the lowest
    /// of the others (`OwnerMacKey.chosen` in the app: the same rule).
    static func chosen(_ addresses: [String]) -> String? {
        func four(_ text: String) -> [UInt8]? {
            var address = in_addr()
            guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
            return withUnsafeBytes(of: &address) { Array($0) }
        }
        let fours = addresses.compactMap { text in four(text).map { (text, $0) } }.sorted { $0.1.lexicographicallyPrecedes($1.1) }
        if let fleet = fours.first(where: { $0.1[0] == 100 && (64...127).contains($0.1[1]) }) { return fleet.0 }
        return fours.first?.0 ?? addresses.compactMap(canonical).sorted().first
    }

    static func isAddress(_ host: String) -> Bool { canonical(host) != nil }

    /// An address in the one spelling that names a key's file, or nil for what is no address (`OwnerMacKey.canonical`).
    static func canonical(_ host: String) -> String? {
        var four = in_addr(), six = in6_addr()
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, host, &four) == 1, inet_ntop(AF_INET, &four, &text, socklen_t(text.count)) != nil {
            return String(cString: text)
        }
        if inet_pton(AF_INET6, host, &six) == 1, inet_ntop(AF_INET6, &six, &text, socklen_t(text.count)) != nil {
            return String(cString: text).lowercased()
        }
        return nil
    }

    /// The key for the hub at `base`, or nil while this Mac has none, as the app finds it (`OwnerMacKey.signing`),
    /// and the number that a call with that key goes to. One hub address has one key file, named by its number. For
    /// a hub that is called by a name, the name is looked up once: the key is the one of that number's file, and a
    /// name that has no number now has no key. While the folder holds no file of that port nothing is looked up.
    public static func find(base: String, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                            lookup: (String) -> String? = systemLookup) -> (key: String, address: String)? {
        guard let (host, port) = parts(base) else { return nil }
        let folder = home.appendingPathComponent(".founderizer/owner-keys", isDirectory: true)
        var address = canonical(host) ?? ""
        if address.isEmpty {
            let tail = "_\(port)"
            guard ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .contains(where: { $0.hasSuffix(tail) && !$0.hasPrefix(".") }),
                  let found = lookup(host).flatMap(canonical) else { return nil }
            address = found
        }
        return key(in: folder.appendingPathComponent(name(host: address, port: port))).map { ($0, address) }
    }

    public static func read(base: String, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                            lookup: (String) -> String? = systemLookup) -> String? {
        find(base: base, home: home, lookup: lookup)?.key
    }

    /// `url` with `address`, a number, as its host: where a call that carries the key goes. **The key goes to the
    /// number that named its file, and never to the name again**: a connection looks a name up by itself, and that
    /// second answer can be another host than the first (`OwnerMacKey.signing` in the app).
    static func numbered(_ url: URL, address: String) -> URL? {
        guard url.host?.lowercased() != address else { return url }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = address.contains(":") ? "[\(address)]" : address
        guard let numbered = parts.url, numbered.host.flatMap(canonical) == address else { return nil }
        return numbered
    }
}

/// How a request to the hub failed before it had an answer.
public enum TransportFailure: Error, Sendable {
    /// The hub did not answer: no connection.
    case unreachable(String)
    /// The connection went while the request was out: the request can have arrived.
    case lost(String)
    /// The answer is larger than this program reads.
    case tooLarge
}

/// **How much one request reads, and how long it waits.** An owner call reads at most 8 MiB (`owner_mcp.py`
/// READ_MAX) and waits 30 seconds for each part and 60 for the whole. A file (`attach_file`, `read_attachment`,
/// `take_backup`) reads up to the hub's own limit of that file and waits 60 seconds for each part and 900 for the whole,
/// as the Mac app reads a copy (`FleetCopy.takeCopy`) and as `owner_mcp.py` does since 14 November 2026 (FILE_WAIT,
/// FILE_TOTAL).
public struct Transfer: Sendable, Equatable {
    public let limit: Int
    public let file: Bool

    public static let call = Transfer(limit: 8 * 1024 * 1024, file: false)
    /// `hub.py` ATTACH_MAX: the largest file that the owner attaches.
    public static let attachment = Transfer(limit: 25 * 1024 * 1024, file: true)
    /// `hub.py` BACKUP_MAX: the largest copy that the hub serves.
    public static let backup = Transfer(limit: 256 * 1024 * 1024, file: true)

    public static let fileWait: TimeInterval = 60
    public static let fileTotal: TimeInterval = 900
}

/// The way to the hub: `URLSession` for the program, a stand-in for a test.
public protocol HubTransport: Sendable {
    func send(_ request: URLRequest, transfer: Transfer) throws(TransportFailure)
        -> (status: Int, headers: [String: String], body: Data)
}

extension HubTransport {
    public func send(_ request: URLRequest) throws(TransportFailure) -> (status: Int, headers: [String: String], body: Data) {
        try send(request, transfer: .call)
    }
}

/// **One request at a time, from a command-line program.** No proxy (`owner_mcp.py`'s `ProxyHandler({})`): the hub is on
/// the fleet's own private network. No redirect is followed, no cookie is kept and nothing is cached.
public final class SessionTransport: NSObject, HubTransport, @unchecked Sendable {
    public static let readMax = Transfer.call.limit
    private let session: URLSession
    /// The session of the file tools: the same rules, with the times of a file (`Transfer`).
    private let fileSession: URLSession

    /// `configuration`: a test gives one whose `protocolClasses` hold its stand-in hub, so that no port is opened.
    public init(configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 30) {
        func made(_ configuration: URLSessionConfiguration, wait: TimeInterval, total: TimeInterval) -> URLSession {
            configuration.connectionProxyDictionary = ["HTTPEnable": false, "HTTPSEnable": false]
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = wait
            configuration.timeoutIntervalForResource = total
            return URLSession(configuration: configuration, delegate: Loader(), delegateQueue: nil)
        }
        let files = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        session = made(configuration, wait: timeout, total: timeout * 2)
        fileSession = made(files, wait: Transfer.fileWait, total: Transfer.fileTotal)
        super.init()
    }

    deinit {
        session.finishTasksAndInvalidate()
        fileSession.finishTasksAndInvalidate()
    }

    /// One request's answer while it arrives.
    final class Arriving: @unchecked Sendable {
        var limit: Int
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        var tooLarge = false
        let done = DispatchSemaphore(value: 0)
        init(limit: Int) { self.limit = limit }
    }

    /// **The answer stops at its limit while it arrives**: a `Content-Length` above the limit ends the request at its
    /// headers, and a body that passes the limit by one byte ends it there, so a hub that sends a body with no end
    /// cannot fill this Mac's memory (before 14 November 2026 the whole body was read first). An answer that is not a
    /// success (an HTTP error) is words, never a file: its limit is the 8 MiB of a call, as `owner_mcp.py` reads it.
    /// No redirect is followed.
    final class Loader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var arriving: [Int: Arriving] = [:]

        func add(_ task: URLSessionTask, _ state: Arriving) {
            lock.lock(); defer { lock.unlock() }
            arriving[task.taskIdentifier] = state
        }

        private func state(_ task: URLSessionTask) -> Arriving? {
            lock.lock(); defer { lock.unlock() }
            return arriving[task.taskIdentifier]
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let state = state(dataTask) else { return completionHandler(.cancel) }
            let http = response as? HTTPURLResponse
            state.response = http
            if let status = http?.statusCode, !(200..<300).contains(status) {
                state.limit = min(state.limit, Transfer.call.limit)
            }
            if response.expectedContentLength > Int64(state.limit) {
                state.tooLarge = true
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let state = state(dataTask), !state.tooLarge else { return }
            state.data.append(data)
            if state.data.count > state.limit {
                state.tooLarge = true
                state.data = Data()
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let state = state(task) else { return }
            lock.lock()
            arriving[task.taskIdentifier] = nil
            lock.unlock()
            state.error = error
            state.done.signal()
        }
    }

    /// **Only an error that means no connection was made is "did not answer".** Every other error, a time-out
    /// included, can come after the request went out, so it is "lost": the request can have arrived, as
    /// `owner_mcp.py` says for an `OSError` after the send. A lost answer must never read as one that was not sent.
    public static let noConnection: Set<URLError.Code> = [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                                          .notConnectedToInternet, .badURL, .unsupportedURL,
                                                          .secureConnectionFailed]

    static func failure(_ error: Error) -> TransportFailure {
        if let code = (error as? URLError)?.code, noConnection.contains(code) {
            return .unreachable(error.localizedDescription)
        }
        return .lost(error.localizedDescription)
    }

    public func send(_ request: URLRequest, transfer: Transfer) throws(TransportFailure)
        -> (status: Int, headers: [String: String], body: Data) {
        let chosen = transfer.file ? fileSession : session
        let state = Arriving(limit: transfer.limit)
        let task = chosen.dataTask(with: request)
        (chosen.delegate as? Loader)?.add(task, state)
        task.resume()
        state.done.wait()
        if state.tooLarge { throw .tooLarge }
        if let error = state.error { throw Self.failure(error) }
        guard let http = state.response else { throw .lost("no HTTP answer") }
        let body = state.data
        if body.count > state.limit { throw .tooLarge }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String { headers[key.lowercased()] = "\(value)" }
        }
        return (http.statusCode, headers, body)
    }
}

/// **The one lock for commands on this Mac**: an exclusive `flock` on `~/.founderizer/lock`, held for the length of
/// one request to the hub, as `owner_mcp.py`'s `command_lock` takes it. So two clients, and this program beside
/// `owner_mcp.py`, never send two commands to one hub at the same time. A read never takes it. A Mac that cannot open
/// the file sends the request with no lock: the hub's own command rules still hold.
public enum CommandLock {
    public static func holding<T>(_ file: URL?, _ work: () throws -> T) rethrows -> T {
        guard let file else { return try work() }
        let folder = file.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let handle = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard handle >= 0 else { return try work() }
        defer { close(handle) }
        while flock(handle, LOCK_EX) != 0 && errno == EINTR {}
        defer { flock(handle, LOCK_UN) }
        return try work()
    }
}

/// **A client of the hub's owner API**, as `owner_mcp.py`'s `call`, `get` and `command` are: no `Origin`, which the
/// hub refuses on an owner route, and this Mac's key for that hub as the bearer when it has one (`OwnerComputerKey`),
/// because the hub knows this Mac by its address and that key; the hub's generation
/// (`db`) on every read and command, read again once when the hub says that it moved; a request id of its own for
/// each command; and the hub's refusal given back whole. It validates nothing that the hub validates.
///
/// One instance serves one process, one call at a time: it holds the generation and the hub's features between
/// calls, as the Python server does.
public final class OwnerHub: @unchecked Sendable {
    /// Where the hub is, as `http://<address>:<port>` with no "/" at the end.
    public private(set) var base: String
    let transport: HubTransport
    let userAgent: String
    /// `X-Fleet-Client` of each command: the label of this installation (`ClientLabel`).
    let clientLabel: () -> String
    /// The file of the lock for commands, or nil for none.
    let lockFile: URL?
    /// This Mac's key for the hub at a base and the number that a call with it goes to, read at each call
    /// (`OwnerComputerKey.find`). A test gives its own.
    let ownerKey: (String) -> (key: String, address: String)?
    private(set) var generationValue: String?
    /// The hub's `ui_features`, from the last read of `/ui/state`.
    private(set) var features: [String]?

    public init(base: String, transport: HubTransport, userAgent: String, clientLabel: @escaping () -> String,
                lockFile: URL?,
                ownerKey: @escaping (String) -> (key: String, address: String)? = { OwnerComputerKey.find(base: $0) }) {
        self.base = base
        self.transport = transport
        self.userAgent = userAgent
        self.clientLabel = clientLabel
        self.lockFile = lockFile
        self.ownerKey = ownerKey
    }

    /// Another hub: what was read of the old one is forgotten.
    func move(to base: String) {
        guard base != self.base else { return }
        self.base = base
        generationValue = nil
        features = nil
    }

    // ------------------------------------------------------------ one call

    /// One call to the owner API from this Mac. `body`: a JSON body, with `X-Fleet-Client`. `file`: instead, a body of
    /// these bytes under this media type, with its own headers, which carry what a JSON body would carry as fields
    /// (`POST /ui/attachments`, `owner_mcp.py`'s `mime` and `extra`). `transfer`: what the answer may be.
    public func call(_ method: String, _ path: String, body: JSONValue? = nil,
                     file: (data: Data, mime: String, headers: [(String, String)])? = nil,
                     transfer: Transfer = .call) throws -> HubAnswer {
        guard let url = URL(string: base + path) else {
            throw OwnerRefusal("The hub's address \(base) and the route \(path) make no address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let file {
            request.httpBody = file.data
            request.setValue(file.mime, forHTTPHeaderField: "Content-Type")
            request.setValue(clientLabel(), forHTTPHeaderField: "X-Fleet-Client")
            for (name, value) in file.headers { request.setValue(value, forHTTPHeaderField: name) }
        } else if let body {
            request.httpBody = Data(body.dumps().utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(clientLabel(), forHTTPHeaderField: "X-Fleet-Client")
        }
        // This Mac's key for this hub, when it has one. A hub from before the key, and a hub whose owner's Mac
        // registered none, refuses a bearer on an owner route before it does anything (403, `key_not_expected`): the
        // same call then goes again with none, as `owner_mcp.py`'s `call` sends it.
        // A call that carries the key goes to the hub's number, which named the key's file (`numbered`).
        var key: String?
        if let found = ownerKey(base), let numbered = OwnerComputerKey.numbered(url, address: found.address) {
            key = found.key
            request.url = numbered
            request.setValue("Bearer " + found.key, forHTTPHeaderField: "Authorization")
        }
        var sent: (status: Int, headers: [String: String], body: Data)
        do {
            sent = try transport.send(request, transfer: transfer)
            if key != nil, sent.status == 403,
               JSONValue.parse(sent.body)?["auth"]?.string == "key_not_expected" {
                request.setValue(nil, forHTTPHeaderField: "Authorization")
                request.url = url                       // with no key, the call goes as its address is written
                sent = try transport.send(request, transfer: transfer)
            }
        } catch {
            switch error {
            case .unreachable(let reason):
                throw OwnerRefusal("The hub at \(base) did not answer (\(reason)). Check that it runs and that this Mac "
                                   + "is on the fleet's private network.")
            case .lost(let reason):
                throw OwnerRefusal("The call to the hub at \(base) was lost: \(reason). The request can have arrived: "
                                   + "read the fleet before you send it again.")
            case .tooLarge:
                throw OwnerRefusal("The hub's answer is larger than this server reads.")
            }
        }
        let kind = (sent.headers["content-type"] ?? "").split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let blank = sent.body.allSatisfy { [9, 10, 13, 32].contains($0) }
        let parsed = kind == "application/json" && !blank ? JSONValue.parse(sent.body) : nil
        return HubAnswer(status: sent.status, data: parsed, raw: sent.body, headers: sent.headers)
    }

    // ------------------------------------------------------------ the hub's own refusal

    /// The hub's own refusal, as the agent must read it, with everything else the hub said beside the reason
    /// (`owner_mcp.py`'s `refusal`, in its words). 403 is the one refusal that is about this program itself. A route or
    /// a field that the hub does not know gets one sentence more: the hub updates by itself, and it can be older than
    /// the app.
    public func refusal(_ answer: HubAnswer, _ what: String) -> OwnerRefusal {
        if answer.status == 403, let auth = answer.auth, auth == "owner_key_required" || auth == "owner_key_mismatch" {
            return OwnerRefusal("The hub refused \(what): \(answer.error ?? auth). The hub asks each call from the "
                                + "owner's computer for that computer's key, and this program has "
                                + (auth == "owner_key_required" ? "none" : "another one") + " for this hub in "
                                + "~/.founderizer/owner-keys. Open Founderizer on this computer once: it registers "
                                + "the key by itself. A program in a VM or a container on this computer is not the "
                                + "owner.")
        }
        if answer.status == 403 {
            return OwnerRefusal("The hub refused \(what): \(answer.error ?? "this is not the owner machine"). This "
                                + "server is the owner only while it runs on the Mac whose address is \"owner\" in "
                                + "team.json. Read the hub's own words above; the install's claim is what sets that "
                                + "address.")
        }
        var rest = answer.data?.object ?? [:]
        rest["error"] = nil
        let said = answer.error ?? String(decoding: answer.raw.prefix(200), as: UTF8.self)
        var text = "The hub refused \(what) (\(answer.status)): \(said)"
        if !rest.isEmpty { text += "\n" + JSONValue.object(rest).dumps(indent: 1) }
        if Self.unknownToTheHub(answer) { text += "\n" + Self.olderHub }
        return OwnerRefusal(text)
    }

    /// The sentence that a refusal of a route or a field that the hub does not know gets.
    public static let olderHub = "This hub can be older than the Founderizer app on this Mac: a route or a field "
        + "that it does not know yet comes with its next update."

    /// The hub's answer to a route that it does not serve (404 `"not found"`), or to a field that the route does not
    /// take (`hub.py` `only`: 400 "unknown field <name>"), and no other: `test_owner_mcp.Parity` reads the same rule
    /// from `hub.py`, and the parity fixture says for each case where the sentence must stand.
    static func unknownToTheHub(_ answer: HubAnswer) -> Bool {
        let error = answer.error ?? ""
        return (answer.status == 404 && PyText.same(error, "not found"))
            || (answer.status == 400 && error.unicodeScalars.starts(with: "unknown field ".unicodeScalars))
    }

    // ------------------------------------------------------------ reads and commands

    /// The hub's generation (`db`), which every read and every command is bound to. A hub that restarted with a new
    /// database answers 409 to the old one, and this reads it again once, as the app does on that refusal.
    @discardableResult
    public func generation(fresh: Bool = false) throws -> String {
        if fresh || generationValue == nil { _ = try state() }
        return generationValue!
    }

    /// **One read of the hub's state, whole**: the read that `generation` makes, which keeps the generation and the
    /// features of its answer, and gives that answer too. `answer_needs_you` reads an item of it before a choice of 0
    /// or 1 (`AnswerDoor.press`), so that the command after it, if one goes, makes no second read.
    func state() throws -> JSONValue {
        let answer = try call("GET", "/ui/state")
        guard answer.status == 200, let db = answer.data?["db"], db.truthy else {
            throw refusal(answer, "a read of the fleet")
        }
        generationValue = db.pythonText
        noteFeatures(answer.data)
        return answer.data ?? .null
    }

    /// The hub's `ui_features`, from a read of `/ui/state`.
    func noteFeatures(_ state: JSONValue?) {
        if let list = state?["ui_features"]?.array { features = list.compactMap(\.string) }
    }

    /// The hub's features, read fresh when `fresh` or when none were read yet.
    func hubFeatures(fresh: Bool) throws -> [String] {
        if fresh || features == nil { try generation(fresh: true) }     // one read of /ui/state gives both
        return features ?? []
    }

    /// True when this answer is the hub saying that the generation moved: then one read again is the whole fix.
    func stale(_ answer: HubAnswer) -> Bool {
        answer.status == 409 && (answer.error ?? "").contains("generation")
    }

    /// One owner read route, with the generation that it asks for, and its answer whatever its status
    /// (`owner_mcp.py`'s `answered`): a hub with a new generation is read again once. `/ui/state` takes none. `query`:
    /// the route's own words, in their order; a null is left out.
    func answered(_ route: String, query: [(String, JSONValue)] = [], transfer: Transfer = .call) throws -> HubAnswer {
        func once() throws -> HubAnswer {
            var words: [(String, String)] = route == "/ui/state" ? [] : [("db", try generation())]
            words += query.filter { !$0.1.isNull }.map { ($0.0, $0.1.pythonText) }
            let path = route + (words.isEmpty ? "" : "?" + Self.urlencode(words))
            return try call("GET", path, transfer: transfer)
        }
        var answer = try once()
        if stale(answer) {
            try generation(fresh: true)
            answer = try once()
        }
        return answer
    }

    /// One owner read route (`answered`), and the hub's own refusal for every answer that is not a 200.
    public func get(_ route: String, _ what: String, query: [(String, JSONValue)] = [],
                    transfer: Transfer = .call) throws -> HubAnswer {
        let answer = try answered(route, query: query, transfer: transfer)
        guard answer.status == 200 else { throw refusal(answer, what) }
        if route == "/ui/state" { noteFeatures(answer.data) }
        return answer
    }

    /// One owner command route: the envelope of `hub.py` `ui_command` (`request_id`, `db`), and its answer as the hub
    /// gave it. `requestID`: the agent's own, when it sends the same command again after a lost answer; else this
    /// makes one. The lock is held for the one request, never for the read of the generation.
    public func command(_ route: String, _ body: [String: JSONValue], _ what: String,
                        requestID: JSONValue? = nil) throws -> JSONValue? {
        let rid: String
        if let given = requestID, given.truthy { rid = given.pythonText } else { rid = UUID().uuidString.lowercased() }
        guard let parsed = UUID(uuidString: rid), parsed.uuidString.lowercased() == rid.lowercased() else {
            throw OwnerRefusal("request_id must be a UUID, or absent so that this server makes one.")
        }
        func once() throws -> HubAnswer {
            let db = try generation()
            var envelope = body
            envelope["request_id"] = .string(rid.lowercased())
            envelope["db"] = .string(db)
            return try CommandLock.holding(lockFile) { try call("POST", route, body: .object(envelope)) }
        }
        var answer = try once()
        if stale(answer) {
            try generation(fresh: true)
            answer = try once()
        }
        guard answer.status == 200 else {
            if answer.status == 409, let sha = answer.data?["sha256"], sha.truthy {
                throw OwnerRefusal("The hub refused \(what): \(answer.error ?? "None"). Another change reached "
                                   + "team.json meanwhile. Read the fleet again and send this command again.")
            }
            throw refusal(answer, what)
        }
        return answer.data
    }

    /// `GET /ui/team`'s SHA-256 of `team.json`, which every command that moves it carries.
    func teamSHA256() throws -> JSONValue {
        try Self.teamSHA256(of: get("/ui/team", "a read of the team").data)
    }

    /// The same of a read of the team that the caller made already (`share_resource`, whose one read also serves its
    /// rule for a secret): `page["sha256"]` as `owner_mcp.py` reads it.
    static func teamSHA256(of team: JSONValue?) throws -> JSONValue {
        guard let team, team.object != nil else { throw NotSent(reason: "'NoneType' object is not subscriptable") }
        guard let sha = team["sha256"] else { throw NotSent(reason: "'sha256'") }
        return sha
    }

    // ------------------------------------------------------------ Python's urlencode

    /// `urllib.parse.urlencode` of these words: each name and value as `quote_plus` writes them.
    public static func urlencode(_ words: [(String, String)]) -> String {
        words.map { quotePlus($0.0) + "=" + quotePlus($0.1) }.joined(separator: "&")
    }

    static func quotePlus(_ text: String) -> String {
        quote(text, safe: "").replacingOccurrences(of: "%20", with: "+")
    }

    /// `urllib.parse.quote(text, safe=safe)`: letters, digits and "_.-~" stay, and every other byte is %XX.
    public static func quote(_ text: String, safe: String = "") -> String {
        var out = ""
        for byte in Array(text.utf8) {
            let scalar = Unicode.Scalar(byte)
            let character = Character(scalar)
            if (byte < 0x80 && (character.isLetter || character.isNumber)) || "_.-~".contains(character)
                || (byte < 0x80 && safe.contains(character)) {
                out.append(character)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

/// **This installation's own public label** for `X-Fleet-Client`, kept across runs as the app keeps its installation
/// UUID and `owner_mcp.py` keeps its own (`client_label`): `founderizer-cli/1/<uuid>` in `~/.founderizer/cli-client`. It
/// is a record of the source, not authentication. A Mac that cannot keep the file gets a new label for this run.
public enum ClientLabel {
    public static func read(home: URL) -> String {
        let folder = home.appendingPathComponent(".founderizer", isDirectory: true)
        let file = folder.appendingPathComponent("cli-client")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        let label = "founderizer-cli/1/\(UUID().uuidString.lowercased())"
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        try? Data((label + "\n").utf8).write(to: file, options: .atomic)
        return label
    }
}
