import Foundation
import Testing
@testable import FleetCore

/// **Each program that the app runs as root reaches `/bin/sh` unchanged through `sudo -n -i`**
/// (`InstallPlan.throughSudo`). The way to the server is played here with the shells of this Mac: the user's own shell
/// reads the remote command, a stand-in for `sudo` gives root's login shell the words with sudo's own backslashes
/// (`man sudo`, `-i`), and root's login shell, bash as on the systems that the installers take, starts `/bin/sh`: this
/// Mac's, and dash, which is `/bin/sh` on Debian and Ubuntu. Until 11 November 2026 two programs lost a "$" on this
/// way: the owner's access line went into no file, and the read of a Linux server's vault key printed no key.
struct RootThroughSudoTests {
    static let deploy = InstallTarget(host: "100.80.1.2", user: "deploy", becomeRoot: true)
    static let root = InstallTarget(host: "100.80.1.2")
    static let recipient = "age1aahjzcwvvmrhch43mhx4w5pld4uwqvcv5wsyrf6k493ggmm3wqus7rxumd"
    /// The shells that run a program as `/bin/sh`: this Mac's, and the one of Debian and Ubuntu.
    static let shells = ["/bin/sh", "/bin/dash"]

    private func plan(_ target: InstallTarget = deploy) -> InstallPlan {
        InstallPlan(job: .join, target: target, steps: [], redactions: [])
    }

    private func folder() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("root-sudo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false)
        return made
    }

    /// One shell text in a shell of this Mac, to its end, with `input` on its standard input and, where given, `bin`
    /// first in its PATH: its exit status and what it printed on both outputs.
    private func shell(_ shell: String, _ text: String, input: String = "", bin: URL? = nil) throws
        -> (status: Int32, output: String) {
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: shell)
        child.arguments = ["-c", text]
        child.standardOutput = output
        child.standardError = output
        child.standardInput = FileHandle.nullDevice
        if !input.isEmpty {
            // From a file and not a pipe, so that a program that ends before it reads it all stops nothing here.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("root-sudo-" + UUID().uuidString)
            try Data(input.utf8).write(to: file)
            child.standardInput = try FileHandle(forReadingFrom: file)
            try FileManager.default.removeItem(at: file)
        }
        if let bin {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = bin.path + ":/usr/bin:/bin"
            child.environment = environment
        }
        try child.run()
        let said = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return (child.terminationStatus, String(decoding: said, as: UTF8.self))
    }

    /// What `sudo -i` gives root's login shell: the words joined with spaces, with a backslash before each character
    /// that is not a letter, a digit, "_", "-" or "$" (as in `HubTCPTests`).
    private func sudoLogin(_ words: [String]) -> String {
        words.map { word in
            word.map { character in
                character.isASCII && (character.isLetter || character.isNumber) || "_-$".contains(character)
                    ? String(character) : "\\" + String(character)
            }.joined()
        }.joined(separator: " ")
    }

    /// The words that the user's own shell gives `sudo` after its options and "--", from the last argument of `ssh`.
    private func wordsForSudo(_ remote: String) throws -> [String] {
        let printed = try shell("/bin/sh", #"sudo() { while [ "$1" != -- ]; do shift; done; shift; printf '%s\0' "$@"; }; "#
                                + remote)
        return printed.output.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// The remote command through the user's shell, `sudo -i` and root's login shell, to its end in `sh`.
    private func throughSudo(_ remote: String, sh: String = "/bin/sh", input: String = "", bin: URL? = nil) throws
        -> (status: Int32, output: String) {
        var words = try wordsForSudo(remote)
        try #require(words.first == "/bin/sh", "\(words)")
        words[0] = sh
        return try shell("/bin/bash", sudoLogin(words), input: input, bin: bin)
    }

    /// The program that `/bin/sh` runs: the third word as root's login shell gives it, or, where that word is `eval` of
    /// a `printf`, what the `printf` prints in each shell.
    private func programThatShRuns(_ remote: String) throws -> String {
        let words = try wordsForSudo(remote)
        try #require(words.count == 3 && words[0] == "/bin/sh" && words[1] == "-c", "\(words)")
        let given = try shell("/bin/bash", sudoLogin(["printf", "%s", words[2]])).output
        guard given.hasPrefix("eval ") else { return given }
        let printed = try Self.shells.map { try shell($0, "printf %s " + given.dropFirst("eval ".count)).output }
        try #require(Set(printed).count == 1, "\(printed)")
        return printed[0]
    }

    /// Every program that the app runs as root on a server: the owner's access line, the read of a Linux server's vault
    /// key, the vault's install, the hub's TCP run, the door's programs and its parts on a business's servers, and each
    /// step of the two installs, of the checks, of a restart and of an update. The check of the server is not one: it
    /// runs as the user that this Mac logs in as, with its script on standard input.
    private func rootPrograms() throws -> [String] {
        let key = try #require(OwnerAccessKey(seed: Data((0..<32).map { UInt8($0 * 7 + 3) })))
        let owner = SoftwareOwnerKey().publicKey
        var programs = [OwnerAccess.install(key), CentralVaultRemote.readBrokerKey, HubTCP.program(),
                        try #require(CentralVaultRemote.install(ownerKey: owner, keepOwner: true)),
                        try #require(CentralVaultRemote.install(ownerKey: owner, keepOwner: false)),
                        DoorAccess.readProgram, DoorAccess.writeProgram, DoorAccess.hostProgram, DoorAccess.boxProgram,
                        try #require(DoorAccess.followProgram(hub: "100.80.1.2", port: 8765)), DoorAccess.recipientProgram,
                        try #require(DoorAccess.heldProgram(login: "bws://0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")),
                        DoorAccess.hubSecretsProgram, DoorAccess.tokensProbe, "cat -- '/home/fleet/github-app.pem'"]
        // The door's parts on a business's server (`DoorSync`). Through `sudo -n -i`, the bundle and the install lost
        // "$d" before 11 November 2026.
        let doorKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOfThisServerThatStaysAsItIs000000000 door@door"
        programs += [DoorHosts.releaseProgram, DoorHosts.revisionProgram, DoorHosts.bundleProgram,
                     try #require(DoorHosts.installProgram(mode: "fix", doorKey: doorKey)),
                     try #require(DoorHosts.probeProgram(host: "worker-4"))]
        // A join line as the hub writes it (`hub.join_line`).
        let line = "command -v tailscale >/dev/null || for try in 1 2 3; do DEBIAN_FRONTEND=noninteractive apt-get "
            + "-o DPkg::Lock::Timeout=1200 -q install </dev/null >/dev/null 2>&1; curl -fsSL "
            + "https://tailscale.com/install.sh | sh && command -v tailscale >/dev/null && break; sleep 20; done; "
            + "tailscale status "
            + ">/dev/null 2>&1 || tailscale up --advertise-tags=tag:founderizer --accept-dns=false; "
            + "curl -fsS http://100.80.1.2:8765/join | FLEET_JOIN=ABCD-EFGH-JKLM sh"
        let tailscale = "tskey-auth-k0000-secret", source = InstallPlan.defaultSource
        var plans: [InstallPlan] = [.hub(target: Self.deploy, source: source, authKey: nil),
                                    .hub(target: Self.deploy, source: source, authKey: tailscale)]
        plans += [.join(target: Self.deploy, line: line, code: "ABCD-EFGH-JKLM", authKey: nil),
                  .join(target: Self.deploy, line: line, code: "ABCD-EFGH-JKLM", authKey: tailscale)]
        plans += [.restart(target: Self.deploy, machine: .linuxWorker),
                  .update(target: Self.deploy, machine: .hub, agent: "manager")]
        plans += MachineCheckout.allCases.map { InstallPlan.check(target: Self.deploy, machine: $0) }
        for step in plans.flatMap(\.steps) {
            switch step.action {
            case .run(let program), .join(let program), .sendAuthKey(let program), .detach(let program),
                 .verify(let program), .waitFor(let program, _, _, _):
                programs.append(program)
            case .signIn(let start, let check, _, _): programs += [start, check]
            case .check, .claim: break
            }
        }
        return programs
    }

    // MARK: the stand-in

    /// The stand-in for `sudo` is true where it matters: a "$" reaches root's login shell, which expands it first, and
    /// a new line reaches it after a backslash, which joins the two lines.
    @Test func theStandInLosesWhatSudoLoses() throws {
        let dollar = "sudo -n -i -- /bin/sh -c " + InstallPlan.quote(#"said=kept; printf '%s' "$said""#)
        #expect(try throughSudo(dollar).output == "")
        let lines = "sudo -n -i -- /bin/sh -c " + InstallPlan.quote("echo one\necho two")
        #expect(try throughSudo(lines).output == "oneecho two\n")
    }

    // MARK: the programs of the app

    /// Every root program of the app reaches `/bin/sh` unchanged through `sudo -n -i`, and through `sudo -S` in the
    /// same words.
    @Test func everyRootProgramOfTheAppReachesShUnchanged() throws {
        let programs = try rootPrograms()
        #expect(programs.count > 50)
        for program in programs {
            let remote = try #require(plan().arguments(for: program).last)
            #expect(try programThatShRuns(remote) == program, "\(remote)")
            #expect(plan().arguments(for: program, runs: .rootWithPassword).last
                    == "sudo -S -k -p '' -i -- /bin/sh -c " + InstallPlan.quote(InstallPlan.throughSudo(program)))
        }
    }

    /// The owner's access line goes into root's file once, through `sudo -n -i`, as it does for root itself. As it was
    /// sent before, "$f" arrived as "": the line went into no file, and the program did not say that it was in place.
    @Test func theOwnersAccessLineGoesIntoRootsFileThroughSudo() throws {
        let key = try #require(OwnerAccessKey(seed: Data((0..<32).map { UInt8($0 * 7 + 3) })))
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for sh in Self.shells {
            let file = folder.appendingPathComponent(URL(fileURLWithPath: sh).lastPathComponent + "/.ssh/authorized_keys")
            let program = OwnerAccess.install(key, file: file.path)
            let before = try throughSudo("sudo -n -i -- /bin/sh -c " + InstallPlan.quote(program), sh: sh)
            #expect(!OwnerAccess.isInPlace(before.output) && !FileManager.default.fileExists(atPath: file.path))
            let remote = try #require(CentralVaultRemote.arguments(target: Self.deploy, program: program).last)
            for _ in 0..<2 {
                let ran = try throughSudo(remote, sh: sh)
                #expect(ran.status == 0 && OwnerAccess.isInPlace(ran.output), "\(sh) said: \(ran.output)")
                #expect(try String(contentsOf: file, encoding: .utf8) == key.publicLine + "\n")
            }
        }
        let program = OwnerAccess.install(key)
        #expect(CentralVaultRemote.arguments(target: Self.root, program: program).last == program)
    }

    /// A Linux server's vault key is read through `sudo -n -i`, and only its public line leaves. As it was sent before,
    /// "$k" arrived as "", and the read printed no key. Here `python3` names the key file, as the configuration does.
    @Test func aServersVaultKeyIsReadThroughSudo() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bin = folder.appendingPathComponent("bin"), keyFile = folder.appendingPathComponent("vault.key")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        try "# created: 2026-11-11T08:00:00Z\n# public key: \(Self.recipient)\nAGE-SECRET-KEY-1QQQ\n"
            .write(to: keyFile, atomically: true, encoding: .utf8)
        let python = bin.appendingPathComponent("python3")
        try "#!/bin/sh\nprintf '%s\\n' '\(keyFile.path)'\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let program = CentralVaultRemote.readBrokerKey
        for sh in Self.shells {
            let before = try throughSudo("sudo -n -i -- /bin/sh -c " + InstallPlan.quote(program), sh: sh, bin: bin)
            #expect(CentralVaultRemote.brokerKey(in: before.output) == nil)
            let remote = try #require(CentralVaultRemote.arguments(target: Self.deploy, program: program).last)
            let ran = try throughSudo(remote, sh: sh, bin: bin)
            #expect(CentralVaultRemote.brokerKey(in: ran.output) == Self.recipient, "\(sh) said: \(ran.output)")
            #expect(!ran.output.contains("SECRET"))
        }
    }

    // MARK: the words

    /// A program that a shell would read in other words after `sudo -i` runs there as it runs here: with "$" before a
    /// name, a digit and "$", new lines, quotes, backslashes, "%", back quotes and characters that are not ASCII, and
    /// with its standard input and its exit status. So does a program that arrives whole in its own words.
    @Test func aProgramRunsThroughSudoAsItRunsHere() throws {
        let input = "one\ntwo\nthree\n"
        let programs = [
            #"x=kept; printf '[%s]' "$x" "${x}" '$x' "\$x" "$(echo sub)" `echo tick` "$1" "$#" 100% 'a\b' "a\\b"; "#
                + #"echo "é ’""#,
            "f() { echo \"in f: $1\"; }\nf one\ntwo=2; echo \"$two\"; exit 3",
            #"IFS= read -r first; rest=$(cat); printf '[%s][%s]' "$first" "$rest"; exit 4"#,
            #"printf '[%s]' "$(echo whole)" "${HOME:+home}" "$?" '%d'; echo $"#,
        ]
        #expect(programs.map(InstallPlan.arrivesThroughSudo) == [false, false, false, true])
        // A "-" at the start goes as an escape too: as the first character of the format, `printf` would read it as an
        // option and print nothing, and the step would end with 0 although nothing ran.
        let option = #"-n x; echo "$HOME""#
        #expect(try programThatShRuns(try #require(plan().arguments(for: option).last)) == option)
        for program in programs {
            let remote = try #require(plan().arguments(for: program).last)
            for sh in Self.shells {
                let here = try shell(sh, program, input: input)
                let there = try throughSudo(remote, sh: sh, input: input)
                #expect(there.status == here.status && there.output == here.output,
                        "\(sh): \(there.status) \(there.output) for \(here.status) \(here.output)")
            }
        }
    }

    /// A program that arrives whole goes in its own words, as before, and so does every program for root itself. Each
    /// other program goes in words with no "$", no new line and nothing but printable ASCII.
    @Test func onlyAProgramThatWouldChangeGoesInOtherWords() {
        for whole in ["tailscale ip -4", "echo 'hi'", InstallPlan.verifyCommand(.linuxWorker), "echo $?", "echo ${x}",
                      #"echo "$(id -u)""#, "echo $"] {
            #expect(InstallPlan.throughSudo(whole) == whole)
            #expect(plan().arguments(for: whole).last == "sudo -n -i -- /bin/sh -c " + InstallPlan.quote(whole))
        }
        for other in [#"echo "$f""#, "echo $1", "echo $$", "echo $-", "echo $_x", "echo $HOME", "echo one\necho two",
                      "echo é", "echo\tx"] {
            let words = InstallPlan.throughSudo(other)
            #expect(words.hasPrefix("eval \"`printf '") && words.hasSuffix("'`\""), "\(words)")
            #expect(words.utf8.allSatisfy { (0x20...0x7e).contains($0) } && !words.contains("$"), "\(words)")
            #expect(InstallPlan.arrivesThroughSudo(words))
            #expect(plan(Self.root).arguments(for: other).last == other)
        }
    }
}
