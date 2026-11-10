import Foundation
import Testing
@testable import FleetCore

/// **The one word a server's page says, and the things the owner has to do about it.**
///
/// His words, 20 October 2026: "still too complex! what is even a check?! I only care about connected or not
/// connected, and if I need to do something! I dont care about internal commands." So the state of this page is
/// the hub's own live answer about the machine — `MachineConnection`, which costs no SSH, no command on his
/// machine and no button — and under it only the rows he can act on: the restart it is waiting for, the helper
/// the hub will not update, the sign-in it still owes, and what a closer look he asked for himself found.
///
/// The three things these tests now hold against coming back: the page never says "Checks", it never reports
/// that nobody has pressed a button, and a closer look nobody asked for never reaches the face.
///
/// From 19 October 2026 they also hold the two actions no other screen offers — the restart of a machine, and the
/// update of a helper the hub refuses ("the hub machine is maintained from the owner Mac") — and the sign-in line,
/// which goes stale against the machine's own reading instead of staying on the screen for ever.
struct ServerStandingTests {
    private func server(_ fields: String = "{}", name: String = "hub", kind: String = "linux",
                        reportedAt: Double = 1000, agents: [String] = ["manager"]) throws -> ServerEntry {
        let security = fields == "{}" ? "null" : fields
        let here = agents.map { "\"\($0)\"" }.joined(separator: ", ")
        let said = kind == "none" ? "null" : "\"\(kind)\""        // "none": a kind no reading has said yet
        return try JSONDecoder().decode(ServerEntry.self, from: Data("""
        {"name": "\(name)", "kind": \(said), "address": "100.96.10.20", "user": "fleet", "hub": true,
         "joined": false, "agents": [\(here)], "available": false, "why": [], "job": null,
         "reading": {"source": "server", "revision": "abc", "current": true, "os": {"name": "Ubuntu 24.04", "kernel": "6.8"},
                     "security": \(security), "runtimes": {}, "user": "fleet", "reported_at": \(reportedAt),
                     "stale": false}}
        """.utf8))
    }

    private let needsRestart = #"{"unattended_upgrades": true, "pending_security": 3, "reboot_required": true,"#
        + #" "firewall": "on", "tailscale": true}"#

    private func checks(_ answers: [VerifyCheck], at: Double = 900) -> VerifyChecklist {
        VerifyChecklist(checks: answers, readAt: at)
    }

    /// The hub's own line about each helper of a machine, as `/ui/health` serves it.
    private func helpers(_ agents: [String] = ["manager"], offline: Bool = false,
                         lastSeen: Double? = 1000) -> [FleetHealth.Helper] {
        agents.map { FleetHealth.Helper(agent: $0, last_seen: lastSeen, offline: offline) }
    }

    /// The hub hears from this machine.
    private func up(_ server: ServerEntry, at: Double = 1000) -> MachineConnection {
        MachineConnection.of(server, helpers: helpers(server.agents), time: at, fresh: true)
    }

    // MARK: the one word

    /// **The hub's own server answers through the hub** (4 November 2026): with no agent and no server service it said
    /// "Not answering" on Servers while the hub, which runs there, answered and measured it. Another server with
    /// neither has still never reported.
    @Test func theHubsOwnServerIsConnectedWhileTheHubAnswers() throws {
        let data = #"{"name": "%@", "kind": "linux", "address": "100.96.10.20", "user": null, "hub": %@, "joined": %@, "agents": [], "available": false, "why": [], "job": null, "reading": null}"#
        let hub = try JSONDecoder().decode(ServerEntry.self, from: Data(String(format: data, "worker-2", "true", "false").utf8))
        let other = try JSONDecoder().decode(ServerEntry.self, from: Data(String(format: data, "spare", "false", "false").utf8))
        // A hub server that joined has a service of its own: while it has sent nothing, that is news.
        let joined = try JSONDecoder().decode(ServerEntry.self, from: Data(String(format: data, "worker-2", "true", "true").utf8))
        #expect(MachineConnection.of(joined, helpers: [], time: 1000, fresh: true) == .notConnected(says: nil))
        #expect(MachineConnection.of(hub, helpers: [], time: 1000, fresh: true) == .connected(lastSeen: 1000))
        #expect(Servers.state(hub, helpers: [], time: 1000, fresh: true).words == "Connected")
        #expect(MachineConnection.of(other, helpers: [], time: 1000, fresh: true) == .notConnected(says: nil))
        // While this Mac does not hear the hub, nothing is known about its server either.
        #expect(MachineConnection.of(hub, helpers: [], time: 1000, fresh: false) == .unknown)
    }

    @Test func theHubsOwnAnswerIsTheStateAndNeedsNoSSHAndNoButton() throws {
        let hub = try server()
        let standing = ServerStanding.of(hub, connected: up(hub), now: 1000)
        #expect(standing.words == "Connected")
        #expect(standing.says == "Founderizer on hub reported just now.")
        #expect(!standing.attention && !standing.working)
        // A machine that is connected gets no button of its own: that is the whole of what he asked for.
        #expect(standing.settled)
        #expect(standing.symbol == "checkmark.circle.fill")
        // And it says it without a closer look ever having been taken.
        #expect(standing.failing.isEmpty)
    }

    @Test func aMachineTheHubDoesNotHearFromSaysSoInTheHubsOwnWords() throws {
        let hub = try server()
        let quiet = MachineConnection.of(hub, helpers: helpers(offline: true),
                                         warnings: [FleetHealth.Warning(kind: "helper_offline",
                                                                        detail: "Manager has not checked in for 22 minutes.",
                                                                        agent: "manager")],
                                         time: 1000, fresh: true)
        let standing = ServerStanding.of(hub, connected: quiet, now: 1000)
        #expect(standing.words == "Not answering")
        #expect(standing.says == "Manager has not checked in for 22 minutes.")
        #expect(standing.attention && !standing.settled)
        // With no line of the hub's own, the page says the fact in its own words rather than nothing.
        let bare = MachineConnection.of(hub, helpers: helpers(offline: true), time: 1000, fresh: true)
        #expect(ServerStanding.of(hub, connected: bare, now: 1000).says == "The hub has heard nothing from hub.")
        // A warning about something else is not the reason, and is not read as one.
        let other = MachineConnection.of(hub, helpers: helpers(offline: true),
                                         warnings: [FleetHealth.Warning(kind: "disk_low", detail: "The hub's disk.",
                                                                        agent: "manager")],
                                         time: 1000, fresh: true)
        #expect(ServerStanding.of(hub, connected: other, now: 1000).says == "The hub has heard nothing from hub.")
    }

    /// The second between opening the page and the hub's first answer. A machine that is perfectly well must not
    /// read as "Not connected" in it.
    @Test func thePageWaitsForTheHubsAnswerInsteadOfGuessingAtIt() throws {
        let standing = ServerStanding.of(try server(), connected: .waiting, now: 1000)
        #expect(standing.words == "Reading…")
        #expect(standing.says == "Founderizer is asking the hub about hub.")
        #expect(standing.working && !standing.attention && !standing.settled)
    }

    @Test func anOldReadingOfTheHubSaysItDoesNotKnowAndNeverSaysConnected() throws {
        let hub = try server()
        let stale = MachineConnection.of(hub, helpers: helpers(), time: 1000, fresh: false)
        #expect(stale == .unknown)
        let standing = ServerStanding.of(hub, connected: stale, now: 1000)
        #expect(standing.words == "Not known")
        #expect(standing.says == "Founderizer cannot reach your hub, so it cannot say whether hub is connected.")
        #expect(standing.attention && !standing.settled)
    }

    @Test func aServerWithNoAgentIsAnsweredByItsOwnServiceReading() throws {
        // No helper of its own, so its server service's reading says it. Current: connected.
        let free = try server(name: "vps", reportedAt: 900, agents: [])
        #expect(MachineConnection.of(free, helpers: helpers(), time: 1000, fresh: true) == .connected(lastSeen: 900))
        // Older than the hub calls current: not connected, and the page says so.
        #expect(MachineConnection.of(free, helpers: helpers(), time: 100_000, fresh: true)
                == .notConnected(says: nil))
    }

    /// The closer look is the answer to "why not", and never the way to learn "whether".
    @Test func aCloserLookNobodyAskedForNeverReachesTheFace() throws {
        let hub = try server()
        let broken = checks([VerifyCheck(check: "clock", state: "fail", says: "the clock is 4 minutes out",
                                         fix: "sudo timedatectl set-ntp true")])
        // Remembered from an earlier launch: it is a reading, and it stays behind Details.
        let remembered = ServerStanding.of(hub, connected: up(hub), now: 1000, checklist: broken)
        #expect(remembered.words == "Connected" && !remembered.attention && remembered.settled)
        #expect(remembered.failing.isEmpty)
        // He pressed for it in this session, so what it found is the answer to his own button.
        let asked = ServerStanding.of(hub, connected: up(hub), now: 1000, checklist: broken, lookedNow: true)
        #expect(asked.words == "Connected" && asked.attention && !asked.settled)
        #expect(asked.says == "the clock is 4 minutes out")
        #expect(asked.fix == "sudo timedatectl set-ntp true")
        // Several: the row counts them and each one says its own sentence underneath.
        let two = ServerStanding.of(hub, connected: up(hub), now: 1000, checklist: checks([
            VerifyCheck(check: "services", state: "fail", says: "fleet-hub is not running", fix: "systemctl restart"),
            VerifyCheck(check: "clock", state: "fail", says: "the clock is 4 minutes out", fix: "timedatectl"),
        ]), lookedNow: true)
        #expect(two.says == "Founderizer looked closer and found 2 things to put right.")
        #expect(two.failing.map(\VerifyCheck.check) == ["services", "clock"])
    }

    /// The three sentences the owner called ours and not his. None of them can be said by this page again.
    @Test func thePageNeverSaysChecksNorThatNobodyPressedAButton() throws {
        let hub = try server()
        let said = [ServerStanding.of(hub, connected: up(hub), now: 1000),
                    ServerStanding.of(hub, connected: up(hub), now: 1000, checklist: checks([])),
                    ServerStanding.of(hub, connected: .notConnected(says: nil), now: 1000)]
        for standing in said {
            for line in [standing.words, standing.says, standing.fix ?? ""] {
                #expect(!line.localizedCaseInsensitiveContains("check"))
                #expect(!line.contains("fleet.py"))
                #expect(!line.contains("verify"))
            }
        }
    }

    @Test func whatGoesOnNowOutranksTheWordAndTheWordOutranksNothing() throws {
        let hub = try server(needsRestart)
        let restarting = ServerStanding.of(hub, connected: up(hub), now: 1000,
                                           restarting: "Waiting for hub to come back…")
        #expect(restarting.words == "Restarting" && restarting.working && !restarting.attention)
        #expect(restarting.says == "Waiting for hub to come back…")
        // A restart still owed is a fact of the machine, not of the word: it rides along whatever is on top.
        #expect(restarting.needsRestart)
        let looking = ServerStanding.of(hub, connected: up(hub), now: 1000, looking: true)
        #expect(looking.working && looking.symbol == "clock.arrow.circlepath")
        #expect(looking.says == "Founderizer is looking closer at hub…")
        // A closer look this Mac could not run says so under the word, and never instead of it: whether the
        // machine is connected is the hub's answer, and this Mac failing to reach it does not change that.
        let unreachable = ServerStanding.of(hub, connected: .notConnected(says: "The hub has heard nothing."),
                                            now: 1000, failure: "ssh: no route to host")
        #expect(unreachable.words == "Not answering")
        #expect(unreachable.says == "The hub has heard nothing. ssh: no route to host")
    }

    // MARK: the restart

    @Test func aMachineThatAsksForARestartIsOfferedOne() throws {
        let well = checks([VerifyCheck(check: "services", state: "ok", says: "fleet-hub is active")])
        let asked = try server(needsRestart)
        let standing = ServerStanding.of(asked, connected: up(asked), now: 1000, checklist: well)
        // The word stays the machine's. A restart it is waiting for is a row under it, with its own button and
        // its own reason — which is what "if I need to do something" asked for, and not a second headline.
        #expect(standing.words == "Connected" && standing.needsRestart)
        #expect(ServerStanding.restartSays(3) == "3 security updates are installed and waiting for a restart.")
        // With no checks read at all it is still the thing to say: the hub's own reading says it.
        #expect(ServerStanding.of(asked, connected: up(asked), now: 1000).needsRestart)
        #expect(ServerStanding.restartSays(1) == "1 security update is installed and waiting for a restart.")
        #expect(ServerStanding.restartSays(nil) == "Its system installed security updates that take effect after a restart.")
        #expect(ServerStanding.restartSays(0) == ServerStanding.restartSays(nil))
        // What failed outranks it, and the restart row stays under that headline.
        let alsoBroken = ServerStanding.of(asked, connected: up(asked), now: 1000,
                                           checklist: checks([VerifyCheck(check: "clock", state: "fail", says: "out", fix: "t")]),
                                           lookedNow: true)
        #expect(alsoBroken.words == "Connected" && alsoBroken.attention && alsoBroken.needsRestart)
        #expect(standing.fix == nil)      // nothing failed, so the state names no fix of its own
    }

    @Test func aReadingFromBeforeOurOwnRestartOffersNoSecondOne() throws {
        let before = try server(needsRestart, reportedAt: 1000)
        #expect(ServerStanding.of(before, connected: up(before), now: 1000, restartedAt: 1200).needsRestart == false)
        // Once the machine has reported since, it answers for itself again.
        let after = try server(needsRestart, reportedAt: 1300)
        #expect(ServerStanding.of(after, connected: up(after), now: 1000, restartedAt: 1200).needsRestart)
    }

    @Test func noRestartIsOfferedForAMacOrAMachineThatDidNotAskForOne() throws {
        let mac = try server(needsRestart, kind: "mac")
        #expect(ServerStanding.of(mac, connected: up(mac), now: 1000).needsRestart == false)
        let quiet = #"{"unattended_upgrades": true, "pending_security": 0, "reboot_required": false,"#
            + #" "firewall": "on", "tailscale": true}"#
        let calm = try server(quiet), plain = try server()
        #expect(ServerStanding.of(calm, connected: up(calm), now: 1000).needsRestart == false)
        #expect(ServerStanding.of(plain, connected: up(plain), now: 1000).needsRestart == false)
    }

    @Test func theRestartRunsOnTheMachineAndProvesItCameBack() {
        let plan = InstallPlan.restart(target: InstallTarget(host: "100.96.10.20", user: "root"), machine: .hub)
        #expect(plan.steps.map(\.id) == ["mark", "restart", "back", "verify"])
        // It ends in the checks, so the page says where the machine stands after the restart and not before it.
        guard case .verify(let command) = plan.steps[3].action else { Issue.record("it must end in verify"); return }
        #expect(command == InstallPlan.verifyCommand(.hub))
        // The reboot is detached, or the connection would die before ssh is done with it.
        guard case .detach(let reboot) = plan.steps[1].action else { Issue.record("the reboot must detach"); return }
        #expect(reboot.contains("setsid") && reboot.contains("systemctl reboot") && reboot.hasSuffix("&"))
        // The machine came back only when its own /run is empty: an answer from one that is merely slow to go
        // down must never read as a restart.
        guard case .waitFor(let wait, let mark, _, let within) = plan.steps[2].action else {
            Issue.record("it must wait for the machine"); return
        }
        #expect(mark == InstallPlan.bootedMark)
        #expect(wait.contains("test -f \(InstallPlan.restartMark)") && wait.contains("is-system-running"))
        // It also waits for the clock, which a machine finds a second or two after its units start, but it gives
        // up on that after two minutes: a clock that is really wrong must reach the checks, not stall the wait.
        #expect(wait.contains("NTPSynchronized") && wait.contains("/proc/uptime"))
        #expect(within >= 300)
        #expect(plan.redactions.isEmpty)
    }

    @Test func theRestartGoesThroughTheOwnersOwnConnection() {
        let asRoot = InstallPlan.restart(target: InstallTarget(host: "100.96.10.20", user: "root"), machine: .hub)
        let arguments = asRoot.arguments(for: "systemctl reboot")
        #expect(arguments.contains("BatchMode=yes") && arguments.contains("NumberOfPasswordPrompts=0"))
        #expect(arguments.contains("root@100.96.10.20"))
        #expect(!arguments.contains { $0.contains("sudo") })
        let asUser = InstallPlan.restart(target: InstallTarget(host: "box", user: "fleet", becomeRoot: true),
                                         machine: .linuxWorker)
        #expect(asUser.arguments(for: "systemctl reboot").last?.hasPrefix("sudo -n -i --") == true)
    }

    // MARK: the update of a helper the hub will not take

    /// One agent's machine reading, as the hub serves it: its role, and what its helper's revision says. A lead by
    /// default, because since 19 October 2026 a lead on a hub without the `leads` feature is the one helper the
    /// hub's own update route will not take — the manager on the hub machine goes through it like a worker.
    private func helper(_ agent: String = "scout", role: String = "lead", update: String = "behind",
                        reportedAt: Double = 1000) throws -> MachineStatus {
        try JSONDecoder().decode(MachineStatus.self, from: Data("""
        {"agent": "\(agent)", "machine": "hub", "role": "\(role)", "update": {"state": "\(update)"}, "os": {},
         "security": {}, "runtime": {}, "reported_at": \(reportedAt)}
        """.utf8))
    }

    @Test func onlyAHelperTheHubWillNotUpdateIsOfferedOneHere() throws {
        let hub = try server(agents: ["manager", "scout", "runner"])
        let readings = try [helper("manager", role: "manager"), helper("scout"), helper("runner", role: "worker")]
        // A lead on a hub without the leads feature: the hub's route refuses it, so this Mac is the only way and
        // the row is its own. The manager and the worker update themselves through the hub, which waits for them
        // to be idle, so neither is offered here: two ways to do one thing is what this page exists to remove.
        #expect(hub.behindHelpers(readings, leads: false).map(\.agent) == ["scout"])
        // With the leads feature the hub takes the lead too, and this page has nothing left to offer.
        #expect(hub.behindHelpers(readings, leads: true).isEmpty)
    }

    @Test func aHelperThatRunsTheFleetsOwnRevisionIsOfferedNothing() throws {
        let hub = try server(agents: ["scout"])
        #expect(try hub.behindHelpers([helper(update: "current")], leads: false).isEmpty)
        // A helper already updating through the hub, or one whose revision the hub cannot say, is not behind.
        #expect(try hub.behindHelpers([helper(update: "updating")], leads: false).isEmpty)
        #expect(try hub.behindHelpers([helper(update: "failed")], leads: false).isEmpty)
        // No reading at all: the face says nothing it cannot stand behind.
        #expect(hub.behindHelpers([], leads: false).isEmpty)
        // A reading of an agent that is not on this server belongs to another page.
        #expect(try hub.behindHelpers([helper("worker4")], leads: false).isEmpty)
    }

    @Test func noUpdateIsOfferedForAMacOrAMachineThatSaysNothingAboutItself() throws {
        // A Mac's agents are one Mac user's own LaunchAgents, not the per-agent users and user services this plan
        // drives, so it is left out rather than offered something that cannot work.
        #expect(try server(kind: "mac", agents: ["scout"]).behindHelpers([helper()], leads: false).isEmpty)
        // A machine whose kind no reading says yet is left out for the same reason.
        #expect(try server(kind: "none", agents: ["scout"]).behindHelpers([helper()], leads: false).isEmpty)
    }

    @Test func aReadingFromBeforeOurOwnUpdateOffersNoSecondOne() throws {
        let hub = try server(agents: ["scout"])
        // The helper reports its new revision within a minute; until it has, the hub still says behind, and a page
        // that offered the same update again would read as a button that did nothing.
        #expect(try hub.behindHelpers([helper(reportedAt: 1000)], leads: false, updatedAt: 1200).isEmpty)
        #expect(try hub.behindHelpers([helper(reportedAt: 1300)], leads: false, updatedAt: 1200).map(\.agent) == ["scout"])
    }

    @Test func theStateRowSaysWhyAndTheUpdateRowSaysOnlyWhatItIs() throws {
        let well = checks([VerifyCheck(check: "services", state: "ok", says: "fleet-hub is active")])
        let hub = try server()
        let standing = ServerStanding.of(hub, connected: up(hub), now: 1000, checklist: well, behind: ["manager"])
        // The word stays the machine's: a helper on an old revision is a row under it, with its own button.
        #expect(standing.words == "Connected" && standing.needsUpdate)
        #expect(ServerStanding.updateSays(["manager"]) == "Founderizer on it is behind for Manager.")
        #expect(ServerStanding.updateSays(["manager", "scout"]) == "Founderizer on it is behind for 2 agents.")
        // A machine where nothing is behind says nothing about updates, which is what keeps its page empty.
        let calm = ServerStanding.of(hub, connected: up(hub), now: 1000, checklist: well)
        #expect(calm.words == "Connected" && !calm.needsUpdate && calm.settled)
    }

    @Test func theUpdateTakesItsTurnAfterEverythingMorePressing() throws {
        let broken = checks([VerifyCheck(check: "clock", state: "fail", says: "out", fix: "timedatectl")])
        // What failed outranks it, and a restart still owed outranks it too: the row stays under that headline, as
        // the restart's does, and both facts ride along.
        let asked = try server(needsRestart)
        // A restart owed and a helper behind are both rows under the one word, and both ride along.
        let both = ServerStanding.of(asked, connected: up(asked), now: 1000, behind: ["manager"])
        #expect(both.words == "Connected" && both.needsRestart && both.needsUpdate)
        // An update this Mac is driving is what is going on now, and nothing else is the word while it runs.
        let going = ServerStanding.of(asked, connected: up(asked), now: 1000, checklist: broken,
                                      behind: ["manager"], updating: "Restarting the helper…")
        #expect(going.words == "Updating" && going.working && !going.attention)
        #expect(going.says == "Restarting the helper…" && going.needsUpdate)
        // A restart this Mac is driving still comes first: it is the machine, and an update is one helper on it.
        let restarting = ServerStanding.of(asked, connected: up(asked), now: 1000, restarting: "Waiting for hub…",
                                           behind: ["manager"], updating: "Restarting the helper…")
        #expect(restarting.words == "Restarting")
    }

    @Test func theUpdateDoesWhatTheHelperWouldDoAndEndsInTheChecks() {
        let plan = InstallPlan.update(target: InstallTarget(host: "100.96.10.20", user: "root"), machine: .hub,
                                      agent: "manager")
        #expect(plan.steps.map(\.id) == ["checkout", "move", "service", "verify"])
        // Not the id "read": that one is an install's first step, which the runner reads a machine's own user and
        // system out of.
        #expect(!plan.steps.contains { $0.id == "read" })
        // Every step runs as that agent's own OS user, from its own home and user services: its home is of mode
        // 700, so nothing else reaches its checkout.
        for step in plan.steps.prefix(3) {
            guard case .run(let program) = step.action else { Issue.record("\(step.id) must be one command"); return }
            #expect(program.hasPrefix("runuser -u fleet-manager -- env HOME=/home/fleet-manager "))
            #expect(program.contains("XDG_RUNTIME_DIR=/run/user/$(id -u fleet-manager)"))
        }
        // The first step only reads, and refuses in the fleet's own words a checkout that cannot be moved on.
        guard case .run(let read) = plan.steps[0].action else { Issue.record("the read must be one command"); return }
        #expect(read.contains("git fetch -q origin"))
        #expect(read.contains("git status --porcelain --untracked-files=no"))
        #expect(read.contains("the checkout has its own changes, so it stays where it is"))
        #expect(read.contains("git merge-base --is-ancestor HEAD refs/remotes/origin/config"))
        #expect(!read.contains("git merge -q"))     // nothing moves in the step that decides whether it can
        // Then the fast-forward, and only that, onto the one ref a fleet runs.
        guard case .run(let move) = plan.steps[1].action else { Issue.record("the move must be one command"); return }
        #expect(move.contains("git merge -q --ff-only refs/remotes/origin/config"))
        #expect(move.contains("git rev-parse --short HEAD"))
        // Then the agent's own service, in that user's own systemd manager, which is what loads the new checkout.
        guard case .run(let service) = plan.steps[2].action else { Issue.record("the restart must be one command"); return }
        #expect(service.contains("systemctl --user restart fleet-manager.service"))
        #expect(service.contains("systemctl --user is-active -q fleet-manager.service"))
        #expect(!service.contains("--no-block"))    // this Mac waits for it, and then reads the checks
        // It ends in the checks, so the page says where the machine stands after the update and not before it.
        guard case .verify(let command) = plan.steps[3].action else { Issue.record("it must end in verify"); return }
        #expect(command == InstallPlan.verifyCommand(.hub))
        #expect(plan.redactions.isEmpty)
    }

    @Test func theUpdateGoesThroughTheOwnersOwnConnection() {
        let asRoot = InstallPlan.update(target: InstallTarget(host: "100.96.10.20", user: "root"), machine: .hub,
                                        agent: "manager")
        let arguments = asRoot.arguments(for: "true")
        #expect(arguments.contains("BatchMode=yes") && arguments.contains("NumberOfPasswordPrompts=0"))
        #expect(arguments.contains("root@100.96.10.20"))
        #expect(!arguments.contains { $0.contains("sudo") })
        // A user that is not root becomes root first, because `runuser` is root's own command.
        let asUser = InstallPlan.update(target: InstallTarget(host: "box", user: "fleet", becomeRoot: true),
                                        machine: .hub, agent: "manager")
        guard case .run(let program) = asUser.steps[2].action else { Issue.record("one command"); return }
        #expect(asUser.arguments(for: program).last?.hasPrefix("sudo -n -i --") == true)
    }

    // MARK: the sign-in line

    private func machine(_ runtime: String, login: String = "null", agent: String = "manager",
                         reportedAt: Double = 1000) throws -> MachineStatus {
        try JSONDecoder().decode(MachineStatus.self, from: Data("""
        {"agent": "\(agent)", "machine": "hub", "role": "manager", "update": {}, "os": {},
         "security": {}, "runtime": \(runtime), "login": \(login), "reported_at": \(reportedAt)}
        """.utf8))
    }

    private let outOfClaude = #"{"name": "claude", "version": "1.0", "signed_in": false}"#
    private let intoClaude = #"{"name": "claude", "version": "1.0", "signed_in": true}"#
    private let waitingLogin = #"{"id": 1, "runtime": "claude", "state": "needs_owner", "detail": null,"#
        + #" "started_at": 1, "updated_at": 2, "url": "https://claude.ai/login", "shows_code": null,"#
        + #" "wants_code": true}"#

    private let failedLogin = #"{"id": 1, "runtime": "claude", "state": "failed","#
        + #" "detail": "The machine hit an error during the sign-in. Try again.", "started_at": 1,"#
        + #" "updated_at": 2, "url": null, "shows_code": null, "wants_code": false}"#

    @Test func aSignInThatFailedIsSaidOnceAndInOrange() throws {
        let out = try machine(#"{"name": "claude", "version": "1.0", "signed_in": false}"#, login: failedLogin)
        let line = try #require(out.signInLine(working: false))
        #expect(line.says == "The machine hit an error during the sign-in. Try again.")
        #expect(line.warn)
    }

    /// **A sign-in that only waited too long for him is no failure** (owner API 1.88, `timed_out`). The owner, 6
    /// November 2026, of "No code came back in 14 minutes." in orange under his provider cards: "that orange message
    /// does not make sense for the user! what is that?!". The row says what it says when there was no attempt.
    @Test func aSignInThatOnlyWaitedTooLongForTheOwnerIsNoFailure() throws {
        let waited = #"{"id": 1, "runtime": "claude", "state": "failed","#
            + #" "detail": "No code came back in 14 minutes. Start the sign-in again.", "started_at": 1,"#
            + #" "updated_at": 2, "url": null, "shows_code": null, "wants_code": false, "timed_out": true}"#
        let out = try machine(outOfClaude, login: waited)
        #expect(out.signInLine(working: false) == SignInLine(says: "Not signed in on this server.", warn: false))
        #expect(out.signInLine(working: false, alreadySaid: true) == nil)
        #expect(out.login?.isFailure == false && out.login?.reason == nil)
        // Every other failure stays orange: one the hub says did not time out, and one from a hub before the field.
        let said = try machine(outOfClaude, login: failedLogin.replacingOccurrences(
            of: #""wants_code": false}"#, with: #""wants_code": false, "timed_out": false}"#))
        #expect(said.signInLine(working: false)?.warn == true && said.login?.isFailure == true)
        let older = try machine(outOfClaude, login: failedLogin)
        #expect(older.signInLine(working: false)?.warn == true && older.login?.timed_out == nil)
        #expect(older.login?.reason == "The machine hit an error during the sign-in.")
    }

    @Test func aSignInThatFailedGoesStaleAgainstTheMachinesOwnReading() throws {
        // The owner's screenshot: the same failure in grey and in orange, still there after the machine had been
        // signed in. The machine's own reading is the truth, so a finished sign-in has nothing left to say.
        let signedIn = try machine(#"{"name": "claude", "version": "1.0", "signed_in": true}"#, login: failedLogin)
        #expect(signedIn.signInLine(working: false) == nil)
        // A machine that reports nothing about its sign-in makes no claim either way, so neither does the row.
        let quiet = try machine(#"{"name": "claude", "version": "1.0", "signed_in": null}"#, login: failedLogin)
        #expect(quiet.signInLine(working: false) == nil)
    }

    @Test func progressIsNotAFailureAndIsSaidOnlyOnce() throws {
        let waiting = #"{"id": 1, "runtime": "claude", "state": "needs_owner", "detail": null, "started_at": 1,"#
            + #" "updated_at": 2, "url": "https://claude.ai/login", "shows_code": null, "wants_code": true}"#
        let open = try machine(#"{"name": "claude", "version": "1.0", "signed_in": false}"#, login: waiting)
        let line = try #require(open.signInLine(working: false))
        #expect(line.says == "Open the link, then paste the code it gives you." && !line.warn)
        // A sign-in still open is news even once the machine says it is in, because it is the newer of the two.
        let done = try machine(#"{"name": "claude", "version": "1.0", "signed_in": true}"#, login: waiting)
        #expect(done.signInLine(working: false)?.warn == false)
        #expect(open.signInLine(working: true) == SignInLine(says: "Working…", warn: false))
    }

    @Test func aMachineThatWasNeverSignedInSaysSoWithoutAlarm() throws {
        let never = try machine(#"{"name": "claude", "version": "1.0", "signed_in": false}"#)
        #expect(never.signInLine(working: false) == SignInLine(says: "Not signed in on this server.", warn: false))
        let fine = try machine(#"{"name": "claude", "version": "1.0", "signed_in": true}"#)
        #expect(fine.signInLine(working: false) == nil)
    }

    // MARK: the sign-in on the face of the page

    @Test func onlyAnAgentThatStillOwesItsSignInIsOnTheFace() throws {
        let both = try server(agents: ["manager", "scout"])
        let out = try machine(outOfClaude), inside = try machine(intoClaude, agent: "scout")
        // One of the two waits, so one card shows, and it is that agent's.
        #expect(both.signIns([out, inside]).map(\.agent) == ["manager"])
        // Every agent signed in: nothing new on the face, which is what keeps a well machine's page empty.
        #expect(try both.signIns([machine(intoClaude), inside]).isEmpty)
        // Both wait: each gets its own card, in the server's own order of agents.
        #expect(try both.signIns([machine(outOfClaude, agent: "scout"), out]).map(\.agent) == ["manager", "scout"])
        // A reading of an agent that is not on this server belongs to another page.
        #expect(try both.signIns([machine(outOfClaude, agent: "worker4")]).isEmpty)
        // No reading at all yet: the face says nothing it cannot stand behind.
        #expect(both.signIns([]).isEmpty)
    }

    @Test func aSignInThatHasStartedStaysOnTheFaceUntilItEnds() throws {
        let hub = try server()
        // The machine says it is in while the sign-in is still going on: the newer of the two is the sign-in, so
        // the card must not leave the page under the owner's hands.
        let going = try machine(intoClaude, login: waitingLogin)
        #expect(going.waitsForSignIn)
        #expect(hub.signIns([going]).map(\.agent) == ["manager"])
        // It is over and the machine agrees: the card goes, and so does the page's reason to show anything.
        let done = try machine(intoClaude, login: #"{"id": 1, "runtime": "claude", "state": "done","#
            + #" "detail": "Signed in.", "started_at": 1, "updated_at": 2, "url": null, "shows_code": null,"#
            + #" "wants_code": false}"#)
        #expect(!done.waitsForSignIn && hub.signIns([done]).isEmpty)
    }

    @Test func theCardOnTheFaceSaysNothingTheStateRowSaidAlready() throws {
        // The state row of a machine that only owes its sign-in says "Waiting for your sign-in" and the check's
        // own fix. So the card under it has nothing to add until something happens.
        let out = try machine(outOfClaude)
        #expect(out.signInLine(working: false, alreadySaid: true) == nil)
        #expect(out.signInLine(working: false) != nil)
        // What the state row does not carry stays: an attempt going on, one that failed, and this Mac's own work.
        let going = try machine(outOfClaude, login: waitingLogin)
        #expect(going.signInLine(working: false, alreadySaid: true)
                == SignInLine(says: "Open the link, then paste the code it gives you.", warn: false))
        let broken = try machine(outOfClaude, login: failedLogin)
        #expect(broken.signInLine(working: false, alreadySaid: true)?.warn == true)
        #expect(out.signInLine(working: true, alreadySaid: true) == SignInLine(says: "Working…", warn: false))
    }
}
