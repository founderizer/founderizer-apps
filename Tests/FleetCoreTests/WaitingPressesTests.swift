import Foundation
import Testing
@testable import FleetCore

/// **A press on a request's option that waits for the hub** (fix round 2, items 1 and 51): the card marks the option
/// pressed last "Sending…"; a press on another option moves the mark and keeps the wait's start, and nothing but an event
/// ends a wait.
struct WaitingPressesTests {
    private let start = ContinuousClock.now

    @Test func theFirstPressStartsAWaitAndTheNextOneTakesItsPlace() {
        var presses = WaitingPresses()
        #expect(presses.press(of: 7) == nil)
        let first = presses.press(1, need: 7, at: start)
        #expect(first)
        #expect(presses.press(of: 7) == .init(choice: 1, since: start))
        // A press on another option of the same request: no second wait, the mark moves, and the start stays.
        let second = presses.press(2, need: 7, at: start + .seconds(3))
        #expect(!second)
        #expect(presses.press(of: 7) == .init(choice: 2, since: start))
    }

    @Test func eachRequestWaitsOnItsOwn() {
        var presses = WaitingPresses()
        let seven = presses.press(0, need: 7, at: start)
        let nine = presses.press(1, need: 9, at: start + .seconds(1))
        #expect(seven && nine)
        presses.end(7)
        #expect(presses.press(of: 7) == nil)
        #expect(presses.press(of: 9) == .init(choice: 1, since: start + .seconds(1)))
        // After its end, a press starts a new wait with its own start.
        let again = presses.press(2, need: 7, at: start + .seconds(5))
        #expect(again)
        #expect(presses.press(of: 7) == .init(choice: 2, since: start + .seconds(5)))
    }
}
