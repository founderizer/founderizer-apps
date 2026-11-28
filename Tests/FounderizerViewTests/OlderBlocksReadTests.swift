import FleetCore
import Foundation
import Observation
import os
import Testing
@testable import Founderizer

/// **A read of the hub's blocks that changed none of them draws no page again, and a block that changed comes to the
/// pages before the next reading** (`FleetStore.showOlder`; the launch probe of 26 November 2026). Each launch that kept
/// its blocks reads the hub's list of them once, to learn that they are the hub's own. When every mark agreed, the store
/// set its state again with the same rows, and each view that reads the state ran again (the chat with its 60 rows, two
/// times in the launch's first 1.4 s). The bugs that this catches: a read that changed no block sets the state (each
/// view that reads it runs again); a block that the hub changed, with the same rows by id, comes to the pages only at
/// the next reading; the rows of a block that the hub's list names no more, with no block taken, stay on the pages
/// until the next reading.
@Suite(.serialized, .timeLimit(.minutes(10))) struct OlderBlocksReadTests {
    static let now = Int(Date().timeIntervalSince1970)
    static let kept = "Find the old build files"

    struct Seen: Sendable, Equatable {
        /// The store set its state while the hub's list and block were read: a view that reads it runs again.
        let setState: Bool
        /// The tasks of the pages after the read: id and title.
        let tasks: [String]
        /// The read ended, and the hub was asked for the block only when its mark moved.
        let readEnded: Bool
        let askedForTheBlock: Bool
    }

    static func task(_ id: Int, _ title: String) -> [String: Any] {
        ["id": id, "title": title, "details": "", "done_when": "Checked", "needs": "none", "goal": "", "owner": "manager",
         "requester": "owner", "state": "completed", "created": now - 900 + id, "attempt": 1, "restarts": 0,
         "nudge_level": 0, "stop_sent": 0, "started": now - 890, "last_activity": now - 800]
    }

    /// The block of tasks 0 to 3 at `mark`, as the hub and this Mac's disk keep it.
    static func block(db: String, mark: String, tasks: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "db": db, "from": 0, "mark": mark, "tasks": tasks, "notes": [], "permissions": [], "holds": [],
            "outcomes": [], "steers": []] as [String: Any])
    }

    /// A store that kept a reading of `hub` and its one block of older tasks (task 1, `kept`, at mark "m1"), after the
    /// hub's first reading; then the hub's list names the block at `mark` (or no block, `named` false), and the hub's
    /// block at that mark holds `tasks`. Whether the store set its state while the list and the block were read, and
    /// what the pages hold then.
    @MainActor static func read(mark: String, tasks: [[String: Any]], named: Bool = true) throws -> Seen {
        let db = "older-read-\(UUID().uuidString)"
        let head: [String: Any] = ["before": 4, "block": 4, "mark": "w-\(mark)", "tasks": tasks.count]
        let window = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": db, "time": now,
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [], "messages": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [],
            "reports": [], "older_tasks": head, "ui_features": ["direct_chat"]] as [String: Any])
        let hub = try LoopbackHub(state: window)
        defer { hub.stop() }
        // The list waits until the test watches the state: the reading's own state comes before it.
        let watching = DispatchSemaphore(value: 0)
        let list = try JSONSerialization.data(withJSONObject: [
            "db": db, "before": 4, "block": 4, "mark": "w-\(mark)",
            "blocks": named ? [["from": 0, "mark": mark, "tasks": tasks.count]] : []] as [String: Any])
        let block = try Self.block(db: db, mark: mark, tasks: tasks)
        hub.answer("GET", "/ui/tasks/older") { request in
            if request.query.contains("from=") { return (status: 200, body: block) }
            _ = watching.wait(timeout: .now() + 20)
            return (status: 200, body: list)
        }
        // The kept reading and its block, on the test's own folder (`ViewHost`), for the hub's address.
        _ = ViewHost.store(try HubState.decode(window))
        let folder = AppFolders.support.appendingPathComponent("Founderizer")
        guard folder.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            throw ViewHost.Missing(description: "the app's folder is not the test's: \(folder.path)")
        }
        defer { try? FileManager.default.removeItem(at: folder) }      // the test's folder only: after the guard
        let address = try HubClient.address(hub.address)
        let blocks = StartAgain.olderFolder(of: address, in: folder)
        try FileManager.default.createDirectory(at: blocks, withIntermediateDirectories: true)
        try window.write(to: folder.appendingPathComponent("state-127.0.0.1-\(hub.port).json"))
        try Self.block(db: db, mark: "m1", tasks: [Self.task(1, Self.kept)]).write(to: blocks.appendingPathComponent("0.json"))
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        guard store.state?.tasks.map(\.title) == [Self.kept] else {
            throw ViewHost.Missing(description: "the store did not start from its kept block")
        }
        Task { await store.refresh() }
        // The hub's reading is the state now, and its list is asked for.
        guard ViewHost.turn(20, until: { hub.requests.contains { $0.path == "/ui/tasks/older" } }) else {
            watching.signal()
            throw ViewHost.Missing(description: "the store did not ask the hub for its list of blocks")
        }
        let stateSet = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = store.state } onChange: { stateSet.withLock { $0 = true } }
        watching.signal()
        let ended = ViewHost.turn(20) { !store.readsOlderBlocks }
        return Seen(setState: stateSet.withLock { $0 }, tasks: (store.state?.tasks ?? []).map { "\($0.id) \($0.title)" },
                    readEnded: ended, askedForTheBlock: hub.requests.contains { $0.query.contains("from=0") })
    }

    @Test func aListWhoseMarksAgreeSetsNoState() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { try Self.read(mark: "m1", tasks: [Self.task(1, Self.kept)]) }
        #expect(seen == Seen(setState: false, tasks: ["1 \(Self.kept)"], readEnded: true, askedForTheBlock: false))
    }

    @Test func aBlockWithTheSameRowsChangedComesBeforeTheNextReading() async throws {
        let (seen, _) = try await ViewHost.onMainLoop {
            try Self.read(mark: "m2", tasks: [Self.task(1, "Find the old build files again")])
        }
        #expect(seen == Seen(setState: true, tasks: ["1 Find the old build files again"], readEnded: true,
                             askedForTheBlock: true))
    }

    /// No block is taken here: the rows that leave are what the store sees (`FleetStore.sameRows`).
    @Test func theRowsOfABlockThatTheListNamesNoMoreLeaveBeforeTheNextReading() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { try Self.read(mark: "m1", tasks: [], named: false) }
        #expect(seen == Seen(setState: true, tasks: [], readEnded: true, askedForTheBlock: false))
    }
}
