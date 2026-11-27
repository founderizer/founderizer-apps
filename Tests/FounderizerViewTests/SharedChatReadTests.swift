import FleetCore
import Foundation
import Testing
@testable import Founderizer

@Suite(.serialized) @MainActor
struct SharedChatReadTests {
    private actor Replies {
        var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    @Test func chatSwitchReusesFleetDataUntilAWriteOrExpiry() async throws {
        let center = NotificationCenter()
        let state = try ViewHost.reading(needs: [], features: [])
        let store = ViewHost.store(state, pageWrites: center)
        let replies = Replies()
        let item = PagePrefetch("shared", sharedAcrossAgents: true) { _, _ in await replies.next() }
        for agent in ["one", "two"] {
            #expect(await store.prefetch(item, agent: agent, hub: store.hub, database: state.db))
        }
        #expect(await replies.count == 1)
        let received = try #require(store.readingKept("shared"))
        #expect(store.canReuseFleetReading("shared", at: received + .seconds(14)))
        #expect(!store.canReuseFleetReading("shared", at: received + .seconds(15)))

        let beforeSave = store.pageReadStart()
        center.post(name: HubWrites.answered, object: nil)
        #expect(!store.keep(0, as: "shared", from: beforeSave))
        #expect(await store.prefetch(item, agent: "one", hub: store.hub, database: state.db))
        #expect((store.reading("shared") as Int?) == 2)
    }

    @Test func joiningAnOlderRequestCannotReplaceANewerIndependentAnswer() async throws {
        let store = ViewHost.store(try ViewHost.reading(needs: [], features: []), pageWrites: NotificationCenter())
        let began = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<String>.makeStream()
        let firstStart = store.pageReadStart()
        let first = Task {
            try await store.read("people", from: firstStart) {
                began.continuation.yield(())
                for await value in gate.stream { return value }
                throw CancellationError()
            }
        }
        var signal = began.stream.makeAsyncIterator()
        _ = await signal.next()
        let independent = store.pageReadStart()
        #expect(store.keep("new", as: "people", from: independent))
        let late = store.pageReadStart()
        let close = Task {
            try await Task.sleep(for: .milliseconds(250))
            gate.continuation.yield("old")
            gate.continuation.finish()
        }
        let joined = try await store.read("people", from: late) { "separate request" }
        try await close.value
        #expect(try await first.value == "old")
        #expect(joined == "old")
        #expect(!store.keep(joined, as: "people", from: late))
        #expect((store.reading("people") as String?) == "new")
    }

    @Test func canceledPageAndFormerFleetCannotPublishInTheCurrentFleet() async throws {
        let store = ViewHost.store(try ViewHost.reading(needs: [], features: []), pageWrites: NotificationCenter())
        let start = store.pageReadStart()
        let published = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return store.keep("obsolete", as: "resources", from: start)
        }.value
        #expect(!published)
        #expect((store.reading("resources") as String?) == nil)
        await #expect(throws: CancellationError.self) {
            _ = try await AccessSettings.readResources(store, hub: store.hub, database: "former-database")
        }
    }

    @Test func lateReplyCannotReplaceANewerReplyOrCrossFleets() throws {
        let store = ViewHost.store(try ViewHost.reading(needs: [], features: []), pageWrites: NotificationCenter())
        let older = store.pageReadStart()
        let newer = store.pageReadStart()
        #expect(store.keep("after", as: "people", from: newer))
        #expect(!store.keep("before", as: "people", from: older))
        #expect((store.reading("people") as String?) == "after")
        store.state = try ViewHost.reading(needs: [], features: [])
        #expect(!store.keep("wrong fleet", as: "people", from: newer))
        #expect((store.reading("people") as String?) == nil)
        #expect(!store.canReuseFleetReading("people"))
    }
}
