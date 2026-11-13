#if os(macOS)
import Foundation

/// Where one step of an install stands, as the owner watches it.
public struct InstallProgress: Equatable, Sendable, Identifiable {
    public enum State: String, Equatable, Sendable { case waiting, running, done, failed }
    public let step: String
    public let title: String
    public let says: String
    public let state: State
    /// The last lines the machine itself printed, with the owner's own secrets taken out.
    public let lines: [String]
    /// What went wrong, in one line, when this step failed.
    public let detail: String?
    public var id: String { step }

    public init(step: String, title: String, says: String, state: State, lines: [String] = [], detail: String? = nil) {
        self.step = step; self.title = title; self.says = says; self.state = state
        self.lines = lines; self.detail = detail
    }
}

public enum InstallError: LocalizedError, Equatable, Sendable {
    case cannotStart(String)
    case step(String, String)
    case notRoot(String)
    case timedOut(String)
    case noClaimCode
    case noChecklist
    /// The check of the server stopped the install before anything changed on it, with its one line of cause and fix
    /// (`ServerCheck.Verdict.stop`).
    case checkStopped(String)
    /// The server asks for a password this install does not hold (`PasswordOnce`).
    case needsPassword(ServerCheck.PasswordNeed)

    public var errorDescription: String? {
        switch self {
        case .cannotStart(let says): return says
        case .step(let title, let says): return "\(title): \(says)"
        case .notRoot(let user): return ServerCheck.notRoot(user)
        case .timedOut(let title): return String(l10n: "\(title) took too long. The server is still working, or it cannot be reached.")
        case .noClaimCode: return String(l10n: "The installer did not print a link code for this Mac. Read its log on the server.")
        case .noChecklist: return String(l10n: "The server did not answer its checks. Nothing was installed twice.")
        case .checkStopped(let says): return says
        case .needsPassword(.sudo): return String(l10n: "sudo on that server asks for a password.")
        case .needsPassword(.ssh): return String(l10n: "That server takes none of this Mac's SSH keys, and asks for a password.")
        }
    }

    /// **What stopped the install, in a few plain words** (fix round 3, item 51): a step that failed carried the last
    /// line `ssh` or the machine printed ("ssh: connect to host 203.0.113.9 port 22: Connection refused"), which is not
    /// his. So it says why when this Mac can tell — the server could not be reached, or it did not take his key — or
    /// the installer's own reason, and else where it stopped. The line keeps the machine's words on its hover. Every
    /// other stop is in this app's own words already. `host` is the server's address as he typed it.
    public func plain(host: String) -> String {
        guard case .step(let title, let says) = self else { return errorDescription ?? String(l10n: "The install stopped.") }
        let said = says.lowercased(), server = host.isEmpty ? String(l10n: "the server") : host
        if let mark = InstallPlan.stopMarks.first(where: says.contains),
           let reason = says.components(separatedBy: mark).last?.trimmingCharacters(in: .whitespaces), !reason.isEmpty {
            return reason.prefix(1).uppercased() + reason.dropFirst()
        }
        if InstallError.unreached(said) { return ServerCheck.unreached(server, said: said) }
        if InstallError.keyRefused(said) { return ServerCheck.keyRefused(server) }
        if InstallError.ownWords.contains(says) { return says }
        return String(l10n: "It stopped at “\(title)”.")
    }

    /// `ssh`'s own words when it did not reach the server at all, or its status for that (255) with nothing printed.
    /// Only `ssh`'s: a package mirror that timed out on the server is not this Mac failing to reach it.
    static func unreached(_ said: String) -> Bool {
        said.hasPrefix("ssh: ") && ["connection refused", "timed out", "no route to host", "could not resolve hostname",
                                    "network is unreachable"].contains(where: said.contains)
            || ["kex_exchange_identification", "during banner exchange", "answered 255."].contains(where: said.contains)
            || said.hasPrefix("connection closed by ") && said.contains(" port ")
    }
    /// `ssh` or the server turning his key down. A Mac whose agent holds many keys offers them all, and the server then
    /// ends with too many failures and not with "Permission denied".
    static func keyRefused(_ line: String) -> Bool {
        let said = line.lowercased()
        return said.contains("permission denied (publickey") || said.contains("too many authentication failures")
    }
    /// The lines this app gives a step that failed: already his words.
    static let ownWords = [InstallPlan.hubSystems, InstallPlan.joinSystems,
                           String(l10n: "It did not answer which user this is."), MachineInstaller.notOnYourNetwork,
                           NetworkSignIn.notApproved, NetworkSignIn.notStarted,
                           String(l10n: "The hub refused the link code."), String(l10n: "The join did not reach the checks of this server.")]
}

/// Installs one Linux machine of a fleet from this Mac, over the owner's own SSH connection (PRODUCT.md P3).
///
/// It runs the plan's steps in order and reports each one. Three things it never does: read the owner's SSH key
/// (`ssh` reads it), put the Tailscale auth key in an argument (it goes on standard input), or keep a line that
/// holds the key or the one-time join code (every line goes through `plan.redact`).
///
/// **A sudo password, where the server's `sudo` asks for one** (`PasswordOnce`): the install holds it in memory for
/// its own length and no longer. Each root step gets it on the first line of its standard input, for `sudo -S`, and
/// only once the check read a `sudo` that asks for it, so a `sudo` that asks nothing is never handed it to pass on to
/// the program. It is in no argument and no kept line, and it is cleared when the install ends, however it ends.
///
/// A step that fails stops the install. Nothing here is undone: each installer step checks first, so the owner
/// fixes what the line says and starts the same install again.
public actor MachineInstaller {
    private let plan: InstallPlan
    private let authKey: String
    private let ssh: String
    private let sudoPassword: PasswordOnce.Password?
    /// Whether the root steps feed `sudo -S` the password: set by the check, which read a `sudo` that asks for one.
    private var feedsSudo = false
    private let claim: @Sendable (String, URL) async throws -> Void
    private var lastOutput = ""
    /// Where the install reaches the machine: the address the owner gave, until the network step puts the machine on
    /// the private network, and from then on its address there. Both installers let SSH in over that network only
    /// (`hubsetup.py firewall`), so a step after them that went to a public address would not arrive, and this is the
    /// connection that is kept for the machine.
    public private(set) var reached: InstallTarget

    /// `ssh` and `claim` are given in the tests, so the whole path is proved without a machine. `sudoPassword` is the
    /// password `PasswordOnce` kept for a `sudo` that asks for one.
    public init(plan: InstallPlan, authKey: String, ssh: String = "/usr/bin/ssh", sudoPassword: PasswordOnce.Password? = nil,
                claim: (@Sendable (String, URL) async throws -> Void)? = nil) {
        self.plan = plan
        self.authKey = authKey
        self.ssh = ssh
        self.sudoPassword = sudoPassword
        self.reached = plan.target
        self.claim = claim ?? { code, url in try await MachineInstaller.sendClaim(code: code, to: url) }
    }

    /// Runs the whole install and answers with the machine's own checklist. `report` is called for each step as it
    /// starts and as it ends, so the screen follows the install without asking.
    public func run(report: @Sendable @escaping (InstallProgress) -> Void) async throws -> VerifyChecklist {
        defer { sudoPassword?.clear() }
        for step in plan.steps {
            report(InstallProgress(step: step.id, title: step.title, says: step.says, state: .running))
            do {
                let lines = try await perform(step, report: report)
                if step.id == "network", let address = InstallPlan.privateAddress(in: lines) { reached.host = address }
                if case .verify = step.action {
                    guard let checklist = VerifyChecklist.read(output: lines.joined(separator: "\n"),
                                                               readAt: Date().timeIntervalSince1970) else {
                        throw InstallError.noChecklist
                    }
                    report(InstallProgress(step: step.id, title: step.title, says: step.says, state: .done,
                                           lines: [checklist.line]))
                    return checklist
                }
                report(InstallProgress(step: step.id, title: step.title, says: step.says, state: .done,
                                       lines: lines.suffix(12)))
            } catch {
                let says = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                report(InstallProgress(step: step.id, title: step.title, says: step.says, state: .failed,
                                       lines: lastLines(), detail: says))
                throw error
            }
        }
        throw InstallError.noChecklist
    }

    private func lastLines() -> [String] { Array(lines(of: lastOutput).suffix(12)) }

    private func perform(_ step: InstallStep, report: @Sendable (InstallProgress) -> Void) async throws -> [String] {
        switch step.action {
        case .check(let every, let within):
            return try await check(step, every: every, within: within, report: report)
        case .run(let program):
            return try await ssh(program, title: step.title, timeout: 1800)
        case .join(let line):
            // A non-zero status is the line's own answer about `verify`, not about the join: it is tolerated only
            // when the machine printed `verify`'s last word, and the checks that follow say what is true.
            let answer = try await remote(line, stdin: nil, timeout: 3600, runs: .root)
            let lines = self.lines(of: redact(answer.output))
            lastOutput = redact(answer.output)
            guard answer.status == 0 || lines.contains(where: { $0.contains(VerifyChecklist.readyLine) }) else {
                throw InstallError.step(step.title, lines.last ?? String(l10n: "The join did not reach the checks of this server."))
            }
            return lines
        case .sendAuthKey(let program):
            // Tailscale's install may wait for apt's lock while a new server runs its first updates.
            return try await ssh(program, title: step.title, stdin: Data(authKey.utf8),
                                 timeout: Double(2 * InstallPlan.aptLockWait + 600))
        case .detach(let program):
            return try await ssh(program, title: step.title, timeout: 120)
        case .waitFor(let program, let mark, let every, let within):
            return try await wait(program, mark: mark, every: every, within: within, step: step, report: report)
        case .signIn(let start, let check, let every, let within):
            return try await signIn(start, check: check, every: every, within: within, step: step, report: report)
        case .claim:
            guard let found = ClaimCode.found(in: lastOutput) else { throw InstallError.noClaimCode }
            try await claim(found.code, found.claim)
            return [String(l10n: "This Mac claimed the hub at \(found.claim.host ?? "").")]
        case .verify(let program):
            return try await ssh(program, title: step.title, timeout: 1800, allowFailure: true)
        }
    }

    /// **The check of the server, as the install's first step** (`ServerCheck`): the user, whether it is root, the
    /// system, and the rest of what the screen checked before the owner pressed Install. A machine that cannot take
    /// the install is said so here, before anything on it changes, and not after ten minutes. A machine that is
    /// still busy with its first start is read again until it is not, and its reason is the step's line meanwhile.
    private func check(_ step: InstallStep, every: Double, within: Double,
                       report: @Sendable (InstallProgress) -> Void) async throws -> [String] {
        let deadline = Date().addingTimeInterval(within)
        while true {
            let lines = try await ssh("/bin/sh -s", title: step.title, stdin: Data(ServerCheck.script.utf8), timeout: 120,
                                      runs: .login)
            guard let reading = ServerCheck.read(lines.joined(separator: "\n")) else {
                throw InstallError.step(step.title, String(l10n: "It did not answer which user this is."))
            }
            if reading.uid != 0 && !plan.target.becomeRoot { throw InstallError.notRoot(plan.target.user) }
            let holds = sudoPassword.map { !$0.isEmpty } ?? false
            switch ServerCheck.verdict(reading, job: plan.job, sshPort: reached.port, holdsSudoPassword: holds) {
            case .ready(let summary, let changes):
                // A password is fed only to a `sudo` that asks for one; one that asks nothing never sees it.
                feedsSudo = holds && reading.sudo == .password && plan.target.becomeRoot
                if !feedsSudo { sudoPassword?.clear() }
                return [summary, changes]
            case .stop(let says): throw InstallError.checkStopped(says)
            case .needsPassword(let need): throw InstallError.needsPassword(need)
            case .wait(let reason):
                guard Date() < deadline else { throw InstallError.timedOut(step.title) }
                report(InstallProgress(step: step.id, title: step.title, says: step.says, state: .running, lines: [reason]))
                try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            }
        }
    }

    /// Reads the installer's log until it prints `mark`. Each read that finds the installer at a new step of its own
    /// ("Founderizer step 14: security updates") says so as this step's line, which the first run's status line reads
    /// (`InstallPhases.status`).
    private func wait(_ program: String, mark: String, every: Double, within: Double, step: InstallStep,
                      report: @Sendable (InstallProgress) -> Void) async throws -> [String] {
        let deadline = Date().addingTimeInterval(within)
        var said: String?
        while Date() < deadline {
            let lines = try await ssh(program, title: step.title, timeout: 120, allowFailure: true)
            let text = lines.joined(separator: "\n")
            if let stop = InstallPlan.stopLine(in: lines) {
                throw InstallError.step(step.title, stop)
            }
            if text.contains(mark) { return lines }
            if let now = lines.last(where: { InstallPhases.installerStep($0) != nil }), now != said {
                said = now
                report(InstallProgress(step: step.id, title: step.title, says: step.says, state: .running, lines: [now]))
            }
            try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
        }
        throw InstallError.timedOut(step.title)
    }

    /// Tailscale's sign-in: started on the machine, then read until the machine is on the network. The link goes to the
    /// screen as this step's lines, and the owner's approval ends the wait (`NetworkSignIn`).
    private func signIn(_ start: String, check: String, every: Double, within: Double, step: InstallStep,
                        report: @Sendable (InstallProgress) -> Void) async throws -> [String] {
        _ = try await ssh(start, title: step.title, timeout: 900)
        let deadline = Date().addingTimeInterval(within)
        var shown = false               // a link he never saw was not his to approve
        var answered = false            // the last read reached the machine: one that fails is not the end of the wait
        while Date() < deadline {
            let lines = try await ssh(check, title: step.title, timeout: 60, allowFailure: true)
            let reading = NetworkSignIn.read(lines)
            answered = lines.contains { $0.hasPrefix(NetworkSignIn.nameMark) }
            switch reading {
            case .on: return lines
            case .ended(let says):
                throw InstallError.step(step.title, says == NetworkSignIn.notApproved && !shown
                                        ? NetworkSignIn.notStarted : says)
            case .waiting(let link):
                if link != nil {
                    shown = true
                    report(InstallProgress(step: step.id, title: step.title, says: step.says, state: .running, lines: lines))
                }
            }
            try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
        }
        guard answered else { throw InstallError.timedOut(step.title) }
        throw InstallError.step(step.title, shown ? NetworkSignIn.notApproved : NetworkSignIn.notStarted)
    }

    private func ssh(_ program: String, title: String, stdin: Data? = nil, timeout: Double,
                     allowFailure: Bool = false, runs: InstallPlan.Runs = .root) async throws -> [String] {
        let answer = try await remote(program, stdin: stdin, timeout: timeout, runs: runs)
        let text = redact(answer.output)
        lastOutput = text
        guard answer.status == 0 || allowFailure else {
            // 255 is `ssh` itself, which can end with "Disconnected from …" after the line that says why. Any other
            // status is the program's: a `git` on the server that was refused its own key is not his SSH key.
            let said = lines(of: text)
            throw InstallError.step(title, (answer.status == 255 ? said.last(where: InstallError.keyRefused) : nil)
                                    ?? said.last ?? "The server answered \(answer.status).")
        }
        return lines(of: text)
    }

    /// One program on the machine. A root step of an install that feeds `sudo -S` carries the password on the first
    /// line of its standard input, and the step's own input after it; the copy made for that is cleared after the run.
    private func remote(_ program: String, stdin: Data?, timeout: Double,
                        runs: InstallPlan.Runs) async throws -> LocalShell.Answer {
        guard runs == .root, feedsSudo, let password = sudoPassword, !password.isEmpty else {
            return try await LocalShell.run(ssh, plan.arguments(for: program, reaching: reached, runs: runs), stdin: stdin,
                                            timeout: timeout)
        }
        var line = password.line()
        var input = Data(capacity: line.count + (stdin?.count ?? 0))
        input.append(contentsOf: line)
        if let stdin { input.append(stdin) }
        defer { PasswordOnce.wipe(&line); PasswordOnce.wipe(&input) }
        return try await LocalShell.run(ssh, plan.arguments(for: program, reaching: reached, runs: .rootWithPassword),
                                        stdin: input, timeout: timeout)
    }

    /// A line with the owner's secrets taken out of it: the plan's, and the sudo password this install holds.
    private func redact(_ text: String) -> String {
        let line = plan.redact(text)
        return sudoPassword?.redact(line) ?? line
    }

    private func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The claim of a new hub, from this Mac and from nowhere else: the code on the request body, to the address the
    /// installer printed. The hub takes the address this call comes from as the owner's own (`hubsetup.py`).
    /// The claim's one refusal of this Mac's own: the address is not on the owner's private network, so nothing is sent.
    public static let notOnYourNetwork = String(l10n: "The installer printed an address that is not on your own network.")

    public static func sendClaim(code: String, to url: URL) async throws {
        guard url.scheme == "http", let host = url.host, ClaimCode.isPrivateAddress(host),
              url.path == "/claim" else {
            throw InstallError.step(String(l10n: "Claim the hub"), notOnYourNetwork)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(code.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let (data, answer) = try await URLSession(configuration: configuration).data(for: request)
        let said = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let http = answer as? HTTPURLResponse, http.statusCode == 200 else {
            throw InstallError.step(String(l10n: "Claim the hub"), said.isEmpty ? String(l10n: "The hub refused the link code.") : said)
        }
    }
}

extension InstallTarget {
    /// **The server an address names, read through this Mac's own `ssh -G`** (`named(_:options:general:...)`): a
    /// `Host` alias of `~/.ssh/config` gives its hostname, user, port and key, and an address that names no alias stays
    /// as it was typed. `ssh -G` reads the configuration only; it connects to nothing.
    ///
    /// **An address that no `Host` block names, typed with no user, takes the alias that gives it as its `HostName`**
    /// (the report of 13 November 2026: a server chosen from the provider's list was checked as root on port 22, while
    /// the person reached that same address as `deploy` through an alias of theirs). Its user, port and key are then
    /// the alias's, as if its name had been typed: an alias with user root first, else the first that the files give.
    /// An alias that goes through another host (`SSHOptions.proxied`) is not one, because the install's `ssh` goes
    /// straight to the address. `home` is the folder whose `.ssh/config` is read.
    public static func named(_ address: String, ssh: String = "/usr/bin/ssh", home: String = NSHomeDirectory(),
                             run: ShellRunner = Shell.local) async -> InstallTarget {
        let typed = address.trimmingCharacters(in: .whitespaces)
        let host = typed.lastIndex(of: "@").map { String(typed[typed.index(after: $0)...]) } ?? typed
        func options(_ name: String) async -> SSHOptions? {
            guard let answer = try? await run(ssh, ["-G", name], nil, 20), answer.ok else { return nil }
            return SSHOptions.read(answer.output)
        }
        // A name `ssh` would read as one of its own options never reaches it.
        guard host.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,252}$", options: .regularExpression) != nil else {
            return named(typed, options: nil, localUser: NSUserName(), home: home) { _ in false }
        }
        var mine = await options(host)
        let general = await options("founderizer-\(UUID().uuidString.lowercased()).invalid")
        if !typed.contains("@"), let found = mine, let general, found.hostname.lowercased() == host.lowercased(),
           found.user == general.user, found.port == general.port, found.identityFiles == general.identityFiles,
           !found.proxied {
            var aliases: [SSHOptions] = []
            for name in SSHConfig.aliases(of: host, config: URL(fileURLWithPath: home + "/.ssh/config"), home: home) {
                if let alias = await options(name), alias.hostname.lowercased() == host.lowercased(), !alias.proxied {
                    aliases.append(alias)
                }
            }
            mine = aliases.first { $0.user == "root" } ?? aliases.first ?? mine
        }
        return named(typed, options: mine, general: general, localUser: NSUserName(), home: home) {
            FileManager.default.fileExists(atPath: $0)
        }
    }
}
#endif
