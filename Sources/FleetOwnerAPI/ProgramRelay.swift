import Darwin
import Foundation
import Security

/// **The program of the app that replaced this one**, for the calls of an AI session that started before an update.
///
/// An update swaps the whole bundle under a program that still runs, and the owner's AI session keeps the list of tools
/// that this program gave it at its start. Until 20 November 2026 each call then got "start a new session"
/// (agent-install-design.md 3.3), while the app took 165 versions in 7 days: each session of the owner's lost its tools
/// within hours (the review of the area "Setup, servers and owner tools", 20 November 2026). Now the call goes to the
/// program behind the path that this one was started by, as a new session would start it, in that program's own MCP
/// form (`mcp --set owner`): one child for the session, and a new one when the build behind the path changes again. The
/// child is taken only when its running process is signed as this program is (`meets`), and its result comes back
/// whole, so the call does what it does in a new session.
///
/// **No call that the client's list is old for**: the relay compares the tool's entry in the child's `tools/list` with
/// this program's own, which is the client's: its marks (whether it asks first), and, for a tool that is not marked as
/// a read, its input schema (what the client sends) and its words, which can say what a call does (a door card's press
/// is in `answer_needs_you`'s words only). A read's fields are the new program's to check (`entry`). A tool that
/// differs, or that the child does not have, is refused, and nothing is sent. The comparison runs in the old program,
/// so a session that started on a build before this rule still compares a read's fields.
///
/// **Never a call twice**: a child that ended before a call took none of it (its input could not be written), so a new
/// child takes it, once; a child that took the call and gave no answer, or one past its deadline, may have carried it
/// out, and the call is not sent again.
public final class ProgramRelay: @unchecked Sendable {
    /// One child program, as the relay speaks to it: a line out (false when it could not be written), the next line in
    /// (nil at the child's end, or when the deadline passed first), and its stop.
    public struct Child: Sendable {
        public let send: @Sendable (String) -> Bool
        public let receive: @Sendable (_ deadline: Date) -> String?
        public let stop: @Sendable () -> Void

        public init(send: @escaping @Sendable (String) -> Bool, receive: @escaping @Sendable (Date) -> String?,
                    stop: @escaping @Sendable () -> Void) {
            self.send = send
            self.receive = receive
            self.stop = stop
        }
    }

    /// What one launch gave: a child; nothing, because it did not start; or a child that the signature check refused,
    /// which is stopped at once.
    public enum Launched: Sendable {
        case child(Child)
        case none
        case refused
    }

    /// What the child did with one call.
    public enum Answer: Equatable, Sendable {
        /// Its result, whole, as it gave it.
        case answered(JSONValue)
        /// The tool's entry in its list differs from this program's: nothing was sent.
        case changed
        /// It has no such tool: nothing was sent.
        case gone
        /// It did not start, or it refused the request for its form: the call was not carried out.
        case silent
        /// The program behind the path is not signed as this program: nothing was sent to it.
        case untrusted
        /// It took the call and ended with no answer, gave none in time, or gave one that is no result: the call may
        /// have been carried out.
        case lost
    }

    /// The path that this program was started by: the child's, and the one that the words of a refusal name.
    public let path: String
    private let build: @Sendable () -> Int?
    private let launch: @Sendable () -> Launched
    private let version: String
    private let startWait: TimeInterval
    private let callWait: TimeInterval
    private let lock = NSLock()
    private var running: Running?
    /// The build behind the path whose program the check refused: it is not started again until that build changes,
    /// as its own code runs before each check.
    private var refusedBuild: Int??
    private var lastID: Int64 = 0

    private struct Running {
        let child: Child
        let build: Int?
        let tools: [String: JSONValue]
    }

    /// `build`: the build behind `path` now. `launch`: a new child of the program behind `path` (`process(path:...)`).
    /// `version`: this program's own, for the child's `initialize`. `startWait`: the most that the child's whole start
    /// may take (Claude Code gives a server 30 seconds). `callWait`: the most that one call may take, above the 15
    /// minutes of the program's own longest call (`Transfer`) and under the 30 after which Claude Code ends a call.
    public init(path: String, build: @escaping @Sendable () -> Int?, launch: @escaping @Sendable () -> Launched,
                version: String, startWait: TimeInterval = 30, callWait: TimeInterval = 20 * 60) {
        self.path = path
        self.build = build
        self.launch = launch
        self.version = version
        self.startWait = startWait
        self.callWait = callWait
    }

    /// The parts of a tool's entry that the relay compares: whether it asks first (its marks), and for a tool that is
    /// not marked as a read also what the client sends and its words. A read changes nothing, and the new program checks
    /// its own fields (`fleet_read` refuses each word that its page does not take), so a read whose fields changed still
    /// goes: `fleet_read`'s changed in 4 of 148 builds in 7 days (a validator's check of 20 November 2026), and each
    /// change ended the main read of every running session until it started again.
    public static func entry(description: String, inputSchema: JSONValue, annotations: JSONValue) -> JSONValue {
        var parts: [String: JSONValue] = ["annotations": annotations]
        if annotations["readOnlyHint"] != .bool(true) {
            parts["description"] = .string(description)
            parts["inputSchema"] = inputSchema
        }
        return .object(parts)
    }

    /// One call, through the child; `entry` is this program's own entry of the tool (`entry(description:...)`), and
    /// `protocolVersion` the one that this program speaks.
    public func call(_ name: String, arguments: JSONValue?, entry: JSONValue, protocolVersion: String) -> Answer {
        lock.lock()
        defer { lock.unlock() }
        if let running, running.build != build() {      // updated again: the program behind the path is another one
            running.child.stop()
            self.running = nil
        }
        var params: [String: JSONValue] = ["name": .string(name)]
        if let arguments { params["arguments"] = arguments }
        for _ in 0..<2 {
            if running == nil {
                let now = build()
                if refusedBuild == .some(now) { return .untrusted }
                switch launch() {
                case .none: return .silent
                case .refused:
                    refusedBuild = .some(now)
                    return .untrusted
                case let .child(child):
                    guard let started = start(child, protocolVersion: protocolVersion) else { return .silent }
                    running = started
                }
            }
            guard let current = running else { return .silent }
            guard let theirs = current.tools[name] else { return .gone }
            guard theirs == entry else { return .changed }
            let reply = request(current.child, "tools/call", .object(params), until: Date().addingTimeInterval(callWait))
            if case let .result(result) = reply, result.object != nil { return .answered(result) }
            current.child.stop()
            running = nil
            switch reply {
            case .unsent: continue
            case .refused: return .silent
            case .result, .ended: return .lost
            }
        }
        return .silent
    }

    /// A child with its build and its tools' entries, after the MCP start (`initialize`, `notifications/initialized` and
    /// each page of `tools/list`), all within `startWait`; nil, with the child stopped, when one of them gets no result
    /// in time.
    private func start(_ child: Child, protocolVersion: String) -> Running? {
        let build = self.build()
        let deadline = Date().addingTimeInterval(startWait)
        let hello: JSONValue = .object([
            "protocolVersion": .string(protocolVersion), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("founderizer-cli"), "version": .string(version)]),
        ])
        var tools: [String: JSONValue] = [:]
        var ready = false
        if case .result = request(child, "initialize", hello, until: deadline),
           child.send(JSONValue.object(["jsonrpc": .string("2.0"),
                                        "method": .string("notifications/initialized")]).dumps()) {
            var cursor: JSONValue?
            for _ in 0..<20 {       // a page of tools at a time, as long as the child gives a next one
                guard case let .result(page) = request(child, "tools/list",
                                                       cursor.map { .object(["cursor": $0]) }, until: deadline),
                      let list = page["tools"]?.array else { break }
                for tool in list {
                    guard let name = tool["name"]?.string else { continue }
                    tools[name] = Self.entry(description: tool["description"]?.string ?? "",
                                             inputSchema: tool["inputSchema"] ?? .null,
                                             annotations: tool["annotations"] ?? .null)
                }
                cursor = page["nextCursor"]
                if cursor == nil || cursor?.isNull == true {
                    ready = true
                    break
                }
            }
        }
        guard ready else {
            child.stop()
            return nil
        }
        return Running(child: child, build: build, tools: tools)
    }

    /// What one request got: its result; nothing, because it could not be written (the child had ended, and took none
    /// of it); a refusal for its form; or no answer (the child's end, the deadline, or another error).
    private enum Reply {
        case result(JSONValue)
        case unsent
        case refused
        case ended
    }

    /// The JSON-RPC errors of a request's form, which a server gives before it carries anything out.
    private static let formErrors: [JSONValue] = [-32700, -32600, -32601, -32602].map { .int($0) }

    /// One request, answered by `deadline`. A request or a notification of the child's own is no reply: the relay
    /// answers a request of the child's (`answerChild`) and reads on. The write itself has no deadline: the child is
    /// this program's own, which reads each line as it comes.
    private func request(_ child: Child, _ method: String, _ params: JSONValue?, until deadline: Date) -> Reply {
        lastID += 1
        let id = JSONValue.int(lastID)
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id, "method": .string(method)]
        if let params { message["params"] = params }
        guard child.send(JSONValue.object(message).dumps()) else { return .unsent }
        while let line = child.receive(deadline) {
            guard let answer = JSONValue.parse(line) else { continue }
            if let asked = answer["method"]?.string {
                answerChild(child, asked, id: answer["id"])
                continue
            }
            // A reply to no id (the child could not read a line) is the one request on its way.
            guard answer["id"] == id || (answer["id"]?.isNull == true && answer["error"] != nil) else { continue }
            if let result = answer["result"] { return .result(result) }
            return Self.formErrors.contains(answer["error"]?["code"] ?? .null) ? .refused : .ended
        }
        return .ended
    }

    /// A request of the child's own: a ping gets an empty result, any other "Method not found"; a notification gets
    /// nothing.
    private func answerChild(_ child: Child, _ method: String, id: JSONValue?) {
        guard let id, !id.isNull else { return }
        let reply: JSONValue = method == "ping"
            ? .object(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])
            : .object(["jsonrpc": .string("2.0"), "id": id,
                       "error": .object(["code": .int(-32601), "message": .string("Method not found: \(method)")])])
        _ = child.send(reply.dumps())
    }

    /// **The program behind `path` as a child process**, in its MCP form: its standard input and output are pipes of
    /// this program's, and its standard error is this program's own, so that its words reach the client's log. It is
    /// taken only when `accepts` its running process (`meets`); else it is stopped at once. A write to a child that ended
    /// fails, and never stops this program (`F_SETNOSIGPIPE`). The child ends when it reads the end of its input: when
    /// this program stops it, or ends itself.
    public static func process(path: String, accepts: (pid_t) -> Bool) -> Launched {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["mcp", "--set", "owner"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { return .none }
        let stop: @Sendable () -> Void = {
            try? writer.close()
            if process.isRunning { process.terminate() }
        }
        guard accepts(process.processIdentifier) else {
            stop()
            return .refused
        }
        let reader = LineReader(output.fileHandleForReading)
        return .child(Child(send: { line in
                                do {
                                    try writer.write(contentsOf: Data((line + "\n").utf8))
                                    return true
                                } catch {
                                    return false
                                }
                            },
                            receive: { reader.next(until: $0) },
                            stop: stop))
    }

    /// **The requirement of a child**, read once at the program's start (`main`), while its own executable is still in
    /// place: an update moves it to the Trash, which the owner can empty. A Developer ID of this program's own team with
    /// the program's identifier; nil for a build with no Developer ID, which takes no child.
    public static func childRequirement() -> String? {
        let own = SignatureCheck.ownSigning()
        guard let team = own.team, own.developerID else { return nil }
        return SignatureCheck.requirement(team: team, identifier: OwnerChannel.programIdentifier)
    }

    /// **The running child meets `requirement`** (OWNER-MCP-BOUNDARY.md 7b), checked on its process right after its
    /// start; nil takes no child. What the check is worth: it refuses a program at the path that is not signed as this
    /// one (a test build, another program, a broken bundle), and it keeps out no process of the owner's user that
    /// controls the path: that one's own code runs before the check, as it runs in each new session, whose client starts
    /// the path with no check.
    public static func meets(_ pid: pid_t, requirement: String?) -> Bool {
        guard let requirement else { return false }
        var code: SecCode?
        var made: SecRequirement?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &made) == errSecSuccess, let made
        else { return false }
        return SecCodeCheckValidity(code, [], made) == errSecSuccess
    }
}

/// The lines of a file handle, read on a thread of their own: each `next` waits for a whole line, the end, or its
/// deadline. A read looks only at the bytes that came since the last one, so a long line costs its length once.
final class LineReader: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    /// The bytes at the buffer's start that hold no new line.
    private var scanned = 0
    private var ended = false

    /// Reads `handle` until its end. Each read takes what has come (`read(2)`): `FileHandle.read(upToCount:)` waits
    /// for the whole count, and `availableData` stops the program on a read that fails, which here is the end.
    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                var count: Int
                repeat {
                    count = chunk.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                } while count < 0 && errno == EINTR
                condition.lock()
                if count > 0 { buffer.append(contentsOf: chunk[0..<count]) } else { ended = true }
                condition.broadcast()
                condition.unlock()
                if count <= 0 { return }
            }
        }
    }

    /// The next line, without its new line; nil at the end, or when `deadline` passed first.
    func next(until deadline: Date) -> String? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                scanned = 0
                return String(decoding: line, as: UTF8.self)
            }
            scanned = buffer.count
            if ended || !condition.wait(until: deadline) { return nil }
        }
    }
}
