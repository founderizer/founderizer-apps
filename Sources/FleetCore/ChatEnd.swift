import Foundation

/// **Whether a chat or a task thread stands at its end**, which decides two things: whether it follows its newest row,
/// and whether "Latest" shows over it.
///
/// It keeps two facts. `follows` is what the scroll's own phases say: he took the view in hand, and where it came to
/// rest. `atEnd` is where the view stands now, from the scroll's own measure. The phases alone left "Latest" over a
/// chat that stood at its end (the owner, 14 November 2026: "it shows the Latest badge when there are actually no more
/// messages"): a jump to a match that is the newest message stops the following and moves nothing, fingers that rest
/// on the trackpad start a phase and no scroll, and a view that comes to its end with no phase of its own (a taller
/// window, a card that folds, a key) was never asked again. So a view at its end follows and shows no "Latest",
/// whatever the phases said last, and a view that leaves its end stops following, whatever moved it.
public struct ChatEnd: Equatable, Sendable {
    /// The most that stands under the view while it still counts as at its end, in points.
    public static let near = 100.0

    /// What the scroll's phases said last: false from the moment he takes the view in hand, or a jump to a match
    /// takes it, until it rests at its end again.
    private var follows = true
    /// The view stands at its end now.
    private var atEnd = true

    public init() {}

    /// **The chat goes to its newest row when one comes.** Set true by "Latest", which brings the view to its end, and
    /// false by a jump to a match, which takes it from there: a view that stands at its end follows all the same.
    public var followsLatest: Bool {
        get { follows || atEnd }
        set { follows = newValue }
    }
    /// "Latest" shows: the view stands away from its end, and nothing brings it there.
    public var showsLatest: Bool { !followsLatest }

    /// He took the view in hand (the scroll's phases `interacting` and `tracking`).
    public mutating func taken() { follows = false }

    /// The scroll came to rest with `under` points of the chat under the view. After a scroll that the chat made
    /// itself (`jumped`, the phase `animating`) the rest can only start the following, never stop it: rows that came
    /// during that scroll stand under the view, and the chat still follows them.
    public mutating func rested(under: Double, jumped: Bool) {
        let end = Self.isEnd(under)
        if end || !jumped { follows = end }
    }

    /// The view stands with `under` points of the chat under it. A view that comes to its end follows again. A view
    /// that left its end stops following when the view itself `moved`: the chat is as long and its room as high as
    /// they were, so nothing came under the view, and he or a jump took it from there by a way that has no phase. A
    /// chat that grew under the view, or a room that became smaller, keeps the following: the chat then goes to its
    /// newest row.
    public mutating func stands(under: Double, moved: Bool) {
        let end = Self.isEnd(under)
        if end { follows = true } else if atEnd, moved { follows = false }
        atEnd = end
    }

    /// Whether a view with `under` points of the chat under it stands at the chat's end.
    public static func isEnd(_ under: Double) -> Bool { under < near }
}
