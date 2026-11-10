import Foundation
import Testing
@testable import FleetCore

/// The rounds that keep the live readings current (`LiveReadings`): when a round goes out.
struct LiveReadingsTests {
    @Test func aRoundGoesOutEveryFifteenSecondsAndNeverBesideAnother() {
        // The first one at once, after the hub's first answer.
        #expect(LiveReadings.roundDue(sinceAsked: nil, running: false))
        #expect(!LiveReadings.roundDue(sinceAsked: 3, running: false))
        #expect(!LiveReadings.roundDue(sinceAsked: 14.9, running: false))
        #expect(LiveReadings.roundDue(sinceAsked: 15, running: false))
        // After a sleep of the Mac, at the first tick.
        #expect(LiveReadings.roundDue(sinceAsked: 28_800, running: false))
        // One at a time: a round whose reads are on their way holds the next one back, however old it is.
        #expect(!LiveReadings.roundDue(sinceAsked: nil, running: true))
        #expect(!LiveReadings.roundDue(sinceAsked: 60, running: true))
    }

    @Test func aLiveReadingIsNeverOlderThanTheHealthRule() {
        // The hub's health speaks for the helpers for 45 seconds (`FleetHealth.currentHelpers`): a round, the 3.7 s of
        // the app's own clock between two looks, and a read of eight seconds stay inside it.
        #expect(LiveReadings.every + 3.7 + 8 < 45)
    }
}
