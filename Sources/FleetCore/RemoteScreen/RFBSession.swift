import Foundation
import Network

/// The bytes of one connection to a screen: some bytes at each receive, all of them at each send.
public protocol RFBTransport: Sendable {
    /// The next bytes, at least one; an empty answer means the far side closed.
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close()
}

/// Why a take-over's screen did not open or stopped. The card says each in its own words.
public enum RFBError: Error, Equatable, Sendable {
    /// The far side is no screen of this protocol, or speaks a version that this client does not.
    case notAScreen
    /// The screen offers no sign-in that these credentials fit.
    case noSignIn
    /// The screen refused the sign-in (a wrong password); its own words, when it gave any.
    case signInRefused(String?)
    /// The screen refused the connection before any sign-in; its own words.
    case refused(String)
    /// The screen sent something that this client cannot read.
    case unreadable(String)
    /// The connection ended.
    case closed
}

/// What the screen said of itself after the sign-in.
public struct RFBScreen: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let name: String
}

/// **One take-over connection to an agent's screen, in the protocol of VNC and of a Mac's Screen Sharing** (RFC 6143;
/// the owner's "Yes, build it" of 21 November 2026 to `superbot-ideas/09-take-over-modal-design.md`). It goes only to the
/// local end of the SSH tunnel that Take over opens: the picture and his input never pass through the hub.
///
/// It asks every server for one pixel format (4 bytes, blue first) and for ZRLE, Hextile, CopyRect and Raw; it reads a
/// new screen size; it reads the server's clipboard and drops it, and it never sends his.
public actor RFBSession {
    private let transport: RFBTransport
    /// The bytes received and not read yet: `buffer[at...]`.
    private var buffer: [UInt8] = []
    private var at = 0
    private var framebuffer: RFBFramebuffer?
    private var minor = 8
    /// The card's two calls (`run`): the whole screen, and whether it wants one now.
    private var deliver: (@Sendable (RFBFrame) -> Void)?
    private var wanted: (@Sendable () -> Bool)?
    /// An update came while the card had not taken the screen before it: `catchUp` gives it.
    private var dirty = false
    /// An update is being read: its screen is half drawn, and goes to the card only at its end.
    private var updating = false
    /// `stop` came: the next read ends the session.
    private var stopped = false

    public init(transport: RFBTransport) {
        self.transport = transport
    }

    // MARK: handshake

    /// Version, sign-in and the screen's first facts. Throws `RFBError`.
    public func start(credentials: RFBCredentials) async throws -> RFBScreen {
        let greeting = try await read(12)
        guard let text = String(bytes: greeting, encoding: .ascii), text.hasPrefix("RFB 003."), text.hasSuffix("\n"),
              let serverMinor = Int(text.dropFirst(8).prefix(3)) else { throw RFBError.notAScreen }
        // 3.3, 3.7 and 3.8; a Mac's 3.889 and every newer one is answered as 3.8, as RFC 6143 lets a client do
        minor = serverMinor >= 8 ? 8 : serverMinor >= 7 ? 7 : serverMinor >= 3 ? 3 : 0
        guard minor >= 3 else { throw RFBError.notAScreen }
        try await send(Array("RFB 003.00\(minor)\n".utf8))
        let chosen: UInt8
        if minor == 3 {
            let type = try await u32()
            if type == 0 { throw RFBError.refused(try await reason()) }
            guard type <= 255, RFBSecurity.choose([UInt8(type)], for: credentials) != nil else { throw RFBError.noSignIn }
            chosen = UInt8(type)
        } else {
            let count = Int(try await read(1)[0])
            if count == 0 { throw RFBError.refused(try await reason()) }
            let offered = try await read(count)
            guard let pick = RFBSecurity.choose(offered, for: credentials) else { throw RFBError.noSignIn }
            chosen = pick
            try await send([pick])
        }
        try await signIn(chosen, credentials: credentials)
        try await send([1])                                         // ClientInit: share the screen
        let width = Int(try await u16()), height = Int(try await u16())
        guard RFBFramebuffer.fits(width: width, height: height) else { throw RFBError.unreadable("screen size") }
        _ = try await read(16)                                      // the server's pixel format: ours replaces it
        let nameLength = Int(try await u32())
        guard nameLength <= 1 << 16 else { throw RFBError.unreadable("name") }
        let name = String(decoding: try await read(nameLength), as: UTF8.self)
        framebuffer = RFBFramebuffer(width: width, height: height)
        try await send(Self.pixelFormat)
        let encodings: [Int32] = [RFBEncoding.zrle, RFBEncoding.hextile, RFBEncoding.copyRect, RFBEncoding.raw,
                                  RFBEncoding.desktopSize]
        var message: [UInt8] = [2, 0] + be16(encodings.count)
        for encoding in encodings { message += be32(UInt32(bitPattern: encoding)) }
        try await send(message)
        try await requestUpdate(incremental: false)
        return RFBScreen(width: width, height: height, name: name)
    }

    private func signIn(_ type: UInt8, credentials: RFBCredentials) async throws {
        switch (type, credentials) {
        case (RFBSecurity.none, _):
            if minor == 8 { try await result() }
        case (RFBSecurity.vnc, .password(let password)):
            let challenge = try await read(16)
            guard let response = RFBVNCSignIn.response(challenge: challenge, password: password) else {
                throw RFBError.unreadable("challenge")
            }
            try await send(response)
            try await result()
        case (RFBSecurity.apple, .account(let user, let password)):
            let generator = try await read(2)
            let size = Int(try await u16())
            guard (64...512).contains(size) else { throw RFBError.unreadable("key size") }
            let prime = try await read(size), serverKey = try await read(size)
            let offer = RFBAppleSignIn.Offer(generator: generator, prime: prime, serverKey: serverKey)
            // an offer that cannot carry the secret, or a name or password too long for its place: no refusal of the
            // screen's (that would drop the password that he gave), and nothing is sent
            guard let response = RFBAppleSignIn.response(to: offer, user: user, password: password) else {
                throw RFBError.unreadable("sign-in offer")
            }
            try await send(response)
            try await result()
        default:
            throw RFBError.noSignIn
        }
    }

    /// The server's SecurityResult: 0 is a sign-in; anything else a refusal, with its words from 3.8 on.
    private func result() async throws {
        guard try await u32() != 0 else { return }
        throw RFBError.signInRefused(minor == 8 ? try? await reason() : nil)
    }

    private func reason() async throws -> String {
        let length = Int(try await u32())
        guard length <= 1 << 16 else { throw RFBError.unreadable("reason") }
        return String(decoding: try await read(length), as: UTF8.self)
    }

    /// SetPixelFormat: 32 bits a pixel, depth 24, little-endian, true colour, red at 16, green at 8, blue at 0.
    static let pixelFormat: [UInt8] = [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]

    // MARK: the screen

    /// Reads the server's messages until the connection ends, and gives the whole screen after each update while
    /// `wanted` says yes; an update that comes while it says no is given by `catchUp`. A copy of a 5K screen is 59 MB,
    /// so no screen is copied that the card would not show. Throws `RFBError` (`closed` when the far side ends it).
    public func run(frames: @escaping @Sendable (RFBFrame) -> Void,
                    wanted: @escaping @Sendable () -> Bool = { true }) async throws {
        guard let framebuffer else { throw RFBError.closed }
        deliver = frames
        self.wanted = wanted
        while true {
            let type = try await read(1)[0]
            switch type {
            case 0:
                _ = try await read(1)
                let count = Int(try await u16())
                var resized = false
                // the rectangles of one update may cover the screen a few times, not thousands of times: each costs
                // work in proportion to its area
                var area = 0
                updating = true
                for _ in 0..<count {
                    resized = try await rectangle(into: framebuffer, area: &area) || resized
                    await Task.yield()                              // a stop can come between two rectangles
                    if stopped { throw RFBError.closed }
                }
                updating = false
                dirty = true
                offer()
                // a new size of the screen asks for all of it again: a server may send only what changed
                try await requestUpdate(incremental: !resized)
            case 1:                                                 // a colour map, which true colour does not use
                _ = try await read(3)
                let count = Int(try await u16())
                _ = try await read(count * 6)
            case 2:                                                 // the bell
                break
            case 3:                                                 // the server's clipboard: read, and dropped
                _ = try await read(3)
                let length = Int(try await u32())
                guard length <= 1 << 24 else { throw RFBError.unreadable("clipboard") }
                _ = try await read(length)
            default:
                throw RFBError.unreadable("message \(type)")
            }
        }
    }

    /// The whole screen to the card, if it wants one and an update came since the last.
    private func offer() {
        guard dirty, !updating, let deliver, let framebuffer, wanted?() ?? true else { return }
        dirty = false
        deliver(framebuffer.frame)
    }

    /// The card took the screen it had: the newest one, if an update came meanwhile.
    public func catchUp() { offer() }

    /// One rectangle of an update; true when it gave the screen a new size. `area` adds up the update's rectangles.
    private func rectangle(into framebuffer: RFBFramebuffer, area: inout Int) async throws -> Bool {
        let x = Int(try await u16()), y = Int(try await u16()), w = Int(try await u16()), h = Int(try await u16())
        let encoding = Int32(bitPattern: try await u32())
        // a new size is no work on pixels: only the rectangles that write pixels count
        if encoding != RFBEncoding.desktopSize {
            area += w * h
            guard area <= 8 * max(1, framebuffer.width * framebuffer.height) + 1 << 20 else {
                throw RFBError.unreadable("update area")
            }
        }
        do {
            switch encoding {
            case RFBEncoding.raw:
                guard framebuffer.contains(x: x, y: y, width: w, height: h) else { throw RFBDecodeError.outside }
                try framebuffer.raw(x: x, y: y, width: w, height: h, bytes: try await read(w * h * 4))
            case RFBEncoding.copyRect:
                let fromX = Int(try await u16()), fromY = Int(try await u16())
                try framebuffer.copy(x: x, y: y, width: w, height: h, fromX: fromX, fromY: fromY)
            case RFBEncoding.hextile:
                try await hextile(into: framebuffer, x: x, y: y, width: w, height: h)
            case RFBEncoding.zrle:
                guard framebuffer.contains(x: x, y: y, width: w, height: h) else { throw RFBDecodeError.outside }
                let length = Int(try await u32())
                guard length <= max(1 << 16, w * h * 4 + 1024) else { throw RFBError.unreadable("zrle length") }
                try framebuffer.zrle(x: x, y: y, width: w, height: h, compressed: try await read(length))
            case RFBEncoding.desktopSize:
                guard RFBFramebuffer.fits(width: w, height: h) else { throw RFBError.unreadable("screen size") }
                framebuffer.resize(width: w, height: h)
                return true
            default:
                throw RFBError.unreadable("encoding \(encoding)")
            }
        } catch let error as RFBDecodeError {
            throw RFBError.unreadable("\(error)")
        }
        return false
    }

    /// Hextile (RFC 6143 7.7.4): tiles of 16 by 16, each raw, or a background with subrectangles.
    private func hextile(into framebuffer: RFBFramebuffer, x: Int, y: Int, width w: Int, height h: Int) async throws {
        guard framebuffer.contains(x: x, y: y, width: w, height: h) else { throw RFBDecodeError.outside }
        var background: [UInt8] = [0, 0, 0, 0], foreground: [UInt8] = [0, 0, 0, 0]
        for tileY in stride(from: y, to: y + h, by: 16) {
            for tileX in stride(from: x, to: x + w, by: 16) {
                let tw = min(16, x + w - tileX), th = min(16, y + h - tileY)
                let mask = try await read(1)[0]
                if mask & 1 != 0 {
                    try framebuffer.raw(x: tileX, y: tileY, width: tw, height: th, bytes: try await read(tw * th * 4))
                    continue
                }
                if mask & 2 != 0 { background = try await read(4) }
                framebuffer.fill(x: tileX, y: tileY, width: tw, height: th, pixel: background)
                if mask & 4 != 0 { foreground = try await read(4) }
                guard mask & 8 != 0 else { continue }
                let count = Int(try await read(1)[0])
                let coloured = mask & 16 != 0
                for _ in 0..<count {
                    let pixel = coloured ? try await read(4) : foreground
                    let place = try await read(2)
                    let sx = Int(place[0] >> 4), sy = Int(place[0] & 15)
                    let sw = Int(place[1] >> 4) + 1, sh = Int(place[1] & 15) + 1
                    guard sx + sw <= tw, sy + sh <= th else { throw RFBDecodeError.badData("hextile subrectangle") }
                    framebuffer.fill(x: tileX + sx, y: tileY + sy, width: sw, height: sh, pixel: pixel)
                }
            }
        }
    }

    private func requestUpdate(incremental: Bool) async throws {
        guard let framebuffer else { return }
        try await send([3, incremental ? 1 : 0, 0, 0, 0, 0] + be16(framebuffer.width) + be16(framebuffer.height))
    }

    // MARK: his input

    /// A pointer event: the place on the agent's screen and the pressed buttons (1 left, 2 middle, 4 right, 8 and 16 a
    /// wheel's step up and down, 32 and 64 left and right). A place outside the screen goes to its nearest edge.
    public func pointer(x: Int, y: Int, buttons: UInt8) async {
        guard let framebuffer, framebuffer.width > 0, framebuffer.height > 0 else { return }
        let px = min(max(0, x), framebuffer.width - 1), py = min(max(0, y), framebuffer.height - 1)
        try? await send([5, buttons] + be16(px) + be16(py))
    }

    /// A key event of one keysym (`RFBKeys`).
    public func key(_ keysym: UInt32, down: Bool) async {
        guard framebuffer != nil else { return }
        try? await send([4, down ? 1 : 0, 0, 0] + be32(keysym))
    }

    public func stop() {
        stopped = true
        transport.close()
    }

    // MARK: bytes

    private func read(_ count: Int) async throws -> [UInt8] {
        if stopped { throw RFBError.closed }
        guard count > 0 else { return [] }
        while buffer.count - at < count {
            // the bytes already read go once they are many, so the buffer never grows with all that came
            if at > 1 << 16 { buffer.removeFirst(at); at = 0 }
            let more: Data
            do { more = try await transport.receive() } catch { throw RFBError.closed }
            guard !more.isEmpty else { throw RFBError.closed }
            buffer.append(contentsOf: more)
        }
        let out = Array(buffer[at..<(at + count)])
        at += count
        if at == buffer.count {
            // a large read's room goes back; a small one's stays for the next
            if buffer.capacity > 1 << 20 { buffer = [] } else { buffer.removeAll(keepingCapacity: true) }
            at = 0
        }
        return out
    }

    private func u16() async throws -> UInt16 {
        let bytes = try await read(2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func u32() async throws -> UInt32 {
        let bytes = try await read(4)
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func send(_ bytes: [UInt8]) async throws {
        do { try await transport.send(Data(bytes)) } catch { throw RFBError.closed }
    }

    private func be16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}

/// **The local end of the take-over's tunnel**, as a TCP connection to `127.0.0.1` and the port that the tunnel gave.
public final class RFBLocalConnection: RFBTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "founderizer.takeover.connection")

    private init(connection: NWConnection) { self.connection = connection }

    /// Connects, or throws `RFBError.closed` after `seconds` or at a refusal.
    public static func open(port: Int, seconds: Double = 10) async throws -> RFBLocalConnection {
        guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw RFBError.closed
        }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let local = RFBLocalConnection(connection: connection)
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume() }
                case .failed, .cancelled, .waiting:
                    if once.take() { connection.cancel(); continuation.resume(throwing: RFBError.closed) }
                default: break
                }
            }
            connection.start(queue: local.queue)
            local.queue.asyncAfter(deadline: .now() + seconds) {
                if once.take() { connection.cancel(); continuation.resume(throwing: RFBError.closed) }
            }
        }
        connection.stateUpdateHandler = nil
        return local
    }

    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, complete, error in
                if let error { continuation.resume(throwing: error); return }
                if let data, !data.isEmpty { continuation.resume(returning: data); return }
                continuation.resume(returning: complete ? Data() : Data())
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func close() { connection.cancel() }

    /// One resume of a continuation, from whichever handler comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}
