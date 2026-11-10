import Foundation
import Testing
@testable import FleetCore

/// What an agent is doing now, read out of what the app already holds: the line under its name in the main sidebar.
struct AgentActivityTests {
    private func task(_ id: Int, owner: String = "vps", state: String = "working", title: String = "The shop page",
                      created: Double = 100, delivered: Double? = nil, what: String? = nil,
                      accepted: Int? = nil) throws -> FleetTask {
        let when: String = delivered.map { String($0) } ?? "null"
        let result: String = what.map { "\"" + $0 + "\"" } ?? "null"
        let checked: String = accepted.map { String($0) } ?? "null"
        let json = "{\"id\": \(id), \"title\": \"\(title)\", \"details\": \"\", \"done_when\": \"\", "
            + "\"needs\": \"\", \"goal\": \"\", \"owner\": \"\(owner)\", \"requester\": \"manager\", "
            + "\"state\": \"\(state)\", \"created\": \(created), \"attempt\": 1, \"restarts\": 0, "
            + "\"nudge_level\": 0, \"stop_sent\": 0, \"delivered\": \(when), \"what\": \(result), \"accepted\": \(checked)}"
        return try JSONDecoder().decode(FleetTask.self, from: Data(json.utf8))
    }

    /// The fleet list says what an agent is doing, and says nothing about one that is doing nothing: the status
    /// dot beside its name already carries that.
    @Test func theFleetListSaysWhatItIsDoingOrNothingAtAll() throws {
        #expect(AgentActivity.doingNow("vps", tasks: [try task(412)]) == "The shop page")
        // Several open tasks: the one that moved last, and how many more there are.
        #expect(AgentActivity.doingNow("vps", tasks: [try task(1, title: "Check the price page", created: 300),
                                                      try task(2, title: "The shop page", created: 100),
                                                      try task(3, title: "Write the mail", created: 200)])
                == "Check the price page · +2")
        #expect(AgentActivity.doingNow("vps", tasks: [try task(1, state: "completed")]) == nil)
        #expect(AgentActivity.doingNow("vps", tasks: []) == nil)
    }
}
