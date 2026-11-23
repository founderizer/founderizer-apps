import Darwin
import Foundation

/// **A stand-in hub on 127.0.0.1 for a view test that needs the hub's answer**: the app writes only within a moment of
/// one (`FleetStore.canWrite`). It answers `GET /ui/state` with the reading that it holds, a `GET` of a path that the
/// test gave an answer for (`give(_:at:)`) with that answer, and every other request with 404, and keeps each request's
/// method, path, body and time, so a test reads what the app sent and when. `stop` ends it. Synthetic data only.
final class LoopbackHub: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: String
        let at: Date
    }

    let port: Int
    private let lock = NSLock()
    private var kept: [Request] = []
    private var reading: Data
    private var answers: [String: Data] = [:]
    private let listener: Int32

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
                answer(peer)
            }
        }
    }

    /// The reading that the next `GET /ui/state` gives.
    func give(_ state: Data) { lock.withLock { reading = state } }

    /// What the next `GET` of this path (without its query) gives: a knowledge file's text, say.
    func give(_ answer: Data, at path: String) { lock.withLock { answers[path] = answer } }

    func stop() { Darwin.close(listener) }

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
        let line = String(decoding: data[..<head.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let words = line.split(separator: " ")
        let method = words.first.map(String.init) ?? "", target = words.dropFirst().first.map(String.init) ?? ""
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        let body = String(decoding: data[head.upperBound...], as: UTF8.self)
        let state: Data? = lock.withLock {
            kept.append(Request(method: method, path: path, body: body, at: Date()))
            return method != "GET" ? nil : path == "/ui/state" ? reading : answers[path]
        }
        let status = state == nil ? "404 Not Found" : "200 OK"
        let text = state ?? Data(#"{"error":"not here"}"#.utf8)
        let answer = Data(["HTTP/1.1 \(status)", "Content-Type: application/json", "Content-Length: \(text.count)",
                           "Connection: close", "", ""].joined(separator: "\r\n").utf8) + text
        _ = answer.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
    }
}
