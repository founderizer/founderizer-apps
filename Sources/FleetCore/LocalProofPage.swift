#if os(macOS)
import Foundation
import Network

/// One page on this Mac's loopback, for the sitting's real browser task (the owner's test of 31 October 2026).
///
/// The extension's link is account-wide, and Claude Code outside the desktop app cannot tell where a lone browser
/// stands: a Chrome on another Mac with the same account answered this Mac's task, and the sitting went on. Only a
/// Chrome on this Mac can reach this address, so the page's script is the proof, whatever the task's words say.
public final class LocalProofPage: @unchecked Sendable {
    private static let page = "<!doctype html><html><head><meta charset='utf-8'><title>Mac setup</title></head>"
        + "<body style='font:16px sans-serif;margin:40px'><h1 id='w'>Wait</h1><script>"
        + "fetch(location.pathname,{method:'POST'}).then(r=>{document.getElementById('w').textContent=r.ok?'Done':'Try again'})"
        + "</script></body></html>"

    private let token: String
    private let queue = DispatchQueue(label: "founderizer.installer.proof")
    private let lock = NSLock()
    private var listener: NWListener?
    private var opened = false

    public init(token: String = UUID().uuidString.lowercased()) { self.token = token }

    /// Starts listening on the loopback alone, and answers the page's address.
    public func start() throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.take(connection) }
        listener.start(queue: queue)
        lock.lock(); self.listener = listener; lock.unlock()
        for _ in 0..<150 where (listener.port?.rawValue ?? 0) == 0 { usleep(20_000) }
        guard let port = listener.port?.rawValue, port != 0, let address = URL(string: "http://127.0.0.1:\(port)/\(token)") else {
            stop()
            throw URLError(.cannotConnectToHost)
        }
        return address
    }

    public func stop() {
        lock.lock(); let listener = self.listener; self.listener = nil; lock.unlock()
        listener?.cancel()
    }

    /// The page's script ran: a browser on this Mac opened it.
    public var seen: Bool {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    private func take(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, bytes: Data())
    }

    private func read(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] piece, _, done, error in
            guard let self, error == nil else { return connection.cancel() }
            let all = bytes + (piece ?? Data())
            if all.count > 65_536 { return connection.cancel() }
            if all.range(of: Data("\r\n\r\n".utf8)) != nil { return self.answer(connection, head: all) }
            if done { return connection.cancel() }
            self.read(connection, bytes: all)
        }
    }

    private func answer(_ connection: NWConnection, head: Data) {
        let parts = String(decoding: head.prefix(512), as: UTF8.self).split(separator: "\r\n").first?.split(separator: " ") ?? []
        let right = parts.count >= 2 && parts[1] == "/\(token)"
        if right, parts[0] == "POST" { lock.lock(); opened = true; lock.unlock() }
        let page = right && parts[0] == "GET", status = right ? "200 OK" : "404 No"
        let body = Data((page ? LocalProofPage.page : right ? "{}" : "No such page.\n").utf8)
        let kind = page ? "text/html; charset=utf-8" : "text/plain; charset=utf-8"
        let reply = "HTTP/1.1 \(status)\r\nContent-Type: \(kind)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(reply.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
