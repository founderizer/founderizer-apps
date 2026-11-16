import Testing
@testable import FleetCore

struct PageHistoryTests {
    @Test func backAndForwardRetraceThePagesHeOpened() {
        var history = PageHistory<String>()
        history.went(from: "chat", to: "tasks")
        history.went(from: "tasks", to: "agents")
        #expect(history.goBack(from: "agents") == "tasks")
        #expect(history.goBack(from: "tasks") == "chat")
        #expect(history.goBack(from: "chat") == nil)
        #expect(history.goForward(from: "chat") == "tasks")
        #expect(history.goForward(from: "tasks") == "agents")
        #expect(history.goForward(from: "agents") == nil)
    }

    @Test func aPageHeOpensHimselfEndsTheForwardList() {
        var history = PageHistory<String>()
        history.went(from: "chat", to: "tasks")
        #expect(history.goBack(from: "tasks") == "chat")
        history.went(from: "chat", to: "settings")
        #expect(history.forward.isEmpty)
        #expect(history.goBack(from: "settings") == "chat")
    }

    @Test func thePageHeIsOnIsNoStep() {
        var history = PageHistory<String>()
        history.went(from: "chat", to: "chat")
        #expect(history.back.isEmpty)
    }

    @Test func aPageThatCannotOpenIsPassedOver() {
        var history = PageHistory<String>()
        history.went(from: "chat", to: "agent.old")
        history.went(from: "agent.old", to: "tasks")
        #expect(history.goBack(from: "tasks") { $0 != "agent.old" } == "chat")
        #expect(history.forward == ["tasks"])
    }

    /// The × of a wizard that fills the window: Add agent, then the new agent's setup, closes to the page he left
    /// before them, and neither wizard page stays on a list.
    @Test func aWizardThatClosesGoesOnNoList() {
        var history = PageHistory<String>()
        history.went(from: "tasks", to: "chat")
        history.went(from: "chat", to: "add-agent")
        history.went(from: "add-agent", to: "setup.juno")
        #expect(history.leave(from: "setup.juno") { $0 != "add-agent" } == "chat")
        #expect(history.back == ["tasks"])
        #expect(history.forward.isEmpty)
        #expect(history.leave(from: "chat") { _ in false } == nil)
        #expect(history.back.isEmpty)
    }

    /// **A place that shows as another page** (`FleetStore.standIn`, review N1): the chat place of an agent on a model
    /// account shows as its detail page, and that move is no step. Back from the detail page goes to the page before the
    /// chat place, and Forward comes back to the detail page. As an ordinary step, Back opened the chat place, which moved
    /// to the detail page again: Back did nothing.
    @Test func aPlaceThatShowsAsAnotherPageIsNoStep() {
        var history = PageHistory<String>()
        history.went(from: "tasks", to: "chat.iris")
        // The move to "detail.iris" is no step: nothing is written to the history.
        #expect(history.goBack(from: "detail.iris") == "tasks")
        #expect(history.back.isEmpty)
        #expect(history.goForward(from: "tasks") == "detail.iris")
        // Back to the chat place by a step (it was on the list before): it moves to the detail page with no step, and
        // the next Back goes on to the page before it.
        var older = PageHistory<String>()
        older.went(from: "tasks", to: "chat.iris")
        older.went(from: "chat.iris", to: "agents")
        #expect(older.goBack(from: "agents") == "chat.iris")
        #expect(older.goBack(from: "detail.iris") == "tasks")
        // The old move, an ordinary step: Back opens the chat place again.
        var step = PageHistory<String>()
        step.went(from: "tasks", to: "chat.iris")
        step.went(from: "chat.iris", to: "detail.iris")
        #expect(step.goBack(from: "detail.iris") == "chat.iris")
    }

    @Test func aRenamedPageKeepsItsPlace() {
        var history = PageHistory<String>()
        history.went(from: "server.worker-1", to: "tasks")
        history.rename { $0 == "server.worker-1" ? "server.box" : $0 }
        #expect(history.goBack(from: "tasks") == "server.box")
    }

    @Test func eachListKeepsItsNewestPages() {
        var history = PageHistory<Int>()
        for page in 0...PageHistory<Int>.limit + 9 { history.went(from: page, to: page + 1) }
        #expect(history.back.count == PageHistory<Int>.limit)
        #expect(history.back.first == 10)
    }
}
