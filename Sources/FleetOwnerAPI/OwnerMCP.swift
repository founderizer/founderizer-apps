import Foundation

/// **The MCP server on standard input and output**: one JSON message a line, as a local MCP server speaks, answered as
/// `owner_mcp.py`'s `rpc` answers. A tools/call waits in one queue and the calls run one at a time, in the order of
/// reading; every other request gets its answer at once, also while a call runs, so a `ping` is answered then too. A
/// notification (no id) gets no answer. This version sends no progress: a call waits only for the lock (one request
/// of another command) and for a few requests to the hub of 60 seconds each, or of 15 minutes at most for the one file
/// of `attach_file` and `read_attachment` and 25 minutes for the copy of `take_backup` (`Transfer`), under the 30
/// minutes after which Claude Code ends a call with no progress; a call of a cloud tool runs a few commands of the
/// cloud's program of 120 seconds each.
///
/// **A cancel** (MCP's `notifications/cancelled`, which a client sends at the owner's Esc or at its own time limit), as
/// `owner_mcp.py`'s `Calls` takes it: a call that waits never starts, a call that runs starts no other command of a
/// cloud's program (`OwnerCloud`), and a cancelled request gets no answer. A command that ran at the cancel goes on to
/// its end. A cancel marks only the requests that this server holds (each request of a message with a tools/call, from
/// its reading to its answer step), as `Calls.cancel`: a cancel of a request that it does not hold, one that came
/// before its request or after its answer, changes nothing.
public final class OwnerMCP: @unchecked Sendable {
    let tools: OwnerTools
    let version: String
    private let sink: @Sendable (String) -> Void
    private let output = NSLock()
    private let calls = DispatchQueue(label: "founderizer.cli.calls")
    private let cancels = NSLock()
    /// Each request that this server holds, by a number of its own: the text of its id, and whether the client
    /// cancelled it. Two held requests with one id are two entries, as `Calls.held` holds them.
    private var held: [Int: (key: String, cancelled: Bool)] = [:]
    private var lastHeld = 0

    /// How many requests this server holds now: none once each one had its answer step (a test reads it).
    var holding: Int {
        cancels.lock()
        defer { cancels.unlock() }
        return held.count
    }

    /// Whether the client cancelled the held request `number`.
    func isCancelled(_ number: Int) -> Bool {
        cancels.lock()
        defer { cancels.unlock() }
        return held[number]?.cancelled ?? false
    }

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
        let named = (message.array ?? [message]).compactMap { one -> String? in
            guard one["method"]?.string == "notifications/cancelled", let id = one["params"]?["requestId"], !id.isNull
            else { return nil }
            return id.dumps()
        }
        // Each request gets an answer, and each message that is not one gets "Invalid Request" (-32600), so that no
        // client waits for an answer that never comes: a message with an id and no method, a method that is not a
        // string, and an element of a batch that is no object. A client's own response (no method, and a `result` or
        // an `error`), a message with neither id nor method, and a notification get nothing: a response is never
        // answered, as `owner_mcp.py` answers none.
        var work: [(request: JSONValue?, id: JSONValue, number: Int?)] = []
        for one in message.array ?? [message] {
            guard one.object != nil else { work.append((nil, .null, nil)); continue }
            let id = one["id"] ?? .null
            let method = one["method"]
            if method == nil && (id.isNull || one["result"] != nil || one["error"] != nil) { continue }
            guard case .string? = method else { work.append((nil, id, nil)); continue }
            if !id.isNull { work.append((one, id, nil)) }
        }
        let queued = work.contains { $0.request?["method"]?.string == "tools/call" }
        cancels.lock()
        if queued {                         // its requests are held, before the cancels: one can name a request of it
            for index in work.indices where work[index].request != nil {
                lastHeld += 1
                held[lastHeld] = (work[index].id.dumps(), false)
                work[index].number = lastHeld
            }
        }
        for key in named {
            for (number, one) in held where one.key == key { held[number]?.cancelled = true }
        }
        cancels.unlock()
        guard !work.isEmpty else { return }
        let items = work
        let answer: @Sendable () -> Void = { [self] in
            // A cancelled request is not started, and gets no answer, also when its cancel came while it ran.
            var answers: [(said: JSONValue, number: Int?)] = []
            for item in items {
                guard let request = item.request else {
                    answers.append((Self.invalid(item.id), nil))
                    continue
                }
                let number = item.number
                if let number, isCancelled(number) { continue }
                answers.append((rpc(request, cancelled: { [self] in number.map(isCancelled) ?? false }), number))
            }
            // The answer step ends the hold of these requests, as `Calls.work` ends it.
            cancels.lock()
            let said = answers.filter { $0.number.map { held[$0]?.cancelled != true } ?? true }.map(\.said)
            for item in items { if let number = item.number { held[number] = nil } }
            cancels.unlock()
            guard !said.isEmpty else { return }
            say(batch ? .array(said) : said[0])
        }
        if queued {
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

    /// One JSON-RPC request, answered; `cancelled` says whether the client cancelled it while it runs.
    public func rpc(_ message: JSONValue, cancelled: @escaping @Sendable () -> Bool = { false }) -> JSONValue {
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
            return result(tools.callResult(name, params["arguments"], cancelled: cancelled))
        default:
            if let key = Self.empty[method] { return result(.object([key: .array([])])) }
            return .object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object(["code": .int(-32601), "message": .string("Method not found: \(method)")])])
        }
    }
}
