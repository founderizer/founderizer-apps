import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: a fleet of twelve Needs-you items, twelve reports and twelve messages, as the hub gives them
// whole, as a window of the newest keys with the open items, and as the blocks of the older rows (owner API 1.258). A
// block holds four keys here, and the window begins at 8. The key of a message is its number in its request id, as
// the hub's own rowid, which no answer gives.
struct OlderRowsTests {
    private static let block = 4, before = 8

    private func need(_ id: Int, open: Bool = false, title: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "title": title ?? "Item \(id)", "why": "Why \(id)", "todo": "Say yes",
                                  "raised": 100.0 + Double(id), "by": "manager"]
        if !open { row["answer"] = "Yes"; row["answered"] = 200.0 + Double(id) }
        return row
    }

    private func report(_ id: Int) -> [String: Any] {
        ["id": id, "text": "Report \(id)", "about": "the export", "created": 300.0 + Double(id), "agent": "manager"]
    }

    private func message(_ n: Int, created: Double? = nil) -> [String: Any] {
        ["request_id": "msg-\(n)", "kind": "message", "text": "Message \(n)", "event_id": 1000 + n,
         "created": created ?? 400.0 + Double(n), "client": "mac-app", "recipient": "manager"]
    }

    /// The rows of the whole fleet: items 1 to 12, of which 3 and 11 are open; reports and messages 1 to 12.
    private var rows: [String: [[String: Any]]] {
        ["needs": (1...12).map { need($0, open: [3, 11].contains($0)) }, "reports": (1...12).map(report),
         "messages": (1...12).map { message($0) }]
    }

    private func key(_ row: [String: Any]) -> Int {
        (row["id"] as? Int) ?? Int((row["request_id"] as! String).dropFirst(4))!
    }

    /// Whether the window holds this row of a list: its key is at or above `before`, or it is an open item.
    private func inWindow(_ list: String, _ row: [String: Any], before: Int = Self.before) -> Bool {
        key(row) >= before || (list == "needs" && row["answer"] == nil)
    }

    private func state(_ rows: [String: [[String: Any]]], db: String = "db", older: [String: Any]? = nil) throws -> HubState {
        var fields: [String: Any] = ["schema_version": 1, "db": db, "time": 1000.0, "tasks": [], "notes": [], "permissions": [],
                                     "agents": [["name": "manager", "role": "manager", "runtime": "codex", "can": []]]]
        for (key, list) in rows { fields[key] = list }
        if let older { fields["older_rows"] = older }
        return try HubState.decode(JSONSerialization.data(withJSONObject: fields))
    }

    /// `older_rows` of a window read of these rows: each list's rows that the window leaves out, counted.
    private func heads(_ rows: [String: [[String: Any]]], _ mark: String, before: Int = Self.before) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: OlderRowsList.allCases.map { list in
            let left = (rows[list.rawValue] ?? []).filter { !inWindow(list.rawValue, $0, before: before) }.count
            return (list.rawValue, ["before": before, "block": Self.block, "mark": mark, "rows": left] as [String: Any])
        })
    }

    /// The window read of these rows, as the hub gives it.
    private func window(_ rows: [String: [[String: Any]]], mark: String = "8.5", db: String = "db",
                        before: Int = Self.before) throws -> HubState {
        try state(Dictionary(uniqueKeysWithValues: rows.map { list, all in (list, all.filter { inWindow(list, $0, before: before) }) }),
                  db: db, older: heads(rows, mark, before: before))
    }

    /// The block of one list of these rows that begins at `from`, as the hub gives it.
    private func olderBlock(_ list: OlderRowsList, _ rows: [String: [[String: Any]]], from: Int, mark: String,
                            db: String = "db", before: Int = Self.before) throws -> OlderRowsBlock {
        let held = rows[list.rawValue]!.filter {
            (from..<from + Self.block).contains(key($0)) && !inWindow(list.rawValue, $0, before: before)
        }
        return try OlderRowsBlock.decode(JSONSerialization.data(withJSONObject: [
            "db": db, "list": list.rawValue, "from": from, "mark": mark, list.rawValue: held] as [String: Any]))
    }

    private func index(_ list: OlderRowsList, _ mark: String, _ marks: [Int: String], db: String = "db",
                       before: Int = Self.before, block: Int = Self.block) throws -> OlderRowsIndex {
        try OlderRowsIndex.decode(JSONSerialization.data(withJSONObject: [
            "db": db, "list": list.rawValue, "before": before, "block": block, "mark": mark, "rows": 6,
            "blocks": marks.sorted { $0.key < $1.key }.map { ["from": $0.key, "mark": $0.value, "rows": 3] }] as [String: Any]))
    }

    /// The blocks of these rows as a Mac holds them when they are current at the state's mark.
    private func current(_ rows: [String: [[String: Any]]], mark: String = "8.5") throws -> OlderRows {
        var older = OlderRows(kept: try OlderRowsList.allCases.flatMap {
            [try olderBlock($0, rows, from: 0, mark: "2"), try olderBlock($0, rows, from: 4, mark: "3")]
        }, db: "db")
        for list in OlderRowsList.allCases { older.finish(try index(list, mark, [0: "2", 4: "3"])) }
        return older
    }

    private func keys(_ state: HubState) -> [[String]] {
        [state.needs.map { String($0.id) }, state.reports.map { String($0.id) }, state.messages.map(\.request_id)]
    }

    /// The bug that this catches: a page that reads `state.needs`, `state.reports` or `state.messages` finds fewer rows
    /// than the fleet has (the Needs-you board's answered items, a chat scrolled back, an edit's "already answered"),
    /// a row twice, or the rows out of the order of the whole state.
    @Test func theWindowJoinedWithTheBlocksIsTheWholeLists() throws {
        let whole = try state(rows)
        var older = try current(rows)
        let joined = older.join(try window(rows), shown: nil)
        #expect(keys(joined) == keys(whole))
        #expect(joined.needs.map(\.title) == whole.needs.map(\.title) && joined.messages == whole.messages)
        #expect(joined.reports == whole.reports && joined.older_rows == nil, "a joined reading holds every row itself")
        let alone = try window(rows)
        #expect(alone.needs.map(\.id) == [3, 8, 9, 10, 11, 12], "the window holds the open items and the newest keys")
        // What the restore page says a hub holds counts the rows that the read leaves out (`FleetHolds`).
        #expect(FleetHolds(alone).needs == 12 && FleetHolds(alone).reports == 12 && alone.needCount == 12)
        // The messages come in the order of their time, which is not the order of their keys, as the hub orders them.
        var late = rows
        late["messages"] = late["messages"]!.map { key($0) == 2 ? message(2, created: 999) : $0 }
        var lateOlder = try current(late)
        let ordered = lateOlder.join(try window(late), shown: nil)
        #expect(ordered.messages.map(\.request_id).suffix(2) == ["msg-12", "msg-2"])
    }

    /// The bug that this catches: the rows of a block that the window just left are gone from every page for the
    /// moment between the read of the state that no longer has them and the read of their block (an open chat loses the
    /// message that the owner reads); or an item that he answered below the window stays open on its card and on the
    /// Dock's count until its block comes, where he can press it again.
    @Test func aRowThatLeftTheWindowStaysOnThePageUntilItsBlockComes() throws {
        var older = try current(rows)
        let shown = older.join(try window(rows), shown: nil)
        var answered = rows
        answered["needs"] = answered["needs"]!.map { key($0) == 3 ? need(3, title: "Item 3, answered") : $0 }
        let next = try window(answered, mark: "8.6")
        #expect(!next.needs.contains { $0.id == 3 } && older.behind(next) == OlderRowsList.allCases)
        let waiting = older.join(next, shown: shown)
        #expect(waiting.needs.filter(\.isOpen).map(\.id) == [11], "an open item that the window no longer holds is open no more")
        #expect(!waiting.needs.contains { $0.id == 3 } && waiting.needs.count == 11)
        let listed = try index(.needs, "8.6", [0: "4", 4: "3"])
        #expect(older.wanted(listed).map(\.from) == [0])
        older.take(try olderBlock(.needs, answered, from: 0, mark: "4"), size: Self.block)
        older.finish(listed)
        #expect(older.join(next, shown: waiting).needs.first { $0.id == 3 }?.title == "Item 3, answered")
        // The window moves up a block: the messages 8 to 11 leave it, and stay until their block comes.
        let up = try window(rows, mark: "12.9", before: 12)
        #expect(up.messages.map(\.request_id) == ["msg-12"])
        let moved = older.join(up, shown: shown)
        #expect(moved.messages.map(\.request_id) == shown.messages.map(\.request_id))
        older.take(try olderBlock(.messages, rows, from: 8, mark: "1", before: 12), size: Self.block)
        older.finish(try index(.messages, "12.9", [0: "2", 4: "3", 8: "1"], before: 12))
        #expect(older.join(up, shown: moved).messages == shown.messages)
    }

    /// The bug that this catches: a message that left the fleet's records (its agent was removed) stays in a chat for
    /// ever, because the Mac kept it "until its block comes", and no block has it.
    @Test func aRowThatIsInNoAnswerWhileTheBlocksAreCurrentLeavesThePage() throws {
        var older = try current(rows)
        let shown = older.join(try window(rows), shown: nil)
        var gone = rows
        gone["messages"] = gone["messages"]!.filter { key($0) != 9 }
        gone["reports"] = gone["reports"]!.filter { key($0) != 10 }
        let next = older.join(try window(gone), shown: shown)      // the same marks: no block changed
        #expect(!next.messages.contains { $0.request_id == "msg-9" } && !next.reports.contains { $0.id == 10 })
        #expect(next.messages.count == 11 && next.reports.count == 11)
    }

    /// The bug that this catches: the blocks that the Mac kept on its disk are all read again at each launch, because
    /// a kept block names no size; or blocks of another size are joined to a window of another one.
    @Test func keptBlocksAreReadAgainOnlyWhenTheirMarksDiffer() throws {
        var older = OlderRows(kept: [try olderBlock(.reports, rows, from: 0, mark: "2"),
                                     try olderBlock(.reports, rows, from: 4, mark: "3")], db: "db")
        #expect(try older.behind(window(rows)) == OlderRowsList.allCases, "kept blocks are of an unknown moment")
        let listed = try index(.reports, "8.5", [0: "2", 4: "9"])
        #expect(older.wanted(listed).map(\.from) == [4])
        older.take(try olderBlock(.reports, rows, from: 4, mark: "9"), size: Self.block)
        #expect(older.finish(listed).isEmpty && older.blocks(.reports).keys.sorted() == [0, 4], "the kept block 0 stays")
        #expect(try !older.behind(window(rows)).contains(.reports))
        // A list of blocks of 8 keys is another set of blocks: each is read, and the blocks of 4 keys leave.
        let wider = try index(.reports, "8.7", [0: "5"], block: 8)
        #expect(older.wanted(wider).map(\.from) == [0])
        #expect(older.finish(wider) == [0, 4] && older.blocks(.reports).isEmpty)
    }

    /// The bug that this catches: one bad answer of the hub makes a reading with an item twice, an open item in a block
    /// (the window has it too), or the rows of another list, and the pages draw it.
    @Test func aBlockAListAndAHeadThatDoNotHoldTogetherAreRefused() throws {
        func refused(_ fields: [String: Any], _ decode: (Data) throws -> Any) -> Bool {
            (try? decode(JSONSerialization.data(withJSONObject: fields))) == nil
        }
        let base: [String: Any] = ["db": "db", "list": "needs", "from": 4, "mark": "3"]
        #expect(!refused(base.merging(["needs": [need(5), need(6)]]) { $1 }, OlderRowsBlock.decode))
        #expect(refused(base.merging(["needs": [need(5), need(5)]]) { $1 }, OlderRowsBlock.decode), "an item twice")
        #expect(refused(base.merging(["needs": [need(5, open: true)]]) { $1 }, OlderRowsBlock.decode), "an open item")
        #expect(refused(base.merging(["needs": [need(2)]]) { $1 }, OlderRowsBlock.decode), "an item below the block")
        #expect(refused(base.merging(["needs": [], "reports": [report(5)]]) { $1 }, OlderRowsBlock.decode), "another list")
        #expect(refused(base.merging(["list": "tasks", "needs": []]) { $1 }, OlderRowsBlock.decode), "no list of these")
        #expect(refused(base.merging(["list": "messages", "messages": [message(5), message(5)]]) { $1 }, OlderRowsBlock.decode))
        let listed: [String: Any] = ["db": "db", "list": "reports", "before": 8, "block": 4, "mark": "8.5", "rows": 6]
        #expect(!refused(listed.merging(["blocks": [["from": 0, "mark": "2", "rows": 3]]]) { $1 }, OlderRowsIndex.decode))
        #expect(refused(listed.merging(["blocks": [["from": 8, "mark": "2", "rows": 3]]]) { $1 }, OlderRowsIndex.decode), "the window's")
        #expect(refused(listed.merging(["blocks": [["from": 2, "mark": "2", "rows": 3]]]) { $1 }, OlderRowsIndex.decode))
        #expect(refused(listed.merging(["list": "tasks", "blocks": []]) { $1 }, OlderRowsIndex.decode))
        #expect((try? state(rows, older: ["needs": ["before": 6, "block": 4, "mark": "6.1", "rows": 2]])) == nil,
                "no multiple of the block")
    }

    /// The bug that this catches: the Mac asks for a list or a block by a route or a word that the hub does not have,
    /// or takes the answer of another list or block for the one that it asked for.
    @Test func theMacAsksForTheRowsOfAListByItsRouteAndAFirstKey() async throws {
        let block = String(decoding: try JSONSerialization.data(withJSONObject: [
            "db": "db", "list": "messages", "from": 300, "mark": "7", "messages": [message(301)]] as [String: Any]), as: UTF8.self)
        let blocks = try OneAnswer(status: "200 OK") { _ in block }
        let got = try await HubClient().olderRowsBlock(at: URL(string: "http://127.0.0.1:\(blocks.port)")!, database: "db",
                                                       list: .messages, from: 300)
        #expect(blocks.received.starts(with: Data("GET /ui/older?db=db&list=messages&from=300 HTTP/1.1\r\n".utf8)))
        #expect(got.block.messages?.map(\.request_id) == ["msg-301"] && got.block.mark == "7")
        let other = try OneAnswer(status: "200 OK") { _ in block }
        await #expect(throws: HubError.self) {
            _ = try await HubClient().olderRowsBlock(at: URL(string: "http://127.0.0.1:\(other.port)")!, database: "db",
                                                     list: .reports, from: 300)
        }
        // An engine that looks an item up by its id, an answered one too (a key request, a door card), reads the one
        // block of an item that the window does not hold: the block of its key, and none for a key of the window.
        let head = OlderRowsHead(before: 400, block: 50, mark: "50.400.9", rows: 380)
        #expect(head.block(of: 371) == 350 && head.block(of: 0) == 0 && head.block(of: 399) == 350)
        #expect(head.block(of: 400) == nil && head.block(of: -1) == nil)
        let listed = #"{"db":"db","list":"needs","before":400,"block":50,"mark":"400.9","rows":380,"blocks":[{"from":300,"mark":"7","rows":50}]}"#
        let lists = try OneAnswer(status: "200 OK") { _ in listed }
        let index = try await HubClient().olderRows(at: URL(string: "http://127.0.0.1:\(lists.port)")!, database: "db", list: .needs)
        #expect(lists.received.starts(with: Data("GET /ui/older?db=db&list=needs HTTP/1.1\r\n".utf8)))
        #expect(index.blocks == [OlderRowsIndex.Entry(from: 300, mark: "7", rows: 50)])
        let foreign = try OneAnswer(status: "200 OK") { _ in listed }
        await #expect(throws: HubError.self) {
            _ = try await HubClient().olderRows(at: URL(string: "http://127.0.0.1:\(foreign.port)")!, database: "db", list: .messages)
        }
    }

    /// The bug that this catches: the blocks of one fleet are joined to the reading of another (a restore gives the hub
    /// a new generation), or to the whole state of a hub that leaves no row out, which then has each row twice.
    @Test func anotherGenerationAndAHubWithNoWindowKeepNoBlock() throws {
        var older = try current(rows)
        let other = older.join(try window(rows, db: "db-2"), shown: nil)
        #expect(other.reports.map(\.id) == [8, 9, 10, 11, 12] && older.blocks(.reports).isEmpty && older.db == "db-2")
        older.take(try olderBlock(.reports, rows, from: 0, mark: "2"), size: Self.block)
        #expect(older.blocks(.reports).isEmpty, "a block of another generation is not taken")
        var kept = try current(rows)
        let whole = try state(rows)                 // a hub from before the window, or one whose marks are not in place
        #expect(kept.behind(whole).isEmpty)
        #expect(keys(kept.join(whole, shown: nil)) == keys(whole) && kept.blocks(.needs).isEmpty)
        let files = OlderRows(kept: [try olderBlock(.needs, rows, from: 0, mark: "2", db: "db-0"),
                                     try olderBlock(.needs, rows, from: 4, mark: "3")], db: "db")
        #expect(files.blocks(.needs).keys.sorted() == [4])
        // The first window read after the update keeps the rows of the whole reading that the Mac kept.
        var fresh = OlderRows()
        #expect(keys(fresh.join(try window(rows), shown: whole)) == keys(whole))
    }
}
