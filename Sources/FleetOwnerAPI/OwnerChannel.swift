import Darwin
import Foundation
import Security

/// **The link between the program and the running app** (the plan's section 3.4): a local socket in the app's own folder
/// of the user's Library, which the app listens on while it runs. The program asks the app what only the app's own engine
/// knows or does (`setup_state`, `setup_show` in this version; the tools of later slices are more entries of the same
/// link, `SetupBoard`).
///
/// **The wire.** One request and one answer for each connection, each one line of JSON (`JSONValue.dumps`, which writes no
/// raw line end inside a value), with the link's version: the request `{"v": 1, "set": "owner", "tool": "setup_state",
/// "fields": {...}}`, the answer `{"v": 1, "result": {...}}` or `{"v": 1, "refused": "<words>"}`. The program says its set
/// in each request, and the app takes a tool only of that set. **A value is never in the line**: a tool that takes one
/// (a token) gets it as a value part, exactly `value_bytes` bytes after the line end, which the envelope names beside
/// `set` and `tool`. The version stays 1: an older app does not read `value_bytes`, answers that it has no such tool,
/// and counts and drops the bytes as bytes after a line.
///
/// **Each side checks the other by its code signature**, from the socket's peer: the peer's audit token
/// (`LOCAL_PEERTOKEN`), the Security framework's guest lookup by that token, then a requirement (`SignatureCheck`), never
/// a process id alone and never a path alone (not run with a Developer ID signed build yet). **What this check is worth,
/// said plainly:** it proves which program calls, not who wanted the call. Each process of the owner's user can start the
/// program and give it any request, so the safety of the link is in what its tools can do: none of them rents, pays or
/// presses, and the one that carries a secret (`save_bot_token`) sends it to the hub's route that any process of the
/// owner's user reaches already.
///
/// **The rule that the tools of later slices rest on.** A check of the peer's signature cannot prove which process writes
/// on a socket: a parent that shares a socket with a child that became our program writes on it as well. So no tool of
/// this link may ever give back anything that the program's own verbs would not give to any process of the owner's user.
public enum OwnerChannel {
    /// The app's bundle identifier, which the program's requirement of a release build names: the program's own
    /// knowledge, never read from a file on the disk (a test holds it to `app/Info.plist`).
    public static let appIdentifier = "com.founderizer.app"
    /// The program's identifier, which the app's requirement of a release build names (`release.sh` signs it so).
    public static let programIdentifier = "com.founderizer.cli"

    /// The version of the wire. A request or an answer of another version is refused in words.
    public static let version: Int64 = 1
    /// The longest request line that the app reads; a longer one is refused.
    public static let requestMax = 64 * 1024
    /// **The longest value part**: the bytes after a request line that its `value_bytes` names (a token, a key). A
    /// secret's value is never a field of a tool, so it comes as this part, from a file or a pipe that the program read.
    public static let valueMax = 64 * 1024
    /// The longest answer line that the program reads.
    public static let answerMax = 1024 * 1024
    /// The connections that the app keeps open at one time. One more ends the oldest.
    public static let openMax = 8
    /// The longest path of the socket, in bytes: a Mac's local socket takes 104 with its end byte, and the link stays
    /// under 100.
    public static let pathMax = 99

    /// **The socket's place**: the app's own folder of the user's Library (`~/Library/Application Support/Founderizer`,
    /// where the app keeps its other files), mode 700, and the socket in it with mode 600.
    public static func place(home: String) -> String {
        (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/Library/Application Support/Founderizer/app.sock"
    }

    /// The home folder of this process's user, from the user database and not from `HOME`, so that the app and the
    /// program agree on the place whatever their environment says.
    public static func userHome() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let home = String(cString: dir)
            if !home.isEmpty { return home }
        }
        return NSHomeDirectory()
    }

    /// The words when the place is too long for a local socket, or nil when it fits.
    public static func tooLong(_ path: String) -> String? {
        let count = path.utf8.count
        guard count > pathMax else { return nil }
        return "The link between founderizer-cli and the Founderizer app would be the file \(path), and that path is "
            + "\(count) bytes long: a local socket on a Mac takes at most \(pathMax). The link works for a user whose "
            + "home folder has a shorter name."
    }

    // ------------------------------------------------------------ the wire

    /// One request of the program. **It never holds a value**: at most the count of the value part that follows its
    /// line (`valueBytes`), in the envelope beside `set` and `tool`, never inside `fields`.
    public struct Request: Sendable, Equatable {
        public var set: String
        public var tool: String
        public var fields: [String: JSONValue]
        /// The bytes of the value part after the line, 1 to `valueMax`, or nil for none.
        public var valueBytes: Int?

        public init(set: String, tool: String, fields: [String: JSONValue] = [:], valueBytes: Int? = nil) {
            self.set = set
            self.tool = tool
            self.fields = fields
            self.valueBytes = valueBytes
        }

        /// The request as one line, with its line end.
        public var line: Data {
            var message: [String: JSONValue] = ["v": .int(OwnerChannel.version), "set": .string(set),
                                                "tool": .string(tool), "fields": .object(fields)]
            if let valueBytes { message["value_bytes"] = .int(Int64(valueBytes)) }
            return Data((JSONValue.object(message).dumps() + "\n").utf8)
        }

        /// The words for a `value_bytes` that is no whole number of 1 to `valueMax`: fixed, with nothing of the
        /// request in them.
        public static let badValueBytes = "The app could not read this request: value_bytes must be a whole number of "
            + "1 to \(OwnerChannel.valueMax), the bytes of the value part after the line."

        /// A line that the app read, with no line end: the request, or the words of its refusal.
        public static func read(_ line: Data) -> Result<Request, Refusal> {
            guard let message = JSONValue.parse(line)?.object else {
                return .failure(Refusal("The app could not read this request: it is not one line of a JSON object."))
            }
            guard message["v"] == .int(OwnerChannel.version) else {
                return .failure(Refusal("This request is of another version of the link than the app's "
                                        + "(\(OwnerChannel.version)): founderizer-cli and the Founderizer app are of "
                                        + "different versions. Start a new session after the app's update."))
            }
            guard case .string(let set)? = message["set"], case .string(let tool)? = message["tool"] else {
                return .failure(Refusal("The app could not read this request: it names no set or no tool."))
            }
            let fields = message["fields"] ?? .object([:])
            guard let map = fields.object else {
                return .failure(Refusal("The fields of \(tool) must be one JSON object."))
            }
            var count: Int?
            switch message["value_bytes"] {
            case nil: break
            case .int(let number)? where number >= 1 && number <= Int64(OwnerChannel.valueMax): count = Int(number)
            default: return .failure(Refusal(badValueBytes))
            }
            return .success(Request(set: set, tool: tool, fields: map, valueBytes: count))
        }
    }

    /// **A value part, as the app and the program hold it**: its own bytes, wiped when it goes (`memset_s`, which the
    /// compiler does not drop), given out only to a closure (`withBytes`) or as strict UTF-8 text (`text`), and printed
    /// as hidden in every way that Swift prints a value (`description`, `debugDescription`, a mirror with no
    /// children), as `BotToken` does in the app. It never goes into a `Request`. **Its limit, said plainly:** a `String`
    /// made from it (`text`) is a copy that Swift cannot wipe; the wipe covers this type's bytes and the link's own
    /// buffers only.
    public final class Value: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                              CustomReflectable {
        // Never changed after `init`, so one value can pass between the listener's queue and the main actor.
        private let bytes: UnsafeMutableRawBufferPointer

        /// A copy of these bytes. The caller wipes its own copy (`OwnerChannel.wipe`).
        public init<C: Collection>(copying source: C) where C.Element == UInt8 {
            bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: Swift.max(source.count, 1), alignment: 1)
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            UnsafeMutableRawBufferPointer(rebasing: bytes[0..<source.count]).copyBytes(from: source)
            count = source.count
        }

        deinit {
            if let base = bytes.baseAddress { memset_s(base, bytes.count, 0, bytes.count) }
            bytes.deallocate()
        }

        /// The number of bytes: for the wire's count, never for an answer.
        public let count: Int

        public func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
            try body(UnsafeRawBufferPointer(rebasing: bytes[0..<count]))
        }

        /// The bytes as text when they are strict UTF-8 (no overlong form, no surrogate, no cut sequence), else nil.
        public var text: String? {
            withBytes { raw in
                var bytes = raw.makeIterator()
                var decoder = UTF8()
                while true {
                    switch decoder.decode(&bytes) {
                    case .scalarValue: continue
                    case .emptyInput: return String(decoding: raw, as: UTF8.self)
                    case .error: return nil
                    }
                }
            }
        }

        public var description: String { "a value part (hidden)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
    }

    /// Writes zeros over bytes that held a value, in a way that the compiler keeps.
    public static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) }
        }
    }

    public static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) }
        }
    }

    /// Words that refuse a request.
    public struct Refusal: Error, Sendable, Equatable {
        public let text: String
        public init(_ text: String) { self.text = text }
    }

    /// One answer of the app.
    public enum Answer: Sendable, Equatable {
        case result(JSONValue)
        case refused(String)

        /// The answer as one line, with its line end.
        public var line: Data {
            let message: JSONValue
            switch self {
            case .result(let value): message = .object(["v": .int(OwnerChannel.version), "result": value])
            case .refused(let words): message = .object(["v": .int(OwnerChannel.version), "refused": .string(words)])
            }
            return Data((message.dumps() + "\n").utf8)
        }

        /// A line that the program read, with no line end, or nil when it is no answer of this version.
        public static func read(_ line: Data) -> Answer? {
            guard let message = JSONValue.parse(line)?.object, message["v"] == .int(OwnerChannel.version) else {
                return nil
            }
            if let value = message["result"], message["refused"] == nil { return .result(value) }
            if case .string(let words)? = message["refused"], message["result"] == nil { return .refused(words) }
            return nil
        }
    }

    /// The one line that a peer which fails the check gets, before anything of its request is read.
    public static let notOurs = Answer.refused(
        "The Founderizer app answers on this link only the founderizer-cli of its own build, checked by its code "
        + "signature. Use the program inside the app: ~/.founderizer/cli.")

    // ------------------------------------------------------------ small pieces of the socket

    /// A local socket's address for a path that fits (`tooLong` is nil).
    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes.prefix(raw.count - 1))
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A new local socket that a child process does not get and that never raises SIGPIPE.
    static func newSocket() -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return -1 }
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return socket
    }

    /// Connects a socket to a path: 0, or the `errno` of the failure.
    static func connect(_ socket: Int32, to path: String) -> Int32 {
        var address = address(path)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return status == 0 ? 0 : errno
    }

    /// The lock that a listening app holds beside its socket.
    public static func lockPath(_ path: String) -> String { path + ".lock" }

    /// **Waits until no copy of the app holds the link's lock**, with no clock: a shared lock that is taken and given
    /// back at once, so it ends when the listening copy ends or stops. It returns at once when the lock's file cannot
    /// be opened or nobody holds the lock. For a copy of the app that started while another one still listens
    /// (`ChannelListener.startWhenFree`).
    public static func waitForLock(_ path: String) {
        let file = open(lockPath(path), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return }
        defer { close(file) }
        while flock(file, LOCK_SH) != 0 {
            guard errno == EINTR else { return }
        }
        _ = flock(file, LOCK_UN)
    }

    /// **Whether a copy of the app holds the link's lock now**: read without making the file and without holding it.
    public static func lockHeld(_ path: String) -> Bool {
        let file = open(lockPath(path), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return false }
        defer { close(file) }
        guard flock(file, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        _ = flock(file, LOCK_UN)
        return false
    }

    /// **Whether a live listener answers at the path**: a connection is taken. It sends nothing and closes at once.
    public static func answers(_ path: String) -> Bool {
        guard tooLong(path) == nil else { return false }
        let socket = newSocket()
        guard socket >= 0 else { return false }
        defer { close(socket) }
        return connect(socket, to: path) == 0
    }
}

// ------------------------------------------------------------ the peer check

/// **How one side checks the other**, from the connected socket. The app's listener and the program each have one; a
/// test gives a stand-in.
public protocol PeerCheck: Sendable {
    func accepts(socket: Int32) -> Bool
}

/// A check that takes no peer: the answer when this process cannot check one (no signature to read).
public struct RefuseEveryPeer: PeerCheck {
    public init() {}
    public func accepts(socket: Int32) -> Bool { false }
}

/// **The check by code signature**: the peer's audit token from the socket (`LOCAL_PEERTOKEN`), the peer's code by the
/// Security framework's guest lookup with that token, and Apple's own check of that code against a requirement. A path
/// is compared besides, for a test build, and never alone. Not run with a Developer ID signed build yet.
public struct SignatureCheck: PeerCheck {
    /// The requirement that the peer's running code must meet.
    public let requirement: String
    /// For a test build: the real path that the peer's main executable must have, besides the requirement.
    public let path: String?

    public init(requirement: String, path: String?) {
        self.requirement = requirement
        self.path = path
    }

    /// A Developer ID application certificate from Apple, as `ProgramLink.swift` asks for it.
    public static let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    /// **The requirement of a release build** for a team and an identifier, or nil when either is empty or holds any
    /// character but ASCII letters and digits (and `.` and `-` in the identifier): then no check is made at all.
    public static func requirement(team: String, identifier: String) -> String? {
        guard !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), !identifier.isEmpty,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }) else {
            return nil
        }
        return developerID + " and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }

    /// **The check of the other side, from this process's own signature.**
    /// - A signature with a team that meets the Developer ID requirement (a release build): the other side must be
    ///   signed with a Developer ID of the same team, with `identifier` (`OwnerChannel.programIdentifier` for the
    ///   program, `OwnerChannel.appIdentifier` for the app).
    /// - A signature with a team that does not meet it: no check, so no peer is taken.
    /// - A signature with no team (ad hoc) or none at all (a test build): the other side must be the exact code at
    ///   `expected`, the program or the app's executable of this own bundle, by its code directory hash and by the real
    ///   path of its main executable; so a test build works with itself and with no other build.
    /// Nil when no check can be made: then no peer is taken.
    public static func of(identifier: String, expected: URL) -> SignatureCheck? {
        let own = ownSigning()
        if let team = own.team {
            guard own.developerID, let text = requirement(team: team, identifier: identifier) else { return nil }
            return SignatureCheck(requirement: text, path: nil)
        }
        guard let real = ProgramPlace.realPath(expected.path), let hash = codeDirectoryHash(of: real) else { return nil }
        return SignatureCheck(requirement: "cdhash H\"\(hash)\"", path: real)
    }

    public func accepts(socket: Int32) -> Bool {
        guard let code = Self.peerCode(socket) else { return false }
        var made: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &made) == errSecSuccess, let made,
              SecCodeCheckValidity(code, [], made) == errSecSuccess else { return false }
        guard let path else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        return Self.mainExecutable(of: staticCode) == path
    }

    /// The real path of a code's main executable: for an app, the executable inside its bundle, and not the bundle's
    /// folder that `SecCodeCopyPath` gives (round 2, R1: a test build's program refused its own app for that).
    public static func mainExecutable(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess, let read = info as? [String: Any],
              let url = read[kSecCodeInfoMainExecutable as String] as? URL else { return nil }
        return ProgramPlace.realPath(url.path)
    }

    /// The running code of the socket's peer, by its audit token.
    static func peerCode(_ socket: Int32) -> SecCode? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: data] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// This process's own signature: its team (nil for an ad hoc signature or none), and whether it meets the
    /// Developer ID requirement.
    public static func ownSigning() -> (team: String?, developerID: Bool) {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return (nil, false) }
        var info: CFDictionary?
        var team: String?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess, let read = info as? [String: Any],
           let given = read[kSecCodeInfoTeamIdentifier as String] as? String, !given.isEmpty {
            team = given
        }
        var requirement: SecRequirement?
        let meets = SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess
            && requirement.map { SecCodeCheckValidity(code, [], $0) == errSecSuccess } == true
        return (team, meets)
    }

    /// The code directory hash of the code at a path, in hex, or nil when it has none.
    public static func codeDirectoryHash(of path: String) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess, let read = info as? [String: Any],
              let hash = read[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// The code directory hash of this process's own code, in hex, and the real path of its main executable: for a test
    /// that checks a peer that is this process.
    public static func own() -> (hash: String, path: String)? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              let real = mainExecutable(of: staticCode), let hash = codeDirectoryHash(of: real) else { return nil }
        return (hash, real)
    }
}

// ------------------------------------------------------------ the app's side: the listener

/// **The app's listener on the link.** It runs on a queue of its own and never on the app's main thread: a client that
/// sends nothing, half a line, a line longer than `requestMax`, or that never reads its answer, holds one place of
/// `openMax` and nothing else. **Each connection ends by an event or by a count, never by a clock**: its answer is
/// written, the client closes (also after its line, while its answer is made), its line is too long, or it is the oldest
/// when one more connection comes than `openMax`. When a connection ends, the task that makes its answer is cancelled,
/// and a wait in it ends at once (`SetupBoard`). A peer that fails the check gets one refusal line
/// (`OwnerChannel.notOurs`), and nothing of its request is read.
///
/// **The wire's one rule for a client:** it sends its line and keeps its side open until the answer; a client that closes
/// its side (also only for writing) has gone, and its request is ended.
///
/// **The value part.** A line whose envelope says `value_bytes` N is followed by exactly N bytes (1 to `valueMax`); the
/// bytes that came in the same read as the line count. The request's work starts only when all N are there, so a client
/// that closes before has nothing done. Bytes after the N are counted and dropped as bytes after a line are. The
/// listener wipes its own buffers of the value (the read's chunk, the line's buffer, the collecting buffer) when it hands
/// the value over (`OwnerChannel.Value`) or ends.
///
/// **One listener for one user.** The listener holds a lock on a file beside the socket while it runs. A second copy of
/// the app finds that lock held, or a live listener at the place, and does not take it; a socket file that nothing
/// listens on (the app crashed) is replaced.
public final class ChannelListener: @unchecked Sendable {
    public enum Start: Equatable, Sendable {
        case listening
        /// Another copy of the app listens at the place: this one does not.
        case anotherListens
        /// The link cannot listen, in words.
        case cannot(String)
    }

    /// The request and its value part, when it has one.
    public typealias Handler = @Sendable (OwnerChannel.Request, OwnerChannel.Value?) async -> OwnerChannel.Answer

    /// The tries of the link's lock at the start, a tenth of a second apart: about 2 seconds.
    public static let lockTries = 20
    static let lockPause: useconds_t = 100_000

    public let path: String
    let check: PeerCheck
    let handler: Handler
    let openMax: Int
    let requestMax: Int
    let queue = DispatchQueue(label: "com.founderizer.app.link")

    // Each of these only on `queue`.
    private var socket: Int32 = -1
    private var lock: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var paused = false
    private var connections: [Connection] = []
    /// The bytes that the listener read from its clients: a test holds the request bound with it.
    fileprivate var bytesRead = 0

    public init(path: String, check: PeerCheck, openMax: Int = OwnerChannel.openMax,
                requestMax: Int = OwnerChannel.requestMax, handler: @escaping Handler) {
        self.path = path
        self.check = check
        self.handler = handler
        self.openMax = openMax
        self.requestMax = requestMax
    }

    /// A listener whose handler takes no value part: a value that comes is dropped (wiped) unread. For a test.
    public convenience init(path: String, check: PeerCheck, openMax: Int = OwnerChannel.openMax,
                            requestMax: Int = OwnerChannel.requestMax,
                            handler: @escaping @Sendable (OwnerChannel.Request) async -> OwnerChannel.Answer) {
        self.init(path: path, check: check, openMax: openMax, requestMax: requestMax,
                  handler: { request, _ in await handler(request) })
    }

    /// Starts listening, once. Call it off the main thread: it makes the folder and reads the place.
    public func start() -> Start { queue.sync { startHere() } }

    /// **Starts listening, and when another copy of the app listens, waits for that copy to end and starts then.**
    /// The case that it is for (a user's report of 15 November 2026): the app starts itself again for an update, and
    /// the new copy starts while the old one still listens for a moment. `start` gave `anotherListens` at once and was
    /// never called again, so after the old copy ended nobody listened, until the owner quit the app and opened it
    /// again. The wait has no clock: it ends when the other copy's lock is free (`OwnerChannel.waitForLock`). A copy
    /// that listens and holds no lock is looked at again after `otherPause`. It blocks its thread for as long as the
    /// other copy lives, so it is called off the main thread, and it returns only `listening` or `cannot`.
    public func startWhenFree() -> Start {
        while true {
            let started = start()
            guard started == .anotherListens else { return started }
            OwnerChannel.waitForLock(path)
            if OwnerChannel.answers(path) { usleep(Self.otherPause) }
        }
    }
    static let otherPause: useconds_t = 2_000_000

    /// Stops listening and ends each connection: for a test.
    public func stop() { queue.sync { stopHere() } }

    /// The connections open now: for a test.
    public var openCount: Int { queue.sync { connections.count } }

    /// The bytes read from all clients: for a test.
    public var readCount: Int { queue.sync { bytesRead } }

    private func startHere() -> Start {
        guard socket < 0 else { return .listening }
        if let words = OwnerChannel.tooLong(path) { return .cannot(words) }
        let folder = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .cannot("The link cannot make its folder \(folder): \(error.localizedDescription)")
        }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            return .cannot("The folder \(folder) is not a folder of this user, so the link does not listen in it.")
        }
        guard chmod(folder, 0o700) == 0 else {
            return .cannot("The folder \(folder) cannot get mode 700 (\(String(cString: strerror(errno)))), so the "
                           + "link does not listen in it.")
        }
        let held = open(OwnerChannel.lockPath(path), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard held >= 0 else { return .cannot("The link cannot open its lock beside \(path).") }
        // **A lock that another process holds for a moment is tried again** (round 3, P1): the program looks at it with a
        // shared lock when a socket file is there and refuses it. Only a live listener means another copy at once; the
        // lock is tried `lockTries` times, `lockPause` apart, before this copy gives up.
        var tries = Self.lockTries
        while flock(held, LOCK_EX | LOCK_NB) != 0 {
            // Only a lock that somebody holds is a reason to try again: a place that takes no lock at all (a home
            // folder on some network volumes) would else read as another copy for ever.
            guard errno == EWOULDBLOCK || errno == EINTR else {
                let words = String(cString: strerror(errno))
                close(held)
                return .cannot("The link cannot take its lock beside \(path): \(words).")
            }
            tries -= 1
            if tries <= 0 || OwnerChannel.answers(path) {
                close(held)
                return .anotherListens
            }
            usleep(Self.lockPause)
        }
        // A copy that holds no lock (an older build) and listens still keeps its place.
        if OwnerChannel.answers(path) {
            close(held)
            return .anotherListens
        }
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else {
                close(held)
                return .cannot("Something that is no socket stands at \(path), so the link does not listen there.")
            }
            unlink(path)                                    // a socket that nothing listens on: the app crashed
        }
        let made = OwnerChannel.newSocket()
        guard made >= 0 else {
            close(held)
            return .cannot("The link cannot make its socket.")
        }
        var address = OwnerChannel.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(made, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(made, 16) == 0 else {
            let words = String(cString: strerror(errno))
            close(made)
            close(held)
            return .cannot("The link cannot listen at \(path): \(words).")
        }
        _ = fcntl(made, F_SETFL, fcntl(made, F_GETFL) | O_NONBLOCK)
        socket = made
        lock = held
        let source = DispatchSource.makeReadSource(fileDescriptor: made, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { close(made) }
        accepting = source
        source.resume()
        return .listening
    }

    private func stopHere() {
        guard socket >= 0 else { return }
        if paused {
            paused = false
            accepting?.resume()
        }
        accepting?.cancel()
        accepting = nil
        for connection in connections { connection.end() }
        connections = []
        unlink(path)
        socket = -1
        close(lock)
        lock = -1
    }

    private func acceptAll() {
        while true {
            let client = accept(socket, nil, nil)
            guard client >= 0 else {
                // No descriptor left in this process or on the Mac: the read source would fire again at once, so it
                // pauses until a connection of the link closes (an event), or, with none open, for half a second.
                if errno == EMFILE || errno == ENFILE { pauseAccepting() }
                return                                      // else none waits now, or the listener stopped
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard check.accepts(socket: client) else {
                // One refusal line, written once if it fits, and the end: nothing of the request is read.
                let line = OwnerChannel.notOurs.line
                _ = line.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
                continue
            }
            let connection = Connection(socket: client, listener: self)
            connections.append(connection)
            connection.begin()
            // One more than the bound ends the oldest, whatever it waits for: a silent client never holds a place
            // for ever.
            while connections.count > openMax { connections.removeFirst().end() }
        }
    }

    /// No descriptor is left (`EMFILE`, `ENFILE`): internal, so that a test can make the case.
    func pauseAccepting() {
        guard !paused, let accepting else { return }
        paused = true
        accepting.suspend()
        if connections.isEmpty {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.resumeAccepting() }
        } else {
            // A connection that never ends by itself would hold the pause for ever (round 3, P2): the oldest ends, as one
            // more connection than the bound ends it, and its close resumes the accepting.
            connections.removeFirst().end()
        }
    }

    fileprivate func resumeAccepting() {
        guard paused, let accepting else { return }
        paused = false
        accepting.resume()
    }

    fileprivate func ended(_ connection: Connection) {
        connections.removeAll { $0 === connection }
    }

    /// One connection: its request line, its answer line, and its end. Only on the listener's queue.
    fileprivate final class Connection: @unchecked Sendable {
        let socket: Int32
        weak var listener: ChannelListener?
        let queue: DispatchQueue
        let requestMax: Int
        private var buffer = Data()
        private var reader: DispatchSourceRead?
        private var writer: DispatchSourceWrite?
        private var unsent = Data()
        private var lineTaken = false
        private var after = 0
        private var work: Task<Void, Never>?
        private var finished = false
        private var sources = 0
        /// A request whose value part is not whole yet, and the bytes of that part so far: their room is reserved for
        /// all of them at once, so no grown copy of them is left behind in freed memory.
        private var waiting: OwnerChannel.Request?
        private var value: [UInt8] = []
        private var valueNeed = 0

        init(socket: Int32, listener: ChannelListener) {
            self.socket = socket
            self.listener = listener
            queue = listener.queue
            requestMax = listener.requestMax
        }

        func begin() {
            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [weak self] in self?.read() }
            source.setCancelHandler { [self] in released() }
            sources += 1
            reader = source
            source.resume()
        }

        /// Reads the request line, never more than `requestMax` and one byte; then the value part that the line names,
        /// exactly its count; after that, reads on only to see the client's close, which ends the connection and its
        /// work.
        private func read() {
            guard !finished else { return }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            defer { OwnerChannel.wipe(&chunk) }                 // it held bytes of the value part, perhaps
            while !finished {
                let room = waiting != nil ? min(chunk.count, valueNeed - value.count)
                    : lineTaken ? chunk.count : min(chunk.count, requestMax + 1 - buffer.count)
                let count = Darwin.read(socket, &chunk, room)
                if count > 0 {
                    listener?.bytesRead += count
                    if waiting != nil {
                        value.append(contentsOf: chunk[0..<count])
                        if value.count == valueNeed { startWork() }
                        continue
                    }
                    if lineTaken {
                        after += count                      // more after the line: never kept, and bounded
                        if after > requestMax { end() }
                        continue
                    }
                    buffer.append(contentsOf: chunk[0..<count])
                    if let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[buffer.startIndex..<end])
                        lineTaken = true
                        take(line, restFrom: end + 1)
                        OwnerChannel.wipe(&buffer)
                        buffer = Data()
                        continue
                    }
                    if buffer.count > requestMax {
                        stopReading()
                        answer(.refused("This request is longer than the \(requestMax) bytes that the app reads."))
                        return
                    }
                    continue
                }
                if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
                end()                                       // the client's close: before its line, nothing is done
                return
            }
        }

        private func stopReading() {
            reader?.cancel()
            reader = nil
        }

        /// The line, and the bytes that came after it in the same read (`buffer` from `start`): the start of its value
        /// part, or bytes after the line, which are counted and dropped. No slice of `buffer` outlives this call, so the
        /// wipe of `buffer` reaches its one copy.
        private func take(_ line: Data, restFrom start: Int) {
            let rest = buffer.count - start
            switch OwnerChannel.Request.read(line) {
            case .failure(let refusal):
                answer(.refused(refusal.text))
            case .success(let request):
                guard let need = request.valueBytes else {
                    after += rest
                    return launch(request, nil)
                }
                valueNeed = need
                value.reserveCapacity(need)
                let taken = min(need, rest)
                value.append(contentsOf: buffer[start..<(start + taken)])
                after += rest - taken
                waiting = request
                if value.count == need { startWork() }
            }
        }

        /// The value part is whole: it goes to the handler in a value of its own, and this buffer is wiped.
        private func startWork() {
            guard let request = waiting else { return }
            waiting = nil
            let part = OwnerChannel.Value(copying: value)
            OwnerChannel.wipe(&value)
            value = []
            launch(request, part)
        }

        private func launch(_ request: OwnerChannel.Request, _ value: OwnerChannel.Value?) {
            guard let handler = listener?.handler else { return end() }
            let queue = queue
            work = Task {
                let answer = await handler(request, value)
                queue.async { [self] in self.answer(answer) }
            }
        }

        private func answer(_ answer: OwnerChannel.Answer) {
            guard !finished else { return }
            work = nil
            stopReading()
            unsent = answer.line
            write()
        }

        private func write() {
            while !unsent.isEmpty {
                let count = unsent.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
                if count > 0 {
                    unsent.removeFirst(count)
                    continue
                }
                if count < 0 && (errno == EAGAIN || errno == EINTR) {
                    // The client does not read now: the rest goes when it can, or the connection ends by the count.
                    if writer == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue)
                        source.setEventHandler { [weak self] in self?.write() }
                        source.setCancelHandler { [self] in released() }
                        sources += 1
                        writer = source
                        source.resume()
                    }
                    return
                }
                break
            }
            end()
        }

        /// The end of the connection, once: the work of its answer is cancelled, and its socket closes when no source
        /// of it is left.
        func end() {
            guard !finished else { return }
            finished = true
            work?.cancel()
            work = nil
            // A value part that was not whole, or a line that was not read to its end: wiped, and nothing is done.
            waiting = nil
            OwnerChannel.wipe(&value)
            value = []
            OwnerChannel.wipe(&buffer)
            buffer = Data()
            listener?.ended(self)
            reader?.cancel()
            reader = nil
            writer?.cancel()
            writer = nil
            if sources == 0 { closed() }
        }

        private func released() {
            sources -= 1
            if finished && sources == 0 { closed() }
        }

        private func closed() {
            close(socket)
            listener?.resumeAccepting()
        }
    }
}

// ------------------------------------------------------------ the program's side: one exchange

/// **One exchange of the program with the app**: connect, check the app, one request line, one answer line.
public enum ChannelClient {
    public enum Reach: Equatable, Sendable {
        /// The app's answer.
        case answer(OwnerChannel.Answer)
        /// Nothing listens at the place, and no copy of the app holds its lock: the app does not run.
        case nothingListens
        /// A copy of the app holds the link's lock and took no connection now (its queue of connections is full, or it
        /// is starting): it runs, and is busy.
        case busy
        /// Something listens and it is not the app of this program's own bundle: nothing was sent.
        case notTheApp
        /// Another failure, in words.
        case failed(String)
    }

    /// **The bound of the program's read**: 60 reads of one second each with nothing from the app, a little above the
    /// app's own 50 seconds of `setup_state`'s wait. Then the program says that the app did not answer.
    public static let quietReads = 60

    /// The exchange. Its read ends at the app's line end, at the app's close, at `answerMax`, or after `quietReads`
    /// reads of `readWait` with nothing new. `value`: the value part, written after the line (whose `value_bytes` this
    /// sets to its count), only once the app passed its check.
    public static func exchange(path: String, request: OwnerChannel.Request, value: OwnerChannel.Value? = nil,
                                check: PeerCheck, answerMax: Int = OwnerChannel.answerMax,
                                quietReads: Int = ChannelClient.quietReads,
                                readWait: timeval = timeval(tv_sec: 1, tv_usec: 0)) -> Reach {
        var request = request
        request.valueBytes = value?.count
        if let words = OwnerChannel.tooLong(path) { return .failed(words) }
        let socket = OwnerChannel.newSocket()
        guard socket >= 0 else { return .failed("This program cannot make a local socket.") }
        defer { close(socket) }
        let failure = OwnerChannel.connect(socket, to: path)
        // No socket file: nothing listens, and the lock is not touched, so an app that starts now takes it at once. A
        // socket file that refuses: busy when a copy holds the lock, else the file of an app that crashed.
        if failure == ENOENT { return .nothingListens }
        if failure == ECONNREFUSED { return OwnerChannel.lockHeld(path) ? .busy : .nothingListens }
        guard failure == 0 else { return .failed("This program could not reach the Founderizer app: "
                                                 + String(cString: strerror(failure)) + ".") }
        guard check.accepts(socket: socket) else { return .notTheApp }
        // **The writes have the read's bound** (a value part of 64 KiB does not fit the socket's buffer, so an app that
        // reads nothing would hold the program for ever): each write waits `readWait` at most, and each that ends with
        // nothing written is one quiet turn; the turns are never counted again from 0 after progress, the read below
        // counts on from them, and after `quietReads` of them in all the program says that the app did not answer. A
        // partial write goes on.
        var wait = readWait
        _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var quietWrites = 0
        enum Sent { case all, closed, quiet }
        func send(_ bytes: UnsafeRawBufferPointer) -> Sent {
            var done = 0
            while done < bytes.count {
                let count = Darwin.write(socket, bytes.baseAddress! + done, bytes.count - done)
                if count > 0 { done += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    quietWrites += 1
                    if quietWrites < quietReads { continue }
                    return .quiet
                }
                return .closed                              // the app closed: its one line, if any, is read below
            }
            return .all
        }
        let line = request.line
        var sent = line.withUnsafeBytes { send($0) }
        if sent == .all, let value { sent = value.withBytes { send($0) } }
        if sent == .quiet { return .failed(noAnswer) }
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var quiet = quietWrites                             // one count for the writes and the read
        while buffer.count <= answerMax {
            let count = Darwin.read(socket, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if let end = buffer.firstIndex(of: 10) {
                    guard let answer = OwnerChannel.Answer.read(Data(buffer[buffer.startIndex..<end])) else {
                        return .failed(unreadable)
                    }
                    return .answer(answer)
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                quiet += 1
                if quiet < quietReads { continue }
                return .failed(noAnswer)
            }
            break
        }
        return .failed(buffer.isEmpty ? closedNoAnswer : unreadable)
    }

    /// The three failures after the request went out, whose outcome the program does not know: a link write gives
    /// each its tool's own "not known" words (`AppLink.call`).
    static let closedNoAnswer = "The Founderizer app closed the link with no answer. Call the tool again."

    static let unreadable = "The Founderizer app gave an answer that this program cannot read: the program and the "
        + "app are of different versions. Start a new session after the app's update."
    static let noAnswer = "The Founderizer app took this call and did not answer it within a minute: its window may be "
        + "busy. Ask the owner whether the app responds; then call the tool again."
}
