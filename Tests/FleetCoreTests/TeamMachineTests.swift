import Foundation
import Testing
@testable import FleetCore

/// The machines of `GET /ui/team` as the app reads them (the OS user of each machine's agents), and the names that the
/// app sends for an agent and a machine. Synthetic data only: no hub, no installer run, no machine.
struct TeamMachineTests {
    private func team(_ machines: Any?) throws -> TeamSnapshot {
        var object: [String: Any] = [
            "db": "db", "revision": String(repeating: "b", count: 40), "sha256": String(repeating: "a", count: 64), "open_tasks": [:],
            "lines": [["agent": "manager", "role": "manager", "reports_to": NSNull()], ["agent": "studio", "role": "worker", "reports_to": "manager"]]]
        if let machines { object["machines"] = machines }
        let snapshot = try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        try snapshot.validate(database: "db")
        return snapshot
    }

    @Test func theTeamCarriesTheWorkerUserOfEachMachineAndAnUnreadableEntryNeverHidesTheTeam() throws {
        #expect(try team(nil).machines == nil)                                        // a hub before 1.12
        // The hub's whole entry (owner API 1.12): the app reads its worker user, and the rest of it changes nothing.
        let worker4: [String: Any] = [
            "address": "100.96.1.50", "agents": ["worker4"], "ssh": ["user": "root", "port": 22], "worker_user": "fleet",
            "runtimes": ["codex": ["version": "codex-cli 0.160.0", "signed_in": true]],
            "add_agent": ["ready": false, "missing": ["shared_os_user"]]]
        let machines = try team(["worker4": worker4, "studio": ["agents": ["studio"]]]).machines
        #expect(machines == ["worker4": TeamMachine(worker_user: "fleet"), "studio": TeamMachine(worker_user: nil)])
        let broken = try team(["worker4": ["worker_user": 4]])
        #expect(broken.machines == nil && broken.lines.count == 2)
    }

    @Test func theNamesThatTheAppSendsAreTheOnesTheHubTakes() {
        func agent(_ name: String) -> Bool { name.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil }
        func machine(_ name: String) -> Bool { name.range(of: AgentPlacement.machinePattern, options: .regularExpression) != nil }
        for name in ["seo", "worker4", "dev-lead", String(repeating: "a", count: 31)] { #expect(agent(name), "\(name)") }
        for name in ["s", "SEO", "seo_1", "1seo", "-seo", "../seo", String(repeating: "a", count: 32)] { #expect(!agent(name), "\(name)") }
        for name in ["worker4", "mac-studio", "app-1.example", "A1_b"] { #expect(machine(name), "\(name)") }
        for name in ["", "-oProxyCommand=id", "mac studio", "../x", ".x", String(repeating: "a", count: 65)] { #expect(!machine(name), "\(name)") }
    }
}
