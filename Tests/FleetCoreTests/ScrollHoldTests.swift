import Testing
@testable import FleetCore

/// The Mac holds a new reading of the fleet while a chat or a thread scrolls (`ScrollHold`; the owner, 17 November
/// 2026: "scrolling up and down the fleet manager conversation does not feel smooth"). A reading that never comes in
/// would leave the page old; one that comes in mid-scroll stops it.
@MainActor struct ScrollHoldTests {
    /// A deadline that the test fires when it chooses, and the seconds that the hold asked for.
    @MainActor final class Deadline {
        var asked: [Double] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func sleep(_ seconds: Double) async {
            asked.append(seconds)
            await withCheckedContinuation { waiting.append($0) }
        }
        func fire() {
            let firing = waiting
            waiting = []
            for continuation in firing { continuation.resume() }
        }
    }

    final class View {}

    /// Lets the reading that waits run until it waits again or ends.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func aReadingComesInAtOnceWhenNothingScrolls() async {
        let deadline = Deadline()
        let hold = ScrollHold(sleep: { await deadline.sleep($0) })
        var cameIn = false
        let reading = Task { @MainActor in await hold.rest(sinceAnswer: 0); cameIn = true }
        await settle()
        #expect(cameIn)
        #expect(deadline.asked.isEmpty)
        deadline.fire()
        await reading.value
    }

    @Test func aReadingWaitsUntilEveryScrollRests() async {
        let deadline = Deadline()
        let hold = ScrollHold(sleep: { await deadline.sleep($0) })
        let chat = View(), panel = View()
        hold.scroll(ObjectIdentifier(chat), moving: true)
        hold.scroll(ObjectIdentifier(panel), moving: true)
        var cameIn = false
        let reading = Task { @MainActor in await hold.rest(sinceAnswer: 3); cameIn = true }
        await settle()
        #expect(!cameIn)
        #expect(deadline.asked == [6])
        hold.scroll(ObjectIdentifier(chat), moving: false)
        await settle()
        #expect(!cameIn)
        hold.scroll(ObjectIdentifier(panel), moving: false)
        await settle()
        #expect(cameIn)
        deadline.fire()
        await reading.value
    }

    /// A scroll view that never tells that it rests (a phase that does not come back to idle) holds the reading only
    /// until its deadline, and no later reading.
    @Test func aScrollThatNeverRestsHoldsOneReadingOnlyUntilItsDeadline() async {
        let deadline = Deadline()
        let hold = ScrollHold(sleep: { await deadline.sleep($0) })
        let chat = View()
        hold.scroll(ObjectIdentifier(chat), moving: true)
        var cameIn = false
        let reading = Task { @MainActor in await hold.rest(sinceAnswer: 0); cameIn = true }
        await settle()
        #expect(!cameIn)
        deadline.fire()
        await settle()
        #expect(cameIn)
        #expect(hold.moving.isEmpty)
        // The next reading does not wait for the view that never rested.
        if hold.moving.isEmpty { await hold.rest(sinceAnswer: 0) }
        #expect(deadline.asked == [9])
        hold.scroll(ObjectIdentifier(chat), moving: false)
        await reading.value
    }

    /// A reading on the screen that is already about to count as old does not wait at all.
    @Test func aReadingThatIsNearlyOldComesInWhileTheChatScrolls() async {
        let deadline = Deadline()
        let hold = ScrollHold(sleep: { await deadline.sleep($0) })
        let chat = View()
        hold.scroll(ObjectIdentifier(chat), moving: true)
        var cameIn = false
        let reading = Task { @MainActor in await hold.rest(sinceAnswer: 9.5); cameIn = true }
        await settle()
        #expect(cameIn)
        #expect(deadline.asked.isEmpty)
        hold.scroll(ObjectIdentifier(chat), moving: false)
        deadline.fire()
        await reading.value
    }
}
