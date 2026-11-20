import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: a fleet of twelve tasks, as the hub gives it whole, as a window of its newest tasks, and
// as the blocks of the older ones (owner API 1.254). A block holds four task ids here, and the window begins at 8.
struct OlderTasksTests {
    private static let block = 4, before = 8

    private func task(_ id: Int, _ state: String = "completed", title: String? = nil) -> [String: Any] {
        ["id": id, "title": title ?? "Task \(id)", "details": "The long words of task \(id)", "done_when": "Checked",
         "needs": "none", "goal": "", "owner": "dev", "requester": "manager", "state": state, "created": 100.0 + Double(id),
         "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
    }

    private func note(_ id: Int, task: Int) -> [String: Any] {
        ["id": id, "task": task, "agent": "dev", "ts": 200.0 + Double(id), "text": "A note of task \(task)"]
    }

    private func hold(_ id: Int, task: Int) -> [String: Any] {
        ["id": id, "task": task, "kind": "stop", "state": "released", "attempt": 1]
    }

    private func outcome(_ id: Int, task: Int) -> [String: Any] {
        ["id": id, "task": task, "attempt": 1, "title": "A send", "kind": "send", "state": "resolved"]
    }

    private func permission(_ id: Int, task: Int) -> [String: Any] {
        ["id": id, "task": task, "agent": "dev", "tool": "Bash", "input": "{}", "key": "k\(id)", "created": 300.0]
    }

    private func steer(_ id: Int, task: Int) -> [String: Any] {
        ["id": id, "task": task, "attempt": 1, "text": "Do it this way", "created": 400.0, "request_id": "r\(id)", "client": "mac"]
    }

    /// The rows of the whole fleet: tasks 1 to 12, of which 3 and 11 have not ended, and a row of each kind for the
    /// tasks 2, 3, 6 and 10.
    private var rows: [String: [[String: Any]]] {
        ["tasks": (1...12).map { task($0, [3, 11].contains($0) ? "working" : "completed") },
         "notes": [note(1, task: 2), note(2, task: 3), note(3, task: 6), note(4, task: 10)],
         "holds": [hold(1, task: 2), hold(2, task: 3), hold(3, task: 6), hold(4, task: 10)],
         "outcomes": [outcome(1, task: 2), outcome(2, task: 3), outcome(3, task: 6), outcome(4, task: 10)],
         "permissions": [permission(1, task: 2), permission(2, task: 3), permission(3, task: 6), permission(4, task: 10)],
         "steers": [steer(1, task: 2), steer(2, task: 3), steer(3, task: 6), steer(4, task: 10)]]
    }

    private func taskOf(_ row: [String: Any]) -> Int { (row["task"] ?? row["id"]) as! Int }

    /// Whether the window holds the rows of this task: it has not ended, or its id is at or above `before`.
    private func inWindow(_ task: Int, of rows: [String: [[String: Any]]]) -> Bool {
        task >= Self.before || rows["tasks"]!.contains { $0["id"] as? Int == task && $0["state"] as? String == "working" }
    }

    private func state(_ rows: [String: [[String: Any]]], db: String = "db", older: [String: Any]? = nil) throws -> HubState {
        var fields: [String: Any] = ["schema_version": 1, "db": db, "time": 1000.0, "needs": [], "messages": [], "reports": [],
                                     "agents": [["name": "manager", "role": "manager", "runtime": "codex", "can": []]]]
        for (key, list) in rows { fields[key] = list }
        if let older { fields["older_tasks"] = older }
        return try HubState.decode(JSONSerialization.data(withJSONObject: fields))
    }

    private func head(_ mark: String, tasks: Int = 6) -> [String: Any] {
        ["before": Self.before, "block": Self.block, "mark": mark, "tasks": tasks]
    }

    /// The window read of these rows, as the hub gives it.
    private func window(_ rows: [String: [[String: Any]]], mark: String = "8.5", db: String = "db") throws -> HubState {
        try state(rows.mapValues { list in list.filter { inWindow(taskOf($0), of: rows) } }, db: db, older: head(mark))
    }

    /// The block of these rows that begins at `from`, as the hub gives it.
    private func olderBlock(_ rows: [String: [[String: Any]]], from: Int, mark: String, db: String = "db") throws -> OlderBlock {
        var fields: [String: Any] = ["db": db, "from": from, "mark": mark]
        for (key, list) in rows {
            fields[key] = list.filter { (from..<from + Self.block).contains(taskOf($0)) && !inWindow(taskOf($0), of: rows) }
        }
        return try OlderBlock.decode(JSONSerialization.data(withJSONObject: fields))
    }

    private func list(_ mark: String, _ marks: [Int: String], db: String = "db") throws -> OlderList {
        try OlderList.decode(JSONSerialization.data(withJSONObject: [
            "db": db, "before": Self.before, "block": Self.block, "mark": mark, "tasks": 6,
            "blocks": marks.sorted { $0.key < $1.key }.map { ["from": $0.key, "mark": $0.value, "tasks": 3] }]))
    }

    /// The blocks of these rows as a Mac holds them when they are current at the state's mark.
    private func current(_ rows: [String: [[String: Any]]], mark: String = "8.5") throws -> OlderTasks {
        var older = OlderTasks(kept: [try olderBlock(rows, from: 0, mark: "2"), try olderBlock(rows, from: 4, mark: "3")], db: "db")
        older.finish(try list(mark, [0: "2", 4: "3"]))
        return older
    }

    private func ids(_ state: HubState) -> [[Int]] {
        [state.tasks.map(\.id), state.notes.map(\.id), (state.holds ?? []).map(\.id), (state.outcomes ?? []).map(\.id),
         state.permissions.map(\.id), (state.steers ?? []).map(\.id)]
    }

    /// The bug that this catches: a page that reads `state.tasks` finds fewer tasks than the fleet has (its board
    /// with the period All, its search, a chat's rows of what he asked for, a task page by its number), a task
    /// twice, or the rows out of the order of their ids.
    @Test func theWindowJoinedWithTheBlocksIsTheWholeState() throws {
        let whole = try state(rows)
        var older = try current(rows)
        let joined = older.join(try window(rows), shown: nil)
        #expect(ids(joined) == ids(whole))
        #expect(joined.tasks.map(\.details) == whole.tasks.map(\.details))
        #expect(joined.notes.map(\.text) == whole.notes.map(\.text))
        #expect(joined.older_tasks == nil && joined.taskCount == 12, "a joined reading holds every task itself")
        // The window alone holds the tasks that have not ended and the newest ids, and says how many more there are.
        let alone = try window(rows)
        #expect(alone.tasks.map(\.id) == [3, 8, 9, 10, 11, 12] && alone.taskCount == 12)
        #expect(FleetHolds(alone).tasks == 12, "what a hub holds counts the tasks that the read leaves out")
    }

    /// The bug that this catches: a task that ends below the window is gone from every page for the moment between
    /// the read of the state that no longer has it and the read of its block; an open task page shows "Task not
    /// found".
    @Test func aTaskThatEndsBelowTheWindowStaysOnThePageUntilItsBlockComes() throws {
        var older = try current(rows)
        let shown = older.join(try window(rows), shown: nil)
        var ended = rows
        ended["tasks"] = ended["tasks"]!.map { $0["id"] as? Int == 3 ? task(3, "completed", title: "Task 3, done") : $0 }
        // The state no longer has task 3, and its mark is a new one: the block is not read yet.
        let next = try window(ended, mark: "8.6")
        #expect(!next.tasks.contains { $0.id == 3 } && older.isBehind(next))
        let waiting = older.join(next, shown: shown)
        #expect(ids(waiting) == ids(shown), "the task and its rows stay as the page showed them")
        #expect(waiting.tasks.first { $0.id == 3 }?.state == "working")
        // The list names the block's new mark, the block comes, and the task is the block's.
        let listed = try list("8.6", [0: "4", 4: "3"])
        #expect(older.wanted(listed).map(\.from) == [0])
        older.take(try olderBlock(ended, from: 0, mark: "4"))
        older.finish(listed)
        #expect(!older.isBehind(next))
        let settled = older.join(next, shown: waiting)
        #expect(ids(settled) == ids(shown))
        #expect(settled.tasks.first { $0.id == 3 }?.title == "Task 3, done")
    }

    /// The bug that this catches: a task that left the fleet's records (a person's removal clears their tasks) stays
    /// on the Tasks board as work for ever, because the Mac kept its row "until its block comes" and no block has it.
    @Test func aTaskThatIsInNoAnswerWhileTheBlocksAreCurrentLeavesThePage() throws {
        var older = try current(rows)
        let shown = older.join(try window(rows), shown: nil)
        var gone = rows
        for key in gone.keys { gone[key] = gone[key]!.filter { taskOf($0) != 3 } }
        let next = older.join(try window(gone), shown: shown)      // the same mark: no block changed
        #expect(!next.tasks.contains { $0.id == 3 } && !next.notes.contains { $0.task == 3 })
        #expect(next.tasks.count == 11)
    }

    /// The bug that this catches: after the update that brings the window, the first read takes the older tasks off
    /// every page until the blocks have come, though the Mac kept them all in its last reading.
    @Test func theFirstWindowReadKeepsTheTasksOfTheWholeReadingThatTheMacKept() throws {
        let kept = try state(rows)                  // the last reading of the app before this change: every task
        var older = OlderTasks()
        let first = older.join(try window(rows), shown: kept)
        #expect(ids(first) == ids(kept))
        #expect(try older.isBehind(window(rows)), "and the blocks are read")
        #expect(try older.wanted(list("8.5", [0: "2", 4: "3"])).map(\.from) == [4, 0], "the newest block first")
    }

    /// The bug that this catches: a task that came back to work is on the board twice, or as ended, because the
    /// block that the Mac holds still has it.
    @Test func aRowOfTheWindowStandsForTheSameRowOfABlock() throws {
        var older = try current(rows)
        var back = rows
        back["tasks"] = back["tasks"]!.map { $0["id"] as? Int == 2 ? task(2, "working", title: "Task 2, again") : $0 }
        let joined = older.join(try window(back, mark: "8.6"), shown: nil)
        #expect(joined.tasks.filter { $0.id == 2 }.map(\.title) == ["Task 2, again"])
        #expect(try ids(joined) == ids(state(rows)), "and each of its rows is there once")
    }

    /// The bug that this catches: the Mac reads every block again at each change, or never reads a block that
    /// changed after the list was read, or keeps the blocks of ids that the window covers again.
    @Test func theMacReadsTheBlocksWhoseMarksDifferAndIsCurrentWhenAllAgree() throws {
        var older = OlderTasks(kept: [try olderBlock(rows, from: 0, mark: "2"), try olderBlock(rows, from: 4, mark: "3"),
                                      try olderBlock(rows, from: 12, mark: "1")], db: "db")
        #expect(try older.current == nil && older.isBehind(window(rows)), "kept blocks are of an unknown moment")
        let listed = try list("8.5", [0: "2", 4: "9"])
        #expect(older.wanted(listed).map(\.from) == [4])
        // The block changed again between the list and its read: its mark is a later one, so nothing is current yet.
        older.take(try olderBlock(rows, from: 4, mark: "10"))
        #expect(older.finish(listed) == [12], "a block that the list does not name leaves")
        #expect(older.current == nil && older.blocks.keys.sorted() == [0, 4])
        let again = try list("8.7", [0: "2", 4: "10"])
        #expect(older.wanted(again).isEmpty)
        #expect(older.wanted(try list("8.7", [0: "2", 4: "10"], db: "db-2")).isEmpty, "a list of another generation asks for none")
        older.finish(again)
        #expect(try older.current == "8.7" && !older.isBehind(window(rows, mark: "8.7")))
        #expect(try older.isBehind(window(rows, mark: "8.8")), "a new mark of the state asks for the list again")
    }

    /// The bug that this catches: about three times a day the newest task id passes a block, and the tasks of the
    /// block that the window leaves are gone from every page until their block is read.
    @Test func theWindowMovesUpABlockAndItsTasksStayUntilTheirBlockComes() throws {
        var older = try current(rows)
        let shown = older.join(try window(rows), shown: nil)
        // The window begins at 12 now: 8, 9 and 10 ended and are a new block; 11 has not ended and stays.
        func moved(_ list: [[String: Any]]) -> [[String: Any]] {
            list.filter { let task = taskOf($0); return task >= 12 || [3, 11].contains(task) }
        }
        let up = try state(rows.mapValues(moved), older: ["before": 12, "block": Self.block, "mark": "12.9", "tasks": 9])
        #expect(up.tasks.map(\.id) == [3, 11, 12] && older.isBehind(up))
        let waiting = older.join(up, shown: shown)
        #expect(ids(waiting) == ids(shown), "the tasks 8 to 10 and the rows of 10 stay as the page showed them")
        var block: [String: Any] = ["db": "db", "from": 8, "mark": "1"]
        for (key, list) in rows { block[key] = list.filter { [8, 9, 10].contains(taskOf($0)) } }
        older.take(try OlderBlock.decode(JSONSerialization.data(withJSONObject: block)))
        older.finish(try OlderList.decode(JSONSerialization.data(withJSONObject: [
            "db": "db", "before": 12, "block": Self.block, "mark": "12.9", "tasks": 9,
            "blocks": [["from": 0, "mark": "2", "tasks": 3], ["from": 4, "mark": "3", "tasks": 3], ["from": 8, "mark": "1", "tasks": 3]]])))
        #expect(older.current == "12.9")
        #expect(ids(older.join(up, shown: waiting)) == ids(shown))
    }

    /// The bug that this catches: after tasks left the fleet's records the window comes down over a block that the
    /// Mac holds, and the pages show a task of that block that is gone, or a task twice.
    @Test func aBlockThatTheWindowCoversAgainIsNotJoined() throws {
        var older = try current(rows)
        // The window begins at 4 now, and task 6 with its rows is gone from the records.
        func down(_ list: [[String: Any]]) -> [[String: Any]] {
            list.filter { let task = taskOf($0); return task != 6 && (task >= 4 || task == 3) }
        }
        let low = try state(rows.mapValues(down), older: ["before": 4, "block": Self.block, "mark": "4.2", "tasks": 2])
        let joined = older.join(low, shown: nil)
        #expect(joined.tasks.map(\.id) == [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12], "block 0 and the window, and no task 6")
        #expect(joined.notes.map(\.task) == [2, 3, 10])
    }

    /// The bug that this catches: one block whose answer the app cannot read stops the read of every block after
    /// it, at each read of the state, for ever; or the Mac asks for that block again every three seconds.
    @Test func aBlockThatCannotBeReadRestsAfterThreeTriesAndTheOthersAreRead() throws {
        var older = OlderTasks()
        let first = older.join(try window(rows), shown: nil)
        let listed = try list("8.5", [0: "2", 4: "3"])
        for round in 1...OlderTasks.tries {
            #expect(older.wanted(listed).map(\.from) == (round == 1 ? [4, 0] : [4]), "round \(round)")
            for entry in older.wanted(listed) {
                if entry.from == 4 { older.fail(entry) } else { older.take(try olderBlock(rows, from: 0, mark: "2")) }
            }
            older.finish(listed)
            #expect(older.current == nil)
        }
        #expect(older.wanted(listed).isEmpty && older.rested == "8.5")
        #expect(try !older.isBehind(window(rows)), "nothing asks again while the state's mark stands")
        #expect(older.join(try window(rows), shown: first).tasks.map(\.id) == [1, 2, 3, 8, 9, 10, 11, 12])
        // A new mark of the state with the same mark of the block: one more try, and then it rests at the new mark.
        let moved = try list("8.55", [0: "2", 4: "3"])
        #expect(try older.isBehind(window(rows, mark: "8.55")))
        #expect(older.wanted(moved).map(\.from) == [4], "the hub's fault can be gone")
        older.fail(moved.blocks[1])
        older.finish(moved)
        #expect(older.rested == "8.55" && older.wanted(moved).isEmpty)
        // A new mark of the block is a new answer: it is asked for again, and a good answer ends the rest.
        let later = try list("8.6", [0: "2", 4: "4"])
        #expect(try older.isBehind(window(rows, mark: "8.6")))
        #expect(older.wanted(later).map(\.from) == [4])
        older.take(try olderBlock(rows, from: 4, mark: "4"))
        older.finish(later)
        #expect(older.current == "8.6" && older.rested == nil)
    }

    /// The bug that this catches: a hub that does not answer for some seconds makes the Mac give its blocks up, or
    /// an answer that the app cannot read is asked for without an end.
    @Test func onlyAnAnswerOfTheBlockItselfCountsAsItsFailure() {
        let unread = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        #expect(OlderTasks.blockFailed(unread) && OlderTasks.blockFailed(HubError.invalidResponse))
        #expect(OlderTasks.blockFailed(HubError.refusal(.read(status: 500, body: Data()))))
        #expect(!OlderTasks.blockFailed(HubError.refusal(.read(status: 404, body: Data()))), "the window came down over it")
        #expect(!OlderTasks.blockFailed(HubError.refusal(.read(status: 409, body: Data()))), "the generation moved")
        #expect(!OlderTasks.blockFailed(URLError(.timedOut)) && !OlderTasks.blockFailed(CancellationError()))
    }

    /// The bug that this catches: the blocks of one fleet are joined to the reading of another (a restore gives the
    /// hub a new generation), or to the whole state of a hub that leaves no task out, which then has each task twice.
    @Test func anotherGenerationAndAHubWithNoWindowKeepNoBlock() throws {
        var older = try current(rows)
        let other = older.join(try window(rows, db: "db-2"), shown: nil)
        #expect(other.tasks.map(\.id) == [3, 8, 9, 10, 11, 12] && older.blocks.isEmpty && older.db == "db-2")
        older.take(try olderBlock(rows, from: 0, mark: "2"))
        #expect(older.blocks.isEmpty, "a block of another generation is not taken")

        var kept = try current(rows)
        let whole = try state(rows)                 // a hub from before the window, or one whose marks are not in place
        #expect(!kept.isBehind(whole))
        #expect(ids(kept.join(whole, shown: nil)) == ids(whole) && kept.blocks.isEmpty)

        // The files of the generation of before are no blocks of this one, and a reading of that generation gives
        // no rows to this one.
        let files = OlderTasks(kept: [try olderBlock(rows, from: 0, mark: "2", db: "db-0"), try olderBlock(rows, from: 4, mark: "3")],
                               db: "db")
        #expect(files.blocks.keys.sorted() == [4])
        var fresh = OlderTasks()
        #expect(fresh.join(try window(rows, db: "db-2"), shown: try state(rows)).tasks.count == 6)
    }

    /// The bug that this catches: a hub that sends no holds, outcomes or guidance (an older one) gets empty lists of
    /// them from the join, and the pages take that for a hub that has the features.
    @Test func aStateWithoutHoldsOutcomesAndGuidanceKeepsNone() throws {
        var bare = rows
        for key in ["holds", "outcomes", "steers"] { bare[key] = nil }
        var older = OlderTasks(kept: [try olderBlock(bare.merging(["holds": [], "outcomes": [], "steers": []]) { $1 }, from: 0, mark: "2")],
                               db: "db")
        let joined = older.join(try window(bare), shown: nil)
        #expect(joined.holds == nil && joined.outcomes == nil && joined.steers == nil)
        #expect(joined.tasks.map(\.id) == [1, 2, 3, 8, 9, 10, 11, 12])
    }

    /// The bug that this catches: one bad answer of the hub makes a reading with a task twice, or with the tasks of
    /// another block, and the pages draw it.
    @Test func ABlockAListAndAHeadThatDoNotHoldTogetherAreRefused() throws {
        func refused(_ fields: [String: Any], _ decode: (Data) throws -> Any) -> Bool {
            (try? decode(JSONSerialization.data(withJSONObject: fields))) == nil
        }
        let base: [String: Any] = ["db": "db", "from": 4, "mark": "3", "notes": [], "permissions": [], "holds": [],
                                   "outcomes": [], "steers": []]
        #expect(!refused(base.merging(["tasks": [task(5), task(6)]]) { $1 }, OlderBlock.decode))
        #expect(refused(base.merging(["tasks": [task(5), task(5)]]) { $1 }, OlderBlock.decode), "a task twice")
        #expect(refused(base.merging(["tasks": [task(2)]]) { $1 }, OlderBlock.decode), "a task below the block")
        #expect(refused(base.merging(["tasks": [], "mark": ""]) { $1 }, OlderBlock.decode))
        let listed: [String: Any] = ["db": "db", "before": 8, "block": 4, "mark": "8.5", "tasks": 6]
        #expect(!refused(listed.merging(["blocks": [["from": 0, "mark": "2", "tasks": 3]]]) { $1 }, OlderList.decode))
        #expect(refused(listed.merging(["blocks": [["from": 8, "mark": "2", "tasks": 3]]]) { $1 }, OlderList.decode), "a block of the window")
        #expect(refused(listed.merging(["blocks": [["from": 2, "mark": "2", "tasks": 3]]]) { $1 }, OlderList.decode), "no first id of a block")
        #expect(refused(listed.merging(["blocks": [["from": 0, "mark": "2", "tasks": 3], ["from": 0, "mark": "3", "tasks": 3]]]) { $1 },
                        OlderList.decode), "a block twice")
        #expect((try? state(rows, older: ["before": 6, "block": 4, "mark": "6.1", "tasks": 2])) == nil, "no multiple of the block")
        #expect((try? state(rows, older: ["before": 8, "block": 0, "mark": "8.1", "tasks": 2])) == nil)
    }

    /// The bug that this catches: the Mac asks for the whole state again, which fails past 16,000,000 bytes, or asks
    /// for a block by a route that the hub does not have.
    @Test func theMacAsksForTheWindowAndForABlockByItsFirstID() async throws {
        let answer = String(decoding: try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "db", "time": 1000.0, "needs": [], "messages": [], "reports": [], "tasks": [], "notes": [],
            "permissions": [], "agents": [["name": "manager", "role": "manager", "runtime": "codex", "can": []]],
            "older_tasks": ["before": 400, "block": 100, "mark": "400.9", "tasks": 380]]), as: UTF8.self)
        let hub = try OneAnswer(status: "200 OK") { _ in answer }
        let read = try await HubClient().stateReading(at: URL(string: "http://127.0.0.1:\(hub.port)")!)
        #expect(hub.received.starts(with: Data("GET /ui/state?tasks=window&rest=window HTTP/1.1\r\n".utf8)))
        #expect(read.state.older_tasks == OlderTasksHead(before: 400, block: 100, mark: "400.9", tasks: 380))

        let block = String(decoding: try JSONSerialization.data(withJSONObject: [
            "db": "db", "from": 300, "mark": "7", "tasks": [task(301)], "notes": [], "permissions": [], "holds": [],
            "outcomes": [], "steers": []]), as: UTF8.self)
        let blocks = try OneAnswer(status: "200 OK") { _ in block }
        let got = try await HubClient().olderBlock(at: URL(string: "http://127.0.0.1:\(blocks.port)")!, database: "db", from: 300)
        #expect(blocks.received.starts(with: Data("GET /ui/tasks/older?db=db&from=300 HTTP/1.1\r\n".utf8)))
        #expect(got.block.tasks.map(\.id) == [301] && got.block.mark == "7")
        // An answer that is another block, or of another generation, is not the block that was asked for.
        let other = try OneAnswer(status: "200 OK") { _ in block }
        await #expect(throws: HubError.self) {
            _ = try await HubClient().olderBlock(at: URL(string: "http://127.0.0.1:\(other.port)")!, database: "db", from: 200)
        }
        let listed = #"{"db":"db","before":400,"block":100,"mark":"400.9","tasks":380,"blocks":[{"from":300,"mark":"7","tasks":90}]}"#
        let lists = try OneAnswer(status: "200 OK") { _ in listed }
        let got2 = try await HubClient().olderList(at: URL(string: "http://127.0.0.1:\(lists.port)")!, database: "db")
        #expect(lists.received.starts(with: Data("GET /ui/tasks/older?db=db HTTP/1.1\r\n".utf8)))
        #expect(got2.blocks == [OlderList.Entry(from: 300, mark: "7", tasks: 90)])
        let foreign = try OneAnswer(status: "200 OK") { _ in listed }
        await #expect(throws: HubError.self) {
            _ = try await HubClient().olderList(at: URL(string: "http://127.0.0.1:\(foreign.port)")!, database: "db-2")
        }
    }
}
