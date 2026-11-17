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

    @Test func aReadingIsCurrentForTwelveSecondsAfterTheHubsLastAnswer() {
        #expect(StateReading.isCurrent(held: false, sinceAnswer: 0, firstReadEnded: true))
        // One read that failed, and a second one: "never for one short break".
        #expect(StateReading.isCurrent(held: false, sinceAnswer: 3.8, firstReadEnded: true))
        #expect(StateReading.isCurrent(held: false, sinceAnswer: 11.9, firstReadEnded: true))
        #expect(!StateReading.isCurrent(held: false, sinceAnswer: 12, firstReadEnded: true))
        #expect(!StateReading.isCurrent(held: false, sinceAnswer: 3_600, firstReadEnded: true))
    }

    @Test func aReadThatTakesLongerThanItsPatienceMakesTheReadingOld() {
        // Eight seconds into a read, with the last answer 11 seconds ago: old, until a read answers.
        #expect(!StateReading.isCurrent(held: true, sinceAnswer: 11, firstReadEnded: true))
        #expect(!StateReading.isCurrent(held: true, sinceAnswer: 0.5, firstReadEnded: true))
    }

    /// The Mac holds a new reading while a chat scrolls (the owner, 17 November 2026: "scrolling up and down the fleet
    /// manager conversation does not feel smooth"). Held too long, the page would say that its reading is old while the
    /// hub answers.
    @Test func aReadingThatWaitsForAScrollComesInBeforeThePageWouldCallItOld() {
        for since in stride(from: 0.0, through: 15, by: 0.5) {
            let wait = StateReading.waitWhileScrolling(sinceAnswer: since)
            #expect(wait >= 0)
            // It comes in at once, or three seconds before the reading on the screen would count as old.
            #expect(since + wait <= max(since, StateReading.limit - 3), "\(since)")
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
        // A read on the clock starts 3 s after the last answer: its patience ends inside the reading's 12 seconds.
        #expect(3 + StateReading.patience <= StateReading.limit)
    }
}
