import Testing
@testable import FleetCore

/// The owner, 14 November 2026, with "Latest" over a chat that stood at its last message: "it shows the Latest badge
/// when there are actually no more messages". `ChatEnd` is what the chat and the task thread ask.
struct ChatEndTests {
    @Test func aChatThatOpensFollowsItsNewestRowAndShowsNoLatest() {
        let end = ChatEnd()
        #expect(end.followsLatest)
        #expect(!end.showsLatest)
    }

    @Test func aScrollAwayFromTheEndShowsLatestUntilTheViewComesBack() {
        var end = ChatEnd()
        end.taken()
        end.stands(under: 600, moved: true)
        end.rested(under: 600, jumped: false)
        #expect(end.showsLatest)
        #expect(!end.followsLatest)
        // He scrolls back: the view comes to its end and rests there.
        end.taken()
        end.stands(under: 40, moved: true)
        end.rested(under: 40, jumped: false)
        #expect(!end.showsLatest)
        #expect(end.followsLatest)
    }

    /// Fingers that rest on the trackpad start a phase and move nothing, and a scroll can end in a phase that asks
    /// nothing again. The view never left its end.
    @Test func aViewInHandAtItsEndShowsNoLatest() {
        var end = ChatEnd()
        end.taken()
        #expect(!end.showsLatest)
        #expect(end.followsLatest)
        end.rested(under: 0, jumped: true)
        #expect(!end.showsLatest)
        #expect(end.followsLatest)
    }

    /// A taller window, a card that folds, a key or the scroll bar bring the view to its end with no phase of the
    /// scroll that says so.
    @Test func aViewThatComesToItsEndByAnyWayFollowsAgain() {
        var end = ChatEnd()
        end.taken()
        end.stands(under: 300, moved: true)
        end.rested(under: 300, jumped: false)
        #expect(end.showsLatest)
        // The window became taller: the room changed, and the view stands at its end.
        end.stands(under: 0, moved: false)
        #expect(!end.showsLatest)
        #expect(end.followsLatest)
        // A long reply then comes under it: the chat goes to it, and Latest stays away.
        end.stands(under: 800, moved: false)
        #expect(end.followsLatest)
        #expect(!end.showsLatest)
    }

    /// The scroll bar, a key or a jump take the view from its end with no phase that says he has it in hand. The chat
    /// is as long as it was, so nothing came under the view: the view moved.
    @Test func aViewThatLeavesItsEndByAnyWayStopsFollowingAndShowsLatest() {
        var end = ChatEnd()
        end.stands(under: 3000, moved: true)
        #expect(end.showsLatest)
        #expect(!end.followsLatest)
        end.stands(under: 0, moved: true)
        #expect(!end.showsLatest)
        #expect(end.followsLatest)
    }

    /// The search card's "In messages" (13 November 2026): a jump to a match stops the following, so that the next
    /// entry does not pull the chat away from the match. The chat stops following before the jump and again after it.
    @Test func aJumpToAMatchFarBackStopsTheFollowingAndShowsLatest() {
        var end = ChatEnd()
        end.followsLatest = false
        end.stands(under: 14_000, moved: true)
        end.followsLatest = false
        #expect(end.showsLatest)
        #expect(!end.followsLatest)
        // Two new entries come under the match: nothing follows them.
        end.stands(under: 14_200, moved: false)
        #expect(end.showsLatest)
        #expect(!end.followsLatest)
        // Latest brings the view to its end.
        end.followsLatest = true
        end.stands(under: 0, moved: true)
        #expect(!end.showsLatest)
        #expect(end.followsLatest)
    }

    /// A match so far back that the chat first draws the earlier messages over it: the chat grows over a view at its
    /// end, which is no leave, and then the jump moves the view over a chat of the same length.
    @Test func aJumpToAMatchThatTheChatDrawsFirstStopsTheFollowing() {
        var end = ChatEnd()
        end.followsLatest = false
        end.stands(under: 9000, moved: false)
        #expect(!end.followsLatest)
        end.followsLatest = false
        #expect(end.showsLatest)
        end.stands(under: 9100, moved: false)
        #expect(!end.followsLatest)
    }

    /// A match that is the chat's newest message moves nothing, so the scroll says nothing after the jump: the view
    /// stands at its end, which is all that the chat asks when the next message comes.
    @Test func aJumpToAMatchAtTheEndKeepsTheFollowingAndShowsNoLatest() {
        var end = ChatEnd()
        end.followsLatest = false
        end.followsLatest = false
        #expect(!end.showsLatest)
        #expect(end.followsLatest)
        // The chat went to the next message, so the view stands at its end still.
        end.stands(under: 0, moved: false)
        #expect(!end.showsLatest)
        #expect(end.followsLatest)
    }

    /// Rows that come while the chat scrolls to its newest row stand under the view when that scroll ends. The chat
    /// made the scroll, so its end does not stop the following.
    @Test func theEndOfTheChatsOwnScrollNeverStopsTheFollowing() {
        var end = ChatEnd()
        end.stands(under: 400, moved: false)
        end.rested(under: 400, jumped: true)
        #expect(end.followsLatest)
        #expect(!end.showsLatest)
        // His own scroll that rests there does.
        end.taken()
        end.rested(under: 400, jumped: false)
        #expect(end.showsLatest)
    }

    @Test func theEndIsLessThanAHundredPointsUnderTheView() {
        #expect(ChatEnd.isEnd(0))
        #expect(ChatEnd.isEnd(-30))      // the view past its end, as a scroll that springs back
        #expect(ChatEnd.isEnd(99))
        #expect(!ChatEnd.isEnd(100))
    }
}
