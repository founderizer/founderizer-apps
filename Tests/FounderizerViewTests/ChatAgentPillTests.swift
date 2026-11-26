import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **The chat's header names its agent by its name, with its role beside it** (the owner's answer of 22 November 2026:
/// the name with the role in grey in the chat header; `ChatAgentPill` draws `AgentNameLine`). The pill alone, in
/// the window of a test, read as a person reads it. Example names only.
@Suite(.serialized, .timeLimit(.minutes(10))) struct ChatAgentPillTests {
    /// The bug that this catches: the header shows the role alone, as before, or the name alone, so with ten agents he
    /// cannot tell what "Nova" does; or the role stands before the name.
    @Test func theHeaderReadsTheNameAndThenTheRoleOnOneLine() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (name: NSPoint?, role: NSPoint?) in
            let agents: [[String: Any]] = [
                ["name": "manager", "role": "manager", "title": "Fleet Manager", "runtime": "claude", "can": [], "placed": true],
                ["name": "nova", "role": "worker", "title": "Customer Support", "runtime": "claude", "can": [], "placed": true]]
            _ = ViewHost.store(try HubState.decode(JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": "pill-\(UUID().uuidString)", "time": Int(Date().timeIntervalSince1970),
                "agents": agents, "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [],
                "messages": [], "reports": [], "ui_features": [String]()] as [String: Any])))
            let host = NSHostingView(rootView: ChatAgentPill(agent: "nova").preferredColorScheme(.dark)
                .frame(width: 520, height: 120).background(FleetStyle.canvas))
            host.sizingOptions = []
            let window = ViewHost.window(showing: host, size: NSSize(width: 520, height: 120))
            defer { ViewHost.close(window) }
            return (try ViewHost.middle(of: "Nova", in: window), try ViewHost.middle(of: "Customer Support", in: window))
        }
        let name = try #require(seen.name, "the header shows the agent's name")
        let role = try #require(seen.role, "the header shows the agent's role")
        #expect(abs(name.y - role.y) < 4 && name.x < role.x, "one line, the name first: \(name) \(role)")
        #expect(screen.stayedHis)
    }
}
