import Foundation
import Testing
@testable import FleetCore

/// **One read of a route at a time** (the fix round of 29 October 2026): Settings › Apps asked `/ui/team` six times and
/// `/ui/resources` eight times in 0.6 s as it opened. A read asked for while the same one is on its way shares it.
///
/// Every test listens to a center of its own: the suite runs beside tests whose writes post `HubWrites.answered` on the
/// default center, and a write answered between two reads rightly makes the second a read of its own (a flake under the
/// full run, 29 October 2026).
struct HubReadsTests {
    private actor Count {
        var reads = 0
        var stopped = false
        func add() { reads += 1 }
        func stop() { stopped = true }
    }

    private static func answer(_ text: String) -> HubReads.Answer { HubReads.Answer(data: Data(text.utf8), response: nil) }
    private static func words(_ answer: HubReads.Answer) -> String { String(decoding: answer.data, as: UTF8.self) }

    @Test func identicalReadsOnTheirWayShareOneRequest() async throws {
        let reads = HubReads(center: NotificationCenter()), count = Count()
        let read: @Sendable () async throws -> HubReads.Answer = {
            await count.add()
            try await Task.sleep(for: .milliseconds(300))
            return Self.answer("one")
        }
        async let first = reads.share("get /ui/team", read)
        async let second = reads.share("get /ui/team", read)
        let (a, b) = try await (first, second)
        #expect(Self.words(a) == "one")
        #expect(Self.words(b) == "one")
        #expect(await count.reads == 1)
        #expect(reads.inFlight == 0)
    }

    @Test func twoRoutesAreTwoReadsAndAReadAfterTheAnswerIsANewOne() async throws {
        let reads = HubReads(center: NotificationCenter()), count = Count()
        let read: @Sendable () async throws -> HubReads.Answer = {
            await count.add()
            try await Task.sleep(for: .milliseconds(100))
            return Self.answer("read")
        }
        async let team = reads.share("get /ui/team", read)
        async let machines = reads.share("get /ui/machines", read)
        _ = try await (team, machines)
        #expect(await count.reads == 2)
        // Nothing is kept: the same read after its answer goes to the hub again.
        _ = try await reads.share("get /ui/team", read)
        #expect(await count.reads == 3)
    }

    @Test func aCancelledCallerStopsWaitingAndTheOtherStillGetsTheAnswer() async throws {
        let reads = HubReads(center: NotificationCenter())
        let read: @Sendable () async throws -> HubReads.Answer = {
            try await Task.sleep(for: .milliseconds(400))
            return Self.answer("late")
        }
        let gone = Task { try await reads.share("get /ui/resources", read) }
        try await Task.sleep(for: .milliseconds(50))
        let stays = Task { try await reads.share("get /ui/resources", read) }
        try await Task.sleep(for: .milliseconds(50))
        gone.cancel()
        await #expect(throws: CancellationError.self) { try await gone.value }
        #expect(Self.words(try await stays.value) == "late")
    }

    @Test func whenEveryCallerLeavesTheReadItselfStops() async throws {
        let reads = HubReads(center: NotificationCenter()), count = Count()
        let read: @Sendable () async throws -> HubReads.Answer = {
            do { try await Task.sleep(for: .seconds(5)) } catch { await count.stop(); throw error }
            return Self.answer("never")
        }
        let only = Task { try await reads.share("get /ui/profiles", read) }
        try await Task.sleep(for: .milliseconds(50))
        only.cancel()
        await #expect(throws: CancellationError.self) { try await only.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await count.stopped)
        #expect(reads.inFlight == 0)
    }

    @Test func aFailedReadFailsForEveryCallerOfIt() async throws {
        let reads = HubReads(center: NotificationCenter()), count = Count()
        let read: @Sendable () async throws -> HubReads.Answer = {
            await count.add()
            try await Task.sleep(for: .milliseconds(150))
            throw HubError.refusal(503, "The hub is starting.")
        }
        let first = Task { try await reads.share("get /ui/servers", read) }
        let second = Task { try await reads.share("get /ui/servers", read) }
        await #expect(throws: HubError.self) { _ = try await first.value }
        await #expect(throws: HubError.self) { _ = try await second.value }
        #expect(await count.reads == 1)
    }

    /// A page that reads right after its own save must see it: a read never joins one that began before a write of this
    /// Mac was answered.
    @Test func aReadAfterAWriteNeverTakesTheAnswerOfAnOlderRead() async throws {
        let center = NotificationCenter()
        let reads = HubReads(center: center), count = Count()
        let read: @Sendable () async throws -> HubReads.Answer = {
            await count.add()
            try await Task.sleep(for: .milliseconds(300))
            return Self.answer("read")
        }
        let before = Task { try await reads.share("GET /ui/resources", read) }
        try await Task.sleep(for: .milliseconds(50))
        center.post(name: HubWrites.answered, object: nil)
        let after = Task { try await reads.share("GET /ui/resources", read) }
        _ = try await (before.value, after.value)
        #expect(await count.reads == 2)
    }

    /// **A page's read by name never joins one that began before a write of this Mac was answered** (`PageReads`,
    /// review A7, fix round 2): a list read right after his save took the read that began during it.
    @MainActor @Test func aPageReadAfterAWriteNeverTakesTheAnswerOfAnOlderRead() async throws {
        let center = NotificationCenter()
        let reads = PageReads(center: center), count = Count()
        let read: @Sendable () async throws -> String = {
            await count.add()
            try await Task.sleep(for: .milliseconds(300))
            return "read"
        }
        let before = Task { try await reads.read("apps", read) }
        try await Task.sleep(for: .milliseconds(50))
        center.post(name: HubWrites.answered, object: nil)
        let after = Task { try await reads.read("apps", read) }
        #expect(try await before.value == "read")
        #expect(try await after.value == "read")
        #expect(await count.reads == 2)
        // With no write between them, two reads of one name are one.
        let first = Task { try await reads.read("secrets", read) }
        let second = Task { try await reads.read("secrets", read) }
        _ = try await (first.value, second.value)
        #expect(await count.reads == 3)
    }

    /// **Only reads with the same time limits share** (review A5, fix round 2): `IntegrationsClient`'s read of `/ui/team`
    /// (60 s) joined `HubClient`'s (10 s) and timed out after 9.9 s. Two reads of one address with one set of limits
    /// share whatever their client; with other limits each is a request of its own.
    @Test func onlyReadsWithTheSameTimeLimitsShare() throws {
        let request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:8765/ui/team?db=generation")))
        func limits(_ request: TimeInterval, _ resource: TimeInterval) -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = request
            configuration.timeoutIntervalForResource = resource
            return configuration
        }
        let short = try #require(HubReads.key(request, in: limits(10, 15)))
        let long = try #require(HubReads.key(request, in: limits(60, 90)))
        #expect(short != long)
        #expect(HubReads.key(request, in: limits(60, 90)) == long)
        var write = request
        write.httpMethod = "POST"
        #expect(HubReads.key(write, in: limits(60, 90)) == nil)
    }

    /// The real path: two pages read the hub's health at once, and the stand-in hub takes exactly one request — a second
    /// request would find nobody listening and fail. **Its own reads, with a center of their own** (review B16, fix round
    /// 2): a write that another suite's test answered meanwhile made the second read a request of its own.
    @Test func twoPagesReadingTheHubAtOnceMakeOneRequest() async throws {
        let hub = try OneAnswer(status: "200 OK") { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return #"{"db":"generation","ok":true,"time":100,"hub":{"integrity":{}},"helpers":[],"warnings":[]}"#
        }
        let address = try #require(URL(string: "http://127.0.0.1:\(hub.port)/"))
        let reads = HubReads(center: NotificationCenter())
        async let first = HubClient(reads: reads).health(hub: address, database: "generation")
        async let second = HubClient(reads: reads).health(hub: address, database: "generation")
        let (a, b) = try await (first, second)
        #expect(a.db == "generation")
        #expect(b.db == "generation")
    }
}
