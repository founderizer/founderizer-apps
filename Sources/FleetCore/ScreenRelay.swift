import Darwin
import Foundation

/// **The relay that checks the real line** of an agent's screen on a Linux server (the owner's "Check the real line" of
/// 20 November 2026, after two reviewers found that a check on a connection of its own proves nothing about Screen
/// Sharing's: a program can greet the two connections in two ways). Screen Sharing connects to the relay's port on this
/// Mac's loopback, and for each of its connections the relay connects to the tunnel's own port, reads the 12 bytes of
/// the screen's greeting there, and passes the connection on only when they are x11vnc's
/// (`ScreenSharingConnection.greeting`). Another greeting closes that connection before Screen Sharing reads a byte,
/// and the relay keeps the fact (`refused`), so that the next press says it in the owner's words. It keeps no byte but
/// the 12 of each greeting, and those only until they are passed on.
public final class ScreenRelay: @unchecked Sendable {
    /// The port on 127.0.0.1 that Screen Sharing opens.
    public let port: Int
    private let inner: Int
    private let request: ScreenSharingConnection
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var sockets: Set<Int32> = []
    private var refusedGreeting = false
    private var stopped = false

    /// Listens on a free port of 127.0.0.1 for the tunnel's port `inner`, or nil when no port could be opened.
    public init?(inner: Int, request: ScreenSharingConnection) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = ScreenRelay.loopback(port: 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, size) == 0 && listen(fd, 8) == 0 && getsockname(fd, pointer, &size) == 0
            }
        }
        guard bound, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); return nil }
        port = Int(UInt16(bigEndian: address.sin_port))
        self.inner = inner
        self.request = request
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "fleet.screen-relay"))
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    /// Whether a connection of Screen Sharing met a greeting that is not x11vnc's since the relay began.
    public var refused: Bool { lock.withLock { refusedGreeting } }

    /// Stops listening and ends every connection that it passes on.
    public func close() {
        lock.withLock {                         // under the lock: `finish` takes a socket out before it closes it
            stopped = true
            for fd in sockets { shutdown(fd, SHUT_RDWR) }
        }
        source.cancel()
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        value.sin_addr.s_addr = inet_addr("127.0.0.1")
        return value
    }

    /// Keeps `fd` among the open connections, or says no once the relay stopped.
    private func track(_ fd: Int32) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            sockets.insert(fd)
            return true
        }
    }

    private func acceptAll(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            guard track(client) else { Darwin.close(client); return }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    /// One connection of Screen Sharing: the greeting of the tunnel's port first, and the connection passed on only for
    /// x11vnc's.
    private func serve(_ client: Int32) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        let server = socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { finish(client, nil); return }
        guard track(server) else { Darwin.close(server); finish(client, nil); return }
        setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var address = ScreenRelay.loopback(port: UInt16(inner))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var banner = [UInt8](repeating: 0, count: 12)
        let count = connected == 0 ? recv(server, &banner, banner.count, MSG_WAITALL) : -1
        let greeting = request.greeting(Array(banner.prefix(max(count, 0))))
        guard greeting == .expected, banner.withUnsafeBytes({ send(client, $0) }) else {
            if greeting == .foreign { lock.withLock { refusedGreeting = true } }
            finish(client, server)
            return
        }
        var forever = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        let other = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            pump(server, client)
            shutdown(client, SHUT_RDWR); shutdown(server, SHUT_RDWR)
            other.signal()
        }
        pump(client, server)
        shutdown(client, SHUT_RDWR); shutdown(server, SHUT_RDWR)
        other.wait()
        finish(client, server)
    }

    /// Passes every byte from `from` to `to` until one side ends.
    private func pump(_ from: Int32, _ to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = recv(from, &buffer, buffer.count, 0)
            guard count > 0,
                  buffer.withUnsafeBytes({ send(to, UnsafeRawBufferPointer(rebasing: $0[0..<count])) }) else { return }
        }
    }

    private func send(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let sent = Darwin.send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }

    private func finish(_ client: Int32, _ server: Int32?) {
        lock.withLock {
            sockets.remove(client)
            if let server { sockets.remove(server) }
        }
        Darwin.close(client)
        if let server { Darwin.close(server) }
    }
}
