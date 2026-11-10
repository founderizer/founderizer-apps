import Foundation
import Testing
@testable import FleetCore

/// **The password, once** (`PasswordOnce`), and the app's own key it puts on a server (`AppSSHKey`): the one-use channel
/// to `ssh`'s askpass program, the key file, and the whole session against a stand-in `ssh` that answers as a server.
struct PasswordOnceTests {
    private static func folder(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fleet-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    /// One program and its standard output, with nothing on its input.
    private static func run(_ path: String, _ arguments: [String] = [], environment: [String: String]? = nil)
        throws -> (status: Int32, output: String) {
        let child = Process(), out = Pipe()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = arguments
        if let environment { child.environment = environment }
        child.standardOutput = out; child.standardError = FileHandle.nullDevice; child.standardInput = FileHandle.nullDevice
        try child.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()
        return (child.terminationStatus, text)
    }

    // MARK: the channel to the askpass program

    @Test func thePasswordGoesToTheAskpassProgramOnceAndIsWrittenNowhere() throws {
        let secret = "s3cret Password!"
        let channel = try AskpassChannel()
        defer { channel.end() }
        // The folder is this Mac user's alone, and what is in it is a program that holds a path and a pipe.
        #expect(Self.mode(channel.folder.path) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: channel.folder.path).sorted() == ["askpass", "pipe"])
        #expect(Self.mode(channel.helper) == 0o700)
        let program = try String(contentsOfFile: channel.helper, encoding: .utf8)
        #expect(program == "#!/bin/sh\nexec /bin/cat -- '\(channel.pipe)'\n")
        var status = stat()
        #expect(lstat(channel.pipe, &status) == 0 && status.st_mode & S_IFMT == S_IFIFO && status.st_mode & 0o777 == 0o600)

        channel.serve(PasswordOnce.Password(secret))
        let first = try Self.run(channel.helper, ["root@203.0.113.9's password: "])
        #expect(first.status == 0 && first.output == secret + "\n")
        #expect(channel.given)
        // A second prompt, a retry, or anyone else finds nothing.
        let second = try Self.run(channel.helper, ["again: "])
        #expect(second.status != 0 && !second.output.contains(secret))
        channel.end()
        #expect(!FileManager.default.fileExists(atPath: channel.folder.path))
    }

    @Test func aChannelThatNobodyReadsWritesNothing() throws {
        let channel = try AskpassChannel()
        channel.serve(PasswordOnce.Password("never read"))
        usleep(60_000)
        channel.end()
        #expect(!channel.given)
        #expect(!FileManager.default.fileExists(atPath: channel.folder.path))
    }

    @Test func aPasswordIsKeptAsBytesThatClearOverwrites() {
        let password = PasswordOnce.Password("hunter22")
        #expect(!password.isEmpty)
        #expect(password.line() == Array("hunter22\n".utf8))
        #expect(password.redact("sudo said hunter22, twice: hunter22") == "sudo said (not shown), twice: (not shown)")
        #expect(password.redact("nothing here") == "nothing here")
        password.clear()
        #expect(password.isEmpty && password.line() == [0x0a])
        #expect(password.redact("hunter22") == "hunter22")
    }

    // MARK: the app's own key

    @Test func theAppsOwnKeyIsMadeOnceWithItsMacInItsComment() async throws {
        let folder = try Self.folder("key")
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = folder.appendingPathComponent("ssh")          // a folder that is not there yet is made, of mode 700
        let line = try await AppSSHKey.make(in: keys, macName: "Sam’s Mac Studio")
        #expect(line.hasPrefix("ssh-ed25519 ") && line.hasSuffix(" founderizer@Sams-Mac-Studio"))
        #expect(AppSSHKey.path(in: keys) == keys.appendingPathComponent("founderizer_ed25519").path)
        #expect(Self.mode(keys.path) == 0o700)
        #expect(Self.mode(AppSSHKey.path(in: keys)) == 0o600)
        #expect(AppSSHKey.publicLine(in: keys) == line)
        // Made once: a second make keeps it, and puts right a mode that drifted.
        _ = chmod(AppSSHKey.path(in: keys), 0o644)
        #expect(try await AppSSHKey.make(in: keys, macName: "Another Mac") == line)
        #expect(Self.mode(AppSSHKey.path(in: keys)) == 0o600)
        // A public half that went missing comes back from the private one.
        try FileManager.default.removeItem(atPath: AppSSHKey.path(in: keys) + ".pub")
        let restored = try await AppSSHKey.make(in: keys, macName: "Sam’s Mac Studio")
        #expect(restored.split(separator: " ")[1] == line.split(separator: " ")[1])
        #expect(AppSSHKey.path() == NSHomeDirectory() + "/.ssh/founderizer_ed25519")
    }

    @Test func aKeyFileThatIsNoKeyIsNotTakenForOne() async throws {
        let keys = try Self.folder("bad-key")
        defer { try? FileManager.default.removeItem(at: keys) }
        try "not a key".write(toFile: AppSSHKey.path(in: keys), atomically: true, encoding: .utf8)
        await #expect(throws: AppSSHKey.Failure.self) { _ = try await AppSSHKey.make(in: keys, macName: "Studio") }
        #expect(try String(contentsOfFile: AppSSHKey.path(in: keys), encoding: .utf8) == "not a key")
    }

    @Test func theKeysCommentNamesTheMacInTheLettersOfAHostName() {
        #expect(AppSSHKey.comment("Sam's MacBook Pro") == "founderizer@Sams-MacBook-Pro")
        #expect(AppSSHKey.comment("Studio.local") == "founderizer@Studio.local")
        #expect(AppSSHKey.comment("  ") == "founderizer@mac")
        #expect(AppSSHKey.comment("büro; rm -rf /") == "founderizer@b-ro-rm--rf")
    }

    // MARK: the key into authorized_keys, by the session's own program

    private static let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOmCcPzkdz2Lq9X4yGx8Wm7dD3bR7d5c3Tq8E founderizer@Studio"

    /// The program as the server's `sh` runs it, as a user whose home is `home` and whose `sudo` asks nothing.
    private static func addKey(home: URL, bin: URL) throws -> String {
        try run("/bin/dash", ["-c", PasswordOnce.addKey(key)],
                environment: ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin"]).output
    }

    @Test func theKeyGoesIntoAuthorizedKeysOnceWithTheirModes() throws {
        let folder = try Self.folder("authorized")
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("home"), bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\n[ \"$*\" = '-n true' ]\n".write(toFile: bin.appendingPathComponent("sudo").path, atomically: true, encoding: .utf8)
        _ = chmod(bin.appendingPathComponent("sudo").path, 0o755)
        let said = try Self.addKey(home: home, bin: bin)
        #expect(said.contains(PasswordOnce.keyAdded) && said.contains(PasswordOnce.sudoMark + "nopasswd"))
        let file = home.appendingPathComponent(".ssh/authorized_keys").path
        #expect(Self.mode(home.appendingPathComponent(".ssh").path) == 0o700)
        #expect(Self.mode(file) == 0o600)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == Self.key + "\n")
        _ = try Self.addKey(home: home, bin: bin)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == Self.key + "\n", "the key was added twice")

        // A file of his own: a last line with no newline gets one first, and the same key with options is not added again.
        try "ssh-rsa AAAAB3NzaC1yc2E his-laptop".write(toFile: file, atomically: true, encoding: .utf8)
        _ = chmod(file, 0o644)
        _ = try Self.addKey(home: home, bin: bin)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "ssh-rsa AAAAB3NzaC1yc2E his-laptop\n" + Self.key + "\n")
        #expect(Self.mode(file) == 0o644, "his own file's mode was changed")
        let blob = Self.key.split(separator: " ")[1]
        try "from=\"10.0.0.1\" ssh-ed25519 \(blob) old-comment\n".write(toFile: file, atomically: true, encoding: .utf8)
        _ = try Self.addKey(home: home, bin: bin)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "from=\"10.0.0.1\" ssh-ed25519 \(blob) old-comment\n")
    }

    // MARK: the whole session, against a stand-in server

    /// A stand-in `ssh` that answers as a server would: the password through `SSH_ASKPASS` where the login takes no key,
    /// the app's key where one is given, and then the remote program, run here with the server's home and `sudo`.
    private final class Server {
        let folder: URL
        var ssh: String { folder.appendingPathComponent("ssh").path }
        var keys: URL { folder.appendingPathComponent("keys") }
        var home: URL { folder.appendingPathComponent("home") }

        /// `sudo`: `password` asks for the server's password, `nopasswd` asks nothing, `none` refuses. `ways` is what
        /// the server lists when it turns a login down.
        init(password: String, sudo: String = "password", ways: String = "publickey,password") throws {
            folder = try PasswordOnceTests.folder("server")
            for name in ["keys", "home", "bin"] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try password.write(toFile: folder.appendingPathComponent("expected").path, atomically: true, encoding: .utf8)
            try write("bin/sudo", """
            #!/bin/sh
            expected=$(cat "\(folder.path)/expected")
            case "$*" in
              "-n true") [ "\(sudo)" = nopasswd ] ;;
              *-S*) [ "\(sudo)" = password ] && IFS= read -r given && [ "$given" = "$expected" ] ;;
              *) exit 1 ;;
            esac
            """)
            try write("ssh", """
            #!/bin/sh
            dir="\(folder.path)"
            printf '%s\\n' "$@" >> "$dir/argv"
            env >> "$dir/env"
            key=""; prev=""; nokey=no
            for a in "$@"; do
              [ "$prev" = "-i" ] && key="$a"
              [ "$a" = "PubkeyAuthentication=no" ] && nokey=yes
              prev="$a"; last="$a"
            done
            denied() { echo "root@203.0.113.9: Permission denied (\(ways))." >&2; exit 255; }
            if [ "$nokey" = yes ]; then
              case "\(ways)" in *password*) ;; *) denied ;; esac
              [ "$SSH_ASKPASS_REQUIRE" = force ] || denied
              given=$("$SSH_ASKPASS" "root@203.0.113.9's password: ") || denied
              [ "$given" = "$(cat "$dir/expected")" ] || denied
              if again=$("$SSH_ASKPASS" "Verification code: " 2>/dev/null) && [ -n "$again" ]; then
                echo "the askpass program answered twice" >&2; exit 254
              fi
            elif [ -n "$key" ]; then
              grep -qF "$(cut -d ' ' -f 2 "$key.pub")" "$dir/home/.ssh/authorized_keys" 2>/dev/null || denied
            fi
            HOME="$dir/home" PATH="$dir/bin:$PATH" exec /bin/sh -c "$last"
            """)
        }

        private func write(_ name: String, _ text: String) throws {
            let path = folder.appendingPathComponent(name).path
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            _ = chmod(path, 0o755)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        private func read(_ name: String) -> String {
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        var argv: String { read("argv") }
        var env: String { read("env") }
        var authorized: String { read("home/.ssh/authorized_keys") }
    }

    private static let target = InstallTarget(host: "203.0.113.9")

    /// **A VPS that takes none of this Mac's keys**: one login with the password, the app's key into authorized_keys,
    /// and from then on the key alone. The password is in no argument and no variable, and it stays for the install
    /// only because that user's `sudo` asks for it.
    @Test func aServerThatTakesNoKeyGetsTheAppsKeyWithThePasswordOnce() async throws {
        let secret = "correct horse battery"
        let server = try Server(password: secret)
        let password = PasswordOnce.Password(secret)
        let outcome = await PasswordOnce.run(Self.target, need: .ssh, password: password, keys: server.keys, ssh: server.ssh)
        var keyed = Self.target
        keyed.identityFile = AppSSHKey.path(in: server.keys)
        #expect(outcome == .ready(keyed, keepsPassword: true))
        #expect(!password.isEmpty, "the install that follows needs the password for sudo")
        let line = try #require(AppSSHKey.publicLine(in: server.keys))
        #expect(server.authorized == line + "\n")
        // The login asked once, with no key, through the askpass program; the key alone opened the second session.
        #expect(server.argv.contains("PubkeyAuthentication=no") && server.argv.contains("NumberOfPasswordPrompts=1"))
        #expect(server.argv.contains("IdentitiesOnly=yes") && server.argv.contains(AppSSHKey.path(in: server.keys)))
        #expect(server.env.contains("SSH_ASKPASS_REQUIRE=force"))
        #expect(!server.argv.contains(secret), "the password stood in an argument")
        #expect(!server.env.contains(secret), "the password stood in a variable")
        let askpass = try #require(server.env.split(separator: "\n").first { $0.hasPrefix("SSH_ASKPASS=") })
        #expect(!FileManager.default.fileExists(atPath: String(askpass.dropFirst("SSH_ASKPASS=".count))),
                "the askpass program outlived the login")
    }

    @Test func aPasswordThatSudoNeedsNotIsForgottenAtOnce() async throws {
        let server = try Server(password: "correct horse battery", sudo: "nopasswd")
        let password = PasswordOnce.Password("correct horse battery")
        let outcome = await PasswordOnce.run(Self.target, need: .ssh, password: password, keys: server.keys, ssh: server.ssh)
        guard case .ready(let target, keepsPassword: false) = outcome else { Issue.record("\(outcome)"); return }
        #expect(target.identityFile == AppSSHKey.path(in: server.keys))
        #expect(password.isEmpty)
    }

    /// **A `sudo` that asks for a password**, where this Mac's keys open the server: the key goes on over them, and
    /// the password only to `sudo -S`, on standard input.
    @Test func aSudoThatAsksForThePasswordGetsItOnStandardInput() async throws {
        let server = try Server(password: "correct horse battery")
        let password = PasswordOnce.Password("correct horse battery")
        let deploy = InstallTarget(host: "203.0.113.9", user: "deploy", becomeRoot: true)
        let outcome = await PasswordOnce.run(deploy, need: .sudo, password: password, keys: server.keys, ssh: server.ssh)
        var keyed = deploy
        keyed.identityFile = AppSSHKey.path(in: server.keys)
        #expect(outcome == .ready(keyed, keepsPassword: true))
        #expect(server.argv.contains("BatchMode=yes") && !server.argv.contains("PubkeyAuthentication=no"))
        #expect(!server.argv.contains("correct horse battery"))
        #expect(!server.env.contains("SSH_ASKPASS_REQUIRE"))
    }

    @Test func aWrongPasswordIsRefusedAndForgotten() async throws {
        let server = try Server(password: "correct horse battery")
        let wrong = PasswordOnce.Password("Tr0ub4dor&3")
        #expect(await PasswordOnce.run(Self.target, need: .ssh, password: wrong, keys: server.keys, ssh: server.ssh)
                == .refused("203.0.113.9 did not take that password for root."))
        #expect(wrong.isEmpty)
        #expect(server.authorized.isEmpty)
        let sudo = try Server(password: "correct horse battery")
        let deploy = InstallTarget(host: "203.0.113.9", user: "deploy", becomeRoot: true)
        #expect(await PasswordOnce.run(deploy, need: .sudo, password: PasswordOnce.Password("Tr0ub4dor&3"), keys: sudo.keys,
                                       ssh: sudo.ssh) == .refused("sudo on 203.0.113.9 did not take that password."))
    }

    @Test func aServerThatTakesKeysOnlyIsNotAskedForAPassword() async throws {
        let server = try Server(password: "correct horse battery", ways: "publickey")
        let password = PasswordOnce.Password("correct horse battery")
        #expect(await PasswordOnce.run(Self.target, need: .ssh, password: password, keys: server.keys, ssh: server.ssh)
                == .refused("203.0.113.9 takes SSH keys only, so a password cannot open it. "
                            + "Give it this Mac's key at your provider."))
        #expect(password.isEmpty)
    }

    /// A user that the password lets in and whose `sudo` refuses it cannot become root.
    @Test func aUserWithNoSudoIsSaidSo() async throws {
        let server = try Server(password: "correct horse battery", sudo: "none")
        let deploy = InstallTarget(host: "203.0.113.9", user: "deploy", becomeRoot: true)
        #expect(await PasswordOnce.run(deploy, need: .ssh, password: PasswordOnce.Password("correct horse battery"),
                                       keys: server.keys, ssh: server.ssh) == .refused(ServerCheck.notRoot("deploy")))
        #expect(server.authorized.isEmpty, "a server that cannot take the install kept the app's key")
    }
}
