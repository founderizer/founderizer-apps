import Darwin
import Foundation

/// **Where the program is**: its own executable by its real path (so that it works when started through a link), the
/// app's bundle around it, the table of its tools in that bundle, and the builds that it compares.
public enum ProgramPlace {
    /// The real path of this process's executable, with every link resolved.
    public static func executable() -> URL {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        if _NSGetExecutablePath(&buffer, &size) != 0 {
            buffer = [CChar](repeating: 0, count: Int(size) + 1)
            _ = _NSGetExecutablePath(&buffer, &size)
        }
        let given = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: realPath(given) ?? given)
    }

    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The application bundle whose `Contents/MacOS` holds this executable, or nil for a build with no bundle.
    public static func bundle(of executable: URL) -> URL? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else { return nil }
        return bundle
    }

    /// The table of the tools: a resource of the app's bundle, or beside the executable for a test build.
    public static func table(for executable: URL) -> URL {
        if let bundle = bundle(of: executable) {
            return bundle.appendingPathComponent("Contents/Resources/owner-tools.json")
        }
        return executable.deletingLastPathComponent().appendingPathComponent("owner-tools.json")
    }

    /// One value of a bundle's Info.plist.
    public static func info(_ key: String, of bundle: URL) -> String? {
        let file = bundle.appendingPathComponent("Contents/Info.plist")
        // Only a regular file of at most 1 MiB is read: a pipe or a device in its place would hold the reader, and
        // the app reads this on its main thread for `setup_diagnosis`.
        guard let facts = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              facts.isRegularFile == true, let size = facts.fileSize, size <= 1024 * 1024,
              let data = try? Data(contentsOf: file), data.count <= 1024 * 1024,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist[key] as? String
    }

    public static func build(of bundle: URL) -> Int? { info("CFBundleVersion", of: bundle).flatMap { Int($0) } }

    /// **The path that the program was started by**: its first argument, made absolute and NOT resolved through links,
    /// so that it still names the place after an update swapped the bundle there (the link `~/.founderizer/cli`, or the
    /// path in Applications). A first argument with no "/" was found on `PATH`: the first folder of `PATH` that holds
    /// an executable of that name gives it.
    public static func startPath(argument: String, directory: String, path: String?) -> String? {
        guard !argument.isEmpty else { return nil }
        if argument.hasPrefix("/") { return argument }
        if argument.contains("/") { return URL(fileURLWithPath: directory).appendingPathComponent(argument).path }
        for folder in (path ?? "").split(separator: ":") where !folder.isEmpty {
            let candidate = URL(fileURLWithPath: String(folder), relativeTo: URL(fileURLWithPath: directory))
                .appendingPathComponent(argument).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The build of the bundle behind a start path now, through every link, or nil when the path is gone or has no
    /// application bundle behind it.
    public static func build(behind start: String?) -> Int? {
        guard let start, let real = realPath(start) else { return nil }
        return bundle(of: URL(fileURLWithPath: real)).flatMap(build(of:))
    }

    /// The link that the app keeps to its own program.
    public static func link(home: URL) -> URL {
        home.appendingPathComponent(".founderizer/cli")
    }

    /// The build of the app whose program the link points at now, or nil when there is no such link or app.
    public static func linkedBuild(home: URL) -> Int? {
        guard let target = realPath(link(home: home).path) else { return nil }
        return bundle(of: URL(fileURLWithPath: target)).flatMap(build(of:))
    }
}

/// **The program's calls**: `call`, `write`, `mcp --set owner`, `tools [name]`, `connect` and `guide`. `main` gives it this Mac;
/// a test gives its own context and its own input and output.
public enum OwnerCLI {
    public static let usage = """
        founderizer-cli: the Founderizer app's own program for an AI agent (Claude Code, Codex).
          founderizer-cli call <tool> ['<json object>']    one tool that only reads, from a shell
          founderizer-cli write <tool> ['<json object>']   one tool that writes, from a shell
          founderizer-cli mcp --set owner   an MCP server on standard input and output, with the fleet's admin tools
          founderizer-cli tools [name]      the tools: one line each, or one tool's words and fields in full
          founderizer-cli connect           the line that adds this program to Claude Code and to Codex
          founderizer-cli guide             the guide to set up a fleet, and the sign to the app that it started
        """

    /// Exit statuses: a refusal is 1, a wrong use of the program is 2.
    public static let refused: Int32 = 1
    public static let wrongUse: Int32 = 2

    /// The page of `fleet_read` that `call` leaves out: its QR links a WhatsApp account to the fleet, and the owner reads
    /// it in the app. The MCP form passes it with the other pages (plan 3.3, one accepted difference).
    public static let callLeavesOut = ("fleet_read", "chat_link")

    /// The setup tools of the plan's slice B (`setup_state`, `setup_show`, on the link to the running app) and the read
    /// `setup_diagnosis` join `call` here, by name: they change no fleet, no server and no file.
    public static let setupTools: [String] = OwnerSetupTools.names

    /// The allow rule for Claude Code that covers `call` alone: never one for `write`, `mcp` or the whole program.
    public static func callRule(path: String) -> String { "Bash(\(shellWord(path)) call:*)" }

    /// The text of a path for a shell line: as it is when it needs no quotes, else in single quotes.
    static func shellWord(_ path: String) -> String {
        let plain = path.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "/._-+@".unicodeScalars.contains($0)
        }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The path that a client's configuration names: the app's link `~/.founderizer/cli` as a whole path when it points
    /// at this program, because the link stays true when the app moves or updates; else this program's own real path.
    public static func connectPath(executable: URL, home: URL) -> String {
        let link = ProgramPlace.link(home: home)
        if let target = ProgramPlace.realPath(link.path), target == executable.path { return link.path }
        return executable.path
    }

    public static func connectLines(path: String) -> [String] {
        let word = shellWord(path)
        return ["claude mcp add --scope user founderizer -- \(word) mcp --set owner",
                "codex mcp add founderizer -- \(word) mcp --set owner"]
    }

    /// One run of the program. `input`: the next line of standard input, or nil at its end. `announce`: tells the
    /// running app that an agent started the guide (`OwnerGuide.announce` in `main`; a test's own, which posts
    /// nothing). `front`: then asks macOS to bring the app of this bundle to the front (`AppLink.front` in `main`).
    /// Returns the exit status.
    public static func run(arguments: [String], executable: URL, context: @autoclosure () -> OwnerContext,
                           version: String, input: () -> String?, output: @escaping @Sendable (String) -> Void,
                           errors: (String) -> Void, announce: () -> Void = {}, front: () -> Void = {}) -> Int32 {
        guard let verb = arguments.first else {
            errors(usage)
            return 2
        }
        switch verb {
        case "connect":
            let path = connectPath(executable: executable, home: context().home)
            output("Claude Code:")
            output("  " + connectLines(path: path)[0])
            output("Codex:")
            output("  " + connectLines(path: path)[1])
            output("Claude Code, the allow rule for founderizer-cli call alone (reads; never a rule for write):")
            output("  " + callRule(path: path))
            return 0
        case "guide":
            // Before a fleet exists: no hub, no table and no context.
            guard arguments.count == 1 else {
                errors("founderizer-cli guide takes no other word.")
                return wrongUse
            }
            output(OwnerGuide.text)
            announce()
            // The app's own activate did not bring it to the front on a test Mac; `open` from this process did (R2).
            front()
            return 0
        case "tools", "mcp", "call", "write":
            break
        case "-h", "--help", "help":
            output(usage)
            return 0
        default:
            errors("founderizer-cli has no call \(verb).\n" + usage)
            return 2
        }
        var callArguments: JSONValue = .object([:])
        if verb == "call" || verb == "write" {
            let rest = Array(arguments.dropFirst())
            let use = "founderizer-cli \(verb) <tool> ['<json object>']: the tool's name, and its fields as one JSON "
                + "object in one word (none means {})."
            guard (1...2).contains(rest.count), !rest[0].isEmpty, !rest[0].hasPrefix("-") else {
                errors(use)
                return wrongUse
            }
            if rest.count == 2 {
                guard let given = JSONValue.parse(rest[1]), given.object != nil else {
                    errors(use)
                    return wrongUse
                }
                callArguments = given
            }
        }
        if verb == "mcp" {
            let rest = Array(arguments.dropFirst())
            guard let at = rest.firstIndex(of: "--set"), at + 1 < rest.count, rest.count == 2 else {
                errors("founderizer-cli mcp needs its set of tools, and starts with no other: "
                       + "founderizer-cli mcp --set owner")
                return 2
            }
            let set = rest[at + 1]
            guard OwnerTools.sets.contains(set) else {
                errors("founderizer-cli knows only the set owner in this version of the app, not \(set).")
                return 2
            }
        }
        let table: OwnerTable
        do {
            table = try OwnerTable.load(from: ProgramPlace.table(for: executable))
        } catch let unreadable as OwnerTable.Unreadable {
            errors(unreadable.text)
            return 1
        } catch {
            errors("This program cannot read the table of its tools: \(error)")
            return 1
        }
        if verb == "tools" {
            return listTools(Array(arguments.dropFirst()), table: OwnerTools.programTable(table), output: output,
                             errors: errors)
        }
        let tools = OwnerTools(table: table, context: context())
        // Only `write` gives the standard input to a value (`from` `stdin`): in the MCP form it is the protocol.
        tools.standardInputFree = verb == "write"
        if verb == "call" || verb == "write" {
            return one(verb == "call" ? .call : .write, arguments[1], callArguments, tools: tools, output: output,
                       errors: errors)
        }
        let server = OwnerMCP(tools: tools, version: version, sink: output)
        while let line = input() { server.take(line: line) }
        server.finish()
        return 0
    }

    /// **One tool from a shell** (`call` or `write`): the JSON of the answer alone on standard output with exit status
    /// 0, so that `| jq` reads it, and the sentence that marks it as the hub's data on standard error; or the refusal
    /// on standard error with exit status 1. A tool of the other verb is refused with words that name the right one, so
    /// a client's question about a shell command, which it asks by how the command begins, is about reads for `call`
    /// and about writes for `write` (OWNER-MCP-BOUNDARY.md section 7). A tool that the program has and that no verb
    /// takes (a table tool that a table marked as a read) is refused by both.
    public static func one(_ verb: OwnerTools.Verb, _ name: String, _ arguments: JSONValue, tools: OwnerTools,
                           output: (String) -> Void, errors: (String) -> Void) -> Int32 {
        if let tool = tools.table.tool(name), tool.kind.listed {
            guard let right = OwnerTools.verb(of: tool) else {
                errors("\(name) is marked as a read in the table of this app, but it is no read that this program "
                       + "wrote, so neither founderizer-cli call nor write takes it. Use the MCP form, where the "
                       + "owner's client asks before it.")
                return refused
            }
            if right != verb {
                errors(right == .write
                       ? "\(name) writes, so founderizer-cli call does not take it: run founderizer-cli write \(name) "
                         + "'<json object>'. The owner's client asks before each write."
                       : "\(name) only reads, so founderizer-cli write does not take it: run founderizer-cli call "
                         + "\(name) '<json object>'.")
                return refused
            }
        }
        if verb == .call, name == callLeavesOut.0, arguments["page"] == .string(callLeavesOut.1) {
            errors("founderizer-cli call does not read the page chat_link: its QR links a WhatsApp account to the "
                   + "fleet. The owner links a WhatsApp account in the Founderizer app, which shows that QR.")
            return refused
        }
        // A tool that the program does not have, or a tool of a later version, gets the words of the MCP form.
        let (text, isError) = tools.call(name, arguments)
        if isError {
            errors(text)
            return refused
        }
        let mark = OwnerTools.dataMark + "\n"
        if text.hasPrefix(mark) {
            errors(OwnerTools.dataMark)
            output(String(text.dropFirst(mark.count)))
        } else {
            output(text)
        }
        return 0
    }

    static func listTools(_ names: [String], table: OwnerTable, output: (String) -> Void,
                          errors: (String) -> Void) -> Int32 {
        guard let name = names.first else {
            for tool in table.tools {
                guard let verb = OwnerTools.verb(of: tool) else { continue }
                output("\(verb.rawValue) \(tool.name): \(tool.firstSentence)")
            }
            return 0
        }
        guard names.count == 1, let tool = table.tool(name) else {
            errors("No tool named \(names.joined(separator: " ")).")
            return 1
        }
        output(tool.name)
        output(tool.description)
        switch tool.kind {
        case .later: output("Not in this version of the app yet.")
        case .absent: output("Not a tool of this program: the Founderizer app does that work, on its own pages.")
        default: break
        }
        if let verb = OwnerTools.verb(of: tool) {
            output("From a shell: founderizer-cli \(verb.rawValue) \(tool.name) '<json object>'")
        }
        output("Input schema:")
        output(tool.inputSchema.dumps(indent: 1))
        output("Only reads: \(tool.annotations["readOnlyHint"] == .bool(true) ? "yes" : "no")")
        return 0
    }
}
