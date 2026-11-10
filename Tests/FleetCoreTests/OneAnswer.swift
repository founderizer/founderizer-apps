import Darwin
import Foundation

/// A stand-in for the hub on 127.0.0.1: it takes one HTTP request, keeps it, and sends the answer that `body` makes from
/// it. Synthetic data only.
final class OneAnswer: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var message = Data()
    }
    let port: Int
    private let box = Box()
    var received: Data { box.lock.withLock { box.message } }

    /// The body of an HTTP message.
    static func body(of message: Data) -> Data {
        message.range(of: Data("\r\n\r\n".utf8)).map { Data(message[$0.upperBound...]) } ?? Data()
    }

    init(status: String, body: @escaping @Sendable (Data) -> String) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 1) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        guard ready else { Darwin.close(listener); throw POSIXError(.EADDRINUSE) }
        port = Int(UInt16(bigEndian: address.sin_port))
        let box = box
        Thread.detachNewThread {
            let peer = accept(listener, nil, nil)
            Darwin.close(listener)
            guard peer >= 0 else { return }
            var timeout = timeval(tv_sec: 5, tv_usec: 0), yes: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            func complete() -> Bool {
                guard let head = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
                let fields = String(decoding: data[..<head.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let length = fields.compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                return data.count >= head.upperBound + length
            }
            while !complete() {
                let count = recv(peer, &buffer, buffer.count, 0)
                if count <= 0 { break }
                data.append(contentsOf: buffer[..<count])
            }
            box.lock.withLock { box.message = data }
            let text = body(data)
            let answer = Data((["HTTP/1.1 \(status)", "Content-Type: application/json", "Content-Length: \(text.utf8.count)",
                                "Connection: close", "", ""]).joined(separator: "\r\n").utf8) + Data(text.utf8)
            _ = answer.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
            Darwin.close(peer)
        }
    }
}
