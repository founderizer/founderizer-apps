import Foundation

/// **`prepare_problem_report`: the owner's own agent writes a problem report, and the owner sends it** (the owner, 15
/// November 2026: "does admin mcp have some sort of bug_report tool call so we can receive them somehow?", and "Yes,
/// build both" to the proposal). A tool of the link, in the set `owner`, and a write (`readOnlyHint` false).
///
/// **It sends nothing.** The app opens its own window Report a problem with the agent's text in its box, beside the
/// facts that the app adds itself, and it marks the report as written by the agent (one more fact, on the screen with
/// the others). The owner reads it, gives the address for the answer and presses Send, as for a report of their own.
/// So the rule of that form stays whole: nothing travels that the owner has not read (`ProblemReport` in FleetCore).
/// A tool that sent a report by itself would let a client that asks nothing send text that the owner never saw.
///
/// **What a process of the owner's user can do with it** (each one can start the program): put a text of its own
/// into the report form and bring that window to the front. It cannot send it, it cannot write over text that the
/// owner wrote there, and a text that holds something like a key is refused before it shows.
public enum PrepareReport {
    public static let name = "prepare_problem_report"
    public static let fields = ["text"]
    /// The longest text of a report: the form's own bound (`ProblemReport.maxText` in FleetCore, which this library
    /// does not link; a test holds the two equal). **This tool counts it in UTF-16 units**, as the website does, so
    /// that a text which the tool takes is never one that the website refuses for its length; the form counts
    /// characters, which is never more. It also keeps the request far under the link's bound for a request line.
    public static let maxText = 4000
    /// The shortest text: a report of a few letters says nothing, and the form knows an agent's text in the box by
    /// the text itself, which a few letters cannot carry.
    public static let minText = 20

    public static let tool = OwnerTable.Tool(
        name: name, description: """
            Prepares a problem report for the makers of Founderizer in the Founderizer app's own form, and sends \
            nothing. text: what went wrong, what you tried and what the tools answered, in plain words, in 20 to \
            4000 characters. Put no key, no token and no password in it, and nothing of the fleet's work (no task, no \
            message, no file). The app opens its window Report a problem with this text in its box, adds its own \
            facts (the versions, the page's name, the last error, its checks), and marks the report as written by \
            the owner's agent. Only the owner sends it: they read it, give the address for the answer and press \
            Send. So tell the owner that the window is open and what it is for. The app refuses a text that holds \
            something like a key, and it never writes over text that the owner wrote in that form. The window takes \
            no key press until the owner clicks in it. Use this tool when a step fails and neither you nor the owner \
            can put it right; read fleet_read with page diagnostics first, for the hub's own record of its faults. \
            It answers shown true.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["text": .object(["type": .string("string")])]),
            "required": .array([.string("text")]),
            "additionalProperties": .bool(false),
        ]),
        annotations: .object(["readOnlyHint": .bool(false)]), kind: .swift, route: "", fields: [], what: name,
        revisionPage: nil, requestIDFromArguments: false, feature: nil)

    // The fixed sentences: each names only the tool's own field, and none quotes anything that the caller sent.
    static let only = "prepare_problem_report takes text, and no other field. Nothing was shown."
    static let textWord = "text must be what went wrong, in plain words, in 20 to 4000 characters. Nothing was shown."
    static let noPart = "prepare_problem_report takes no part after its request line. Nothing was shown."
    static let holdsKey = "The text holds something that looks like a key, a token or a password. A report never "
        + "carries a secret: take it out, and call again. Nothing was shown."
    static let ownText = "The report form holds text that the owner wrote, and this tool never writes over it. The "
        + "owner sends that report or clears the box first. Nothing was changed."
    static let noWindow = "The Founderizer app cannot open its report window now. The owner opens it: Help, Report a "
        + "problem. Nothing was shown."
    static let ended = "Another report took the place of this one, or the call ended before the form took the text. "
        + "Ask the owner whether the window Report a problem shows your text."
    /// The program's words when the request went out and no answer came.
    public static let notKnownHere = "Whether the app showed the report is not known: the link ended before its "
        + "answer. Nothing is sent by this tool. Ask the owner whether the window Report a problem shows your text."

    /// **The text of a call**, as the program and the app read it: the one field, a string, with no white space at
    /// its ends, of `minText` characters or more and of at most `maxText` UTF-16 units.
    public static func read(_ fields: [String: JSONValue]) -> Result<String, OwnerChannel.Refusal> {
        guard fields.keys.allSatisfy({ $0 == "text" }) else { return .failure(.init(only)) }
        guard case .string(let given)? = fields["text"] else { return .failure(.init(textWord)) }
        let text = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minText, text.utf16.count <= maxText else { return .failure(.init(textWord)) }
        return .success(text)
    }

    /// How the app's form took the text.
    public enum Outcome: Equatable, Sendable {
        /// The form shows the text.
        case shown
        /// The form holds text that the owner wrote: nothing changed.
        case ownText
        /// The app has no way to open the window now.
        case noWindow
        /// Another ask took this one's place, or the call ended.
        case ended
    }

    /// **The app's part**, as closures: the library links no AppKit and not FleetCore.
    public struct Desk: Sendable {
        /// Whether the text holds something that looks like a key (the form's own check, `KeyInText`).
        public var holdsKey: @Sendable (String) -> Bool
        /// Puts the text into the report form and brings its window to the front.
        public var show: @Sendable (String) async -> Outcome

        public init(holdsKey: @escaping @Sendable (String) -> Bool, show: @escaping @Sendable (String) async -> Outcome) {
            self.holdsKey = holdsKey
            self.show = show
        }
    }

    /// **The app's answer**: the field's form, then the key check, and only then the form. A call that ended before
    /// the form is asked shows nothing.
    public static func answer(fields: [String: JSONValue], value: OwnerChannel.Value?, desk: Desk) async -> OwnerChannel.Answer {
        guard value == nil else { return .refused(noPart) }
        let text: String
        switch read(fields) {
        case .failure(let refusal): return .refused(refusal.text)
        case .success(let read): text = read
        }
        guard !desk.holdsKey(text) else { return .refused(holdsKey) }
        guard !Task.isCancelled else { return .refused(ended) }
        switch await desk.show(text) {
        case .shown: return .result(.object(["shown": .bool(true)]))
        case .ownText: return .refused(ownText)
        case .noWindow: return .refused(noWindow)
        case .ended: return .refused(ended)
        }
    }
}
