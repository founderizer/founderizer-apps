import Foundation
import Synchronization

/// **The sample fleet** (the owner's yes of 11 November 2026 to its three pictures): a made-up company's fleet that a
/// phone with no hub can look at. It is what a new owner sees before their fleet exists, and it is the demo that App
/// Review asks for (guideline 2.1), so that the app works on its own (4.2.3).
///
/// It is the hub's own words: `make_sample.py` reads them from the hub's code into `SampleFleetData`. The phone reads
/// them through its own client and its own pages, at an address that no network has, and this protocol answers there,
/// inside the app: nothing of the sample leaves the phone. **Every write gets the hub's refusal**, so the page that
/// wrote says "Not sent: This is a sample." where it says any refusal of a hub.
final class SampleHub: URLProtocol {
    /// Where the sample is. No network resolves a name under `.invalid` (RFC 6761), so only this protocol answers it.
    static let host = "sample.founderizer.invalid"
    static let address = URL(string: "http://\(host)/")!
    /// The hub's words for a write in the sample, which the phone shows as "Not sent: This is a sample."
    static let refusal = "this is a sample"
    /// The sample's generation, as `make_sample.py` names it.
    static let database = "sample"

    /// The sample's reads, with every time counted back from the moment it began.
    private static let reads = Mutex<Reads?>(nil)

    /// The sample begins: its times count back from `now`, so its newest message is minutes old.
    static func begin(at now: Date = Date()) {
        let made = Reads(now: now.timeIntervalSince1970)
        reads.withLock { $0 = made }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.lowercased() == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = Self.answer(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                             headerFields: answer.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// One answer of the sample, as a hub sends it.
    struct Answer: Sendable {
        let status: Int
        let body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    /// The sample's answer to one request: its compact read, a chat's page and a task's page, and the hub's refusal
    /// for every write. What the sample does not have (a device, a file, a wait) is not found.
    static func answer(_ request: URLRequest) -> Answer {
        guard (request.httpMethod ?? "GET") == "GET" else { return refused(409, refusal) }
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return refused(404, "not in the sample")
        }
        let sample = Self.reads.withLock { kept in
            if let kept { return kept }
            let made = Reads(now: Date().timeIntervalSince1970)
            kept = made
            return made
        }
        let since = parts.queryItems?.first { $0.name == "since" }?.value
        let path = parts.path.split(separator: "/").map(String.init)
        if path == ["ui", "mobile"] {
            // An unchanged fleet answers 304 with no body, as a hub does.
            if request.value(forHTTPHeaderField: "If-None-Match") == sample.tag {
                return Answer(status: 304, body: Data(), headers: ["ETag": sample.tag])
            }
            return Answer(status: 200, body: sample.mobile,
                          headers: ["Content-Type": "application/json", "ETag": sample.tag])
        }
        guard path.count == 4, path[0] == "ui", path[1] == "mobile" else { return refused(404, "not in the sample") }
        switch path[2] {
        case "chat":
            guard let page = sample.chats[path[3]] else { return refused(404, "not in the sample") }
            // The sample never changes: after the cursor of its page, a chat has nothing new.
            guard let since, let cursor = Double(since) else { return Answer(status: 200, body: page) }
            let empty: [String: Any] = ["db": database, "agent": path[3], "items": [Any](), "cursor": cursor]
            return Answer(status: 200, body: json(empty))
        case "task":
            guard let id = Int(path[3]), let page = sample.tasks[id] else { return refused(404, "not in the sample") }
            return Answer(status: 200, body: notes(of: page, after: since.flatMap { Int($0) } ?? 0))
        default:
            return refused(404, "not in the sample")
        }
    }

    /// A task's page with its notes after `since`, and the cursor of the last note.
    private static func notes(of page: Data, after since: Int) -> Data {
        guard since > 0, var fields = (try? JSONSerialization.jsonObject(with: page)) as? [String: Any],
              let notes = fields["notes"] as? [[String: Any]], let cursor = fields["cursor"] as? Int else { return page }
        fields["notes"] = notes.filter { ($0["id"] as? Int ?? 0) > since }
        fields["cursor"] = max(cursor, since)
        return json(fields)
    }

    private static func refused(_ status: Int, _ words: String) -> Answer {
        Answer(status: status, body: json(["error": words]))
    }

    private static func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The sample's reads, each as the bytes that a hub sends, with its times set from one moment.
    private struct Reads: Sendable {
        let mobile: Data
        let tag: String
        let chats: [String: Data]
        let tasks: [Int: Data]

        init(now: Double) {
            var all: [String: Any] = [:]
            if let parsed = try? JSONSerialization.jsonObject(with: Data(SampleFleetData.json.utf8)),
               let timed = SampleHub.timed(parsed, now: now) as? [String: Any] {
                all = timed
            }
            mobile = SampleHub.json(all["mobile"] ?? [String: Any]())
            tag = "\"sample-\(Int(now))\""
            chats = ((all["chats"] as? [String: Any]) ?? [:]).mapValues { SampleHub.json($0) }
            tasks = Dictionary(uniqueKeysWithValues: ((all["tasks"] as? [String: Any]) ?? [:]).compactMap { id, page in
                Int(id).map { ($0, SampleHub.json(page)) }
            })
        }
    }

    /// Every time of the sample, "@-480" or "@i-480" (a whole number), as seconds from `now`.
    static func timed(_ value: Any, now: Double) -> Any {
        switch value {
        case let words as String where words.hasPrefix("@i"):
            return Int(words.dropFirst(2)).map { Int(now) + $0 } ?? words
        case let words as String where words.hasPrefix("@"):
            return Double(words.dropFirst()).map { now + $0 } ?? words
        case let list as [Any]:
            return list.map { timed($0, now: now) }
        case let fields as [String: Any]:
            return fields.mapValues { timed($0, now: now) }
        default:
            return value
        }
    }
}
