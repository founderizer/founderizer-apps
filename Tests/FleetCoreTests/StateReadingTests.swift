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

    @Test func thePatienceIsLongerThanASlowReadAndShorterThanAReadsTimeLimit() {
        // The slowest read of the owner's fleet in 300, under load, took 6.9 s; a read gives up after 10 s.
        #expect(StateReading.patience > 6.9)
        #expect(StateReading.patience < 10)
        // A read on the clock starts 3 s after the last answer: its patience ends inside the reading's 12 seconds.
        #expect(3 + StateReading.patience <= StateReading.limit)
    }
}
