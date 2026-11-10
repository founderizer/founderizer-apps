import Foundation
import Testing
@testable import FleetCore

struct TeamTests {
    let hash = String(repeating: "a", count: 64)
    let revision = String(repeating: "b", count: 40)
    var lines: [ReportingLine] { [
        .init(agent: "worker", role: "worker", reports_to: "lead"),
        .init(agent: "manager", role: "manager", reports_to: nil),
        .init(agent: "lead", role: "lead", reports_to: "manager")
    ] }
    func snapshot(_ lines: [ReportingLine], open: [String: Int] = [:], db: String = "db") throws -> TeamSnapshot {
        let input = try payloadFields(TeamLinesInput(lines: lines))
        return try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject:
            input.merging(["db": db, "sha256": hash, "revision": revision, "open_tasks": open]) { _, new in new }))
    }
    @Test func reportingTreeRejectsLoopsAndKeepsEveryAgent() throws {
        let input = TeamLinesInput(lines: lines)
        #expect(input.isValid)
        #expect(input.tree.map(\.line.agent) == ["manager", "lead", "worker"])
        #expect(input.tree.map(\.depth) == [0, 1, 2])
        var loop = lines
        loop[0].role = "lead"; loop[2].reports_to = "worker"
        #expect(!TeamLinesInput(lines: loop).isValid)
        #expect(TeamLinesInput(lines: loop).tree.count == 3)
        var missing = lines; missing[0].reports_to = "unknown"
        #expect(!TeamLinesInput(lines: missing).isValid)
        var badParent = lines; badParent[2].role = "worker"
        #expect(!TeamLinesInput(lines: badParent).isValid)
        #expect(!TeamLinesInput(lines: lines + [lines[0]]).isValid)
        #expect(throws: (any Error).self) { try snapshot(lines, db: "another").validate(database: "db") }
        #expect(throws: (any Error).self) { try snapshot(lines, open: ["unknown": 1]).validate(database: "db") }
    }
    @Test func openTasksBlockRoleChangesButKeepReportingMovesAvailable() throws {
        let original = try snapshot(lines, open: ["worker": 1])
        var move = TeamLinesInput(lines: lines); move.lines[0].reports_to = "manager"
        #expect(move.problem(against: original, allowsLeads: true) == nil)
        move.lines[0].role = "lead"
        #expect(move.problem(against: original, allowsLeads: true) != nil)
        #expect(move.problem(against: try snapshot(lines), allowsLeads: true) == nil)
        #expect(move.problem(against: try snapshot(lines), allowsLeads: false) != nil)
        var swap = lines
        swap[1].role = "lead"; swap[1].reports_to = "lead"
        swap[2].role = "manager"; swap[2].reports_to = nil
        #expect(TeamLinesInput(lines: swap).problem(against: original, allowsLeads: true) != nil)
    }
    @Test func reportingCommandSurvivesStorageWithNullManagerAndSameIdentity() throws {
        let request = PendingRequest(hub: URL(string: "http://localhost:8765")!, database: "db", client: "local",
                                     command: .teamLines(sha256: hash), text: try TeamLinesInput(lines: lines).payload())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outbox = Outbox(file: folder.appendingPathComponent("pending.json"))
        try outbox.save(request)
        let restored = try #require(try outbox.load())
        #expect(restored.requestID == request.requestID && restored.route == "ui/team/lines")
        #expect(try restored.body() == request.body())
        let body = try JSONSerialization.jsonObject(with: restored.body()) as! [String: Any]
        #expect(body["base_sha256"] as? String == hash)
        #expect((body["lines"] as! [[String: Any]]).first { $0["role"] as? String == "manager" }?["reports_to"] is NSNull)
    }
    @Test func reportingReceiptsRefuseOtherPositionsAndOldBooleanShape() throws {
        let request = PendingRequest(hub: URL(string: "http://localhost:8765")!, database: "db", client: "local",
                                     command: .teamLines(sha256: hash), text: try TeamLinesInput(lines: lines).payload())
        var fields: [String: Any] = ["ok": true, "request_id": request.requestID.uuidString.lowercased(), "client": "local",
                                   "replayed": false, "revision": revision, "sha256": hash]
        func receipt() throws -> ControlReceipt {
            try JSONDecoder().decode(ControlReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        fields["changed"] = [["agent": "worker", "before": ["role": "worker", "reports_to": "manager"],
                              "after": ["role": "worker", "reports_to": "lead"]]]
        #expect(try receipt().matches(request))
        fields["changed"] = [["agent": "worker", "before": ["role": "worker", "reports_to": "manager"],
                              "after": ["role": "worker", "reports_to": "manager"]]]
        #expect(try !receipt().matches(request))
        fields["changed"] = false
        #expect(try receipt().changed?.flag == false)
        #expect(try !receipt().matches(request))
        fields["changed"] = []
        fields["client"] = "other-client"
        #expect(try !receipt().matches(request))
    }
}
