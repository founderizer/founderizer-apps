import FleetCore
import Foundation

/// **Bitwarden's own address pair**: the US cloud or the EU cloud, the two that a store's manifest may name
/// (`bitwarden/clients`, `default-environment.service.ts`). An address from a manifest never reaches the client.
public enum StoreRegion: String, Sendable {
    case us, eu

    var identity: URL { URL(string: self == .us ? "https://identity.bitwarden.com" : "https://identity.bitwarden.eu")! }
    var api: URL { URL(string: self == .us ? "https://api.bitwarden.com" : "https://api.bitwarden.eu")! }
}

/// **Why a call of the store did not give its answer.**
public enum StoreFailure: Equatable, Sendable {
    /// Bitwarden's `invalid_client` at the sign-in, or a 401 of a route directly after a fresh sign-in.
    case tokenRefused
    /// The sign-in's JWT names another organization than the store's.
    case otherOrganization
    /// Bitwarden took the token, and its key does not open the sign-in's payload, or the payload holds no key of
    /// 64 bytes; or the JWT names no organization.
    case tokenUnusable
    /// Another 4xx.
    case refused(Int)
    /// No connection was made: no network, no name, no TLS, a refused connection. Nothing reached the store.
    case notSent
    /// All else: a timeout, a lost connection, a 3xx, a 5xx, an answer that this client cannot read.
    case noAnswer
}

public enum StoreSignIn: Equatable, Sendable { case ok, failed(StoreFailure) }

/// What `GET projects/<id>` says of one project.
public enum StoreProjectAccess: Equatable, Sendable {
    case writes
    /// `write: false`: the token can only read the project.
    case readOnly
    /// A 404: the token has no access to the project (Bitwarden's `ProjectsController.GetAsync`), or it is gone.
    case noAccess
    case failed(StoreFailure)
}

/// What `GET organizations/<id>/projects` says: the projects that the token can write.
public enum StoreWritable: Equatable, Sendable { case projects([String]), noAccess, failed(StoreFailure) }

/// **The outcome of one create call.**
public enum StoreCreate: Equatable, Sendable {
    /// A 2xx with a `STORE_UUID` id: the store made the item.
    case made(String)
    /// A 4xx, or a token that Bitwarden refused before the call: nothing was made.
    case refused
    /// No connection was made, or the call never left this Mac: nothing was sent.
    case notSent
    /// All else: a timeout, a lost connection, a 3xx, a 5xx, an answer that is not JSON, an id that is no
    /// `STORE_UUID`. The store may have the item.
    case unknown
}

/// **One item of the store, as `GET secrets/<id>` gives it**: its one project, and its name and note when they open
/// with the organization key. Never its value.
public struct StoreItem: Equatable, Sendable {
    public let id: String
    public let project: String?
    public let name: String?
    public let note: String?
}

public enum StoreRead: Equatable, Sendable { case item(StoreItem), gone, failed(StoreFailure) }
public enum StoreFind: Equatable, Sendable { case items([StoreItem]), failed(StoreFailure) }
public enum StoreUpdate: Equatable, Sendable { case updated, gone, failed(StoreFailure) }

/// **An item that this Mac made**, as the record names it: its id, the record's project, the name `<namespace>/<name>`
/// and the mark as its note, all read back from the store. Only `StoreSave.own` makes one, so `update` writes no
/// other item, and it sends the name, the note and the project again, so the mark stays.
public struct OwnStoreItem: Equatable, Sendable {
    public let id: String
    public let project: String
    public let name: String
    public let note: String

    init(id: String, project: String, name: String, note: String) {
        self.id = id; self.project = project; self.name = name; self.note = note
    }
}

/// **The store that the Mac writes** (`BitwardenStore`, and a stand-in in the tests). It has no delete call.
public protocol StoreProvider: Sendable {
    /// A fresh sign-in, in place of any earlier one.
    func signIn() async -> StoreSignIn
    func canWrite(project: String) async -> StoreProjectAccess
    func writable() async -> StoreWritable
    func create(name: String, value: String, note: String, project: String) async -> StoreCreate
    func read(id: String) async -> StoreRead
    /// The items of `project` whose name is `name` and whose note is `note`, each one read.
    func find(name: String, note: String, project: String) async -> StoreFind
    func update(_ item: OwnStoreItem, value: String) async -> StoreUpdate
}

/// **Bitwarden Secrets Manager, as one machine account writes it** (the door's stage B, section 4): plain HTTPS
/// calls of `URLSession`, with the crypto of `BitwardenCrypto.swift`. Read from Bitwarden's own source (22 November
/// 2026): the routes of `bitwarden/server` `SecretsController` and `ProjectsController`, the models
/// `SecretCreateRequestModel`, `SecretUpdateRequestModel` and `ProjectResponseModel`, and the sign-in of
/// `bitwarden/sdk-internal` (`AccessTokenRequest`, `send_identity_connect_request`).
///
/// - One session of its own: ephemeral, no cache, no cookie store, no cookie sent or kept, no stored credential, and
///   its delegate refuses each redirect, so a 3xx ends the call. It calls only Bitwarden's own address pair of its
///   region.
/// - A 401 of a route: it signs in again and sends the call one more time. Only a 401 directly after a fresh sign-in
///   counts as a refusal of the token. A refused call made no item, so sending it again makes none either.
/// - Each id that it puts in a path, and each id of an answer, is a `STORE_UUID`.
/// - It keeps the token, its bearer and the organization key in memory only, and prints none of them.
public actor BitwardenStore: StoreProvider, CustomReflectable {
    private let token: BitwardenAccessToken
    private let organization: String
    private let identity: URL
    private let api: URL
    private let session: URLSession
    private var bearer: String?
    private var organizationKey: CompositeKey?
    /// No call of a route has used the bearer of the last sign-in yet.
    private var fresh = false

    /// A store for one token, region and organization; nil for a token that is no access token, a region that is not
    /// `us` or `eu`, or an organization that is no `STORE_UUID`. It makes no call.
    public init?(token: String, region: String, organization: String) {
        guard let region = StoreRegion(rawValue: region) else { return nil }
        self.init(token: token, organization: organization, identity: region.identity, api: region.api, protocols: [])
    }

    /// For the tests: other addresses, and the `URLProtocol` classes that answer them.
    init?(token: String, organization: String, identity: URL, api: URL, protocols: [AnyClass]) {
        guard let parsed = BitwardenAccessToken(token), StoreUUID.valid(organization) else { return nil }
        self.token = parsed
        self.organization = organization
        self.identity = identity
        self.api = api
        session = URLSession(configuration: Self.configuration(protocols: protocols), delegate: NoRedirects(),
                             delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// The session's configuration: nothing kept between calls, and nothing kept after them.
    static func configuration(protocols: [AnyClass]) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        if !protocols.isEmpty { configuration.protocolClasses = protocols + (configuration.protocolClasses ?? []) }
        return configuration
    }

    nonisolated public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// The configuration of this store's own session, for the tests.
    nonisolated var sessionConfiguration: URLSessionConfiguration { session.configuration }

    // MARK: the sign-in

    public func signIn() async -> StoreSignIn {
        bearer = nil
        organizationKey = nil
        fresh = false
        var request = URLRequest(url: identity.appending(path: "connect/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        Self.common(&request)
        request.httpBody = Data(Self.form([("scope", "api.secrets"), ("client_id", token.id),
                                           ("client_secret", token.clientSecret),
                                           ("grant_type", "client_credentials")]).utf8)
        switch await wire(request) {
        case .notSent: return .failed(.notSent)
        case .lost: return .failed(.noAnswer)
        case .answer(let status, let data):
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard status == 200 else {
                if status == 400 || status == 401, object?["error"] as? String == "invalid_client" { return .failed(.tokenRefused) }
                return .failed(Self.failure(.answer(status, data)))
            }
            guard let jwt = object?["access_token"] as? String, !jwt.isEmpty, jwt.utf8.count < 16_384,
                  let payload = object?["encrypted_payload"] as? String else { return .failed(.noAnswer) }
            guard let named = SignInParts.organization(ofJWT: jwt) else { return .failed(.tokenUnusable) }
            guard named == organization else { return .failed(.otherOrganization) }
            guard let key = SignInParts.organizationKey(payload: payload, token: token) else { return .failed(.tokenUnusable) }
            bearer = jwt
            organizationKey = key
            fresh = true
            return .ok
        }
    }

    // MARK: the routes

    public func canWrite(project: String) async -> StoreProjectAccess {
        guard StoreUUID.valid(project) else { return .failed(.notSent) }
        switch await call("GET", "projects/\(project)") {
        case .answer(200, let data):
            guard let object = Self.object(data), object["id"] as? String == project,
                  let write = object["write"] as? Bool else { return .failed(.noAnswer) }
            return write ? .writes : .readOnly
        case .answer(404, _): return .noAccess
        case let other: return .failed(Self.failure(other))
        }
    }

    public func writable() async -> StoreWritable {
        switch await call("GET", "organizations/\(organization)/projects") {
        case .answer(200, let data):
            guard let list = Self.object(data)?["data"] as? [[String: Any]] else { return .failed(.noAnswer) }
            var ids: [String] = []
            for project in list {
                guard let id = project["id"] as? String, StoreUUID.valid(id), let write = project["write"] as? Bool else {
                    return .failed(.noAnswer)
                }
                if write { ids.append(id) }
            }
            return .projects(ids)
        case .answer(404, _): return .noAccess
        case let other: return .failed(Self.failure(other))
        }
    }

    public func create(name: String, value: String, note: String, project: String) async -> StoreCreate {
        guard StoreUUID.valid(project) else { return .notSent }
        let answer = await call("POST", "organizations/\(organization)/secrets") { key in
            try Self.json(["key": EncString.seal(name, key: key), "value": EncString.seal(value, key: key),
                           "note": EncString.seal(note, key: key), "projectIds": [project]])
        }
        switch answer {
        case .answer(let status, let data) where (200..<300).contains(status):
            guard let id = Self.object(data)?["id"] as? String, StoreUUID.valid(id) else { return .unknown }
            return .made(id)
        case .answer(let status, _) where (400..<500).contains(status): return .refused
        case .answer: return .unknown
        case .tokenRefused: return .refused
        case .signIn(.notSent), .signIn(.noAnswer), .notSent, .notMade: return .notSent
        case .signIn: return .refused
        case .lost: return .unknown
        }
    }

    public func read(id: String) async -> StoreRead {
        guard StoreUUID.valid(id) else { return .failed(.notSent) }
        switch await call("GET", "secrets/\(id)") {
        case .answer(200, let data):
            guard let object = Self.object(data), object["id"] as? String == id else { return .failed(.noAnswer) }
            return .item(item(id: id, object: object))
        case .answer(404, _): return .gone
        case let other: return .failed(Self.failure(other))
        }
    }

    public func find(name: String, note: String, project: String) async -> StoreFind {
        guard StoreUUID.valid(project) else { return .failed(.notSent) }
        let listed: [[String: Any]]
        switch await call("GET", "projects/\(project)/secrets") {
        case .answer(200, let data):
            guard let secrets = Self.object(data)?["secrets"] as? [[String: Any]] else { return .failed(.noAnswer) }
            listed = secrets
        case let other: return .failed(Self.failure(other))
        }
        guard let key = organizationKey else { return .failed(.noAnswer) }
        var ids: [String] = []
        for secret in listed {
            guard let id = secret["id"] as? String, StoreUUID.valid(id) else { return .failed(.noAnswer) }
            if let sealed = secret["key"] as? String, EncString.openText(sealed, key: key) == name { ids.append(id) }
        }
        var found: [StoreItem] = []
        for id in ids {
            switch await read(id: id) {
            case .item(let item) where item.note == note && item.project == project: found.append(item)
            case .item, .gone: continue
            case .failed(let failure): return .failed(failure)
            }
        }
        return .items(found)
    }

    public func update(_ item: OwnStoreItem, value: String) async -> StoreUpdate {
        guard StoreUUID.valid(item.id), StoreUUID.valid(item.project) else { return .failed(.notSent) }
        let answer = await call("PUT", "secrets/\(item.id)") { key in
            // bws sends valueChanged true for a new value, so Bitwarden keeps the old one as a version.
            try Self.json(["key": EncString.seal(item.name, key: key), "value": EncString.seal(value, key: key),
                           "note": EncString.seal(item.note, key: key), "projectIds": [item.project],
                           "valueChanged": true])
        }
        switch answer {
        case .answer(200, let data):
            return Self.object(data)?["id"] as? String == item.id ? .updated : .failed(.noAnswer)
        case .answer(404, _): return .gone
        case let other: return .failed(Self.failure(other))
        }
    }

    // MARK: the calls

    private func item(id: String, object: [String: Any]) -> StoreItem {
        let projects = (object["projects"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        let project = projects.count == 1 && StoreUUID.valid(projects[0]) ? projects[0] : nil
        let open: (String) -> String? = { [organizationKey] field in
            guard let key = organizationKey, let sealed = object[field] as? String else { return nil }
            return EncString.openText(sealed, key: key)
        }
        return StoreItem(id: id, project: project, name: open("key"), note: open("note"))
    }

    private enum Wire { case answer(Int, Data), notSent, lost }

    private enum Answer {
        case answer(Int, Data)
        /// No connection was made.
        case notSent
        /// The call was not made: its body could not be sealed.
        case notMade
        /// The call may have arrived, and no answer came.
        case lost
        /// A 401 directly after a fresh sign-in.
        case tokenRefused
        /// A sign-in before the call, or between its two tries, failed: the call of that try was not sent.
        case signIn(StoreFailure)
    }

    private static func failure(_ answer: Answer) -> StoreFailure {
        switch answer {
        // A 429 says nothing of the token or the item: Bitwarden only asks for fewer calls.
        case .answer(let status, _): return (400..<500).contains(status) && status != 429 ? .refused(status) : .noAnswer
        case .notSent, .notMade: return .notSent
        case .lost: return .noAnswer
        case .tokenRefused: return .tokenRefused
        case .signIn(let failure): return failure
        }
    }

    /// One call of a route, with the bearer of a sign-in, and the rule of the 401.
    private func call(_ method: String, _ path: String, body: (@Sendable (CompositeKey) throws -> Data)? = nil) async -> Answer {
        if bearer == nil, case .failed(let failure) = await signIn() { return .signIn(failure) }
        for attempt in 0..<2 {
            guard let bearer, let key = organizationKey else { return .signIn(.noAnswer) }
            var request = URLRequest(url: api.appending(path: path))
            request.httpMethod = method
            Self.common(&request)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            if let body {
                guard let data = try? body(key) else { return .notMade }
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = data
            }
            let wasFresh = fresh
            switch await wire(request) {
            case .answer(401, _):
                fresh = false
                if wasFresh || attempt == 1 { return .tokenRefused }
                if case .failed(let failure) = await signIn() { return .signIn(failure) }
            case .answer(let status, let data):
                fresh = false
                return .answer(status, data)
            case .notSent: return .notSent
            case .lost:
                fresh = false
                return .lost
            }
        }
        return .tokenRefused
    }

    private func wire(_ request: URLRequest) async -> Wire {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .lost }
            return .answer(http.statusCode, data)
        } catch let error as URLError where Self.noConnection.contains(error.code) {
            return .notSent
        } catch {
            return .lost
        }
    }

    /// The errors of a call that made no connection, so that nothing of it reached the store.
    static let noConnection: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed,
        .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
        .appTransportSecurityRequiresSecureConnection, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
        .badURL, .unsupportedURL,
    ]

    private static func common(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("21", forHTTPHeaderField: "Device-Type")     // the SDK's own device type, `SDK`
        request.setValue("Founderizer", forHTTPHeaderField: "User-Agent")
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// `application/x-www-form-urlencoded`: each byte but the unreserved ones percent-encoded.
    static func form(_ fields: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        return fields.map { encoded($0.0) + "=" + encoded($0.1) }.joined(separator: "&")
    }
}

/// The session's delegate: it refuses each redirect, so the 3xx is the call's answer and no second request goes.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
