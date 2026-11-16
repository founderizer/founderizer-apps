#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// **The kept record of an install** (`InstallRecord`, `InstallLog`, `InstallRecords`): what it holds of each step and
/// of a stop, what it never holds, and how its folder gives it back after the page, the app or its version is gone.
/// Each test has a scratch folder of its own and removes it.
struct InstallRecordTests {
    private final class Scratch {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("install-records-\(UUID().uuidString)")
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    private let hub = "http://100.64.0.7:8765/"
    /// A time with whole milliseconds, as a file gives it back.
    private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    private func newLog(_ kind: InstallRecord.Kind = .join, hub: String? = "http://100.64.0.7:8765/", launch: String = "now",
                     at seconds: Double = 0) -> InstallLog {
        InstallLog(kind: kind, hub: hub, host: "203.0.113.9", launch: launch, at: time(seconds))
    }

    // MARK: the fixed names

    /// Each step of the two plans has its own fixed name, and a name that is not on the list is `other`.
    @Test func everyStepOfTheTwoPlansIsOnTheList() {
        let target = InstallTarget(host: "203.0.113.9")
        let plans = [InstallPlan.hub(target: target, source: InstallPlan.defaultSource, authKey: nil),
                     InstallPlan.join(target: target, line: "sh join.sh", code: "ABCDEFGH", authKey: nil)]
        for step in plans.flatMap(\.steps) {
            #expect(InstallRecord.StepID(named: step.id) != .other, "\(step.id)")
            #expect(InstallRecord.StepID(named: step.id).rawValue == step.id)
        }
        #expect(InstallRecord.StepID(named: "brew") == .other)
        #expect(InstallRecord.StepID(named: "order") == .order)
        #expect(InstallRecord.stepIDs == ["read", "network", "code", "plan", "start", "wait_claim", "claim", "wait_ready",
                                         "verify", "join", "order", "other"])
    }

    /// The names that a reader for another program gives out are lower-case words with underscores, and none repeats.
    @Test func theFixedNamesAreSnakeCase() {
        let names = InstallRecord.Kind.allCases.map(\.rawValue) + InstallRecord.Outcome.allCases.map(\.rawValue)
            + InstallRecord.Stop.allCases.map(\.rawValue) + InstallRecord.StepState.allCases.map(\.rawValue)
            + InstallRecord.stepIDs
        for name in names {
            #expect(name.range(of: "^[a-z]+(_[a-z]+)*$", options: .regularExpression) != nil, "\(name)")
        }
        #expect(Set(InstallRecord.Stop.allCases.map(\.rawValue)).count == InstallRecord.Stop.allCases.count)
        #expect(Set(InstallRecord.stepIDs).count == InstallRecord.stepIDs.count)
    }

    // MARK: the kind of a stop

    /// A step's words give the same kind that the page's own line says (`InstallError.plain` reads them in this order).
    @Test func aStepThatFailedHasTheKindOfItsWords() {
        func step(_ says: String) -> InstallRecord.Stop { .of(InstallError.step("Join the fleet", says)) }
        #expect(step("Founderizer join stopped: this server has too little memory.") == .installerStopped)
        #expect(step("Fleet install stopped: no Tailscale auth key came in.") == .installerStopped)
        #expect(step("ssh: connect to host 203.0.113.9 port 22: Connection refused") == .serverUnreached)
        #expect(step("The server answered 255.") == .serverUnreached)
        #expect(step("root@203.0.113.9: Permission denied (publickey).") == .loginRefused)
        #expect(step("E: Unable to locate package") == .stepFailed)
    }

    /// Words that fit two kinds take the kind that the page's line takes: the installer's stop mark before a server
    /// not reached, and a server not reached before a key not taken. A stop mark with no reason after it is no
    /// installer's stop, as the page's line reads it. Each kind is held to the page's own line for the same words.
    @Test func wordsThatFitTwoKindsTakeThePagesKind() {
        func step(_ says: String) -> InstallError { .step("Join the fleet", says) }
        // Each of these two meets the stop mark and one more check: the mark is read first.
        let marked = step("Founderizer join stopped: the server answered 255.")
        #expect(InstallError.unreached("founderizer join stopped: the server answered 255."))
        #expect(InstallRecord.Stop.of(marked) == .installerStopped)
        #expect(marked.plain(host: "203.0.113.9", place: nil) == "The server answered 255.")
        let markedKey = step("Founderizer join stopped: Permission denied (publickey).")
        #expect(InstallError.keyRefused("Founderizer join stopped: Permission denied (publickey)."))
        #expect(InstallRecord.Stop.of(markedKey) == .installerStopped)
        #expect(markedKey.plain(host: "203.0.113.9", place: nil) == "Permission denied (publickey).")
        let both = step("ssh: connect to host 203.0.113.9 port 22: Operation timed out; Permission denied (publickey).")
        #expect(InstallRecord.Stop.of(both) == .serverUnreached)
        #expect(both.plain(host: "203.0.113.9", place: nil) != ServerCheck.keyRefused("203.0.113.9"))
        let bare = step("Founderizer install stopped:")
        #expect(InstallRecord.Stop.of(bare) == .stepFailed)
        #expect(bare.plain(host: "203.0.113.9", place: nil) == "It stopped at “Join the fleet”.")
        let refused = step("root@203.0.113.9: Permission denied (publickey).")
        #expect(refused.plain(host: "203.0.113.9", place: nil) == ServerCheck.keyRefused("203.0.113.9"))
    }

    /// The line that a record keeps is the page's own line only where its words are this app's own: none for the
    /// installer's own reason, which the server printed, and none for the words of a hub, Tailscale or a Mac's installer.
    @Test func onlyTheAppsOwnWordsAreKept() {
        let host = "203.0.113.9"
        let installers = InstallError.step("Join the fleet", "Founderizer join stopped: Traceback: /root/secret.txt")
        #expect(InstallRecord.words(of: installers, host: host) == nil)
        let refused = InstallError.step("Join the fleet", "root@203.0.113.9: Permission denied (publickey).")
        #expect(InstallRecord.words(of: refused, host: host) == ServerCheck.keyRefused(host))
        #expect(InstallRecord.words(of: InstallError.step("Join the fleet", "E: Unable to locate package"), host: host)
            == "It stopped at “Join the fleet”.")
        #expect(InstallRecord.words(of: InstallError.noClaimCode, host: host) == InstallError.noClaimCode.errorDescription)
        #expect(InstallRecord.words(of: MacLinkError.refused("Homebrew printed this."), host: host) == nil)
        #expect(InstallRecord.words(of: HubError.refusal(HubRefusal(status: 403, hubWords: "owner only")), host: host) == nil)
        #expect(InstallRecord.words(of: URLError(.timedOut), host: host) == nil)
    }

    @Test func everyOtherErrorHasItsOwnKind() {
        #expect(InstallRecord.Stop.of(InstallError.cannotStart("The hub gave no join line. Try again.")) == .cannotStart)
        #expect(InstallRecord.Stop.of(InstallError.notRoot("ada")) == .notRoot)
        #expect(InstallRecord.Stop.of(InstallError.timedOut("Finish the install")) == .timedOut)
        #expect(InstallRecord.Stop.of(InstallError.noClaimCode) == .noClaimCode)
        #expect(InstallRecord.Stop.of(InstallError.noChecklist) == .noChecklist)
        #expect(InstallRecord.Stop.of(InstallError.checkStopped("This install needs Ubuntu.")) == .checkStopped)
        #expect(InstallRecord.Stop.of(InstallError.needsPassword(.sudo)) == .needsSudoPassword)
        #expect(InstallRecord.Stop.of(InstallError.needsPassword(.ssh)) == .needsSSHPassword)
        #expect(InstallRecord.Stop.of(MacLinkError.refused("Homebrew did not install.")) == .macRefused)
        #expect(InstallRecord.Stop.of(MacLinkError.unreachable) == .macUnreachable)
        #expect(InstallRecord.Stop.of(MacLinkError.unreadable) == .macUnreadable)
        #expect(InstallRecord.Stop.of(MacLinkError.notAnAddress) == .cannotStart)
        #expect(InstallRecord.Stop.of(HubError.unavailable) == .hubUnreached)
        #expect(InstallRecord.Stop.of(HubError.refusal(HubRefusal(status: 403, hubWords: "owner only"))) == .hubRefused)
        #expect(InstallRecord.Stop.of(HubError.invalidAddress) == .hubRefused)
        #expect(InstallRecord.Stop.of(HubError.invalidResponse) == .hubRefused)
        #expect(InstallRecord.Stop.of(URLError(.timedOut)) == .hubUnreached)
        #expect(InstallRecord.Stop.of(CancellationError()) == .other)
    }

    // MARK: one install, step by step

    /// A step has the time it began and the time it ended; a report that changes no state changes nothing, so a line
    /// that a step printed writes nothing.
    @Test func aStepKeepsItsStateAndItsTimes() {
        var log = newLog()
        do { let changed = log.note(step: "read", state: .running, at: time(1)); #expect(changed) }
        do { let changed = log.note(step: "read", state: .running, at: time(2)); #expect(!changed) }
        do { let changed = log.note(step: "read", state: .done, at: time(3)); #expect(changed) }
        do { let changed = log.note(step: "read", state: .done, at: time(4)); #expect(!changed) }
        do { let changed = log.note(step: "network", state: .running, at: time(5)); #expect(changed) }
        #expect(log.record.steps == [.init(id: .read, state: .done, began: time(1), ended: time(3)),
                                     .init(id: .network, state: .running, began: time(5), ended: nil)])
        #expect(log.record.outcome == .running && log.record.stoppedAt == nil && log.record.ended == nil)
        #expect(log.record.lastChange == time(5))
    }

    /// Two steps of a Mac's installer that the list does not have are two steps of the record, each with its own times.
    @Test func twoUnknownStepsStayTwoSteps() {
        var log = newLog(.mac)
        log.note(step: "brew", state: .running, at: time(1))
        log.note(step: "brew", state: .done, at: time(2))
        log.note(step: "launch-agents", state: .running, at: time(3))
        log.note(step: "launch-agents", state: .failed, at: time(4))
        #expect(log.record.steps.map(\.id) == [.other, .other])
        #expect(log.record.steps.map(\.state) == [.done, .failed])
        #expect(log.record.steps[1].began == time(3) && log.record.steps[1].ended == time(4))
    }

    /// A stop keeps its kind, the step it stopped at and the page's own line. The step's failed report can come after
    /// the stop, as the installer's reports do, and the step that the install stopped at is the same before and after.
    @Test func aStopKeepsItsKindItsStepAndThePagesLine() {
        var log = newLog()
        log.note(step: "read", state: .done, at: time(1))
        log.note(step: "join", state: .running, at: time(2))
        do { let changed = log.stop(.serverUnreached, says: "This Mac could not reach 203.0.113.9 over SSH.", waitsForNetwork: false, at: time(9)); #expect(changed) }
        #expect(log.record.outcome == .stopped && log.record.stop == .serverUnreached)
        #expect(log.record.stoppedAt == .join && log.record.ended == time(9))
        #expect(log.record.says == "This Mac could not reach 203.0.113.9 over SSH.")
        do { let changed = log.note(step: "join", state: .failed, at: time(9.5)); #expect(changed) }
        #expect(log.record.outcome == .stopped && log.record.stoppedAt == .join)
    }

    /// A stop before any step (no key from Tailscale, no join line from the hub) has no step, and still its kind.
    @Test func aStopBeforeTheFirstStepHasNoStep() {
        var log = newLog()
        log.stop(.networkKeyRefused, says: nil, waitsForNetwork: true, at: time(1))
        #expect(log.record.stoppedAt == nil && log.record.stop == .networkKeyRefused)
        #expect(log.record.waitsForNetwork && log.record.says == nil && log.record.steps.isEmpty)
    }

    /// The one kept line never holds a key or a join code that the plan hides, is one line, and has a fixed length at
    /// most. A string too short to be a secret is not taken out, as in the plan's own rule.
    @Test func theKeptLineHoldsNoSecretOfThePlan() throws {
        let key = "tskey-auth-kAUTH1234CNTRL-notarealkey", code = "QRSTUVWX"
        let plan = InstallPlan.join(target: InstallTarget(host: "203.0.113.9"), line: "sh join.sh \(code)", code: code,
                                    authKey: key)
        var log = newLog()
        log.hide(plan.redactions)
        log.hide(["abc"])
        log.stop(.installerStopped, says: "The key \(key) and the code \(code)\ndid not work for abc.", at: time(1))
        #expect(log.record.says == "The key (not shown) and the code (not shown) did not work for abc.")
        let data = try JSONEncoder().encode(log.record)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(key) && !text.contains(code))

        var long = newLog()
        long.stop(.stepFailed, says: String(repeating: "word ", count: 200), at: time(1))
        #expect(long.record.says?.count == InstallRecord.saysLimit)
    }

    /// The log lets go of the plan's secrets at the install's end, and takes none after it: a line that is kept later
    /// (a Mac's install that goes on, and stops again) is cleaned only of what was hidden again since.
    @Test func theLogLetsGoOfItsSecretsAtTheEnd() {
        let code = "QRSTUVWX"
        var log = newLog(.mac)
        log.hide([code])
        log.stop(.macRefused, says: nil, at: time(1))
        log.hide(["ZZZZYYYY"])                      // after the end: not taken
        log.goOn()
        log.stop(.cannotStart, says: "The codes \(code) and ZZZZYYYY.", at: time(2))
        #expect(log.record.says == "The codes \(code) and ZZZZYYYY.")
        log.goOn()
        log.hide([code])
        log.stop(.cannotStart, says: "The codes \(code) and ZZZZYYYY.", at: time(3))
        #expect(log.record.says == "The codes (not shown) and ZZZZYYYY.")
    }

    /// The record's file has these fields and no other: no field for a user, a port, a path of a key or a step's lines.
    @Test func theRecordHasItsFieldsAndNoOther() throws {
        var log = newLog()
        log.note(step: "read", state: .done, at: time(1))
        log.place(server: "worker-2")
        log.stop(.serverUnreached, says: "This Mac could not reach 203.0.113.9 over SSH.", at: time(2))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(log.record)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["id", "kind", "launch", "hub", "host", "server", "steps", "began",
                                                      "ended", "outcome", "stop", "waitsForNetwork", "says"])
        let step = (object?["steps"] as? [[String: Any]])?.first
        #expect(Set(step?.keys.map { $0 } ?? []) == ["id", "state", "began", "ended"])
    }

    /// An install that ended well has no stop; the hub's address, the address reached and the server's name come when
    /// they are known.
    @Test func anInstallThatEndedWellHasNoStop() {
        var log = newLog(.hub, hub: nil)
        #expect(log.record.hub == nil)
        log.note(step: "claim", state: .done, at: time(1))
        do { let changed = log.place(hub: hub); #expect(changed) }
        do { let changed = log.place(hub: hub); #expect(!changed) }
        do { let changed = log.place(host: "100.64.0.7", server: "hub"); #expect(changed) }
        do { let changed = log.place(hub: "", host: "", server: nil); #expect(!changed) }
        do { let changed = log.done(at: time(5)); #expect(changed) }
        #expect(log.record.outcome == .done && log.record.stop == nil && log.record.stoppedAt == nil)
        #expect(log.record.hub == hub && log.record.host == "100.64.0.7" && log.record.server == "hub")
        #expect(log.record.ended == time(5))
    }

    /// The page ended an install that ran: it is cancelled, and the error of the work that was cut off is no stop. An
    /// install that ended already keeps its end.
    @Test func aCancelledInstallStaysCancelled() {
        var log = newLog()
        log.note(step: "network", state: .running, at: time(1))
        do { let changed = log.cancel(at: time(2)); #expect(changed) }
        do { let changed = log.stop(.other, says: nil, at: time(3)); #expect(!changed) }
        #expect(log.record.outcome == .cancelled && log.record.stop == nil && log.record.stoppedAt == .network)
        #expect(log.record.ended == time(2))

        var stopped = newLog()
        stopped.stop(.timedOut, says: nil, at: time(1))
        do { let changed = stopped.cancel(at: time(2)); #expect(!changed) }
        #expect(stopped.record.outcome == .stopped && stopped.record.ended == time(1))
    }

    /// A Mac's installer that goes on after its stop is the same install, running again, and can end well.
    @Test func aMacsInstallGoesOnAfterItsStop() {
        var log = newLog(.mac)
        log.note(step: "brew", state: .failed, at: time(1))
        log.stop(.macRefused, says: nil, at: time(1))
        #expect(log.record.stoppedAt == .other)
        do { let changed = log.goOn(); #expect(changed) }
        do { let changed = log.goOn(); #expect(!changed) }
        #expect(log.record.outcome == .running && log.record.stop == nil && log.record.ended == nil)
        // The step that failed runs again, so a later stop names the step that it stopped at then.
        #expect(log.record.steps[0].state == .running && log.record.steps[0].ended == nil)
        do { let changed = log.note(step: "brew", state: .running, at: time(2)); #expect(!changed) }
        log.note(step: "brew", state: .done, at: time(3))
        log.note(step: "order", state: .running, at: time(3))
        log.stop(.macRefused, says: nil, at: time(3.5))
        #expect(log.record.stoppedAt == .order)
        log.goOn()
        log.done(at: time(4))
        #expect(log.record.outcome == .done && log.record.steps.map(\.state) == [.done, .done])
        #expect(log.record.steps[1].ended == time(4))
    }

    /// Only an install that runs ends well: one that stopped, or that its page ended, keeps its end.
    @Test func onlyAnInstallThatRunsEndsWell() {
        var stopped = newLog()
        stopped.stop(.timedOut, says: nil, at: time(1))
        do { let changed = stopped.done(at: time(2)); #expect(!changed) }
        #expect(stopped.record.outcome == .stopped && stopped.record.ended == time(1))
        var cancelled = newLog()
        cancelled.cancel(at: time(1))
        do { let changed = cancelled.done(at: time(2)); #expect(!changed) }
        #expect(cancelled.record.outcome == .cancelled)
    }

    /// A Mac's installer names its own steps: a record keeps a fixed number of them at most, and a server's name a
    /// fixed length at most.
    @Test func aRecordKeepsAFixedNumberOfStepsAndAShortName() {
        var log = newLog(.mac)
        for number in 0..<(InstallRecord.mostSteps + 10) { log.note(step: "step-\(number)", state: .done, at: time(1)) }
        #expect(log.record.steps.count == InstallRecord.mostSteps)
        do { let changed = log.note(step: "one-more", state: .running, at: time(2)); #expect(!changed) }
        log.place(server: String(repeating: "n", count: 500))
        #expect(log.record.server?.count == InstallRecord.nameLimit)
    }

    /// A record that a later version of the app wrote, with a step and a kind of stop that this version does not
    /// know, is still read: the step and the kind read as `other`.
    @Test func aRecordOfALaterVersionIsStillRead() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        var log = newLog(launch: "first")
        log.note(step: "read", state: .failed, at: time(1))
        log.stop(.timedOut, says: nil, at: time(1))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(log.record)) as? [String: Any])
        object["stop"] = "a_kind_of_later"
        object["steps"] = [["id": "a_step_of_later", "state": "failed", "began": 1_800_000_001_000.0, "ended": 1_800_000_001_000.0]]
        object["began"] = 1_800_000_000_000.0
        object["ended"] = 1_800_000_001_000.0
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object)
            .write(to: scratch.folder.appendingPathComponent("\(log.record.id.uuidString.lowercased()).json"))
        let read = InstallRecords(folder: scratch.folder, launch: "second").all()
        #expect(read.count == 1 && read.first?.stop == .other && read.first?.stoppedAt == .other)
        #expect(read.first?.began == time(0) && read.first?.outcome == .stopped)
    }

    // MARK: the folder

    /// A record that was written is read back whole by another start of the app, from a file that only its user reads.
    @Test func aRecordOutlivesItsApp() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        var log = newLog(launch: "first")
        log.note(step: "read", state: .done, at: time(1))
        log.note(step: "join", state: .failed, at: time(2))
        log.place(server: "worker-2")
        log.stop(.installerStopped, says: "This server has too little memory.", at: time(2))
        InstallRecords(folder: scratch.folder, launch: "first").write(log.record)

        let later = InstallRecords(folder: scratch.folder, launch: "second")
        #expect(later.all() == [log.record])
        #expect(later.newest(hub: hub) == log.record)
        #expect(later.newest(hub: hub, host: "203.0.113.9") == log.record)
        #expect(later.newest(hub: hub, host: "203.0.113.10") == nil)
        #expect(later.newest(hub: "http://100.64.0.9:8765/") == nil)
        #expect(later.newest(hub: nil) == nil)

        let files = try FileManager.default.contentsOfDirectory(atPath: scratch.folder.path)
        #expect(files == ["\(log.record.id.uuidString.lowercased()).json"])
        func mode(_ path: String) throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        }
        #expect(try mode(scratch.folder.appendingPathComponent(files[0]).path) == 0o600)
        #expect(try mode(scratch.folder.path) == 0o700)
        // A second write of the record leaves its file for its user only too.
        log.place(server: "worker-3")
        later.write(log.record)
        #expect(try mode(scratch.folder.appendingPathComponent(files[0]).path) == 0o600)
        // A copy of the file under another name is no record: a file is its record only by its record's id.
        try FileManager.default.copyItem(at: scratch.folder.appendingPathComponent(files[0]),
                                         to: scratch.folder.appendingPathComponent("copy.json"))
        #expect(InstallRecords(folder: scratch.folder, launch: "third").all().map(\.server) == ["worker-3"])
    }

    /// The newest install of a kind is found whatever its hub: a hub's install that stopped after its claim has the
    /// claimed address, which the app never went to.
    @Test func theNewestInstallOfAKind() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = InstallRecords(folder: scratch.folder, launch: "now")
        var claimed = newLog(.hub, hub: nil, at: 0)
        claimed.note(step: "claim", state: .done, at: time(1))
        claimed.place(hub: "http://100.64.0.12:8765/")
        claimed.note(step: "wait_ready", state: .running, at: time(2))
        claimed.stop(.timedOut, says: nil, at: time(3))
        var joined = newLog(.join, at: 10)
        joined.done(at: time(11))
        records.write(claimed.record)
        records.write(joined.record)
        #expect(records.newest(hub: nil) == nil)
        #expect(records.newest(kind: .hub) == claimed.record && records.newest(kind: .hub)?.stoppedAt == .waitReady)
        #expect(records.newest(kind: .join) == joined.record && records.newest(kind: .mac) == nil)
    }

    /// A write that did not reach the disk is tried again at the next write of the same record, and counts one time.
    @Test func aWriteThatDidNotReachTheDiskIsTriedAgain() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        // A file where the folder must be: no record can be written.
        try Data().write(to: scratch.folder)
        let records = InstallRecords(folder: scratch.folder, launch: "now")
        let log = newLog()
        records.write(log.record)
        #expect(records.changes == 1 && records.all() == [log.record])
        try FileManager.default.removeItem(at: scratch.folder)
        records.write(log.record)
        #expect(records.changes == 1)
        #expect(InstallRecords(folder: scratch.folder, launch: "now").all() == [log.record])
        // Once it is on the disk, the same record writes nothing more.
        try FileManager.default.removeItem(at: scratch.folder)
        records.write(log.record)
        #expect(!FileManager.default.fileExists(atPath: scratch.folder.path))
    }

    /// The last write of a record has no next write of its own: a write of another record tries it again.
    @Test func aWriteOfAnotherRecordTriesTheOnesThatWait() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        try Data().write(to: scratch.folder)
        let records = InstallRecords(folder: scratch.folder, launch: "now")
        var first = newLog(at: 0)
        first.done(at: time(1))
        records.write(first.record)
        try FileManager.default.removeItem(at: scratch.folder)
        let second = newLog(at: 10)
        records.write(second.record)
        #expect(records.changes == 2)
        #expect(InstallRecords(folder: scratch.folder, launch: "now").all() == [second.record, first.record])
    }

    /// An install that the app's end cut off reads as interrupted in every later start, with the step that ran, and
    /// never as one that runs; in its own launch it runs.
    @Test func anInstallThatTheAppsEndCutOffReadsAsInterrupted() {
        let scratch = Scratch()
        defer { scratch.remove() }
        var log = newLog(launch: "first")
        log.note(step: "read", state: .done, at: time(1))
        log.note(step: "wait_ready", state: .running, at: time(2))
        let first = InstallRecords(folder: scratch.folder, launch: "first")
        first.write(log.record)
        #expect(first.newest(hub: hub)?.outcome == .running)

        let cut = InstallRecords(folder: scratch.folder, launch: "second").newest(hub: hub)
        #expect(cut?.outcome == .interrupted && cut?.stoppedAt == .waitReady)
        #expect(cut?.ended == nil && cut?.lastChange == time(2))
        // An install that ended keeps its end in every launch.
        var ended = newLog(launch: "first", at: 10)
        ended.done(at: time(11))
        first.write(ended.record)
        #expect(InstallRecords(folder: scratch.folder, launch: "third").all().map(\.outcome) == [.done, .interrupted])
    }

    /// A hub's own install that stopped before its claim has no hub's address, and is found as that: the first run's
    /// case. The newest of a hub is the one that began last.
    @Test func theNewestOfAHubAndOfNoHub() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = InstallRecords(folder: scratch.folder, launch: "now")
        var first = newLog(.hub, hub: nil, at: 0)
        first.stop(.serverUnreached, says: nil, at: time(1))
        var second = newLog(.hub, hub: nil, at: 5)
        second.note(step: "code", state: .failed, at: time(6))
        second.stop(.stepFailed, says: nil, at: time(6))
        var joined = newLog(.join, at: 3)
        joined.done(at: time(4))
        for record in [first.record, joined.record, second.record] { records.write(record) }
        #expect(records.newest(hub: nil) == second.record)
        #expect(records.newest(hub: hub) == joined.record)
        #expect(records.all() == [second.record, joined.record, first.record])
    }

    /// A write that changes a record counts once and says so; the same record again writes nothing.
    @Test func aWriteThatChangesNothingCountsNothing() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = InstallRecords(folder: scratch.folder, launch: "now")
        final class Count: @unchecked Sendable { var posts = 0 }
        let count = Count()
        let watch = NotificationCenter.default.addObserver(forName: InstallRecords.changed, object: records, queue: nil) { _ in
            count.posts += 1
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        var log = newLog()
        #expect(records.changes == 0)
        records.write(log.record)
        records.write(log.record)
        #expect(records.changes == 1 && count.posts == 1)
        log.note(step: "read", state: .running, at: time(1))
        records.write(log.record)
        #expect(records.changes == 2 && count.posts == 2)
        #expect(records.all().count == 1)
    }

    /// The newest records stay, and an older one goes with its file. A file that is no record is passed over and stays.
    @Test func onlyTheNewestRecordsStay() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        try Data("not a record".utf8).write(to: scratch.folder.appendingPathComponent("notes.json"))
        // A file that is larger than a record can be is never read as one, whatever it holds.
        var large = newLog(at: 900)
        large.done(at: time(901))
        let padded = try JSONEncoder().encode(large.record) + Data(repeating: 0x20, count: InstallRecords.largestFile)
        let largeName = "\(large.record.id.uuidString.lowercased()).json"
        try padded.write(to: scratch.folder.appendingPathComponent(largeName))
        let records = InstallRecords(folder: scratch.folder, launch: "now", keeps: 3)
        var written: [InstallRecord] = []
        for number in 0..<5 {
            var log = newLog(at: Double(number * 10))
            log.done(at: time(Double(number * 10 + 1)))
            records.write(log.record)
            written.append(log.record)
        }
        #expect(records.all() == [written[4], written[3], written[2]])
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: scratch.folder.path))
        #expect(files == Set(written[2...].map { "\($0.id.uuidString.lowercased()).json" } + ["notes.json", largeName]))
        #expect(InstallRecords(folder: scratch.folder, launch: "later").all() == [written[4], written[3], written[2]])
    }

    /// The record that is written now is never the one that goes, also when it is the oldest: it stays past the limit
    /// until the next write of another record.
    @Test func theRecordThatIsWrittenNowStays() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = InstallRecords(folder: scratch.folder, launch: "now", keeps: 2)
        var newer: [InstallRecord] = []
        for number in 1...2 {
            var log = newLog(at: Double(number * 10))
            log.done(at: time(Double(number * 10 + 1)))
            records.write(log.record)
            newer.append(log.record)
        }
        var old = newLog(at: 0)
        old.done(at: time(1))
        records.write(old.record)
        #expect(Set(records.all().map(\.id)) == [newer[0].id, newer[1].id, old.record.id])
        var newest = newLog(at: 30)
        newest.done(at: time(31))
        records.write(newest.record)
        #expect(records.all().map(\.id) == [newest.record.id, newer[1].id])
        #expect(InstallRecords(folder: scratch.folder, launch: "later").all().map(\.id) == [newest.record.id, newer[1].id])
    }

    /// An install that this launch still runs is never the one that goes, however many began after it.
    @Test func aRunningInstallOfThisLaunchIsNeverRemoved() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = InstallRecords(folder: scratch.folder, launch: "now", keeps: 1)
        let running = newLog(at: 0)
        records.write(running.record)
        var newer = newLog(at: 10)
        newer.done(at: time(11))
        records.write(newer.record)
        #expect(Set(records.all().map(\.id)) == [running.record.id, newer.record.id])
    }

    /// Writes from several threads at one time lose no record.
    @Test func writesFromManyThreadsLoseNothing() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = InstallRecords(folder: scratch.folder, launch: "now")
        let logs = (0..<16).map { newLog(at: Double($0)) }
        DispatchQueue.concurrentPerform(iterations: logs.count) { records.write(logs[$0].record) }
        #expect(records.all().count == 16 && records.changes == 16)
        #expect(InstallRecords(folder: scratch.folder, launch: "later").all().count == 16)
    }
}
#endif
