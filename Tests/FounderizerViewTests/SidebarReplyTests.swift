import FleetCore
import Foundation
import Testing
@testable import Founderizer

struct SidebarReplyTests {
    @Test func aNewReplyClearsWhenItsChatOpensBetweenFleetReadings() async throws {
        let (marks, _) = try await ViewHost.onMainLoop {
            let db = "sidebar-\(UUID().uuidString)"
            func reading(_ ids: [Int]) throws -> HubState {
                let agents: [[String: Any]] = ["manager", "helper"].map {
                    ["name": $0, "role": $0, "runtime": "codex", "can": [], "placed": true]
                }
                let reports: [[String: Any]] = ids.map {
                    ["id": $0, "agent": "helper", "text": "Ready", "about": "", "created": $0]
                }
                let state: [String: Any] = [
                    "schema_version": 1, "db": db, "time": 100, "agents": agents, "reports": reports,
                    "tasks": [], "notes": [], "permissions": [], "messages": [], "needs": []
                ]
                return try HubState.decode(JSONSerialization.data(withJSONObject: state))
            }
            let store = ViewHost.store(try reading([2]))
            store.destination = .agents
            store.markRead("helper")
            store.state = try reading([11, 2])
            let new = store.hasNewReply(from: "helper")
            store.destination = .agent("helper")
            let opened = store.hasNewReply(from: "helper")
            store.markUnread("helper")
            let marked = store.hasNewReply(from: "helper")
            store.markRead("helper")
            return [new, opened, marked, store.hasNewReply(from: "helper")]
        }
        #expect(marks == [true, false, true, false])
    }
}
