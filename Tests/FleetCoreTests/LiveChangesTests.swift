import Foundation
import Testing
@testable import FleetCore

/// The hub's change signal (owner feature `live_changes`): what a token says, which answer is a wake, the cap on
/// wakes, the backoff after a failed wait, the wait itself, the nap of a page loop, the read that runs once more,
/// and the signal of a write. Synthetic data only.
struct LiveChangesTests {
    private func token(_ text: String) throws -> LiveToken { try #require(LiveToken(text)) }

    // MARK: the token

    @Test func aTokenIsItsBootAndItsTwoCounts() throws {
        let read = try token("b7f3.12.940")
        #expect((read.boot, read.state, read.activity, read.text) == ("b7f3", 12, 940, "b7f3.12.940"))
        // The counts are the last two parts, so a boot with a dot in it still reads.
        let dotted = try token("1729.5.7.9")
        #expect((dotted.boot, dotted.state, dotted.activity) == ("1729.5", 7, 9))
        for text in [nil, "", "b7f3", "b7f3.12", ".12.9", "b7f3..9", "b7f3.12.", "b7f3.x.9", "b7f3.-1.9", "b7f3.+1.9",
                     "b 7.1.2", "b+7.1.2", "b7f3.1.2\n", String(repeating: "b", count: 200) + ".1.2"] {
            #expect(LiveToken(text) == nil, "\(String(describing: text))")
        }
    }

    @Test func onlyTheBootOrTheStateCountWakes() throws {
        let since = try token("boot.5.100")
        #expect(try token("boot.6.100").wakes(since: since))
        #expect(try token("other.5.100").wakes(since: since))
        // The activity count never wakes anything: a log row, a thread record or a usage reading is no news.
        #expect(!(try token("boot.5.180").wakes(since: since)))
        #expect(!(try token("boot.5.100").wakes(since: since)))
    }

    @Test func aStateReadCoversAChangeOfItsOwnBootAndCount() throws {
        let change = try token("boot.6.1")
        #expect(try token("boot.6.0").covers(change))
        #expect(try token("boot.9.0").covers(change))
        #expect(!(try token("boot.5.9").covers(change)))
        #expect(!(try token("other.9.9").covers(change)))
    }

    @Test func theStateIsDecodedWithItsTokenAndTheFeature() throws {
        func state(_ extra: [String: Any]) throws -> HubState {
            var object: [String: Any] = ["schema_version": 1, "db": "db", "time": 1000.0, "agents": [], "tasks": [],
                                         "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []]
            object.merge(extra) { _, new in new }
            return try HubState.decode(JSONSerialization.data(withJSONObject: object))
        }
        let live = try state(["token": "boot.3.4", "ui_features": ["live_changes"]]), expected = try token("boot.3.4")
        #expect(live.offersLiveChanges && live.liveToken == expected)
        // An older hub: no token, no feature, and the app reads on its clocks as before.
        let older = try state([:])
        #expect(!older.offersLiveChanges && older.liveToken == nil)
    }

    // MARK: the cap

    @Test func theCapLetsOneWakeThroughEveryTwoSecondsAndFoldsTheRest() {
        var cap = WakeCap(interval: 2)
        var answers: [WakeCap.Answer] = []
        answers.append(cap.wake(at: 100))
        // Inside the two seconds: one wake is held for their end, and the wakes after it fold into that one.
        answers.append(cap.wake(at: 100.5))
        answers.append(cap.wake(at: 101))
        answers.append(cap.wake(at: 101.9))
        #expect(answers == [.now, .at(102), .folded, .folded])
        cap.fired(at: 102)
        // The held one went out, so the next two seconds count from it.
        answers = [cap.wake(at: 103)]
        cap.fired(at: 104)
        answers.append(cap.wake(at: 106.5))
        answers.append(cap.wake(at: 107))
        #expect(answers == [.at(104), .now, .at(108.5)])
        // Another hub or generation starts again: nothing held, and the next wake goes at once.
        cap.reset()
        let fresh = cap.wake(at: 107.1)
        #expect(fresh == .now)
    }

    // MARK: the backoff

    @Test func aFailedWaitWaitsLongerEachTimeFromOneToThirtySeconds() {
        for jitter in [0.0, 0.5, 1.0] {
            let delays = (1...9).map { WakeBackoff.delay(failures: $0, jitter: jitter) }
            #expect(delays.allSatisfy { (1...30).contains($0) }, "\(delays)")
            #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 }, "\(delays)")
            #expect(delays.last! >= 24)
        }
        func near(_ value: TimeInterval, _ expected: TimeInterval) -> Bool { abs(value - expected) < 1e-9 }
        #expect(near(WakeBackoff.delay(failures: 1, jitter: 0), 1))
        #expect(near(WakeBackoff.delay(failures: 1, jitter: 1), 1.2))
        #expect(near(WakeBackoff.delay(failures: 3, jitter: 0.5), 4))
        #expect(near(WakeBackoff.delay(failures: 5, jitter: 0), 12.8))
        #expect(near(WakeBackoff.delay(failures: 40, jitter: 1), 30))
        #expect(WakeBackoff.delay(failures: 0, jitter: 1) == 0)
    }

    @Test func anAnswerEndsTheBackoffAndTheNextWaitAsksFromTheNewestToken() throws {
        var watch = LiveWatch(from: try token("boot.5.1"))
        let delays = [watch.failed(jitter: 0.5), watch.failed(jitter: 0.5), watch.failed(jitter: 0.5)]
        #expect(delays == [1, 2, 4])
        // A wait the hub held to its end, whose activity moved, is no wake, and it still ends the backoff.
        let quiet = try token("boot.5.9")
        let held = watch.answered(quiet, took: 20, jitter: 0.5)
        #expect(held == .wait)
        #expect(watch.failures == 0 && watch.since == quiet)
        let again = watch.failed(jitter: 0.5)
        #expect(again == 1)
        // A change wakes once, however soon it comes: the next wait asks from it, so the same count is no second wake.
        let change = try token("boot.6.9")
        let first = watch.answered(change, took: 0.1, jitter: 0.5), second = watch.answered(change, took: 20, jitter: 0.5)
        #expect(first == .wake && second == .wait && watch.failures == 0)
        // A hub that started again wakes too.
        let restarted = watch.answered(try token("again.0.0"), took: 0.2, jitter: 0.5)
        #expect(restarted == .wake)
    }

    /// A hub that answers every wait at once with nothing new is not asked again in a tight loop: each such answer is
    /// a failure, and the next wait waits 1, 2, 4… seconds first, until a wait is held or something changes.
    @Test func anAnswerThatDidNotWaitIsNotAskedAgainAtOnce() throws {
        var watch = LiveWatch(from: try token("boot.5.1"))
        let same = try token("boot.5.1")
        let steps = [watch.answered(same, took: 0.01, jitter: 0.5), watch.answered(same, took: 0.01, jitter: 0.5),
                     watch.answered(same, took: 0.5, jitter: 0.5)]
        #expect(steps == [.pause(1), .pause(2), .pause(4)])
        let wake = watch.answered(try token("boot.6.1"), took: 0.01, jitter: 0.5)
        #expect(wake == .wake && watch.failures == 0)
    }

    // MARK: the read on the clock

    @Test func theReadOnTheClockCountsFromTheLastReadWhoeverRanIt() {
        #expect(LiveChanges.untilRead(after: nil, now: 50) == 0)
        #expect(LiveChanges.untilRead(after: 49, now: 50) == 2)
        #expect(LiveChanges.untilRead(after: 47, now: 50) == 0)
        #expect(LiveChanges.untilRead(after: 46, now: 50) == 0)
        #expect(LiveChanges.untilRead(after: 50, now: 50) == 3)
    }

    // MARK: the wait

    @Test func theWaitAsksFromTheTokenAndGivesTheHubsNewOne() async throws {
        let hub = try OneAnswer(status: "200 OK") { _ in #"{"db": "db", "token": "boot.6.2"}"# }
        let answer = try await LiveChangesClient().wait(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                        since: try token("boot.5.1"))
        #expect(answer == .token(try token("boot.6.2")))
        #expect(hub.received.starts(with: Data("GET /ui/wait?db=db&since=boot.5.1&wait=20 HTTP/1.1\r\n".utf8)))
        #expect(!String(decoding: hub.received, as: UTF8.self).lowercased().contains("authorization:"))
    }

    @Test func aPhonesWaitCarriesItsOwnKey() async throws {
        let hub = try OneAnswer(status: "200 OK") { _ in #"{"db": "db", "token": "boot.6.2"}"# }
        _ = try await LiveChangesClient().wait(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                               since: try token("boot.5.1"), key: "phone-key")
        #expect(String(decoding: hub.received, as: UTF8.self).contains("Authorization: Bearer phone-key\r\n"))
    }

    @Test func anotherGenerationIsAnAnswerAndAnUnreadableOneIsNot() async throws {
        let since = try token("boot.5.1")
        let changed = try OneAnswer(status: "409 Conflict") { _ in #"{"error": "hub generation changed; refresh state"}"# }
        #expect(try await LiveChangesClient().wait(hub: URL(string: "http://127.0.0.1:\(changed.port)")!, database: "db",
                                                   since: since) == .generationChanged)
        let other = try OneAnswer(status: "200 OK") { _ in #"{"db": "db2", "token": "boot.6.2"}"# }
        #expect(try await LiveChangesClient().wait(hub: URL(string: "http://127.0.0.1:\(other.port)")!, database: "db",
                                                   since: since) == .generationChanged)
        let garbled = try OneAnswer(status: "200 OK") { _ in #"{"db": "db", "token": "boot.six.2"}"# }
        await #expect(throws: HubError.self) {
            try await LiveChangesClient().wait(hub: URL(string: "http://127.0.0.1:\(garbled.port)")!, database: "db", since: since)
        }
        let refused = try OneAnswer(status: "503 Service Unavailable") { _ in #"{"error": "the hub is starting"}"# }
        await #expect(throws: HubError.self) {
            try await LiveChangesClient().wait(hub: URL(string: "http://127.0.0.1:\(refused.port)")!, database: "db", since: since)
        }
    }

    // MARK: the nap

    @MainActor @Test func aNapEndsAtItsTimeWhenNothingWakesIt() async throws {
        let wakes = PageWakes()
        let started = Date()
        #expect(try await wakes.nap(0.05) == false)
        #expect(Date().timeIntervalSince(started) >= 0.04)
        #expect(wakes.napping == 0)
    }

    @MainActor @Test func aWakeEndsEveryNapThatIsOnEachOnce() async throws {
        let wakes = PageWakes()
        let first = Task { @MainActor in try await wakes.nap(30) }
        let second = Task { @MainActor in try await wakes.nap(30) }
        while wakes.napping < 2 { await Task.yield() }
        let started = Date()
        wakes.wake()
        #expect(try await first.value == true)
        #expect(try await second.value == true)
        #expect(Date().timeIntervalSince(started) < 10)
        // That wake is spent: a nap that begins after it waits for the next one, or for its own time.
        #expect(try await wakes.nap(0.05) == false)
        #expect(wakes.wakes == 1)
    }

    @MainActor @Test func aWakeBeforeTheNapBeganDoesNotEndIt() async throws {
        let wakes = PageWakes()
        wakes.wake()
        #expect(try await wakes.nap(0.05) == false)
    }

    @MainActor @Test func aNapThrowsWhenItsLoopIsCancelledAsASleepDoes() async throws {
        let wakes = PageWakes()
        let loop = Task { @MainActor in try await wakes.nap(30) }
        while wakes.napping < 1 { await Task.yield() }
        loop.cancel()
        await #expect(throws: CancellationError.self) { try await loop.value }
        #expect(wakes.napping == 0)
    }

    // MARK: the read that runs once more

    @MainActor private final class Log {
        var lines: [String] = []
        var count = 0
        var gate: CheckedContinuation<Void, Never>?
    }

    @MainActor @Test func aCallDuringARunMakesItRunOnceMoreAndWaitsForThatOne() async {
        let runs = RunAgain(), log = Log()
        let read: @MainActor () async -> Void = {
            log.count += 1
            let run = log.count
            log.lines.append("start \(run)")
            if run == 1 { await withCheckedContinuation { log.gate = $0 } }
            log.lines.append("end \(run)")
        }
        let first = Task { @MainActor in await runs.run(read); log.lines.append("first back") }
        while log.gate == nil { await Task.yield() }
        // Two calls while the first run is out: they share one more run, and neither comes back before it ended.
        let second = Task { @MainActor in await runs.run(read); log.lines.append("second back") }
        let third = Task { @MainActor in await runs.run(read); log.lines.append("third back") }
        for _ in 0..<20 { await Task.yield() }
        #expect(log.lines == ["start 1"])
        log.gate?.resume()
        await first.value
        await second.value
        await third.value
        #expect(log.count == 2)
        #expect(Array(log.lines.prefix(4)) == ["start 1", "end 1", "start 2", "end 2"])
        #expect(Set(log.lines.dropFirst(4)) == ["first back", "second back", "third back"])
        #expect(!runs.isRunning)
        // A call after the runs ended starts a run of its own.
        await runs.run(read)
        #expect(log.count == 3)
    }

    // MARK: the signal of a write

    @Test func aPostThatGotItsAnswerIsNotedAndAReadIsNot() {
        let center = NotificationCenter()
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let token = center.addObserver(forName: HubWrites.answered, object: nil, queue: nil) { _ in count.value += 1 }
        defer { center.removeObserver(token) }
        var post = URLRequest(url: URL(string: "http://127.0.0.1/ui/send")!)
        post.httpMethod = "POST"
        HubWrites.note(post, center: center)
        HubWrites.note(URLRequest(url: URL(string: "http://127.0.0.1/ui/state")!), center: center)
        #expect(count.value == 1)
    }
}
