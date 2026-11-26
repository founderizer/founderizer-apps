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
