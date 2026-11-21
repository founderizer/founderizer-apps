import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: one agent's KPIs as GET /ui/kpis gives them (owner API 1.275).
struct KPIsTests {
    private static let week = 7 * 86_400.0
    private static let start = 1_791_331_200.0       // 7 October 2026, 00:00 UTC

    private func week(_ n: Int, _ value: Double?, counts: Bool) -> [String: Any] {
        ["start": Self.start + Double(n) * Self.week, "value": value ?? NSNull(), "counts": counts]
    }

    private func kpi(_ id: Int, direction: String = "at_least", number: Double = 80, unit: String = "%",
                     state: String = "on", value: Double? = 82, counts: Bool = true,
                     weeks: [[String: Any]]? = nil, marks: [[String: Any]] = []) -> [String: Any] {
        ["id": id, "ref": "I-\(id)", "agent": "support", "name": "Replies on time", "words": "Answer within a day",
         "direction": direction, "number": number, "unit": unit, "window_days": 7, "state": state,
         "state_since": Self.start, "setter": "lead", "setter_role": "Support Lead", "created": Self.start,
         "weeks": weeks ?? (0..<8).map { week($0, 82, counts: true) }, "marks": marks,
         "value": value ?? NSNull(), "value_at": value == nil ? NSNull() : Self.start + 7 * Self.week,
         "value_counts": counts]
    }

    private func decode(_ kpis: [[String: Any]], db: String = "db", agent: String? = "support") throws -> AgentKPIs {
        try JSONDecoder().decode(AgentKPIs.self, from: JSONSerialization.data(withJSONObject: [
            "db": db, "agent": agent ?? NSNull(), "kpis": kpis] as [String: Any]))
    }

    @Test func aCardSaysTheLevelAndTheNewestValueThatCounts() throws {
        let list = try decode([kpi(1), kpi(2, direction: "at_most", number: 5, unit: "h", value: 4.5),
                               kpi(3, number: 12, unit: "", value: 30, counts: false)])
        #expect(list.kpis.map(\.levelWords) == ["≥ 80%", "≤ 5 h", "≥ 12"])
        #expect(list.kpis.map(\.shownValue) == [KPI.amount(82, "%"), KPI.amount(4.5, "h"), nil])   // no count: a dash
        let english = Locale(identifier: "en_US")
        #expect([KPI.amount(82, "%", locale: english), KPI.amount(4.5, "h", locale: english),
                 KPI.amount(1200, "", locale: english), KPI.amount(1200, "EUR", locale: english)]
                == ["82%", "4.5 h", "1,200", "€1,200.00"])
        #expect(KPI.amount(12, "PRS", locale: english) == "12 PRS")       // three capitals that are no currency
        #expect(list.kpis[0].setter_role == "Support Lead")
    }

    @Test func offTargetIsUnderAFloorAndOverACeiling() throws {
        let list = try decode([kpi(1), kpi(2, direction: "at_most", number: 5, unit: "h", value: 6)])
        #expect(list.kpis[0].isOff(79) && !list.kpis[0].isOff(80) && !list.kpis[0].isOff(95))
        #expect(list.kpis[1].isOff(6) && !list.kpis[1].isOff(5) && !list.kpis[1].isOff(1))
    }

    @Test func aWeekOfAValueThatDoesNotCountIsNoColumnAndTheLevelStaysOnTheScale() throws {
        let weeks = [week(0, 40, counts: false), week(1, nil, counts: false), week(2, 60, counts: true),
                     week(3, 70, counts: true)]
        let low = try decode([kpi(1, number: 90, weeks: weeks)]).kpis[0]
        #expect(weeks.indices.map { low.counted(low.weeks[$0]) } == [nil, nil, 60, 70])
        #expect(abs(low.scaleTop - 90 * 1.15) < 1e-9)                 // the level's line stands inside the chart,
        let high = try decode([kpi(2, number: 50, weeks: weeks)]).kpis[0]  // with room over the highest
        #expect(abs(high.scaleTop - 70 * 1.15) < 1e-9)
    }

    @Test func aWeeksChangesAreTheMarksInsideItsSevenDays() throws {
        let marks: [[String: Any]] = [["at": Self.start + 3600, "words": "Level changed by Support Lead"],
                                      ["at": Self.start + Self.week, "words": "Check changed"],
                                      ["at": Self.start + 2 * Self.week - 1, "words": "Model changed"]]
        let kpi = try decode([kpi(1, marks: marks)]).kpis[0]
        // the hub's week is after its start and up to its end: a mark on the boundary is the earlier week's
        #expect(kpi.marks(in: kpi.weeks[0]).map(\.words) == ["Level changed by Support Lead", "Check changed"])
        #expect(kpi.marks(in: kpi.weeks[1]).map(\.words) == ["Model changed"])
        #expect(kpi.marks(in: kpi.weeks[2]).isEmpty)
    }

    @Test func aReadingOfAnotherGenerationOrAgentIsNone() async throws {
        let good = try JSONSerialization.data(withJSONObject: ["db": "db", "agent": "support", "kpis": [kpi(1)]] as [String: Any])
        let hub = try OneAnswer(status: "200 OK") { _ in String(decoding: good, as: UTF8.self) }
        let list = try await HubClient().kpis(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                               agent: "support")
        #expect(list.kpis.map(\.id) == [1])
        #expect(hub.received.starts(with: Data("GET /ui/kpis?db=db&agent=support HTTP/1.1\r\n".utf8)))
        for (db, agent) in [("other", "support"), ("db", "billing")] {
            let body = try JSONSerialization.data(withJSONObject: ["db": db, "agent": agent, "kpis": [kpi(1)]] as [String: Any])
            let wrong = try OneAnswer(status: "200 OK") { _ in String(decoding: body, as: UTF8.self) }
            await #expect(throws: HubError.self) {
                try await HubClient().kpis(hub: URL(string: "http://127.0.0.1:\(wrong.port)")!, database: "db",
                                           agent: "support")
            }
        }
    }

    @Test func theTabIsAWorkersOrALeadsWithAKPIOnAHubThatServesThem() throws {
        // The design's 8.2: never the fleet manager, never with no KPI, never on a hub before KPIs.
        let on = ["kpis", "profiles"]
        #expect(AgentKPIs.tabShown(role: "worker", features: on, count: 2))
        #expect(AgentKPIs.tabShown(role: "lead", features: on, count: 1))
        #expect(!AgentKPIs.tabShown(role: "manager", features: on, count: 3))
        #expect(!AgentKPIs.tabShown(role: "worker", features: on, count: 0))
        #expect(!AgentKPIs.tabShown(role: "worker", features: on, count: nil))
        #expect(!AgentKPIs.tabShown(role: "worker", features: ["profiles"], count: 2))
        // and the snapshot's count reaches the agent's row (owner API 1.275); a hub before it sends none
        let agents: [[String: Any]] = [["name": "support", "role": "worker", "runtime": "codex", "can": [], "kpis": 2],
                                       ["name": "manager", "role": "manager", "runtime": "codex", "can": []]]
        let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "db", "time": Self.start, "agents": agents, "tasks": [], "holds": [],
            "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []] as [String: Any]))
        #expect(state.agents.map(\.kpis) == [2, nil])
    }
}
