import Foundation

/// **The MCP server on standard input and output**: one JSON message a line, as a local MCP server speaks, answered as
/// `owner_mcp.py`'s `rpc` answers. A tools/call waits in one queue and the calls run one at a time, in the order of
/// reading; every other request gets its answer at once, also while a call runs, so a `ping` is answered then too. A
/// notification (no id) gets no answer. This version sends no progress and takes no cancel: a call waits only for the
/// lock (one request of another command) and for a few requests to the hub of 60 seconds each, or of 15 minutes at
/// most for the one file of `attach_file`, `read_attachment` and `take_backup` (`Transfer`), under the 30 minutes after
/// which Claude Code ends a call with no progress.
public final class OwnerMCP: @unchecked Sendable {
    let tools: OwnerTools
    let version: String
    private let sink: @Sendable (String) -> Void
    private let output = NSLock()
    private let calls = DispatchQueue(label: "founderizer.cli.calls")

    static let empty = ["resources/list": "resources", "resources/templates/list": "resourceTemplates",
                        "prompts/list": "prompts"]

    /// `sink`: one line of output, with no new line at its end.
    public init(tools: OwnerTools, version: String, sink: @escaping @Sendable (String) -> Void) {
        self.tools = tools
        self.version = version
        self.sink = sink
    }

    /// One message on one line of the output, never two on one line.
    func say(_ message: JSONValue) {
        output.lock()
        defer { output.unlock() }
        sink(message.dumps())
    }

    /// One line that the client wrote.
    public func take(line: String) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let message = JSONValue.parse(line) else {
            say(.object(["jsonrpc": .string("2.0"), "id": .null,
                         "error": .object(["code": .int(-32700), "message": .string("Parse error")])]))
            return
        }
        if message.array?.isEmpty == true {                 // an empty batch is no request at all
            say(Self.invalid(.null))
            return
        }
        let batch = message.array != nil
        // Each request gets an answer, and each message that is not one gets "Invalid Request" (-32600), so that no
        // client waits for an answer that never comes: a message with an id and no method, a method that is not a
        // string, and an element of a batch that is no object. A client's own response (no method, and a `result` or
        // an `error`), a message with neither id nor method, and a notification get nothing: a response is never
        // answered, as `owner_mcp.py` answers none.
        var work: [(request: JSONValue?, id: JSONValue)] = []
        for one in message.array ?? [message] {
            guard one.object != nil else { work.append((nil, .null)); continue }
            let id = one["id"] ?? .null
            let method = one["method"]
            if method == nil && (id.isNull || one["result"] != nil || one["error"] != nil) { continue }
            guard case .string? = method else { work.append((nil, id)); continue }
            if !id.isNull { work.append((one, id)) }
        }
        guard !work.isEmpty else { return }
        let items = work
        let answer: @Sendable () -> Void = { [self] in
            let answers = items.map { $0.request.map(rpc) ?? Self.invalid($0.id) }
            say(batch ? .array(answers) : answers[0])
        }
        if items.contains(where: { $0.request?["method"]?.string == "tools/call" }) {
            calls.async(execute: answer)
        } else {
            answer()
        }
    }

    static func invalid(_ id: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .int(-32600), "message": .string("Invalid Request")])])
    }

    /// The end of the input: the calls that were read run to their end first.
    public func finish() {
        calls.sync {}
    }

    /// One JSON-RPC request, answered.
    public func rpc(_ message: JSONValue) -> JSONValue {
        let id = message["id"] ?? .null
        let method = message["method"]?.string ?? ""
        let params = message["params"]?.object ?? [:]
        func result(_ value: JSONValue) -> JSONValue {
            .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
        }
        switch method {
        case "initialize":
            let want = params["protocolVersion"]?.string
            let chosen = want.flatMap { tools.table.supported.contains($0) ? $0 : nil } ?? tools.table.protocolVersion
            return result(.object([
                "protocolVersion": .string(chosen),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("founderizer"), "title": .string("Founderizer"),
                                       "version": .string(version)]),
                "instructions": .string(tools.table.instructions),
            ]))
        case "ping", "logging/setLevel":
            return result(.object([:]))
        case "tools/list":
            return result(.object(["tools": .array(tools.listed.map {
                .object(["name": .string($0.name), "description": .string($0.description),
                         "inputSchema": $0.inputSchema, "annotations": $0.annotations])
            })]))
        case "tools/call":
            let name = params["name"]?.pythonText ?? "None"
            let (text, isError) = tools.call(name, params["arguments"])
            return result(.object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                                   "isError": .bool(isError)]))
        default:
            if let key = Self.empty[method] { return result(.object([key: .array([])])) }
            return .object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object(["code": .int(-32601), "message": .string("Method not found: \(method)")])])
        }
    }
}
