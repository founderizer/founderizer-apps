import Testing
@testable import FleetCore

/// The owner, 17 November 2026: "scrolling up and down the fleet manager conversation does not feel smooth". A chat
/// keeps selectable words only on the row under the pointer and the row whose words he pressed last
/// (`ChatWordsSelection`).
struct ChatWordsSelectionTests {
    @Test func aChatThatOpensHasNoSelectableRow() {
        #expect(ChatWordsSelection().selectable.isEmpty)
    }

    @Test func theRowUnderThePointerIsSelectableAndStopsWhenThePointerLeaves() {
        var selection = ChatWordsSelection()
        selection.hover("report-1", inside: true)
        #expect(selection.selectable == ["report-1"])
        selection.hover("report-2", inside: true)
        selection.hover("report-1", inside: false)
        #expect(selection.selectable == ["report-2"])
        selection.hover("report-2", inside: false)
        #expect(selection.selectable.isEmpty)
    }

    /// A drag that selects words in one row can end over another row, and ⌘C comes after the pointer moved on.
    @Test func thePressedRowKeepsItsWordsWhenThePointerLeaves() {
        var selection = ChatWordsSelection()
        selection.hover("message-7", inside: true)
        selection.press(onWords: true)
        selection.hover("report-8", inside: true)
        selection.hover("message-7", inside: false)
        #expect(selection.selectable == ["message-7", "report-8"])
        selection.hover("report-8", inside: false)
        #expect(selection.selectable == ["message-7"])
    }

    @Test func aPressOnTheWordsOfAnotherRowTakesThePressFromTheFirst() {
        var selection = ChatWordsSelection()
        selection.hover("message-7", inside: true)
        selection.press(onWords: true)
        selection.hover("message-7", inside: false)
        selection.hover("need-3", inside: true)
        selection.press(onWords: true)
        selection.hover("need-3", inside: false)
        #expect(selection.selectable == ["need-3"])
    }

    /// A press on a button of another row (a reply's Copy, an option of a card) keeps his selection, as AppKit does.
    @Test func aPressOnAButtonOfAnotherRowKeepsThePressedRow() {
        var selection = ChatWordsSelection()
        selection.hover("report-1", inside: true)
        selection.press(onWords: true)
        selection.hover("report-1", inside: false)
        selection.hover("need-3", inside: true)
        selection.press(onWords: false)
        selection.hover("need-3", inside: false)
        #expect(selection.selectable == ["report-1"])
    }

    /// A press outside every row (the composer, the sidebar) does not end the selection of the row he pressed before.
    @Test func aPressOnNoRowKeepsThePressedRow() {
        var selection = ChatWordsSelection()
        selection.hover("message-7", inside: true)
        selection.press(onWords: true)
        selection.hover("message-7", inside: false)
        selection.press(onWords: true)
        #expect(selection.selectable == ["message-7"])
    }

    /// A row's fields are slow to make, so none comes or goes while the chat moves: the row under the pointer gets them
    /// when the chat rests.
    @Test func nothingChangesWhileTheChatScrolls() {
        var selection = ChatWordsSelection()
        selection.hover("report-1", inside: true)
        selection.scroll(moving: true)
        selection.hover("report-1", inside: false)
        selection.hover("report-2", inside: true)
        selection.hover("report-2", inside: false)
        selection.hover("report-3", inside: true)
        #expect(selection.selectable == ["report-1"])
        selection.scroll(moving: false)
        #expect(selection.selectable == ["report-3"])
    }

    /// The pointer left the row during the scroll and stands over no row when the chat rests: no row keeps its words.
    @Test func aRowThatThePointerLeftDuringTheScrollLosesItsWordsWhenTheChatRests() {
        var selection = ChatWordsSelection()
        selection.hover("report-1", inside: true)
        selection.scroll(moving: true)
        selection.hover("report-1", inside: false)
        #expect(selection.selectable == ["report-1"])
        selection.scroll(moving: false)
        #expect(selection.selectable.isEmpty)
    }

    @Test func aPressWhileTheChatScrollsTakesEffectWhenItRests() {
        var selection = ChatWordsSelection()
        selection.scroll(moving: true)
        selection.hover("report-4", inside: true)
        selection.press(onWords: true)
        #expect(selection.selectable.isEmpty)
        selection.scroll(moving: false)
        selection.hover("report-4", inside: false)
        #expect(selection.selectable == ["report-4"])
    }
}
