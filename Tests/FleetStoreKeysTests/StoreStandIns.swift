import CryptoKit
import FleetCore
import Foundation
@testable import FleetStoreKeys

// Stand-ins for the store's tests. Invented values only: no Bitwarden host, no real token, no network. Each wire has
// host names of its own under `.test`, which no name server answers, so a test that the stand-in does not catch
// reaches nothing.

/// **Bitwarden's two hosts, answered in this process**: it records each request, and answers each one with the
/// replies given for its method and path, in turn, the last of them for each later request. A request with no reply
/// gets a 404.
final class StoreWire: @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var form: [String: String] {
            Dictionary(uniqueKeysWithValues: String(decoding: body, as: UTF8.self).split(separator: "&").map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                return (parts[0], parts.count > 1 ? parts[1] : "")
            })
        }
    }

    enum Reply: Sendable {
        case answer(Int, String, [String: String])
        /// The connection fails with this code.
        case fail(URLError.Code)
        /// A redirect to this path of the same host.
        case redirect(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var wires: [String: StoreWire] = [:]

    let domain = UUID().uuidString.lowercased() + ".test"
    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var given: [String: Int] = [:]
    private var made: [Call] = []

    var identity: URL { URL(string: "https://identity.\(domain)")! }
    var api: URL { URL(string: "https://api.\(domain)")! }

    init() { Self.lock.withLock { Self.wires[domain] = self } }

    static func wire(for url: URL?) -> StoreWire? {
        guard let host = url?.host, let dot = host.firstIndex(of: ".") else { return nil }
        return lock.withLock { wires[String(host[host.index(after: dot)...])] }
    }

    func on(_ method: String, _ path: String, _ reply: Reply) {
        lock.withLock { replies["\(method) \(path)", default: []].append(reply) }
    }

    func on(_ method: String, _ path: String, _ status: Int, _ body: String = "{}", headers: [String: String] = [:]) {
        on(method, path, .answer(status, body, headers))
    }

    var calls: [Call] { lock.withLock { made } }
    func calls(_ method: String, _ path: String) -> [Call] { calls.filter { $0.method == method && $0.path == path } }

    func reply(to request: URLRequest) -> Reply {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        return lock.withLock {
            made.append(Call(method: method, path: path, headers: request.allHTTPHeaderFields ?? [:], body: body))
            let key = "\(method) \(path)"
            guard let queue = replies[key], !queue.isEmpty else { return .answer(404, "{\"message\":\"Resource not found.\"}", [:]) }
            let index = min(given[key, default: 0], queue.count - 1)
            given[key] = index + 1
            return queue[index]
        }
    }

    /// A store on this wire, for `token` and `organization`.
    func store(token: String = Invented.token, organization: String = Invented.organization) -> BitwardenStore {
        BitwardenStore(token: token, organization: organization, identity: identity, api: api,
                       protocols: [StoreWireProtocol.self])!
    }

    /// A good sign-in of the invented token, for `organization`.
    func signsIn(organization: String = Invented.organization) {
        on("POST", "/connect/token", 200, Invented.signIn(organization: organization))
    }
}

/// The `URLProtocol` that hands each request of a `.test` host to its wire.
final class StoreWireProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { StoreWire.wire(for: request.url) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let wire = StoreWire.wire(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch wire.reply(to: request) {
        case .answer(let status, let body, let headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect(let path):
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.path = path
            let target = components.url!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Invented values of a machine account and its organization.
enum Invented {
    static let organization = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    static let otherOrganization = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f"
    static let project = "11112222-3333-4444-8555-666677778888"
    static let ownProject = "aaaabbbb-cccc-4ddd-8eee-ffff00001111"
    static let item = "12345678-9abc-4def-8123-456789abcdef"
    static let tokenID = "deadbeef-0000-4111-8222-333344445555"
    static let tokenKey = Data((0..<16).map { UInt8($0 &* 7 &+ 3) })
    static let token = "0.\(tokenID).inventedClientSecret0123456789:\(tokenKey.base64EncodedString())"
    static let organizationKey = Data((0..<64).map { UInt8($0 ^ 0x5a) })
    static let fleet = "0123456789abcdef"
    static let reference = "bws://0f0e0d0c-0b0a-4090-8070-605040302010"

    static var key: CompositeKey { CompositeKey(organizationKey)! }

    /// A sign-in's answer: a JWT that names `organization`, and the payload sealed with the token's key.
    static func signIn(organization: String = organization) -> String {
        let claims = try! JSONSerialization.data(withJSONObject: ["organization": organization, "scope": ["api.secrets"]])
        let middle = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let payload = try! JSONSerialization.data(withJSONObject: ["encryptionKey": organizationKey.base64EncodedString()])
        let sealed = try! EncString.seal(payload, key: BitwardenAccessToken(token)!.key)
        let answer: [String: Any] = ["access_token": "eyJhbGciOiJub25lIn0.\(middle).c2lnbmVk", "expires_in": 3600,
                                     "token_type": "Bearer", "scope": "api.secrets", "encrypted_payload": sealed]
        return String(decoding: try! JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    }

    /// `GET secrets/<id>`'s answer for an item of `project` with this name and note, sealed with the organization key.
    static func secret(id: String = item, project: String = project, name: String, note: String) -> String {
        let answer: [String: Any] = ["object": "secret", "id": id, "organizationId": organization,
                                     "key": try! EncString.seal(name, key: key), "value": try! EncString.seal("old", key: key),
                                     "note": try! EncString.seal(note, key: key),
                                     "projects": [["id": project, "name": "2.x"]], "read": true, "write": true]
        return String(decoding: try! JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    }

    /// A store key's spec, as the hub gives it.
    static func target(project: String = project, made: [String: Any]? = nil) -> StoreKeyTarget {
        var fields: [String: Any] = ["repo": "acme/gitops", "path": "platform/stores/main.yaml",
                                     "store_kind": "ClusterSecretStore", "store": "main", "namespace": "shop",
                                     "name": "stripe-key-a1b2c3", "provider": "bitwardensecretsmanager", "region": "us",
                                     "organization": organization, "project": project]
        for (key, value) in made ?? [:] { fields[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(StorePart<StoreKeyTarget>.self, from: data).value!
    }

    static func job(_ target: StoreKeyTarget = target(), need: Int = 42) -> StoreKeyJob {
        StoreKeyJob(fleet: fleet, need: need, agent: "devops", target: target)!
    }
}

/// **A store in memory**, for the steps of a Save: it records each call in order, and answers as it is told.
actor FakeStore: StoreProvider {
    var log: [String] = []
    var signInAnswer: StoreSignIn = .ok
    var canWriteAnswer: StoreProjectAccess = .writes
    var writableAnswer: StoreWritable = .projects([])
    var createAnswers: [StoreCreate] = [.made(Invented.item)]
    var readAnswer: StoreRead = .gone
    var findAnswer: StoreFind = .items([])
    var updateAnswer: StoreUpdate = .updated
    var updated: [(OwnStoreItem, String)] = []

    func set(_ change: @Sendable (isolated FakeStore) -> Void) { change(self) }
    func count(_ name: String) -> Int { log.filter { $0 == name }.count }

    func signIn() -> StoreSignIn { log.append("signIn"); return signInAnswer }
    func canWrite(project: String) -> StoreProjectAccess { log.append("canWrite"); return canWriteAnswer }
    func writable() -> StoreWritable { log.append("writable"); return writableAnswer }
    func create(name: String, value: String, note: String, project: String) -> StoreCreate {
        log.append("create")
        return createAnswers.count > 1 ? createAnswers.removeFirst() : createAnswers[0]
    }
    func read(id: String) -> StoreRead { log.append("read"); return readAnswer }
    func find(name: String, note: String, project: String) -> StoreFind { log.append("find"); return findAnswer }
    func update(_ item: OwnStoreItem, value: String) -> StoreUpdate {
        log.append("update")
        updated.append((item, value))
        return updateAnswer
    }
}

/// **The hub's steps of one request, in memory**: it answers `open` as it is told, and records each step.
actor FakeSteps: StoreKeySteps {
    struct Refusal: LocalizedError { var errorDescription: String? { "The hub refused it." } }
    var log: [String] = []
    var opens: [StoreOpened] = [.first]
    var openIDs: [String] = []
    var noneIDs: [String] = []
    var made: [(secret: String, remote: String, statement: String, signature: String)] = []
    var updatedWith: [(statement: String?, signature: String?)] = []
    var refuseNone = false

    func set(_ change: @Sendable (isolated FakeSteps) -> Void) { change(self) }

    func open(openID: String) throws -> StoreOpened {
        log.append("open")
        openIDs.append(openID)
        return opens.count > 1 ? opens.removeFirst() : opens[0]
    }
    func none(openID: String) throws {
        log.append("none")
        if refuseNone { throw Refusal() }
        noneIDs.append(openID)
    }
    func made(secret: String, remote: String, statement: String, signature: String) throws {
        log.append("made")
        made.append((secret, remote, statement, signature))
    }
    func updated(statement: String?, signature: String?) throws {
        log.append("updated")
        updatedWith.append((statement, signature))
    }
}

/// An owner key in memory that writes each signature into a shared log, so a test sees when it signed.
struct LoggingKey: OwnerKey, @unchecked Sendable {
    let inner = SoftwareOwnerKey()
    let log: Log
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }
    var publicKey: String { inner.publicKey }
    func sign(_ statement: String) throws -> String {
        log.add("sign")
        return try inner.sign(statement)
    }
}

/// A clock that passes the clock check, and one that does not: the hub's clock two hours from this Mac's.
enum Clocks {
    static let good = StoreClock(hubTime: 1_795_000_000, readAt: 1_795_000_010)
    static let wrong = StoreClock(hubTime: 1_795_000_000, readAt: 1_795_007_200)
}
