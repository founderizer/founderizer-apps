import Foundation

// **The ended tasks that a read of the state leaves out** (owner API 1.254, owner feature `older_tasks`).
//
// `GET /ui/state` held every task that the fleet ever had, with its long texts. On the first fleet, on 20 November
// 2026, that was 6.63 MB of an answer of 8.88 MB for 1,528 tasks, and the answer grew by up to 1.5 MB a day, while
// `HubState.decode` reads at most 16,000,000 bytes: within days every read of the Mac app would have failed.
//
// The Mac asks for the state with `tasks=window`: the tasks that have not ended, and the ended tasks of the newest
// ids. The older ended tasks, with their notes, permissions, holds, outcomes and guidance, come in blocks from
// `GET /ui/tasks/older`. Each block has a mark that moves when its answer changes, so the Mac reads a block once,
// keeps it (also on its disk), and reads it again only when its mark differs. `OlderTasks` joins the blocks to each
// window read, so the reading that the pages draw holds every task, as it did: no page reads a block itself.

/// `older_tasks` of a window read of the state: where the ended tasks that it leaves out are.
public struct OlderTasksHead: Decodable, Sendable, Equatable {
    /// The id below which an ended task is in a block and not in the state. A multiple of `block`.
    public let before: Int
    /// The task ids of one block.
    public let block: Int
    /// A text that differs when a block below `before` changed, or `before` did.
    public let mark: String
    /// The number of the tasks in those blocks: with the tasks of the state, every task of the fleet.
    public let tasks: Int

    public var isValid: Bool { block > 0 && before >= 0 && before % block == 0 && tasks >= 0 && !mark.isEmpty }
}

/// `GET /ui/tasks/older?db=`: the blocks below the window, each with its mark.
public struct OlderList: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        /// The first task id of the block.
        public let from: Int
        public let mark: String
        public let tasks: Int
    }
    public let db: String
    public let before: Int
    public let block: Int
    public let mark: String
    public let blocks: [Entry]

    public static func decode(_ data: Data) throws -> OlderList {
        guard data.count <= 16_000_000 else { throw HubError.invalidResponse }
        let list = try JSONDecoder().decode(Self.self, from: data)
        guard !list.db.isEmpty, !list.mark.isEmpty, list.block > 0, list.before >= 0, list.before % list.block == 0,
              list.blocks.allSatisfy({ $0.from >= 0 && $0.from < list.before && $0.from % list.block == 0 && !$0.mark.isEmpty }),
              Set(list.blocks.map(\.from)).count == list.blocks.count
        else { throw HubError.invalidResponse }
        return list
    }
}

/// `GET /ui/tasks/older?db=&from=`: the ended tasks of one block as the state gives a task, with the rows of theirs
/// that the state gives beside its tasks.
public struct OlderBlock: Decodable, Sendable {
    public let db: String
    public let from: Int
    public let mark: String
    public let tasks: [FleetTask]
    public let notes: [ProgressNote]
    public let permissions: [FleetPermission]
    public let holds: [TaskHold]
    public let outcomes: [TaskOutcome]
    public let steers: [TaskSteer]

    public static func decode(_ data: Data) throws -> OlderBlock {
        guard data.count <= 16_000_000 else { throw HubError.invalidResponse }
        let block = try JSONDecoder().decode(Self.self, from: data)
        guard !block.db.isEmpty, !block.mark.isEmpty, block.from >= 0,
              block.tasks.allSatisfy({ $0.id >= block.from }),
              block.steers.allSatisfy(\.isValid),
              Set(block.tasks.map(\.id)).count == block.tasks.count,
              Set(block.notes.map(\.id)).count == block.notes.count,
              Set(block.permissions.map(\.id)).count == block.permissions.count,
              Set(block.holds.map(\.id)).count == block.holds.count,
              Set(block.outcomes.map(\.id)).count == block.outcomes.count,
              Set(block.steers.map(\.id)).count == block.steers.count
        else { throw HubError.invalidResponse }
        return block
    }
}

/// **The blocks of older tasks that this Mac holds for one fleet, and their join to a window read of the state.**
///
/// `join` gives the reading that the pages draw: the window's rows, then the rows of the blocks, by id. A row of the
/// window stands for a row of the same id in a block (a task that came back to work is the window's).
///
/// **A task that leaves the window stays on the page until its block comes.** A task that ends below the window, and
/// the tasks of a block that the window just left, are in no answer that the Mac holds at that moment: the state no
/// longer has them, and the block that has them is not read yet. `join` keeps the rows that the page showed for
/// them (`waiting`), only while the blocks are not the hub's own of that moment (`current` differs from the state's
/// mark). When they are, a task that is in neither the window nor a block is gone from the fleet, and it leaves.
public struct OlderTasks: Sendable {
    /// The fleet's generation whose blocks these are.
    public private(set) var db: String?
    /// The blocks, by their first task id.
    public private(set) var blocks: [Int: OlderBlock] = [:]
    /// The mark of the state at which every block here is the hub's own (`finish`), or nil: not known.
    public private(set) var current: String?
    /// The mark of the state at which the read of the blocks rests although a block is not the hub's own: that
    /// block's answer could not be read `tries` times at its mark (`fail`). Nothing asks for it again while the
    /// state's mark stands, and the rows that the pages showed for its tasks stay (`waiting`). At each new mark of
    /// the state it is asked for one more time (`wanted`): the hub's fault can be gone by then.
    public private(set) var rested: String?
    /// The blocks whose answer could not be read, by their first id: the mark that it had, and how many times.
    private var failed: [Int: Failure] = [:]
    private var waiting = Rows()
    /// The reads of one block at one mark that fail before the Mac lets it rest.
    public static let tries = 3

    private struct Failure: Sendable {
        let mark: String
        var times: Int
    }

    struct Rows: Sendable {
        var tasks: [FleetTask] = []
        var notes: [ProgressNote] = []
        var permissions: [FleetPermission] = []
        var holds: [TaskHold] = []
        var outcomes: [TaskOutcome] = []
        var steers: [TaskSteer] = []
    }

    public init() {}

    /// The blocks that this Mac kept on its disk, for the reading of the same generation that it kept with them.
    /// Whether they are the hub's own of now is not known: the first read of the state says its mark, and the list
    /// then says which of them to read again.
    public init(kept: [OlderBlock], db: String) {
        self.db = db
        for block in kept where block.db == db { blocks[block.from] = block }
    }

    /// Whether the blocks must be read: the state leaves tasks out, and its mark is neither the one that these
    /// blocks are current at nor the one that their read rests at.
    public func isBehind(_ window: HubState) -> Bool {
        guard let head = window.older_tasks, head.isValid else { return false }
        return db != window.db || (current != head.mark && rested != head.mark)
    }

    /// The blocks of the list that this Mac reads now: each one whose mark differs from the block that it holds,
    /// the newest first. A block whose answer could not be read `tries` times at that mark is left out while the
    /// read rests at this list's mark, and asked for once more at a list with a new mark.
    public func wanted(_ list: OlderList) -> [OlderList.Entry] {
        guard list.db == db else { return [] }
        let again = rested != nil && rested != list.mark
        return list.blocks.filter { blocks[$0.from]?.mark != $0.mark && (again || !gaveUp($0)) }.sorted { $0.from > $1.from }
    }

    private func gaveUp(_ entry: OlderList.Entry) -> Bool {
        failed[entry.from].map { $0.mark == entry.mark && $0.times >= Self.tries } ?? false
    }

    /// Takes one block that the hub gave. A block of another generation is none of this fleet's.
    public mutating func take(_ block: OlderBlock) {
        guard block.db == db else { return }
        blocks[block.from] = block
        failed[block.from] = nil
    }

    /// **The answer of one block could not be read** (`blockFailed`): the read of the blocks goes on with the next
    /// block, and this one is asked for again at the next reads, `tries` times in all at this mark. A block with a
    /// new mark is a new answer, and counts from one.
    public mutating func fail(_ entry: OlderList.Entry) {
        let times = failed[entry.from].map { $0.mark == entry.mark ? $0.times + 1 : 1 } ?? 1
        failed[entry.from] = Failure(mark: entry.mark, times: times)
    }

    /// Whether an error of a block's read is of that block's own answer: the hub gave one that this app cannot
    /// read, or could not make it (a 5xx). Then the other blocks are still read. Every other error ends the read
    /// of the blocks, and the next read of the state starts it again: the hub did not answer, the generation moved
    /// (409), or the window came down over the block (404), which the next list no longer names.
    public static func blockFailed(_ error: Error) -> Bool {
        switch error {
        case is DecodingError, HubError.invalidResponse: true
        case HubError.refusal(let refusal): refusal.status >= 500
        default: false
        }
    }

    /// After the blocks that the list asked for were read: the blocks that the list does not name leave (the window
    /// came down over them), and when each block has the list's mark, the blocks are current at the list's own mark.
    /// A block that changed between the list and its read has a later mark: then the next list settles it. When the
    /// only blocks that differ are ones whose answer could not be read (`fail`), the read rests at the list's mark.
    /// It gives the blocks that left, so that their files can leave too.
    @discardableResult
    public mutating func finish(_ list: OlderList) -> [Int] {
        guard list.db == db else { return [] }
        let named = Set(list.blocks.map(\.from))
        let left = blocks.keys.filter { !named.contains($0) }
        for from in left { blocks[from] = nil }
        failed = failed.filter { named.contains($0.key) }
        let behind = list.blocks.filter { blocks[$0.from]?.mark != $0.mark }
        if behind.isEmpty {
            current = list.mark
            rested = nil
        } else if behind.allSatisfy(gaveUp) {
            rested = list.mark
        }
        return left.sorted()
    }

    /// **The reading that the pages draw for this window read**: its rows and the rows of the blocks, by id.
    /// `shown` is the reading that the pages drew until now, from which the rows of a task come that is in no
    /// answer yet (see the type's own words). A state that leaves no task out is given back as it is, and the
    /// blocks leave: the hub is older than the blocks, or its marks are not in place.
    public mutating func join(_ window: HubState, shown: HubState?) -> HubState {
        guard let head = window.older_tasks, head.isValid else {
            self = OlderTasks()
            return window
        }
        if db != window.db {
            self = OlderTasks()
            db = window.db
        }
        let held = blocks.values.filter { $0.from < head.before }.sorted { $0.from < $1.from }
        var known = Set(window.tasks.map(\.id))
        for block in held { known.formUnion(block.tasks.map(\.id)) }
        if current == head.mark {
            waiting = Rows()
        } else if let shown, shown.db == window.db {
            let ids = Set(shown.tasks.lazy.map(\.id).filter { $0 < head.before && !known.contains($0) })
            waiting = ids.isEmpty ? Rows() : Rows(
                tasks: shown.tasks.filter { ids.contains($0.id) }, notes: shown.notes.filter { ids.contains($0.task) },
                permissions: shown.permissions.filter { ids.contains($0.task) },
                holds: (shown.holds ?? []).filter { ids.contains($0.task) },
                outcomes: (shown.outcomes ?? []).filter { ids.contains($0.task) },
                steers: (shown.steers ?? []).filter { ids.contains($0.task) })
        } else {
            waiting = Rows()
        }
        var joined = window
        joined.older_tasks = nil        // every task that this Mac holds is in `tasks`
        joined.tasks = Self.byID(window.tasks, held.map(\.tasks) + [waiting.tasks])
        joined.notes = Self.byID(window.notes, held.map(\.notes) + [waiting.notes])
        joined.permissions = Self.byID(window.permissions, held.map(\.permissions) + [waiting.permissions])
        // A hub that sends no holds, outcomes or guidance has none in its blocks either, and nil stays nil.
        if window.holds != nil || held.contains(where: { !$0.holds.isEmpty }) || !waiting.holds.isEmpty {
            joined.holds = Self.byID(window.holds ?? [], held.map(\.holds) + [waiting.holds])
        }
        if window.outcomes != nil || held.contains(where: { !$0.outcomes.isEmpty }) || !waiting.outcomes.isEmpty {
            joined.outcomes = Self.byID(window.outcomes ?? [], held.map(\.outcomes) + [waiting.outcomes])
        }
        if window.steers != nil || held.contains(where: { !$0.steers.isEmpty }) || !waiting.steers.isEmpty {
            joined.steers = Self.byID(window.steers ?? [], held.map(\.steers) + [waiting.steers])
        }
        return joined
    }

    /// The rows of `first` and then of each of `more` whose id no earlier row has, in the order of their ids: the
    /// order in which the hub gives the rows of the whole state.
    private static func byID<Row: Identifiable>(_ first: [Row], _ more: [[Row]]) -> [Row] where Row.ID == Int {
        guard more.contains(where: { !$0.isEmpty }) else { return first }
        var seen = Set(first.map(\.id))
        var rows = first
        for part in more {
            for row in part where seen.insert(row.id).inserted { rows.append(row) }
        }
        return rows.sorted { $0.id < $1.id }
    }
}
