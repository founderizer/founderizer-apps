#if os(macOS)
import Foundation

/// **The password, once** (the owner, 4 November 2026: "maybe users will only have ssh access to that server.. with
/// nothing else installed", and he approved "the password once"). When a VPS takes none of this Mac's keys, or the
/// `sudo` of the user this Mac logs in as asks for a password, the app asks for that password once, uses it to put the
/// app's own key (`AppSSHKey`) on the server, and forgets it. Every connection after that one uses the key. After the
/// install the server's own hardening turns password login off (`hubsetup.py harden`), so the password is of use only
/// before it.
///
/// The password is a value in this Mac's memory and nowhere else: never written to a file, never in an argument, an
/// environment variable or a kept line, never sent to the hub, and cleared as soon as it is of no more use, as far as
/// Swift lets a program reach the memory it used.
///
/// **How `ssh` gets it** (`AskpassChannel`). `ssh` asks a password of its `SSH_ASKPASS` program alone, with
/// `SSH_ASKPASS_REQUIRE=force`. That program is a two-line script in a new folder of mode 700, which runs `cat` on a
/// named pipe beside it. The app writes the password into that pipe once, at the moment a reader has it open, then
/// removes the pipe: a second reader, a second prompt or a retry finds nothing, and `ssh` itself asks once
/// (`NumberOfPasswordPrompts=1`). A pipe keeps what is written to it in the kernel until it is read and never on a
/// disk; the folder is in this Mac user's own temporary folder, so no other user can open it; and neither the script
/// nor any argument or variable holds anything but paths. If `ssh` never asks (the server took a key, or refused the
/// connection), nothing is ever written.
///
/// **How `sudo` gets it**: on the first line of the standard input of the SSH session, for `sudo -S`, which reads it
/// there and from nowhere else. The install that follows feeds its own root steps the same way, for its own length
/// (`MachineInstaller`, `InstallPlan.Runs.rootWithPassword`), and clears the password when it ends.
public enum PasswordOnce {
    /// A password in this Mac's memory only. Its text is copied out of the `String` it was given at once, into bytes
    /// that `clear` overwrites; the caller lets go of its own copy.
    public final class Password: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8]

        public init(_ text: String) { bytes = Array(text.utf8) }

        public var isEmpty: Bool { lock.withLock { bytes.isEmpty } }

        /// The password and a newline, for `sudo -S` and the askpass pipe: the caller clears its copy after use.
        func line() -> [UInt8] { lock.withLock { bytes + [0x0a] } }

        /// The same text with the password taken out of it, done on bytes so that no `String` of it is ever made.
        func redact(_ text: String) -> String {
            lock.withLock {
                var source = Array(text.utf8)
                defer { PasswordOnce.wipe(&source) }
                guard !bytes.isEmpty, source.count >= bytes.count else { return text }
                var out: [UInt8] = [], at = 0
                while at < source.count {
                    if at + bytes.count <= source.count, source[at..<at + bytes.count].elementsEqual(bytes) {
                        out += Array("(not shown)".utf8); at += bytes.count
                    } else {
                        out.append(source[at]); at += 1
                    }
                }
                return String(decoding: out, as: UTF8.self)
            }
        }

        /// Overwrites the password and lets it go: it is empty from now on.
        public func clear() { lock.withLock { PasswordOnce.wipe(&bytes); bytes = [] } }

        deinit { PasswordOnce.wipe(&bytes) }
    }

    /// What the password did.
    public enum Outcome: Equatable, Sendable {
        /// The app's own key is on the server and opens it, and `target` reaches the server with that key from now on.
        /// `keepsPassword`: the `sudo` of that user asks for the password, so the install that follows gets the same
        /// `Password` (`MachineInstaller`'s `sudoPassword`), which clears it when it ends. Otherwise it is cleared already.
        case ready(InstallTarget, keepsPassword: Bool)
        /// One plain line of why not. The password is cleared.
        case refused(String)
    }

    /// What the remote program prints once the key is in `authorized_keys`, and how that user becomes root.
    static let keyAdded = "founderizer-key=added"
    static let sudoMark = "founderizer-sudo="
    /// What the server prints once this Mac reached it with its own key alone.
    static let keyWorks = "founderizer-key=works"

    /// **Logs in once with the password where `need` is SSH, or with this Mac's keys where it is `sudo`; puts the app's
    /// own public key in that account's `~/.ssh/authorized_keys`; reads with the same password whether that user's
    /// `sudo` takes it; then proves the key alone opens the server.** `keys` is the folder of the app's key (`~/.ssh`).
    public static func run(_ target: InstallTarget, need: ServerCheck.PasswordNeed, password: Password,
                           keys: URL = InstallTarget.keyFolder, ssh: String = "/usr/bin/ssh",
                           run: ShellRunner = Shell.local) async -> Outcome {
        var keeps = false
        defer { if !keeps { password.clear() } }
        let publicLine: String
        do { publicLine = try await AppSSHKey.make(in: keys, run: run) } catch {
            return .refused((error as? LocalizedError)?.errorDescription ?? "This Mac could not make its own SSH key.")
        }
        let program = "/bin/sh -c " + InstallPlan.quote(addKey(publicLine))
        var line = password.line()
        var input = Data(line)
        defer { wipe(&line); wipe(&input) }
        let plan = InstallPlan(job: .join, target: target, steps: [], redactions: [])
        let answer: LocalShell.Answer?
        switch need {
        case .ssh:
            guard let channel = try? AskpassChannel() else {
                return .refused("This Mac could not open the way its password goes to ssh.")
            }
            channel.serve(password)
            answer = try? await run("/usr/bin/env", ["SSH_ASKPASS=\(channel.helper)", "SSH_ASKPASS_REQUIRE=force", ssh]
                                    + passwordLogin(target) + [program], input, 90)
            channel.end()
        case .sudo:
            answer = try? await run(ssh, plan.arguments(for: program, runs: .login), input, 90)
        }
        guard let answer else { return .refused(ServerCheck.unreached(target.host)) }
        guard answer.status != 255 else { return .refused(refusal(answer, need: need, target: target)) }
        let said = answer.lines
        let sudo = said.last { $0.hasPrefix(sudoMark) }.map { String($0.dropFirst(sudoMark.count)) }
        if sudo == "refused" {
            return .refused(need == .sudo ? "sudo on \(target.host) did not take that password." : ServerCheck.notRoot(target.user))
        }
        guard said.contains(keyAdded), let sudo, ["root", "nopasswd", "password"].contains(sudo) else {
            return .refused("This Mac could not add its key to \(target.user)'s ~/.ssh/authorized_keys on \(target.host).")
        }
        var keyed = target
        keyed.identityFile = AppSSHKey.path(in: keys)
        let alone = InstallPlan(job: .join, target: keyed, steps: [], redactions: [])
        let works = (try? await run(ssh, alone.arguments(for: "echo \(keyWorks)", runs: .login), nil, 60))?
            .lines.contains(keyWorks) == true
        // With `sudo` the Mac's own keys still open the server, so a server that will not take the app's key keeps them.
        guard works || need == .sudo else {
            return .refused("\(target.host) still asks for a password with this Mac's key in \(target.user)'s "
                            + "authorized_keys, so its SSH server reads keys from elsewhere.")
        }
        keeps = sudo == "password"
        return .ready(works ? keyed : target, keepsPassword: keeps)
    }

    /// The arguments of the one login with a password: no key, one prompt, and the same host key rule as the install.
    static func passwordLogin(_ target: InstallTarget) -> [String] {
        ["-o", "BatchMode=no", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=20",
         "-o", "ServerAliveInterval=30", "-o", "ControlPath=none", "-o", "PubkeyAuthentication=no",
         "-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "NumberOfPasswordPrompts=1",
         "-p", String(target.port), target.destination]
    }

    /// **The program of that one session, as the user it logged in as.** First how that user becomes root: it is root,
    /// its `sudo` asks nothing, or `sudo -S` takes the password on the first line of standard input (`-k`: it asks
    /// every time, so it always reads that line). A user that cannot become root is said so, and nothing is left on
    /// the server. Then the key goes into `~/.ssh/authorized_keys`, once: `~/.ssh` is made with mode 700 and the file
    /// with 600 where they are not there, a file whose last line has no newline gets one first, and a key that is there
    /// already, with any comment or options, is not added again.
    static func addKey(_ line: String) -> String {
        "umask 077; if [ \"$(id -u)\" = 0 ]; then sudo=root; elif sudo -n true >/dev/null 2>&1; then sudo=nopasswd; "
            + "elif sudo -S -k -p '' true >/dev/null 2>&1; then sudo=password; else echo \(sudoMark)refused; exit 0; fi; "
            + "key=\(InstallPlan.quote(line)); blob=${key#* }; blob=${blob%% *}; dir=\"$HOME/.ssh\"; "
            + "file=\"$dir/authorized_keys\"; [ -d \"$dir\" ] || mkdir -m 700 \"$dir\" || exit 1; "
            + "if [ -s \"$file\" ] && [ -n \"$(tail -c 1 \"$file\")\" ]; then echo >> \"$file\"; fi; "
            + "grep -qF \"$blob\" \"$file\" 2>/dev/null || printf '%s\\n' \"$key\" >> \"$file\" || exit 1; "
            + "echo \(keyAdded); echo \"\(sudoMark)$sudo\""
    }

    /// Why `ssh` did not let the session in, in one line.
    static func refusal(_ answer: LocalShell.Answer, need: ServerCheck.PasswordNeed, target: InstallTarget) -> String {
        let host = target.host, said = answer.output.lowercased()
        if need == .ssh, let denied = said.range(of: "permission denied") {
            let ways = said[denied.upperBound...].drop { $0 != "(" }.prefix { $0 != ")" }
            guard ways.isEmpty || ways.contains("password") || ways.contains("keyboard-interactive") else {
                return "\(host) takes SSH keys only, so a password cannot open it. Give it this Mac's key at your provider."
            }
            return "\(host) did not take that password for \(target.user)."
        }
        switch ServerCheck.sshRefused(answer.output, host: host) {
        case .stop(let says): return says
        default: return ServerCheck.keyRefused(host)
        }
    }

    /// Overwrites bytes in place, as far as Swift lets a program reach the memory it used.
    static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) }
        }
    }

    static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) }
        }
    }
}

/// **The one-use channel of a password to `ssh`'s askpass program** (`PasswordOnce`): a folder of mode 700 in this
/// Mac user's own temporary folder, a named pipe of mode 600 in it, and the program, which is `cat` on that pipe. The
/// app writes the password into the pipe once, when a reader has it open, and removes it then: nothing is ever kept
/// in a file, and nothing is written at all if nobody asks.
final class AskpassChannel: @unchecked Sendable {
    let folder: URL
    /// The program `SSH_ASKPASS` names. It holds the pipe's path and nothing else.
    var helper: String { folder.appendingPathComponent("askpass").path }
    var pipe: String { folder.appendingPathComponent("pipe").path }
    private let lock = NSLock()
    private var ended = false
    private var wasRead = false

    init(in base: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) throws {
        folder = base.appendingPathComponent("founderizer-askpass-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            guard mkfifo(pipe, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try "#!/bin/sh\nexec /bin/cat -- \(InstallPlan.quote(pipe))\n".write(toFile: helper, atomically: false,
                                                                                 encoding: .utf8)
            guard chmod(helper, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            end()
            throw error
        }
    }

    /// Whether a reader took the password.
    var given: Bool { lock.withLock { wasRead } }

    /// Gives the password to the first reader of the pipe, on a thread of its own, until `end`. The pipe opens for
    /// writing only once a reader holds it, so until then nothing is written anywhere.
    func serve(_ password: PasswordOnce.Password) {
        let pipe = self.pipe
        Thread.detachNewThread { [self] in
            while !lock.withLock({ ended }) {
                let fd = Darwin.open(pipe, O_WRONLY | O_NONBLOCK)
                guard fd >= 0 else {
                    guard errno == ENXIO else { return }        // no pipe any more
                    usleep(10_000)
                    continue
                }
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)                // a reader that went away is no signal to this app
                var line = password.line()
                _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                PasswordOnce.wipe(&line)
                Darwin.close(fd)
                unlink(pipe)
                lock.withLock { wasRead = true }
                return
            }
        }
    }

    /// Ends the channel: the pipe, the program and their folder are removed.
    func end() {
        lock.withLock { ended = true }
        try? FileManager.default.removeItem(at: folder)
    }
}
#endif
