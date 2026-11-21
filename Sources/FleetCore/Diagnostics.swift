import Foundation

/// **The hub's own faults and refused calls** (owner feature `diagnostics`, `GET /ui/diagnostics`, UI-API.md 1.167).
///
/// The owner, 14 November 2026: "Pictures first (Recommended)", and to the pictures C0, E1, E2 and E3 of Report a
/// problem and System status: "ok yes, make sure we include all relevant inforamtion that is SAFE to send". The plan is
/// `~/dev/founderizer-plans/feedback-diagnostics-plan.md`.
///
/// **What it may hold is types, never words.** A fault is an exception class, files of the hub's code with their lines,
/// numbers and times; a refused call is a tool's name, a file and a line, and numbers. The hub checks every value before
/// it answers, and this app checks each one again: a value of the wrong type drops the whole answer, a value out of its
/// shape drops its entry, a class or a file that is
/// not on this app's own list is `other` or `lib`, and a line that looks like a key goes nowhere. A tool's name is only
/// shape-checked here (the hub keeps only names of its own list), so the words that a wrong hub could still choose are
/// a few lower-case letters in that one place. The app writes each line itself, and Report a problem shows every line
/// before it sends anything.
///
/// **A stall** (UI-API.md 1.284) is said in the same rows as a fault, as "Stall at hub.py 5574, from hub.py 74318.
/// Once.": the owner's "Yes, reports only" of 21 November 2026 to that picture of the "Last error" row. It raises no
/// warning: the hub counts no stall in `hub_fault`. A hub before 1.284 sends no `stalls`, and the answer has none.
public struct HubDiagnostics: Decodable, Sendable, Equatable {
    /// The hub feature that carries the route, in `ui_features`.
    public static let feature = "diagnostics"
    /// The most that the "Hub errors" row says, as the "Checks" row (`FleetTrouble.reportLine`).
    public static let mostWords = 420

    public struct Frame: Decodable, Sendable, Equatable {
        public let file: String
        public let line: Int
        public init(file: String, line: Int) { self.file = file; self.line = line }
        /// A frame outside the hub's code: it names no file and no line.
        public var isLibrary: Bool { file == "lib" }
    }

    public struct Fault: Decodable, Sendable, Equatable {
        public let program: String
        public let kind: String
        public let frames: [Frame]
        public let errno: Int?
        public let http: Int?
        public let count: Int
        public let first: Double
        public let last: Double

        enum CodingKeys: String, CodingKey { case program, kind = "class", frames, errno, http, count, first, last }

        public init(program: String = "hub", kind: String, frames: [Frame], errno: Int? = nil, http: Int? = nil,
                    count: Int, first: Double, last: Double) {
            self.program = program; self.kind = kind; self.frames = frames; self.errno = errno; self.http = http
            self.count = count; self.first = first; self.last = last
        }
    }

    public struct Refusal: Decodable, Sendable, Equatable {
        public let tool: String
        public let file: String
        public let line: Int
        public let count: Int
        public let first: Double
        public let last: Double

        public init(tool: String, file: String, line: Int, count: Int, first: Double, last: Double) {
            self.tool = tool; self.file = file; self.line = line; self.count = count; self.first = first; self.last = last
        }
    }

    /// A time when the hub's threads waited, with the places of the thread that held them; `kind` is one of
    /// `stallKinds`, which the rows all say as "Stall".
    public struct Stall: Decodable, Sendable, Equatable {
        public let kind: String
        public let frames: [Frame]
        public let count: Int
        public let first: Double
        public let last: Double

        public init(kind: String, frames: [Frame], count: Int, first: Double, last: Double) {
            self.kind = kind; self.frames = frames; self.count = count; self.first = first; self.last = last
        }
    }

    public let faults: [Fault]
    public let refusals: [Refusal]
    public let stalls: [Stall]
    public let db: String?

    public init(faults: [Fault], refusals: [Refusal], stalls: [Stall] = [], db: String? = nil) {
        self.faults = faults; self.refusals = refusals; self.stalls = stalls; self.db = db
    }

    enum CodingKeys: String, CodingKey { case faults, refusals, stalls, db }

    /// `stalls` may be missing (a hub before 1.284); a value of the wrong type drops the whole answer, as for the rest.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        faults = try values.decode([Fault].self, forKey: .faults)
        refusals = try values.decode([Refusal].self, forKey: .refusals)
        stalls = try values.decodeIfPresent([Stall].self, forKey: .stalls) ?? []
        db = try values.decodeIfPresent(String.self, forKey: .db)
    }

    // ------------------------------------------------------------ shapes

    /// ASCII with no line break, and the whole text in the pattern: `\z`, because ICU's `$` also matches before a final
    /// line break, which would then reach the lines of the mail (the review of 14 November 2026).
    /// `NSRegularExpression`, so that the same ICU rules hold on every macOS (the review of 14 November 2026: the
    /// `String` search refused a final line break on one release where `NSRegularExpression` takes it).
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard text.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.newlines.contains($0) }),
              let expression = try? NSRegularExpression(pattern: "^(?:\(pattern))\\z") else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    /// The hub's program files, as `publish.TAKEN` names them on 14 November 2026. A frame in any other file is shown as
    /// `lib`: a file name is a word that a wrong hub could choose. A file that a later hub adds shows as `lib` until
    /// this list has it.
    static let files: Set<String> = [
        "acp_programs.py", "acp_runner.py", "channels.py", "desktop.py", "diagnostics.py", "door.py", "door_providers.py",
        "door_render.py", "door_targets.py", "fleet.py", "gate.py", "google.py", "hidden.py", "hook_clean.py",
        "hook_hosts.py", "hub.py", "hubsetup.py", "lifecycle.py", "mcp.py", "oauth_server.py", "onboard.py", "ops.py",
        "owner_mcp.py", "pins.py", "place.py", "prices.py", "push.py", "releases.py", "screen_runner.py", "selftest.py",
        "server.py", "thread_door.py", "threads.py", "usage.py", "vault.py", "verify.py", "verify_case.py", "wakeups.py",
        "worker_install.py"]
    /// A file of the hub's code tree as the hub names it, or `lib`.
    static func isFile(_ text: String) -> Bool {
        text == "lib" || (text.count <= 330 && !text.contains("..")
            && matches(text, #"[A-Za-z0-9_][A-Za-z0-9_.-]{0,79}(/[A-Za-z0-9_][A-Za-z0-9_.-]{0,79}){0,3}\.py"#))
    }
    /// The exception classes that a fault may name: the list of the hub's `diagnostics.CLASSES`. A hub that names
    /// another class, also one that a later hub knows, is shown as `other`: a class name is a word that code chooses.
    static let classes: Set<String> = [
        "ArithmeticError", "AssertionError", "AttributeError", "BlockingIOError", "BrokenPipeError", "BufferError",
        "CalledProcessError", "ChildProcessError", "ConnectionAbortedError", "ConnectionError", "ConnectionRefusedError",
        "ConnectionResetError", "DatabaseError", "EOFError", "FileExistsError", "FileNotFoundError", "HTTPError",
        "ImportError", "IncompleteRead", "IndexError", "IntegrityError", "InterfaceError", "InterruptedError",
        "IsADirectoryError", "JSONDecodeError", "KeyError", "LookupError", "MemoryError", "ModuleNotFoundError",
        "NameError", "NotADirectoryError", "NotImplementedError", "OSError", "OperationalError", "OverflowError",
        "PermissionError", "ProcessLookupError", "ProgrammingError", "RecursionError", "RemoteDisconnected",
        "RuntimeError", "SSLError", "StopIteration", "SubprocessError", "TimeoutError", "TimeoutExpired", "ToolError",
        "TypeError", "URLError", "UnboundLocalError", "UnicodeDecodeError", "UnicodeEncodeError", "UnicodeError",
        "ValueError", "ZeroDivisionError"]
    /// The kinds of a stall that the hub names (diagnostics.STALLS). Another kind drops its stall: a kind is a word.
    public static let stallKinds: Set<String> = ["busy", "hold", "collect", "paused"]
    /// A tool of the hub's list: lower-case words with "_", and `other`.
    static func isTool(_ text: String) -> Bool { matches(text, #"[a-z][a-z0-9_]{0,63}"#) }
    private static func isLine(_ line: Int) -> Bool { (0..<10_000_000).contains(line) }
    private static func isCount(_ count: Int) -> Bool { (1...1_000_000_000).contains(count) }

    /// Only the entries whose every value has its shape, and a class off the list as `other`. A library frame has line 0;
    /// a fault has 1 to 12 frames.
    public func checked() -> HubDiagnostics {
        let faults = faults.filter { fault in
            fault.program == "hub" && Self.isCount(fault.count)
                && (1...12).contains(fault.frames.count)
                && fault.frames.allSatisfy { Self.isFile($0.file) && Self.isLine($0.line) && (!$0.isLibrary || $0.line == 0) }
                && fault.errno.map { (0...100_000).contains($0) } ?? true
                && fault.http.map { (100...599).contains($0) } ?? true
        }.map { fault in
            Fault(program: fault.program, kind: Self.classes.contains(fault.kind) ? fault.kind : "other",
                  frames: fault.frames.map { Self.files.contains($0.file) ? $0 : Frame(file: "lib", line: 0) },
                  errno: fault.errno, http: fault.http, count: fault.count, first: fault.first, last: fault.last)
        }
        let refusals = refusals.filter {
            Self.isTool($0.tool) && Self.isFile($0.file) && Self.isLine($0.line) && Self.isCount($0.count)
        }.map {
            Self.files.contains($0.file) ? $0
                : Refusal(tool: $0.tool, file: "lib", line: 0, count: $0.count, first: $0.first, last: $0.last)
        }
        let stalls = stalls.filter { stall in
            Self.stallKinds.contains(stall.kind) && Self.isCount(stall.count) && (1...12).contains(stall.frames.count)
                && stall.frames.allSatisfy { Self.isFile($0.file) && Self.isLine($0.line) && (!$0.isLibrary || $0.line == 0) }
        }.map { stall in
            Stall(kind: stall.kind, frames: stall.frames.map { Self.files.contains($0.file) ? $0 : Frame(file: "lib", line: 0) },
                  count: stall.count, first: stall.first, last: stall.last)
        }
        return HubDiagnostics(faults: Array(faults.prefix(20)), refusals: Array(refusals.prefix(20)),
                              stalls: Array(stalls.prefix(20)), db: db)
    }

    // ------------------------------------------------------------ the lines, which the app writes itself

    /// "once", "2 times".
    static func times(_ count: Int, capital: Bool = false) -> String {
        count == 1 ? (capital ? "Once" : "once") : "\(count) times"
    }

    /// "KeyError", "HTTPError 503", "OSError errno 13".
    static func name(_ fault: Fault) -> String {
        if let http = fault.http { return "\(fault.kind) \(http)" }
        if let errno = fault.errno { return "\(fault.kind) errno \(errno)" }
        return fault.kind
    }

    /// A stall as the rows say it: a fault named "Stall", with no errno and no HTTP status.
    static func asFault(_ stall: Stall) -> Fault {
        Fault(kind: "Stall", frames: stall.frames, count: stall.count, first: stall.first, last: stall.last)
    }

    /// What the rows say as errors: the hub's faults, then its stalls.
    var errors: [Fault] { faults + stalls.map(Self.asFault) }

    /// The frames in the hub's code, the innermost first.
    static func places(_ fault: Fault) -> [Frame] { fault.frames.reversed().filter { !$0.isLibrary } }

    /// **C0, the "Last error" row:** "KeyError at hub.py 31761, from hub.py 32044. 3 times." The place where it was
    /// raised, the place that called it, and how many times.
    public static func lastError(_ fault: Fault) -> String {
        let places = places(fault)
        var line = name(fault)
        if let at = places.first { line += " at \(at.file) \(at.line)" }
        if places.count > 1 { line += ", from \(places[1].file) \(places[1].line)" }
        line += ". " + times(fault.count, capital: true) + "."
        return line.count <= mostWords ? line : String(line.prefix(mostWords - 1)) + "…"     // the site takes 500 at most
    }

    /// One fault of the "Hub errors" row: "KeyError at hub.py 31761, 3 times".
    static func item(_ fault: Fault) -> String {
        let at = places(fault).first.map { " at \($0.file) \($0.line)" } ?? ""
        return name(fault) + at + ", " + times(fault.count)
    }

    /// One refused call of the "Hub errors" row: "send_message at hub.py 28470, 2 times".
    static func item(_ refusal: Refusal) -> String {
        refusal.file == "lib" ? "\(refusal.tool), \(times(refusal.count))"
            : "\(refusal.tool) at \(refusal.file) \(refusal.line), \(times(refusal.count))"
    }

    /// **E3, the "Hub errors" row:** "KeyError at hub.py 31761, 3 times. TimeoutError at hub.py 41190, once. Refused:
    /// send_message at hub.py 28470, 2 times." At most `mostWords` characters: what does not fit is counted.
    public var errorsLine: String? {
        let faultItems = errors.map(Self.item)
        let refusalItems = refusals.map(Self.item)
        guard !faultItems.isEmpty || !refusalItems.isEmpty else { return nil }
        var line = "", shown = 0
        let room = Self.mostWords - 16          // the room that "; +99 more." needs
        for (index, item) in faultItems.enumerated() {
            let next = (index == 0 ? "" : ". ") + item
            guard line.count + next.count <= room else { break }
            line += next; shown += 1
        }
        if shown == faultItems.count {
            for (index, item) in refusalItems.enumerated() {
                let next = (index == 0 ? (line.isEmpty ? "Refused: " : ". Refused: ") : "; ") + item
                guard line.count + next.count <= room else { break }
                line += next; shown += 1
            }
        }
        let more = faultItems.count + refusalItems.count - shown
        return line + (more > 0 ? (line.isEmpty ? "" : "; ") + "+\(more) more." : ".")
    }

    /// **Which row says it, so that one error never shows two times:** one fault or stall and no refused call, while
    /// this Mac has no error of its own, goes in "Last error" (C0); anything more goes in "Hub errors" (E3), as a list.
    /// The warning kinds that Report a problem leaves out of its findings and its Checks line, because one of these
    /// rows says the same faults: one error, said once. Rows that say only stalls say no fault, and the hub counts no
    /// stall in `hub_fault`, so its warning stays.
    public func said(_ rows: (lastError: String?, hubErrors: String?)) -> Set<String> {
        (rows.lastError ?? rows.hubErrors) == nil || faults.isEmpty && refusals.isEmpty ? [] : ["hub_fault"]
    }

    /// A line that looks like it holds a key is not shown and not sent: the shapes leave no room for one, and this is
    /// the last word (`KeyInText`, the guard of the chat's composer).
    public func rows(macHasItsOwnError: Bool) -> (lastError: String?, hubErrors: String?) {
        let safe = { (line: String?) in line.flatMap { KeyInText.contains($0) ? nil : $0 } }
        if errors.count == 1, refusals.isEmpty, !macHasItsOwnError { return (safe(Self.lastError(errors[0])), nil) }
        return (nil, safe(errorsLine))
    }
}
