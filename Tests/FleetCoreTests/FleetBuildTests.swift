#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// **One server's line on the first run's build page** (`FleetBuildRow`, slice 3 of the one wizard): the words, the
/// minutes and the four parts of the bar, from the provider's build, the wait for the hub, each install's steps, the
/// move and the sign-in, with the real plans' steps and the measured seconds of `InstallPhases`.
struct FleetBuildTests {
    private let hub = InstallPlan.hub(target: InstallTarget(host: "server"), source: "", authKey: nil).steps.map(\.id)
    private let join = InstallPlan.join(target: InstallTarget(host: "server"), line: "", code: "", authKey: nil).steps.map(\.id)

    private func steps(_ ids: [String], done: Int) -> [InstallProgress] {
        ids.enumerated().map { index, id in
            InstallProgress(step: id, title: id, says: "", state: index < done ? .done : index == done ? .running : .waiting)
        }
    }

    /// The provider's build: 75 seconds before the install's 850 make 16 minutes; a server that starts has 30 seconds
    /// before a join's 495, 9 minutes (the join's own step is 360 seconds since its checks run once, 21 November 2026).
    @Test func aServerThatItsProviderMakesHasTheBuildsWordsAndMinutes() {
        let making = FleetBuildRow.building(joining: false, plan: hub)
        #expect(making.words == "Making your server" && making.minutes == 16 && making.parts == [0.2, 0, 0, 0])
        #expect(!making.ownersTurn)
        let starting = FleetBuildRow.building(joining: true, plan: join)
        #expect(starting.words == "Starting your server" && starting.minutes == 9 && starting.parts == [0.6, 0, 0, 0])
    }

    @Test func theManagersServerWaitsForTheHubWithItsJoinsMinutes() {
        let row = FleetBuildRow.waitsForHub(plan: join)
        #expect(row.words == "Waiting for your hub" && row.minutes == 9 && row.parts == [0.6, 0, 0, 0] && !row.ownersTurn)
    }

    /// A join says what its long step does and checks the server by its agent's name; the hub's own install keeps the
    /// hub's words; an install that ended has no words and no minutes.
    @Test func eachInstallSaysWhatRunsWithItsMinutesAndParts() throws {
        let updates = FleetBuildRow.installing(try #require(InstallPhases(steps: steps(join, done: 2), planned: join,
                                                                          runningFor: 180)), joinFor: "Juno")
        #expect(updates.words == "Installing security updates" && updates.parts == [1, 1, 0.5, 0] && updates.minutes == 5)
        let checks = FleetBuildRow.installing(try #require(InstallPhases(steps: steps(join, done: 3), planned: join)),
                                              joinFor: "Juno")
        #expect(checks.words == "Checking Juno's server" && checks.minutes == 2)
        let network = FleetBuildRow.installing(try #require(InstallPhases(steps: steps(join, done: 1), planned: join)),
                                               joinFor: "Juno")
        #expect(network.words == "Joining your private network")
        let hubChecks = FleetBuildRow.installing(try #require(InstallPhases(steps: steps(hub, done: 8), planned: hub)))
        #expect(hubChecks.words == "Checking your hub" && hubChecks.minutes == 2)
        let ended = FleetBuildRow.installing(try #require(InstallPhases(steps: steps(hub, done: 9), planned: hub)))
        #expect(ended.words == nil && ended.minutes == nil && ended.parts == [1, 1, 1, 1])
    }

    /// **The bar never goes back** (the review of 17 November 2026): after the provider's build, whose first part stood
    /// at 0.6, the install's first step fills the rest of that part; a server that no provider made in this run starts
    /// the part at 0.
    @Test func anInstallAfterTheProvidersBuildGoesOnFromItsFirstPart() throws {
        let start = try #require(InstallPhases(steps: steps(hub, done: 0), planned: hub))
        #expect(FleetBuildRow.installing(start, afterBuild: true).parts?.first == FleetBuildRow.startShare)
        #expect(FleetBuildRow.installing(start).parts?.first == 0)
        let read = try #require(InstallPhases(steps: steps(hub, done: 1), planned: hub))
        #expect(FleetBuildRow.installing(read, afterBuild: true).parts?.first == 1)
        #expect(FleetBuildRow.building(joining: true, plan: hub).parts?.first == FleetBuildRow.startShare)
        // The wait for the hub and an install with no step yet stand where the next row begins.
        #expect(FleetBuildRow.waitsForHub(plan: join).parts?.first == FleetBuildRow.startShare)
        #expect(FleetBuildRow.starting(plan: hub, afterBuild: true).parts?.first == FleetBuildRow.startShare)
        #expect(FleetBuildRow.starting(plan: hub, afterBuild: false).parts == [0, 0, 0, 0])
        #expect(FleetBuildRow.starting(plan: hub, afterBuild: false).words == "Starting your server")
    }

    @Test func theSignInIsTheOwnersTurnAndAReadyServerShowsNothing() {
        let signIn = FleetBuildRow.signIn
        #expect(signIn.words == "Waiting for your sign-in" && signIn.ownersTurn && signIn.minutes == nil)
        #expect(FleetBuildRow.ready.words == nil && FleetBuildRow.ready.parts == nil && FleetBuildRow.ready.minutes == nil)
        #expect(FleetBuildRow.settingUp("Claude Code").words == "Installing Claude Code")
    }
}
#endif
