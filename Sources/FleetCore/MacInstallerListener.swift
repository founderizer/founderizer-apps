#if os(macOS)
import Foundation
import Network

/// The installer's half of the link, on the always-on Mac (PRODUCT.md P3).
///
/// The installer shows a link code and waits. The owner's own app sends the order — the hub's address, the one-time
/// join line, and the Tailscale key when that Mac needs one — and this listener gives it to the work that runs the
/// join. Two routes and nothing else:
///
///   - `POST /install` with the order. It must be sealed with the code on the screen (`MacLinkSeal`); three bad seals
///     and this listener stops, so a code cannot be guessed. An order is taken once.
///   - `POST /state` for where the install stands, until it ends.
///
/// It is HTTP on the local network, because this Mac is not on the fleet's private network until the install puts it
/// there, and every body is sealed. The code is the whole authorization, it is shown on this Mac's own screen, and the
/// listener holds nothing else: no credential of the owner's is kept here, and the Tailscale key goes to the join and
/// no further.
public final class MacInstallerListener: @unchecked Sendable {
    /// What runs the join, once an order with the right code arrives.
    public typealias Work = @Sendable (MacInstallOrder) -> Void
    /// Wrong codes from anywhere before the listener stops answering, as a join code on the hub has.
    public static let tries = 3

    private let code: String
    private let work: Work
    private let queue = DispatchQueue(label: "founderizer.installer.link")
    private let lock = NSLock()
    private var listener: NWListener?
    private var current: MacInstallState
    private var wrong = 0
    private var taken = false

    public init(code: String, state: MacInstallState, work: @escaping Work) {
        self.code = ClaimCode.read(code) ?? code
        self.current = state
        self.work = work
    }

    /// Starts listening, and answers the port it listens on.
    public func start(port: UInt16 = UInt16(MacInstallerClient.port)) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any))
        listener.newConnectionHandler = { [weak self] connection in self?.take(connection) }
        listener.start(queue: queue)
        lock.lock(); self.listener = listener; lock.unlock()
        // The port is known once the listener is ready, which is what the owner reads off this Mac's screen.
        for _ in 0..<150 where (listener.port?.rawValue ?? 0) == 0 { usleep(20_000) }
        return listener.port?.rawValue ?? port
    }

    public func stop() {
        lock.lock(); let listener = self.listener; self.listener = nil; lock.unlock()
        listener?.cancel()
    }

    public var state: MacInstallState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// An order that stopped before any work: the owner's app may send the next one.
    public func takeAgain(_ state: MacInstallState) {
        lock.lock(); taken = false; current = state; lock.unlock()
    }

    /// The root step starts, also from a Try again at this Mac: the link says so, and the app sends no other order.
    public func workAgain(_ state: MacInstallState) {
        lock.lock(); taken = true; current = state; lock.unlock()
    }

    /// What the next read of `/state` answers. The installer calls it at each step of its own work.
    public func update(_ state: MacInstallState) {
        lock.lock(); current = state; lock.unlock()
    }

    // MARK: One connection, one request

    private func take(_ connection: NWConnection) {
        let request = Request()
        connection.start(queue: queue)
        read(connection, request)
    }

    private func read(_ connection: NWConnection, _ request: Request) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] piece, _, done, error in
            guard let self else { return connection.cancel() }
            if let piece { request.bytes.append(piece) }
            if request.bytes.count > 262_144 || error != nil {
                return self.answer(connection, status: 413, state: MacInstallState(state: self.state.state,
                                                                                   says: "That request is too large."))
            }
            if let whole = request.whole() {
                return self.serve(connection, whole)
            }
            if done { return connection.cancel() }
            self.read(connection, request)
        }
    }

    private func serve(_ connection: NWConnection, _ request: Whole) {
        // The owner's own app reads on whatever a stranger on this network sent: wrong seals stop orders, and no read.
        if request.method == "POST", request.path == "/state", MacLinkSeal.open(request.body, code: code) != nil {
            return answer(connection, status: 200, state: state)
        }
        lock.lock()
        let stopped = listener == nil || wrong >= MacInstallerListener.tries
        lock.unlock()
        if stopped {
            return answer(connection, status: 403, state: MacInstallState(state: state.state,
                                                                          says: "This installer stopped taking orders. Start it again on that Mac."))
        }
        switch (request.method, request.path) {
        case ("POST", "/state"):
            refuse(connection)
        case ("POST", "/install"):
            guard let opened = MacLinkSeal.open(request.body, code: code),
                  let order = try? JSONDecoder().decode(MacInstallOrder.self, from: opened),
                  order.isValid, ClaimCode.read(order.code) == code else { return refuse(connection) }
            lock.lock()
            let already = taken
            if !already { taken = true }
            lock.unlock()
            if already {
                return answer(connection, status: 409, state: MacInstallState(state: state.state,
                                                                              says: "That Mac is working on an order."))
            }
            update(MacInstallState(state: "running", says: "Setting up this Mac", steps: state.steps, missing: state.missing))
            answer(connection, status: 200, state: state)
            work(order)
        default:
            answer(connection, status: 404, state: MacInstallState(state: state.state, says: "This installer serves only its own link."))
        }
    }

    private func refuse(_ connection: NWConnection) {
        lock.lock()
        wrong += 1
        let left = MacInstallerListener.tries - wrong
        lock.unlock()
        answer(connection, status: 403, state: MacInstallState(state: state.state,
                                                               says: left > 0 ? "That is not the link code this Mac shows."
                                                               : "Too many wrong link codes. Start the installer again on that Mac."))
    }

    /// A 200 goes sealed, because only the holder of the code gets one. A refusal says only why, in the clear: the
    /// caller may not hold the code at all.
    private func answer(_ connection: NWConnection, status: Int, state: MacInstallState) {
        let plain = (try? JSONEncoder().encode(state)) ?? Data("{}".utf8)
        let body = status == 200 ? ((try? MacLinkSeal.seal(plain, code: code)) ?? Data()) : plain
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "No")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The bytes of one request, until its head and its whole body are in.
    private final class Request: @unchecked Sendable {
        var bytes = Data()

        func whole() -> Whole? {
            guard let split = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: bytes[..<split.lowerBound], as: UTF8.self)
            let lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
            guard let first = lines.first else { return nil }
            let parts = first.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            var length = 0
            for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
                length = max(0, Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0)
            }
            let body = bytes[split.upperBound...]
            guard body.count >= length else { return nil }
            let path = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            return Whole(method: String(parts[0]), path: path, body: Data(body.prefix(length)))
        }
    }

    private struct Whole {
        let method: String
        let path: String
        let body: Data
    }
}
#endif
