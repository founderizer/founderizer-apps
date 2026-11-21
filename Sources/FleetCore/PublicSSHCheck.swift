#if os(macOS)
import Foundation
import Network

/// **The public SSH check of each server** (the build spec of the app's SSH key, step 3; the design's section 6: "The
/// public SSH check comes now"). Once a day, in the round that puts each server's hardening right
/// (`ServerHardeningModel`), the server says over the round's own root SSH which public addresses it has, the ports
/// of its sshd (`sshd -T`) and its `permitrootlogin`; this Mac then connects to each such address and port and reads
/// the first line, and the round logs one line for the server: `open` where an SSH greeting came, `not reached from this
/// Mac` where this Mac has no route to the address, `closed` elsewhere.
///
/// **It reads and changes nothing**: no firewall rule, no file, no folder (an active firewall keeps the owner's own SSH
/// rule, `hubsetup.py firewall`), and nothing on a page. A private address (the private network's, a provider's private
/// network, loopback, link-local) is never checked: only an address on the public internet
/// (`InstallTarget.isPublicAddress`). What it reads is from this Mac's own network at that time: a port open only to
/// another network reads `closed` here, and a public address that the server's own interfaces do not hold (a
/// provider's NAT) is not seen.
public enum PublicSSHCheck {
    static let addressesMark = "founderizer-public-addresses:"
    static let portsMark = "founderizer-sshd-ports:"
    static let rootMark = "founderizer-root-login:"
    /// The most places that one check connects to.
    static let most = 8

    /// **The program, as root on the server**: its global addresses (`ip`), and the ports and the root rule that sshd
    /// itself reads (`sshd -T`), each on a line of its own after its mark. It reads only. Where `sshd -T` cannot answer
    /// (no `/run/sshd` while sshd waits on its socket), its two lines are empty.
    public static func program() -> String {
        #"PATH="$PATH:/usr/sbin:/sbin"; a=$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | tr '\n' ' '); "#
            + #"t=$(sshd -T 2>/dev/null); p=$(printf '%s\n' "$t" | awk '$1=="port"{print $2}' | tr '\n' ' '); "#
            + #"r=$(printf '%s\n' "$t" | awk '$1=="permitrootlogin"{print $2; exit}'); "#
            + #"printf '\#(addressesMark)%s\n' "$a"; printf '\#(portsMark)%s\n' "$p"; printf '\#(rootMark)%s\n' "$r""#
    }

    /// One address and port that this Mac connects to.
    public struct Place: Hashable, Sendable {
        public var address: String
        public var port: Int

        public init(address: String, port: Int) { self.address = address; self.port = port }

        /// `203.0.113.5:22`, `[2001:db8::1]:22`.
        public var words: String { (address.contains(":") ? "[\(address)]" : address) + ":\(port)" }
    }

    /// What the server said.
    public struct Reading: Equatable, Sendable {
        /// Its addresses on the public internet, each once, in its order: never a private one.
        public var addresses: [String]
        /// The ports that its sshd reads, each once; empty where `sshd -T` gave none.
        public var ports: [Int]
        /// Its `permitrootlogin` as `sshd -T` says it, or nil.
        public var rootLogin: String?

        /// The program's three lines out of the output, or nil when they are not there: the program did not run.
        public static func read(_ output: String) -> Reading? {
            let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            func after(_ mark: String) -> String? {
                lines.last { $0.hasPrefix(mark) }.map { String($0.dropFirst(mark.count)) }
            }
            guard let printed = after(addressesMark) else { return nil }
            var addresses: [String] = []
            for word in printed.split(separator: " ") {
                let address = String(word.split(separator: "/").first ?? word)
                if InstallTarget.isPublicAddress(address), !addresses.contains(address) { addresses.append(address) }
            }
            var ports: [Int] = []
            for word in (after(portsMark) ?? "").split(separator: " ") {
                if let port = Int(word), (1...65535).contains(port), !ports.contains(port) { ports.append(port) }
            }
            let root = after(rootMark)?.trimmingCharacters(in: .whitespaces)
            return Reading(addresses: addresses, ports: ports,
                           rootLogin: root.flatMap { $0.range(of: "^[a-z-]{1,32}$", options: .regularExpression) != nil ? $0 : nil })
        }

        /// The places that this Mac checks: each public address at each port of sshd, or at `fallback` (the round's own
        /// port) where `sshd -T` gave none; at most `most`.
        public func places(fallback: Int) -> [Place] {
            let ports = self.ports.isEmpty ? [fallback] : self.ports
            return Array(addresses.flatMap { address in ports.map { Place(address: address, port: $0) } }.prefix(most))
        }
    }

    /// What this Mac read at one place.
    public enum State: Equatable, Sendable {
        /// An SSH server answered with its greeting.
        case open
        /// A refused connection, nothing before the time was up, or no SSH greeting.
        case closed
        /// This Mac has no route to that address now: nothing was checked there.
        case unreached

        public var words: String {
            switch self {
            case .open: return "open"
            case .closed: return "closed"
            case .unreached: return "not reached from this Mac"
            }
        }
    }

    /// What one connection from this Mac came to (`greeting`).
    public enum Contact: Equatable, Sendable {
        /// The place sent this first line, or closed before a line came (nil).
        case answered(String?)
        /// The place refused the connection, or nothing came before the time was up.
        case closed
        /// No route from this Mac to that address now (an IPv6 address from a network with IPv4 only, or no network).
        case unreached
    }

    /// `open` only for an SSH greeting: a port that refused, that nothing answered, or where another program answered
    /// is `closed`.
    public static func state(greeting: String?) -> State {
        greeting?.hasPrefix("SSH-") == true ? .open : .closed
    }

    public static func state(_ contact: Contact) -> State {
        switch contact {
        case .answered(let line): return state(greeting: line)
        case .closed: return .closed
        case .unreached: return .unreached
        }
    }

    /// The errors of a connection that waits (`NWConnection.State.waiting`) or failed with no route from this Mac:
    /// those say nothing of the server's port. Any other (a refused connection, `ECONNREFUSED`) is `closed`.
    static let noRoute: Set<POSIXErrorCode> = [.ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN, .EADDRNOTAVAIL,
                                               .EAFNOSUPPORT]

    /// What a connection that waits or failed with `error` came to.
    public static func contact(waiting error: NWError) -> Contact {
        if case .posix(let code) = error, noRoute.contains(code) { return .unreached }
        return .closed
    }

    /// The one line that the round logs for a server. A server behind a provider's NAT has no public address on its own
    /// interfaces, and is not seen.
    public static func line(_ read: [(Place, State)], rootLogin: String?) -> String {
        let places = read.isEmpty ? "no public address on its interfaces"
            : read.map { "\($0.0.words) \($0.1.words)" }.joined(separator: ", ")
        return places + "; root login: " + (rootLogin ?? "not read")
    }

    // MARK: once a day

    /// How long after a check that read the server the next one is due: a day. After one that could not, an hour.
    public static let every: Double = 86_400
    public static let again: Double = 3_600

    /// Whether a check is due: none is kept, its time has come, or the time kept is more than a day ahead (a clock
    /// that went back).
    public static func due(next: Double?, now: Double) -> Bool {
        guard let next else { return true }
        return now >= next || next - now > every
    }

    /// When the next check is due after one that read the server, or one that could not.
    public static func next(read: Bool, now: Double) -> Double { now + (read ? every : again) }

    // MARK: one check

    /// What one check came to: its line, and whether it read the server.
    public struct Outcome: Equatable, Sendable {
        public var line: String
        public var read: Bool
    }

    /// **One check of one server**: the connection of the round (`connection`), the program as root over it (`run`),
    /// then each place (`greeting`, which only a test gives). A place that this Mac has no route to is said so in the
    /// line, and the check still read the server: a Mac with IPv4 only checks a server with IPv6 once a day, not each
    /// hour. A Mac with no network fails at the program's SSH run first, which is a check that did not read it.
    public static func check(connection: @Sendable () async throws -> InstallTarget,
                             run: @Sendable (InstallTarget, String) async throws -> String,
                             greeting: @Sendable (Place) async -> Contact = { await PublicSSHCheck.greeting($0) }) async
        -> Outcome {
        let target: InstallTarget
        do { target = try await connection() } catch { return Outcome(line: "not read: no connection", read: false) }
        let output: String
        do { output = try await run(target, program()) } catch {
            return Outcome(line: "not read: \(error.localizedDescription)", read: false)
        }
        guard let reading = Reading.read(output) else {
            let said = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "nothing"
            return Outcome(line: "not read: the server's answer was \(said.prefix(160))", read: false)
        }
        var read: [(Place, State)] = []
        for place in reading.places(fallback: target.port) {
            read.append((place, state(await greeting(place))))
        }
        return Outcome(line: line(read, rootLogin: reading.rootLogin), read: true)
    }

    /// **The first line that a place sends**, within `timeout` seconds of the start: a TCP connection from this Mac,
    /// nothing written, at most 256 bytes read, and the connection closed. A connection with no route from this Mac
    /// (`contact(waiting:)`, or a path that is not satisfied when the time is up) is `unreached`.
    public static func greeting(_ place: Place, timeout: Double = 5) async -> Contact {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: place.port)), place.port > 0 else { return .closed }
        let connection = NWConnection(host: NWEndpoint.Host(place.address), port: port, using: .tcp)
        let queue = DispatchQueue(label: "com.founderizer.public-ssh-check")
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 4, maximumLength: 256) { data, _, _, _ in
                        let first = data.map { String(decoding: $0, as: UTF8.self) }?
                            .split(whereSeparator: \.isNewline).first.map(String.init)
                        once.resume(.answered(first))
                        connection.cancel()
                    }
                case .failed(let error), .waiting(let error):     // refused, or no route now
                    once.resume(contact(waiting: error))
                    connection.cancel()
                case .cancelled:
                    once.resume(.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(connection.currentPath?.status == .unsatisfied ? .unreached : .closed)
                connection.cancel()
            }
        }
    }

    /// A continuation that takes its first value only.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Contact, Never>?

        init(_ continuation: CheckedContinuation<Contact, Never>) { self.continuation = continuation }

        func resume(_ value: Contact) {
            let taken: CheckedContinuation<Contact, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            taken?.resume(returning: value)
        }
    }
}
#endif
