#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// The four steps and the minutes that an install shows under its moving title (the owner's yes of 4 November 2026
/// to "Steps and minutes"), read from the steps of the real plans, and the line of what runs now under the first run's
/// title (his yes of 5 November 2026).
struct InstallPhasesTests {
    private func steps(_ ids: [String], done: Int, failed: Bool = false, lines: [String] = []) -> [InstallProgress] {
        ids.enumerated().map { index, id in
            let state: InstallProgress.State = index < done ? .done : index == done ? (failed ? .failed : .running) : .waiting
            return InstallProgress(step: id, title: id, says: "", state: state, lines: index == done ? lines : [])
        }
    }

    private let hub = InstallPlan.hub(target: InstallTarget(host: "server"), source: "", authKey: nil).steps.map(\.id)
    private let join = InstallPlan.join(target: InstallTarget(host: "server"), line: "", code: "", authKey: nil).steps.map(\.id)

    @Test func thePlansAreTheOnesTheMinutesWereMeasuredOn() {
        #expect(hub == ["read", "network", "code", "plan", "start", "wait_claim", "claim", "wait_ready", "verify"])
        #expect(join == ["read", "network", "join", "verify"])
        #expect(Set(hub + join).isSubset(of: Set(InstallPhases.seconds.keys)))
    }

    @Test func aHubsInstallMovesThroughTheFourStepsInOrder() throws {
        #expect(try #require(InstallPhases(steps: steps(hub, done: 0))).current == 0)
        #expect(try #require(InstallPhases(steps: steps(hub, done: 1))).current == 1)
        #expect(try #require(InstallPhases(steps: steps(hub, done: 2))).current == 2)
        #expect(try #require(InstallPhases(steps: steps(hub, done: 7))).current == 2)
        #expect(try #require(InstallPhases(steps: steps(hub, done: 8))).current == 3)
        #expect(try #require(InstallPhases(steps: steps(hub, done: 9))).current == InstallPhases.names.count)
    }

    /// The proof run of 5 November 2026: about 14 minutes from the server on the network to the hub's first answer,
    /// most of it the wait for the installer's own end. The old table said 8 at the start and 1 for the last 11.
    @Test func theMinutesFollowTheMeasuredSteps() throws {
        #expect(try #require(InstallPhases(steps: steps(hub, done: 0))).minutesLeft == 15, "850 seconds, rounded up")
        let waiting = try #require(InstallPhases(steps: steps(hub, done: 7)))
        #expect(waiting.minutesLeft == 13, "the wait for the installer's end, then its checks: 725 seconds")
        #expect(try #require(InstallPhases(steps: steps(join, done: 0))).minutesLeft == 10)
    }

    /// The second proof run of 5 November 2026: the installer reports a step only when it starts, so at "start" the
    /// four steps after it were not in the list, and the first run said "About 1 min" with twelve minutes to go.
    @Test func theStepsNotReportedYetCountFromThePlan() throws {
        let reported = Array(steps(hub, done: 4).prefix(5))
        #expect(try #require(InstallPhases(steps: reported)).minutesLeft == 1)
        let planned = try #require(InstallPhases(steps: reported, planned: hub))
        #expect(planned.minutesLeft == 13, "770 seconds: start, wait_claim, claim, wait_ready and verify")
        #expect(planned.current == 2 && planned.status == "Starting your hub")
        // Before the private network step is reported, the plan places the steps.
        let first = Array(steps(hub, done: 0).prefix(1))
        #expect(InstallPhases(steps: first) == nil)
        #expect(try #require(InstallPhases(steps: first, planned: hub)).current == 0)
        #expect(try #require(InstallPhases(steps: first, planned: hub)).minutesLeft == 15)
        // A join counts its own plan.
        #expect(try #require(InstallPhases(steps: Array(steps(join, done: 1).prefix(2)), planned: join)).minutesLeft == 9)
    }

    @Test func theMinutesGoDownWithinALongStepAndStandAtItsLastHalfMinute() throws {
        let start = try #require(InstallPhases(steps: steps(hub, done: 7), runningFor: 0))
        let later = try #require(InstallPhases(steps: steps(hub, done: 7), runningFor: 600))
        let late = try #require(InstallPhases(steps: steps(hub, done: 7), runningFor: 5000))
        #expect(start.minutesLeft == 13)
        #expect(later.minutesLeft == 3, "725 - 600 = 125 seconds")
        #expect(late.minutesLeft == 2, "its last 30 seconds and the checks' 75")
        // A time that is not one moves nothing.
        #expect(try #require(InstallPhases(steps: steps(hub, done: 7), runningFor: -40)).minutesLeft == 13)
    }

    @Test func theLineSaysWhatRunsNowInTheOrderTheFirstRunMeetsIt() throws {
        func status(_ done: Int, _ lines: [String] = []) throws -> String? {
            try #require(InstallPhases(steps: steps(hub, done: done, lines: lines))).status
        }
        #expect(try status(0) == "Starting your server")
        #expect(try status(1) == "Joining your private network")
        #expect(try status(2) == "Copying the Founderizer code")
        #expect(try status(4) == "Starting your hub")
        #expect(try status(6) == "Linking your hub to this Mac")
        #expect(try status(7) == "Starting your hub")
        #expect(try status(7, ["Founderizer step 12: the checks the owner can act on"]) == "Starting your hub")
        #expect(try status(7, ["Founderizer step 14: security updates"]) == "Installing security updates")
        #expect(try status(7, ["Founderizer step 15: verify: is this machine of the fleet healthy?"]) == "Checking your hub")
        #expect(try status(8) == "Checking your hub")
        #expect(try status(9) == nil)
        #expect(try #require(InstallPhases(steps: steps(join, done: 2))).status == nil, "a server's join has no line")
    }

    @Test func theInstallersOwnStepIsReadFromItsLog() {
        #expect(InstallPhases.installerStep("Founderizer step 14: security updates") == "security updates")
        #expect(InstallPhases.installerStep("Founderizer:   this machine of the fleet is healthy") == nil)
        #expect(InstallPhases.installerStep("x Founderizer step 3: the user fleet") == nil)
        #expect(InstallPhases.installerStep("Founderizer step 3: ") == nil)
    }

    @Test func aStepThatALaterPlanAddsLandsByItsPlace() throws {
        let made = ["create", "read", "network", "keys", "join", "verify"]
        #expect(try #require(InstallPhases(steps: steps(made, done: 1))).current == 0)
        #expect(try #require(InstallPhases(steps: steps(made, done: 3))).current == 2)
    }

    @Test func anInstallWithNoPrivateNetworkStepShowsNoSteps() {
        #expect(InstallPhases(steps: steps(["mark", "restart", "back", "verify"], done: 1)) == nil)
        #expect(InstallPhases(steps: []) == nil)
    }
}
#endif
