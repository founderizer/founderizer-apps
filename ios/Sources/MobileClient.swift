import FleetCore
import Foundation

/// What the hub answered, in the owner's words. The phone has its own refusals, because an owner device has two locks
/// and each failure asks for a different step (UI-API.md, "The key of a device").
enum MobileError: LocalizedError, Sendable, Equatable {
    case invalidAddress
    case invalidResponse
    /// The hub refused. `auth` is its reason when the refusal is about this device's key.
    case refusal(status: Int, auth: String?, message: String)
    /// The hub answers nothing at `GET /ui/mobile`: it is from before the phone's routes.
    case noPhoneRoutes
    case noAnswer

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an HTTP or HTTPS hub address without a path or login."
        case .invalidResponse: "The hub's answer does not match the phone's API."
        // The hub's reason as a sentence, and no status code: "atlas is in setup" reads "The hub refused it: Atlas is
        // in setup." The code stays in the error for what the app decides from it.
        case .refusal(_, let auth, let message):
            auth.map(MobileError.authWords) ?? "The hub refused it: \(MobileError.sentence(message))"
        case .noPhoneRoutes: "This hub does not have the phone's routes yet. The Mac app still works with it."
        // The Mac's words for the same failure, both sentences, so both apps say it one way (fix round 2, item 35).
        case .noAnswer: "Your hub did not answer. Check that its server is on."
        }
    }

    /// **A write that the hub refused, in a few words that say what failed** (fix round 2, item 36): "Not sent: Atlas is
    /// in setup." It read "The hub refused it: Atlas is in setup.", eight words with no "not" in them. A refusal of
    /// this phone's key keeps its own words, which say what to do.
    var notSentWords: String {
        guard case .refusal(_, nil, let message) = self else { return localizedDescription }
        return "Not sent: \(Self.sentence(message))"
    }

    /// The hub's words as a sentence: the first letter in upper case and a full stop at the end.
    static func sentence(_ words: String) -> String {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return trimmed.capitalizedFirst + (".!?".contains(last) ? "" : ".")
    }

    /// The hub decided, so sending the same request again changes nothing. A request that waits for an answer that
    /// may still come is never definitive: it keeps its number and the owner can retry it.
    var isDefinitive: Bool {
        if case .noPhoneRoutes = self { return true }
        guard case .refusal(let status, _, _) = self else { return false }
        return [400, 403, 404, 409, 413, 415, 422, 429, 503].contains(status)
    }

    /// The hub's `auth` value, when it named one.
    var auth: String? {
        guard case .refusal(_, let auth, _) = self else { return nil }
        return auth
    }

    /// What a refusal of the enrollment means and what the owner does next. The hub answers 403 for two different
    /// things here — the address is not one of its devices, or the code did not work — and they ask for different
    /// steps, so they never share a sentence. **Each is 12 words at most** (T-35): the one for a phone the hub does
    /// not know had 24, and the page's own line already says where the Mac makes a code.
    static func enrollWords(_ error: MobileError) -> String {
        switch error {
        case .refusal(429, _, _):
            return "Too many wrong codes. Wait an hour, or make a new code."
        case .refusal(403, _, let message):
            return message.lowercased().contains("owner device")
                ? "Your hub does not know this phone. Add it on your Mac."
                : "This code did not work. Make a new one on your Mac."
        default:
            return error.localizedDescription
        }
    }

    /// The words of a code that the hub refused, which cannot go again.
    static func refusedCode(_ words: String?) -> Bool {
        words == "This code did not work. Make a new one on your Mac." || words?.hasPrefix("Too many wrong codes") == true
    }

    /// What a refusal of this device means and what the owner does next. Each `auth` value is a different thing: not
    /// enrolled yet, no key sent, the wrong key, a route that the phone may not use, and a key where none is wanted.
    static func authWords(_ auth: String) -> String {
        switch auth {
        case "device_not_enrolled":
            "This phone is not enrolled. On your Mac press New code, then add this phone in Settings."
        case "device_key_required":
            "The hub wants this phone's key and the phone sent none. Add this phone again with a new code."
        case "device_key_mismatch":
            "This phone's key is not the one the hub keeps. Add this phone again with a new code."
        case "device_not_allowed":
            "The phone may not use that part of the hub. That setup work stays in the Mac app."
        case "key_not_expected":
            "This address is the owner's own Mac, which needs no key. Forget this phone's key in Settings."
        default:
            "The hub refused this phone (\(auth))."
        }
    }
}

/// Everything that Fleet Mobile sends to the hub. The Mac app's `HubClient` stays as it is: the phone has its own
/// routes, its own refusals and its own bearer token, and nothing here may change what the Mac sends. The session is
/// hardened in the same way: ephemeral, no cookie, no credential, no redirect, and no cache.
final class MobileClient: Sendable {
    private let session: URLSession
    /// The one host whose requests never leave this phone, because `protocolClass` answers them inside the app: the
    /// sample fleet's (`SampleHub`). Nil for a client of a hub.
    private let localHost: String?

    init(answering host: String? = nil, with protocolClass: AnyClass? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        if let protocolClass { configuration.protocolClasses = [protocolClass] + (configuration.protocolClasses ?? []) }
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        localHost = protocolClass == nil ? nil : host?.lowercased()
    }

    static func address(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme, ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url
        else { throw MobileError.invalidAddress }
        return url.appendingPathComponent("")
    }

    // MARK: Building one request

    /// One request to the hub. An enrolled phone carries its key as a bearer token on **every** call; a phone without
    /// a key sends no header at all, because the owner's own Mac is refused when it sends one (`key_not_expected`).
    /// The key never goes into the address, a query or a log.
    static func request(_ route: String, hub: URL, key: String?, query: [URLQueryItem] = [],
                        method: String = "GET") -> URLRequest {
        var parts = URLComponents(url: hub.appendingPathComponent(route), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// What the hub's answer means. `false` is 304: the fleet did not change and there is no body. Every refusal
    /// carries the hub's own words and, for a device, its `auth` reason.
    static func check(_ response: HTTPURLResponse, data: Data) throws -> Bool {
        switch response.statusCode {
        case 200: return true
        case 304: return false
        default:
            let body = try? JSONDecoder().decode(RefusalBody.self, from: data)
            throw MobileError.refusal(status: response.statusCode, auth: body?.auth,
                                      message: String((body?.error ?? "The hub gave no reason.").prefix(500)))
        }
    }

    private struct RefusalBody: Decodable { let error: String?; let auth: String? }

    /// **Every request of the phone goes through here, and in the app that hosts the unit tests none leaves this Mac**
    /// (review B9i): whatever path asks — a read, a send, a link, a file, a press on a ping — a request to any other
    /// host is refused before it goes, because the built-in address is the owner's own hub. A stand-in on this Mac
    /// still answers a check, and so does the sample fleet, which this app answers itself.
    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if Self.hostsTests, !Self.isLoopback(request.url), !answersHere(request.url) { throw OffThisMac() }
        return try await session.data(for: request)
    }

    /// The request goes to the host that this app answers itself (`localHost`), so it never leaves the phone.
    private func answersHere(_ url: URL?) -> Bool {
        guard let localHost, let host = url?.host?.lowercased() else { return false }
        return host == localHost
    }

    /// This process runs the unit tests (Xcode's test host). It lives here and not on the store, because the share
    /// extension sends through this client and has no store.
    static let hostsTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// What a request off this Mac meets in the app that hosts the checks: no answer of a network can be this.
    struct OffThisMac: Error {}

    /// An address on this Mac, which is all that a check may reach.
    static func isLoopback(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do { (data, response) = try await self.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw error is URLError ? MobileError.noAnswer : error }
        guard let response = response as? HTTPURLResponse else { throw MobileError.invalidResponse }
        _ = try Self.check(response, data: data)
        return (data, response)
    }

    // MARK: The reads

    /// The compact read, with the generation that the phone holds and the tag of its last body. The tag is the whole
    /// point on a phone: an unchanged fleet answers 304 with no body at all.
    static func snapshotRequest(hub: URL, key: String?, database: String?, etag: String?) -> URLRequest {
        var request = Self.request("ui/mobile", hub: hub, key: key,
                                   query: database.map { [URLQueryItem(name: "db", value: $0)] } ?? [])
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// `GET /ui/mobile`. `etag` is the tag of the last body; nil comes back when the hub answers 304, which means
    /// that the fleet did not change and the phone keeps what it has. The body comes back too, as the hub sent it, so
    /// that the phone can keep it for its next launch.
    func snapshot(at hub: URL, key: String?, database: String?, etag: String?)
        async throws -> (snapshot: MobileSnapshot, etag: String?, body: Data)? {
        let request = Self.snapshotRequest(hub: hub, key: key, database: database, etag: etag)
        let data: Data, response: URLResponse
        do { (data, response) = try await self.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw error is URLError ? MobileError.noAnswer : error }
        guard let response = response as? HTTPURLResponse else { throw MobileError.invalidResponse }
        guard try Self.check(response, data: data) else { return nil }
        return (try MobileSnapshot.decode(data), response.value(forHTTPHeaderField: "ETag"), data)
    }

    /// `GET /ui/mobile/chat/<agent>`. Without `since` it gives the last page; with it, the page after that cursor.
    func chat(at hub: URL, key: String?, database: String, agent: String, since: Double?) async throws -> MobileChatPage {
        guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw MobileError.invalidResponse
        }
        var query = [URLQueryItem(name: "db", value: database)]
        if let since { query.append(URLQueryItem(name: "since", value: String(since))) }
        let (data, _) = try await perform(Self.request("ui/mobile/chat/\(agent)", hub: hub, key: key, query: query))
        guard data.count <= 1_000_000 else { throw MobileError.invalidResponse }
        let page = try JSONDecoder().decode(MobileChatPage.self, from: data)
        guard page.db == database, page.agent == agent else { throw MobileError.invalidResponse }
        return page
    }

    /// `GET /ui/mobile/task/<id>`: the task itself and its notes after `since`.
    func task(at hub: URL, key: String?, database: String, id: Int, since: Int) async throws -> MobileTaskPage {
        guard id > 0, since >= 0 else { throw MobileError.invalidResponse }
        let query = [URLQueryItem(name: "db", value: database), URLQueryItem(name: "since", value: String(since))]
        let (data, _) = try await perform(Self.request("ui/mobile/task/\(id)", hub: hub, key: key, query: query))
        guard data.count <= 2_000_000 else { throw MobileError.invalidResponse }
        let page = try JSONDecoder().decode(MobileTaskPage.self, from: data)
        guard page.db == database, page.task.id == id else { throw MobileError.invalidResponse }
        return page
    }

    /// `GET /ui/owner/devices`: the owner's devices, so that Settings can name this one.
    func devices(at hub: URL, key: String?, database: String) async throws -> MobileDeviceList {
        let (data, _) = try await perform(Self.request("ui/owner/devices", hub: hub, key: key,
                                                       query: [URLQueryItem(name: "db", value: database)]))
        guard data.count <= 262_144 else { throw MobileError.invalidResponse }
        return try JSONDecoder().decode(MobileDeviceList.self, from: data)
    }

    /// `POST /ui/owner/devices/<device>/push` (owner feature push): the token that Apple gave this phone for pings,
    /// and the phone's own seal key when the hub seals what a ping says (`sealed_push`). It is an owner command with a
    /// new number each time; the hub keeps the last token of each device, and its key with it.
    func givePushToken(_ token: String, environment: String, seal: Data?, device: String, hub: URL, key: String?,
                       database: String, label: String) async throws {
        guard device.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil,
              token.range(of: "^[0-9a-f]{64,200}$", options: .regularExpression) != nil
        else { throw MobileError.invalidResponse }
        var request = Self.request("ui/owner/devices/\(device)/push", hub: hub, key: key, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(label, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try Self.pushTokenBody(token, environment: environment, seal: seal, database: database)
        _ = try await perform(request)
    }

    /// What the push route takes: a new request number, the generation, the token, its environment and, when given,
    /// the seal key in base64.
    static func pushTokenBody(_ token: String, environment: String, seal: Data?, database: String) throws -> Data {
        var body = ["request_id": UUID().uuidString.lowercased(), "db": database, "token": token,
                    "environment": environment]
        if let seal { body["seal"] = seal.base64EncodedString() }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// `GET /ui/owner/devices/<device>/recovery` (owner feature `recovery_copy`): the box that waits for this phone, or nil.
    func recoveryBox(device: String, hub: URL, key: String?, database: String) async throws -> String? {
        guard device.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil else {
            throw MobileError.invalidResponse
        }
        let (data, _) = try await perform(Self.request("ui/owner/devices/\(device)/recovery", hub: hub, key: key,
                                                       query: [URLQueryItem(name: "db", value: database)]))
        struct Box: Decodable { let device: String; let sealed: String? }
        guard data.count <= 16_384, let box = try? JSONDecoder().decode(Box.self, from: data), box.device == device else {
            throw MobileError.invalidResponse
        }
        return box.sealed
    }

    /// `POST /ui/owner/devices/<device>/recovery/held`: this phone opened its copy and keeps it, so the hub deletes the
    /// box and keeps only the time.
    func recoveryHeld(device: String, hub: URL, key: String?, database: String, label: String) async throws {
        guard device.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil else {
            throw MobileError.invalidResponse
        }
        var request = Self.request("ui/owner/devices/\(device)/recovery/held", hub: hub, key: key, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(label, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString.lowercased(), "db": database], options: [.sortedKeys])
        _ = try await perform(request)
    }

    // MARK: Enrollment

    /// The eight characters of a code, from what the owner typed. The alphabet leaves out the letters and digits that
    /// look alike, so a code never holds I, O, 0 or 1. nil when it is not a code.
    static let codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    static func normalizedCode(_ typed: String) -> String? {
        let code = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard code.count == 8, code.allSatisfy({ codeAlphabet.contains($0) }) else { return nil }
        return code
    }

    /// `POST /ui/owner/enroll`, from this phone's own address and before it has a key, so it carries no bearer token
    /// and no request number. The hub gives the key once and never again.
    /// `signing` (owner feature `door_calls`): this phone's own signing key and its binding to the QR's one-time value.
    /// `recovery` (owner feature `recovery_copy`, UI-API 1.95): this phone's own recovery key and its binding to the same
    /// one-time value, which the Mac seals the recovery code to.
    func enroll(at hub: URL, code: String, signing: (key: String, binding: String)? = nil,
                recovery: (key: String, binding: String)? = nil) async throws -> MobileEnrollment {
        guard let code = Self.normalizedCode(code) else { throw MobileError.invalidResponse }
        var request = Self.request("ui/owner/enroll", hub: hub, key: nil, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["code": code]
        if let signing { body["signing_key"] = signing.key; body["binding"] = signing.binding }
        if let signing, let recovery, recovery.key != signing.key {
            body["recovery_key"] = recovery.key; body["recovery_binding"] = recovery.binding
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, _) = try await perform(request)
        let enrollment = try JSONDecoder().decode(MobileEnrollment.self, from: data)
        guard !enrollment.key.isEmpty, !enrollment.device.isEmpty else { throw MobileError.invalidResponse }
        return enrollment
    }

    // MARK: The writes

    /// `POST /ui/attachments`: one file, before the message that carries it. Its own number makes it idempotent, so
    /// a send that is repeated is one file on the hub and never a second one. The answer must describe the bytes that
    /// went, or the phone does not take it.
    func upload(_ data: Data, name: String, mime: String, requestID: UUID, client: String, hub: URL, key: String?,
                database: String) async throws -> MessageAttachment {
        guard MessageAttachment.types[mime] != nil else { throw AttachmentError.type }
        guard !data.isEmpty, data.count <= MessageAttachment.sizeLimit else { throw AttachmentError.tooLarge }
        var request = Self.request("ui/attachments", hub: hub, key: key,
                                   query: [URLQueryItem(name: "db", value: database)], method: "POST")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.setValue(requestID.uuidString.lowercased(), forHTTPHeaderField: "X-Fleet-Request-Id")
        request.setValue(MessageAttachment.safeName(name, mime: mime), forHTTPHeaderField: "X-Fleet-Name")
        request.httpBody = data
        let (answer, _) = try await perform(request)
        let file = try JSONDecoder().decode(MessageAttachment.self, from: answer)
        try file.validate()
        guard file.mime == mime, file.matches(data) else { throw AttachmentError.bytes }
        return file
    }

    /// `GET /ui/attachments/<id>`: the bytes of one file, with their count and their SHA-256 checked before anything
    /// is shown.
    func attachment(_ file: MessageAttachment, hub: URL, key: String?, database: String) async throws -> Data {
        try file.validate()
        let (data, _) = try await perform(Self.request("ui/attachments/\(file.id)", hub: hub, key: key,
                                                       query: [URLQueryItem(name: "db", value: database)]))
        guard file.matches(data) else { throw AttachmentError.bytes }
        return data
    }

    /// One owner write, with the request's own number, its generation and this phone's client label, as the Mac app
    /// sends them. The receipt must name the same request, or the phone does not take it as confirmed.
    func send(_ pending: PendingRequest, key: String?) async throws -> SendReceipt {
        var request = Self.request(pending.route, hub: pending.hub, key: key, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(pending.client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try pending.body()
        let (data, _) = try await perform(request)
        let receipt = try JSONDecoder().decode(SendReceipt.self, from: data)
        guard receipt.matches(pending) else { throw MobileError.invalidResponse }
        return receipt
    }
}

/// The hub is one address inside the tailnet. A redirect would take the phone somewhere else, so there are none.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
