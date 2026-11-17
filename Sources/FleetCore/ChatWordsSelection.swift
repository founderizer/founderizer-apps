import Foundation

/// **Which rows of a chat can have their words selected now** (the Mac app's agent chat; the owner, 17 November 2026:
/// "scrolling up and down the fleet manager conversation does not feel smooth").
///
/// SwiftUI keeps a hidden AppKit text field over each text that can be selected, and each of these fields drew again at
/// every frame of a scroll, also where it stood far from the screen. The Fleet Manager's chat of 60 entries had 273 of
/// them, and a frame of its scroll took 13 to 16 ms where a screen of 120 Hz gives 8.3 (measured in a copy of the app
/// with that chat; with no field, the same scroll took about a third of each frame). A row that gets or loses its
/// fields is slow too, so the fields cannot come and go with the rows on the screen while the chat moves: that gave
/// frames of 30 to 45 ms. So only two rows have them: the row under the pointer, where a press starts a selection, and
/// the row whose words he pressed last, which keeps its selection when the pointer leaves it, for ⌘C and its menu.
/// While the chat scrolls, nothing changes: the row under the pointer gets its fields when the chat comes to rest.
public struct ChatWordsSelection: Equatable, Sendable {
    /// The row under the pointer.
    public private(set) var hovered: String?
    /// The row whose words he pressed last.
    public private(set) var pressed: String?
    /// The chat's scroll moves now.
    public private(set) var scrolling = false
    /// The rows whose words can be selected now.
    public private(set) var selectable: Set<String> = []

    public init() {}

    /// The pointer came into `row`, or left it.
    public mutating func hover(_ row: String, inside: Bool) {
        if inside { hovered = row } else if hovered == row { hovered = nil }
        settle()
    }

    /// He pressed a button of the mouse. A press on words (`onWords`, a text that he can select or write in) gives the
    /// row under the pointer the press: a selection begins there and ends where it stood before. A press on a button,
    /// an option of a card or the room between rows keeps the row of the press before, as AppKit keeps a selection
    /// when he presses a button.
    public mutating func press(onWords: Bool) {
        if onWords, let hovered { pressed = hovered }
        settle()
    }

    /// The chat's scroll began to move, or came to rest.
    public mutating func scroll(moving: Bool) {
        scrolling = moving
        settle()
    }

    private mutating func settle() {
        guard !scrolling else { return }
        selectable = Set([hovered, pressed].compactMap { $0 })
    }
}
