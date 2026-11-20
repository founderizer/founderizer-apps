import Foundation

// **The Needs-you items, reports and messages that a read of the state leaves out** (owner API 1.258, owner feature
// `older_rows`).
//
// The window of the tasks (owner API 1.254) left three lists of `GET /ui/state` with every row. On the first fleet, on
// 20 November 2026, they were 1.25 MB of a window read of 2.63 MB, and they grew by about 0.15 MB a day, while
// `HubState.decode` reads at most 16,000,000 bytes.
//
// The Mac asks for the state with `rest=window` too: the items that are open, and the items, reports and messages of
// the newest keys. The older rows come in blocks from `GET /ui/older`, one list at a time. Each block has a mark that
// moves when its answer changes, so the Mac reads a block once, keeps it (also on its disk), and reads it again only
// when its mark differs. `OlderRows` joins the blocks to each window read, so the reading that the pages draw holds
// every item, report and message, as it did: no page reads a block itself.

/// The three lists of `older_rows`, by their names in the hub's answers.
public enum OlderRowsList: String, CaseIterable, Sendable {
    case needs, reports, messages
}

/// One list of `older_rows` of a window read of the state: where the rows are that it leaves out.
public struct OlderRowsHead: Decodable, Sendable, Equatable {
    /// The key below which a row is in a block and not in the state (an open item is in the state). A multiple of
    /// `block`.
    public let before: Int
    /// The keys of one block.
    public let block: Int
    /// A text that differs when a block below `before` changed, or `before` did.
    public let mark: String
    /// The number of the rows in those blocks.
    public let rows: Int

    public var isValid: Bool { block > 0 && before >= 0 && before % block == 0 && rows >= 0 && !mark.isEmpty }

    /// The first key of the block that holds a row of this key, or nil for a key of the window (at or above `before`)
    /// and a key below 0, which no block has: a reader that looks an item up by its id, an answered one too, reads that
    /// block when the window does not hold it (the app's engines of a key request and of the door card).
    public func block(of key: Int) -> Int? { block > 0 && key >= 0 && key < before ? key - key % block : nil }
}

/// `older_rows` of a window read: the head of each list.
public struct OlderRowsHeads: Decodable, Sendable, Equatable {
    public let needs: OlderRowsHead?
    public let reports: OlderRowsHead?
    public let messages: OlderRowsHead?

    public subscript(_ list: OlderRowsList) -> OlderRowsHead? {
        switch list {
        case .needs: needs
        case .reports: reports
        case .messages: messages
        }
    }

    public var isValid: Bool { OlderRowsList.allCases.allSatisfy { self[$0]?.isValid ?? true } }
}

/// `GET /ui/older?db=&list=`: the blocks of one list below the window, each with its mark.
public struct OlderRowsIndex: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        /// The first key of the block.
        public let from: Int
        public let mark: String
        public let rows: Int
    }
    public let db: String
    public let list: String
    public let before: Int
    public let block: Int
    public let mark: String
    public let blocks: [Entry]

    public static func decode(_ data: Data) throws -> OlderRowsIndex {
        guard data.count <= 16_000_000 else { throw HubError.invalidResponse }
        let index = try JSONDecoder().decode(Self.self, from: data)
        guard !index.db.isEmpty, OlderRowsList(rawValue: index.list) != nil, !index.mark.isEmpty, index.block > 0,
              index.before >= 0, index.before % index.block == 0,
              index.blocks.allSatisfy({ $0.from >= 0 && $0.from < index.before && $0.from % index.block == 0 && !$0.mark.isEmpty }),
              Set(index.blocks.map(\.from)).count == index.blocks.count
        else { throw HubError.invalidResponse }
        return index
    }
}

/// `GET /ui/older?db=&list=&from=`: the older rows of one block, as the state gives them, under the list's own name.
public struct OlderRowsBlock: Decodable, Sendable {
    public let db: String
    public let list: String
    public let from: Int
    public let mark: String
    public let needs: [OwnerNeed]?
    public let reports: [ManagerReport]?
    public let messages: [OwnerMessage]?

    public var kind: OlderRowsList? { OlderRowsList(rawValue: list) }

    public static func decode(_ data: Data) throws -> OlderRowsBlock {
        guard data.count <= 16_000_000 else { throw HubError.invalidResponse }
        let block = try JSONDecoder().decode(Self.self, from: data)
        guard !block.db.isEmpty, !block.mark.isEmpty, block.from >= 0, let kind = block.kind else {
            throw HubError.invalidResponse
        }
        // A block holds its own list and no other, each row once; an item of it has its answer (an open item is the
        // window's), and an item or a report has an id of the block's keys at the least.
        let good = switch kind {
        case .needs:
            block.reports == nil && block.messages == nil && block.needs.map { needs in
                Set(needs.map(\.id)).count == needs.count && needs.allSatisfy { $0.answer != nil && $0.id >= block.from }
            } == true
        case .reports:
            block.needs == nil && block.messages == nil && block.reports.map { reports in
                Set(reports.map(\.id)).count == reports.count && reports.allSatisfy { $0.id >= block.from }
            } == true
        case .messages:
            block.needs == nil && block.reports == nil
                && block.messages.map { Set($0.map(\.id)).count == $0.count } == true
        }
        guard good else { throw HubError.invalidResponse }
        return block
    }
}

/// **The blocks of older items, reports and messages that this Mac holds for one fleet, and their join to a window
/// read of the state**, as `OlderTasks` holds the blocks of older tasks (read its words): each list on its own, with
/// its own mark. A row of the window stands for a row of the same id in a block (an item that is open again is the
/// window's), and a row that left the window stays on the page until its block comes.
public struct OlderRows: Sendable {
    /// The fleet's generation whose blocks these are.
    public private(set) var db: String?
    private var parts: [OlderRowsList: Part] = [:]
    /// The reads of one block at one mark that fail before the Mac lets it rest (as `OlderTasks.tries`).
    public static let tries = 3

    /// The blocks of one list.
    struct Part: Sendable {
        var blocks: [Int: OlderRowsBlock] = [:]
        /// The number of keys of the blocks here, once a list or a block named it; nil for blocks that this Mac kept on
        /// its disk. A list of another size is another set of blocks.
        var size: Int?
        /// The mark of the state at which every block here is the hub's own, or nil: not known.
        var current: String?
        /// The mark at which the read of the blocks rests although a block is not the hub's own (`OlderTasks.rested`).
        var rested: String?
        var failed: [Int: Failure] = [:]

        func sized(_ size: Int) -> Bool { self.size == nil || self.size == size }
    }

    struct Failure: Sendable {
        let mark: String
        var times: Int
    }

    public init() {}

    /// The blocks that this Mac kept on its disk, for the reading of the same generation that it kept with them.
    /// Whether they are the hub's own of now is not known: the first read of the state says its marks.
    public init(kept: [OlderRowsBlock], db: String) {
        self.db = db
        for block in kept where block.db == db {
            guard let kind = block.kind else { continue }
            parts[kind, default: Part()].blocks[block.from] = block
        }
    }

    /// The blocks of one list that this Mac holds, by their first key.
    public func blocks(_ list: OlderRowsList) -> [Int: OlderRowsBlock] { parts[list]?.blocks ?? [:] }

    /// The lists whose blocks must be read: the state leaves rows out, and its mark of the list is neither the one that
    /// its blocks are current at nor the one that their read rests at.
    public func behind(_ window: HubState) -> [OlderRowsList] {
        guard let heads = window.older_rows, heads.isValid else { return [] }
        return OlderRowsList.allCases.filter { list in
            guard let head = heads[list] else { return false }
            let part = parts[list]
            return db != window.db || (part?.current != head.mark && part?.rested != head.mark)
        }
    }

    /// The blocks of a list that this Mac reads now: each one whose mark differs from the block that it holds, the
    /// newest first, but one whose answer could not be read `tries` times at that mark while the read rests at the
    /// list's mark (it is asked for once more at a list with a new mark).
    public func wanted(_ index: OlderRowsIndex) -> [OlderRowsIndex.Entry] {
        guard index.db == db, let list = OlderRowsList(rawValue: index.list) else { return [] }
        let part = parts[list] ?? Part()
        let held = part.sized(index.block) ? part.blocks : [:]
        let again = part.rested != nil && part.rested != index.mark
        return index.blocks.filter { held[$0.from]?.mark != $0.mark && (again || !Self.gaveUp($0, part)) }
            .sorted { $0.from > $1.from }
    }

    private static func gaveUp(_ entry: OlderRowsIndex.Entry, _ part: Part) -> Bool {
        part.failed[entry.from].map { $0.mark == entry.mark && $0.times >= tries } ?? false
    }

    /// The part of a list for blocks of `size` keys: the blocks of another size leave.
    private mutating func part(_ list: OlderRowsList, size: Int) -> Part {
        var part = parts[list] ?? Part()
        if !part.sized(size) { part = Part() }
        part.size = size
        return part
    }

    /// Takes one block that the hub gave, of a list of `size` keys. A block of another generation is none of this
    /// fleet's.
    public mutating func take(_ block: OlderRowsBlock, size: Int) {
        guard block.db == db, let list = block.kind else { return }
        var part = part(list, size: size)
        part.blocks[block.from] = block
        part.failed[block.from] = nil
        parts[list] = part
    }

    /// The answer of one block could not be read (`OlderTasks.blockFailed`): it is asked for again at the next reads,
    /// `tries` times in all at its mark.
    public mutating func fail(_ entry: OlderRowsIndex.Entry, of list: OlderRowsList) {
        var part = parts[list] ?? Part()
        let times = part.failed[entry.from].map { $0.mark == entry.mark ? $0.times + 1 : 1 } ?? 1
        part.failed[entry.from] = Failure(mark: entry.mark, times: times)
        parts[list] = part
    }

    /// After the blocks that the list asked for were read: the blocks that it does not name leave (the window came down
    /// over them), and when each block has the list's mark, the list's blocks are current at its mark; when the only
    /// blocks that differ are ones whose answer could not be read, the read rests at that mark. It gives the blocks
    /// that left, so that their files can leave too.
    @discardableResult
    public mutating func finish(_ index: OlderRowsIndex) -> [Int] {
        guard index.db == db, let list = OlderRowsList(rawValue: index.list) else { return [] }
        let before = Set(parts[list].map { Array($0.blocks.keys) } ?? [])
        var part = part(list, size: index.block)
        let named = Set(index.blocks.map(\.from))
        for from in part.blocks.keys where !named.contains(from) { part.blocks[from] = nil }
        part.failed = part.failed.filter { named.contains($0.key) }
        let behind = index.blocks.filter { part.blocks[$0.from]?.mark != $0.mark }
        if behind.isEmpty {
            part.current = index.mark
            part.rested = nil
        } else if behind.allSatisfy({ Self.gaveUp($0, part) }) {
            part.rested = index.mark
        }
        parts[list] = part
        return before.subtracting(part.blocks.keys).sorted()
    }

    /// **The reading that the pages draw for this window read**: its items, reports and messages and the rows of the
    /// blocks, in the order of the whole state (the items and the reports by id, the messages by their time and their
    /// request id). `shown` is the reading that the pages drew until now: while the blocks of a list are not the hub's
    /// own of this window (`current`), a row that it showed and that no answer holds stays, because it left the window
    /// and its block is not read yet; then a row that is in no answer is gone from the fleet, and it leaves. A state
    /// that leaves no row out is given back as it is, and the blocks leave: the hub is older than the blocks, or its
    /// marks are not in place.
    public mutating func join(_ window: HubState, shown: HubState?) -> HubState {
        guard let heads = window.older_rows, heads.isValid else {
            self = OlderRows()
            return window
        }
        if db != window.db {
            self = OlderRows()
            db = window.db
        }
        var joined = window
        joined.older_rows = nil         // every row that this Mac holds is in the lists
        let previous = shown.flatMap { $0.db == window.db ? $0 : nil }
        if let head = heads.needs {
            let held = held(.needs, head).flatMap { $0.needs ?? [] }
            let known = Set(window.needs.map(\.id) + held.map(\.id))
            // An open item is in every window: one that the pages showed as open and that the window no longer holds is
            // open no more (answered, or gone), so its open card does not wait, nor its count on the Dock; its answered
            // row comes with its block.
            let waiting = waits(.needs, head) ? (previous?.needs ?? []).filter {
                $0.id < head.before && !known.contains($0.id) && !$0.isOpen
            } : []
            joined.needs = Self.unique(window.needs + held + waiting, id: \.id).sorted { $0.id < $1.id }
        }
        if let head = heads.reports {
            let held = held(.reports, head).flatMap { $0.reports ?? [] }
            let known = Set(window.reports.map(\.id) + held.map(\.id))
            let waiting = waits(.reports, head) ? (previous?.reports ?? []).filter { $0.id < head.before && !known.contains($0.id) } : []
            joined.reports = Self.unique(window.reports + held + waiting, id: \.id).sorted { $0.id < $1.id }
        }
        if let head = heads.messages {
            let held = held(.messages, head).flatMap { $0.messages ?? [] }
            let known = Set(window.messages.map(\.id) + held.map(\.id))
            // A message gives no key: every message that the pages showed and that no answer holds waits.
            let waiting = waits(.messages, head) ? (previous?.messages ?? []).filter { !known.contains($0.id) } : []
            joined.messages = Self.unique(window.messages + held + waiting, id: \.id)
                .sorted { ($0.created, $0.request_id) < ($1.created, $1.request_id) }
        }
        return joined
    }

    /// The blocks of a list below the window, oldest first, when they are of the head's size.
    private func held(_ list: OlderRowsList, _ head: OlderRowsHead) -> [OlderRowsBlock] {
        guard let part = parts[list], part.sized(head.block) else { return [] }
        return part.blocks.values.filter { $0.from < head.before }.sorted { $0.from < $1.from }
    }

    /// Whether the rows of a list that the pages showed and that no answer holds wait for their block: only while
    /// the list's blocks are not the hub's own of this window.
    private func waits(_ list: OlderRowsList, _ head: OlderRowsHead) -> Bool { parts[list]?.current != head.mark }

    /// The rows in their first place, each id once: a row of the window stands for a row of the same id in a block.
    private static func unique<Row, ID: Hashable>(_ rows: [Row], id: KeyPath<Row, ID>) -> [Row] {
        var seen = Set<ID>()
        return rows.filter { seen.insert($0[keyPath: id]).inserted }
    }
}
