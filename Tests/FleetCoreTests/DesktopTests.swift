import Foundation
import Testing
@testable import FleetCore

@Test func browserDesktopRequiresTheTaskOwnerCapabilityAndHubSupport() throws {
    func taskState(needs: String = "browser", status: String = "working", screen: Bool = true,
                   features: [String] = ["live_desktop", "browser_desktop"],
                   holds: [[String: Any]] = []) throws -> HubState {
        let task: [String: Any] = ["id": 7, "title": "Chrome task", "details": "Local check", "done_when": "Checked",
            "needs": needs, "goal": "Local", "owner": "worker", "requester": "manager", "state": status,
            "created": 1000, "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "local", "time": 1000, "ui_features": features,
            "agents": [["name": "worker", "role": "worker", "runtime": "claude", "can": screen ? ["browser", "screen"] : ["browser"]],
                       ["name": "other-mac", "role": "worker", "runtime": "claude", "can": ["screen"]]],
            "tasks": [task], "holds": holds, "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []]))
    }
    let supported = try taskState()
    #expect(supported.tasks[0].supportsDesktopPreview(in: supported))
    let noScreen = try taskState(screen: false)      // a Mac set up for Claude alone: its Chrome can still be watched
    #expect(noScreen.tasks[0].supportsDesktopPreview(in: noScreen))
    for state in [try taskState(features: ["live_desktop"]),
                  try taskState(features: ["browser_desktop"]), try taskState(status: "completed"),
                  try taskState(status: "canceled"), try taskState(needs: "none")] {
        #expect(!state.tasks[0].supportsDesktopPreview(in: state))
    }
    let previous = try taskState(needs: "screen", features: ["live_desktop"])
    #expect(previous.tasks[0].supportsDesktopPreview(in: previous))
    for needs in ["browser", "screen"] {
        for holdState in ["requested", "stopped", "not_confirmed", "released"] {
            let hold: [String: Any] = ["id": 1, "task": 7, "kind": "pause", "state": holdState, "attempt": 1]
            let held = try taskState(needs: needs, holds: [hold])
            #expect(held.tasks[0].supportsDesktopPreview(in: held) == (holdState == "released"))
            let other = try taskState(needs: needs, holds: [hold.merging(["task": 8]) { _, value in value }])
            #expect(other.tasks[0].supportsDesktopPreview(in: other))
        }
    }
}

@Test func desktopResponseCannotCrossTaskAttemptOrGeneration() throws {
    let context = DesktopContext(hub: URL(string: "http://127.0.0.1:8765")!, database: "db", task: 7, attempt: 2)
    #expect(try context.url().absoluteString == "http://127.0.0.1:8765/ui/tasks/7/desktop?db=db&attempt=2")
    func frame(_ fields: [String: Any]) throws -> DesktopFrame {
        try JSONDecoder().decode(DesktopFrame.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    let base: [String: Any] = ["db": "db", "task": 7, "attempt": 2, "status": "waiting"]
    #expect(try frame(base).validatedImage(in: context) == nil)
    for changed in [["db": "other"], ["attempt": 1], ["task": 8], ["status": "invented"], ["image": "unexpected"]] as [[String: Any]] {
        #expect(throws: (any Error).self) { try frame(base.merging(changed) { _, value in value }).validatedImage(in: context) }
    }
    let stale = base.merging(["status": "live", "captured_at": 1, "image": "bad"]) { _, value in value }
    #expect(throws: (any Error).self) { try frame(stale).validatedImage(in: context, now: 100) }
}

@Test func screenAndPrimaryTokensAreSummedWithoutAddingQuotaPercentages() throws {
    let tokens: [String: Any] = ["input": 10,"output": 20,"cache_read": 30,"cache_write": 0,"total": 60,
        "sessions": 1,"since": 1000,"last_activity": 1900,"collected_at": 2000,"source": "test","scope": "test"]
    let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens, "screen": ["tokens": tokens]])
    let usage = try JSONDecoder().decode(AgentUsage.self, from: data)
    #expect(usage.isValid)
    #expect(usage.tokens?.total == 60)
    #expect(usage.screen?.tokens?.total == 60)
    #expect(usage.combinedTokens?.total == 120)
    #expect(usage.combinedTokens?.sessions == 2)
    #expect(usage.limits == nil)
    #expect(usage.screen?.limits == nil)
}
