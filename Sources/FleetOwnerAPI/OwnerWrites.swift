import CryptoKit
import Darwin
import Foundation

/// **The nine tools that write, as `owner_mcp.py` writes them** (slice A2): `save_profile` (`with_profile_base`),
/// `attach_file`, `read_attachment`, `take_backup`, `grant_access` (with `_one_moved`, `_one_moved_map` and
/// `_team_command`), `share_resource`, `send_message` (`write_message`), `answer_needs_you` (`answer_need`) and
/// `decline_secret_request` (`decline_secret`). Each makes the same requests in the same order, with the same refusals
/// in the same words and the same result; the parity check (`OwnerParityTests`, `test_owner_mcp.Parity`) holds them to
/// that function by function.
extension OwnerTools {
    /// The tools of the table's kind `swift` that this program has. A table of a newer `owner_mcp.py` can name a
    /// `swift` tool that this code has not: that tool is refused in words, as one of a later version (`init`).
    public static let written: Set<String> = [
        "fleet_overview", "fleet_read", "search_history", "see_costs",
        "save_profile", "attach_file", "read_attachment", "take_backup", "grant_access", "share_resource",
        "send_message", "answer_needs_you", "decline_secret_request",
    ]

    func runWritten(_ name: String, _ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        switch name {
        case "fleet_overview": return try overview(args, on: hub)
        case "fleet_read": return try readPage(args, on: hub)
        case "search_history": return try history(args, on: hub)
        case "see_costs": return try costs(args, on: hub)
        case "save_profile": return try saveProfile(args, on: hub)
        case "attach_file": return try attachFile(args, on: hub)
        case "read_attachment": return try readAttachment(args, on: hub)
        case "take_backup": return try takeBackup(args, on: hub)
        case "grant_access": return try grantAccess(args, on: hub)
        case "share_resource": return try shareResource(args, on: hub)
        case "send_message": return try sendMessage(args, on: hub)
        case "answer_needs_you": return try answerNeed(args, on: hub)
        case "decline_secret_request": return try declineSecret(args, on: hub)
        default: throw OwnerRefusal(Self.notYet(name))
        }
    }

    // ------------------------------------------------------------ messages and Needs-you

    /// `send_message`: `POST /ui/messages`.
    func sendMessage(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        var body: [String: JSONValue] = ["text": args["text"] ?? .null]
        for key in ["recipient", "attachments", "replaces_request_id"] {
            if let value = args[key], !value.isNull { body[key] = value }
        }
        return try hub.command("/ui/messages", body, "the message", requestID: args["request_id"])
    }

    /// `answer_needs_you`: `POST /ui/needs/<need>`.
    func answerNeed(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        var body: [String: JSONValue] = [:]
        for key in ["answer", "choice", "choices"] {
            if let value = args[key], !value.isNull { body[key] = value }
        }
        let need = try Self.wholeNumber(args, "need")
        return try hub.command("/ui/needs/\(need)", body, "the answer", requestID: args["request_id"])
    }

    /// `decline_secret_request`: `POST /ui/needs/<need>/secret` with the decline alone. No value comes in or goes out.
    func declineSecret(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        let need = try Self.wholeNumber(args, "need")
        let reason = args["reason"].flatMap { $0.truthy ? $0 : nil } ?? .string("")
        return try hub.command("/ui/needs/\(need)/secret", ["decline": reason], "the decline",
                               requestID: args["request_id"])
    }

    // ------------------------------------------------------------ the profile

    /// `save_profile`: one agent's profile, with the digest of the profile that it is built on from `GET /ui/profiles`,
    /// read immediately before the command.
    func saveProfile(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        let agent = PyText.strip(Self.text(args["agent"]))
        guard !agent.isEmpty else { throw OwnerRefusal("agent must be the name of the agent whose profile this is.") }
        try Self.onePart("agent", agent)
        let page = try hub.get("/ui/profiles", "the profiles").data
        let profiles = (page?["profiles"]).flatMap { $0.truthy ? $0.array : nil } ?? []
        guard let found = profiles.first(where: { PyText.same($0["agent"]?.string, agent) }) else {
            throw OwnerRefusal("There is no agent \(agent). Read fleet_read(page=\"profiles\") for the ones there are.")
        }
        return try hub.command("/ui/profiles/\(OwnerHub.quote(agent, safe: ""))",
                               ["sections": args["sections"] ?? .null, "base_sha256": found["sha256"] ?? .null],
                               "the profile of \(agent)", requestID: args["request_id"])
    }

    // ------------------------------------------------------------ access

    static let grantRoutes = ["repo": "/ui/team/repos", "tool": "/ui/team/tools", "secret": "/ui/secrets/grant",
                              "drive": "/ui/team/google", "gmail": "/ui/team/google"]

    /// `grant_access`: one agent's hold of one resource that the fleet already has. Each kind is its own owner route,
    /// and the three that take a whole map are read from `GET /ui/team` first, so only the named agent moves.
    func grantAccess(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        let resource = args["resource"] ?? .null, agent = args["agent"] ?? .null, level = args["level"] ?? .null
        let (kind, what) = PyText.partition(Self.text(resource), ":")
        if PyText.same(kind, "server") {
            throw OwnerRefusal("A server goes with its business: the owner's app gives each server that carries a "
                               + "business's Tailscale tag to that business's DevOps agent (or the manager while it has "
                               + "none), puts the host's parts in place and writes the door's access file. Nothing here "
                               + "gives it.")
        }
        guard Self.grantRoutes.keys.contains(where: { PyText.same($0, kind) }), !what.isEmpty else {
            throw OwnerRefusal("resource must be <kind>:<what>, with a kind of "
                               + Self.grantRoutes.keys.sorted(by: JSONValue.pythonOrder).joined(separator: ", ")
                               + " — for example repo:acme/web, secret:bws://<uuid>, gmail:a@b.com or tool:github.")
        }
        guard case .string(let name) = agent, !name.isEmpty else {
            throw OwnerRefusal("agent must be the name of the agent that holds this resource.")
        }
        let whatFor = "the grant of \(resource.pythonText) to \(name)"
        if PyText.same(kind, "secret") {
            return try hub.command("/ui/secrets/grant", ["login": .string(what), "agent": agent, "grant": level],
                                   whatFor, requestID: args["request_id"])
        }
        let lines = try Self.teamLines(try hub.get("/ui/team", "a read of the team").data)
        func moved(_ map: [String: JSONValue]) -> [String: JSONValue] {
            var map = map
            map[name] = nil
            if !level.isNull { map[name] = level }
            return map
        }
        if PyText.same(kind, "repo") {
            var access: [String: JSONValue] = [:]
            for (agentName, line) in lines {
                let repos = try Self.teamPart(line, "repos", object: true).object ?? [:]
                if let found = repos.first(where: { PyText.same($0.key, what) }) { access[agentName] = found.value }
            }
            return try teamCommand("/ui/team/repos", ["repo": .string(what), "access": .object(moved(access))],
                                   whatFor, args, on: hub)
        }
        if PyText.same(kind, "tool") {
            var names: [String: JSONValue] = [:]
            for (agentName, line) in lines {
                let tools = try Self.teamPart(line, "tools", object: false).array ?? []
                if tools.contains(where: { PyText.same($0.string, what) }) { names[agentName] = .string("use") }
            }
            let agents = moved(names).keys.sorted(by: JSONValue.pythonOrder).map(JSONValue.string)
            return try teamCommand("/ui/team/tools", ["tool": .string(what), "agents": .array(agents)], whatFor, args,
                                   on: hub)
        }
        var access: [String: JSONValue] = [:]
        for (agentName, line) in lines {
            let google = try Self.teamPart(line, "google", object: true).object ?? [:]
            let service = try Self.teamPart(google, kind, object: true).object ?? [:]
            if PyText.same(service["account"]?.string, what) {
                guard let found = service["level"] else { throw OwnerRefusal(Self.teamShape) }
                access[agentName] = found
            }
        }
        return try teamCommand("/ui/team/google", ["account": .string(what), "service": .string(kind),
                                                   "access": .object(moved(access))], whatFor, args, on: hub)
    }

    /// `owner_mcp.py`'s TEAM_SHAPE: nothing is sent when the read of the team has another shape.
    static let teamShape = "The hub's answer to the read of the team does not have the shape that grant_access reads, "
        + "so nothing was sent. Read fleet_read(page=\"team\") and tell the owner."

    /// `team_lines`: `lines` of `GET /ui/team`, a list of objects, each with its agent's name as a text.
    static func teamLines(_ held: JSONValue?) throws -> [(String, [String: JSONValue])] {
        guard let lines = held?["lines"]?.array else { throw OwnerRefusal(teamShape) }
        return try lines.map { line in
            guard let map = line.object, case .string(let name)? = map["agent"] else { throw OwnerRefusal(teamShape) }
            return (name, map)
        }
    }

    /// `team_part`: one part of a line, empty when it is absent or empty (Python's truth), and a refusal when it is of
    /// another kind than an object (`object`) or a list.
    static func teamPart(_ map: [String: JSONValue], _ key: String, object: Bool) throws -> JSONValue {
        let found = map.first(where: { PyText.same($0.key, key) })?.value
        guard let value = found, value.truthy else { return object ? .object([:]) : .array([]) }
        guard object ? value.object != nil : value.array != nil else { throw OwnerRefusal(teamShape) }
        return value
    }

    /// `_team_command`: one command that moves `team.json`, with the SHA-256 of the file that it is built on, read
    /// again immediately before it.
    func teamCommand(_ route: String, _ body: [String: JSONValue], _ what: String, _ args: [String: JSONValue],
                     on hub: OwnerHub) throws -> JSONValue? {
        var body = body
        body["base_sha256"] = try hub.teamSHA256()
        return try hub.command(route, body, what, requestID: args["request_id"])
    }

    /// `share_resource`: `POST /ui/resources`, the owner's standing for one resource. It changes no grant.
    func shareResource(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        var policy: JSONValue = .null
        if let most = args["max"], !most.isNull {
            policy = .object(["max": most, "to": args["to"].flatMap { $0.truthy ? $0 : nil } ?? .string("workers")])
        }
        return try teamCommand("/ui/resources", ["resource": args["resource"] ?? .null, "policy": policy],
                               "the standing of this resource", args, on: hub)
    }


    // ------------------------------------------------------------ files on this Mac

    /// `attach_file`: one file of this Mac to the hub (`POST /ui/attachments`). The body is the file itself, so its
    /// request id and its name are headers; the upload holds the lock for its one request, and a new generation is
    /// read again once with the same request id.
    func attachFile(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        guard case .string(let given)? = args["path"], !PyText.strip(given).isEmpty
        else { throw OwnerRefusal("path must be the file on this Mac to send.") }
        let place = try localPlace(given)              // a NUL first, before "~" is expanded
        guard LocalFile.isFile(place) else { throw OwnerRefusal("\(place) is not a file on this Mac.") }
        let most = Transfer.attachment.limit
        let tooLarge = { (size: Int) in
            OwnerRefusal("\(place) is \(size) bytes; an attachment is at most \(most / (1024 * 1024)) MiB.")
        }
        let data: Data
        do {
            let size = try LocalFile.size(place)
            if size > most { throw tooLarge(size) }
            data = try LocalFile.read(place)
        } catch let failure as LocalFile.Failure {
            throw OwnerRefusal("\(place) could not be read on this Mac: \(failure.reason).")
        }
        if data.count > most { throw tooLarge(data.count) }
        let rid = (args["request_id"].flatMap { $0.truthy ? $0.pythonText : nil } ?? UUID().uuidString).lowercased()
        let named = PyText.strip(args["mime"].flatMap { $0.truthy ? $0.pythonText : nil } ?? "")
        let fileName = LocalFile.name(place)
        let mime = named.isEmpty ? MediaType.guess(fileName, table.mediaTypes) : named
        let header = String(String.UnicodeScalarView(fileName.unicodeScalars.map {
            (0x20...0x7E).contains($0.value) ? $0 : "_"
        }))
        func once(_ db: String) throws -> HubAnswer {
            try CommandLock.holding(hub.lockFile) {
                try hub.call("POST", "/ui/attachments?db=\(OwnerHub.quote(db, safe: "/"))",
                             file: (data, mime, [("X-Fleet-Request-Id", rid), ("X-Fleet-Name", header)]),
                             transfer: Transfer(limit: Transfer.call.limit, file: true))
            }
        }
        var answer = try once(try hub.generation())
        if hub.stale(answer) { answer = try once(try hub.generation(fresh: true)) }
        guard answer.status == 200 else { throw hub.refusal(answer, "the upload of \(fileName)") }
        var result = answer.data?.object ?? [:]
        result["path"] = .string(place)
        return .object(result)
    }

    /// `read_attachment`: `GET /ui/attachments/<id>` into a file on this Mac, checked against the hub's own SHA-256.
    /// It writes the bytes and opens none of them.
    func readAttachment(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        guard case .int(let number)? = args["attachment"], number >= 1 else {
            throw OwnerRefusal("attachment must be the number of an attachment (A-<id> without the A-).")
        }
        guard case .string(let given)? = args["path"], !PyText.strip(given).isEmpty
        else { throw OwnerRefusal("path must be where on this Mac the file is written.") }
        var place = try localPlace(given)
        let answer = try hub.get("/ui/attachments/\(number)", "attachment A-\(number)", transfer: .attachment)
        let digest = Self.sha256(answer.raw)
        if let said = answer.headers["x-fleet-sha256"], !said.isEmpty, !PyText.same(said, digest) {
            throw OwnerRefusal("the file did not arrive whole: the hub's SHA-256 is not the one of the bytes received.")
        }
        var folder: String?
        if LocalFile.isFolder(place) {
            folder = place
            place = try Self.intoFolder(place, Self.hubFileName(answer, fallback: "attachment-\(number)"))
        }
        try Self.write(answer.raw, to: place, newIn: folder)
        let mime = PyText.strip(PyText.partition(answer.headers["content-type"] ?? "", ";").0)
        return .object(["attachment": .int(number), "path": .string(place), "bytes": .int(Int64(answer.raw.count)),
                        "sha256": .string(digest), "mime": .string(mime)])
    }

    /// `take_backup`: `GET /ui/backup` into a file on this Mac, then `POST /ui/backups/confirm` once the bytes are
    /// checked against the hub's own SHA-256. Nothing is written on the hub machine.
    func takeBackup(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        guard case .string(let given)? = args["path"], !PyText.strip(given).isEmpty
        else { throw OwnerRefusal("path must be where on this Mac the copy is written.") }
        var place = try localPlace(given)
        let answer = try hub.get("/ui/backup", "a copy of this fleet", transfer: .backup)
        let digest = Self.sha256(answer.raw)
        if let said = answer.headers["x-fleet-backup-sha256"], !said.isEmpty, !PyText.same(said, digest) {
            throw OwnerRefusal("the copy did not arrive whole: the hub's SHA-256 is not the one of the bytes received.")
        }
        var folder: String?
        if LocalFile.isFolder(place) {
            folder = place
            let fallback = "founderizer-\(Int(context.now().timeIntervalSince1970)).zip"
            place = try Self.intoFolder(place, Self.hubFileName(answer, fallback: fallback))
        }
        try Self.write(answer.raw, to: place, newIn: folder)     // before the confirmation: a refusal confirms nothing
        let receipt = try hub.command("/ui/backups/confirm", ["sha256": .string(digest),
                                                              "bytes": .int(Int64(answer.raw.count))],
                                      "the confirmation of the copy", requestID: args["request_id"])
        var result = receipt?.object ?? [:]
        result["path"] = .string(place)
        result["bytes"] = .int(Int64(answer.raw.count))
        result["sha256"] = .string(digest)
        return .object(result)
    }

    // ------------------------------------------------------------ the parts that the tools share

    /// Python's `str(value or "")`.
    static func text(_ value: JSONValue?) -> String {
        guard let value, value.truthy else { return "" }
        return value.pythonText
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// **The hub's name of a file counts only as one new, plain file name** (`owner_mcp.py`'s `hub_file_name`): what
    /// follows `filename=` in `Content-Disposition`, with its quotes taken off and cut at its first NUL. A name that is
    /// empty, that starts with "." (".", "..", a dot file), that holds "/", or that holds a character outside printable
    /// ASCII is not used, and the fallback is.
    static func hubFileName(_ answer: HubAnswer, fallback: String) -> String {
        let said = answer.headers["content-disposition"] ?? ""
        var name = PyText.strip(PyText.partition(said, "filename=").1, only: "\"")
        name = PyText.partition(name, "\u{0}").0
        let bad = name.unicodeScalars.contains { $0 == "/" || !(0x20...0x7E).contains($0.value) }
        if name.isEmpty || name.unicodeScalars.first == "." || bad { return fallback }
        return name
    }

    /// `owner_mcp.py`'s `local_place`: the path that the agent named, refused when it holds a NUL, which no system call
    /// can take (a C call would cut the path there).
    func localPlace(_ given: String) throws -> String {
        guard !given.unicodeScalars.contains("\u{0}") else {
            throw OwnerRefusal("path cannot hold a NUL character: name a file or a folder of this Mac.")
        }
        return localPath(PyText.strip(given))
    }

    /// `owner_mcp.py`'s `into_folder`: the folder and the name, refused unless the file's own folder is that folder.
    static func intoFolder(_ folder: String, _ name: String) throws -> String {
        let place = LocalFile.join(folder, name)
        guard PyText.same(LocalFile.parent(place), LocalFile.normal(folder)) else {
            throw OwnerRefusal("the hub's name of the file would put it outside \(LocalFile.normal(folder)), so "
                               + "nothing was written.")
        }
        return place
    }

    /// The bytes into a file on this Mac, its folders made; a file that cannot be written is a refusal in words with
    /// the system's reason, as `owner_mcp.py`'s `write_here` says it. `newIn`: the agent named that folder, so the file
    /// is made new and only new, and follows no link (`O_CREAT|O_EXCL|O_NOFOLLOW`): a file, a link or a folder of that
    /// name stays as it is, and nothing is written.
    static func write(_ data: Data, to place: String, newIn folder: String? = nil) throws {
        var creating = false
        do {
            try LocalFile.makeFolders(LocalFile.parent(place))
            creating = true
            try LocalFile.write(data, to: place, new: folder != nil)
        } catch let failure as LocalFile.Failure {
            // Only the create's own EEXIST: a file in the way of the folders is the system's words below.
            if let folder, creating, failure.code == EEXIST {
                throw OwnerRefusal("\(LocalFile.name(place)) is there already in \(LocalFile.normal(folder)), so "
                                   + "nothing was written. Name the file itself in path to replace it, or name another "
                                   + "folder.")
            }
            throw OwnerRefusal("\(place) could not be written on this Mac: \(failure.reason).")
        }
    }

    /// `str(pathlib.Path(os.path.expanduser(text)))`: "~" is the home of this process (`$HOME`), "~user" that user's
    /// home, and the path as `pathlib` writes it. On Unicode scalars, as Python reads a text.
    func localPath(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.first == "~" else { return LocalFile.normal(text) }
        let slash = scalars.firstIndex(of: "/") ?? scalars.count
        let user = PyText.string(scalars[1..<slash])
        let rest = PyText.string(scalars[slash...])
        var home: String
        if user.isEmpty {
            home = context.home.path
        } else {
            let expanded = ("~" + user as NSString).expandingTildeInPath
            guard expanded.unicodeScalars.first != "~" else { return LocalFile.normal(text) }
            home = expanded
        }
        while home.unicodeScalars.count > 1 && home.unicodeScalars.last == "/" { home.unicodeScalars.removeLast() }
        if PyText.same(home, "/") { home = "" }
        let path = home + rest
        return LocalFile.normal(path.isEmpty ? "/" : path)
    }
}

/// **Python's own reading of a text, on Unicode scalars**: Swift compares and splits `String` by characters, with
/// canonical equivalence, and Python by code points, so a combining mark after ":" or "/" (`"repo:\u{301}x"`) is one
/// character in Swift and two code points in Python. Each split, strip and compare of a text that `owner_mcp.py` makes
/// is made here the way Python makes it.
enum PyText {
    /// The characters of Python's `str.isspace`, which `str.strip()` takes off.
    static let space: Set<UInt32> = Set([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0,
                                          0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000] + Array(0x2000...0x200A))
    /// The characters that Python's `int()` takes off a text: `space` without U+001C to U+001F (measured with
    /// Python 3.12 over every code point: `int("\x1c5")` is a ValueError); `owner_mcp.py` INT_SPACE. Both programs
    /// read a whole number by one rule (`OwnerTools.wholeNumber`), which takes ASCII digits alone.
    static let intSpace: Set<UInt32> = space.subtracting([0x1C, 0x1D, 0x1E, 0x1F])

    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    /// `text.strip()`, `text.strip(only)` with `only`, or a strip of the characters of `set`.
    static func strip(_ text: String, only: String? = nil, set: Set<UInt32>? = nil) -> String {
        let taken = only.map { Set($0.unicodeScalars.map(\.value)) } ?? set ?? space
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !taken.contains($0.value) }),
              let last = scalars.lastIndex(where: { !taken.contains($0.value) }) else { return "" }
        return string(scalars[first...last])
    }

    /// `text.partition(separator)`: the part before the first separator and the part after it. With no separator, the
    /// text and "", as Python's `[0]` and `[2]`.
    static func partition(_ text: String, _ separator: String) -> (String, String) {
        let scalars = Array(text.unicodeScalars), mark = Array(separator.unicodeScalars)
        guard !mark.isEmpty, scalars.count >= mark.count else { return (text, "") }
        for start in 0...(scalars.count - mark.count) where Array(scalars[start..<start + mark.count]) == mark {
            return (string(scalars[..<start]), string(scalars[(start + mark.count)...]))
        }
        return (text, "")
    }

    /// Python's `==` of two texts: the same code points, not only the same characters.
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    static func contains(_ text: String, _ scalar: Unicode.Scalar) -> Bool { text.unicodeScalars.contains(scalar) }
}

/// **The media type of a file that the agent attaches with no `mime`**, by its ending in lower case, from the table
/// (`owner_mcp.py` MEDIA_TYPES, which `--dump-tools` carries): the hub's own ten types and their other endings. Every
/// other file is `application/octet-stream`. The program keeps no table of its own.
public enum MediaType {
    public static func guess(_ name: String, _ types: [String: String]) -> String {
        types[LocalFile.suffix(name).lowercased()] ?? "application/octet-stream"
    }
}

/// **A file on this Mac, with the system's own words for what went wrong** (`strerror`, as Python's `OSError.strerror`
/// gives them), and paths written as Python's `pathlib` writes them, on Unicode scalars.
enum LocalFile {
    struct Failure: Error {
        let code: Int32
        let reason: String
        init(_ code: Int32) {
            self.code = code
            reason = String(cString: strerror(code))
        }
    }

    /// A path that a C call would cut at a NUL never reaches one: the tools refuse it before (`localPlace`), and each
    /// call here refuses it too.
    static func callable(_ path: String) -> Bool { !path.unicodeScalars.contains("\u{0}") }

    static func parts(_ path: String) -> [String] {
        Array(path.unicodeScalars).split(separator: "/").map { PyText.string($0) }
    }

    /// The path as `pathlib.PurePosixPath` writes it: no empty part, no ".", no "/" at the end; two "/" at the start
    /// stay two, as POSIX lets them.
    static func normal(_ path: String) -> String {
        let scalars = Array(path.unicodeScalars)
        let slashes = scalars.prefix { $0 == "/" }.count
        let root = slashes == 2 ? "//" : slashes > 0 ? "/" : ""
        let kept = parts(path).filter { !PyText.same($0, ".") }
        if kept.isEmpty { return root.isEmpty ? "." : root }
        return root + kept.joined(separator: "/")
    }

    /// `place / name` of `pathlib`: nothing is added after a root ("/", "//"), and "." or "" is no place at all.
    /// Checked against `PurePosixPath` (`OwnerWriteTests.pathsAreWrittenAsPathlibWritesThem`).
    static func join(_ place: String, _ name: String) -> String {
        if name.unicodeScalars.first == "/" { return normal(name) }
        let base = normal(place)
        if PyText.same(base, ".") { return normal(name) }
        if base.unicodeScalars.last == "/" { return normal(base + name) }        // the root "/" or "//"
        return normal(base + "/" + name)
    }

    /// `Path.name`: the last part.
    static func name(_ path: String) -> String { parts(normal(path)).last ?? "" }

    /// `Path.parent`.
    static func parent(_ path: String) -> String {
        let normal = Array(normal(path).unicodeScalars)
        guard let slash = normal.lastIndex(of: "/") else { return "." }
        let head = PyText.string(normal[..<slash])
        if head.isEmpty || PyText.same(head, "/") { return normal.starts(with: ["/", "/"]) ? "//" : "/" }
        return head
    }

    /// The ending of a name as Python's `os.path.splitext` finds it: after the last ".", where a run of "." at the
    /// start of the name does not count (".png" has none).
    static func suffix(_ name: String) -> String {
        let rest = Array(name.unicodeScalars.drop { $0 == "." })
        guard let dot = rest.lastIndex(of: ".") else { return "" }
        return PyText.string(rest[(dot + 1)...])
    }

    /// `Path.is_file()`: false for a path with a NUL, as in Python.
    static func isFile(_ path: String) -> Bool {
        var info = stat()
        return callable(path) && stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return callable(path) && stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func size(_ path: String) throws -> Int {
        var info = stat()
        guard callable(path) else { throw Failure(EINVAL) }
        guard stat(path, &info) == 0 else { throw Failure(errno) }
        return Int(info.st_size)
    }

    static func read(_ path: String) throws -> Data {
        guard callable(path) else { throw Failure(EINVAL) }
        let handle = open(path, O_RDONLY | O_CLOEXEC)
        guard handle >= 0 else { throw Failure(errno) }
        defer { close(handle) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(handle, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure(errno)
            }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
    }

    /// `Path.mkdir(parents=True, exist_ok=True)`.
    static func makeFolders(_ path: String) throws {
        guard callable(path) else { throw Failure(EINVAL) }
        if mkdir(path, 0o777) == 0 { return }
        let first = errno
        if first == ENOENT, !PyText.same(parent(path), path) {
            try makeFolders(parent(path))
            if mkdir(path, 0o777) == 0 { return }
            let again = errno
            if isFolder(path) { return }
            throw Failure(again)
        }
        if isFolder(path) { return }
        throw Failure(first)
    }

    /// `Path.write_bytes`: the file made or emptied, then the bytes. `new`: `open(path, "xb")`, made new and only new,
    /// following no link at its last part; EEXIST when anything of that name is there.
    static func write(_ data: Data, to path: String, new: Bool = false) throws {
        guard callable(path) else { throw Failure(EINVAL) }
        let flags = new ? O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC : O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
        let handle = open(path, flags, 0o666)
        guard handle >= 0 else { throw Failure(errno) }
        defer { close(handle) }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var done = 0
            while done < bytes.count {
                let count = Darwin.write(handle, bytes.baseAddress! + done, bytes.count - done)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure(errno)
                }
                done += count
            }
        }
    }
}
