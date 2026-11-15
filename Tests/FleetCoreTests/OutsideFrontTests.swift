import Testing
@testable import FleetCore

/// The keys of the app after it came to the front from outside (`OutsideFront`).
@Suite struct OutsideFrontTests {
    /// With no front from outside, each key reaches the app.
    @Test func withNoFrontFromOutsideEachKeyPasses() {
        var front = OutsideFront()
        #expect(!front.holdsKeys && front.takesKeys)
        front.click(appInFront: true)
        #expect(front.takesKeys)
        front.leftFront()
        #expect(front.takesKeys)
    }

    /// The case that it is for: the owner types in another window, the app comes to the front, and the next keys of
    /// that typing must not land in it.
    @Test func afterAFrontFromOutsideNoKeyPassesUntilAClick() {
        var front = OutsideFront()
        front.came(appInFront: false)
        #expect(front.holdsKeys && !front.takesKeys)
        // A second ask for the front changes nothing: the app is in front now, and the owner still did not click.
        front.came(appInFront: true)
        #expect(!front.takesKeys)
        front.click(appInFront: true)
        #expect(!front.holdsKeys && front.takesKeys)
    }

    /// The program's own `open` can bring the app to the front a moment before the app takes the guide's sign: the app
    /// is in front then, and nobody clicked in it, so the hold comes all the same.
    @Test func anAppThatCameForwardAMomentBeforeTheSignHoldsToo() {
        var front = OutsideFront()
        front.came(appInFront: true)
        #expect(front.holdsKeys)
    }

    /// An owner who clicked in the app since it became the app in front keeps their keys when their agent asks for the
    /// front, again and again.
    @Test func anOwnerWhoWorksInTheAppKeepsTheirKeys() {
        var front = OutsideFront()
        front.click(appInFront: true)
        front.came(appInFront: true)
        #expect(!front.holdsKeys && front.takesKeys)
        front.came(appInFront: true)
        #expect(front.takesKeys)
    }

    /// **A page that changed from outside holds the keys of an owner who works in the app too** (`setup_show` for a
    /// place of the fleet's own pages): what they type is for the page that went. Their next click ends the hold, and
    /// they keep their keys again at a later front that changes no page.
    @Test func aPageThatChangedFromOutsideHoldsTheKeysOfAnOwnerWhoWorksInTheApp() {
        var front = OutsideFront()
        front.click(appInFront: true)
        front.came(appInFront: true, pageChanged: true)
        #expect(front.holdsKeys && !front.takesKeys)
        front.click(appInFront: true)
        #expect(!front.holdsKeys && front.takesKeys)
        front.came(appInFront: true)
        #expect(front.takesKeys)
        front.came(appInFront: true, pageChanged: false)
        #expect(front.takesKeys)
        // With the app not in front it holds as every front from outside does, and leaving the app ends it.
        var away = OutsideFront()
        away.came(appInFront: false, pageChanged: true)
        #expect(away.holdsKeys)
        away.leftFront()
        #expect(away.takesKeys)
    }

    /// **The first click after a page that changed from outside reaches no control**: it was aimed at the page that
    /// went. The app drops its mouse-down, its drags and its mouse-up, and that click only ends the hold. The click
    /// after it reaches the app.
    @Test func theFirstClickAfterAPageChangeOnlyEndsTheHold() {
        for inFront in [true, false] {
            var front = OutsideFront()
            front.click(appInFront: true)                   // an owner who works in the app
            front.came(appInFront: inFront, pageChanged: true)
            #expect(front.holdsKeys && front.holdsClick)
            // The first click: dropped, with its drag and its release, and the hold of the keys ends.
            let first = front.click(appInFront: true)
            #expect(!first && !front.holdsKeys && !front.holdsClick)
            let drag = front.pointer(up: false), release = front.pointer(up: true)
            #expect(!drag && !release)
            // The next click reaches the app, whole.
            let second = front.click(appInFront: true)
            let later = front.pointer(up: false), up = front.pointer(up: true)
            #expect(second && later && up)
        }
    }

    /// **One event is one click, whichever watch asks first**: the app has more than one watch of its mouse-downs, in
    /// no fixed order. Each asks with the event, and the second ask for the same event gets the first one's answer.
    /// Without that, the second ask would count as a second click, and the click that the app drops would pass.
    @Test func twoWatchesThatAskForOneEventGetOneAnswer() {
        typealias Event = OutsideFront.Event
        var front = OutsideFront()
        front.click(appInFront: true)
        front.came(appInFront: true, pageChanged: true)
        let first = Event(number: 7, time: 100.5)
        #expect(!front.answered(first))
        let one = front.click(appInFront: true, event: first), two = front.click(appInFront: true, event: first)
        let three = front.click(appInFront: false, event: first)
        #expect(!one && !two && !three && front.answered(first))
        // Its mouse-up is dropped one time, as for one click.
        let release = front.pointer(up: true), later = front.pointer(up: true)
        #expect(!release && later)
        // The next event is the next click: it reaches the app, for each watch that asks.
        let second = Event(number: 8, time: 100.9)
        let four = front.click(appInFront: true, event: second), five = front.click(appInFront: true, event: second)
        #expect(four && five && front.answered(second) && !front.answered(first))
        // The same number at another time is another event: a program can make an event with any number.
        front.came(appInFront: true, pageChanged: true)
        let six = front.click(appInFront: true, event: Event(number: 8, time: 101.4))
        #expect(!six)
        // With no event, each ask is a click of its own: the second one passes.
        var plain = OutsideFront()
        plain.came(appInFront: true, pageChanged: true)
        let seven = plain.click(appInFront: true), eight = plain.click(appInFront: true)
        #expect(!seven && eight)
    }

    /// **A change of page always holds the next click**, whatever the rule saw of a click before it. Until 15
    /// November 2026 a click that was under way at the change counted as the dropped one, and the next click reached
    /// the app, about 100 ms later, on a page that the owner did not see yet. Now no page changes while a mouse
    /// button is down (`SetupShow.buttonHeld`), and this rule has no branch for it: a mouse-down whose mouse-up the
    /// rule never saw (a control took it), a click that is over and a button that is down elsewhere all end in the
    /// same way.
    @Test func aChangeOfPageAlwaysHoldsTheNextClick() {
        typealias Event = OutsideFront.Event
        // A mouse-down that the rule saw, and no mouse-up since: the state that the old branch took for a click
        // under way.
        var seen = OutsideFront()
        let first = seen.click(appInFront: true, event: Event(number: 1, time: 1))
        seen.came(appInFront: true, pageChanged: true)
        #expect(first && seen.holdsKeys && seen.holdsClick)
        // A mouse-up of that older click, which waited in the queue, is no part of a dropped click: it passes, and
        // it ends no hold. (The store counts it for nothing: it began before the change, `ShownPage`.)
        let lateUp = seen.pointer(up: true)
        #expect(lateUp && seen.holdsKeys && seen.holdsClick)
        let next = seen.click(appInFront: true, event: Event(number: 2, time: 2)), nextUp = seen.pointer(up: true)
        #expect(!next && !nextUp && seen.takesKeys && !seen.holdsClick)
        let after = seen.click(appInFront: true, event: Event(number: 3, time: 3)), afterUp = seen.pointer(up: true)
        #expect(after && afterUp)

        // A click that is over, and no click at all: the next click is the one that is dropped.
        var over = OutsideFront()
        over.click(appInFront: true, event: Event(number: 1, time: 1))
        _ = over.pointer(up: true)
        over.came(appInFront: true, pageChanged: true)
        var none = OutsideFront()
        none.came(appInFront: false, pageChanged: true)
        for var front in [over, none] {
            #expect(front.holdsClick)
            let click = front.click(appInFront: true, event: Event(number: 9, time: 9))
            #expect(!click && !front.holdsClick)
        }
        // A front that changes no page holds no click.
        var plain = OutsideFront()
        plain.click(appInFront: true, event: Event(number: 1, time: 1))
        plain.came(appInFront: true)
        let plainUp = plain.pointer(up: true)
        #expect(plainUp && !plain.holdsClick)
    }

    /// **A double click is one click for the hold**: after the mouse-down that the app dropped, the second and the
    /// third mouse-down of the same click series (a click count above 1) were aimed at the page that went too, and
    /// are dropped with their mouse-ups. A new single click after them reaches the app, and so does a double click
    /// that begins then.
    @Test func aDoubleClickIsOneClickForTheHold() {
        typealias Event = OutsideFront.Event
        var front = OutsideFront()
        front.click(appInFront: true)
        front.came(appInFront: true, pageChanged: true)
        var series: [Bool] = []
        for count in 1...3 {                                // a triple click
            series.append(front.click(appInFront: true, event: Event(number: count, time: 1 + Double(count) / 10, count: count)))
            series.append(front.pointer(up: true))
        }
        #expect(series == [false, false, false, false, false, false])
        #expect(front.takesKeys && !front.holdsClick)       // the first of them ended the hold of the keys
        // A new single click reaches the app, and a double click that begins with it reaches it too.
        let single = front.click(appInFront: true, event: Event(number: 4, time: 3)), singleUp = front.pointer(up: true)
        let second = front.click(appInFront: true, event: Event(number: 5, time: 3.2, count: 2))
        let secondUp = front.pointer(up: true)
        #expect(single && singleUp && second && secondUp)
        // With no hold, a double click reaches the app whole, as before.
        var plain = OutsideFront()
        let one = plain.click(appInFront: true, event: Event(number: 1, time: 1))
        let two = plain.click(appInFront: true, event: Event(number: 2, time: 1.2, count: 2))
        #expect(one && two)
        // A double click that is only the dropped click's second watch (the same event) is still one answer.
        var asked = OutsideFront()
        asked.came(appInFront: true, pageChanged: true)
        let event = Event(number: 1, time: 1, count: 2)
        let first = asked.click(appInFront: true, event: event), again = asked.click(appInFront: true, event: event)
        #expect(!first && !again)
    }

    /// **A front that changed no page drops no click**, as before: the click that ends its hold reaches the app.
    @Test func aFrontWithNoPageChangeDropsNoClick() {
        var front = OutsideFront()
        front.came(appInFront: false)
        #expect(front.holdsKeys && !front.holdsClick)
        let click = front.click(appInFront: true)
        let release = front.pointer(up: true)
        #expect(click && release && front.takesKeys)
        // A plain front while the first click after a page change is still owed does not take that hold away.
        front.came(appInFront: true, pageChanged: true)
        front.came(appInFront: true)
        front.came(appInFront: true, pageChanged: false)
        #expect(front.holdsClick && front.holdsKeys)
        // With no hold at all, each drag and each release reaches the app.
        var plain = OutsideFront()
        let drag = plain.pointer(up: false), up = plain.pointer(up: true)
        #expect(drag && up)
    }

    /// **Leaving the app ends the hold of the first click too**: the owner who comes back sees the page that came,
    /// and clicks on what they see. A release that belongs to a dropped mouse-down is still dropped after it.
    @Test func leavingTheAppEndsTheHoldOfTheFirstClick() {
        var front = OutsideFront()
        front.came(appInFront: true, pageChanged: true)
        front.leftFront()
        #expect(!front.holdsClick && front.takesKeys)
        let click = front.click(appInFront: true)
        #expect(click)
        // The button went down, was dropped, and the app left the front before its release.
        var held = OutsideFront()
        held.came(appInFront: true, pageChanged: true)
        let down = held.click(appInFront: true)
        held.leftFront()
        let release = held.pointer(up: true), next = held.pointer(up: true)
        #expect(!down && !release && next)
    }

    /// A click counts for later only in an app in front. macOS can give a click to a window in the back without
    /// bringing its app forward, and the guide's sign can reach the app after its program brought it forward: the hold
    /// comes then, with the app in front too. Such a click still ends a hold that is on.
    @Test func aClickInAnAppThatIsNotInFrontIsWorthNothingLater() {
        var front = OutsideFront()
        front.click(appInFront: false)
        front.came(appInFront: true)
        #expect(front.holdsKeys && !front.takesKeys)
        front.click(appInFront: false)
        #expect(!front.holdsKeys && front.takesKeys)
        front.came(appInFront: true)
        #expect(front.holdsKeys)
        // And a click in the app in front is worth nothing once the app is asked forward while it is not in front.
        var other = OutsideFront()
        other.click(appInFront: true)
        other.came(appInFront: false)
        #expect(other.holdsKeys)
    }

    /// Leaving the app ends the hold, and it ends the click's worth too: the next front from outside finds an owner
    /// whose keys are for another window again.
    @Test func leavingTheAppEndsTheHoldAndTheClicksWorth() {
        var front = OutsideFront()
        front.came(appInFront: false)
        front.leftFront()
        #expect(!front.holdsKeys && front.takesKeys)
        front.click(appInFront: true)
        front.leftFront()
        front.came(appInFront: true)
        #expect(front.holdsKeys && !front.takesKeys)
    }

    /// A key is no sign that the owner is there: with the hold on, a key press ends nothing, however many come.
    @Test func aKeyNeverEndsTheHold() {
        var front = OutsideFront()
        front.came(appInFront: false)
        for _ in 0..<50 { #expect(!front.takesKeys) }
        #expect(front.holdsKeys)
    }
}
