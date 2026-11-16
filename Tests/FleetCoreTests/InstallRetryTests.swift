import Foundation
import Testing
@testable import FleetCore

/// An install that tries again by itself after an error that passes (`InstallRetry`, the plan
/// `install-auto-repair-plan.md` of 16 November 2026).
@Suite struct InstallRetryTests {
    private func decide(_ stop: InstallRecord.Stop, _ cause: InstallCause? = nil, job: InstallJob = .join,
                        step: String? = "join", tries: Int = 1, key: Bool = false, sudo: Bool = false) -> InstallRetry? {
        InstallRetry.decision(stop: stop, cause: cause, job: job, step: step, tries: tries, needsNetworkKey: key,
                              usedSudoPassword: sudo)
    }

    /// Every row of the table, with what it waits for.
    @Test func theRowsOfTheTable() {
        #expect(decide(.installerStopped, .hubBusy)?.wait == .reads(8, untilAnswer: false))
        #expect(decide(.installerStopped, .serverNameUnread)?.wait == .reads(4, untilAnswer: false))
        #expect(decide(.installerStopped, .joinCodeExpired)?.wait == InstallRetry.Wait.nothing)
        #expect(decide(.installerStopped, .hubNoAnswer)?.wait == .reads(20, untilAnswer: true))
        for cause: InstallCause in [.privateNetwork, .packages, .agentProgram] {
            #expect(decide(.installerStopped, cause, job: .join)?.wait == InstallRetry.Wait.nothing)
            #expect(decide(.installerStopped, cause, job: .hub, step: "start")?.wait == InstallRetry.Wait.nothing)
        }
        #expect(decide(.installerStopped, .codeNotFetched, job: .hub, step: "code")?.wait == InstallRetry.Wait.nothing)
        #expect(decide(.serverUnreached, job: .hub, step: "code")?.wait == InstallRetry.Wait.nothing)
        #expect(decide(.hubUnreached, step: nil)?.wait == .reads(20, untilAnswer: true))
    }

    /// A join's retry runs the same line, which the hub takes again from the same server; only an expired code gets a
    /// new one, because a new code ends every other open code of the hub.
    @Test func onlyAnExpiredCodeGetsANewOne() {
        #expect(decide(.installerStopped, .joinCodeExpired)?.freshCode == true)
        for cause: InstallCause in [.hubBusy, .serverNameUnread, .hubNoAnswer, .privateNetwork, .packages, .agentProgram] {
            #expect(decide(.installerStopped, cause)?.freshCode == false, "\(cause)")
        }
        #expect(decide(.hubUnreached, step: nil)?.freshCode == false)
    }

    /// A kept code runs again only while it has ten minutes left, by the end that the hub gave with it.
    @Test func aKeptCodeNeedsTenMinutesLeft() {
        let now = 1_794_844_034.0
        #expect(InstallRetry.codeLeftAtLeast == 600)
        #expect(InstallRetry.keepsCode(expiresAt: now + 1800, now: now))
        #expect(InstallRetry.keepsCode(expiresAt: now + 600, now: now))
        #expect(!InstallRetry.keepsCode(expiresAt: now + 599, now: now))
        #expect(!InstallRetry.keepsCode(expiresAt: now - 1, now: now))
        #expect(!InstallRetry.keepsCode(expiresAt: 0, now: now))
    }

    /// What needs the owner, what only a join can wait for, and a join's code from a hub that a policy blocks: no retry.
    @Test func whatIsNeverTriedAgain() {
        let never: [InstallCause] = [.needsRoot, .systemNotSupported, .noSystemd, .homebrew, .wrongMacUser,
                                     .serverNameRefused, .joinCodeRefused, .hubClaim, .firewall, .vault, .agentUsers,
                                     .service, .updates, .other]
        for cause in never {
            #expect(decide(.installerStopped, cause) == nil, "\(cause)")
            #expect(decide(.installerStopped, cause, job: .hub, step: "start") == nil, "\(cause)")
        }
        #expect(decide(.installerStopped, .codeNotFetched, job: .join) == nil)
        #expect(decide(.installerStopped, nil) == nil)
        // The rows that read the hub are a join's: a hub's own install has no hub to read before its claim.
        for cause: InstallCause in [.hubBusy, .serverNameUnread, .joinCodeExpired, .hubNoAnswer] {
            #expect(decide(.installerStopped, cause, job: .hub, step: "start") == nil, "\(cause)")
        }
        #expect(decide(.hubUnreached, job: .hub, step: "claim") == nil)
        for stop: InstallRecord.Stop in [.cannotStart, .loginRefused, .stepFailed, .hubNotOurs, .notRoot, .timedOut,
                                         .noClaimCode, .noChecklist, .checkStopped, .needsSudoPassword,
                                         .needsSSHPassword, .networkKeyRefused, .hubRefused, .macRefused,
                                         .macUnreachable, .macUnreadable, .other] {
            #expect(decide(stop) == nil, "\(stop)")
        }
    }

    /// SSH lost runs again only at the hub's `code` and `plan`, where what the lost run left running on the server does
    /// no harm beside a second run: never at `network`, whose `tailscale up` a second one would meet with a new key, nor
    /// after an installer started (`start` runs `hub.sh` detached, `join` runs `join.sh`, and neither takes a lock); a
    /// `read` that failed waited for the server already.
    @Test func aLostServerOnlyAtTheHubsCodeAndPlan() {
        for step in ["code", "plan"] { #expect(decide(.serverUnreached, job: .hub, step: step) != nil, "\(step)") }
        for step in ["read", "network", "start", "wait_claim", "claim", "wait_ready", "verify", "join", "order",
                     "other"] {
            #expect(decide(.serverUnreached, step: step) == nil, "\(step)")
            #expect(decide(.serverUnreached, job: .hub, step: step) == nil, "\(step)")
        }
        #expect(decide(.serverUnreached, step: nil) == nil)
    }

    /// Two retries after the press, so three tries in all; a stop that needs the owner's Tailscale key, and a press
    /// that gave a sudo password, get none.
    @Test func theCountTheKeyAndThePassword() {
        #expect(InstallRetry.most == 2)
        #expect(decide(.installerStopped, .hubBusy, tries: 1) != nil)
        #expect(decide(.installerStopped, .hubBusy, tries: 2) != nil)
        #expect(decide(.installerStopped, .hubBusy, tries: 3) == nil)
        #expect(decide(.installerStopped, .privateNetwork, key: true) == nil)
        #expect(decide(.installerStopped, .packages, sudo: true) == nil)
        #expect(decide(.serverUnreached, job: .hub, step: "code", sudo: true) == nil)
    }

    /// The name that the record keeps: the cause where the installer gave one, else the stop's kind.
    @Test func theNameThatTheRecordKeeps() {
        #expect(InstallRetry.name(stop: .installerStopped, cause: .hubBusy) == "hub_busy")
        #expect(InstallRetry.name(stop: .serverUnreached, cause: nil) == "server_unreached")
    }

    /// The new causes read from their sentences, before the rows that share words with them: the hub's refusals of
    /// `join_server`, and the package stops of `join.sh`, `hub.sh` and this app's own steps.
    @Test func theNewCausesReadFromTheirSentences() {
        #expect(InstallCause.of(sentence: "The join code expired. Make a new line in Founderizer.") == .joinCodeExpired)
        #expect(InstallCause.of(sentence: "The join code is not valid.") == .joinCodeRefused)
        #expect(InstallCause.of(sentence: "Too many wrong join codes from this address. Wait 10 minutes, then try again.")
                == .joinCodeRefused)
        #expect(InstallCause.of(sentence: "The hub could not read this server's name in Tailscale. Run the line again in "
                                + "a minute; the code stays valid.") == .serverNameUnread)
        #expect(InstallCause.of(sentence: "The package lists could not be updated: apt-get update did not finish. A "
                                + "package mirror can fail for a moment: run the line again.") == .packages)
        #expect(InstallCause.of(sentence: "The packages of this system could not be installed: apt-get install did not "
                                + "finish. A package mirror can fail for a moment: run the line again.") == .packages)
        #expect(InstallCause.of(sentence: "Could not install Tailscale on this server: its installer did not finish. A "
                                + "package mirror can fail for a moment: run the line again.") == .privateNetwork)
        #expect(InstallCause.of(sentence: "Could not clone the Founderizer repository from its address: git did not "
                                + "finish. Check the address, then run the line again.") == .codeNotFetched)
    }

    /// This app's own steps print the installers' stop mark with sentences that their causes read, where they ended
    /// before with a line of apt's, git's or the shell's (`step_failed`).
    @Test func theAppsOwnStepsStopWithASentence() {
        for (stop, cause) in [(InstallPlan.packagesStop, InstallCause.packages), (InstallPlan.cloneStop, .codeNotFetched),
                              (InstallPlan.tailscaleThere, .privateNetwork),
                              (InstallPlan.tailscaleStop(removing: InstallPlan.authKeyFile), .privateNetwork)] {
            let echoed = stop.components(separatedBy: "echo '").dropFirst().first?.components(separatedBy: "'").first ?? ""
            let error = InstallError.step("The step", echoed)
            #expect(InstallRecord.Stop.of(error) == .installerStopped, "\(stop)")
            #expect(InstallCause.of(error) == cause, "\(stop)")
            #expect(stop.filter { $0 == "'" }.count == 2, "no quote inside the single quotes: \(stop)")
        }
    }

    /// One record for the press: each retry counts the try, keeps the name of its stop and starts the steps again; the
    /// fields survive the record's file, and an older record has none.
    @Test func theRecordCountsTheTries() throws {
        var log = InstallLog(kind: .join, hub: "http://100.64.0.1:8765/", host: "203.0.113.9")
        log.note(step: "read", state: .done)
        log.note(step: "join", state: .failed)
        let first = log.retry(after: .installerStopped, cause: .hubBusy)
        #expect(first)
        #expect(log.record.tries == 2 && log.record.retried == ["hub_busy"] && log.record.steps.isEmpty)
        log.note(step: "read", state: .running)
        #expect(log.record.steps.count == 1)
        let second = log.retry(after: .serverUnreached, cause: nil)
        #expect(second)
        #expect(log.record.tries == 3 && log.record.retried == ["hub_busy", "server_unreached"])
        log.stop(.installerStopped, says: nil, cause: .packages)
        let afterStop = log.retry(after: .installerStopped, cause: .packages)
        #expect(!afterStop)
        let data = try JSONEncoder().encode(log.record)
        let back = try JSONDecoder().decode(InstallRecord.self, from: data)
        #expect(back.tries == 3 && back.retried == ["hub_busy", "server_unreached"])
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["tries"] = nil
        json["retried"] = nil
        let older = try JSONDecoder().decode(InstallRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.tries == nil && older.retried == nil)
    }

    /// The agent reads the tries and the earlier stops by their fixed names only: a name that is neither a cause nor a
    /// stop's kind (a record file that something else wrote) is not passed on.
    @Test func theAgentReadsTheTries() throws {
        var log = InstallLog(kind: .join, hub: "http://100.64.0.1:8765/", host: "203.0.113.9")
        log.retry(after: .installerStopped, cause: .packages)
        log.stop(.installerStopped, says: nil, cause: .packages)
        let last = ReachFacts.lastInstall(log.record)
        #expect(last.tries == 2 && last.retried == ["packages"])
        var record = log.record
        record.retried = ["packages", "rm -rf /"]
        #expect(ReachFacts.lastInstall(record).retried == ["packages"])
        #expect(ReachFacts.lastInstall(InstallRecord(kind: .join, hub: nil, host: "203.0.113.9")).tries == 1)
    }

    /// Every row that retries gives way to the owner's Tailscale key, to a press that gave a sudo password, and to the
    /// count.
    @Test func everyRowGivesWayToTheKeyThePasswordAndTheCount() {
        let rows: [(InstallRecord.Stop, InstallCause?, InstallJob, String?)] = [
            (.installerStopped, .hubBusy, .join, "join"), (.installerStopped, .serverNameUnread, .join, "join"),
            (.installerStopped, .joinCodeExpired, .join, "join"), (.installerStopped, .hubNoAnswer, .join, "join"),
            (.installerStopped, .privateNetwork, .join, "network"), (.installerStopped, .packages, .hub, "start"),
            (.installerStopped, .agentProgram, .join, "join"), (.installerStopped, .codeNotFetched, .hub, "code"),
            (.serverUnreached, nil, .hub, "code"), (.serverUnreached, nil, .hub, "plan"),
            (.hubUnreached, nil, .join, nil)]
        for (stop, cause, job, step) in rows {
            let row = "\(stop) \(cause.map(\.rawValue) ?? "none") \(job)"
            #expect(decide(stop, cause, job: job, step: step) != nil, "\(row)")
            #expect(decide(stop, cause, job: job, step: step, tries: 2) != nil, "\(row)")
            #expect(decide(stop, cause, job: job, step: step, tries: 3) == nil, "\(row)")
            #expect(decide(stop, cause, job: job, step: step, key: true) == nil, "\(row)")
            #expect(decide(stop, cause, job: job, step: step, sudo: true) == nil, "\(row)")
        }
    }

    /// The stops stand in the plans' own steps: the hub's `code` step (git's install, the clone), the keyed network
    /// step of both plans, and the start of the sign-in.
    @Test func theStopsStandInThePlansSteps() throws {
        let target = InstallTarget(host: "198.51.100.7")
        let hub = InstallPlan.hub(target: target, source: "https://example.com/fleet.git", authKey: "key")
        guard case .run(let code) = try #require(hub.steps.first { $0.id == "code" }).action else {
            Issue.record("no code step to run"); return
        }
        #expect(code.contains(" || { \(InstallPlan.packagesStop); }; "))
        #expect(code.contains(" || { \(InstallPlan.cloneStop); }; "))
        let join = InstallPlan.join(target: target, line: "", code: "", authKey: "key")
        for plan in [hub, join] {
            guard case .sendAuthKey(let network) = try #require(plan.steps.first { $0.id == "network" }).action else {
                Issue.record("no keyed network step"); return
            }
            #expect(network.contains(InstallPlan.tailscaleInstall
                                     + InstallPlan.tailscaleStop(removing: InstallPlan.authKeyFile)))
        }
        let signIn = InstallPlan.join(target: target, line: "", code: "", authKey: nil)
        guard case .signIn(let start, _, _, _) = try #require(signIn.steps.first { $0.id == "network" }).action else {
            Issue.record("no sign-in step"); return
        }
        #expect(start.hasPrefix(InstallPlan.tailscaleInstall + InstallPlan.tailscaleThere))
    }

    /// What a decision reads of the error that ended a try, as the page's stop reads it.
    @Test func whatADecisionReadsOfTheError() {
        let packages = InstallError.step("Install the hub", "Founderizer install stopped: The package lists could not be "
            + "updated: apt-get update did not finish. A package mirror can fail for a moment: run the line again.")
        #expect(InstallRetry.stopped(by: packages, networkKeyRefused: false, authKeyEmpty: true)
                == .init(stop: .installerStopped, cause: .packages, needsNetworkKey: false))
        let noKey = InstallError.step("The private network", NetworkSignIn.notOnNetwork)
        #expect(InstallRetry.stopped(by: noKey, networkKeyRefused: false, authKeyEmpty: true).needsNetworkKey)
        #expect(!InstallRetry.stopped(by: noKey, networkKeyRefused: false, authKeyEmpty: false).needsNetworkKey)
        let refused = InstallRetry.stopped(by: noKey, networkKeyRefused: true, authKeyEmpty: false)
        #expect(refused.stop == .networkKeyRefused && refused.needsNetworkKey)
    }

    /// The wait makes its count of reads, ends at the first answer when it waits for one, ends at a cancel before its
    /// next read, and makes no read when it waits for nothing.
    @Test func theWaitMakesItsCountOfReads() async {
        var pauses = 0, reads = 0
        await InstallRetry.wait(.reads(8, untilAnswer: false), pause: { pauses += 1 },
                                read: { reads += 1; return true }, cancelled: { false })
        #expect(pauses == 8 && reads == 8)
        pauses = 0; reads = 0
        await InstallRetry.wait(.reads(20, untilAnswer: true), pause: { pauses += 1 },
                                read: { reads += 1; return reads == 3 }, cancelled: { false })
        #expect(pauses == 3 && reads == 3)
        pauses = 0; reads = 0
        await InstallRetry.wait(.reads(20, untilAnswer: true), pause: { pauses += 1 },
                                read: { reads += 1; return false }, cancelled: { false })
        #expect(pauses == 20 && reads == 20)
        pauses = 0; reads = 0
        await InstallRetry.wait(.reads(8, untilAnswer: false), pause: { pauses += 1 },
                                read: { reads += 1; return false }, cancelled: { pauses == 2 })
        #expect(pauses == 2 && reads == 1)
        pauses = 0; reads = 0
        await InstallRetry.wait(.nothing, pause: { pauses += 1 }, read: { reads += 1; return true },
                                cancelled: { false })
        #expect(pauses == 0 && reads == 0)
    }

    /// The record keeps the names of the last two retries, and no retry comes after a cancel or an end.
    @Test func theRecordKeepsTheLastTwoAndNothingAfterTheEnd() {
        var log = InstallLog(kind: .hub, hub: nil, host: "203.0.113.9")
        for cause: InstallCause in [.packages, .privateNetwork, .agentProgram] {
            let retried = log.retry(after: .installerStopped, cause: cause)
            #expect(retried)
        }
        #expect(log.record.tries == 4 && log.record.retried == ["private_network", "agent_program"])
        var cancelled = InstallLog(kind: .join, hub: "http://100.64.0.1:8765/", host: "203.0.113.9")
        let ended = cancelled.cancel()
        let afterCancel = cancelled.retry(after: .installerStopped, cause: .hubBusy)
        #expect(ended && !afterCancel && cancelled.record.tries == nil && cancelled.record.retried == nil)
        var done = InstallLog(kind: .join, hub: "http://100.64.0.1:8765/", host: "203.0.113.9")
        let finished = done.done()
        let afterDone = done.retry(after: .serverUnreached, cause: nil)
        #expect(finished && !afterDone && done.record.tries == nil)
    }

    /// The facts of the page's install count one try at least and three at most, whatever the model holds.
    @Test func theInstallFactsCountOneToThreeTries() {
        func tries(_ held: Int) -> Int? {
            ReachFacts.install(.init(way: "linux", running: true, failed: false, ended: false, job: "join", steps: [],
                                     planned: ["read", "network", "join", "verify"], runningStep: "read",
                                     since: Date(timeIntervalSince1970: 0), stop: nil, waitsForNetwork: false,
                                     tries: held))?.tries
        }
        #expect(tries(0) == 1 && tries(1) == 1 && tries(2) == 2 && tries(3) == 3 && tries(9) == 3)
        var record = InstallRecord(kind: .join, hub: nil, host: "203.0.113.9")
        record.tries = 0
        #expect(ReachFacts.lastInstall(record).tries == 1)
        record.tries = 9
        #expect(ReachFacts.lastInstall(record).tries == 3)
    }

    /// **The keyed step leaves no key file when Tailscale did not install**: its own stop ends the step before the
    /// `rm -f` after `tailscale up`, so the stop removes the file first (a review of 16 November 2026). Under dash, with
    /// stand-ins: an `apt-get` and a `curl` that give nothing, a `sleep` that does not wait, and no `tailscale`.
    @Test func theKeyedStepLeavesNoKeyFileWhenTailscaleDidNotInstall() throws {
        guard case .sendAuthKey(let step) = InstallPlan.keyedNetwork else {
            Issue.record("the keyed network step sends no key"); return
        }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fleet-retry-" + UUID().uuidString)
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["apt-get", "curl", "sleep"] {
            let program = bin.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: program, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        }
        let keyFile = folder.appendingPathComponent("fleet-authkey"), input = folder.appendingPathComponent("input")
        try "tskey-auth-k0000-secret\n".write(to: input, atomically: true, encoding: .utf8)
        let shell = Process(), out = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/dash")
        shell.arguments = ["-c", step.replacingOccurrences(of: InstallPlan.authKeyFile, with: keyFile.path)]
        shell.environment = ["PATH": bin.path + ":/bin"]
        shell.standardInput = try FileHandle(forReadingFrom: input)
        shell.standardOutput = out; shell.standardError = out
        try shell.run(); shell.waitUntilExit()
        let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(shell.terminationStatus == 1, "\(said)")
        #expect(said.contains("Founderizer install stopped: Could not install Tailscale on this server"), "\(said)")
        #expect(!FileManager.default.fileExists(atPath: keyFile.path), "the key file stayed: \(said)")
    }

    /// The step that a run stopped at is noted where the installer reports it, from the installer's own context: a
    /// running and a done report leave it, a failed one sets it.
    @Test func theFailedStepIsNotedWhereTheInstallerReportsIt() async {
        let failed = InstallRetry.FailedStep()
        #expect(failed.value == nil)
        await Task.detached {
            failed.note(InstallProgress(step: "read", title: "Example", says: "", state: .running))
            failed.note(InstallProgress(step: "read", title: "Example", says: "", state: .done))
            failed.note(InstallProgress(step: "code", title: "Example", says: "", state: .running))
        }.value
        #expect(failed.value == nil)
        await Task.detached {
            failed.note(InstallProgress(step: "code", title: "Example", says: "", state: .failed))
        }.value
        #expect(failed.value == "code")
    }
}
