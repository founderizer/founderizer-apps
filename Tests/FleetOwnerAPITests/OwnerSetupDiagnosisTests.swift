import FleetCore
import Foundation
import Testing
@testable import FleetOwnerAPI

/// **`setup_diagnosis`**: its exact keys, its fixed lists against FleetCore's kinds, its own change number and waits
/// beside those of `setup_state`, what moves no number, its refusals, and the tool in the program. No test starts the
/// app or runs `tailscale`.
@MainActor
struct OwnerSetupDiagnosisTests {
    /// What a test's app gives: the facts, the diagnosis, Tailscale and the seconds, with a count of Tailscale's reads.
    final class App {
        var facts = OwnerSetupBoardTests.facts(hub: .set)
        var diagnosis = OwnerSetupDiagnosisTests.diagnosis()
        var network = SetupNetwork(tailscale: "connected", hubDevice: "offline")
        var seconds: Int? = 12
        var work = SetupWorkSeconds(firstRunBuild: 30, addServerBuild: 40, install: 50)
        var networkReads = 0
        /// The build of the app's bundle on the disk.
        var disk: Int?
    }

    nonisolated static func diagnosis(hub: SetupFacts.Hub = .set, failure: String = "timed_out",
                                      window: String = "fleet",
                                      agentSetup: SetupDiagnosis.AgentSetup? = nil, firstRunBuild: SetupBuild? = nil,
                                      addServerBuild: SetupBuild? = nil,
                                      install: SetupInstall? = nil, lastInstall: SetupLastInstall? = nil,
                                      builds: SetupUnjoinedBuilds = .none) -> SetupDiagnosis {
        SetupDiagnosis(hub: hub, failure: failure, readEnded: true, answeredThisLaunch: true, answeredBefore: true,
                       hasReading: true, window: window, agentSetup: agentSetup, firstRunBuild: firstRunBuild,
                       addServerBuild: addServerBuild, install: install, lastInstall: lastInstall, builds: builds)
    }

    /// A join that stopped at its check, as the kept record of it says.
    nonisolated static let stoppedLast = SetupLastInstall(kind: "join", outcome: "stopped", step: "verify",
                                                          stop: "no_checklist", stepsDone: 3, stepsPlanned: 4)

    /// A build that stopped at joining, with its page still showing it.
    nonisolated static let stoppedBuild = SetupBuild(stage: "token", stoppedAt: "joining", stopShows: true, use: "hub",
                                                     provider: "hetzner")
    nonisolated static let runningBuild = SetupBuild(stage: "making", stoppedAt: nil, stopShows: false, use: "agent",
                                                     provider: "vultr")
    nonisolated static let runningInstall = SetupInstall(state: "running", kind: "server", step: "network",
                                                         stop: "none", stepsDone: 1, stepsPlanned: 4)

    func board(_ app: App, waitMax: Duration = .seconds(1)) -> SetupBoard {
        SetupBoard(read: { app.facts }, show: { _, _ in nil }, diagnose: { app.diagnosis },
                   network: { app.networkReads += 1; return app.network }, ages: { app.seconds },
                   workAges: { app.work }, waitMax: waitMax)
    }

    func ask(_ board: SetupBoard, _ tool: String, _ fields: [String: JSONValue] = [:],
             value: OwnerChannel.Value? = nil) async -> OwnerChannel.Answer {
        await board.answer(OwnerChannel.Request(set: "owner", tool: tool, fields: fields), value: value)
    }

    func result(_ answer: OwnerChannel.Answer) -> JSONValue? {
        if case .result(let value) = answer { return value }
        return nil
    }

    // ------------------------------------------------------------ the answer

    /// **The keys, all of them, at each level**, for every hub, window and agent's setup: a key added to the answer
    /// fails here, and with it any key of a secret's kind.
    @Test func theAnswerHasTheseKeysAndNoOther() {
        let top: Set<String> = ["change", "hub", "hub_read", "tailscale", "hub_device", "window", "agent_setup",
                                "first_run_build", "add_server_build", "install", "last_install", "builds", "app_build"]
        let read: Set<String> = ["failure", "read_ended", "answered_this_launch", "answered_before", "has_reading",
                                 "seconds_since_answer"]
        let build: Set<String> = ["stage", "stopped_at", "stop_shows", "use", "provider", "seconds_in_stage"]
        let install: Set<String> = ["state", "kind", "step", "stop", "cause", "waits_for_network", "steps_done",
                                    "steps_planned", "tries", "seconds_in_step"]
        let last: Set<String> = ["kind", "outcome", "step", "stop", "cause", "waits_for_network", "steps_done",
                                 "steps_planned", "tries", "retried", "seconds_ago"]
        let builds: Set<String> = ["unjoined", "server", "left_behind", "not_known", "newest_seconds_ago"]
        let appBuild: Set<String> = ["running", "on_disk", "offered", "state"]
        let secretWords = try! NSRegularExpression(pattern: "token|key|pass|secret|code|address|account|mail|user|host",
                                                   options: .caseInsensitive)
        let setups: [SetupDiagnosis.AgentSetup?] = [nil, .init(manager: true, placed: false, serverJoined: false)]
        // The app's work: none, and all of it.
        let works: [(SetupBuild?, SetupBuild?, SetupInstall?)] = [(nil, nil, nil),
                                                                  (Self.stoppedBuild, Self.runningBuild,
                                                                   Self.runningInstall)]
        for hub in [SetupFacts.Hub.none, .set, .answers] {
            for window in SetupDiagnosis.windows {
                for setup in setups {
                    for (noChange, work) in [false, true].flatMap({ flag in works.map { (flag, $0) } }) {
                        // The kept records: none with no work, and a last install and a count with all of it.
                        let json = Self.diagnosis(hub: hub, window: window, agentSetup: setup, firstRunBuild: work.0,
                                                  addServerBuild: work.1, install: work.2,
                                                  lastInstall: work.0 == nil ? nil : Self.stoppedLast,
                                                  builds: work.0 == nil ? .none
                                                      : .init(server: 1, leftBehind: 0, notKnown: 2))
                            .json(change: 3, noChange: noChange, network: .init(tailscale: "connected",
                                                                                 hubDevice: "online"),
                                  secondsSinceAnswer: 5, workSeconds: .init(firstRunBuild: 1, addServerBuild: 2,
                                                                            install: 3, lastInstall: 4))
                        let keys = Set(json.object!.keys)
                        // The last install shows only while the model holds no install, and the counts always.
                        #expect(json["last_install"] == .null)
                        #expect(json["builds"]?.object.map { Set($0.keys) } == builds)
                        #expect(keys == (noChange ? top.union(["no_change"]) : top))
                        #expect(Set(json["hub_read"]!.object!.keys) == read)
                        if let agent = json["agent_setup"]?.object {
                            #expect(Set(agent.keys) == ["manager", "placed", "server_joined"])
                            #expect(window == "agent_setup")
                        }
                        for name in ["first_run_build", "add_server_build"] {
                            if work.0 == nil { #expect(json[name] == .null) }
                            else { #expect(json[name]?.object.map { Set($0.keys) } == build) }
                        }
                        if work.2 == nil { #expect(json["install"] == .null) }
                        else { #expect(json["install"]?.object.map { Set($0.keys) } == install) }
                        #expect(json["app_build"]?.object.map { Set($0.keys) } == appBuild)
                        #expect(SetupAppBuild.states.contains(json["app_build"]?["state"]?.string ?? ""))
                        for key in keys.union(read).union(["manager", "placed", "server_joined"]).union(build)
                            .union(install).union(last).union(builds).union(appBuild) {
                            let range = NSRange(location: 0, length: key.utf16.count)
                            #expect(secretWords.firstMatch(in: key, range: range) == nil, "a secret's kind: \(key)")
                        }
                        #expect(SetupDiagnosis.failures.contains(json["hub_read"]!["failure"]!.string!))
                        #expect(SetupDiagnosis.tailscales.contains(json["tailscale"]!.string!))
                        #expect(SetupDiagnosis.hubDevices.contains(json["hub_device"]!.string!))
                        #expect(SetupDiagnosis.windows.contains(json["window"]!.string!))
                    }
                }
            }
        }
        // The filled values, exactly.
        let json = Self.diagnosis(firstRunBuild: Self.stoppedBuild, addServerBuild: Self.runningBuild,
                                  install: Self.runningInstall)
            .json(change: 1, workSeconds: .init(firstRunBuild: 1, addServerBuild: 2, install: 3))
        #expect(json["first_run_build"] == .object(["stage": .string("token"), "stopped_at": .string("joining"),
                                                    "stop_shows": .bool(true), "use": .string("hub"),
                                                    "provider": .string("hetzner"), "seconds_in_stage": .null]))
        #expect(json["add_server_build"] == .object(["stage": .string("making"), "stopped_at": .null,
                                                     "stop_shows": .bool(false), "use": .string("agent"),
                                                     "provider": .string("vultr"), "seconds_in_stage": .int(2)]))
        #expect(json["install"] == .object(["state": .string("running"), "kind": .string("server"),
                                            "step": .string("network"), "stop": .string("none"),
                                            "cause": .string("none"), "waits_for_network": .bool(false),
                                            "steps_done": .int(1), "steps_planned": .int(4), "tries": .int(1),
                                            "seconds_in_step": .int(3)]))
        // The keys of the last install, with a hub of each kind: it shows while the model holds no install.
        for hub in [SetupFacts.Hub.none, .set, .answers] {
            let kept = Self.diagnosis(hub: hub, lastInstall: Self.stoppedLast).json(change: 1)
            #expect(kept["last_install"]?.object.map { Set($0.keys) } == last)
            #expect(Set(kept.object!.keys) == top)
        }
    }

    /// **The tries of a press** (`InstallRetry`): 1 to 3, and the earlier tries' stops by the names of the lists of
    /// cause and of stop only; a count outside its range is held to it, and any other name is `other`.
    @Test func theTriesAndTheEarlierStopsAreFixedNames() {
        let record = SetupLastInstall(kind: "join", outcome: "stopped", step: "join", stop: "installer_stopped",
                                      cause: "packages", stepsDone: 2, stepsPlanned: 4, tries: 3,
                                      retried: ["hub_busy", "server_unreached", "rm -rf /", "none"])
        let last = Self.diagnosis(lastInstall: record).json(change: 1)["last_install"]
        #expect(last?["tries"] == .int(3))
        #expect(last?["retried"] == .array([.string("other"), .string("other")]))
        let two = SetupLastInstall(kind: "join", outcome: "stopped", step: "join", stop: "installer_stopped",
                                   cause: "packages", stepsDone: 2, stepsPlanned: 4, tries: 9,
                                   retried: ["hub_busy", "server_unreached"])
        let said = Self.diagnosis(lastInstall: two).json(change: 1)["last_install"]
        #expect(said?["tries"] == .int(3))
        #expect(said?["retried"] == .array([.string("hub_busy"), .string("server_unreached")]))
        let none = Self.diagnosis(install: SetupInstall(state: "running", kind: "server", step: "join", stop: "none",
                                                         stepsDone: 1, stepsPlanned: 4, tries: 0))
            .json(change: 1)["install"]
        #expect(none?["tries"] == .int(1))
        let many = Self.diagnosis(install: SetupInstall(state: "running", kind: "server", step: "join", stop: "none",
                                                         stepsDone: 1, stepsPlanned: 4, tries: 9))
            .json(change: 1)["install"]
        #expect(many?["tries"] == .int(3))
        let zero = SetupLastInstall(kind: "join", outcome: "stopped", step: "join", stop: "installer_stopped",
                                    cause: "packages", stepsDone: 2, stepsPlanned: 4, tries: 0, retried: [])
        #expect(Self.diagnosis(lastInstall: zero).json(change: 1)["last_install"]?["tries"] == .int(1))
    }

    /// **The last install by the kept records**: given only while the model holds no install, with its seconds, and
    /// null with no record. Its stop and its wait for the network count only for a record that says stopped.
    @Test func theLastInstallShowsOnlyWhileNoInstallIsHeld() {
        let none = Self.diagnosis().json(change: 1, workSeconds: .init(lastInstall: 9))
        #expect(none["last_install"] == .null)
        let kept = Self.diagnosis(lastInstall: Self.stoppedLast).json(change: 1, workSeconds: .init(lastInstall: 75))
        #expect(kept["last_install"] == .object(["kind": .string("join"), "outcome": .string("stopped"),
                                                 "step": .string("verify"), "stop": .string("no_checklist"),
                                                 "cause": .string("none"), "waits_for_network": .bool(false),
                                                 "steps_done": .int(3),
                                                 "steps_planned": .int(4), "tries": .int(1), "retried": .array([]),
                                                 "seconds_ago": .int(75)]))
        // With an install in the model, in any state: null, whatever the record says.
        for held in [Self.runningInstall,
                     SetupInstall(state: "none", kind: "server", step: "read", stop: "none", stepsDone: 0, stepsPlanned: 4),
                     SetupInstall(state: "done", kind: "hub", step: "none", stop: "none", stepsDone: 9, stepsPlanned: 9)] {
            let both = Self.diagnosis(install: held, lastInstall: Self.stoppedLast)
                .json(change: 1, workSeconds: .init(install: 3, lastInstall: 75))
            #expect(both["last_install"] == .null && both["install"] != .null)
        }
        // A record that waits for the network, and one that the app's end cut off: no stop for it.
        var waits = Self.stoppedLast
        waits.stop = "network_key_refused"
        waits.waitsForNetwork = true
        let waiting = Self.diagnosis(lastInstall: waits).json(change: 1)["last_install"]
        #expect(waiting?["stop"] == .string("network_key_refused") && waiting?["waits_for_network"] == .bool(true))
        #expect(waiting?["seconds_ago"] == .null)
        waits.outcome = "interrupted"
        let cut = Self.diagnosis(lastInstall: waits).json(change: 1, workSeconds: .init(lastInstall: -3))["last_install"]
        #expect(cut?["outcome"] == .string("interrupted") && cut?["stop"] == .string("none"))
        #expect(cut?["waits_for_network"] == .bool(false) && cut?["seconds_ago"] == .null)
    }

    /// **The counts of the servers that never joined**: the sum and its three parts, always an object, each part
    /// from 0 to its bound.
    @Test func theBuildsThatNeverJoinedAreCounts() {
        // With no such record the age is null, also when a caller gives one.
        #expect(Self.diagnosis().json(change: 1, workSeconds: .init(unjoinedBuild: 40))["builds"]
                == .object(["unjoined": .int(0), "server": .int(0), "left_behind": .int(0), "not_known": .int(0),
                            "newest_seconds_ago": .null]))
        let some = Self.diagnosis(builds: .init(server: 2, leftBehind: 1, notKnown: 3))
            .json(change: 1, workSeconds: .init(unjoinedBuild: 86_400))
        #expect(some["builds"] == .object(["unjoined": .int(6), "server": .int(2), "left_behind": .int(1),
                                           "not_known": .int(3), "newest_seconds_ago": .int(86_400)]))
        let odd = Self.diagnosis(builds: .init(server: -4, leftBehind: 5000, notKnown: 0))
            .json(change: 1, workSeconds: .init(unjoinedBuild: -3))
        #expect(odd["builds"] == .object(["unjoined": .int(Int64(SetupUnjoinedBuilds.most)), "server": .int(0),
                                          "left_behind": .int(Int64(SetupUnjoinedBuilds.most)), "not_known": .int(0),
                                          "newest_seconds_ago": .null]))
        // The age moves no number: it is read when the answer is written.
        let counted = Self.diagnosis(builds: .init(server: 1, leftBehind: 0, notKnown: 0))
        #expect(counted.json(change: 1)["builds"]?["newest_seconds_ago"] == .null)
        #expect(counted == Self.diagnosis(builds: .init(server: 1, leftBehind: 0, notKnown: 0)))
        // With an install in the model the counts stay.
        let held = Self.diagnosis(install: Self.runningInstall, builds: .init(server: 1, leftBehind: 0, notKnown: 0))
        #expect(held.json(change: 1)["builds"]?["unjoined"] == .int(1))
    }

    /// **A change of a kept record moves the diagnosis's number**, and the seconds since the record's change do not.
    @Test func aChangeOfAKeptRecordMovesTheNumberAndItsSecondsDoNot() async {
        let app = App()
        let board = board(app)
        app.diagnosis.lastInstall = Self.stoppedLast
        board.refresh()
        #expect(board.diagnosisChange == 2 && board.change == 1)
        app.work = SetupWorkSeconds(lastInstall: 600)
        board.refresh()
        #expect(board.diagnosisChange == 2)
        #expect(result(await ask(board, "setup_diagnosis"))?["last_install"]?["seconds_ago"] == .int(600))
        app.diagnosis.builds = .init(server: 1, leftBehind: 0, notKnown: 0)
        board.refresh()
        #expect(board.diagnosisChange == 3 && board.change == 1)
        #expect(result(await ask(board, "setup_diagnosis"))?["builds"]?["unjoined"] == .int(1))
    }

    /// **The rule of `app_build.state`**, in its order, and its numbers: an offer that is not newer than the build that
    /// runs is no offer, and a number of 0 or less is null.
    @Test func theAppBuildSaysWhetherANewerBuildWaits() {
        func state(_ running: Int?, _ onDisk: Int?, _ offered: Int?, _ installing: Bool) -> String {
            SetupAppBuild.state(running: running, onDisk: onDisk, offered: offered, installing: installing)
        }
        #expect(state(246, 247, nil, false) == "waits_for_restart")
        #expect(state(246, 247, 248, true) == "waits_for_restart")
        #expect(state(246, 246, 247, true) == "installing")
        #expect(state(246, nil, nil, true) == "installing")
        #expect(state(246, 246, 247, false) == "offered")
        #expect(state(246, 246, 246, false) == "current")
        #expect(state(246, 245, 240, false) == "current")
        #expect(state(nil, 247, 247, false) == "current")
        #expect(SetupAppBuild.states == ["waits_for_restart", "installing", "offered", "current"])

        let waits = Self.diagnosis()
        var diagnosis = waits
        diagnosis.appBuild = SetupAppBuild(running: 246, offered: 247, installing: false)
        #expect(diagnosis.json(change: 1, diskBuild: 247)["app_build"]
                == .object(["running": .int(246), "on_disk": .int(247), "offered": .int(247),
                            "state": .string("waits_for_restart")]))
        diagnosis.appBuild = SetupAppBuild(running: 246, offered: 246, installing: false)
        #expect(diagnosis.json(change: 1, diskBuild: nil)["app_build"]
                == .object(["running": .int(246), "on_disk": .null, "offered": .null, "state": .string("current")]))
        diagnosis.appBuild = SetupAppBuild(running: -1, offered: 0, installing: false)
        #expect(diagnosis.json(change: 1, diskBuild: 0)["app_build"]
                == .object(["running": .null, "on_disk": .null, "offered": .null, "state": .string("current")]))
        #expect(waits.json(change: 1)["app_build"]
                == .object(["running": .null, "on_disk": .null, "offered": .null, "state": .string("current")]))
    }

    /// **The build on the disk is read when the answer is written** and moves no number; an offer moves it.
    @Test func theDiskBuildMovesNoNumberAndAnOfferDoes() async {
        let app = App()
        app.diagnosis.appBuild = SetupAppBuild(running: 246, offered: nil, installing: false)
        app.disk = 246
        let board = SetupBoard(read: { app.facts }, show: { _, _ in nil }, diagnose: { app.diagnosis },
                               network: { app.network }, diskBuild: { app.disk }, waitMax: .seconds(1))
        #expect(result(await ask(board, "setup_diagnosis"))?["app_build"]?["state"] == .string("current"))
        app.disk = 247
        board.refresh()
        #expect(board.diagnosisChange == 1)
        #expect(result(await ask(board, "setup_diagnosis"))?["app_build"]?["state"] == .string("waits_for_restart"))
        app.diagnosis.appBuild.offered = 248
        board.refresh()
        #expect(board.diagnosisChange == 2 && board.change == 1)
    }

    /// **A build's or an install's value outside its list never passes**: a name becomes null, a step or a stop
    /// `other`, a count is capped, and the seconds show only while the work runs.
    @Test func aWorkValueOutsideItsListNeverPasses() {
        let odd = SetupBuild(stage: "Making example-server-1", stoppedAt: "100.64.0.9", stopShows: true,
                             use: "root@100.64.0.9", provider: "example.com")
        let install = SetupInstall(state: "It stopped at Join the fleet", kind: "worker-2",
                                   step: "Install Founderizer on example-mac", stop: "ssh: connect to host 100.64.0.9",
                                   waitsForNetwork: true, stepsDone: 40, stepsPlanned: -3)
        let json = Self.diagnosis(firstRunBuild: odd, install: install)
            .json(change: 1, workSeconds: .init(firstRunBuild: 9, install: 9))
        #expect(json["first_run_build"] == .object(["stage": .null, "stopped_at": .null, "stop_shows": .bool(false),
                                                    "use": .null, "provider": .null, "seconds_in_stage": .null]))
        // A stop's kind and a wait for the network are said only of a state that is `stopped`.
        #expect(json["install"] == .object(["state": .null, "kind": .null, "step": .string("other"),
                                            "stop": .string("none"), "cause": .string("none"),
                                            "waits_for_network": .bool(false),
                                            "steps_done": .int(9), "steps_planned": .int(0), "tries": .int(1),
                                            "seconds_in_step": .null]))
        // The same for a kept record: a kind or an outcome outside its list is null, a step or a stop `other`.
        let record = SetupLastInstall(kind: "worker-2", outcome: "It stopped", step: "Install Founderizer on example-mac",
                                      stop: "ssh: connect to host 100.64.0.9", waitsForNetwork: true, stepsDone: 40,
                                      stepsPlanned: -3)
        #expect(Self.diagnosis(lastInstall: record).json(change: 1, workSeconds: .init(lastInstall: 9))["last_install"]
                == .object(["kind": .null, "outcome": .null, "step": .string("other"), "stop": .string("none"),
                            "cause": .string("none"), "waits_for_network": .bool(false), "steps_done": .int(9),
                            "steps_planned": .int(0), "tries": .int(1), "retried": .array([]),
                            "seconds_ago": .int(9)]))
        var halted = record
        halted.outcome = "stopped"
        let said = Self.diagnosis(lastInstall: halted).json(change: 1)["last_install"]
        #expect(said?["stop"] == .string("other") && said?["waits_for_network"] == .bool(true))
        // Each kind of stop of this version passes as itself.
        for stop in SetupDiagnosis.installStops {
            let held = SetupInstall(state: "stopped", kind: "server", step: "read", stop: stop, stepsDone: 0,
                                    stepsPlanned: 4)
            #expect(Self.diagnosis(install: held).json(change: 1)["install"]?["stop"] == .string(stop))
        }
        // **A cause only for the installer's own stop** (`stopsWithCause`): each cause of this version passes as
        // itself there, also in a kept record; a text outside the list is `other`, never itself; every other stop,
        // an install that did not stop and a record that does not say stopped have `none`, whatever the model gave.
        for cause in SetupDiagnosis.installCauses {
            for stop in SetupDiagnosis.stopsWithCause {
                let held = SetupInstall(state: "stopped", kind: "server", step: "join", stop: stop, cause: cause,
                                        stepsDone: 2, stepsPlanned: 4)
                #expect(Self.diagnosis(install: held).json(change: 1)["install"]?["cause"] == .string(cause))
                let kept = SetupLastInstall(kind: "join", outcome: "stopped", step: "join", stop: stop, cause: cause,
                                            stepsDone: 2, stepsPlanned: 4)
                #expect(Self.diagnosis(lastInstall: kept).json(change: 1)["last_install"]?["cause"]
                        == .string(cause))
            }
        }
        let strange = SetupInstall(state: "stopped", kind: "server", step: "join", stop: "installer_stopped",
                                   cause: "Could not get the Founderizer repository from git://100.64.0.7:9418",
                                   stepsDone: 2, stepsPlanned: 4)
        #expect(Self.diagnosis(install: strange).json(change: 1)["install"]?["cause"] == .string("other"))
        for stop in SetupDiagnosis.installStops where !SetupDiagnosis.stopsWithCause.contains(stop) {
            let held = SetupInstall(state: "stopped", kind: "server", step: "join", stop: stop,
                                    cause: "code_not_fetched", stepsDone: 2, stepsPlanned: 4)
            #expect(Self.diagnosis(install: held).json(change: 1)["install"]?["cause"] == .string("none"))
        }
        let running = SetupInstall(state: "running", kind: "server", step: "join", stop: "installer_stopped",
                                   cause: "code_not_fetched", stepsDone: 2, stepsPlanned: 4)
        #expect(Self.diagnosis(install: running).json(change: 1)["install"]?["cause"] == .string("none"))
        let cut = SetupLastInstall(kind: "join", outcome: "interrupted", step: "join", stop: "installer_stopped",
                                   cause: "code_not_fetched", stepsDone: 2, stepsPlanned: 4)
        #expect(Self.diagnosis(lastInstall: cut).json(change: 1)["last_install"]?["cause"] == .string("none"))
        // Seconds below 0 are null; a stopped install has no seconds; a build at token has none.
        let stopped = SetupInstall(state: "stopped", kind: "hub", step: "claim", stop: "login_refused", stepsDone: 6,
                                   stepsPlanned: 9)
        let quiet = Self.diagnosis(firstRunBuild: Self.runningBuild, addServerBuild: Self.stoppedBuild,
                                   install: stopped)
            .json(change: 1, workSeconds: .init(firstRunBuild: -1, addServerBuild: 5, install: 5))
        #expect(quiet["first_run_build"]?["seconds_in_stage"] == .null)
        #expect(quiet["add_server_build"]?["seconds_in_stage"] == .null)
        #expect(quiet["install"]?["seconds_in_step"] == .null)
        #expect(quiet["install"]?["stop"] == .string("login_refused"))
    }

    /// **No free text passes**: a value outside its list becomes `other`, `not_read` or null.
    @Test func aValueOutsideItsListNeverPasses() {
        let odd = Self.diagnosis(failure: "Your hub took too long to answer at 100.96.10.20:8765.",
                                 window: "Manager's server")
        let json = odd.json(change: 1, network: .init(tailscale: "Running on example-mac", hubDevice: "worker-2"),
                            secondsSinceAnswer: -4)
        #expect(json["hub_read"]?["failure"] == .string("other"))
        #expect(json["tailscale"] == .string("not_read"))
        #expect(json["hub_device"] == .string("not_read"))
        #expect(json["window"] == .null)
        #expect(json["hub_read"]?["seconds_since_answer"] == .null)
        // A device that is no fact of a connected Mac, and an agent's setup outside its window.
        let device = Self.diagnosis(window: "fleet", agentSetup: .init(manager: true, placed: true, serverJoined: true))
            .json(change: 1, network: .init(tailscale: "connected", hubDevice: "100.96.10.20"))
        #expect(device["hub_device"] == .string("not_read") && device["agent_setup"] == .null)
        // With no hub the failure is none; Tailscale is given only while a hub is set and does not answer.
        let noHub = Self.diagnosis(hub: .none).json(change: 1, network: .init(tailscale: "connected", hubDevice: "online"))
        #expect(noHub["hub_read"]?["failure"] == .string("none") && noHub["tailscale"] == .string("not_read"))
        let answers = Self.diagnosis(hub: .answers).json(change: 1, network: .init(tailscale: "connected",
                                                                                    hubDevice: "online"))
        #expect(answers["tailscale"] == .string("not_read") && answers["hub_device"] == .string("not_read"))
        // The hub's device is read only for a connected Mac.
        let off = Self.diagnosis().json(change: 1, network: .init(tailscale: "not_connected", hubDevice: "online"))
        #expect(off["hub_device"] == .string("not_read"))
        // Seconds only after an answer of this launch.
        var never = Self.diagnosis()
        never.answeredThisLaunch = false
        #expect(never.json(change: 1, secondsSinceAnswer: 8)["hub_read"]?["seconds_since_answer"] == .null)
    }

    /// **Each wire list is the FleetCore kind's raw values**, in order.
    @Test func eachListIsFleetCoresKinds() {
        #expect(SetupDiagnosis.failures == ReachFacts.ReadKind.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.tailscales == ReachFacts.Tailscale.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.hubDevices == ReachFacts.HubDevice.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.windows == ReachFacts.Window.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.failures.count == 14)
        #expect(SetupDiagnosis.buildStages == ReachFacts.BuildStage.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.installStates == ReachFacts.InstallState.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.installKinds == ReachFacts.InstallKind.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.installSteps == ReachFacts.InstallStepName.allCases.map(\.rawValue))
        // **The kinds of a stop are the record's own, with `none` first**: a kind that the app's install gets later
        // fails here until the answer, the tool's words and the guide have it.
        #expect(SetupDiagnosis.installStops == ["none"] + InstallRecord.Stop.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.installStops.last == "other" && Set(SetupDiagnosis.installStops).count == 21)
        // **The installer's own reasons are the app's own names, with `none` first**, and only two kinds of a stop
        // carry one: a name that the app gets later fails here until the answer, the tool's words and the guide
        // have it.
        #expect(SetupDiagnosis.installCauses == ["none"] + InstallCause.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.stopsWithCause == [InstallRecord.Stop.installerStopped.rawValue,
                                                  InstallRecord.Stop.macRefused.rawValue])
        #expect(SetupDiagnosis.stopsWithCause.isSubset(of: Set(SetupDiagnosis.installStops)))
        #expect(SetupDiagnosis.lastInstallKinds == InstallRecord.Kind.allCases.map(\.rawValue))
        #expect(SetupDiagnosis.lastInstallOutcomes == InstallRecord.Outcome.allCases.map(\.rawValue))
        // What a build left at its provider, without `nothing`, which is no unjoined build.
        #expect(Set(SetupDiagnosis.unjoinedBuilds)
                == Set(BuildRecord.AtProvider.allCases.map(\.rawValue)).subtracting(["nothing"]))
        #expect(SetupDiagnosis.unjoinedBuilds.count == BuildRecord.AtProvider.allCases.count - 1)
        // A record's step names are the install's, without `none`.
        #expect(InstallRecord.stepIDs == SetupDiagnosis.installSteps.filter { $0 != "none" })
        #expect(SetupDiagnosis.providers == CloudProvider.allCases.map(\.rawValue))
        #expect(Set(SetupDiagnosis.providers) == SetupFacts.providers)
        #expect(SetupDiagnosis.uses == [CloudServerUse.hub.rawValue, CloudServerUse.agent.rawValue])
        #expect(SetupDiagnosis.longestPlan == ReachFacts.longestPlan)
    }

    /// **The build's stages are the app's own**: the cases of `FleetCloudModel.Stage`, read from the app's source, as
    /// `everyStepOfTheFirstRunHasAName` reads the first run's steps.
    @Test func theStagesAreTheCloudModelsCases() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer/FleetSetupSteps.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "final class FleetCloudModel {"))
        let line = try NSRegularExpression(pattern: #"enum Stage: Equatable \{ case ([a-z, ]+) \}"#)
        let rest = String(source[start.upperBound...])
        let found = try #require(line.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)))
        let cases = (rest as NSString).substring(with: found.range(at: 1)).components(separatedBy: ", ")
        #expect(cases == SetupDiagnosis.buildStages)
    }

    /// **The uses are `CloudServerUse`'s cases**, read from FleetCore's source (the type has no list of its cases).
    @Test func theUsesAreTheCasesOfCloudServerUse() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FleetCore/CloudServers.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "public enum CloudServerUse: String, Codable, Sendable {"))
        let end = try #require(source.range(of: "}", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let line = try NSRegularExpression(pattern: #"^\s*case ([a-z, ]+)$"#, options: .anchorsMatchLines)
        let cases = line.matches(in: body, range: NSRange(body.startIndex..., in: body))
            .flatMap { (body as NSString).substring(with: $0.range(at: 1)).components(separatedBy: ", ") }
        #expect(cases == SetupDiagnosis.uses)
    }

    /// **Every step of the two plans is on the list**, and the longest plan is the count that caps another Mac's.
    @Test func everyStepOfThePlansIsOnTheList() {
        let target = InstallTarget(host: "100.64.0.9")
        let hub = InstallPlan.hub(target: target, source: "https://example.com/founderizer.git", authKey: nil)
        let join = InstallPlan.join(target: target, line: "curl -fsSL https://example.com/join | sh", code: "example",
                                    authKey: nil)
        let ids = hub.steps.map(\.id) + join.steps.map(\.id)
        #expect(Set(ids) == Set(SetupDiagnosis.installSteps).subtracting(["order", "other", "none"]))
        #expect(max(hub.steps.count, join.steps.count) == SetupDiagnosis.longestPlan)
    }

    // ------------------------------------------------------------ two numbers

    @Test func theAnswerGivesItsOwnNumberAndTheNetwork() async {
        let app = App()
        let board = board(app)
        let json = result(await ask(board, "setup_diagnosis"))
        #expect(json == app.diagnosis.json(change: 1, network: app.network, secondsSinceAnswer: 12))
        #expect(app.networkReads == 1)
        // A hub that answers, or none: Tailscale is not asked.
        app.diagnosis = Self.diagnosis(hub: .answers, failure: "none")
        #expect(result(await ask(board, "setup_diagnosis"))?["tailscale"] == .string("not_read"))
        #expect(app.networkReads == 1)
    }

    /// Waits for the board's count of waits, patiently (500 tries, 10 ms apart, as `open(_:becomes:)` does).
    func waiting(_ board: SetupBoard, becomes count: Int) async -> Bool {
        for _ in 0..<500 where board.waiting != count { try? await Task.sleep(for: .milliseconds(10)) }
        return board.waiting == count
    }

    /// **A change of the diagnosis ends a waiting `setup_diagnosis` and not a waiting `setup_state`**, and the reverse
    /// (the plan's version 2, point 1).
    @Test func eachChangeEndsOnlyItsOwnWaits() async {
        let app = App()
        // 5 seconds: the count of two waits is reached well before, also on a loaded Mac; the wait that the change
        // must NOT end then ends by this time.
        let board = board(app, waitMax: .seconds(5))
        async let state = ask(board, "setup_state", ["after": .int(1)])
        async let diagnosis = ask(board, "setup_diagnosis", ["after": .int(1)])
        #expect(await waiting(board, becomes: 2))
        app.diagnosis.failure = "no_connection"
        board.refresh()
        #expect(board.change == 1 && board.diagnosisChange == 2)
        #expect(result(await diagnosis)?["change"] == .int(2))
        #expect(board.waiting == 1)
        // The wait of setup_state goes on to its bound, with no change.
        #expect(await state == .result(app.facts.json(change: 1, noChange: true, map: true)))

        async let state2 = ask(board, "setup_state", ["after": .int(1)])
        async let diagnosis2 = ask(board, "setup_diagnosis", ["after": .int(2)])
        #expect(await waiting(board, becomes: 2))
        app.facts.hub = .answers
        board.refresh()
        #expect(board.change == 2 && board.diagnosisChange == 2)
        #expect(await state2 == .result(app.facts.json(change: 2, map: true)))
        let waited = result(await diagnosis2)
        #expect(waited?["no_change"] == .bool(true) && waited?["change"] == .int(2))
    }

    /// **A change of a build or of the install ends a waiting `setup_diagnosis`, and never a waiting `setup_state`**
    /// (the plan's step 2).
    @Test func aChangeOfTheWorkEndsOnlyTheDiagnosisWaits() async {
        let app = App()
        // 5 seconds, as above: the wait of setup_state must last through both changes and end at its bound.
        let board = board(app, waitMax: .seconds(5))
        async let state = ask(board, "setup_state", ["after": .int(1)])
        async let build = ask(board, "setup_diagnosis", ["after": .int(1)])
        #expect(await waiting(board, becomes: 2))
        app.diagnosis.addServerBuild = Self.stoppedBuild
        board.refresh()
        #expect(board.change == 1 && board.diagnosisChange == 2)
        let built = result(await build)
        #expect(built?["change"] == .int(2) && built?["add_server_build"]?["stopped_at"] == .string("joining"))
        #expect(await waiting(board, becomes: 1))
        async let install = ask(board, "setup_diagnosis", ["after": .int(2)])
        #expect(await waiting(board, becomes: 2))
        app.diagnosis.install = Self.runningInstall
        board.refresh()
        #expect(board.change == 1 && board.diagnosisChange == 3)
        let installed = result(await install)
        #expect(installed?["change"] == .int(3) && installed?["install"]?["step"] == .string("network"))
        // A stop that the page cleared is a change too: the kept stop no longer shows.
        app.diagnosis.addServerBuild?.stopShows = false
        board.refresh()
        #expect(board.change == 1 && board.diagnosisChange == 4)
        #expect(await state == .result(app.facts.json(change: 1, noChange: true, map: true)))
    }

    /// **The seconds and Tailscale move no number.**
    @Test func secondsAndTailscaleMoveNoNumber() async {
        let app = App()
        let board = board(app)
        app.diagnosis.addServerBuild = Self.runningBuild
        app.diagnosis.install = Self.runningInstall
        board.refresh()
        #expect(board.diagnosisChange == 2)
        _ = await ask(board, "setup_diagnosis")
        app.seconds = 999
        app.network = SetupNetwork(tailscale: "not_running", hubDevice: "not_read")
        app.work = SetupWorkSeconds(firstRunBuild: 7, addServerBuild: 888, install: 777)
        board.refresh()
        #expect(board.diagnosisChange == 2 && board.change == 1)
        let json = result(await ask(board, "setup_diagnosis"))
        #expect(json?["change"] == .int(2))
        #expect(json?["tailscale"] == .string("not_running"))
        #expect(json?["hub_read"]?["seconds_since_answer"] == .int(999))
        #expect(json?["add_server_build"]?["seconds_in_stage"] == .int(888))
        #expect(json?["install"]?["seconds_in_step"] == .int(777))
    }

    /// **The wait and the Tailscale read stay under the program's quiet bound**: 40 seconds of wait, about 15 of the
    /// read, below the 60 reads of one second each with nothing from the app.
    @Test func theWaitAndTheReadStayUnderTheProgramsBound() {
        #expect(SetupBoard.diagnosisWaitLimit == .seconds(40))
        #expect(SetupBoard.networkReadLimit == .seconds(15))
        #expect(SetupBoard.diagnosisWaitLimit < .seconds(ChannelClient.quietReads) - SetupBoard.networkReadLimit)
        #expect(SetupBoard.waitLimit == .seconds(50))
        // The read's own limit, with its two ends of 5 seconds each, is inside the bound that the wait is cut for.
        #expect(.seconds(ReachFacts.tailscaleLimit + 10) <= SetupBoard.networkReadLimit)
        // A wait of setup_diagnosis is never longer than its own limit, whatever the board's is; setup_state's is.
        #expect(SetupBoard.limit(diagnosis: true, waitMax: .seconds(50)) == SetupBoard.diagnosisWaitLimit)
        #expect(SetupBoard.limit(diagnosis: true, waitMax: .seconds(2)) == .seconds(2))
        #expect(SetupBoard.limit(diagnosis: false, waitMax: .seconds(50)) == .seconds(50))
    }

    /// **no_change only while the number is still the caller's**: a change during the Tailscale read moves the number,
    /// and the answer then says no no_change.
    @Test func aChangeDuringTheReadIsNoNoChange() async {
        let app = App()
        let board = board(app, waitMax: .milliseconds(50))
        // With no change: no_change true at the bound.
        #expect(result(await ask(board, "setup_diagnosis", ["after": .int(1)]))?["no_change"] == .bool(true))
        let network = app.network
        let changing = SetupBoard(read: { app.facts }, show: { _, _ in nil }, diagnose: { app.diagnosis },
                                  network: {
                                      app.diagnosis.failure = "no_connection"
                                      return network
                                  }, ages: { app.seconds }, waitMax: .milliseconds(50))
        let json = result(await ask(changing, "setup_diagnosis", ["after": .int(1)]))
        #expect(json?["no_change"] == nil)
        #expect(json?["change"] == .int(2))
        #expect(json?["hub_read"]?["failure"] == .string("no_connection"))
        #expect(changing.change == 1)
    }

    /// Both kinds of wait count under one bound.
    @Test func bothKindsOfWaitShareOneBound() async {
        let app = App()
        // A long bound: each wait here ends by the change below, never by its time, also on a loaded Mac.
        let board = board(app, waitMax: .seconds(30))
        var calls: [Task<OwnerChannel.Answer, Never>] = []
        for index in 0..<SetupBoard.waitsMax {
            let tool = index % 2 == 0 ? "setup_state" : "setup_diagnosis"
            calls.append(Task { await ask(board, tool, ["after": .int(1)]) })
        }
        #expect(await waiting(board, becomes: SetupBoard.waitsMax))
        #expect(result(await ask(board, "setup_diagnosis", ["after": .int(1)]))?["no_change"] == .bool(true))
        #expect(board.waiting == SetupBoard.waitsMax)
        app.facts.hub = .answers
        app.diagnosis.failure = "none"
        board.refresh()
        for call in calls { #expect(result(await call.value)?["no_change"] == nil) }
    }

    @Test func itRefusesWhatItDoesNotTake() async {
        let board = board(App())
        #expect(await ask(board, "setup_diagnosis", ["after": .int(-1)])
                == .refused("after must be a whole number of 0 or more: the change of an earlier setup_diagnosis."))
        #expect(await ask(board, "setup_diagnosis", ["after": .string("2")])
                == .refused("after must be a whole number of 0 or more: the change of an earlier setup_diagnosis."))
        // A fixed sentence: nothing that the caller sent is said back.
        #expect(await ask(board, "setup_diagnosis", ["host": .string("x")])
                == .refused("setup_diagnosis takes only after."))
        #expect(await ask(board, "setup_diagnosis", ["sk-example-1234": .int(1), "after": .int(1)])
                == .refused("setup_diagnosis takes only after."))
        #expect(await ask(board, "setup_diagnosis", value: OwnerChannel.Value(copying: Array("x".utf8)))
                == .refused("setup_diagnosis takes no value part after its request line, so the app did nothing."))
    }

    // ------------------------------------------------------------ the tool

    @Test func theToolIsAReadWithEveryValueInItsWords() throws {
        let tool = try #require(OwnerSetupTools.tools.first { $0.name == "setup_diagnosis" })
        #expect(tool.annotations == .object(["readOnlyHint": .bool(true)]))
        #expect(tool.inputSchema["additionalProperties"] == .bool(false))
        #expect(tool.inputSchema["required"] == .array([]))
        #expect(tool.inputSchema["properties"]?.object.map { Set($0.keys) } == ["after"])
        #expect(OwnerTools.verb(of: tool) == .call)
        #expect(OwnerCLI.setupTools.contains("setup_diagnosis"))
        // **Each list stands in the words as one phrase**, in its order, once the explanations in brackets are taken
        // out: a value that left its list, or that the words lost, fails here (a single word would also be found in
        // another sentence: "refused this Mac", "the fleet's own pages").
        let words = tool.description
        let flat = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let bare = try NSRegularExpression(pattern: " ?\\([^()]*\\)")
            .stringByReplacingMatches(in: flat, range: NSRange(flat.startIndex..., in: flat), withTemplate: "")
        for list in [["none", "set", "answers"], SetupDiagnosis.failures, SetupDiagnosis.tailscales,
                     SetupDiagnosis.hubDevices, SetupDiagnosis.windows, SetupDiagnosis.buildStages,
                     SetupDiagnosis.uses, SetupDiagnosis.providers, SetupDiagnosis.installStates,
                     SetupDiagnosis.installKinds, SetupDiagnosis.installSteps, SetupDiagnosis.installStops,
                     SetupDiagnosis.installCauses,
                     SetupDiagnosis.lastInstallKinds, SetupDiagnosis.lastInstallOutcomes,
                     SetupDiagnosis.unjoinedBuilds, SetupAppBuild.states] {
            #expect(bare.contains(list.joined(separator: ", ")), "the words lack the list \(list)")
        }
        for value in ["change", "after", "no_change", "agent_setup", "manager", "placed", "server_joined",
                      "seconds_since_answer", "first_run_build", "add_server_build", "stage", "stopped_at",
                      "stop_shows", "use", "provider", "seconds_in_stage", "install", "state", "kind", "step", "stop",
                      "steps_done", "steps_planned", "seconds_in_step", "app_build", "running", "on_disk", "offered",
                      "waits_for_network", "cause", "last_install", "outcome", "seconds_ago", "builds", "unjoined"] {
            let pattern = try NSRegularExpression(pattern: "(?<![A-Za-z_])\(value)(?![A-Za-z_])")
            #expect(pattern.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) != nil,
                    "the words lack \(value)")
        }
        let plain = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for words in ["where it would open when it is closed", "online can be minutes old",
                      "offline is Tailscale's own word and usually current", "after 40 seconds",
                      "can add up to about 15 seconds", "Settings included", "the setup of any agent",
                      "an answer that this app cannot read as a hub's state",
                      "One failed read is not a hub that is down", "never gives an address, a name, a key or a line",
                      "the server that the first run makes at a provider, and the one that Add server makes",
                      "stopped_at is kept after the page cleared its stop, until a new try starts or the app quits; "
                        + "stop_shows then says false", "this app's own install of a server, never one that another Mac ran",
                      "the model still holds that stop; its page can be closed",
                      "Add server's is not null once Add server opened in this run of the app",
                      "seconds_in_step (null while no step runs)",
                      "for kind mac, whose steps come from that Mac, the kind is the app's own and never a word that "
                        + "the Mac sent",
                      "The words of a stop stay in the app",
                      // The kept records: when the last install shows, what its two odd outcomes mean, and what a
                      // count is and is not.
                      "It is given only while install is null, and it is null with no record",
                      "with hub none, the newest install of a hub",
                      "interrupted: the app quit, crashed or was updated while it ran",
                      "another try from this Mac ends the same way",
                      "of every fleet and every run of the app",
                      "A record stays after the owner deleted its server at the provider, so a count is no proof "
                        + "that a server exists",
                      "can be the first run's welcome page in front of a manager's setup that never finished"] {
            #expect(plain.contains(words), "\(words)")
        }
        // The wait for the network is a fact of its own, and no kind of stop any more.
        #expect(!plain.contains("waits_for_network, other") && !SetupDiagnosis.installStops.contains("waits_for_network"))
        #expect(!plain.contains("offline is sure") && !plain.contains("manager's server"))
        #expect(tool.description.allSatisfy { $0.isASCII })
    }
}

/// **The read in the program**: `call` takes it and `write` refuses it, and the MCP form lists it as a read.
final class OwnerSetupDiagnosisProgramTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    private func context(_ link: OwnerSetupProgramTests.Link) -> OwnerContext {
        OwnerContext(hubSetting: { nil }, transport: Fixture.transport(), home: home,
                     userAgent: "founderizer-cli/test", ownBuild: nil, startedBuild: { nil },
                     clientLabel: { "founderizer-cli/1/test" }, appLink: link.appLink())
    }

    private func program() throws -> URL {
        let folder = home.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = Bundle.module.url(forResource: "owner-tools", withExtension: "json", subdirectory: "Fixtures")!
        try? FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("owner-tools.json"))
        return folder.appendingPathComponent("founderizer-cli")
    }

    private func run(_ arguments: [String], link: OwnerSetupProgramTests.Link) throws -> (Int32, [String], [String]) {
        let out = Lines()
        var errors: [String] = []
        let status = OwnerCLI.run(arguments: arguments, executable: try program(), context: context(link),
                                  version: "0.1.0", input: { nil }, output: { out.add($0) },
                                  errors: { errors.append($0) })
        return (status, out.all, errors)
    }

    static let answer = OwnerSetupDiagnosisTests.diagnosis().json(change: 1)

    @Test func callTakesItAndWriteDoesNot() throws {
        let link = OwnerSetupProgramTests.Link([.answer(.result(Self.answer))])
        let (one, read, said) = try run(["call", "setup_diagnosis", #"{"after": 2}"#], link: link)
        #expect(one == 0 && said.isEmpty && read == [Self.answer.dumps(indent: 1)])
        #expect(link.requests == [OwnerChannel.Request(set: "owner", tool: "setup_diagnosis",
                                                       fields: ["after": .int(2)])])
        let (two, _, refused) = try run(["write", "setup_diagnosis", "{}"], link: link)
        #expect(two == 1 && refused == ["setup_diagnosis only reads, so founderizer-cli write does not take it: run "
                                        + "founderizer-cli call setup_diagnosis '<json object>'."])
        #expect(link.requests.count == 1)
        #expect(link.fronts == 0)
        let (_, tools, _) = try run(["tools"], link: link)
        #expect(tools.contains { $0.hasPrefix("call setup_diagnosis: Setup: Why the hub does not answer") })
    }

    @Test func theMCPFormListsItAsARead() async throws {
        let link = OwnerSetupProgramTests.Link([.answer(.result(Self.answer))])
        let lines = Lines()
        let mcp = OwnerMCP(tools: OwnerTools(table: Fixture.table, context: context(link)), version: "0.1.0",
                           sink: { lines.add($0) })
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}"#)
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "setup_diagnosis", "#
                 + #""arguments": {}}}"#)
        mcp.finish()
        // The wait blocks a thread: off Swift's shared pool.
        let said = await off { lines.wait(for: 2) }
        let listed = try #require(said.first { $0["id"] == .int(1) }?["result"]?["tools"]?.array)
        let tool = try #require(listed.first { $0["name"] == .string("setup_diagnosis") })
        #expect(tool["annotations"]?["readOnlyHint"] == .bool(true))
        let call = try #require(said.first { $0["id"] == .int(2) }?["result"])
        #expect(call["isError"] == .bool(false))
        #expect(link.requests.map(\.tool) == ["setup_diagnosis"])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".founderizer/lock").path))
    }
}
