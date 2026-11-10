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
