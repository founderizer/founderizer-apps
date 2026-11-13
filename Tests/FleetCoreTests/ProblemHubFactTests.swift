import Foundation
import Testing
@testable import FleetCore

/// The "Hub" fact of Report a problem: the release that the hub runs, with its commit in the published repository,
/// which support can find; the hub's own configuration commit only where no release is known.
struct ProblemHubFactTests {
    private func releases() throws -> ReleaseState {
        let url = try #require(Bundle.module.url(forResource: "releases", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ReleaseState.self, from: try Data(contentsOf: url))
    }

    @Test func theFactIsTheReleaseThatTheHubRunsWithItsPublicCommit() throws {
        let state = try releases()
        let value = ProblemReport.hubRelease(state, revision: state.revision)
        #expect(value == "2026.10.1 (aaaaaaaaaaaa)")       // the release a run reached, not the newest one offered
        let facts = ProblemReport.facts(app: "2026.11.1", system: "15.3.0", fleet: nil, hub: value, screen: "Task",
                                        trouble: nil)
        #expect(facts.first { $0.name == "Hub" }?.value == "2026.10.1 (aaaaaaaaaaaa)")     // whole, not cut
        #expect(facts.map(\.name) == ["Founderizer", "macOS", "Fleet", "Hub", "Screen"])
    }

    @Test func withNoReleaseKnownTheFactIsTheHubsOwnRevisionCutAsBefore() {
        let revision = "1f43dab42994b95bf1f7458f683c5b0dd0bb0153"
        let value = ProblemReport.hubRelease(nil, revision: revision)
        #expect(value == revision)
        let facts = ProblemReport.facts(app: "2026.11.1", system: "15.3.0", fleet: nil, hub: value, screen: "Task",
                                        trouble: nil)
        #expect(facts.first { $0.name == "Hub" }?.value == "1f43dab42994")
        #expect(ProblemReport.hubRelease(nil, revision: nil) == nil)
    }
}
