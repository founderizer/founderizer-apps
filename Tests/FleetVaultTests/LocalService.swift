import Darwin
import Foundation

/// A service on this machine only (127.0.0.1) for the tests of `request`: a real listener that the system curl
/// reaches. It keeps every message that it gets, and it answers as its behaviour says. Synthetic data only.
final class LocalService: @unchecked Sendable {
    enum Behaviour: Sendable {
        /// Takes the whole request, then sends these bytes and closes.
        case answer(Data)
        /// Takes the whole request and never answers. The connection stays open until `stop`.
        case silent
        /// Takes the whole request and closes without an answer.
        case close
        /// Sends these bytes after the first bytes that come, which are not an HTTP request (a TLS hello), and closes.
        case early(Data)
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var messages: [Data] = []
        var kept: [Int32] = []
        var stopped = false
    }

    let port: Int
    private let state = State()

    init(_ behaviour: Behaviour) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 16) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        guard ready else { Darwin.close(listener); throw POSIXError(.EADDRINUSE) }
        port = Int(UInt16(bigEndian: address.sin_port))
        let state = state
        Thread.detachNewThread {
            // The listener is closed by the thread that waits on it.
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            while !state.lock.withLock({ state.stopped }) {
                guard poll(&waiting, 1, 50) > 0 else { continue }
                let peer = accept(listener, nil, nil)
                if peer >= 0 { DispatchQueue.global().async { Self.serve(peer, behaviour, state) } }
            }
            Darwin.close(listener)
        }
    }
    deinit { stop() }

    var origin: String { "http://127.0.0.1:\(port)" }
    /// Every message that came, complete or not, in the order of their ends.
    var received: [Data] { state.lock.withLock { state.messages } }

    /// True when `count` messages came in at most `seconds`.
    func waitForMessages(_ count: Int = 1, seconds: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while received.count < count { if Date() > end { return false }; usleep(10_000) }
        return true
    }

    func stop() {
        let kept = state.lock.withLock { () -> [Int32] in
            state.stopped = true
            defer { state.kept = [] }
            return state.kept
        }
        kept.forEach { Darwin.close($0) }
    }

    private static func serve(_ peer: Int32, _ behaviour: Behaviour, _ state: State) {
        var yes: Int32 = 1, timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))       // a client that ended gives an error, not a signal
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        func more() -> Bool {
            let count = recv(peer, &buffer, buffer.count, 0)
            if count > 0 { data.append(contentsOf: buffer[..<count]) }
            return count > 0
        }
        func answer(_ reply: Data) {
            reply.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let sent = send(peer, bytes.baseAddress! + offset, bytes.count - offset, 0)
                    if sent <= 0 { return }
                    offset += sent
                }
            }
        }
        if case .early(let reply) = behaviour {
            _ = more()
            state.lock.withLock { state.messages.append(data) }
            answer(reply); Darwin.close(peer)
            return
        }
        let end = Data("\r\n\r\n".utf8)
        while data.range(of: end) == nil { if !more() { break } }
        if let head = data.range(of: end) {
            let length = Self.parts(of: data).lines.compactMap { line -> Int? in
                let field = line.split(separator: ":", maxSplits: 1)
                guard field.count == 2, field[0].lowercased() == "content-length" else { return nil }
                return Int(field[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            while data.count < head.upperBound + length { if !more() { break } }
        }
        state.lock.withLock { state.messages.append(data) }
        switch behaviour {
        case .answer(let reply): answer(reply); Darwin.close(peer)
        case .silent:
            let late = state.lock.withLock { () -> Bool in
                if !state.stopped { state.kept.append(peer) }
                return state.stopped
            }
            if late { Darwin.close(peer) }
        case .close, .early: Darwin.close(peer)
        }
    }

    /// A complete HTTP/1.1 answer with its length.
    static func response(_ status: String = "200 OK", headers: [String] = [], body: Data = Data()) -> Data {
        Data((["HTTP/1.1 " + status, "Content-Length: \(body.count)", "Connection: close"] + headers + ["", ""]).joined(separator: "\r\n").utf8) + body
    }

    /// The request line and the header lines of a message, and its body.
    static func parts(of message: Data) -> (lines: [String], body: Data) {
        guard let head = message.range(of: Data("\r\n\r\n".utf8)) else { return ([], message) }
        return (String(decoding: message[..<head.lowerBound], as: UTF8.self).components(separatedBy: "\r\n"), Data(message[head.upperBound...]))
    }

    /// A port of this machine where nothing listens.
    static func closedPort() throws -> Int {
        let service = try LocalService(.close)
        service.stop()
        usleep(120_000)                                             // the listener's thread closes it at its next look
        return service.port
    }
}
