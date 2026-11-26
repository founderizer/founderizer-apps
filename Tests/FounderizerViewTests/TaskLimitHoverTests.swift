import FleetCore
import Foundation
import Testing
@testable import Founderizer

/// **A held task's hover in its thread names its agent only when the agent's own route is held** (owner API 1.330; the
/// owner, 24 November 2026: the fleet had wrong data about an agent, which the hover said as "<agent> is at its usage
/// limit" while that agent chatted and worked). A hold of the agent's screen route keeps only its desktop task: the hover
/// says the usage bar's words, "Usage limit until <time>", and nothing when the reset's time is not known. Bugs: the
/// hover says the agent's sentence for a hold of its screen route (his complaint, back in the thread); or it drops the
/// agent's sentence where the agent's own route is held, or on a hub without `task_limit`.
@Suite struct TaskLimitHoverTests {
    private static let now = 1_000_000.0

    private func reading(features: [String], agentHeld: Bool) throws -> HubState {
        var agent: [String: Any] = ["name": "remy", "role": "worker", "runtime": "claude", "can": []]
        if agentHeld { agent["limit"] = ["since": Self.now - 60, "until": Self.now + 3600, "reset_known": true, "task": NSNull()] }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": [agent], "tasks": [], "holds": [],
            "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [], "ui_features": features]))
    }

    private func hold(known: Bool = true) throws -> RuntimeLimit {
        try JSONDecoder().decode(RuntimeLimit.self, from: JSONSerialization.data(withJSONObject: [
            "since": Self.now - 60, "until": Self.now + 3600, "reset_known": known]))
    }

    /// **The thread's limit line stands while the rule's hold keeps the task, and nothing comes first**
    /// (`HubState.limitHolding`): the task's own hold on a hub with `task_limit`, else its agent's; no line for a task
    /// that ended or that his hold holds. Bugs: the line reads the agent's limit on every hub (a line on the agent's other
    /// tasks, and none on the held desktop task); or it stands over his pause, or on an ended task.
    @Test func theThreadsLimitLineIsTheRulesHold() throws {
        func line(features: [String], agentHeld: Bool, taskHeld: Bool, state: String = "working",
                  paused: Bool = false) throws -> RuntimeLimit? {
            let limit: [String: Any] = ["since": Self.now - 60, "until": Self.now + 3600, "reset_known": true]
            var agent: [String: Any] = ["name": "remy", "role": "worker", "runtime": "claude", "can": []]
            if agentHeld { agent["limit"] = limit }
            let task: [String: Any] = ["id": 9, "title": "Desktop work", "details": "", "done_when": "", "needs": "screen",
                                       "goal": "", "owner": "remy", "requester": "manager", "state": state, "created": 1.0,
                                       "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0,
                                       "limit": taskHeld ? limit : NSNull()]
            let holds: [[String: Any]] = paused ? [["id": 1, "task": 9, "kind": "pause", "state": "stopped", "attempt": 1]] : []
            let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": "test-db", "time": Self.now, "agents": [agent], "tasks": [task], "holds": holds,
                "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [],
                "ui_features": features]))
            return state.limitHolding(state.tasks[0])
        }
        #expect(try line(features: [TaskLimit.feature], agentHeld: false, taskHeld: true)?.until == Self.now + 3600)
        #expect(try line(features: [TaskLimit.feature], agentHeld: true, taskHeld: false) == nil)
        #expect(try line(features: [], agentHeld: true, taskHeld: false)?.until == Self.now + 3600)
        #expect(try line(features: [TaskLimit.feature], agentHeld: false, taskHeld: true, state: "completed") == nil)
        #expect(try line(features: [TaskLimit.feature], agentHeld: false, taskHeld: true, paused: true) == nil)
    }

    @Test func theHoverNamesTheAgentOnlyWhenItsOwnRouteIsHeld() throws {
        let screen = try reading(features: [TaskLimit.feature], agentHeld: false)
        let words = try #require(screen.limitHover(try hold(), owner: "remy"))
        #expect(words == "Usage limit until " + fleetComingTime(Self.now + 3600, now: Self.now))
        #expect(!words.contains("Remy") && !words.contains("is at its usage limit"))
        #expect(screen.limitHover(try hold(known: false), owner: "remy") == nil)
        // Its own route is held: the agent is at its limit.
        let own = try reading(features: [TaskLimit.feature], agentHeld: true)
        #expect(own.limitHover(try hold(), owner: "remy")?.hasPrefix("Remy is at its usage limit until ") == true)
        // A hub without task_limit: the agent's limit was the reading, as before.
        let older = try reading(features: [], agentHeld: false)
        #expect(older.limitHover(try hold(known: false), owner: "remy") == "Remy is at its usage limit.")
    }
}
