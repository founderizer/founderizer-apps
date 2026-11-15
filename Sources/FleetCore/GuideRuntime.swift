#if os(macOS)
import Darwin
import Foundation
import Security

/// **What one start of the guide's session needs** (spec section 3.2, lane S).
public struct GuideStart: Sendable {
    /// The provider's program. The runner checks this file itself, at the start (`GuideProgram.check`).
    public var program: URL
    /// The file is the copy in the app's own folder, which a failed check deletes. false: the owner's own program.
    public var appsOwn: Bool
    /// The helper, by its whole path: the program in the app's bundle (`founderizer-cli`). The session's one MCP server.
    public var helper: String
    /// The helper's set of tools: `guide`.
    public var set: String
    /// The random label of this session, which the helper says when it connects to the app. A secret: it is in no log.
    public var label: String
    /// The session's tools by their own names (`setup_state`, `propose_team`, ...): the model gets these and no other.
    public var tools: [String]
    /// The guide text for the app's window: the program's whole system prompt.
    public var text: String
    /// The session's id, a UUID in small letters. The app chooses it.
    public var session: String
    /// A start after a quit: the program goes on with the session of that id.
    public var resume: Bool
    public var places: GuidePlaces
    public var home: String
    public var user: String

    public init(program: URL, appsOwn: Bool, helper: String, set: String = "guide", label: String, tools: [String],
                text: String, session: String, resume: Bool, places: GuidePlaces, home: String = NSHomeDirectory(),
                user: String = NSUserName()) {
        self.program = program; self.appsOwn = appsOwn; self.helper = helper; self.set = set; self.label = label
        self.tools = tools; self.text = text; self.session = session; self.resume = resume; self.places = places
        self.home = home; self.user = user
    }
}

/// **The command of a start, and the lines that the app writes to the program**, with no process: a test holds each
/// to the spec, word for word.
public enum GuideCommand {
    /// The variable of the helper's environment that holds the session's label.
    public static let labelVariable = "FOUNDERIZER_GUIDE"

    /// The arguments of Claude Code for the guide's session. Each option but `--no-chrome` ran in the probe of 14
    /// November 2026 on 2.1.312. `--bare` is never given: it reads no plan sign-in. `--no-chrome`: no default of the
    /// owner's gives this session a browser tool.
    public static func arguments(_ start: GuideStart) -> [String] {
        ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
         "--strict-mcp-config", "--mcp-config", start.places.configuration.path,
         "--setting-sources", "", "--tools", "", "--disable-slash-commands", "--no-chrome",
         "--allowedTools", start.tools.map(GuideCheck.whole).joined(separator: ","),
         "--system-prompt", start.text]
            + (start.resume ? ["--resume", start.session] : ["--session-id", start.session])
            + ["--model", "sonnet"]
    }

    /// **The program's whole environment**: nothing of the app's own. The updater is off, so that the session does not
    /// update the owner's program. Two more variables are the program's own, read in the file of 2.1.312 and proved on
    /// that version on 15 November 2026 (`GuideLiveTests`). Neither is a documented option, so nothing rests on one
    /// alone:
    ///
    /// - `CLAUDE_CODE_HARBOR_KITE=0` closes the program's own socket, through which another Claude Code session of this
    ///   user can put a message into this one. With it the program opens no socket and gives the helper no name of
    ///   one. The check at each turn also stops the program when a socket is open (`GuideStop.socket`), and the runner
    ///   stops it at a turn that the app did not ask for.
    /// - `CLAUDE_CODE_DISABLE_FILE_MENTIONS=1`: the program reads no file that a message names after "@". Without it,
    ///   the program gave the model the content of such a file, although the model has no tool that reads one. Each
    ///   message also goes to the program as plain words (`GuideRules.plain`), so that it holds no such name.
    public static func environment(home: String, user: String) -> [String: String] {
        ["HOME": home, "USER": user, "PATH": "/usr/bin:/bin", "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_HARBOR_KITE": "0",
         "CLAUDE_CODE_DISABLE_FILE_MENTIONS": "1"]
    }

    /// The MCP configuration: one server, the helper with its set, by its whole path, with the label in its
    /// environment.
    public static func configuration(_ start: GuideStart) -> Data {
        let server: [String: Any] = ["command": start.helper, "args": ["mcp", "--set", start.set],
                                     "env": [labelVariable: start.label]]
        return (try? JSONSerialization.data(withJSONObject: ["mcpServers": [GuideCheck.server: server]],
                                            options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// **One message for the model, as one line of the program's input.** Each text passes `GuideRules.plain` here,
    /// whatever its caller did with it: the program takes no first character of it for itself, and reads no file's
    /// name in it. `asItIs` is for the live test alone, which sends what an owner types to see what the program does.
    public static func message(_ text: String) -> Data { message(text, asItIs: false) }

    static func message(_ text: String, asItIs: Bool) -> Data {
        line(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": asItIs ? text : GuideRules.plain(text)]]]])
    }

    /// The line that stops the turn and keeps the process.
    public static func interrupt(id: String) -> Data {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// **The program's own files of the session's folder go, at the guide's end**: `claude purge --yes <folder>` deletes
    /// the conversation files that the program keeps for that folder, and asks nothing.
    public static func purge(_ places: GuidePlaces) -> [String] { ["purge", "--yes", places.work.path] }

    /// A new label: 32 random bytes, in hex.
    public static func newLabel() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return (0..<4).map { _ in String(UInt64.random(in: .min ... .max), radix: 16) }.joined()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A new session id, as the program takes it.
    public static func newSession() -> String { UUID().uuidString.lowercased() }
}

/// **The guide's session: one process of the provider's program, many turns** (spec section 3.2, lane S). It has no
/// view. The app writes one message at a time, and reads typed events.
///
/// What it holds, at each start and at each turn:
/// - The file passed the two checks at this start (`GuideProgram.check`).
/// - The first message is the app's own, never words of the owner: `run(first:)` takes it, and `send` writes nothing
///   before the first turn began with a start that passed the check.
/// - Each start of a turn passes `GuideCheck`, or the program is stopped at once.
/// - One message is with the program at a time, and each turn answers a message that the app wrote. A turn that the
///   app did not ask for stops the program: a message that another process put into the session gets no answer drawn.
public final class GuideRuntime: @unchecked Sendable {
    /// The session's events, in order. The stream ends after `.stopped` or `.ended`.
    public let events: AsyncStream<GuideEvent>

    private let start: GuideStart
    private let checker: GuideProgram.Checker
    private let yield: AsyncStream<GuideEvent>.Continuation
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var check: GuideCheck?
    /// The messages that wait for the turn before them to end.
    private var waiting: [Data] = []
    /// How many messages the app wrote to the program.
    private var asked = 0
    /// A message is with the program, and its turn has not ended.
    private var inFlight = false
    /// The turn of that message began, with a start that passed the check.
    private var begun = false
    /// The first turn began with a start that passed the check.
    private var firstPassed = false
    /// The model spoke or called a tool in this turn.
    private var spoke = false
    /// A limit or a missing sign-in was said in this turn already.
    private var said: Set<String> = []
    /// The last start of a turn that the program printed, as the check read it.
    private var lastStart: GuideTurnStart?
    /// The program printed a line that this reader knows.
    private var printed = false
    /// The last event went out.
    private var over = false
    private var quitting = false

    public init(_ start: GuideStart, checker: GuideProgram.Checker = .mac) {
        self.start = start
        self.checker = checker
        (events, yield) = AsyncStream<GuideEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    /// **Starts the program and writes the app's first message** (the event `start`, or `resumed` after a quit). It
    /// throws `GuideProgram.Refusal` when the file fails a check: such a file is never started.
    @discardableResult
    public func run(first: String) throws -> GuideProgram.File {
        let file = try GuideProgram.check(start.program, appsOwn: start.appsOwn, with: checker).get()
        try start.places.make()
        try start.places.write(GuideCommand.configuration(start), to: start.places.configuration)

        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = file.url
        process.arguments = GuideCommand.arguments(start)
        process.environment = GuideCommand.environment(home: start.home, user: start.user)
        process.currentDirectoryURL = start.places.work
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A program that ended closes the pipe: a write then fails, and raises no signal that would end the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        lock.lock()
        check = GuideCheck(tools: start.tools, version: file.version)
        self.process = process
        self.input = input.fileHandleForWriting
        waiting = [GuideCommand.message(first)]
        lock.unlock()
        do { try process.run() } catch {
            lock.withLock { over = true }
            yield.finish()
            throw GuideProgram.Refusal.missing
        }
        let reader = output.fileHandleForReading
        Thread.detachNewThread { [self] in read(reader, of: process) }
        lock.withLock { writeNext() }
        return file
    }

    /// What the program said that the model has, at the last start of a turn: for the live test's record.
    public var turnStart: GuideTurnStart? { lock.withLock { lastStart } }

    /// One more message for the model: the owner's words after K's three steps, or an event of the app. It goes when
    /// the turn before it has ended.
    public func send(_ text: String) { send(text, asItIs: false) }

    /// For the live test alone: a text with no change, as an owner types it.
    func send(_ text: String, asItIs: Bool) {
        lock.withLock {
            guard !over, !quitting else { return }
            waiting.append(GuideCommand.message(text, asItIs: asItIs))
            writeNext()
        }
    }

    /// Stops the turn that runs, and keeps the process. The program may send the helper no cancel notice for a tool
    /// call that was cut, so the app takes down the card or the page of that call itself.
    public func interrupt() {
        lock.withLock {
            guard inFlight, !over, let input else { return }
            try? input.write(contentsOf: GuideCommand.interrupt(id: "guide-\(UUID().uuidString.lowercased())"))
        }
    }

    /// **A quit of the app**: the program's input ends, and after two seconds the program gets SIGTERM. A turn that was
    /// cut stays cut, and nothing that was said before it is lost: the program keeps the conversation itself.
    public func quit() async {
        let process: Process? = lock.withLock {
            quitting = true
            try? input?.close()
            input = nil
            return self.process
        }
        guard let process else { return }
        for _ in 0..<40 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        if process.isRunning { process.terminate() }
    }

    // MARK: - Inside

    /// Writes the next message when no turn runs. Under the lock.
    private func writeNext() {
        guard !inFlight, !over, !quitting, let input, !waiting.isEmpty, asked == 0 || firstPassed else { return }
        let message = waiting.removeFirst()
        asked += 1
        inFlight = true
        begun = false
        spoke = false
        said = []
        try? input.write(contentsOf: message)
    }

    /// Reads the program's lines to their end, on a thread of its own, and then says how the program ended.
    private func read(_ reader: FileHandle, of process: Process) {
        // The system's own read gives what the pipe holds now. `FileHandle.read(upToCount:)` waits for the whole count
        // or for the end, so a line would wait until the program ends.
        var rest = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            rest.append(contentsOf: buffer[0..<count])
            while let end = rest.firstIndex(of: 0x0A) {
                let line = String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
                rest.removeSubrange(rest.startIndex...end)
                take(line)
            }
        }
        if !rest.isEmpty { take(String(decoding: rest, as: UTF8.self)) }
        process.waitUntilExit()
        let last: GuideEvent? = lock.withLock {
            guard !over else { return nil }
            over = true
            try? input?.close()
            input = nil
            if quitting { return .ended }
            // A resume that ended with nothing printed was refused too.
            if start.resume, !printed { return .stopped(.resumeRefused) }
            return .stopped(.exited(process.terminationStatus))
        }
        if let last { yield.yield(last) }
        yield.finish()
    }

    /// One line of the program.
    private func take(_ line: String) {
        var out: [GuideEvent] = []
        var stopped: GuideStop?
        lock.lock()
        guard !over, let check else { lock.unlock(); return }
        let read = GuideStream.read(line)
        if read != .events([]) { printed = true }
        switch read {
        case .start(let turn):
            lastStart = turn
            if let stop = check.stop(for: turn) {
                stopped = stop
            } else if inFlight, !begun {
                begun = true
                firstPassed = true
                out.append(.turnStarted)
            } else if inFlight, asked == 1, !spoke {
                // The program's line at its own start and the line of the first turn: the first message goes at once,
                // so the two can come one after the other. Both passed the check, and they are one turn.
            } else if asked > 0 {
                // No message of the app waits for a turn: another process wrote into the session.
                stopped = .unasked
            }
            // Else it is the program's line at its own start, before the first message: checked, and no turn.
        case .events(let events):
            loop: for event in events {
                switch event {
                case .words, .toolCall, .ownAnswer:
                    guard inFlight else { stopped = .unasked; break loop }
                    guard begun else { stopped = .unchecked; break loop }
                    spoke = true
                    out.append(event)
                case .limit, .notSignedIn:
                    let key = event == .notSignedIn ? "sign-in" : "limit"
                    if said.insert(key).inserted { out.append(event) }
                case .turnEnded:
                    guard inFlight else { continue }
                    inFlight = false
                    begun = false
                    out.append(event)
                case .stopped(let stop):
                    // A resume that fails before its first turn began was refused. 2.1.312 prints one `result` line
                    // with an error for a session that it does not have, and ends (run on 15 November 2026).
                    if start.resume, !firstPassed, case .failed = stop { stopped = .resumeRefused } else { stopped = stop }
                    break loop
                case .interruptTaken:
                    out.append(event)
                case .turnStarted, .ended:
                    break
                }
            }
        }
        if let stopped {
            over = true
            out.append(.stopped(stopped))
            try? input?.close()
            input = nil
        } else {
            writeNext()
        }
        let process = self.process
        lock.unlock()
        // Stopped at once: the model gets no more of this turn, and a tool call of it gets no more time.
        if stopped != nil, let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for event in out { yield.yield(event) }
    }
}
#endif
