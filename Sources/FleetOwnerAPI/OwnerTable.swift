import Foundation

/// **The table of the owner's tools**, as `owner_mcp.py --dump-tools` prints it and as the app carries it in
/// `Contents/Resources/owner-tools.json`. It is made from the same objects that the Python server's own tools are, so
/// the names, the words, the fields and the routes here are that server's, and the program keeps no copy of them.
public struct OwnerTable: Sendable {
    /// What the program does with a tool of the table.
    public enum Kind: String, Sendable {
        /// The fields go to one command route as they are.
        case plain
        /// The same, with the SHA-256 of `team.json`: the client's own when it gives one, which a field of `whole`
        /// needs, else from `GET /ui/team`.
        case withBase = "with_base"
        /// The same, with the revision of the goal, duty or rule that its own page gives.
        case withRevision = "with_revision"
        /// A tool that the program writes in Swift (`OwnerTools.written`): the four reads and the nine writes.
        case swift
        /// A tool that a later version of the app writes in Swift. It is refused at the call.
        case later
        /// A tool that the program never has: the app's own pages do that work. It is refused at the call.
        case absent

        /// A tool that the program builds from the table's facts alone.
        public var built: Bool { self == .plain || self == .withBase || self == .withRevision }
        /// A tool that the program lists and runs.
        public var listed: Bool { built || self == .swift }
    }

    public struct Tool: Sendable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
        public let annotations: JSONValue
        public let kind: Kind
        /// For a tool that the table builds: its route template, with `{name}` for each part from an argument.
        public let route: String
        public let fields: [String]
        /// Its words in a refusal ("the machine check").
        public let what: String
        /// For `with_revision`: the page whose thing gives the revision (`goal`, `responsibility`, `trigger`).
        public let revisionPage: String?
        /// Whether a `request_id` of the agent's goes to the hub.
        public let requestIDFromArguments: Bool
        /// The name in the hub's `ui_features` that this tool needs, or nil.
        public let feature: String?
        /// For `with_base`: the fields that replace a whole value that is always there (`owner_mcp.py`'s `whole`),
        /// which go only with the `base_sha256` of the client's own read. A table from before them has none.
        public var whole: [String] = []
        /// The fields whose null goes to the hub, because their schema takes null (`owner_mcp.py`'s `nulls`): an
        /// agent's model that follows the default again, a chat app account removed. Every other null is left out.
        /// A table from before them has none.
        public var nulls: [String] = []
        /// The seconds of its request when they are not the 30 of a call (`owner_mcp.py`'s `wait`: claim_teams, whose
        /// hub waits up to 30 seconds for the platform itself), or nil.
        public var wait: TimeInterval?

        /// The first sentence of its words, for one line of `founderizer-cli tools`.
        public var firstSentence: String {
            let text = description
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(after: index)
                if ".?!".contains(text[index]), next == text.endIndex || text[next] == " " {
                    return String(text[..<next])
                }
                index = next
            }
            return text
        }
    }

    public let tools: [Tool]
    public let instructions: String
    public let protocolVersion: String
    public let supported: [String]
    /// `fleet_read`'s pages: each name with its route and its words.
    public let pages: [String: (route: String, what: String)]
    public let pageQuery: [String]
    /// The words of `pageQuery` that each page's route reads (`owner_mcp.py` PAGE_TAKES); a page that is not here
    /// reads none of them.
    public let pageTakes: [String: [String]]
    public let pageWords: [String]
    public let pageInPath: [String]
    public let historyWords: [String]
    public let costsWords: [String]
    /// `attach_file`'s media type of a file by its ending in lower case (`owner_mcp.py` MEDIA_TYPES).
    public let mediaTypes: [String: String]
    /// A SHA-256 of the table's content.
    public let version: String
    /// **The recipes of a server at AWS, Azure or Google Cloud** (`owner_mcp.py` CLOUD_RECIPES, design 9), which the
    /// three tools of a cloud read (`OwnerCloud`). A table from before them has none.
    public var cloudRecipes: JSONValue = .null

    public func tool(_ name: String) -> Tool? { tools.first { $0.name == name } }

    /// The words that one page needs (`owner_mcp.py` `page_needs`): its id, and the subject in its path.
    public func needs(of page: String) -> [String] {
        guard let route = pages[page]?.route else { return [] }
        return (route.contains("{id}") ? ["id"] : []) + pageInPath.filter { route.contains($0) }.map { String($0.dropFirst().dropLast()) }
    }

    /// The words that `fleet_read` takes for one page, in the order of its route (`owner_mcp.py` `page_words`): the ones
    /// it needs, then the words of its query.
    public func words(of page: String) -> [String] { needs(of: page) + (pageTakes[page] ?? []) }

    /// This table, with each tool of the kind `swift` that is not in `written` made a tool of a later version: a
    /// newer `owner_mcp.py` can write a table with a tool that this program's code does not have yet.
    public func writtenIn(_ written: Set<String>) -> OwnerTable {
        OwnerTable(tools: tools.map { tool in
            guard tool.kind == .swift, !written.contains(tool.name) else { return tool }
            return Tool(name: tool.name, description: tool.description, inputSchema: tool.inputSchema,
                        annotations: tool.annotations, kind: .later, route: tool.route, fields: tool.fields,
                        what: tool.what, revisionPage: tool.revisionPage,
                        requestIDFromArguments: tool.requestIDFromArguments, feature: tool.feature, whole: tool.whole,
                        nulls: tool.nulls)
        }, instructions: instructions, protocolVersion: protocolVersion, supported: supported, pages: pages,
           pageQuery: pageQuery, pageTakes: pageTakes, pageWords: pageWords, pageInPath: pageInPath,
           historyWords: historyWords, costsWords: costsWords, mediaTypes: mediaTypes, version: version,
           cloudRecipes: cloudRecipes)
    }

    /// Why a table could not be read, in words for an agent.
    public struct Unreadable: Error, Sendable {
        public let text: String
    }

    public static func load(from file: URL) throws -> OwnerTable {
        guard let data = try? Data(contentsOf: file) else {
            throw Unreadable(text: "This program found no table of its tools at \(file.path). The Founderizer app "
                             + "carries one in Contents/Resources/owner-tools.json: install the app again from "
                             + "founderizer.com.")
        }
        return try parse(data, from: file.path)
    }

    public static func parse(_ data: Data, from place: String = "the table") throws -> OwnerTable {
        let broken = Unreadable(text: "The table of this program's tools at \(place) cannot be read. Install the "
                                + "Founderizer app again from founderizer.com.")
        guard let root = JSONValue.parse(data)?.object, let list = root["tools"]?.array else { throw broken }
        func words(_ key: String) throws -> [String] {
            guard let items = root[key]?.array else { throw broken }
            return try items.map { guard let text = $0.string else { throw broken }; return text }
        }
        var tools: [Tool] = []
        for item in list {
            guard let name = item["name"]?.string, let description = item["description"]?.string,
                  let schema = item["inputSchema"], let annotations = item["annotations"],
                  case .string(let said)? = item["kind"] else { throw broken }
            // A kind that this program does not know (a newer owner_mcp.py made the table) is a tool for a later
            // version: refused at the call, and the rest of the table still works.
            let kind = Kind(rawValue: said) ?? .later
            var route = "", fields: [String] = [], what = "", page: String?, fromArguments = true, feature: String?
            var whole: [String] = [], nulls: [String] = [], wait: TimeInterval?
            if kind.built {
                guard let found = item["route"]?.string, let names = item["fields"]?.array,
                      let said = item["what"]?.string else { throw broken }
                route = found
                fields = try names.map { guard let text = $0.string else { throw broken }; return text }
                what = said
                page = item["revision_page"]?.string
                if kind == .withRevision, page == nil { throw broken }
                if case .bool(let given)? = item["request_id_from_args"] { fromArguments = given }
                feature = item["feature"]?.string
                if let names = item["whole"]?.array {
                    whole = try names.map { guard let text = $0.string else { throw broken }; return text }
                }
                if let names = item["nulls"]?.array {
                    nulls = try names.map { guard let text = $0.string else { throw broken }; return text }
                }
                if let given = item["wait"] {
                    guard case .int(let seconds) = given, seconds > 0 else { throw broken }
                    wait = TimeInterval(seconds)
                }
            }
            var tool = Tool(name: name, description: description, inputSchema: schema, annotations: annotations,
                            kind: kind, route: route, fields: fields, what: what, revisionPage: page,
                            requestIDFromArguments: fromArguments, feature: feature, whole: whole, nulls: nulls)
            tool.wait = wait
            tools.append(tool)
        }
        guard let pageMap = root["PAGES"]?.object, let instructions = root["instructions"]?.string,
              let version = root["version"]?.string, let protocolVersion = root["protocol"]?.string else { throw broken }
        var types: [String: String] = [:]
        guard let typeMap = root["MEDIA_TYPES"]?.object else { throw broken }
        for (ending, type) in typeMap {
            guard let text = type.string else { throw broken }
            types[ending] = text
        }
        var pages: [String: (route: String, what: String)] = [:]
        for (name, value) in pageMap {
            guard let pair = value.array, pair.count == 2, let route = pair[0].string, let what = pair[1].string
            else { throw broken }
            pages[name] = (route, what)
        }
        guard let takesMap = root["PAGE_TAKES"]?.object else { throw broken }
        var takes: [String: [String]] = [:]
        for (name, value) in takesMap {
            guard let items = value.array else { throw broken }
            takes[name] = try items.map { guard let text = $0.string else { throw broken }; return text }
        }
        return OwnerTable(tools: tools, instructions: instructions, protocolVersion: protocolVersion,
                          supported: try words("supported"), pages: pages, pageQuery: try words("PAGE_QUERY"),
                          pageTakes: takes, pageWords: try words("PAGE_WORDS"), pageInPath: try words("PAGE_IN_PATH"),
                          historyWords: try words("HISTORY_WORDS"), costsWords: try words("COSTS_WORDS"), mediaTypes: types,
                          version: version, cloudRecipes: root["cloud_recipes"] ?? .null)
    }
}
