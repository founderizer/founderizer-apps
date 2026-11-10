import Foundation
import Testing
@testable import FleetCore

/// What Founderizer tells the customer before he writes to us (the owner, 18 October 2026). Most of these are
/// about what the screen must **not** say: nothing that passed, nothing invented, and nothing about a machine this
/// Mac has not read.
struct FleetTroubleTests {
    private func health(helpers: [[String: Any]] = [], warnings: [[String: Any]] = [],
                        time: Double = 1_000) throws -> FleetHealth {
        try JSONDecoder().decode(FleetHealth.self, from: JSONSerialization.data(withJSONObject: [
            "db": "generation", "ok": warnings.isEmpty, "time": time, "revision": "1f43dab42994b95bf1f7458f683c5b0dd",
            "hub": ["integrity": [:]], "helpers": helpers, "warnings": warnings]))
    }

    /// One agent's machine reading. Its server has the agent's own name, as servers had before they took their
    /// Tailscale names; a test of a server named apart gives the name in `over`.
    private func machine(_ agent: String, over: [String: Any] = [:], at time: Double = 1_000) throws -> MachineStatus {
        var body: [String: Any] = [
            "agent": agent, "machine": agent, "role": "worker", "reported_at": time,
            "update": ["state": "current"], "security": [:], "runtime": ["name": "Codex", "signed_in": true],
            "os": ["name": "Ubuntu 24.04"]
        ]
        for (key, value) in over { body[key] = value }
        return try JSONDecoder().decode(MachineStatus.self, from: JSONSerialization.data(withJSONObject: body))
    }

    private func read(connectionError: String? = nil, storageError: String? = nil, isFresh: Bool = true,
                      health: FleetHealth? = nil, machines: [MachineStatus] = [], servers: [ServerEntry] = [],
                      checklists: [String: VerifyChecklist] = [:], time: Double = 1_000) -> FleetTrouble {
        FleetTrouble.read(connectionError: connectionError, storageError: storageError, isFresh: isFresh,
                          state: nil, health: health, machines: machines, servers: servers, checklists: checklists,
                          at: time)
    }

    /// One server as `/ui/servers` lists it: by default one that joined, with no agent, and a current reading.
    private func server(_ name: String = "worker-3", kind: String = "linux", agents: [String] = [], joined: Bool = true,
                        hub: Bool = false, reportedAt: Double? = 1_000, stale: Bool = false, restart: Bool = false,
                        security: [String: Any] = [:]) throws -> ServerEntry {
        let reading: Any = reportedAt.map { [
            "source": "server", "os": ["name": "Ubuntu 24.04"], "runtimes": [:], "reported_at": $0, "stale": stale,
            "security": security.merging(["reboot_required": restart]) { $1 }] as [String: Any] } ?? NSNull()
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: [
            "name": name, "kind": kind, "hub": hub, "joined": joined, "agents": agents, "reading": reading,
            "available": agents.isEmpty, "why": []] as [String: Any]))
    }

    // ------------------------------------------------------------ nothing that is right

    @Test func aFleetWithNothingWrongHasNoRowsAtAll() throws {
        let found = read(health: try health(helpers: [["agent": "vps", "offline": false, "last_seen": 999.0]]),
                         machines: [try machine("vps")],
                         checklists: ["vps": VerifyChecklist(checks: [
                            .init(check: "disk", state: "ok", says: "41 GB free."),
                            .init(check: "clock", state: "ok", says: "In step.")])])
        #expect(found.isClear)
        #expect(found.findings.isEmpty)
        #expect(found.checksRead == 2)
        #expect(found.summary == "Founderizer sees nothing wrong from here.")
    }

    @Test func aWarnIsNotAFailureAndIsNotARow() throws {
        let found = read(machines: [try machine("vps")],
                         checklists: ["vps": VerifyChecklist(checks: [
                            .init(check: "disk", state: "warn", says: "4 GB free.", fix: "Free some space.")])])
        #expect(found.isClear)
    }

    @Test func aMachineThisMacHasNotReadIsNeverShownAsWell() throws {
        let found = read(machines: [try machine("vps"), try machine("studio")],
                         checklists: ["vps": VerifyChecklist(checks: [.init(check: "disk", state: "ok", says: "Fine.")])])
        #expect(found.isClear)
        #expect(found.unchecked == ["studio"])
        #expect(found.summary.contains("has not read the checks of studio yet"))
    }

    // ------------------------------------------------------------ what it does say

    @Test func theHubComesFirstBecauseNothingUnderItCanBeTrusted() throws {
        let found = read(connectionError: "The hub is unavailable.",
                         health: try health(helpers: [["agent": "vps", "offline": true, "last_seen": 400.0]]),
                         machines: [try machine("vps")])
        #expect(found.findings.first?.id == "hub/unreachable")
        #expect(found.findings.first?.says == "The hub is unavailable.")
        #expect(found.findings.contains { $0.id == "vps/offline" })
    }

    @Test func theManagersWarningIsOneRowInTheHubsOwnWords() throws {
        let state = try JSONDecoder().decode(HubState.self, from: JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "generation", "time": 1_000.0, "manager_flag": "The manager is not signed in.",
            "agents": [], "tasks": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []]))
        let found = FleetTrouble.read(connectionError: nil, storageError: nil, isFresh: true, state: state,
                                      health: try health(warnings: [["kind": "manager_signed_out", "agent": "manager",
                                                                     "detail": "The manager is not signed in.",
                                                                     "fix": "Open Manager and sign it in."]]),
                                      machines: [], servers: [], checklists: [:], at: 1_000)
        #expect(found.findings.map(\.id) == ["hub/manager_signed_out/manager"])
        #expect(found.findings.first?.title == "The manager needs you")
        #expect(found.findings.first?.fix == "Open Manager and sign it in.")
    }

    // ------------------------------------------------------------ one row for one thing

    @Test func machinesWithTheSameTroubleInTheSameWordsAreOneRow() throws {
        let found = read(machines: [try machine("vps", over: ["security": ["reboot_required": true]]),
                                    try machine("studio", over: ["security": ["reboot_required": true]]),
                                    try machine("worker4", over: ["security": ["reboot_required": true]])])
        #expect(found.findings.count == 1)
        let row = try #require(found.findings.first)
        #expect(row.id == "machines/reboot")
        #expect(row.title == "3 servers wait for a restart")
        // Named, then said of all of them: never "its system" after three names.
        #expect(row.says == "vps, studio, worker4. Their systems installed updates that need a restart.")
        #expect(row.fix == "Restart each one when no task of yours runs on it.")
        // No one machine to open, and a restart is never an agent's to take.
        #expect(row.machine == nil)
        #expect(!row.takesAnAgent)
    }

    @Test func troubleWhoseOwnWordsDifferStaysItsOwnRow() throws {
        let found = read(machines: [
            try machine("vps", over: ["update": ["state": "failed", "detail": "git refused the fetch"]]),
            try machine("studio", over: ["update": ["state": "failed", "detail": "no space left"]])])
        #expect(found.findings.count == 2)
        #expect(Set(found.findings.map(\.id)) == ["vps/update", "studio/update"])
    }

    @Test func twoMachinesWithTwoDifferentTroublesStayTwoRows() throws {
        let found = read(machines: [try machine("vps", over: ["security": ["reboot_required": true]]),
                                    try machine("studio", over: ["runtime": ["name": "Codex", "signed_in": false]])])
        #expect(Set(found.findings.map(\.id)) == ["vps/reboot", "studio/signed_in"])
    }

    @Test func aRestartIsNeverHandedToAnAgentThatMayBeRunningOnThatMachine() throws {
        let found = read(machines: [try machine("vps", over: ["security": ["reboot_required": true]])])
        let row = try #require(found.findings.first)
        #expect(row.id == "vps/reboot")
        #expect(row.ownerOnly)
        #expect(!row.takesAnAgent)
    }

    @Test func anOldReadingIsNamedOnlyWhenTheHubAnswered() {
        #expect(read(isFresh: false).findings.isEmpty)
        let withState = FleetTrouble.read(connectionError: nil, storageError: nil, isFresh: false,
                                          state: nil, health: nil, machines: [], servers: [], checklists: [:],
                                          at: 1_000)
        #expect(withState.findings.isEmpty)
    }

    @Test func aQuietHelperSaysHowLongItHasBeenQuiet() throws {
        let found = read(health: try health(helpers: [["agent": "studio", "offline": true, "last_seen": 400.0]]))
        let quiet = try #require(found.findings.first { $0.id == "studio/offline" })
        // System status's words for the same fact (fix round 2): its name, and since when.
        #expect(quiet.title == "Studio is not answering")
        #expect(quiet.says.hasPrefix("Silent since "))
        #expect(quiet.fix == nil)
        #expect(quiet.machine == "studio")
    }

    /// The fix round of 29 October 2026: three agents' warnings shared the id `hub/<kind>`, so the screen drew Mini's row
    /// three times and never Scout's or Echo's. One row per agent's server, merged as System status merges them, each fact
    /// once.
    @Test func everySilentAgentIsOneRowOfItsOwnAndSaysItsFactOnce() throws {
        var warnings: [[String: Any]] = [], helpers: [[String: Any]] = []
        for agent in ["mini", "scout", "echo"] {
            warnings.append(["kind": "helper_offline", "agent": agent, "detail": "Silent since 23:06.",
                             "fix": "Open \(agent.capitalized)."])
            helpers.append(["agent": agent, "offline": true, "last_seen": 400.0])
        }
        for agent in ["mini", "scout", "echo"] {
            warnings.append(["kind": "machine_stale", "agent": agent, "detail": "No status for ten minutes.",
                             "fix": "Open \(agent.capitalized) and check it."])
        }
        let found = read(health: try health(helpers: helpers, warnings: warnings))
        #expect(found.findings.map(\.title) == ["Mini is not answering", "Scout is not answering", "Echo is not answering"])
        #expect(Set(found.findings.map(\.id)).count == 3)
        #expect(found.findings.allSatisfy { $0.says == "Silent since 23:06." })
        // The helper's own row is the hub's row about it, not a second one.
        #expect(!found.findings.contains { $0.id.hasSuffix("/offline") })
    }

    /// Review A1 (fix round 2): the manager's limit, its spent allowance, stuck tasks and undecided reports all name the
    /// manager, and were one row "The manager needs you" that said all four facts. Only an agent's server is one row.
    @Test func warningsThatNameOneAgentStayRowsOfTheirOwnUnlessTheyAreAboutItsServer() throws {
        let found = read(health: try health(warnings: [
            ["kind": "manager_limited", "detail": "The manager reached its usage limit.", "agent": "manager"],
            ["kind": "tasks_stuck", "detail": "2 tasks are stuck, and nobody is acting on them.", "agent": "manager"],
            ["kind": "reports_undecided", "detail": "3 reports from your agents wait for a decision.", "agent": "manager"],
            ["kind": "disk_low", "detail": "The hub disk has 312 MiB free.", "agent": "manager"],
        ]))
        let rows = found.findings.filter { $0.id.hasPrefix("hub/") }
        #expect(rows.map(\.title) == ["The manager needs you", "Some tasks are stuck", "Reports wait for a decision",
                                      "The hub's disk is nearly full"])
        #expect(rows.map(\.says) == ["The manager reached its usage limit.", "2 tasks are stuck, and nobody is acting on them.",
                                     "3 reports from your agents wait for a decision.", "The hub disk has 312 MiB free."])
        #expect(Set(rows.map(\.id)).count == 4)
    }

    @Test func sinceIsATimeTodayAndADayBefore() {
        let utc = TimeZone(identifier: "UTC")!
        let today = FleetTrouble.since(1_800_000_000, now: 1_800_000_600, zone: utc)
        let before = FleetTrouble.since(1_800_000_000, now: 1_800_000_000 + 3 * 86_400, zone: utc)
        #expect(!today.contains(","))
        #expect(before.contains(","))
        #expect(before.hasSuffix(today))
    }

    @Test func aHelperThatNeverAnsweredSaysThatAndNotATime() throws {
        let found = read(health: try health(helpers: [["agent": "studio", "offline": true]]))
        #expect(found.findings.first?.says.contains("never answered") == true)
    }

    @Test func aSignedOutProviderIsHisOwnStepAndNeverAnAgents() throws {
        let found = read(machines: [try machine("vps", over: ["runtime": ["name": "Codex", "signed_in": false]])])
        let signedOut = try #require(found.findings.first { $0.id == "vps/signed_in" })
        #expect(signedOut.says.contains("Codex"))
        #expect(signedOut.fix?.contains("your own step") == true)
        // The prompt must never be offered for a sign-in: no agent of his may take it.
        #expect(!signedOut.takesAnAgent)
    }

    @Test func aFailedUpdateAndAFailedCheckEachSayWhatTheMachineSaid() throws {
        let found = read(machines: [try machine("vps", over: [
            "update": ["state": "failed", "detail": "git refused the fetch"],
            "check": ["id": 4, "state": "failed", "requested_at": 900.0, "completed_at": 950.0,
                      "detail": "the helper did not answer"]])])
        #expect(found.findings.first { $0.id == "vps/update" }?.says == "git refused the fetch")
        #expect(found.findings.first { $0.id == "vps/check" }?.says == "the helper did not answer")
    }

    @Test func aStaleMachineReadingIsNotReadAsAProblemOfItsOwn() throws {
        // Older than ten minutes: the hub's reading, not the machine, is what is out of date.
        let found = read(machines: [try machine("vps", over: ["reported_at": 100.0,
                                                              "runtime": ["name": "Codex", "signed_in": false]])])
        #expect(found.isClear)
    }

    @Test func aFailedVerifyCheckCarriesItsOwnWordsAndItsOwnFix() throws {
        let found = read(machines: [try machine("vps")],
                         checklists: ["vps": VerifyChecklist(checks: [
                            .init(check: "disk", state: "ok", says: "41 GB free."),
                            .init(check: "tailnet", state: "fail", says: "This machine is not on your private network.",
                                  fix: "Run `tailscale up` on it and join your own network.")])])
        let check = try #require(found.findings.first { $0.id == "vps/tailnet" })
        #expect(check.title == "Private network · vps")
        #expect(check.says == "This machine is not on your private network.")
        #expect(check.fix == "Run `tailscale up` on it and join your own network.")
        #expect(check.takesAnAgent)
        #expect(found.checksRead == 2)
    }

    @Test func aFailedSignInCheckIsStillNotWorkForAnAgent() throws {
        let found = read(machines: [try machine("vps")],
                         checklists: ["vps": VerifyChecklist(checks: [
                            .init(check: VerifyChecklist.signInCheck, state: "fail", says: "Codex is signed out.",
                                  fix: "Sign in from the app.")])])
        #expect(found.findings.first?.takesAnAgent == false)
    }

    /// The hub writes the team file for the whole fleet, and every server whose copy breaks a rule fails `team`
    /// (review A, round 4, 30 October 2026). An agent on one server would change only that server's copy, which then
    /// stops taking the fleet's updates, while the hub's own file stays broken. So it is his step too: no prompt, and
    /// it stays in the report. A stopped service on the same server still takes an agent.
    @Test func aBrokenTeamFileIsNotWorkForAnAgentEither() throws {
        let team = VerifyCheck(check: "team", state: "fail", says: "The team file breaks one of its rules.",
                               fix: "Put the rule right in the team file. Until then, the app cannot change your team.",
                               command: "cd /root/fleet-kit && python3 -c 'import json, hub; "
                                   + "print(hub.team_problem(json.load(open(\"team.json\"))))'")
        let stopped = VerifyCheck(check: "services", state: "fail", says: "The hub is not running.",
                                  fix: "Start it again on this server.", command: "systemctl --user restart fleet-hub")
        let found = read(machines: [try machine("hub"), try machine("vps")],
                         checklists: ["hub": VerifyChecklist(checks: [stopped, team]),
                                      "vps": VerifyChecklist(checks: [team])])
        let teams = found.findings.filter { $0.id.hasSuffix("/team") }
        #expect(teams.map(\.id) == ["hub/team", "vps/team"])
        #expect(teams.allSatisfy { $0.ownerOnly && !$0.takesAnAgent })
        #expect(try #require(found.findings.first { $0.id == "hub/services" }).takesAnAgent)
        #expect(found.reportLine.contains("vps/team: The team file breaks one of its rules."))
    }

    /// Since 30 October 2026 the hub's address checks send him to Report a problem, with no command (dd172d3 in the
    /// hub's repository). That is a step in this app, which no agent can take, so it offers no prompt; and Report a
    /// problem, the window that line would send him to, shows no fix line for it (review B, round 6).
    @Test func aFixThatSendsHimToReportAProblemOffersNoPrompt() throws {
        let fix = "Report a problem from the Help menu, so that the hub gets this address right."
        let found = read(machines: [try machine("manager", over: ["machine": "hub"]),
                                    try machine("studio", over: ["machine": "mac-studio"])],
                         checklists: [
                            "hub": VerifyChecklist(checks: [
                                .init(check: "hub_answers", state: "fail",
                                      says: "The hub has no address, so no server can reach it.", fix: fix)]),
                            "mac-studio": VerifyChecklist(checks: [
                                .init(check: "tailnet", state: "fail",
                                      says: "This server is 100.70.1.22, but the hub expects 100.70.1.21 and refuses "
                                          + "its calls.", fix: fix)])])
        #expect(found.findings.map(\.id) == ["hub/hub_answers", "mac-studio/tailnet"])
        #expect(found.findings.allSatisfy { $0.ownerOnly && !$0.takesAnAgent && $0.shownFix == nil })
    }

    /// The fix line decides that, and not the check: an older hub wrote the tailnet check's command inside its fix,
    /// and a newer one gives it apart, and both still offer the prompt.
    @Test func aTailnetFixWithACommandStillTakesAnAgent() throws {
        let old = VerifyCheck(check: "tailnet", state: "fail",
                              says: "the private network is not up (Tailscale is Stopped)",
                              fix: "Start Tailscale: sudo tailscale up --accept-dns=false")
        let new = VerifyCheck(check: "tailnet", state: "fail",
                              says: "Tailscale is not up, so this server is on no private network.",
                              fix: "Start Tailscale on this server.", command: "tailscale up --accept-dns=false")
        for check in [old, new] {
            let found = read(machines: [try machine("vps")], checklists: ["vps": VerifyChecklist(checks: [check])])
            let finding = try #require(found.findings.first { $0.id == "vps/tailnet" })
            #expect(!finding.ownerOnly)
            #expect(finding.takesAnAgent)
            #expect(finding.shownFix == check.fix)
        }
    }

    @Test func oneBrokenFleetCannotFillTheScreen() throws {
        let checks = (0..<20).map { VerifyCheck(check: "check\($0)", state: "fail", says: "Wrong.", fix: "Put it right.") }
        let found = read(machines: [try machine("vps")], checklists: ["vps": VerifyChecklist(checks: checks)])
        #expect(found.findings.count == FleetTrouble.maxFindings)
    }

    // ------------------------------------------------------------ what goes in the report

    @Test func theReportLineNamesWhatWasWrongAndStaysInsideWhatTheSiteTakes() throws {
        let checks = (0..<12).map {
            VerifyCheck(check: "check\($0)", state: "fail", says: String(repeating: "x", count: 200), fix: "Put it right.")
        }
        let found = read(machines: [try machine("vps")], checklists: ["vps": VerifyChecklist(checks: checks)])
        #expect(found.reportLine.count <= 500)
        #expect(found.reportLine.contains("vps/check0"))
        #expect(found.reportLine.contains("more"))
    }

    @Test func aClearFleetStillSaysHowMuchWasChecked() throws {
        #expect(read().reportLine == "Nothing wrong from the app; no server checks read")
        let found = read(machines: [try machine("vps")],
                         checklists: ["vps": VerifyChecklist(checks: [.init(check: "disk", state: "ok", says: "Fine.")])])
        #expect(found.reportLine == "Nothing wrong from the app; 1 server checks read")
    }

    // ------------------------------------------------------------ the block he pastes into his agent

    @Test func thePromptCarriesTheChecksOwnFixAndNoAdviceOfOurs() {
        let finding = Trouble(id: "vps/tailnet", title: "Private network · vps",
                              says: "This machine is not on your private network.",
                              fix: "Run `tailscale up` on it and join your own network.",
                              machine: "vps", server: "vps", kind: .check)
        let text = TroublePrompt.text(for: finding, fleet: "0123456789abcdef", revision: "1f43dab42994")
        #expect(text.contains("Server: vps"))
        #expect(text.contains("Check: vps/tailnet"))
        #expect(text.contains("This machine is not on your private network."))
        #expect(text.contains("Run `tailscale up` on it and join your own network."))
        #expect(text.contains("Fleet: 0123456789abcdef"))
        #expect(text.contains("Revision: 1f43dab42994"))
        for refusal in TroublePrompt.refusals { #expect(text.contains(refusal)) }
    }

    @Test func thePromptLeavesOutAFactThisMacDoesNotHave() {
        let finding = Trouble(id: "vps/disk", title: "Disk space · vps", says: "Full.", fix: "Free space.",
                              machine: "vps", kind: .check)
        let text = TroublePrompt.text(for: finding, fleet: nil, revision: "")
        #expect(!text.contains("Fleet:"))
        #expect(!text.contains("Revision:"))
    }

    /// A hub before 30 October 2026 wrote the command inside `fix` and sends no `command`. Its prompt gives the
    /// command as it always did: once, in the fix line, with the step that carries that line out.
    @Test func anOldHubsPromptCarriesTheCommandInItsFixLineAsBefore() throws {
        let answer = try #require(VerifyChecklist.read(output: """
        [{"check": "services", "state": "fail", "says": "fleet-hub is not running",
          "fix": "Start it again: systemctl --user restart fleet-hub"}]
        """))
        #expect(answer.checks.first?.command == nil)
        let finding = try #require(read(machines: [try machine("hub")], checklists: ["hub": answer])
            .findings.first { $0.id == "hub/services" })
        let text = TroublePrompt.text(for: finding, fleet: nil, revision: nil)
        #expect(finding.takesAnAgent)
        #expect(text.contains("\nThe fix Founderizer gives: Start it again: systemctl --user restart fleet-hub\n\n"))
        #expect(text.components(separatedBy: "systemctl --user restart fleet-hub").count == 2)
        #expect(!text.contains("The command Founderizer gives"))
        #expect(text.contains("\n3. Carry out the fix line above, and nothing else. If it cannot be done without one "
                              + "of the refusals, stop and say so.\n"))
    }

    /// A hub since 30 October 2026 keeps `fix` in his words and the exact command apart, in `command`. Review A of
    /// that day: the prompt held only "Start it again on this server.", so his agent had no command and had to stop
    /// and ask. The agent gets the command once, under the fix line, and carries out that line with it and nothing
    /// else; the copy of the checks this Mac keeps, which Report a problem reads, keeps it; and his screen and the
    /// report never show it.
    @Test func aNewHubsCommandReachesHisAgentOnceAndNoScreen() throws {
        let answer = try #require(VerifyChecklist.read(output: """
        [{"check": "services", "state": "fail", "says": "The hub is not running.",
          "fix": "Start it again on this server.", "command": "systemctl --user restart fleet-hub"}]
        """))
        #expect(answer.checks.first?.command == "systemctl --user restart fleet-hub")
        let kept = try JSONDecoder().decode([VerifyCheck].self, from: JSONEncoder().encode(answer.checks))
        let found = read(machines: [try machine("hub")], checklists: ["hub": VerifyChecklist(checks: kept)])
        let finding = try #require(found.findings.first { $0.id == "hub/services" })
        let text = TroublePrompt.text(for: finding, fleet: nil, revision: nil)
        #expect(finding.takesAnAgent)
        #expect(text.contains("\nThe fix Founderizer gives: Start it again on this server.\n"
                              + "The command Founderizer gives: systemctl --user restart fleet-hub\n\n"))
        #expect(text.components(separatedBy: "systemctl --user restart fleet-hub").count == 2)
        #expect(text.contains("\n3. Carry out the fix line above, with the command Founderizer gives for it, and "
                              + "nothing else. If it cannot be done without one of the refusals, stop and say so.\n"))
        for refusal in TroublePrompt.refusals { #expect(text.contains(refusal)) }
        for shown in [finding.title, finding.says, finding.fix ?? "", found.reportLine] {
            #expect(!shown.contains("systemctl"))
        }
    }

    /// Some commands only read (review B, 30 October 2026): the hub's `hub_answers` check gives the status of the
    /// hub's service. The fix line stays the step and the command is its means, because an agent told to run the
    /// command and nothing else reads what it prints and stops there.
    @Test func theFixLineStaysTheStepWhenItsCommandOnlyReads() throws {
        let answer = try #require(VerifyChecklist.read(output: """
        [{"check": "hub_answers", "state": "fail", "says": "The hub does not answer at http://100.70.1.21:8765.",
          "fix": "Look at the hub's service on this server.", "command": "systemctl --user status fleet-hub"}]
        """))
        let finding = try #require(read(machines: [try machine("hub")], checklists: ["hub": answer])
            .findings.first { $0.id == "hub/hub_answers" })
        let text = TroublePrompt.text(for: finding, fleet: nil, revision: nil)
        #expect(finding.takesAnAgent)
        #expect(text.contains("\nThe fix Founderizer gives: Look at the hub's service on this server.\n"
                              + "The command Founderizer gives: systemctl --user status fleet-hub\n\n"))
        #expect(text.contains("\n3. Carry out the fix line above, with the command Founderizer gives for it, and "
                              + "nothing else. If it cannot be done without one of the refusals, stop and say so.\n"))
        #expect(!text.contains("Run the command"))
    }

    /// A finding keeps the agent's name, which its page in the app goes by, and an agent's server can have another
    /// name: studio runs on mac-studio (review B, round 3, 30 October 2026). The prompt said "Server: studio", and
    /// "Machine: studio" before that, so step 1 sent his agent to a server that is not there. It names the server by
    /// its own name and the agent apart, for a failed check and for a failed update alike.
    @Test func thePromptNamesTheServerByItsOwnNameAndTheAgentApart() throws {
        let studio = try machine("studio", over: ["machine": "mac-studio", "update": ["state": "failed"]])
        let found = read(machines: [studio], checklists: ["mac-studio": VerifyChecklist(checks: [
            .init(check: "services", state: "fail", says: "Studio is not running.",
                  fix: "Start it again on this server.", command: "systemctl --user restart fleet-studio")])])
        for id in ["mac-studio/services", "studio/update"] {
            let finding = try #require(found.findings.first { $0.id == id })
            let text = TroublePrompt.text(for: finding, fleet: nil, revision: nil)
            #expect(finding.takesAnAgent)
            #expect(finding.machine == "studio")         // its page in the app, and the link to it
            #expect(text.contains("\nServer: mac-studio\nAgent: Studio\nCheck: \(id)\n"))
            #expect(!text.contains("Server: studio"))
            #expect(text.contains("\n1. Reach the server named above,"))
        }
    }

    // ------------------------------------------------------------ a server's checks, under the server's own name

    /// A server's page keeps its checks under the server's own name, and since servers take their Tailscale names
    /// that is seldom its agent's: studio runs on mac-studio (review A, round 6, 30 October 2026). Report a problem
    /// looked them up by the agent's name, found none, and said it had not read them.
    @Test func aServerNamedApartFromItsAgentHasItsChecksRead() throws {
        let found = read(machines: [try machine("studio", over: ["machine": "mac-studio"])],
                         checklists: ["mac-studio": VerifyChecklist(checks: [
                            .init(check: "disk", state: "ok", says: "41 GiB free."),
                            .init(check: "services", state: "fail", says: "Studio is not running.",
                                  fix: "Start it again on this server.",
                                  command: "systemctl --user restart fleet-studio")])])
        #expect(found.unchecked.isEmpty)
        #expect(found.checksRead == 2)
        let finding = try #require(found.findings.first { $0.id == "mac-studio/services" })
        #expect(finding.title == "Services · mac-studio")
        #expect(finding.takesAnAgent)
    }

    /// The agents of one server share its checks, so each failed check is one row and one prompt, which names both
    /// agents (review A, round 6).
    @Test func aServerWithTwoAgentsListsEachCheckOnce() throws {
        let found = read(machines: [try machine("mini", over: ["machine": "mac-mini"]),
                                    try machine("scout", over: ["machine": "mac-mini"])],
                         checklists: ["mac-mini": VerifyChecklist(checks: [
                            .init(check: "services", state: "fail", says: "Scout is not running.",
                                  fix: "Start it again on this server.",
                                  command: "systemctl --user restart fleet-scout"),
                            .init(check: "disk", state: "fail", says: "0.4 GiB free.",
                                  fix: "Free disk space on this server.")])])
        #expect(found.findings.map(\.id) == ["mac-mini/services", "mac-mini/disk"])
        #expect(found.checksRead == 2)
        #expect(found.unchecked.isEmpty)
        let finding = try #require(found.findings.first)
        #expect(TroublePrompt.text(for: finding, fleet: nil, revision: nil)
            .contains("\nServer: mac-mini\nAgents: Mini, Scout\nCheck: mac-mini/services\n"))
    }

    /// The hub's own server is "hub" and its agent "manager", so the hub's checks were never read here either.
    @Test func theHubsChecksAreFoundUnderItsServersName() throws {
        let found = read(machines: [try machine("manager", over: ["machine": "hub"])],
                         checklists: ["hub": VerifyChecklist(checks: [
                            .init(check: "clock", state: "fail",
                                  says: "This server does not follow network time, so its clock drifts.",
                                  fix: "Turn network time on for this server.",
                                  command: "sudo timedatectl set-ntp true")])])
        #expect(found.unchecked.isEmpty)
        let finding = try #require(found.findings.first { $0.id == "hub/clock" })
        #expect(TroublePrompt.text(for: finding, fleet: nil, revision: nil)
            .contains("\nServer: hub\nAgent: Manager\nCheck: hub/clock\n"))
    }

    // ------------------------------------------------------------ a server with no agent

    /// `/ui/machines` has a row for each agent, so a server with no agent was not in this window at all: what a closer
    /// look found on its page stood nowhere here, and "nothing wrong" covered a server nobody had read.
    @Test func aServerWithNoAgentHasItsChecksReadAndItsPageOpened() throws {
        let alone = try server()
        let found = read(servers: [alone], checklists: FleetTrouble.checklists(of: [], servers: [alone]) { name in
            (name == "worker-3" ? stoppedHub() : nil, true)
        })
        #expect(found.unchecked.isEmpty)
        #expect(found.checksRead == 1)
        let finding = try #require(found.findings.first { $0.id == "worker-3/services" })
        #expect(finding.title == "Services · worker-3")
        #expect(finding.machine == "worker-3")
        #expect(finding.server == "worker-3")
        #expect(finding.agents.isEmpty)
        #expect(finding.takesAnAgent)
        let prompt = TroublePrompt.text(for: finding, fleet: nil, revision: nil)
        #expect(prompt.contains("\nServer: worker-3\nCheck: worker-3/services\n"))
        #expect(!prompt.contains("Agent: "))
    }

    /// Its checks stay unread until a closer look of this launch reads them, and the screen says so.
    @Test func aServerWithNoAgentThatWasNotReadIsNeverShownAsWell() throws {
        let alone = try server()
        let found = read(servers: [alone], checklists: FleetTrouble.checklists(of: [], servers: [alone]) { _ in
            (stoppedHub(), false)
        })
        #expect(found.findings.isEmpty)
        #expect(found.unchecked == ["worker-3"])
        #expect(found.summary == "Founderizer sees nothing wrong from here, and has not read the checks of worker-3 yet.")
    }

    /// A server the machine rows already name is not read twice, and keeps its agents.
    @Test func aServerWithAnAgentStaysOneServer() throws {
        let scout = try machine("scout", over: ["machine": "box"]), box = try server("box", agents: ["scout"])
        let found = read(machines: [scout], servers: [box], checklists: ["box": stoppedHub()])
        #expect(found.findings.map(\.id) == ["box/services"])
        #expect(found.findings.first?.agents == ["scout"])
        #expect(found.findings.first?.machine == "scout")
        #expect(found.checksRead == 1)
    }

    /// With the machine rows missing, the server list still gives each server its agents.
    @Test func aServerKeepsItsAgentsWhenTheMachineRowsAreMissing() throws {
        let found = read(servers: [try server("box", agents: ["scout"])], checklists: ["box": stoppedHub()])
        #expect(found.findings.first?.agents == ["scout"])
        #expect(found.findings.first?.machine == "scout")
    }

    /// No helper speaks for it, so its own reading does, by the rule of its own page (`MachineConnection.of`).
    @Test func aQuietServerWithNoAgentIsARowThatOpensItsPage() throws {
        let found = read(servers: [try server(reportedAt: 100, stale: true)], time: 1_000)
        let finding = try #require(found.findings.first)
        #expect(found.findings.count == 1)
        #expect(finding.id == "worker-3/silent")
        #expect(finding.title == "worker-3 is not answering")
        #expect(finding.says.hasPrefix("Silent since "))
        #expect(finding.machine == "worker-3")
        #expect(finding.server == "worker-3")
        #expect(finding.agents.isEmpty)
        #expect(!finding.takesAnAgent)
    }

    @Test func aServerWithNoAgentThatNeverReportedSaysThatAndNotATime() throws {
        let finding = try #require(read(servers: [try server(reportedAt: nil)]).findings.first)
        #expect(finding.says == "It has never answered.")
    }

    /// A reading of the hub that is not current says nothing about a server, and a server that reports now is well.
    @Test func onlyACurrentReadingOfTheHubCallsAServerQuiet() throws {
        #expect(read(isFresh: false, servers: [try server(reportedAt: 100, stale: true)]).findings
            .filter { $0.kind == .machine }.isEmpty)
        #expect(read(servers: [try server()]).isClear)
    }

    /// A server that never joined has no service to answer: the hub's own machine with no agent is not quiet.
    @Test func aServerThatNeverJoinedHasNoServiceToBeQuiet() throws {
        #expect(read(servers: [try server("hub", joined: false, hub: true, reportedAt: nil)]).isClear)
    }

    /// A server with an agent has its helper, and its helper's own row: its server reading adds no second one.
    @Test func aServerWithAnAgentIsNotAskedTwiceWhetherItAnswers() throws {
        #expect(read(servers: [try server("box", agents: ["scout"], reportedAt: 100, stale: true)]).isClear)
    }

    @Test func aServerWithNoAgentThatWaitsForARestartIsHisOwnStep() throws {
        let finding = try #require(read(servers: [try server(restart: true)]).findings.first)
        #expect(finding.id == "worker-3/reboot")
        #expect(finding.title == "worker-3 waits for a restart")
        #expect(finding.machine == "worker-3")
        #expect(finding.server == "worker-3")
        #expect(finding.agents.isEmpty)
        #expect(finding.ownerOnly)
        #expect(!finding.takesAnAgent)
    }

    /// An old reading says nothing about a restart: that server's row is the quiet one.
    @Test func anOldReadingOfAServerWithNoAgentOffersNoRestart() throws {
        let found = read(servers: [try server(reportedAt: 100, stale: true, restart: true)], time: 1_000)
        #expect(found.findings.map(\.id) == ["worker-3/silent"])
    }

    /// Its page offers a Mac no restart (`ServerStanding.of`), so nothing here sends him there for one.
    @Test func aMacWithNoAgentHasNoRestartRow() throws {
        #expect(read(servers: [try server(kind: "mac", restart: true)]).isClear)
    }

    /// An agent can have the name of a server it does not run on, and the two rows stay two rows.
    @Test func anAgentNamedAsAnEmptyServerKeepsARowOfItsOwn() throws {
        let found = read(health: try health(helpers: [["agent": "box", "offline": true]]),
                         machines: [try machine("box", over: ["machine": "mac-box"])],
                         servers: [try server("box", reportedAt: 100, stale: true)], time: 1_000)
        #expect(found.findings.map(\.id) == ["box/offline", "box/silent"])
        #expect(found.findings.first?.server == "mac-box")
    }

    /// With the machine rows missing, the button of a quiet agent still names its server's page.
    @Test func aQuietAgentKeepsItsServerWhenTheMachineRowsAreMissing() throws {
        let found = read(health: try health(helpers: [["agent": "studio", "offline": true]]),
                         servers: [try server("mac-studio", agents: ["studio"])])
        #expect(found.findings.first?.server == "mac-studio")
    }

    /// It takes its place among the machines that wait for the same thing, with the same words.
    @Test func aRestartOnAServerWithNoAgentJoinsTheRowOfTheOthers() throws {
        let found = read(machines: [try machine("scout", over: ["security": ["reboot_required": true]])],
                         servers: [try server(restart: true)])
        let finding = try #require(found.findings.first { $0.id == "machines/reboot" })
        #expect(finding.title == "2 servers wait for a restart")
        #expect(finding.says.hasPrefix("scout, worker-3. "))
    }

    // ------------------------------------------------------------ a cross on a server's Security row

    /// The cross sends him to this window, which said nothing about it (the owner's yes of 30 October 2026): the row
    /// says what is off, and its one button goes back to the server's page.
    @Test func aFirewallThatIsOffIsARowThatOpensItsServer() throws {
        let found = read(servers: [try server(security: ["firewall": "inactive"])])
        let finding = try #require(found.findings.first)
        #expect(found.findings.count == 1)
        #expect(finding.id == "worker-3/security")
        #expect(finding.title == "Firewall off · worker-3")
        #expect(finding.says.isEmpty)
        #expect(finding.fix == nil)
        #expect(finding.machine == "worker-3")
        #expect(finding.server == "worker-3")
        #expect(finding.agents.isEmpty)
        #expect(!finding.takesAnAgent)
    }

    @Test func aServerWithAgentsHasOneRowThatKnowsThem() throws {
        let found = read(servers: [try server("mac-studio", kind: "mac", agents: ["studio", "atlas"],
                                              security: ["firewall": "inactive", "tailscale": true])])
        let finding = try #require(found.findings.first)
        #expect(found.findings.count == 1)
        #expect(finding.title == "Firewall off · mac-studio")
        #expect(finding.machine == "studio")
        #expect(finding.server == "mac-studio")
        #expect(finding.agents == ["studio", "atlas"])
    }

    /// The row's words are the cross's: everything that is off, in one row.
    @Test func everythingThatIsOffOnOneServerIsOneRow() throws {
        let found = read(servers: [try server(security: ["tailscale": false, "firewall": "inactive",
                                                         "unattended_upgrades": false])])
        #expect(found.findings.map(\.title) == ["Private network, Firewall, Security updates off · worker-3"])
    }

    /// Automatic security updates whose last good run is older than three days have stopped (Fleet 2026.11.173 reads
    /// that run): the row says so as what it is, and a hub that reads no run, or a run of yesterday, says nothing.
    @Test func securityUpdatesThatStoppedAreSaidAsStalled() throws {
        let day = 86_400.0, now = 10 * day
        let stalled = read(servers: [try server(reportedAt: now, security: [
            "tailscale": true, "firewall": "inactive", "unattended_upgrades": true, "upgraded_at": now - 4 * day])],
                           time: now)
        #expect(stalled.findings.map(\.title) == ["Firewall off, Security updates stalled · worker-3"])
        let entry = try server(reportedAt: now, security: ["unattended_upgrades": true, "upgraded_at": now - 4 * day])
        let parts = try #require(entry.reading?.security).map { entry.securityParts($0, at: now) } ?? []
        #expect(parts.last?.on == false && parts.last?.words == "Stalled")
        for upgraded: Any in [now - day, NSNull()] {
            #expect(read(servers: [try server(reportedAt: now, security: [
                "tailscale": true, "firewall": "active", "unattended_upgrades": true, "upgraded_at": upgraded])],
                         time: now).isClear)
        }
    }

    /// What the page does not call off is no row: what is on, what nobody reported, and a Mac's security updates.
    @Test func onlyWhatThePageCallsOffIsARow() throws {
        #expect(read(servers: [try server(security: ["tailscale": true, "firewall": "active",
                                                     "unattended_upgrades": true])]).isClear)
        #expect(read(servers: [try server()]).isClear)
        #expect(read(servers: [try server(kind: "mac", security: ["unattended_upgrades": false])]).isClear)
    }

    /// An old reading says nothing about the server now, as for an agent's machine.
    @Test func anOldReadingCallsNothingOff() throws {
        let found = read(servers: [try server("box", agents: ["scout"], reportedAt: 100, stale: true,
                                              security: ["firewall": "inactive"])], time: 1_000)
        #expect(found.isClear)
    }

    /// One cause is one row: a closer look that found the firewall off says so with its fix, and what it did not find
    /// stays a row.
    @Test func aCheckThatSaysTheSameThingTakesThePartThatItSays() throws {
        let checked = VerifyChecklist(checks: [.init(check: "firewall", state: "fail", says: "The firewall is off.",
                                                     fix: "Turn the firewall on.")])
        let firewall = try server(security: ["firewall": "inactive"])
        #expect(read(servers: [firewall], checklists: ["worker-3": checked]).findings.map(\.id) == ["worker-3/firewall"])
        let both = try server(security: ["firewall": "inactive", "unattended_upgrades": false])
        #expect(read(servers: [both], checklists: ["worker-3": checked]).findings.map(\.title)
            == ["Firewall · worker-3", "Security updates off · worker-3"])
    }

    /// Only a failed check of that server takes a part, and each part goes by the check that says it.
    @Test func onlyAFailedCheckOfThatServerTakesAPart() throws {
        let firewall = try server(security: ["firewall": "inactive"])
        let passed = VerifyChecklist(checks: [.init(check: "firewall", state: "ok", says: "The firewall is on.")])
        #expect(read(servers: [firewall], checklists: ["worker-3": passed]).findings.map(\.id) == ["worker-3/security"])
        let elsewhere = VerifyChecklist(checks: [.init(check: "firewall", state: "fail", says: "The firewall is off.")])
        #expect(read(servers: [firewall], checklists: ["box": elsewhere]).findings.map(\.id) == ["worker-3/security"])
        let network = VerifyChecklist(checks: [.init(check: "tailnet", state: "fail", says: "Tailscale is not up.")])
        #expect(read(servers: [try server(security: ["tailscale": false])], checklists: ["worker-3": network])
            .findings.map(\.id) == ["worker-3/tailnet"])
    }

    /// The row comes last, so that a fleet of many servers does not push the hub's own row out of the list.
    @Test func aSecurityRowPushesNothingOutOfTheList() throws {
        let found = read(connectionError: "The hub did not answer.",
                         servers: try (1 ... 14).map { try server("worker-\($0)", security: ["firewall": "inactive"]) })
        #expect(found.findings.count == FleetTrouble.maxFindings)
        #expect(found.findings.first?.id == "hub/unreachable")
    }

    /// The window's own words are what goes with the report.
    @Test func theReportLineCarriesARowWithNoLineOfItsOwn() throws {
        let found = read(servers: [try server(security: ["firewall": "inactive"])])
        #expect(found.reportLine == "worker-3/security: Firewall off · worker-3")
    }

    // ------------------------------------------------------------ only a closer look of this launch

    /// The hub's server as a closer look found it: stopped.
    private func stoppedHub() -> VerifyChecklist {
        VerifyChecklist(checks: [.init(check: "services", state: "fail", says: "The hub is not running.",
                                       fix: "Start it again on this server.",
                                       command: "systemctl --user restart fleet-hub")], readAt: 1_000)
    }

    /// A server's page puts what a closer look found on its face only in the launch that ran it (`lookedNow`), and
    /// Report a problem reads by the same rule (review B, round 6, 30 October 2026). A failure kept from an earlier
    /// launch, the stopped hub of last week, is no finding now, and its server counts as not read.
    @Test func aFailureKeptFromAnEarlierLaunchIsNoCurrentFinding() throws {
        let manager = try machine("manager", over: ["machine": "hub"])
        let found = read(machines: [manager], checklists: FleetTrouble.checklists(of: [manager], servers: []) { server in
            (server == "hub" ? stoppedHub() : nil, false)
        })
        #expect(found.findings.isEmpty)
        #expect(found.unchecked == ["hub"])
        #expect(found.summary == "Founderizer sees nothing wrong from here, and has not read the checks of hub yet.")
    }

    /// The same failure, read by a closer look of this launch, is a finding, with its prompt.
    @Test func aFailureReadInThisLaunchIsAFinding() throws {
        let manager = try machine("manager", over: ["machine": "hub"])
        let found = read(machines: [manager], checklists: FleetTrouble.checklists(of: [manager], servers: []) { server in
            (server == "hub" ? stoppedHub() : nil, true)
        })
        #expect(found.unchecked.isEmpty)
        #expect(try #require(found.findings.first { $0.id == "hub/services" }).takesAnAgent)
    }

    @Test func howLongAgoIsSaidInWordsAndNeverAsADate() {
        #expect(FleetTrouble.ago(-5) == "just now")
        #expect(FleetTrouble.ago(30) == "less than a minute ago")
        #expect(FleetTrouble.ago(60) == "1 minute ago")
        #expect(FleetTrouble.ago(3_600) == "1 hour ago")
        #expect(FleetTrouble.ago(90_000) == "1 day ago")
    }
}
