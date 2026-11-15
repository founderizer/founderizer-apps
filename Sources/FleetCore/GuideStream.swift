#if os(macOS)
import Foundation

// The onboarding guide: the reader of what the provider's program prints (`~/dev/founderizer-plans/
// onboarding-guide-spec.md`, section 3.2, lane S). The guide is the owner's own Claude Code in the first run's window.
// **Nothing in the app starts it: these files have no caller, and the first run is as it was** (`GuideSwitch`).
//
// Claude Code with `--output-format stream-json` prints one JSON object on each line. This file turns a line into
// typed events and reads nothing else. It keeps no text of the program but the guide's own words: a path, an account
// and a number of a limit stay out of an event.

/// What the program says at the start of each turn, in its `system/init` line: what the model has in this turn. The
/// runner holds each one to what it started (`GuideCheck`).
public struct GuideTurnStart: Equatable, Sendable {
    public struct Server: Equatable, Sendable {
        public let name: String
        public let status: String
        public init(name: String, status: String) { self.name = name; self.status = status }
    }

    /// The exact name of each tool that the model can call.
    public let tools: [String]
    public let servers: [Server]
    /// `claude_code_version`.
    public let version: String
    /// Whether the line names a socket of the program's own, through which another Claude Code session on this Mac
    /// can write into this one (`messaging_socket_path`). The path itself is not kept.
    public let hasMessagingSocket: Bool

    public init(tools: [String], servers: [Server], version: String, hasMessagingSocket: Bool = false) {
        self.tools = tools; self.servers = servers; self.version = version; self.hasMessagingSocket = hasMessagingSocket
    }
}

/// How a turn ended.
public enum GuideTurnEnd: Equatable, Sendable {
    case done
    /// The app cut it (`GuideRuntime.interrupt`).
    case interrupted
    /// It ended on a limit or on a sign-in that is gone: the event before this one says which.
    case failed
}

/// Why the runner stopped the program, or why the program ended. Each case is a fixed kind: no text of the program.
public enum GuideStop: Equatable, Sendable {
    /// The model's tool list is not the guide's list: names that are not on it, and names of it that are missing.
    case tools(unlisted: [String], missing: [String])
    /// The MCP servers are not exactly the helper, connected.
    case servers
    /// The program is not the version that the app started.
    case version
    /// The program's own socket for other sessions is open.
    case socket
    /// A turn began that the app did not ask for.
    case unasked
    /// The model spoke or called a tool before a start of the turn passed the check.
    case unchecked
    /// The program reported an error of this kind (its own fixed word, such as `error_during_execution`).
    case failed(String)
    /// The program ended by itself, with this status.
    case exited(Int32)
    /// A resume failed before its first turn began: the program refused it (it has no session of that id for the
    /// folder), so the app starts a new session.
    case resumeRefused
}

/// One event of the guide's session, in the order of the program's lines.
public enum GuideEvent: Equatable, Sendable {
    /// A turn began, and its start passed the check.
    case turnStarted
    /// Words of the guide.
    case words(String)
    /// A tool call that started: the tool's whole name, as the program gives it.
    case toolCall(id: String, name: String)
    case turnEnded(GuideTurnEnd)
    /// The owner's plan is at its limit, or the program waits to try again because of it.
    case limit(resetsAt: Date?)
    case notSignedIn
    /// The program took the message for a command of its own and answered it with no call of the model. Its answer
    /// is not the guide's words, and nothing of it is drawn.
    case ownAnswer
    /// The program took the app's interrupt.
    case interruptTaken
    /// The end of this session's program. No event comes after it.
    case stopped(GuideStop)
    /// The program ended after the app's own quit. No event comes after it.
    case ended
}

/// One line of the program, as the runner needs it: the events of a line, and the start of a turn apart, because the
/// runner checks that one before it lets anything through.
public enum GuideLine: Equatable, Sendable {
    case start(GuideTurnStart)
    case events([GuideEvent])
}

public enum GuideStream {
    /// **One printed line as events.** A line that is no JSON object, and a line of a type that this reader does not
    /// know, give nothing: a later version's new line breaks nothing.
    public static func read(_ line: String) -> GuideLine {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return .events([]) }
        switch type {
        case "system": return system(object)
        case "assistant": return .events(assistant(object))
        case "rate_limit_event": return .events(rateLimit(object["rate_limit_info"] as? [String: Any] ?? [:]))
        case "result": return .events(result(object))
        case "control_response":
            let response = object["response"] as? [String: Any]
            return .events(response?["subtype"] as? String == "success" ? [.interruptTaken] : [])
        default: return .events([])
        }
    }

    private static func system(_ object: [String: Any]) -> GuideLine {
        switch object["subtype"] as? String {
        case "init":
            let servers = (object["mcp_servers"] as? [[String: Any]] ?? []).map {
                GuideTurnStart.Server(name: $0["name"] as? String ?? "", status: $0["status"] as? String ?? "")
            }
            let socket = (object["messaging_socket_path"] as? String).map { !$0.isEmpty } ?? false
            return .start(GuideTurnStart(tools: object["tools"] as? [String] ?? [], servers: servers,
                                         version: object["claude_code_version"] as? String ?? "",
                                         hasMessagingSocket: socket))
        case "api_retry":
            // The program waits and tries the model again. Only two of its fixed causes are the owner's to know.
            return .events(known(error: object["error"] as? String) ?? [])
        default: return .events([])
        }
    }

    private static func assistant(_ object: [String: Any]) -> [GuideEvent] {
        // A line with `error` holds the program's own words for it ("Not logged in"), not the guide's.
        if let error = object["error"] as? String { return known(error: error) ?? [] }
        let message = object["message"] as? [String: Any] ?? [:]
        // The program's own answer to a message that it took for a command: no model wrote it.
        if object["local_command_outcome"] != nil || message["model"] as? String == "<synthetic>" { return [.ownAnswer] }
        var events: [GuideEvent] = []
        for part in message["content"] as? [[String: Any]] ?? [] {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String, !text.isEmpty { events.append(.words(text)) }
            case "tool_use":
                if let id = part["id"] as? String, let name = part["name"] as? String {
                    events.append(.toolCall(id: id, name: name))
                }
            default: break
            }
        }
        return events
    }

    /// `rate_limit_event`. The program's own statuses are `allowed`, `allowed_warning` and `rejected` (read in the
    /// file of 2.1.312): the first two let the turn go on, so they are no limit. Each other word is one.
    private static func rateLimit(_ info: [String: Any]) -> [GuideEvent] {
        guard let status = info["status"] as? String, !["allowed", "allowed_warning"].contains(status) else { return [] }
        return [.limit(resetsAt: seconds(info["resetsAt"]))]
    }

    private static func result(_ object: [String: Any]) -> [GuideEvent] {
        guard object["is_error"] as? Bool == true else { return [.turnEnded(.done)] }
        let error = object["error"] as? String
        if let events = known(error: error) { return events + [.turnEnded(.failed)] }
        if object["api_error_status"] as? Int == 429 { return [.limit(resetsAt: nil), .turnEnded(.failed)] }
        // A turn that the app cut ends as an error of the run, with a reason that says "aborted".
        if (object["terminal_reason"] as? String)?.hasPrefix("aborted") == true { return [.turnEnded(.interrupted)] }
        return [.stopped(.failed(kind(error ?? object["subtype"] as? String)))]
    }

    /// The two causes that are the owner's to know, by the program's own fixed words; nil for each other one.
    private static func known(error: String?) -> [GuideEvent]? {
        switch error {
        case "rate_limit": [.limit(resetsAt: nil)]
        case "authentication_failed": [.notSignedIn]
        default: nil
        }
    }

    /// A fixed word of the program as a kind: small letters, digits and "_", 40 at most. Never a sentence.
    static func kind(_ word: String?) -> String {
        let kept = (word ?? "").lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
        let kind = String(String.UnicodeScalarView(kept.prefix(40)))
        return kind.isEmpty ? "unknown" : kind
    }

    private static func seconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
}

/// **The check at each turn** (section 3.2). The program prints what the model has at the start of each turn, and the
/// runner stops the program at once when that is not what the app started: one tool more or less, another MCP server,
/// another version, or the program's own socket for other sessions.
public struct GuideCheck: Equatable, Sendable {
    /// The helper's name in the MCP configuration, and so in each tool's whole name.
    public static let server = "founderizer"

    /// The whole name of each tool of the session's list (`mcp__founderizer__<name>`).
    public let tools: Set<String>
    public let version: String

    public init(tools: [String], version: String) {
        self.tools = Set(tools.map(Self.whole))
        self.version = version
    }

    /// A tool's name as the program gives it to the model.
    public static func whole(_ tool: String) -> String { "mcp__\(server)__\(tool)" }

    /// Why this start of a turn stops the program, or nil when it is what the app started. The other parts of the line
    /// (built-in agent types, plug-ins) are not the same at each start of one version, and the model has no tool for
    /// them: the check does not read them.
    public func stop(for start: GuideTurnStart) -> GuideStop? {
        let has = Set(start.tools)
        if has != tools {
            return .tools(unlisted: has.subtracting(tools).sorted(), missing: tools.subtracting(has).sorted())
        }
        guard start.servers.count == 1, start.servers[0].name == Self.server, start.servers[0].status == "connected" else {
            return .servers
        }
        if start.version != version { return .version }
        if start.hasMessagingSocket { return .socket }
        return nil
    }
}
#endif
