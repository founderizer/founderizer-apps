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

    /// **The share of each of the four steps that is done** (the bar under a server on the first run's build page, slice
    /// 3 of the one wizard): the units that ended, never the time (F4 of 22 November 2026, piece 3). A part that the
    /// clock filled read full while its step still ran; the same steps must give the same bar at each moment, and each
    /// heading of the hub's installer must add its share without ever filling the part before its step ends.
    @Test func eachOfTheFourStepsSaysHowMuchOfItIsDone() throws {
        func parts(_ ids: [String], done: Int, lines: [String] = [], at time: TimeInterval = 0) throws -> [Double] {
            try #require(InstallPhases(steps: steps(ids, done: done, lines: lines), planned: ids, runningFor: time)).parts
        }
        // "read" ran four times its 15 seconds: it has not ended, so the VPS part is empty.
        #expect(try parts(hub, done: 0) == [0, 0, 0, 0] && parts(hub, done: 0, at: 60) == [0, 0, 0, 0])
        // In the wait for the installer's end: Install has code, plan, start, wait_claim, claim and wait_ready with the
        // installer's 19 headings, 25 units, and 5 of them ended, at the wait's start and five minutes into it.
        #expect(InstallPhases.installerHeadings["wait_ready"] == 19)
        #expect(try parts(hub, done: 7) == [1, 1, 0.2, 0] && parts(hub, done: 7, at: 300) == [1, 1, 0.2, 0])
        // Each heading adds its share: the 13 before "Founderizer step 14" have ended, the 14th runs.
        let updates = try parts(hub, done: 7, lines: ["Founderizer step 14: security updates"], at: 300)
        let hardening = try parts(hub, done: 7, lines: ["Founderizer step 15: this server's own hardening"], at: 10)
        #expect(updates == [1, 1, 0.72, 0] && hardening == [1, 1, 0.76, 0])
        // A heading past the count, or any heading, never fills the part while its step runs.
        #expect(try parts(hub, done: 7, lines: ["Founderizer step 99: a new part"]) == [1, 1, 0.96, 0])
        #expect(try parts(hub, done: 7, lines: ["apt says something"]) == [1, 1, 0.2, 0])
        #expect(try parts(hub, done: 8) == [1, 1, 1, 0] && parts(hub, done: 9) == [1, 1, 1, 1])
        // A join: read, network, join, verify. Its step has no heading that the app counts, so a heading holds the
        // part where it stood, at three minutes as past its estimate.
        #expect(try parts(join, done: 2, at: 180) == [1, 1, 0, 0] && parts(join, done: 2, at: 5000) == [1, 1, 0, 0])
        #expect(try parts(join, done: 2, lines: ["Founderizer step 3: base packages"], at: 180) == [1, 1, 0, 0])
    }

    /// **A retry of the app never sends the bar back** (F4 of 22 November 2026, piece 3; the rule of
    /// `AgentSetupFlow.barPart`): a try that stopped for an error that passes runs again from its first step, and the
    /// bar of the build page fell from the security updates to an empty bar while the line said "Starting your server".
    /// The bar keeps where the press reached; the line and the minutes say the step that runs now; a new press starts
    /// again from nothing.
    @Test func aRetryOfTheAppNeverSendsTheBarBack() throws {
        var hold = InstallHold()
        let heading = ["Founderizer step 14: security updates"]
        let updates = try #require(InstallPhases(steps: steps(hub, done: 7, lines: heading), planned: hub))
        hold.keep(updates)
        // The retry: no step yet, then its first step runs again.
        let none = try #require(InstallPhases(steps: [], planned: hub))
        let read = try #require(InstallPhases(steps: steps(hub, done: 0), planned: hub))
        hold.keep(none)
        hold.keep(read)
        for now in [none, read] {
            let shown = hold.applied(to: now)
            #expect(shown.parts == [1, 1, 0.72, 0] && shown.current == 2, "\(now.step ?? "-")")
            #expect(shown.status == now.status && shown.minutesLeft == now.minutesLeft && shown.step == now.step)
        }
        // A part that the retry passes goes on from there.
        let further = try #require(InstallPhases(steps: steps(hub, done: 8), planned: hub))
        hold.keep(further)
        #expect(hold.applied(to: further).parts == [1, 1, 1, 0] && hold.applied(to: further).current == 3)
        // A new press starts its bar again.
        #expect(InstallHold().applied(to: read) == read && read.parts == [0, 0, 0, 0])
    }

    /// **Each heading of the installers has its line, and the count of the hub's is the script's** (F4 pieces 3 and 4):
    /// `hub.sh` has one `heading` line for each part of its install. A part that it gains without a row here says the
    /// step's own line ("Starting your hub" after the updates) and leaves the build page's bar short of its last parts;
    /// one that it loses leaves the bar waiting for parts that never come. `join.sh`'s headings (F4 piece 1) each need
    /// a row of the join's table. The public copy of the apps has no installer, and skips the test.
    @Test(.enabled(if: InstallCauseTests.repositoryHasAHubFile)) func theHubsHeadingsAreTheOnesItsInstallerPrints() throws {
        func headings(_ file: String) throws -> [String] {
            let script = try String(contentsOf: InstallCauseTests.repository.appendingPathComponent(file), encoding: .utf8)
            return try InstallCauseTests.captures(#"(?m)^\s+heading "([^"]*)""#, in: script)
        }
        func rows(_ words: String, _ table: [(words: String, line: InstallPhases.HeadingLine)]) -> Int {
            table.filter { words.lowercased().hasPrefix($0.words.lowercased()) }.count
        }
        let hub = try headings("hub.sh")
        #expect(hub.count == InstallPhases.installerHeadings["wait_ready"], "\(hub)")
        #expect(hub.count == InstallPhases.hubHeadings.count)
        for words in hub { #expect(rows(words, InstallPhases.hubHeadings) == 1, "hub.sh: \(words)") }
        for words in try headings("join.sh") { #expect(rows(words, InstallPhases.joinHeadings) == 1, "join.sh: \(words)") }
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
        // 495 seconds: the join runs no checks of its own since 20 November 2026 (FLEET_VERIFY=caller), a minute less
        #expect(try #require(InstallPhases(steps: steps(join, done: 0))).minutesLeft == 9)
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
        #expect(try #require(InstallPhases(steps: Array(steps(join, done: 1).prefix(2)), planned: join)).minutesLeft == 8)
    }

    /// **The minutes show only while they are true** (F4 of 22 November 2026, piece 2): they go down within a long
    /// step and stand at its last half minute; once the step has run longer than its estimate, no count is true. A join
    /// of 14 minutes said "About 2 min" from its sixth minute to its end.
    @Test func theMinutesGoDownWithinALongStepAndGoOnceItPassesItsEstimate() throws {
        func minutes(_ ids: [String], done: Int, at time: TimeInterval) throws -> Int? {
            try #require(InstallPhases(steps: steps(ids, done: done), runningFor: time)).minutesLeft
        }
        #expect(try minutes(hub, done: 7, at: 0) == 13)
        #expect(try minutes(hub, done: 7, at: 600) == 3, "725 - 600 = 125 seconds")
        #expect(try minutes(hub, done: 7, at: 650) == 2, "its estimate: its last 30 seconds and the checks' 75")
        #expect(try minutes(hub, done: 7, at: 651) == nil && minutes(hub, done: 7, at: 5000) == nil)
        #expect(try minutes(join, done: 2, at: 360) == 2 && minutes(join, done: 2, at: 361) == nil)
        // A time that is not one moves nothing.
        #expect(try minutes(hub, done: 7, at: -40) == 13)
    }

    /// **A wait that this Mac cannot reach shows no minutes** (F4 piece 5, the picture P4): the step's line and its bar
    /// stay, and its page says that this Mac cannot reach the server now. A count of minutes went on going down while
    /// no read reached the server.
    @Test func aWaitThatThisMacCannotReachShowsNoMinutes() throws {
        var reported = steps(hub, done: 7)
        reported[7] = InstallProgress(step: "wait_ready", title: "wait_ready", says: "", state: .running,
                                      lines: ["Founderizer step 16: security updates"], unreachable: true)
        let unreached = try #require(InstallPhases(steps: reported, planned: hub, runningFor: 60))
        #expect(unreached.unreachable && unreached.minutesLeft == nil)
        #expect(unreached.status == "Installing security updates" && unreached.parts == [1, 1, 0.8, 0])
        reported[7] = InstallProgress(step: "wait_ready", title: "wait_ready", says: "", state: .running,
                                      lines: ["Founderizer step 16: security updates"])
        let reached = try #require(InstallPhases(steps: reported, planned: hub, runningFor: 60))
        #expect(!reached.unreachable && reached.minutesLeft == 12 && reached.parts == unreached.parts)
    }

    /// **One table of lines for each server setup page** (F4 of 22 November 2026, piece 4; the owner's "Yes, as drawn"
    /// to the pictures P2 and P7): each plan step and each heading of the installer gives the app's own phrase, in the
    /// order that the install meets them. A hub's hardening after its security updates said "Starting your hub" again,
    /// and a join said "Installing security updates" for its whole step.
    @Test func theLineSaysWhatRunsNowInTheOrderTheFirstRunMeetsIt() throws {
        func status(_ done: Int, _ lines: [String] = [], _ plan: [String]? = nil) throws -> String? {
            try #require(InstallPhases(steps: steps(plan ?? hub, done: done, lines: lines))).status
        }
        #expect(try status(0) == "Starting your server")
        #expect(try status(1) == "Joining your private network")
        #expect(try status(2) == "Copying the Founderizer code")
        #expect(try status(4) == "Starting your hub")
        #expect(try status(5, ["Founderizer step 5: the firewall: the private network only"]) == "Starting your hub")
        #expect(try status(6) == "Linking your hub to this Mac")
        #expect(try status(7) == "Starting your hub")
        #expect(try status(7, ["Founderizer step 13: the checks the owner can act on"]) == "Starting your hub")
        #expect(try status(7, ["Founderizer step 16: security updates"]) == "Installing security updates")
        #expect(try status(7, ["Founderizer step 17: this server's own hardening"]) == "Securing your server")
        #expect(try status(7, ["Founderizer step 18: the network: a kept connection keeps its speed"]) == "Securing your server")
        #expect(try status(7, ["Founderizer step 19: verify: is this machine of the fleet healthy?"]) == "Checking your hub")
        #expect(try status(8) == "Checking your hub")
        #expect(try status(9) == nil)
        // A join: its long step installs Founderizer until its installer says more, then each group of its headings.
        #expect(try status(2, [], join) == "Installing Founderizer")
        #expect(try status(2, ["Founderizer step 1: base packages"], join) == "Installing Founderizer")
        #expect(try status(2, ["Founderizer step 5: the firewall: the private network only"], join) == "Securing your server")
        #expect(try status(2, ["Founderizer step 7: security updates"], join) == "Installing security updates")
        #expect(try status(2, ["Founderizer step 9: one OS user for each agent of this machine"], join)
                == "Preparing your server for agents")
        #expect(try status(3, [], join) == "Checking your server")
        // A heading that the table does not have: the step's own line, with no line before it (`InstallHold` holds one).
        #expect(try status(7, ["Founderizer step 20: a part of a newer installer"]) == "Starting your hub")
        #expect(try status(2, ["Founderizer step 4: the join to the hub"], join) == "Installing Founderizer")
    }

    /// **A heading that the table does not have holds the line where it stood** (F4 piece 4: the line never goes back
    /// inside one step): a newer installer than this app, with a part after the hardening, said "Starting your hub".
    @Test func aHeadingThatTheTableDoesNotHaveHoldsTheLine() throws {
        var hold = InstallHold()
        let hardening = try #require(InstallPhases(steps: steps(hub, done: 7, lines: [
            "Founderizer step 17: this server's own hardening"]), planned: hub))
        hold.keep(hardening)
        let newer = try #require(InstallPhases(steps: steps(hub, done: 7, lines: [
            "Founderizer step 18: a part of a newer installer"]), planned: hub))
        hold.keep(newer)
        #expect(hold.applied(to: newer).status == "Securing your server")
        // A known heading after it says its own line again, and the next step has its own.
        let verify = try #require(InstallPhases(steps: steps(hub, done: 7, lines: [
            "Founderizer step 19: verify: is this machine of the fleet healthy?"]), planned: hub))
        hold.keep(verify)
        #expect(hold.applied(to: verify).status == "Checking your hub")
        let checks = try #require(InstallPhases(steps: steps(hub, done: 8), planned: hub))
        #expect(hold.applied(to: checks).status == "Checking your hub")
        // The same unknown heading in a press with no line before it: the step's own line.
        #expect(InstallHold().applied(to: newer).status == "Starting your hub")
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
