#if os(macOS)
import Foundation
import os

/// **This Mac's `ssh` to a kept connection, with the gate of app mode in front** (the build spec of the app's SSH key,
/// step 2: "An account gets `-F /dev/null` only after one run with it worked"). The rounds and the steps that reach a
/// server with the connection that the app keeps start `ssh` here, with the arguments that their own caller built
/// (`InstallPlan.arguments`, `CentralVaultRemote.arguments`, `OwnerMacKeyRegistration.arguments`,
/// `DoorAccess.sshArguments`).
///
/// Before the run, an account that names the app's own key file and is not in app mode yet gets one run of the gate
/// (`prove`), at most once a day; the run that follows keeps the arguments that it was given, and the next call to
/// that account is in app mode once the gate got in. After the run, an app-mode run that the account refused puts it
/// back to today's arguments (`settle`). Step 4 of the spec adds the agent and its socket here.
public enum SSHRun {
    static let log = Logger(subsystem: "com.founderizer.app", category: "ssh-key")

    /// One `ssh` with `arguments`, after the gate for `target` (the connection that they reach), or for none.
    public static func run(_ arguments: [String], to target: InstallTarget?, stdin: Data? = nil,
                           timeout: Double) async throws -> LocalShell.Answer {
        if let target { await prove(target) }
        let answer = try await LocalShell.run("/usr/bin/ssh", arguments, stdin: stdin, timeout: timeout)
        if let target { settle(target, arguments: arguments, answer: answer) }
        return answer
    }

    /// **An app-mode run that the account refused puts that account back to today's arguments**: its key or its host
    /// key was refused (`DoorAccess.loginRefused`) with `-F /dev/null` and the app's key alone, where today's
    /// arguments, which read the owner's configuration, can still get in. The gate tries it again a day later. A run
    /// that `ssh` did not reach the server with, a program that failed, and a row of a later step change nothing.
    static func settle(_ target: InstallTarget, arguments: [String], answer: LocalShell.Answer,
                       ledger: SSHKeyLedger = .shared, appKey: String = AppSSHKey.path(),
                       now: Double = Date().timeIntervalSince1970) {
        guard arguments.starts(with: ["-F", "/dev/null"]), target.identityFile == appKey,
              DoorAccess.loginRefused(status: answer.status, output: answer.output),
              ledger.recordBack(SSHKeyLedger.Account(address: target.host, user: target.user, port: target.port),
                                now: now) else { return }
        log.notice("\(target.destination, privacy: .public):\(target.port, privacy: .public): an app-mode run was refused, today's arguments are back: \(answer.lines.last ?? "", privacy: .public)")
    }

    /// **The gate's one run for an account**: where `target` names the app's own key file and the ledger says that no
    /// run of the gate got in yet (and none was tried in the last day), `ssh` in app mode with that key alone, as the
    /// user that this Mac logs in as, with the host key that this Mac knows already (`StrictHostKeyChecking=yes`, so
    /// nothing is added to a known-hosts file), runs `echo founderizer-key=works`, which changes nothing. Its line in
    /// the output makes the account `plain`; any other end is a try, and the account keeps today's arguments. A ledger
    /// with no file (a test, another program) runs nothing. `ledger`, `appKey`, `ssh`, `run` and `now`: for a test.
    ///
    /// **One run for each account at a time** (Fable's check of 21 November 2026): the door round, the hardening round
    /// and the key registration can reach one account in the same minute, and a server that refuses the app's key
    /// alone would count two or three refused logins in one second against its MaxAuthTries and fail2ban. A second
    /// caller while a run is open goes on with no run of its own. **A refused key ends by a count**: after three runs
    /// that the server refused ("permission denied", too many authentication failures), the gate runs no more for that
    /// account until the app puts its key there again (`added`, from `PasswordOnce`). No answer and a refused host key
    /// sent no login, so they only wait for the next day.
    public static func prove(_ target: InstallTarget, ledger: SSHKeyLedger = .shared, appKey: String = AppSSHKey.path(),
                             ssh: String = "/usr/bin/ssh", run: ShellRunner = Shell.local,
                             now: Double = Date().timeIntervalSince1970, added: Bool = false) async {
        let account = SSHKeyLedger.Account(address: target.host, user: target.user, port: target.port)
        guard target.identityFile == appKey, ledger.isOpen else { return }
        if added { ledger.recordAdded(account) }
        let key = Proving.Key(ledger: ObjectIdentifier(ledger), account: account)
        guard ledger.provable(account, now: now), proving.begin(key) else { return }
        defer { proving.end(key) }
        // a run that ended just before this one began has written its row
        guard ledger.provable(account, now: now) else { return }
        let answer = try? await run(ssh, proof(target, key: .file(appKey)), nil, 40)
        let place = "\(target.destination):\(target.port)"
        if answer?.ok == true, answer?.lines.contains(PasswordOnce.keyWorks) == true {
            ledger.recordPlain(account, now: now)
            log.notice("\(place, privacy: .public): the app's key alone got in: app mode")
            return
        }
        let refused = answer.map(refusedLogin) ?? false
        ledger.recordTried(account, now: now, refused: refused)
        let said = answer.map { $0.lines.last ?? "status \($0.status)" } ?? "ssh did not start"
        if refused, (ledger.row(account)?.refused ?? 0) >= SSHKeyLedger.refusals {
            log.notice("\(place, privacy: .public): the app's key alone was refused \(SSHKeyLedger.refusals, privacy: .public) times, no more tries until the app adds its key there again: \(said, privacy: .public)")
        } else {
            log.notice("\(place, privacy: .public): the app's key alone did not get in, today's arguments stay: \(said, privacy: .public)")
        }
    }

    /// Whether `ssh` says that the server refused the login itself: it took no key of the ones offered. A refused host
    /// key, and a server that did not answer, sent no login.
    static func refusedLogin(_ answer: LocalShell.Answer) -> Bool {
        let said = answer.output.lowercased()
        return answer.status == 255 && (said.contains("permission denied (") || said.contains("too many authentication failures"))
    }

    /// The accounts whose gate runs now, in this process: the app's rounds are all in it.
    static let proving = Proving()

    final class Proving: @unchecked Sendable {
        struct Key: Hashable { let ledger: ObjectIdentifier; let account: SSHKeyLedger.Account }
        private let lock = NSLock()
        private var open: Set<Key> = []

        /// true for the first caller; false while that caller's run is open.
        func begin(_ key: Key) -> Bool { lock.withLock { open.insert(key).inserted } }
        func end(_ key: Key) { _ = lock.withLock { open.remove(key) } }
    }

    /// The options of the gate's run: the host key that this Mac knows already, never a new one, by the rule of the
    /// target (`InstallTarget.hostKeyOptions`: at a port that the owner did not give, the line of the host's port 22,
    /// never a `[host]:port` line that an earlier run kept), and the install's timeout.
    static func proofOptions(_ target: InstallTarget) -> [String] {
        target.hostKeyOptions(strict: true) + ["-o", "ConnectTimeout=20"]
    }

    /// The arguments of the gate's run: app mode with `key`, as the user that this Mac logs in as.
    static func proof(_ target: InstallTarget, key: SSHCall.Key) -> [String] {
        SSHCall(host: target.host, user: target.user, port: target.port, options: proofOptions(target),
                shape: .command("echo " + PasswordOnce.keyWorks)).arguments(key)
    }
}
#endif
