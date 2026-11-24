import FleetCore
import Foundation

/// What the hub answered, in the owner's words. The phone has its own refusals, because an owner device has two locks
/// and each failure asks for a different step (UI-API.md, "The key of a device").
enum MobileError: LocalizedError, Sendable, Equatable {
    case invalidAddress
    case invalidResponse
    /// The hub refused, with what it said as one value (`HubRefusal`, as in the Mac app: its status, its English line,
    /// its code and the names inside it). `auth` is its reason when the refusal is about this device's key.
    case refusal(HubRefusal, auth: String?)
    /// The hub answers nothing at `GET /ui/mobile`: it is from before the phone's routes.
    case noPhoneRoutes
    case noAnswer

    var errorDescription: String? {
        switch self {
        case .invalidAddress: String(l10n: "Enter an HTTP or HTTPS hub address without a path or login.")
        case .invalidResponse: String(l10n: "The hub's answer does not match the phone's API.")
        // The hub's reason as a sentence, and no status code: "atlas is in setup" reads "The hub refused it: Atlas is
        // in setup." The code stays in the error for what the app decides from it.
        case .refusal(let refusal, let auth):
            auth.map(MobileError.authWords) ?? String(l10n: "The hub refused it: \(MobileError.sentence(of: refusal))")
        case .noPhoneRoutes: String(l10n: "This hub does not have the phone's routes yet. The Mac app still works with it.")
        // The Mac's words for the same failure, both sentences, so both apps say it one way (fix round 2, item 35).
        case .noAnswer: String(l10n: "Your hub did not answer. Check that its server is on.")
        }
    }

    /// **A write that the hub refused, in a few words that say what failed** (fix round 2, item 36): "Not sent: Atlas is
    /// in setup." It read "The hub refused it: Atlas is in setup.", eight words with no "not" in them. A refusal of
    /// this phone's key keeps its own words, which say what to do.
    var notSentWords: String {
        guard case .refusal(let refusal, nil) = self else { return localizedDescription }
        return Self.notSent(refusal)
    }

    /// "Not sent: Atlas is in setup.": a refusal of the hub in a few words, **made from its fields at the moment it
    /// is read** and so in the language of that day (`sentence(of:)`). A request that the hub refused keeps the
    /// refusal as fields, never these words (`PendingRequest.notSentLine`).
    static func notSent(_ refusal: HubRefusal) -> String {
        String(l10n: "Not sent: \(Self.sentence(of: refusal))")
    }

    /// **What the hub refused, as a sentence of this phone.** The words of the refusal are the app's own for a code
    /// that it knows, in the language of the device, and the hub's English for every other (`HubRefusal.words`).
    /// The hub's English is made a sentence here, as it always was: the first letter in upper case and a full stop
    /// at the end. The app's own words are a sentence already, and a name in them (a server, an agent) stays as the
    /// hub wrote it. A refusal that carried no words says it in the phone's own sentence, not the Mac's "Unexpected
    /// HTTP response.".
    static func sentence(of refusal: HubRefusal) -> String {
        guard let said = refusal.said else { return String(l10n: "The hub gave no reason.") }
        return refusal.words == refusal.hubWords ? sentence(said) : said
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
        guard case .refusal(let refusal, _) = self else { return false }
        return [400, 403, 404, 409, 413, 415, 422, 429, 503].contains(refusal.status)
    }

    /// The hub's `auth` value, when it named one.
    var auth: String? {
        guard case .refusal(_, let auth) = self else { return nil }
        return auth
    }

    /// What a refusal of the enrollment means and what the owner does next. The hub answers 403 for two different
    /// things here — the address is not one of its devices, or the code did not work — and they ask for different
    /// steps, so they never share a sentence. **Each is 12 words at most** (T-35): the one for a phone the hub does
    /// not know had 24, and the page's own line already says where the Mac makes a code.
    static func enrollWords(_ error: MobileError) -> String {
        switch error {
        case .refusal(let refusal, _) where refusal.status == 429:
            return tooManyCodes
        case .refusal(let refusal, _) where refusal.status == 403:
            // By the hub's code, and by the old English phrase for a hub that sends none (`HubRefusal.means`): the
            // words of a refusal are for the owner to read, and in Spanish they are not the hub's.
            return refusal.means(.notOwnerDevice)
                ? String(l10n: "Your hub does not know this phone. Add it on your Mac.")
                : codeDidNotWork
        case .noAnswer:
            // **A join that got no answer names Tailscale** (F7, piece A5): the hub answers only on the owner's private
            // network, and a phone with Tailscale off said to check a server that was on. The phone cannot tell
            // Tailscale off from a hub that does not answer: on the owner's iPhone with Tailscale off, its own
            // addresses (`getifaddrs`) still held one in Tailscale's ranges (his check of 23 November 2026). So one
            // line says both.
            return String(l10n: "Your hub did not answer. Check that Tailscale is on on this phone.")
        default:
            return error.localizedDescription
        }
    }

    /// The words of a code that did not work and of too many wrong codes, once in the device's language: `enrollWords`
    /// gives them and `refusedCode` knows a refused code by them, so the two agree in every language.
    static let codeDidNotWork = String(l10n: "This code did not work. Make a new one on your Mac.")
    static let tooManyCodes = String(l10n: "Too many wrong codes. Wait an hour, or make a new code.")

    /// The words of a code that the hub refused, which cannot go again.
    static func refusedCode(_ words: String?) -> Bool {
        words == codeDidNotWork || words?.hasPrefix(tooManyCodes) == true
    }

    /// What a refusal of this device means and what the owner does next. Each `auth` value is a different thing: not
    /// enrolled yet, no key sent, the wrong key, a route that the phone may not use, and a key where none is wanted.
    static func authWords(_ auth: String) -> String {
        switch auth {
        case "device_not_enrolled":
            String(l10n: "This phone is not enrolled. On your Mac press New code, then add this phone in Settings.")
        case "device_key_required":
            String(l10n: "The hub wants this phone's key and the phone sent none. Add this phone again with a new code.")
        case "device_key_mismatch":
            String(l10n: "This phone's key is not the one the hub keeps. Add this phone again with a new code.")
        case "device_not_allowed":
            String(l10n: "The phone may not use that part of the hub. That setup work stays in the Mac app.")
        case "key_not_expected":
            String(l10n: "This address is the owner's own Mac, which needs no key. Forget this phone's key in Settings.")
        default:
            String(l10n: "The hub refused this phone (\(auth)).")
        }
    }
}

extension PendingRequest {
    /// **The line under a request that did not go, as the phone says it**: "Not sent: Atlas is in setup." One helper
    /// for the three places that show it (Settings, a chat, Needs you). A request that the hub refused keeps the
    /// refusal as its fields (`refuse(_:)`: status, the hub's line, code and names), and this line is **made from them
    /// when it is read**, in the language of that day and with the app's own words for a code that it knows
    /// (`MobileError.notSent`), never kept as words. The stored text `refusal` shows only where there are no fields:
    /// a request that an older version of the phone refused, whose words were made when it was written, and a refusal
    /// of this phone's key, whose own words say what to do. nil for a request that no refusal stopped:
    /// `refusal != nil` stays the mark that a request waits for Discard or Try again.
    var notSentLine: String? {
        guard let stored = refusal else { return nil }
        return refusedByHub.map(MobileError.notSent) ?? stored
    }

    /// The hub's refusal, or the phone's own, stopped this request. **What the hub refused is kept as its fields**
    /// (`refuse(_:)`), and the words are made when the owner reads them (`notSentLine`). A refusal of this phone's key
    /// keeps the phone's own words, which say what to do, and so does an error of the phone's own that is no refusal:
    /// they are kept as text, as they always were.
    mutating func refuse(because error: MobileError) {
        if case .refusal(let hubRefused, nil) = error { refuse(hubRefused) } else { refusal = error.notSentWords }
    }

    /// The item that this request is his message under (Needs clarification, `OwnerCommand.needTalk`), or nil for every
    /// other request. It is the card's own request, as its answer is, and never an answer: the card stays open.
    var talkNeed: Int? {
        if case .needTalk(let need) = command { need } else { nil }
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
    /// a key adds no header here (a phone in the simulator gets the Mac's own key at the send, `data(for:)`).
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
    /// carries what the hub said (`HubRefusal.read`, the one decoder: its words, its code and its names) and, for a
    /// device, its `auth` reason, which that decoder does not read.
    static func check(_ response: HTTPURLResponse, data: Data) throws -> Bool {
        switch response.statusCode {
        case 200: return true
        case 304: return false
        default:
            let body = try? JSONDecoder().decode(RefusalBody.self, from: data)
            throw MobileError.refusal(HubRefusal.read(status: response.statusCode, body: data), auth: body?.auth)
        }
    }

    /// The one field of a refusal's body that `HubRefusal.read` leaves to the phone: why this device's key was refused.
    private struct RefusalBody: Decodable { let auth: String? }

    /// **Every request of the phone goes through here, and in the app that hosts the unit tests none leaves this Mac**
    /// (review B9i): whatever path asks — a read, a send, a link, a file, a press on a ping — a request to any other
    /// host is refused before it goes, because the built-in address is the owner's own hub. A stand-in on this Mac
    /// still answers a check, and so does the sample fleet, which this app answers itself.
    ///
    /// **A phone in the simulator is a program of the owner's Mac** (`OwnerMacKey.home`): it has no device key and the
    /// Mac's address, and the hub asks each call from that address for the Mac's key. So `hubData` adds that key to a
    /// request that carries none. On a real phone there is no such key, and the request goes as it is.
    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if Self.hostsTests, !Self.isLoopback(request.url), !answersHere(request.url) { throw OffThisMac() }
        return try await session.hubData(for: request)
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
    /// point on a phone: an unchanged fleet answers 304 with no body at all. **It says what this build draws**
    /// (`X-Fleet-Draws`, owner API 1.285): the hub takes such a thing on an item only while each app of the owner's said
    /// it, and a read of a device with no such header takes this phone's word back. So each read of the state says it,
    /// the share extension's and a ping's too, which make their read here. **Only with this phone's own key**: a phone
    /// with none (in the simulator) reads with the Mac's owner key (`hubData`), and the hub keeps a header that comes
    /// with that key as the word of the owner's computer, which draws its own cards and not this phone's.
    static func snapshotRequest(hub: URL, key: String?, database: String?, etag: String?) -> URLRequest {
        var request = Self.request("ui/mobile", hub: hub, key: key,
                                   query: database.map { [URLQueryItem(name: "db", value: $0)] } ?? [])
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let key, !key.isEmpty { request.setValue(draws.joined(separator: ","), forHTTPHeaderField: "X-Fleet-Draws") }
        return request
    }

    /// **What this build of the phone draws, by the hub's names** (`hub.APP_DRAWS`): pictures as the options of a
    /// request (`NeedPictures` in the app). A name goes in only with the build that draws it. Here, and not on the
    /// view, because the share extension compiles this file and none of the app's pages.
    static let draws = [pictureOptions]
    /// The hub's name for pictures as the options of a request: what this build draws, and the feature of a hub that
    /// gives them (`ui_features`).
    static let pictureOptions = "need_pictures"

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

    /// `GET /ui/mobile/ended` (hub 1.166): the head of every ended task. What he asked for in a chat stays in it when
    /// its work ends (`ChatAskRow`), and the main read holds only the last 20 that ended. With `chat` (hub 1.258,
    /// `ended_asks`): only the ended heads of what he asked for in that chat, in its messages from `from` on, so the
    /// answer grows with what the phone holds and not with the fleet's history.
    func ended(at hub: URL, key: String?, database: String, chat: String? = nil, from: Double = 0) async throws -> MobileEndedPage {
        var query = [URLQueryItem(name: "db", value: database)]
        if let chat { query += [URLQueryItem(name: "chat", value: chat), URLQueryItem(name: "from", value: String(from))] }
        let (data, _) = try await perform(Self.request("ui/mobile/ended", hub: hub, key: key, query: query))
        guard data.count <= 8_000_000 else { throw MobileError.invalidResponse }
        let page = try JSONDecoder().decode(MobileEndedPage.self, from: data)
        guard page.db == database else { throw MobileError.invalidResponse }
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
        // the store offers Word, Excel and PowerPoint only to a hub with `office_files` (MobileStore.stage)
        guard MessageAttachment.sendable(mime, office: true) else { throw AttachmentError.type }
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

    /// **His message under a card** (Needs clarification, owner feature `need_clarify`) and **a task's Pause from an
    /// answered card** (`MobileStore.pause(task:)`), the two owner commands of this phone: each goes as the Mac sends it,
    /// and its receipt is a command's, which names the item and carries its talk with his message in it, or names the
    /// task's hold (`ControlReceipt.matches`). An answer's receipt has an event and a time, which a command's has not:
    /// read as one, every message that the hub took would wait as "Not sent", and its Try again too.
    func command(_ pending: PendingRequest, key: String?) async throws -> ControlReceipt {
        switch pending.command {
        case .needTalk?, .control(_, .pause)?: break
        default: throw MobileError.invalidResponse
        }
        var request = Self.request(pending.route, hub: pending.hub, key: key, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(pending.client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try pending.body()
        let (data, _) = try await perform(request)
        let receipt = try JSONDecoder().decode(ControlReceipt.self, from: data)
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
