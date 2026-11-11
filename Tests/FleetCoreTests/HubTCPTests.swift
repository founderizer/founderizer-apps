import Foundation
import Testing
@testable import FleetCore

/// The hub's TCP window (`HubTCP`): the root run that this Mac makes once on a hub's machine. The run's shell text runs
/// here, in `/bin/sh` and `/bin/bash`, on a folder that stands in for root's clone. Its `hubsetup.py` writes down each call and each
/// write, and answers with the words of the real step (fleet-pilot `hubsetup.py`, `hub_tcp_step`, release 2026.11.293),
/// which reads the value first and writes only when it must. So the test shows which calls each hub gets.
struct HubTCPTests {
    static let hub = URL(string: "http://100.80.1.2:8765")!
    static let fleet = "89abcdef01234567"
    static let db = "gen-1"
    static let now: Double = 1_762_800_000

    // The real step's words, and a line of the real kit-clone.
    static let already = "Founderizer: a kept connection keeps its TCP window over an idle time already"
    static let set = "Founderizer: a kept connection keeps its TCP window over an idle time "
        + "(net.ipv4.tcp_slow_start_after_idle = 0)"
    static let own = "Founderizer: TCP keeps this server's own setting: /etc/sysctl.conf sets "
        + "net.ipv4.tcp_slow_start_after_idle"
    static let unwritten = "Founderizer: TCP keeps its setting: /etc/sysctl.d/60-fleet-hub-tcp.conf could not be "
        + "written (Read-only file system)"
    static let would = "Founderizer: would keep the TCP window of a kept connection over an idle time "
        + "(net.ipv4.tcp_slow_start_after_idle = 0 in /etc/sysctl.d/60-fleet-hub-tcp.conf)"
    static let cloned = "Founderizer: root's own clone is at release 2026.11.300 already (0123456789ab)"

    /// The stand-in for root's clone's `hubsetup.py`. Flag files in its folder say what the hub is like: `set`, the value
    /// holds; `own`, a file of the server's own sets it; `old`, a release with no `tcp` step; `broken`, a `hubsetup.py`
    /// that cannot start after `kit-clone`; `clone-fails`; `crash`, the step breaks; `read-only`, the step cannot write
    /// its file. As the real step, `tcp` reads first and writes only when the value does not hold.
    static let standIn = #"""
        import os, sys
        here = os.path.dirname(os.path.abspath(__file__))
        args = sys.argv[1:]
        with open(os.path.join(here, "calls"), "a") as log:
            log.write(" ".join(args) + "\n")
        def flag(name):
            return os.path.exists(os.path.join(here, name))
        if args == ["kit-clone"]:
            if flag("clone-fails"):
                print("Founderizer install stopped: root's own clone could not fetch the published repository", file=sys.stderr)
                sys.exit(1)
            print("\#(cloned)")
            sys.exit(0)
        if args[:1] == ["tcp"] and flag("broken"):
            raise SystemError("this hubsetup.py cannot start")
        if args[:1] == ["tcp"] and flag("old"):
            print("usage: hubsetup.py [-h] {runtime,agent-users,vault,firewall,harden} ...", file=sys.stderr)
            print("hubsetup.py: error: argument what: invalid choice: 'tcp'", file=sys.stderr)
            sys.exit(2)
        if args == ["tcp", "--help"]:
            print("usage: hubsetup.py tcp [-h] [--check]")
            sys.exit(0)
        if args == ["tcp"]:
            if flag("crash"):
                raise RuntimeError("the step broke")
            if flag("own"):
                print("\#(own)")
            elif flag("set"):
                print("\#(already)")
            elif flag("read-only"):
                print("\#(unwritten)")
            else:
                with open(os.path.join(here, "writes"), "a") as log:
                    log.write("set\n")
                open(os.path.join(here, "set"), "w").close()
                print("\#(set)")
            sys.exit(0)
        sys.exit(3)
        """#

    private func clone(_ flags: [String] = []) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hub-tcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for flag in flags { try Data().write(to: folder.appendingPathComponent(flag)) }
        try Data(Self.standIn.utf8).write(to: folder.appendingPathComponent("hubsetup.py"))
        return folder
    }

    /// One shell text in a shell of this Mac, to its end: what it printed, on standard output and standard error.
    private func printed(_ text: String, shell: String = "/bin/sh") throws -> String {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: shell)
        child.arguments = ["-c", text]
        child.standardOutput = pipe
        child.standardError = pipe
        try child.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The run (or another text) on that folder: what it printed, and the calls and the writes of the stand-in.
    private func run(_ folder: URL, _ text: String? = nil, shell: String = "/bin/sh") throws
        -> (output: String, calls: [String], writes: Int) {
        let output = try printed(text ?? HubTCP.program(in: folder.path), shell: shell)
        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        return (output, lines("calls"), lines("writes").count)
    }

    /// What `sudo -i` gives root's login shell (sudo's manual, `-i`): the command and its arguments joined with spaces,
    /// with a backslash before each character that is not a letter, a digit, "_", "-" or "$".
    private func sudoLogin(_ arguments: [String]) -> String {
        arguments.map { argument in
            argument.map { character in
                character.isASCII && (character.isLetter || character.isNumber) || "_-$".contains(character)
                    ? String(character) : "\\" + String(character)
            }.joined()
        }.joined(separator: " ")
    }

    private func scratch() throws -> (UserDefaults, String) {
        let suite = "founderizer-test-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func isSet(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("set").path)
    }

    // MARK: the run

    /// The run starts as the central vault's install does, from root's own clone at its one fixed place, with no "$"
    /// and no new line in it (sudo -i would give both to root's login shell), and the vault's own root run keeps its
    /// text: nothing of this step is in it.
    @Test func theRunIsTheStepFromRootsOwnCloneAfterKitClone() throws {
        let step = "python3 /usr/local/lib/founderizer-kit/hubsetup.py"
        #expect(HubTCP.program() == CentralVaultRemote.bridge() + "; \(step) kit-clone || exit 1; "
                + "\(step) tcp --help >/dev/null 2>&1 || { echo founderizer-hub-tcp-no-step; exit 0; }; \(step) tcp")
        let text = HubTCP.program()
        let dollar = text.contains("$"), newLine = text.contains(where: \.isNewline), ascii = text.allSatisfy(\.isASCII)
        #expect(!dollar && !newLine && ascii)
        let key = SoftwareOwnerKey().publicKey
        for keepOwner in [false, true] {
            let install = try #require(CentralVaultRemote.install(ownerKey: key, keepOwner: keepOwner))
            #expect(install.hasPrefix(CentralVaultRemote.bridge() + "; \(step) kit-clone && \(step) central-vault "))
            #expect(!install.contains("hubsetup.py tcp") && !install.contains(HubTCP.noStep))
        }
    }

    /// A hub without the value gets the step once, which sets it. The app keeps the hub as done and makes no second run
    /// there. A second run would find the value and write nothing.
    @Test func aHubWithoutTheValueGetsTheStepOnce() throws {
        let folder = try clone()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(HubTCP.isDue(hub: Self.hub, fleet: Self.fleet, db: Self.db, tries: nil, now: Self.now, in: defaults))

        let first = try run(folder)
        #expect(first.calls == ["kit-clone", "tcp --help", "tcp"], "sh said: \(first.output)")
        #expect(first.writes == 1 && isSet(folder))
        #expect(HubTCP.outcome(first.output) == .done)
        let tries = HubTCP.keep(HubTCP.outcome(first.output), hub: Self.hub, fleet: Self.fleet, db: Self.db, after: nil,
                                at: Self.now, in: defaults)
        #expect(tries == nil)
        #expect(HubTCP.isDone(hub: Self.hub, fleet: Self.fleet, db: Self.db, in: defaults))
        for later in [Self.now + 600, Self.now + 86_400 * 365] {
            #expect(!HubTCP.isDue(hub: Self.hub, fleet: Self.fleet, db: Self.db, tries: nil, now: later, in: defaults))
        }

        let second = try run(folder)
        #expect(second.calls == first.calls + ["kit-clone", "tcp --help", "tcp"])
        #expect(second.writes == 1, "no second write")
        #expect(HubTCP.outcome(second.output) == .done)
    }

    /// A hub that has the value, or a file of its own that sets it, gets the step's check and no write, and is done.
    @Test func aHubThatHasTheValueGetsTheCheckAndNothingMore() throws {
        for flag in ["set", "own"] {
            let folder = try clone([flag])
            defer { try? FileManager.default.removeItem(at: folder) }
            let ran = try run(folder)
            #expect(ran.calls == ["kit-clone", "tcp --help", "tcp"], "\(flag): \(ran.output)")
            #expect(ran.writes == 0, "\(flag)")
            #expect(HubTCP.outcome(ran.output) == .done, "\(flag)")
        }
    }

    /// A hub whose release is known to be older than 2026.11.293 gets no run at all. A hub whose release is not known
    /// gets the run, and its `tcp --help` refuses there: no step runs, and the hub is not kept as done, so its next
    /// tries come after the wait, and the step runs when the hub has taken a release that has it.
    @Test func aHubWhoseReleaseHasNoStepGetsNothing() async throws {
        #expect(HubTCP.hasStep(release: "2026.11.292") == false)
        #expect(HubTCP.hasStep(release: "2026.10.999") == false)
        #expect(HubTCP.hasStep(release: "2025.12.400") == false)
        #expect(HubTCP.hasStep(release: "2026.11.293") == true)
        #expect(HubTCP.hasStep(release: "2026.11.1000") == true)
        #expect(HubTCP.hasStep(release: "2026.12.1") == true)
        #expect(HubTCP.hasStep(release: "2027.1.1") == true)
        for unknown in [nil, "", "2026.11", "2026.11.293.1", "v2026.11.300", "2026..300", "2026.11.x"] {
            #expect(HubTCP.hasStep(release: unknown) == nil, "\(unknown ?? "nil")")
        }

        let (defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let reading = try JSONDecoder().decode(VaultReading.self, from: Data(
            #"{"db": "gen-1", "fleet": "89abcdef01234567", "machines": [], "held": {}}"#.utf8))
        let gated = await HubTCP.round(reading, hub: Self.hub, release: "2026.11.292", tries: nil, now: { Self.now },
                                       in: defaults) { _ in Issue.record("a run on a release with no step"); return "" }
        #expect(gated == nil)

        let folder = try clone(["old"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let ran = try run(folder)
        #expect(ran.calls == ["kit-clone", "tcp --help"], "sh said: \(ran.output)")
        #expect(ran.writes == 0 && !isSet(folder))
        #expect(HubTCP.outcome(ran.output) == .noStep)
        let tries = HubTCP.keep(.noStep, hub: Self.hub, fleet: Self.fleet, db: Self.db, after: nil, at: Self.now, in: defaults)
        #expect(tries?.failures == 1)
        #expect(!HubTCP.isDone(hub: Self.hub, fleet: Self.fleet, db: Self.db, in: defaults))
        #expect(!HubTCP.isDue(hub: Self.hub, fleet: Self.fleet, db: Self.db, tries: tries, now: Self.now + 599, in: defaults))
        #expect(HubTCP.isDue(hub: Self.hub, fleet: Self.fleet, db: Self.db, tries: tries, now: Self.now + 600, in: defaults))

        // The hub took a release that has the step: the next run sets the value.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("old"))
        let later = try run(folder)
        #expect(later.calls.suffix(3) == ["kit-clone", "tcp --help", "tcp"])
        #expect(later.writes == 1 && isSet(folder))
        #expect(HubTCP.outcome(later.output) == .done)

        // A `hubsetup.py` that cannot start, after kit-clone, refuses `tcp --help` as well: no step runs, and the
        // outcome is "no step".
        let broken = try clone(["broken"])
        defer { try? FileManager.default.removeItem(at: broken) }
        let refused = try run(broken)
        #expect(refused.calls == ["kit-clone", "tcp --help"], "sh said: \(refused.output)")
        #expect(refused.writes == 0)
        #expect(HubTCP.outcome(refused.output) == .noStep)
    }

    /// A part of the run that fails stops it: no part after it runs, nothing is set, and the hub is not done. The
    /// failure is one try of this step alone, and it changes the record of no other hub.
    @Test func aPartThatFailsStopsTheRunAndChangesNothingElse() throws {
        let (defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let other = URL(string: "http://100.64.0.9:8765")!
        _ = HubTCP.keep(.done, hub: other, fleet: Self.fleet, db: Self.db, after: nil, at: Self.now, in: defaults)

        let cases: [(flags: [String], calls: [String], said: String)] = [
            (["clone-fails"], ["kit-clone"], "Founderizer install stopped: root's own clone could not fetch the published repository"),
            (["crash"], ["kit-clone", "tcp --help", "tcp"], "RuntimeError: the step broke"),
            (["read-only"], ["kit-clone", "tcp --help", "tcp"], Self.unwritten),
        ]
        var tries: VaultTries?
        for (flags, calls, said) in cases {
            let folder = try clone(flags)
            defer { try? FileManager.default.removeItem(at: folder) }
            let ran = try run(folder)
            #expect(ran.calls == calls, "\(flags): \(ran.output)")
            #expect(ran.writes == 0 && !isSet(folder), "\(flags)")
            #expect(HubTCP.outcome(ran.output) == .failed(said), "\(flags): \(ran.output)")
            tries = HubTCP.keep(HubTCP.outcome(ran.output), hub: Self.hub, fleet: Self.fleet, db: Self.db, after: tries,
                                at: Self.now, in: defaults)
        }
        #expect(tries?.failures == 3)
        #expect(!HubTCP.isDone(hub: Self.hub, fleet: Self.fleet, db: Self.db, in: defaults))
        #expect(HubTCP.isDone(hub: other, fleet: Self.fleet, db: Self.db, in: defaults))

        // An old clone whose release-key.pub the bridge cannot write: nothing of the clone runs at all.
        let folder = try clone()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("release-key.pub"),
                                                withIntermediateDirectories: true)
        let ran = try run(folder)
        #expect(ran.calls.isEmpty, "sh said: \(ran.output)")
        #expect(ran.writes == 0 && !isSet(folder))
        if case .failed = HubTCP.outcome(ran.output) {} else { Issue.record("not a failure: \(ran.output)") }
    }

    /// A user who is not root runs it through `sudo -n -i -- /bin/sh -c '…'`: that user's shell gives sudo the run as
    /// one word, sudo gives it to root's login shell with its backslashes, and the run arrives whole in `/bin/sh`.
    @Test func theRunArrivesWholeThroughSudo() throws {
        // The stand-in for sudo is true where it matters: a "$" reaches root's login shell, which expands it first.
        let lost = try printed(sudoLogin(["/bin/sh", "-c", #"said=kept; printf '%s' "$said""#]), shell: "/bin/bash")
        #expect(lost.isEmpty, "the stand-in for sudo kept a $: \(lost)")

        let folder = try clone()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = InstallTarget(host: "100.80.1.2", user: "me", becomeRoot: true)
        let remote = try #require(CentralVaultRemote.arguments(target: target, program: HubTCP.program(in: folder.path)).last)
        #expect(remote.hasPrefix("sudo -n -i -- /bin/sh -c '"))
        // What the user's own shell gives sudo: the words after `sudo -n -i --`.
        let words = try printed(#"sudo() { shift 3; printf '%s\0' "$@"; }; "# + remote)
        let arguments = words.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        #expect(arguments == ["/bin/sh", "-c", HubTCP.program(in: folder.path)])
        for login in ["/bin/bash", "/bin/sh"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("calls"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("set"))
            let ran = try run(folder, sudoLogin(arguments), shell: login)
            #expect(ran.calls == ["kit-clone", "tcp --help", "tcp"], "\(login) said: \(ran.output)")
            #expect(HubTCP.outcome(ran.output) == .done, "\(login) said: \(ran.output)")
        }
    }

    // MARK: what the app reads and keeps

    @Test func theOutcomeIsTheStepsOwnLastWord() {
        #expect(HubTCP.outcome(Self.cloned + "\n" + Self.set + "\n") == .done)
        #expect(HubTCP.outcome(Self.cloned + "\n" + Self.already + "\n") == .done)
        #expect(HubTCP.outcome(Self.cloned + "\r\n  " + Self.own + "  \r\n") == .done)
        #expect(HubTCP.outcome(Self.cloned + "\n" + HubTCP.noStep + "\n") == .noStep)
        // The step's check alone, a step that broke after a line, kit-clone's own line, and no line at all are no done
        // step. A failed run's reason is its own last line.
        #expect(HubTCP.outcome(Self.cloned + "\n" + Self.would + "\n") == .failed(Self.would))
        #expect(HubTCP.outcome(Self.cloned + "\n" + Self.would + "\nTraceback (most recent call last):\n")
                == .failed("Traceback (most recent call last):"))
        #expect(HubTCP.outcome(Self.cloned + "\n") == .failed(Self.cloned))
        #expect(HubTCP.outcome("sudo: a password is required\n") == .failed("sudo: a password is required"))
        #expect(HubTCP.outcome("") == .failed("The run printed no line."))
        #expect(HubTCP.outcome("not " + HubTCP.noStep) == .failed("not " + HubTCP.noStep))
        // The real step's other words: it could not write, or the kernel did not take the value.
        for line in [Self.unwritten,
                     "Founderizer: this server did not take net.ipv4.tcp_slow_start_after_idle = 0 now (Read-only file "
                        + "system): /etc/sysctl.d/60-fleet-hub-tcp.conf sets it at a start where /proc/sys can be written",
                     "Founderizer: this server still reads net.ipv4.tcp_slow_start_after_idle = 1 after the write: "
                        + "/etc/sysctl.d/60-fleet-hub-tcp.conf sets 0 at a start where /proc/sys can be written"] {
            #expect(HubTCP.outcome(Self.cloned + "\n" + line + "\n") == .failed(line))
        }
    }

    /// Once for each hub, fleet and generation: a done hub is never due again, another generation, another fleet at the
    /// same address and another address are, a reading with no fleet is never, and 6 failed tries in a row end the
    /// tries.
    @Test func theRunIsOnceForEachHubFleetAndGeneration() throws {
        let (defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!HubTCP.isDue(hub: Self.hub, fleet: nil, db: Self.db, tries: nil, now: Self.now, in: defaults))
        #expect(!HubTCP.isDue(hub: Self.hub, fleet: "not-a-fleet", db: Self.db, tries: nil, now: Self.now, in: defaults))
        #expect(!HubTCP.isDue(hub: Self.hub, fleet: Self.fleet, db: "", tries: nil, now: Self.now, in: defaults))
        _ = HubTCP.keep(.done, hub: Self.hub, fleet: Self.fleet, db: Self.db, after: nil, at: Self.now, in: defaults)
        #expect(!HubTCP.isDue(hub: Self.hub, fleet: Self.fleet, db: Self.db, tries: nil, now: Self.now, in: defaults))
        #expect(HubTCP.isDue(hub: Self.hub, fleet: Self.fleet, db: "gen-2", tries: nil, now: Self.now, in: defaults))
        #expect(HubTCP.isDue(hub: Self.hub, fleet: "0123456789abcdef", db: Self.db, tries: nil, now: Self.now, in: defaults))
        let elsewhere = URL(string: "http://100.80.1.3:8765")!
        #expect(HubTCP.isDue(hub: elsewhere, fleet: Self.fleet, db: Self.db, tries: nil, now: Self.now, in: defaults))

        var tries: VaultTries?
        for attempt in 1...VaultTries.most {
            let at = Self.now + Double(attempt - 1) * VaultTries.wait
            #expect(HubTCP.isDue(hub: elsewhere, fleet: Self.fleet, db: Self.db, tries: tries, now: at, in: defaults),
                    "try \(attempt)")
            tries = HubTCP.keep(.failed("try \(attempt) failed"), hub: elsewhere, fleet: Self.fleet, db: Self.db,
                                after: tries, at: at, in: defaults)
        }
        #expect(tries?.givenUp == true)
        #expect(!HubTCP.isDue(hub: elsewhere, fleet: Self.fleet, db: Self.db, tries: tries, now: Self.now + 86_400,
                              in: defaults))
        #expect(!HubTCP.isDone(hub: elsewhere, fleet: Self.fleet, db: Self.db, in: defaults))
    }

    /// The tries start again when the hub runs another release than the one they were for, and only then: the same
    /// release, or a release that is not known (a reading that is missing), keeps them.
    @Test func theTriesStartAgainWithAnotherRelease() {
        let used = VaultTries(failures: VaultTries.most, last: Self.now, reason: "The hub's release has no TCP step yet.")
        #expect(used.givenUp)
        let new = HubTCP.tries(used, for: "2026.11.293", after: "2026.11.290")
        #expect(new.tries == nil && new.release == "2026.11.293")
        let same = HubTCP.tries(used, for: "2026.11.290", after: "2026.11.290")
        #expect(same.tries == used && same.release == "2026.11.290")
        let unknown = HubTCP.tries(used, for: nil, after: "2026.11.290")
        #expect(unknown.tries == used && unknown.release == "2026.11.290")
        let first = HubTCP.tries(nil, for: "2026.11.297", after: nil)
        #expect(first.tries == nil && first.release == "2026.11.297")
    }

    /// A clock for a round, which a run moves, as a real run takes time.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Double
        init(_ time: Double) { self.time = time }
        func read() -> Double { lock.lock(); defer { lock.unlock() }; return time }
        func move(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; time += seconds }
    }

    /// The programs that a round gave to its run.
    private actor Runs {
        var programs: [String] = []
        func add(_ program: String) { programs.append(program) }
    }

    /// The round's part of the step (`HubTCP.round`), which the vault's model calls at the end of each round: a run only
    /// while the step is due, with the step's own program. A run that could not be made is one try with its words; a
    /// done run is kept, and no run comes after it. No reading, or a reading with no fleet, gets no run.
    @Test func aRoundRunsTheStepOnlyWhileItIsDue() async throws {
        let (defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runs = Runs()
        func reading(_ fleet: String?) throws -> VaultReading {
            let named = fleet.map { #", "fleet": "\#($0)""# } ?? ""
            return try JSONDecoder().decode(VaultReading.self,
                                            from: Data(#"{"db": "gen-1"\#(named), "machines": [], "held": {}}"#.utf8))
        }
        struct Unreached: LocalizedError {
            var errorDescription: String? { "The fleet has no SSH connection to the hub's machine on record." }
        }

        let unnamed = try reading(nil)
        for none in [nil, unnamed] as [VaultReading?] {
            let tries = await HubTCP.round(none, hub: Self.hub, release: nil, tries: nil, now: { Self.now },
                                           in: defaults) { program in
                await runs.add(program); return Self.already
            }
            #expect(tries == nil)
        }
        #expect(await runs.programs.isEmpty)

        let named = try reading(Self.fleet)
        // The run takes 500 seconds on the clock: the try counts from the end of the run.
        let clock = Clock(Self.now)
        let first = await HubTCP.round(named, hub: Self.hub, release: nil, tries: nil, now: { clock.read() },
                                       in: defaults) { program in
            await runs.add(program); clock.move(500); throw Unreached()
        }
        #expect(first?.failures == 1)
        #expect(first?.last == Self.now + 500)
        #expect(first?.reason == "The fleet has no SSH connection to the hub's machine on record.")
        let waits = await HubTCP.round(named, hub: Self.hub, release: "2026.11.300", tries: first, now: { Self.now + 1_099 },
                                       in: defaults) { program in
            await runs.add(program); return Self.already
        }
        #expect(waits == first)
        let done = await HubTCP.round(named, hub: Self.hub, release: "2026.11.300", tries: first, now: { Self.now + 1_100 },
                                      in: defaults) { program in
            await runs.add(program); return Self.cloned + "\n" + Self.already + "\n"
        }
        #expect(done == nil)
        #expect(HubTCP.isDone(hub: Self.hub, fleet: Self.fleet, db: Self.db, in: defaults))
        let after = await HubTCP.round(named, hub: Self.hub, release: "2026.11.300", tries: nil, now: { Self.now + 86_400 },
                                       in: defaults) { program in
            await runs.add(program); return Self.already
        }
        #expect(after == nil)
        #expect(await runs.programs == [HubTCP.program(), HubTCP.program()])
    }
}
