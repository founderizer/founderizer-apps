import Foundation
import Testing
@testable import FleetCore

/// When the fleet's state on the screen is current (`StateReading`): at a launch, while the app runs, and after a read
/// that takes long.
struct StateReadingTests {
    @Test func theKeptReadingIsCurrentWhileTheLaunchsFirstReadIsOnItsWay() {
        // Before the first read ends, however long it has taken so far: a first read of 1.4 s said "old" at 1.0 s.
        #expect(StateReading.isCurrent(held: false, sinceAnswer: nil, firstReadEnded: false))
        // That read failed: the kept reading is the last reading at once.
        #expect(!StateReading.isCurrent(held: false, sinceAnswer: nil, firstReadEnded: true))
        // That read has taken more than its patience: old, while it still goes on.
        #expect(!StateReading.isCurrent(held: true, sinceAnswer: nil, firstReadEnded: false))
    }

    /// **One break of the hub says nothing** (the owner, 27 October 2026: "never for one short break"; 17 November
    /// 2026: "either fix the underlaying issue OR not show the wanring at all"). His Mac's own record of six hours:
    /// breaks of 19.4 s just after he connected Gmail and 22.3 s at a release restart, each with reads that hung or
    /// failed, and each said "This reading of your fleet is old" for a few seconds.
    @Test func oneBreakOfTheHubSaysNothingAndALongerOneIsOld() {
        #expect(StateReading.isCurrent(held: false, sinceAnswer: 0, firstReadEnded: true))
        // A read that hung eight seconds and more inside the break, as at 17:46 UTC: still current.
        #expect(StateReading.isCurrent(held: true, sinceAnswer: 19.4, firstReadEnded: true))
        #expect(StateReading.isCurrent(held: false, sinceAnswer: 22.3, firstReadEnded: true))
        #expect(StateReading.limit > 22.3)
        // A hub that stays away: old once the break has lasted its whole limit, whatever the reads did.
        #expect(!StateReading.isCurrent(held: false, sinceAnswer: StateReading.limit, firstReadEnded: true))
        #expect(!StateReading.isCurrent(held: true, sinceAnswer: 3_600, firstReadEnded: true))
        // A page's own reading: one break of failed reads says nothing; a longer one, or an old state, is its last.
        #expect(!StateReading.pageReadingIsOld(stateIsCurrent: true, failingFor: nil))
        #expect(!StateReading.pageReadingIsOld(stateIsCurrent: true, failingFor: 20))
        #expect(StateReading.pageReadingIsOld(stateIsCurrent: true, failingFor: StateReading.limit))
        #expect(StateReading.pageReadingIsOld(stateIsCurrent: false, failingFor: nil))
        // How long a page's reads have failed: from the first of them, and from the Mac's last wake when they began
        // before it, so a Mac that wakes after a night starts no break (Conversations, People, Devices and the other
        // pages' own lines, 17 November 2026).
        let first = ContinuousClock.now, woke = first + .seconds(8 * 3_600)
        #expect(StateReading.failingFor(since: nil, wokeAt: woke, now: woke) == nil)
        #expect(StateReading.failingFor(since: first, wokeAt: nil, now: first + .seconds(30)) == 30)
        #expect(StateReading.failingFor(since: first, wokeAt: woke, now: woke + .seconds(5)) == 5)
        #expect(StateReading.failingFor(since: woke, wokeAt: first, now: woke + .seconds(5)) == 5)
    }

    /// **A wake starts no break, and no work moves by the reading from before it** (a review of 17 November 2026): with
    /// the hub away after a night's sleep, that reading stays current for up to one break, and an agent that worked as
    /// the Mac went to sleep moved on the screen as if it worked now.
    @Test func noWorkMovesByAReadingFromBeforeAWake() {
        let began = ContinuousClock.now, woke = began.advanced(by: .seconds(8 * 3_600))
        #expect(StateReading.workMoves(stateIsCurrent: true, readBegan: began, wokeAt: nil))
        #expect(StateReading.workMoves(stateIsCurrent: true, readBegan: began, wokeAt: began.advanced(by: .seconds(-1))))
        #expect(!StateReading.workMoves(stateIsCurrent: true, readBegan: began, wokeAt: woke))
        // The hub's answer to the first read after the wake.
        #expect(StateReading.workMoves(stateIsCurrent: true, readBegan: woke.advanced(by: .seconds(2)), wokeAt: woke))
        // The reading that this Mac kept from its last launch is from before the wake too; an old one never moves.
        #expect(!StateReading.workMoves(stateIsCurrent: true, readBegan: nil, wokeAt: woke))
        #expect(!StateReading.workMoves(stateIsCurrent: false, readBegan: began, wokeAt: nil))
        // With no wake, a launch's kept reading moves while its first read is on its way, as before this rule.
        #expect(StateReading.workMoves(stateIsCurrent: true, readBegan: nil, wokeAt: nil))
    }

    /// The Mac holds a new reading while a chat scrolls (the owner, 17 November 2026: "scrolling up and down the fleet
    /// manager conversation does not feel smooth"). Held too long, the page would say that its reading is old while the
    /// hub answers.
    @Test func aReadingThatWaitsForAScrollComesInBeforeThePageWouldCallItOld() {
        for since in stride(from: 0.0, through: 15, by: 0.5) {
            let wait = StateReading.waitWhileScrolling(sinceAnswer: since)
            #expect(wait >= 0)
            // It comes in at once, or at most nine seconds after the hub's last answer, well inside one break.
            #expect(since + wait <= max(since, StateReading.scrollWaitMost), "\(since)")
            #expect(StateReading.isCurrent(held: false, sinceAnswer: since + wait, firstReadEnded: true) || wait == 0, "\(since)")
        }
        #expect(StateReading.waitWhileScrolling(sinceAnswer: 3) == 6)
        // Before the hub's first answer of a launch there is no reading to keep current: nothing waits.
        #expect(StateReading.waitWhileScrolling(sinceAnswer: nil) == 0)
        // A clock that went back an hour after the answer: still nine seconds at most.
        #expect(StateReading.waitWhileScrolling(sinceAnswer: -3_600) == 9)
    }

    @Test func thePatienceIsLongerThanASlowReadAndShorterThanAReadsTimeLimit() {
        // The slowest read of the owner's fleet in 300, under load, took 6.9 s; a read gives up after 10 s.
        #expect(StateReading.patience > 6.9)
        #expect(StateReading.patience < 10)
        // The launch's first read: its patience ends before a read gives up.
        #expect(StateReading.patience < StateReading.limit)
    }
}
