import Foundation
import Testing
@testable import FleetCore

/// The ledger of the accounts of the app's own SSH key, and the gate of app mode (the build spec of the app's SSH key,
/// step 2).
struct SSHKeyLedgerTests {
    private static func folder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ssh-ledger-" + UUID().uuidString)
            .appendingPathComponent("ssh")
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [[String]] = []
        var all: [[String]] { lock.withLock { made } }
        /// Notes one call, and gives how many came before it.
        func note(_ arguments: [String]) -> Int {
            lock.withLock {
                made.append(arguments)
                return made.count - 1
            }
        }
        func runner(_ answer: LocalShell.Answer) -> ShellRunner {
            { _, arguments, _, _ in
                _ = self.note(arguments)
                return answer
            }
        }
    }

    /// **Two writers lose no row**, the file is the owner's alone, and a row of a later step keeps what it holds. Bugs:
    /// two rounds that write at once read the same file and each renames its own in, so one account's row is lost and
    /// that account goes back to today's arguments; a file of mode 644 lets another user of the Mac read the list of
    /// the servers that this Mac is root on; this build writes a later step's row back as `plain`, or without the
    /// fields that it does not know.
    @Test func twoWritersLoseNoRowAndARowOfALaterStepStays() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        await withTaskGroup(of: Void.self) { group in
            for port in 2200..<2240 {
                group.addTask {        // each writer an object of its own, as two programs have
                    SSHKeyLedger(folder: folder).recordPlain(.init(address: "100.84.1.2", user: "root", port: port),
                                                             now: 1_794_000_000)
                }
            }
        }
        let ledger = SSHKeyLedger(folder: folder)
        #expect(Set(ledger.rows().map(\.account.port)) == Set(2200..<2240))
        #expect(ledger.rows().allSatisfy { $0.state == SSHKeyLedger.plain && $0.at == 1_794_000_000 })
        let file = folder.appendingPathComponent("accounts.json").path
        let modes = try [file, folder.path].map {
            try #require(FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? Int)
        }
        #expect(modes == [0o600, 0o700])

        let later = #"{"accounts": [{"address": "100.84.1.9", "user": "root", "port": 22, "state": "proved", "hub": "http://100.64.0.2:8765"}]}"#
        try Data(later.utf8).write(to: URL(fileURLWithPath: file))
        let account = SSHKeyLedger.Account(address: "100.84.1.9", user: "root", port: 22)
        ledger.recordPlain(account, now: 1_794_000_100)
        ledger.recordTried(account, now: 1_794_000_100)
        #expect(ledger.row(account) == SSHKeyLedger.Row(account: account, state: "proved", at: nil, tried: nil))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any]
        #expect((written?["accounts"] as? [[String: Any]])?.first?["hub"] as? String == "http://100.64.0.2:8765")
    }

    /// **The gate of app mode** (`SSHRun.prove`): an account of the app's own key gets app mode only after one run with
    /// that key alone, under `-F /dev/null` and with a host key that this Mac knows, printed the proof; a run that did
    /// not get in holds the account at today's arguments for a day. At a port that the owner did not give, the known key
    /// is the one of the host's port 22 (bug: a `[host]:port` line that an earlier `accept-new` run kept at the hub's
    /// port lets another program there answer the proof). Bugs: an account goes to app mode with no such run,
    /// so a server that lets this Mac in only with a `Host *` key of the owner's stops working; a refused gate runs
    /// again at each call, one refused login after another against the server's MaxAuthTries and fail2ban.
    @Test func onlyARunWithTheAppsKeyAloneThatGotInPutsAnAccountInAppMode() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let ledger = SSHKeyLedger(folder: folder), app = "/Users/me/.ssh/founderizer_ed25519", calls = Calls()
        let target = InstallTarget(host: "100.84.1.2", user: "deploy", port: 2222, identityFile: app, becomeRoot: true)
        let account = SSHKeyLedger.Account(address: "100.84.1.2", user: "deploy", port: 2222)
        let start = 1_794_000_000.0
        func prove(_ target: InstallTarget, _ output: String, status: Int32 = 0, after days: Double,
                   in other: SSHKeyLedger? = nil) async {
            await SSHRun.prove(target, ledger: other ?? SSHKeyLedger(folder: folder), appKey: app,
                               run: calls.runner(LocalShell.Answer(status: status, output: output)),
                               now: start + days * 86_400)
        }
        await prove(target, "deploy@100.84.1.2: Permission denied (publickey).\r\n", status: 255, after: 0)
        #expect(calls.all == [[
            "-F", "/dev/null", "-a", "-x", "-o", "IdentitiesOnly=yes", "-i", app,
            "-o", "PreferredAuthentications=publickey", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0",
            "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ProxyCommand=none",
            "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=100.84.1.2", "-o", "ConnectTimeout=20",
            "-p", "2222", "deploy@100.84.1.2", "echo founderizer-key=works"]])
        #expect(!ledger.confined(account) && ledger.row(account)?.tried == start)
        await prove(target, "founderizer-key=works\n", after: 0.5)          // within the day: no run
        #expect(calls.all.count == 1)
        await prove(target, "", after: 1)                                   // no proof line is no proof
        #expect(calls.all.count == 2 && !ledger.confined(account))
        await prove(target, "founderizer-key=works\n", after: 2)
        #expect(ledger.confined(account) && ledger.row(account)?.at == start + 2 * 86_400)
        await prove(target, "founderizer-key=works\n", after: 3)            // in app mode: no more runs
        // the owner's own key, and a ledger with no file (a test, another program): no run at all
        var his = target
        his.identityFile = "/Users/me/.ssh/id_ed25519"
        his.port = 22
        await prove(his, "founderizer-key=works\n", after: 0)
        await prove(InstallTarget(host: "100.84.1.20", identityFile: app), "founderizer-key=works\n", after: 0,
                    in: SSHKeyLedger())
        #expect(calls.all.count == 3)
        // an app-mode run that the account refused puts it back to today's arguments; a program that failed, and a
        // refused run of today's arguments, change nothing (bug: a server that refuses the app's key alone after its
        // gate stays in app mode, refused at each round, where today's arguments still get in)
        let refused = LocalShell.Answer(status: 255, output: "deploy@100.84.1.2: Permission denied (publickey).\r\n")
        let call = InstallPlan(job: .join, target: target, steps: [], redactions: []).call(for: "true", runs: .login)
        let confined = call.arguments(SSHCall.key(for: target, ledger: ledger, appKey: app)), today = call.arguments(.owner)
        #expect(confined.starts(with: ["-F", "/dev/null"]))
        SSHRun.settle(target, arguments: confined, answer: LocalShell.Answer(status: 1, output: "false\n"), ledger: ledger,
                      appKey: app, now: start + 4 * 86_400)
        SSHRun.settle(target, arguments: today, answer: refused, ledger: ledger, appKey: app, now: start + 4 * 86_400)
        #expect(ledger.confined(account))
        SSHRun.settle(target, arguments: confined, answer: refused, ledger: ledger, appKey: app, now: start + 4 * 86_400)
        #expect(!ledger.confined(account) && ledger.row(account)?.tried == start + 4 * 86_400)
    }

    /// **One gate run for each account at a time** (Fable's check of 21 November 2026): while the door round's run of
    /// the gate waits for `ssh`, the hardening round reaches the same account, and goes on with no run of its own.
    /// Bug: each round reads the ledger before the first one writes its try, and a server that refuses the app's key
    /// alone counts two or three refused logins in one second against its MaxAuthTries and fail2ban.
    @Test func twoGatesAtOnceForOneAccountMakeOneRun() async {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let ledger = SSHKeyLedger(folder: folder), app = "/Users/me/.ssh/founderizer_ed25519", calls = Calls()
        let target = InstallTarget(host: "100.84.1.9", user: "root", port: 22, identityFile: app)
        let (started, begin) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let run: ShellRunner = { _, arguments, _, _ in
            if calls.note(arguments) == 0 {         // the first run waits for the second caller
                begin.yield()
                var wait = released.makeAsyncIterator()
                _ = await wait.next()
            }
            return LocalShell.Answer(status: 255, output: "root@100.84.1.9: Permission denied (publickey).\r\n")
        }
        async let first: Void = SSHRun.prove(target, ledger: ledger, appKey: app, run: run, now: 1_794_000_000)
        var began = started.makeAsyncIterator()
        _ = await began.next()
        await SSHRun.prove(target, ledger: ledger, appKey: app, run: run, now: 1_794_000_000)
        #expect(calls.all.count == 1)
        release.yield()
        await first
        #expect(calls.all.count == 1 && ledger.row(SSHKeyLedger.Account(address: "100.84.1.9", user: "root", port: 22))?
                    .refused == 1)
    }

    /// **A refused key ends by a count** (Fable's check of 21 November 2026): three runs of the gate that the server
    /// refused, a day apart, and it runs no more for that account until the app puts its key there again
    /// (`PasswordOnce`); a refused host key and no answer sent no login, so they only wait a day each. Bugs: a refused
    /// gate runs each day for ever, one refused login a day against the server's fail2ban; a refused host key or a
    /// server that was off ends the gate for good, and that account never reaches app mode.
    @Test func aRefusedKeyEndsAfterThreeTriesAndAHostKeyOrNoAnswerOnlyWaits() async {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let ledger = SSHKeyLedger(folder: folder), app = "/Users/me/.ssh/founderizer_ed25519", calls = Calls()
        let start = 1_794_000_000.0
        func prove(_ host: String, _ output: String, status: Int32 = 255, day: Double, added: Bool = false) async {
            await SSHRun.prove(InstallTarget(host: host, user: "root", port: 22, identityFile: app), ledger: ledger,
                               appKey: app, run: calls.runner(LocalShell.Answer(status: status, output: output)),
                               now: start + day * 86_400, added: added)
        }
        let refused = SSHKeyLedger.Account(address: "100.84.1.20", user: "root", port: 22)
        for day in 0..<5 { await prove("100.84.1.20", "root@100.84.1.20: Permission denied (publickey).\r\n", day: Double(day)) }
        #expect(calls.all.count == 3 && ledger.row(refused)?.refused == 3 && !ledger.provable(refused, now: start + 9 * 86_400))
        await prove("100.84.1.20", "founderizer-key=works\n", status: 0, day: 6, added: true)
        #expect(calls.all.count == 4 && ledger.confined(refused))
        await prove("100.84.1.21", "Host key verification failed.\r\n", day: 0)
        await prove("100.84.1.21", "Host key verification failed.\r\n", day: 1)
        await prove("100.84.1.21", "ssh: connect to host 100.84.1.21 port 22: Operation timed out\r\n", day: 2)
        await prove("100.84.1.21", "ssh: connect to host 100.84.1.21 port 22: Operation timed out\r\n", day: 3)
        let waits = SSHKeyLedger.Account(address: "100.84.1.21", user: "root", port: 22)
        #expect(calls.all.count == 8 && ledger.row(waits)?.refused == 0 && ledger.provable(waits, now: start + 4 * 86_400))
    }
}
