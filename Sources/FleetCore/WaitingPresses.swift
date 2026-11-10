import Foundation

/// **The presses on a request's own options that wait until the hub can take them** (fix round 2 of 29 October 2026,
/// items 1 and 51), by request: the option pressed last, which the card marks "Sending…", and when the wait began. A
/// second press on another option of the same request takes the first one's place and keeps its start, so the mark moves
/// with it at once and the wait is not started again. No clock ends a wait (the owner's rule: a wait ends on an event):
/// it ends when its answer goes, or when the request leaves, its options change or this Mac turns to another hub.
public struct WaitingPresses: Equatable, Sendable {
    public struct Press: Equatable, Sendable {
        /// The option, by its place among the request's options.
        public let choice: Int
        /// When the first press of this wait came: the mark shows a second after it (`Held`).
        public let since: ContinuousClock.Instant
    }

    private var presses: [Int: Press] = [:]

    public init() {}

    /// A press on option `choice` of request `need`, at `now`. True when it starts a wait; false when a wait of that
    /// request goes on, and now carries this option.
    public mutating func press(_ choice: Int, need: Int, at now: ContinuousClock.Instant) -> Bool {
        if let current = presses[need] {
            presses[need] = Press(choice: choice, since: current.since)
            return false
        }
        presses[need] = Press(choice: choice, since: now)
        return true
    }

    /// The press that waits on request `need`, or nil.
    public func press(of need: Int) -> Press? { presses[need] }

    /// The wait of request `need` ended: its answer went, or the press was dropped.
    public mutating func end(_ need: Int) { presses[need] = nil }
}
