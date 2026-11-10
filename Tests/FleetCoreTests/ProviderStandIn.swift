import Foundation
import Security
@testable import FleetCore

/// A provider's API as this app talks to it (Tailscale, Hetzner, DigitalOcean): it records every request, and answers
/// each one with the answers given for its method and path, in turn, the last of them for every later request. A request
/// it was given no answer for gets a 404, and an answer of status `dropped` is a connection that fails on the way.
/// Synthetic data only: no network, no account, no real token.
final class ProviderStandIn: @unchecked Sendable {
    static let dropped = -1
    struct Call: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: String
        var path: String { url.path }
        var query: String { url.query ?? "" }
        var object: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] }
    }

    private let lock = NSLock()
    private var made: [Call] = []
    private var answers: [String: [(Int, String, [String: String])]] = [:]
    private var given: [String: Int] = [:]
    /// No connection at all: every request fails before it reaches anything.
    var offline = false

    /// One more answer for `method` and `path`.
    func answer(_ method: String, _ path: String, _ status: Int, _ body: String = "{}", headers: [String: String] = [:]) {
        lock.withLock { answers["\(method) \(path)", default: []].append((status, body, headers)) }
    }

    /// No answers for `method` and `path` any more, so the next ones given are the only ones.
    func clear(_ method: String, _ path: String) {
        lock.withLock { answers["\(method) \(path)"] = nil; given["\(method) \(path)"] = nil }
    }

    var calls: [Call] { lock.withLock { made } }
    func calls(_ method: String, _ path: String) -> [Call] { calls.filter { $0.method == method && $0.path == path } }
    func call(_ method: String, _ path: String) -> Call? { calls(method, path).last }

    var exchange: ProviderExchange {
        { [self] request in
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            let call = Call(method: method, url: url, headers: request.allHTTPHeaderFields ?? [:],
                            body: String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            let (status, body, headers) = try lock.withLock { () throws -> (Int, String, [String: String]) in
                made.append(call)
                if offline { throw URLError(.notConnectedToInternet) }
                let key = "\(method) \(url.path)"
                guard let queue = answers[key], !queue.isEmpty else { return (404, "{\"message\":\"no such thing\"}", [:]) }
                let index = min(given[key, default: 0], queue.count - 1)
                given[key] = index + 1
                if queue[index].0 == Self.dropped { throw URLError(.networkConnectionLost) }
                return queue[index]
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }
}

/// A credential kept in memory instead of this Mac's keychain, which a test never touches.
final class MemoryShelf: CredentialShelf, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    /// The keychain refuses, as it does for a copy of the app that is not signed with its Developer ID.
    var refuses = false

    init(_ data: Data? = nil) { self.data = data }

    var held: Data? { lock.withLock { data } }
    func read() -> Data? { lock.withLock { data } }
    func keep(_ data: Data) throws {
        try lock.withLock {
            if refuses { throw FleetKeychainItem.Failure(label: "test item", status: errSecInteractionNotAllowed) }
            self.data = data
        }
    }
}
