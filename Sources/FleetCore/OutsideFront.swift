import Foundation

/// **The keys of the app after it came to the front from outside.** The owner's own agent can bring the app to the
/// front (`setup_show`, and the sign of `founderizer-cli guide`), and any process of the owner's user can do the same
/// through the app's program. At that moment the owner may be typing in another window: the next keys of that typing
/// would land in the app, in the field that has the cursor, on a default button (the paid press "Make the server", the
/// Continue of "Name your manager") or on a page that takes plain keys (a number and Return answer a request on Needs
/// you). So after such a front the app takes no key press until the owner's first click in it, or until the owner
/// leaves it and comes back by themselves (the owner's "Yes, build it" of 15 November 2026 to the plan
/// `agent-install-app-map-plan.md`, section 4: that rule for the paid press, made here for every key because a review
/// found the same fault at the name's field).
///
/// **It holds unless the app is in front and the owner clicked in it since it came there**: an owner who works in
/// the app keeps their keys when their agent asks for the front. A key counts as no such sign, because the first
/// stray key would then end the hold that it is meant to meet. **No key passes, with Command too**: Command and
/// Return sends the message of a chat, and Command and W closes the window.
///
/// **A page that changed from outside holds the keys also for an owner who works in the app** (`setup_show` for a
/// place of the fleet's own pages): the keys that the owner types at that moment are for the page that went, a
/// message in a chat's box for one, and on the page that came they would do another thing (on Needs you a number and
/// Return answer a request). So that owner loses their keys until their next click, as an owner who comes from
/// another window does.
///
/// **After a page that changed from outside, the first click reaches no control** (`holdsClick`): that click was
/// aimed at the page that went, and on the page that came it would land on another control (an option of a request
/// on Needs you, the "−" that takes access away on Can use). So the first click only ends the hold: the app drops
/// its mouse-down, and with it its drags and its mouse-up. A front that changed no page drops no click. Leaving
/// the app ends this hold too: the owner who comes back sees the page that came, and clicks on what they see.
///
/// **The click that is dropped is a whole click that began after the change.** No page changes from outside while
/// a mouse button is down (`ShowRules`: `setup_show` refuses then), so a change never cuts a click in two. Until 15
/// November 2026 a click that was under way at the change counted as the dropped one, and the next click reached
/// the app: a review showed that this next click can come 100 ms later, on a page that the owner did not see yet.
///
/// **A double click is one click**: a mouse-down with a click count above 1 that follows a dropped mouse-down is
/// the same click series, aimed at the page that went, and is dropped too, with its mouse-up. macOS counts by time
/// and place, so a fast second click close to the first is dropped with it. The next single click reaches the app.
///
/// A value type with no clock: the app's side wires it to its own events (`AppFront`).
public struct OutsideFront: Equatable, Sendable {
    /// The app takes no key press now.
    public private(set) var holdsKeys = false
    /// The app drops the next click: a page changed from outside, and the owner did not click since.
    public private(set) var holdsClick = false
    /// The owner clicked in the app while it was the app in front, and it did not leave the front since.
    private var clicked = false
    /// The mouse-down of a click was dropped, and its button is still down: its drags and its mouse-up go with it.
    private var droppedDown = false
    /// The last mouse-down was dropped: a later mouse-down of the same click series is dropped too.
    private var lastDropped = false
    /// The mouse-down that the rule answered last, and its answer (`click`).
    private var lastEvent: Event?
    private var lastReaches = true

    /// **One mouse-down, by what AppKit says of it**: its number (`NSEvent.eventNumber`), its time
    /// (`NSEvent.timestamp`) and its place in a click series (`NSEvent.clickCount`: 2 for the second mouse-down of a
    /// double click). The time is in it because an event that a program made can carry any number.
    public struct Event: Equatable, Sendable {
        public var number: Int
        public var time: Double
        public var count: Int

        public init(number: Int, time: Double, count: Int = 1) {
            self.number = number
            self.time = time
            self.count = count
        }
    }

    public init() {}

    /// The app was asked to the front from outside. `appInFront`: it is the app in front at that moment.
    /// `pageChanged`: the ask changed the page that the window shows, so the hold comes for every owner, and the
    /// next click only ends it. The caller changes no page while a mouse button is down (`ShowRules`).
    public mutating func came(appInFront: Bool, pageChanged: Bool = false) {
        if pageChanged || !appInFront || !clicked { holdsKeys = true }
        if pageChanged { holdsClick = true }
    }

    /// A click in the app (its mouse-down). Each click ends a hold: the owner is at the app's window. It counts for
    /// later only when the app is the app in front (`appInFront`): macOS can give a click to a window in the back
    /// without bringing its app forward, and the guide's sign can reach the app after its program brought it forward,
    /// so such a click must be worth nothing then. **True when the click reaches the app's controls**: false for the
    /// first click after a page changed from outside, which the app drops.
    ///
    /// **One event is one click, whichever watch asks first** (`event`): the app has more than one watch of its
    /// mouse-downs (the hold's own, and the one that opens the app's menu on a right click), and AppKit gives them no
    /// fixed order. Each asks this rule with the event, and the second one that asks for the same event gets the
    /// first one's answer: else the second ask would count as a second click, and a dropped click would pass.
    ///
    /// **A later mouse-down of a click series whose mouse-down before it was dropped is dropped too** (the event's
    /// `count` above 1): a double click is one click for the hold.
    @discardableResult
    public mutating func click(appInFront: Bool, event: Event? = nil) -> Bool {
        if let event, event == lastEvent { return lastReaches }
        let sameSeries = (event?.count ?? 1) > 1 && lastDropped
        let reaches = !holdsClick && !sameSeries
        holdsClick = false
        droppedDown = !reaches
        lastDropped = !reaches
        if appInFront { clicked = true }
        holdsKeys = false
        lastEvent = event
        lastReaches = reaches
        return reaches
    }

    /// Whether `event` is the mouse-down that `click` answered last: a watch that asks for it again counts nothing.
    public func answered(_ event: Event) -> Bool { event == lastEvent }

    /// A drag with a button down, or a button's release (`up`). True when it reaches the app's controls: false while
    /// it belongs to a click whose mouse-down the app dropped.
    public mutating func pointer(up: Bool) -> Bool {
        guard droppedDown else { return true }
        if up { droppedDown = false }
        return false
    }

    /// The app is no longer the app in front: what comes next is a new arrival.
    public mutating func leftFront() {
        clicked = false
        holdsKeys = false
        holdsClick = false
    }

    /// Whether a key press reaches the app.
    public var takesKeys: Bool { !holdsKeys }
}
