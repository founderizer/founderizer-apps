import Foundation
import Testing
@testable import FleetCore

@Test func perAgentChatAvailabilityKeepsLegacyRoutingAndHonorsRefusals() throws {
    func state(feature: Bool, allowed: Bool?) throws -> HubState {
        var agent: [String: Any] = ["name": "worker", "role": "worker", "runtime": "grok", "can": []]
        if let allowed { agent["direct_chat"] = allowed }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "chat-capabilities", "time": 1000.0,
            "ui_features": feature ? ["direct_chat"] : [], "agents": [agent],
            "tasks": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []
        ]))
    }
    #expect(try state(feature: false, allowed: nil).supportsChat(with: "manager"))
    #expect(try !state(feature: false, allowed: true).supportsChat(with: "worker"))
    #expect(try state(feature: true, allowed: nil).supportsChat(with: "worker"))
    #expect(try state(feature: true, allowed: true).supportsChat(with: "worker"))
    #expect(try !state(feature: true, allowed: false).supportsChat(with: "worker"))
}

@Test func chatHistoryIsBoundedAndUnchangedPollsSkipReindexing() throws {
    let data = try JSONSerialization.data(withJSONObject: (0..<10_000).map {
        ["id": $0, "agent": $0 % 2 == 0 ? "manager" : "worker", "text": "Report \($0)", "about": "", "created": Double($0)] as [String: Any]
    })
    let reports = try JSONDecoder().decode([ManagerReport].self, from: data)
    let freshReports = try JSONDecoder().decode([ManagerReport].self, from: data)
    var timeline = ChatTimeline()
    #expect({ timeline.update(messages: [], reports: reports) }())
    #expect(timeline.count(for: "manager") == 5000)
    #expect(timeline.count(for: "worker") == 5000)
    #expect(timeline.entries(for: "manager").count == 60)
    #expect(timeline.entries(for: "worker", limit: 120).count == 120)
    #expect(timeline.entries(for: "manager").last?.id == "report-9998")
    #expect(timeline.entries(for: "worker").last?.id == "report-9999")
    #expect(timeline.entries(for: "missing").isEmpty)
    #expect(timeline.entries(for: "worker", limit: -1).isEmpty)
    let start = ContinuousClock.now
    for _ in 0..<100 {
        #expect({ !timeline.update(messages: [], reports: freshReports) }())
        #expect(timeline.entries(for: "manager").count == 60)
    }
    print("10,000-row chat: 100 unchanged refresh checks + 60-row reads: \(start.duration(to: .now))")
}

@Test func chatIndexUpdatesReadReceiptsAndClearsAcrossHubs() throws {
    func message(_ read: Double?) throws -> OwnerMessage {
        try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: [
            "request_id": "r", "kind": "message", "text": "Hello", "event_id": 1,
            "created": 1.0, "client": "test", "recipient": "worker", "read_at": read as Any? ?? NSNull()
        ]))
    }
    var timeline = ChatTimeline()
    let initialChanged = timeline.update(messages: [try message(nil)], reports: [])
    #expect(initialChanged)
    #expect(timeline.entries(for: "manager").isEmpty)
    let receiptChanged = timeline.update(messages: [try message(2)], reports: [])
    #expect(receiptChanged)
    if case .message(let row) = timeline.entries(for: "worker").first { #expect(row.read_at == 2) }
    else { Issue.record("Missing worker message") }
    #expect({ timeline.update(messages: [], reports: []) }())
    #expect(timeline.entries(for: "worker").isEmpty)
}
