import Foundation
import Testing
@testable import FleetOwnerAPI

/// **The parity check** (plan 3.3, OWNER-MCP.md "The program inside the app"): each case of
/// `Fixtures/owner-parity.json`, which `owner_mcp.py` made against a stand-in hub (`python3 test_owner_mcp.py
/// --parity-fixture`, held to the code by `test_owner_mcp.Parity`), runs here against a stand-in hub that gives the same
/// answers in the same order. The requests must be the same: method, path, parsed query, the headers that carry
/// meaning (`Content-Type`, `X-Fleet-Request-Id`, `X-Fleet-Name`, that `X-Fleet-Client` is there, and that
/// `Authorization` and `Origin` are not), and the parsed body, with each request id that a program made named by its
/// order. The outcome must be the same too, the result or the refusal's words, and so must every file and folder
/// after the call (the setup's too). One accepted difference: the sentence that this program adds when the hub does not
/// know a route or a field (`OwnerHub.olderHub`) must stand exactly as many times as the fixture says (its
/// `older_hub`, which the Python side reads from what `hub.py` answers), and is then taken out.
struct OwnerParityTests {
    struct Case: Sendable {
        let name: String
        let tool: String
        let arguments: JSONValue
        let setup: JSONValue
        let answers: [(Int, [String: String], Data)]
        let requests: JSONValue
        let outcome: JSONValue
        let olderHub: Int
        let after: JSONValue
        /// A case of design 9's tools of a cloud: whether each cloud has a `proved` date, whether its programs are
        /// missing, and each command that `owner_mcp.py` ran, with the files that it named and the answer that it got.
        let cloud: JSONValue?
    }

    static let root: JSONValue = {
        let url = Bundle.module.url(forResource: "owner-parity", withExtension: "json", subdirectory: "Fixtures")!
        return JSONValue.parse(try! Data(contentsOf: url))!
    }()

    /// The clock of both programs in the check (`PARITY_NOW`), so that a fallback name of a copy needs no placeholder.
    static let now: Date = {
        guard case .int(let seconds)? = root["now"] else { fatalError("no now in the fixture") }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }()

    static let cases: [Case] = {
        return root["cases"]!.array!.map { item in
            let answers: [(Int, [String: String], Data)] = item["answers"]!.array!.map { answer in
                var headers: [String: String] = [:]
                for (key, value) in answer["headers"]?.object ?? [:] { headers[key] = value.string }
                let data = answer["text"]?.string.map { Data($0.utf8) }
                    ?? Data(base64Encoded: answer["base64"]?.string ?? "") ?? Data()
                guard case .int(let status)? = answer["status"] else { return (0, headers, data) }
                return (Int(status), headers, data)
            }
            guard case .int(let older)? = item["older_hub"] else { fatalError("no older_hub in the fixture") }
            return Case(name: item["name"]!.string!, tool: item["tool"]!.string!, arguments: item["arguments"]!,
                        setup: item["setup"]!, answers: answers, requests: item["requests"]!,
                        outcome: item["outcome"]!, olderHub: Int(older), after: item["after"]!, cloud: item["cloud"])
        }
    }()

    @Test func theFixtureCoversEachToolThatBothProgramsHave() {
        let named = Set(Self.cases.map(\.tool))
        let both = Set(Fixture.table.tools.filter { $0.kind != .absent }.map(\.name))
        #expect(both.subtracting(named).isEmpty, "\(both.subtracting(named).sorted())")
        #expect(both.count == 58 + 4 + 13)
        #expect(Self.cases.count > 100)
    }

    @Test(arguments: OwnerParityTests.cases.map(\.name))
    func eachCaseIsWhatOwnerMCPDid(_ name: String) throws {
        let one = try #require(Self.cases.first { $0.name == name })
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("owner-parity-\(UUID().uuidString)", isDirectory: true)
        let work = scratch.appendingPathComponent("work", isDirectory: true)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for folder in one.setup["folders"]?.array ?? [] {
            try FileManager.default.createDirectory(at: work.appendingPathComponent(folder.string!),
                                                    withIntermediateDirectories: true)
        }
        let setupFiles = one.setup["files"]?.object ?? [:]
        for (file, content) in setupFiles {
            let place = work.appendingPathComponent(file)
            try LocalFile.makeFolders(LocalFile.parent(work.path + "/" + file))
            if case .int(let size)? = content["sparse"] {
                FileManager.default.createFile(atPath: place.path, contents: nil)
                let handle = try FileHandle(forWritingTo: place)
                try handle.truncate(atOffset: UInt64(size))
                try handle.close()
            } else if let bytes = content["base64"]?.string {      // a file that is no text: a picture
                try LocalFile.write(try #require(Data(base64Encoded: bytes)), to: work.path + "/" + file)
            } else {
                // POSIX, as Python makes it: Foundation's file URL gives the name decomposed (NFD).
                try LocalFile.write(Data(content.string!.utf8), to: work.path + "/" + file)
            }
        }
        for (link, target) in one.setup["links"]?.object ?? [:] {
            #expect(symlink(work.path + "/" + target.string!, work.path + "/" + link) == 0)
        }

        let hub = StandInHub(features: [])
        let answers = one.answers
        let count = Counter()
        hub.full = { _ in
            let index = count.next()
            return index < answers.count ? answers[index]
                : (500, ["Content-Type": "application/json"], Data(#"{"error": "no answer scripted"}"#.utf8))
        }
        let bin = scratch.appendingPathComponent("bin", isDirectory: true).path
        let places = [(work.path, "<tmp>"), (home.path, "<home>"), (bin, "<bin>"), (hub.base, "<hub>")]
        let commands = Commands()
        var table = Fixture.table, programs = CloudPrograms(find: { _ in nil }, run: { _, _, _ in
            .ended(exit: 99, out: Data(), error: Data("no program in this case".utf8))
        })
        if let cloud = one.cloud {
            table.cloudRecipes = Self.proved(table.cloudRecipes, cloud["proved"]?.truthy == true)
            let missing = cloud["missing"]?.truthy == true
            let scripted = cloud["commands"]?.array ?? []
            programs = CloudPrograms(find: { name in missing ? nil : bin + "/" + name }, run: { _, argv, _ in
                let index = commands.record(argv: argv, places: places)
                guard index < scripted.count, case .int(let exit)? = scripted[index]["exit"] else {
                    return .ended(exit: 99, out: Data(), error: Data("no answer scripted".utf8))
                }
                return .ended(exit: Int32(exit), out: Data((scripted[index]["out"]?.string ?? "").utf8),
                              error: Data((scripted[index]["error"]?.string ?? "").utf8))
            })
        }
        let tools = Fixture.tools(hub, home: home, table: table, now: { Self.now }, programs: programs)
        let arguments = try #require(JSONValue.parse(one.arguments.dumps().replacingOccurrences(of: "<tmp>",
                                                                                                 with: work.path)))
        let (text, isError) = tools.call(one.tool, arguments)

        var outcome: JSONValue
        if isError {
            outcome = .object(["refusal": .string(Self.callFiles(text))])
        } else {
            let mark = (one.cloud == nil ? OwnerTools.dataMark : OwnerCloud.dataMark) + "\n"
            #expect(text.hasPrefix(mark))
            outcome = .object(["result": Self.callFiles(try #require(JSONValue.parse(String(text.dropFirst(mark.count)))))])
        }
        if let cloud = one.cloud {
            let wanted = JSONValue.array((cloud["commands"]?.array ?? []).map { command in
                .object(["argv": command["argv"] ?? .null, "files": command["files"] ?? .null])
            })
            #expect(commands.seen.dumps() == wanted.dumps(),
                    "\(name): the commands\n\(commands.seen.dumps(indent: 1))\nare not\n\(wanted.dumps(indent: 1))")
            for path in commands.paths where path.contains("/founderizer-cloud-") {     // the call's own files
                #expect(!FileManager.default.fileExists(atPath: path), "\(name): \(path) is still there")
            }
        }
        let sentence = "\n" + OwnerHub.olderHub
        #expect(Self.count(sentence, in: outcome) == one.olderHub,
                "\(name): the sentence of an older hub stands \(Self.count(sentence, in: outcome)) times")
        outcome = Self.placed(Self.without(sentence, outcome), places)
        // A JSON comparison: JSONValue's own == compares texts by character, Python by code point.
        #expect(outcome.dumps() == one.outcome.dumps(), "\(name): \(outcome.dumps()) is not \(one.outcome.dumps())")
        let given = one.arguments["request_id"].flatMap { $0.truthy ? $0.pythonText.lowercased() : nil }
        let made = Self.requests(hub.seen, given: given)
        #expect(made.dumps() == one.requests.dumps(),
                "\(name):\n\(made.dumps(indent: 1))\nis not\n\(one.requests.dumps(indent: 1))")
        let after = Self.after(work: work, home: home, places: places)
        #expect(after.dumps() == one.after.dumps(), "\(name): \(after.dumps()) is not \(one.after.dumps())")
    }

    /// How many times a text stands in the strings of a value.
    static func count(_ text: String, in value: JSONValue) -> Int {
        switch value {
        case .string(let words): return words.components(separatedBy: text).count - 1
        case .array(let list): return list.reduce(0) { $0 + count(text, in: $1) }
        case .object(let map): return map.values.reduce(0) { $0 + count(text, in: $1) }
        default: return 0
        }
    }

    static func without(_ text: String, _ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let words): return .string(words.replacingOccurrences(of: text, with: ""))
        case .array(let list): return .array(list.map { without(text, $0) })
        case .object(let map): return .object(map.mapValues { without(text, $0) })
        default: return value
        }
    }

    /// Each command of the cloud's program that a case ran, as `parity_fixture` writes it: its words and the text of
    /// each file that it names (as the stand-in reads them: `file://<path>`, `ssh-keys=<path>`, or a path as a word),
    /// with the places and the folder of the call's files as their marks.
    final class Commands: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [JSONValue] = []
        private var files: [String] = []
        var seen: JSONValue { lock.lock(); defer { lock.unlock() }; return .array(list) }
        /// The paths of the files that the commands named, which must be gone after the call.
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return files }

        func record(argv: [String], places: [(String, String)]) -> Int {
            var files: [String: JSONValue] = [:]
            for word in argv.dropFirst() {
                for start in ["file://", "ssh-keys=", ""] where word.hasPrefix(start) {
                    let path = String(word.dropFirst(start.count))
                    var folder: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &folder), !folder.boolValue,
                       let data = FileManager.default.contents(atPath: path) {
                        files[OwnerParityTests.callFiles(.string(path)).string!] = .string(String(decoding: data,
                                                                                                   as: UTF8.self))
                        lock.lock()
                        self.files.append(path)
                        lock.unlock()
                        break
                    }
                }
            }
            let one = OwnerParityTests.callFiles(OwnerParityTests.placed(
                .object(["argv": .array(argv.map(JSONValue.string)), "files": .object(files)]), places))
            lock.lock(); defer { lock.unlock() }
            list.append(one)
            return list.count - 1
        }
    }

    /// The folder of the files of one cloud command as `<files>` (`PARITY_CALL_FILES` of test_owner_mcp).
    static func callFiles(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(callFiles(text))
        case .array(let list): return .array(list.map(callFiles))
        case .object(let map):
            return .object(Dictionary(uniqueKeysWithValues: map.map { (callFiles($0.key), callFiles($0.value)) }))
        default: return value
        }
    }

    static func callFiles(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?:/[^/\s"']+)*/founderizer-cloud-[^/\s"']+"#)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: "<files>")
    }

    /// The recipes with each cloud's `proved` date of the case: the fixture's cases run with a date but where they say
    /// not, as `parity_programs` sets them.
    static func proved(_ recipes: JSONValue, _ proved: Bool) -> JSONValue {
        guard var root = recipes.object, var clouds = root["clouds"]?.object else { return recipes }
        for (name, recipe) in clouds {
            var one = recipe.object ?? [:]
            one["proved"] = proved ? .string("2026-12-01") : .null
            clouds[name] = .object(one)
        }
        root["clouds"] = .object(clouds)
        return .object(root)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value - 1
        }
    }

    /// Each local folder and the hub's address in a value, as its placeholder (`parity_places`).
    static func placed(_ value: JSONValue, _ places: [(String, String)]) -> JSONValue {
        switch value {
        case .string(var text):
            for (real, mark) in places { text = text.replacingOccurrences(of: real, with: mark) }
            return .string(text)
        case .array(let list): return .array(list.map { placed($0, places) })
        case .object(let map): return .object(map.mapValues { placed($0, places) })
        default: return value
        }
    }

    /// The requests as `parity_requests` writes them.
    static func requests(_ seen: [Seen], given: String?) -> JSONValue {
        var ids: [String: String] = [:]
        func rid(_ value: JSONValue?) -> JSONValue {
            guard let value else { return .null }
            guard case .string(let text) = value, text != given,
                  text.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                             options: .regularExpression) != nil else { return value }
            if ids[text] == nil { ids[text] = "<rid\(ids.count + 1)>" }
            return .string(ids[text]!)
        }
        return .array(seen.map { request in
            let kind = (request.header("Content-Type") ?? "").split(separator: ";").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            var body: JSONValue = .null
            if let bytes = request.bytes, !bytes.isEmpty {
                if kind == "application/json", var parsed = JSONValue.parse(bytes) {
                    if case .object(var map) = parsed, let id = map["request_id"] {
                        map["request_id"] = rid(id)
                        parsed = .object(map)
                    }
                    body = parsed
                } else {
                    body = .object(["bytes": .int(Int64(bytes.count)), "sha256": .string(OwnerTools.sha256(bytes))])
                }
            }
            func text(_ name: String) -> JSONValue { request.header(name).map(JSONValue.string) ?? .null }
            return .object([
                "method": .string(request.method), "path": .string(request.path),
                "query": query(request.query ?? ""),
                "headers": .object([
                    "content-type": text("Content-Type"),
                    "x-fleet-request-id": rid(request.header("X-Fleet-Request-Id").map(JSONValue.string)),
                    "x-fleet-name": text("X-Fleet-Name"),
                    "x-fleet-client": .bool(request.header("X-Fleet-Client") != nil),
                    "authorization": .bool(request.header("Authorization") != nil),
                    "origin": .bool(request.header("Origin") != nil),
                ]),
                "body": body,
            ])
        })
    }

    /// `urllib.parse.parse_qs(query, keep_blank_values=True)`.
    static func query(_ text: String) -> JSONValue {
        var words: [String: [JSONValue]] = [:]
        for part in text.split(separator: "&") where !part.isEmpty {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decoded(_ raw: Substring) -> String {
                let spaced = raw.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            words[decoded(pair[0]), default: []].append(.string(pair.count > 1 ? decoded(pair[1]) : ""))
        }
        return .object(words.mapValues(JSONValue.array))
    }

    /// Every file (with its SHA-256) and every folder after the call, as `parity_after` lists them: the setup's too, and
    /// only each own file of a program in the home left out, by its name.
    static func after(work: URL, home: URL, places: [(String, String)]) -> JSONValue {
        let own: Set<String> = [".founderizer/lock", ".founderizer/client", ".founderizer/cli-client"]
        var files: [String: JSONValue] = [:], folders: [String] = []
        /// The names in a folder as the file system keeps them (`readdir`, as Python lists them).
        func names(_ path: String) -> [String] {
            guard let folder = opendir(path) else { return [] }
            defer { closedir(folder) }
            var found: [String] = []
            while let entry = readdir(folder) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if name != "." && name != ".." { found.append(name) }
            }
            return found
        }
        func walk(_ root: String, _ relative: String, _ mark: String) {
            for name in names(relative.isEmpty ? root : root + "/" + relative) {
                let rel = relative.isEmpty ? name : relative + "/" + name
                if mark == "<home>" && own.contains(rel) { continue }
                let path = root + "/" + rel
                let named = placed(.string("\(mark)/\(rel)"), places).string!
                if LocalFile.isFolder(path) {
                    folders.append(named)
                    walk(root, rel, mark)
                } else if let data = try? LocalFile.read(path) {
                    files[named] = .string(OwnerTools.sha256(data))
                }
            }
        }
        walk(work.path, "", "<tmp>")
        walk(home.path, "", "<home>")
        return .object(["files": .object(files),
                        "folders": .array(folders.sorted(by: JSONValue.pythonOrder).map(JSONValue.string))])
    }
}
