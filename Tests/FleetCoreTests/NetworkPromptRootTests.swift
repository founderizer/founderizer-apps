import Foundation
import Testing
@testable import FleetCore

/// **Each later step of the prompt for the owner's own agent runs whole as root, also on a server that the agent
/// reaches as a user who is not root** (`NetworkPrompt.text`). Step 1 of the prompt says what the agent puts in front
/// of the remote command of each later step for such a user; this test reads it there and does what it says. Until
/// 11 November 2026 that was `sudo -i -- ` in front of commands of more than one part: the user's own shell split them
/// at ";", "&&", "||" and "|" before `sudo` ran, so only the first part ran as root. Step 3 ran Tailscale's install
/// as the user, step 4 could not write the key file, and step 5 could not remove it.
///
/// The way to the server is played with the shells of this Mac, as in `RootThroughSudoTests`: the agent's shell runs
/// the line of the prompt with a stand-in for `ssh`, which gives the user's login shell (bash) the remote command as
/// `ssh` joins it; a stand-in for `sudo` gives root's login shell (bash) the words with sudo's own backslashes
/// (`man sudo`, `-i`); and `/bin/sh` runs the program: this Mac's, and dash, which is `/bin/sh` on Debian and Ubuntu.
/// The server is a folder. Its `/root` is a folder that only the stand-in for `sudo` opens, Tailscale's install puts
/// `tailscale` in a folder that only that stand-in lets a program change, and the user has nothing on its PATH but
/// `sudo`. So a part of a step that runs outside `sudo` cannot reach the key file, cannot install and finds no program.
/// A part that the user's shell runs by itself, such as `echo`, needs no program, so `faults(in:)` also checks the
/// shape of the words.
struct NetworkPromptRootTests {
    /// The shells that run a program as `/bin/sh`: this Mac's, and the one of Debian and Ubuntu.
    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    /// The command lines of each step of a prompt: the lines of its code blocks that call `ssh`.
    static func steps(in text: String = NetworkPrompt.text) -> [Int: [String]] {
        var step = 0, lines: [Int: [String]] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## Step "), let number = Int(line.dropFirst("## Step ".count).prefix(while: \.isNumber)) {
                step = number
            } else if step > 0, line.hasPrefix("    ssh ") {
                lines[step, default: []].append(String(line.dropFirst(4)))
            }
        }
        return lines
    }

    /// What step 1 of a prompt tells the agent to put in front of the remote command of each later step, for a user
    /// who is not root.
    static func prefix(in text: String = NetworkPrompt.text) -> String? {
        let words = text.replacingOccurrences(of: "\n", with: " ")
        guard let end = words.range(of: "` in front of the remote command"),
              let start = words.range(of: "put `", options: .backwards, range: words.startIndex..<end.lowerBound)
        else { return nil }
        return String(words[start.upperBound..<end.lowerBound])
    }

    /// The remote command of an `ssh` line: the text between its first and its last single quote.
    static func remoteCommand(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "'"), let close = line.lastIndex(of: "'"), open < close else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    /// What, in the words of a prompt, keeps a later step from running whole as root for a user who is not root, and
    /// what the walk through the steps cannot see. Empty when there is nothing.
    /// - Step 1 says to put exactly `sudo -n -i -- ` in front, and shows it inside the single quotes of a remote
    ///   command. The walk puts the prefix there by itself, and its stand-in for `sudo` takes any options.
    /// - Each later remote command is one command: one `/bin/sh -c "…"` with no `"`, `$`, `` ` ``, `\` or new line in
    ///   it, or a command with no character that a shell reads. The walk does not see a part outside `sudo` that the
    ///   user's shell runs by itself, such as `echo`.
    /// - Only steps 1 to 5 run a command. The walk runs steps 2 to 5, and step 1 runs as the user that it reads.
    static func faults(in text: String) -> [String] {
        var faults: [String] = []
        let prefix = Self.prefix(in: text)
        if prefix != "sudo -n -i -- " {
            faults.append("step 1 puts \(prefix.map { "`\($0)`" } ?? "nothing") in front of the later remote commands")
        }
        if !text.replacingOccurrences(of: "\n", with: " ").contains(#"'sudo -n -i -- /bin/sh -c ""#) {
            faults.append("step 1 does not show `sudo -n -i -- ` inside the single quotes of a remote command")
        }
        let steps = Self.steps(in: text)
        if Set(steps.keys) != [1, 2, 3, 4, 5] {
            faults.append("the steps that run a command are \(steps.keys.sorted()), not 1 to 5")
        }
        for (step, lines) in steps.sorted(by: { $0.key < $1.key }) where step > 1 {
            for line in lines {
                guard let command = remoteCommand(line) else {
                    faults.append("step \(step): `\(line)` has no remote command in single quotes")
                    continue
                }
                let whole = command.range(of: #"^/bin/sh -c "[^"$`\\\n]*"$"#, options: .regularExpression) != nil
                let plain = command.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>()$`\\\"'*?[]{}~#!\n")) == nil
                if !whole && !plain { faults.append("step \(step): `\(command)` is more than one command") }
            }
        }
        return faults
    }

    /// Steps 2 to 5 on a new server with no Tailscale, as the agent runs them, with `prefix` in front of each remote
    /// command (none for root). The first updates of the server hold apt's lock, which Tailscale's installer does not
    /// wait for, so step 3 must wait for it. Each step starts where the step before it should have left the server, so
    /// that each one is judged on its own.
    private func walk(_ server: StandInServer, prefix: String?, sh: String = "/bin/sh") throws {
        let steps = Self.steps()
        let two = try #require(steps[2]), three = try #require(steps[3]), four = try #require(steps[4])
        let five = try #require(steps[5])
        try #require(two.count == 1 && three.count == 2 && four.count == 2 && five.count == 2, "\(steps)")
        try server.holdAptLock(540)
        let who = prefix == nil ? "root" : "a user who is not root, with \(sh)"
        func run(_ line: String) throws -> StandInServer.Ran {
            let ran = try server.run(line, prefix: prefix, sh: sh)
            #expect(ran.status == 0 && ran.err.isEmpty, "\(who): `\(line)` ended with \(ran.status): \(ran.err)")
            if prefix != nil {
                // The user's shell gives the whole remote command to `sudo` once, and root's login shell runs the
                // words that `sudo` got, unchanged: the remote command has no "$" that it would expand.
                let gets = ran.logged("sudo gets"), runs = ran.logged("root runs"), sent = ran.logged("ssh sends")
                #expect(gets.count == 1 && runs == gets, "\(who): `\(line)`\n\(ran.log)")
                #expect(sent.count == 1 && !sent.joined().contains("$"), "\(who): `\(line)`\n\(ran.log)")
            }
            return ran
        }
        // Step 2: a server with no Tailscale says so.
        #expect(try run(two[0]).out == "none\n", "\(who)")
        // Step 3: Tailscale's install puts `tailscale` among the system's programs, which only root may change, after a
        // wait for apt's lock.
        _ = try run(three[0])
        #expect(server.installed, "\(who): step 3 did not install Tailscale")
        #expect(server.aptWaits == [540], "\(who): step 3 waited \(server.aptWaits) seconds for apt's lock, not 540")
        try server.install()
        #expect(try run(three[1]).out == "1.90.6\n", "\(who)")
        // Step 4: the key goes into root's file, which only root can read, and its check says so.
        _ = try run(four[0])
        let written = try server.authKeyFile()
        #expect(written?.text == server.key && written?.mode == 0o600, "\(who): step 4 wrote \(String(describing: written))")
        try server.putAuthKey()
        #expect(try run(four[1]).out == "600\n", "\(who)")
        // Step 5: `tailscale up` reads the key, and the line removes the key file whether or not that worked.
        _ = try run(five[0])
        #expect(server.keyGivenToTailscale() == server.key, "\(who): step 5 gave Tailscale no key")
        #expect(try server.authKeyFile() == nil, "\(who): step 5 left the key file on the server")
        let up = try run(five[1]).out
        #expect(up.hasPrefix("100.64.2.1\n") && up.contains(#""BackendState": "Running""#), "\(who): \(up)")
        // Step 2 again, on the server that is now on the network: its address.
        #expect(try run(two[0]).out == "100.64.2.1\n", "\(who)")
    }

    // MARK: the stand-in

    /// The stand-in for `sudo` is true where it matters: a "$" reaches root's login shell, which expands it first; a
    /// new line reaches it after a backslash, which joins the two lines; and a part after ";" runs as the user, who
    /// cannot write in root's folder.
    @Test func theStandInLosesWhatSudoLoses() throws {
        let server = try StandInServer()
        defer { server.remove() }
        #expect(try server.remote(#"sudo -n -i -- /bin/sh -c 'x=kept; echo "[$x]"'"#).out == "[]\n")
        #expect(try server.remote("sudo -n -i -- /bin/sh -c 'echo one\necho two'").out == "oneecho two\n")
        let file = server.authKey.path
        let split = try server.remote("sudo -n -i -- umask 077; cat > \(file)", input: server.key)
        let notWritten = try server.authKeyFile()
        #expect(split.status != 0 && split.err.contains("Permission denied") && notWritten == nil, "\(split.err)")
        let whole = try server.remote("sudo -n -i -- /bin/sh -c 'umask 077; cat > \(file)'", input: server.key)
        let written = try server.authKeyFile()
        #expect(whole.status == 0 && written?.text == server.key && written?.mode == 0o600, "\(whole.err)")
    }

    /// `faults(in:)` finds each wrong shape of the words that the walk through the steps lets pass.
    @Test func theShapeCheckFindsAWrongPrompt() throws {
        let wrong = [
            // With no -n, `sudo` can ask for a password, which the agent does not have.
            ("put `sudo -n -i -- ` in front", "put `sudo -i -- ` in front"),
            // With no -i, what step 1 says about root's login shell is not true.
            ("put `sudo -n -i -- ` in front", "put `sudo -n -- ` in front"),
            // In front of `ssh`, `sudo` runs on the agent's own machine.
            (#"`ssh "$SSHUSER@$HOST" 'sudo -n -i -- /bin/sh -c "…"'`"#,
             #"`sudo -n -i -- ssh "$SSHUSER@$HOST" '/bin/sh -c "…"'`"#),
            // The user's shell runs `echo` outside `sudo`, and it prints the same.
            (#"&& tailscale ip -4 || echo none"'"#, #"&& tailscale ip -4" || echo none'"#),
            // Root's login shell expands a "$" after `sudo -i`.
            (#"stat -c %a /root/fleet-authkey"'"#, #"stat -c %a $HOME/fleet-authkey"'"#),
            // The walk does not run a command of a step after step 5.
            ("## Step 6. Report\n", "## Step 6. Report\n\n    ssh \"$SSHUSER@$HOST\" 'tailscale version'\n"),
        ]
        for (old, new) in wrong {
            let text = NetworkPrompt.text.replacingOccurrences(of: old, with: new)
            try #require(text != NetworkPrompt.text, "`\(old)` is not in the prompt")
            #expect(!Self.faults(in: text).isEmpty, "the check finds nothing wrong with `\(new)`")
        }
    }

    // MARK: the prompt

    /// The words have the shape that runs each later step whole as root (`faults(in:)`).
    @Test func theWordsHaveTheShapeThatRunsEachLaterStepWhole() {
        #expect(Self.faults(in: NetworkPrompt.text) == [])
    }

    /// For a user who is not root, every later step runs whole as root through what step 1 puts in front of it, and
    /// the key file of steps 4 and 5 is written and then removed.
    @Test func everyLaterStepRunsWholeAsRootForAUserWhoIsNotRoot() throws {
        let prefix = try #require(Self.prefix())
        for sh in Self.shells {
            let server = try StandInServer()
            defer { server.remove() }
            try walk(server, prefix: prefix, sh: sh)
        }
    }

    /// For root, the same commands run as they stand.
    @Test func theSameStepsRunAsTheyStandForRoot() throws {
        let server = try StandInServer()
        defer { server.remove() }
        try walk(server, prefix: nil)
    }

    /// **Step 5's `tailscale up` has `--reset`, and waits 300 seconds at most.** The hub's join line, and this app's
    /// own sign-in, run `tailscale up` with their tags and no key, and that `tailscale up` waits for a sign-in.
    /// Tailscale keeps its settings, its tags too, also after it ended. Then it refuses a `tailscale up` that does not
    /// name each of them again, unless it has `--reset` (Tailscale 1.104.6 in a Debian 12 container, 11 November
    /// 2026): until then step 5 failed on such a machine, with each new key. With no `--timeout`, `tailscale up` waits
    /// for ever on a tailnet that holds each new machine until an admin approves it: now it ends after 5 minutes with
    /// Tailscale's words, and the line removes the key file. The words of step 5 say what the agent does then. On a
    /// machine where Tailscale runs, step 5 runs no `tailscale up`, so `--reset` does not change its settings: step 2
    /// asks the owner about such a machine, and step 5 had no `tailscale status` before it.
    @Test func stepFiveBringsUpAMachineThatAnEarlierTailscaleUpLeftAndWaitsFiveMinutesAtMost() throws {
        let line = try #require(Self.steps()[5]?.first), given = try #require(Self.prefix())
        let words = NetworkPrompt.text.replacingOccurrences(of: "\n", with: " ")
        for wanted in ["can wait up to 5 minutes", "`--reset` removes the settings",
                       "ends with `timeout waiting for Tailscale service to enter a Running state`",
                       "approve this machine in their Tailscale admin console", "run the second line of step 5"] {
            #expect(words.contains(wanted), "the words of step 5 do not say: \(wanted)")
        }
        for prefix in [nil, given] as [String?] {
            // A machine where Tailscale runs, with a name of its own: no `tailscale up`, and its settings stay.
            let running = try StandInServer()
            defer { running.remove() }
            try running.install()
            try running.onNetwork(with: ["--hostname=box", "--accept-dns=false"])
            try running.putAuthKey()
            let quiet = try running.run(line, prefix: prefix, sh: "/bin/sh")
            let keyLeft = try running.authKeyFile()
            #expect(running.upWaits.isEmpty && running.settings == "--hostname=box\n--accept-dns=false\n"
                    && running.keyGivenToTailscale() == nil && keyLeft == nil,
                    "step 5 changed a machine where Tailscale runs: \(running.settings) \(quiet.err)")
            for approval in [false, true] {
                let server = try StandInServer()
                defer { server.remove() }
                try server.install()
                let kept = try server.earlierUp(["--advertise-tags=tag:founderizer", "--accept-dns=false"])
                #expect(kept.contains("--advertise-tags=tag:founderizer"), "the earlier tailscale up kept \(kept)")
                if approval { try server.approveByHand() }
                try server.putAuthKey()
                let ran = try server.run(line, prefix: prefix, sh: "/bin/sh")
                let who = (prefix == nil ? "root" : "a user who is not root")
                    + (approval ? ", on a tailnet that approves each machine by hand" : "")
                #expect(server.keyGivenToTailscale() == server.key, "\(who): step 5 gave Tailscale no key: \(ran.err)")
                #expect(try server.authKeyFile() == nil, "\(who): step 5 left the key file on the server")
                #expect(server.upWaits == ["300s"], "\(who): tailscale up waited \(server.upWaits), not 300s at most")
                if approval {
                    #expect(ran.err.contains("timeout waiting for Tailscale service to enter a Running state")
                            && !ran.err.contains("waits here for ever"), "\(who): \(ran.err)")
                } else {
                    #expect(ran.status == 0 && ran.err.isEmpty, "\(who): step 5 ended with \(ran.status): \(ran.err)")
                }
            }
        }
    }

    /// **Step 3 tries Tailscale's installer again**: a try that fails is made again after 20 seconds, three times at
    /// most, and a try counts only when `tailscale` is there after it. Here the first updates of the server hold apt's
    /// lock, and curl gets no script on the first try, or on all three, as when the network of a new server is not
    /// ready yet: `sh` then ends with 0 and installs nothing. After three tries the line ends with 0 and no Tailscale,
    /// and the second line of step 3 is the check that stops the agent.
    @Test func stepThreeTriesTailscalesInstallerAgain() throws {
        let line = try #require(Self.steps()[3]?.first), given = try #require(Self.prefix())
        for prefix in [nil, given] as [String?] {
            for misses in [1, 3] {
                let server = try StandInServer()
                defer { server.remove() }
                try server.holdAptLock(540)
                try server.failCurl(misses)
                let ran = try server.run(line, prefix: prefix, sh: "/bin/sh")
                let who = (prefix == nil ? "root" : "a user who is not root") + ", \(misses) tries of curl with nothing"
                #expect(ran.status == 0 && server.installed == (misses < 3),
                        "\(who): step 3 ended with \(ran.status), Tailscale there: \(server.installed): \(ran.err)")
                #expect(server.aptWaits == [540] && server.slept == Array(repeating: 20, count: misses),
                        "\(who): step 3 waited \(server.aptWaits) seconds for apt's lock and slept \(server.slept)")
            }
        }
    }

    /// **Step 1 reads a new machine, whose key SSH on the agent's machine has never seen, and a key that changed
    /// still stops it.** SSH in BatchMode, and SSH that cannot ask on a terminal, refuses a key that it does not know:
    /// "Host key verification failed.", with status 255 (OpenSSH 10.3p1 on this Mac). Until 12 November 2026 step 1
    /// gave SSH no value of StrictHostKeyChecking, so it stopped on each new machine. `hostKeySSH` plays SSH's check
    /// of the key as `test_hub_install.StandInServer` plays it, from OpenSSH's own: a key that SSH keeps for the
    /// address goes on, another key stops it, and an unknown key goes on only with "accept-new", "no" or "off", which
    /// keep it. The words of step 1 say what the owner does when the key changed.
    @Test func stepOneKeepsTheKeyOfANewMachineAndAKeyThatChangedStopsIt() throws {
        let line = try #require(Self.steps()[1]?.first)
        let words = (NetworkPrompt.text.components(separatedBy: "## Step 1.").dropFirst().first ?? "")
            .components(separatedBy: "## Step 2.")[0].replacingOccurrences(of: "\n", with: " ")
        for wanted in ["REMOTE HOST IDENTIFICATION HAS CHANGED", "`ssh-keygen -R <the address>`",
                       "Do not remove it yourself"] {
            #expect(words.contains(wanted), "the words of step 1 do not say: \(wanted)")
        }
        for option in ["StrictHostKeyChecking=no", "StrictHostKeyChecking=off", "UserKnownHostsFile=/dev/null"] {
            #expect(!NetworkPrompt.text.contains(option), "a line of the prompt stops SSH's key check: \(option)")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-step-one-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let known = folder.appendingPathComponent("known_hosts"), log = folder.appendingPathComponent("log")
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEZvdW5kZXJpemVyU3RhbmRJbkhvc3RLZXkwMTIzNDU2Nzg5"
        let earlier = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEFuRWFybGllck1hY2hpbmVBdFRoaXNBZGRyZXNzMDE"
        for (kept, goes) in [("", true), ("203.0.113.9 \(key)\n", true), ("203.0.113.9 \(earlier)\n", false)] {
            try Data(kept.utf8).write(to: known)
            try Data().write(to: log)
            let ran = try Self.shell(Self.hostKeySSH + line, in: folder,
                                     environment: ["HOST": "203.0.113.9", "SSHUSER": "root", "KNOWN": known.path,
                                                   "HOSTKEY": key, "LOG": log.path])
            let sent = try String(contentsOf: log, encoding: .utf8)
            let now = try String(contentsOf: known, encoding: .utf8)
            let who = kept.isEmpty ? "no key" : kept.contains(key) ? "its key" : "the key of an earlier machine"
            if goes {
                #expect(ran.status == 0 && sent.components(separatedBy: "ssh sends [").count == 2
                            && now == "203.0.113.9 \(key)\n",
                        "where SSH keeps \(who): step 1 ended with \(ran.status) (\(ran.err)), SSH keeps \(now)")
            } else {
                #expect(ran.status == 255 && ran.err.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") && sent.isEmpty
                            && now == kept,
                        "where SSH keeps \(who): step 1 ended with \(ran.status) (\(ran.err)), SSH keeps \(now)")
            }
        }
    }

    /// The agent's `ssh` for the test of step 1, as far as it checks the key of the machine: it takes the first value
    /// of StrictHostKeyChecking that it gets, and checks the key that the machine gives
    /// (HOSTKEY) against the agent's known_hosts (KNOWN, one "<host> <type> <key>" a line). With "ask", the value when
    /// nothing gives one, SSH asks on a terminal, and it stops in BatchMode and with no terminal. When it goes on, it
    /// writes the remote command to LOG.
    static let hostKeySSH = #"""
        ssh() {
            _strict=
            while [ "$#" -gt 0 ]; do
                case $1 in
                -o) _option=$2; shift 2 ;;
                -o?*) _option=${1#-o}; shift ;;
                -*) shift; continue ;;
                *) break ;;
                esac
                _word=$(printf '%s' "${_option%%[= ]*}" | /usr/bin/tr '[:upper:]' '[:lower:]')
                _value=$(printf '%s' "${_option#*[= ]}" | /usr/bin/tr '[:upper:]' '[:lower:]')
                case $_word in stricthostkeychecking) [ -n "$_strict" ] || _strict=$_value ;; esac
            done
            _host=${1#*@}
            shift
            _known=new
            while read -r _name _kind _key _rest; do
                [ "$_name" = "$_host" ] || continue
                if [ "$_kind $_key" = "$HOSTKEY" ]; then _known=yes; break; fi
                _known=changed
            done < "$KNOWN"
            case $_known/${_strict:-ask} in
            yes/* | changed/no | changed/off) ;;
            changed/*)
                printf '%s\n' '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @' \
                    'Host key verification failed.' >&2
                return 255 ;;
            new/accept-new | new/no | new/off)
                printf '%s %s\n' "$_host" "$HOSTKEY" >> "$KNOWN"
                printf "Warning: Permanently added '%s' (ED25519) to the list of known hosts.\n" "$_host" >&2 ;;
            *) echo 'Host key verification failed.' >&2; return 255 ;;
            esac
            printf 'ssh sends [%s]\n' "$*" >> "$LOG"
        }

        """#

    /// `text` in `/bin/sh -c`, in `folder`, with `environment` and nothing else but PATH: its status and its output.
    static func shell(_ text: String, in folder: URL,
                      environment: [String: String]) throws -> (status: Int32, out: String, err: String) {
        let out = folder.appendingPathComponent("out"), err = folder.appendingPathComponent("err")
        for file in [out, err] { try Data().write(to: file) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", text]
        child.environment = environment.merging(["PATH": "/usr/bin:/bin", "LC_ALL": "C"]) { kept, _ in kept }
        child.currentDirectoryURL = folder
        let outHandle = try FileHandle(forWritingTo: out), errHandle = try FileHandle(forWritingTo: err)
        defer { try? outHandle.close(); try? errHandle.close() }
        child.standardOutput = outHandle
        child.standardError = errHandle
        child.standardInput = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        return (child.terminationStatus, try String(contentsOf: out, encoding: .utf8),
                try String(contentsOf: err, encoding: .utf8))
    }
}

extension NetworkPromptRootTests {
    /// The server of these tests, in a folder of this Mac.
    struct StandInServer {
        /// One line, to its end: its exit status, what it printed on each output, and what the stand-ins logged.
        struct Ran {
            let status: Int32, out: String, err: String, log: String

            /// What the log says after `label`, one entry for each line of it that starts with it.
            func logged(_ label: String) -> [Substring] {
                log.split(separator: "\n").filter { $0.hasPrefix(label) }.map { $0.dropFirst(label.count) }
            }
        }

        let folder: URL
        /// What the owner's key file on the agent's machine holds. It is not a key.
        let key = "tskey-auth-kStandIn0000-0123456789abcdef\n"

        /// The server's `/root`: only the stand-in for `sudo` opens it.
        var root: URL { folder.appendingPathComponent("root") }
        /// Where Tailscale's install puts `tailscale`: only the stand-in for `sudo` lets a program change it.
        var system: URL { folder.appendingPathComponent("system") }
        /// The PATH of the user who is not root: `sudo` alone.
        var user: URL { folder.appendingPathComponent("user") }
        /// The rest of root's PATH: the tools that the steps call, and stand-ins for `curl` and GNU `stat`.
        var tools: URL { folder.appendingPathComponent("tools") }
        /// What Tailscale's daemon keeps.
        var state: URL { folder.appendingPathComponent("state") }
        var log: URL { folder.appendingPathComponent("log") }
        var record: URL { folder.appendingPathComponent("record") }
        var template: URL { folder.appendingPathComponent("tailscale") }
        /// The owner's key file on the agent's machine (`KEYFILE`).
        var keyFile: URL { folder.appendingPathComponent("owner-authkey") }
        /// The key file of steps 4 and 5: `/root/fleet-authkey` on the server.
        var authKey: URL { root.appendingPathComponent("fleet-authkey") }

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("network-prompt-" + UUID().uuidString)
            let files = FileManager.default
            for part in [folder, root, system, user, tools, state] {
                try files.createDirectory(at: part, withIntermediateDirectories: false)
            }
            try program(Self.sudo, at: user.appendingPathComponent("sudo"))
            try program(Self.record, at: record)
            try program(Self.tailscale, at: template)
            try program(Self.curl, at: tools.appendingPathComponent("curl"))
            try program(Self.aptGet, at: tools.appendingPathComponent("apt-get"))
            try program(Self.sleep, at: tools.appendingPathComponent("sleep"))
            try program(Self.stat, at: tools.appendingPathComponent("stat"))
            for tool in ["cat", "rm", "head", "chmod", "cp", "sh"] {
                let found = try #require(["/bin/", "/usr/bin/"].map { $0 + tool }.first { files.isExecutableFile(atPath: $0) })
                try files.createSymbolicLink(atPath: tools.appendingPathComponent(tool).path, withDestinationPath: found)
            }
            try Data(key.utf8).write(to: keyFile)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            try open(false)
        }

        private func program(_ text: String, at file: URL) throws {
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        func remove() {
            try? open(true)
            try? FileManager.default.removeItem(at: folder)
        }

        /// Opens root's two folders, as `sudo` does for the program that it runs, or closes them again.
        func open(_ open: Bool) throws {
            try FileManager.default.setAttributes([.posixPermissions: open ? 0o700 : 0], ofItemAtPath: root.path)
            try FileManager.default.setAttributes([.posixPermissions: open ? 0o755 : 0o555], ofItemAtPath: system.path)
        }

        var installed: Bool { FileManager.default.isExecutableFile(atPath: system.appendingPathComponent("tailscale").path) }

        /// Tailscale as step 3 should have installed it.
        func install() throws {
            guard !installed else { return }
            try open(true)
            defer { try? open(false) }
            let file = system.appendingPathComponent("tailscale")
            try FileManager.default.copyItem(at: template, to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        /// The key file as step 4 should have written it.
        func putAuthKey() throws {
            try open(true)
            defer { try? open(false) }
            try? FileManager.default.removeItem(at: authKey)
            try Data(key.utf8).write(to: authKey)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authKey.path)
        }

        /// The key file on the server, with its mode, if it is there.
        func authKeyFile() throws -> (text: String, mode: Int)? {
            try open(true)
            defer { try? open(false) }
            guard FileManager.default.fileExists(atPath: authKey.path) else { return nil }
            let mode = try FileManager.default.attributesOfItem(atPath: authKey.path)[.posixPermissions] as? Int
            return (try String(contentsOf: authKey, encoding: .utf8), mode ?? -1)
        }

        func keyGivenToTailscale() -> String? {
            try? String(contentsOf: state.appendingPathComponent("key"), encoding: .utf8)
        }

        /// A `tailscale up` with `words` and no key ran on this machine before, and it waited for a sign-in that nobody
        /// gave: Tailscale keeps its settings, and it does not run (`tailscale`). The settings, one flag a line.
        func earlierUp(_ words: [String]) throws -> String {
            try Self.earlierUp(words, tailscale: template, state: state)
        }

        /// `earlierUp` with the stand-in `tailscale` and the state folder of another test.
        static func earlierUp(_ words: [String], tailscale: URL, state: URL) throws -> String {
            let child = Process()
            child.executableURL = tailscale
            child.arguments = ["up"] + words
            child.environment = ["PATH": "/usr/bin:/bin", "STATE": state.path]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            try? FileManager.default.removeItem(at: state.appendingPathComponent("up-waits"))   // that one's own wait
            return (try? String(contentsOf: state.appendingPathComponent("settings"), encoding: .utf8)) ?? ""
        }

        /// Tailscale runs on this machine, with `settings` that a `tailscale up` before gave it (`tailscale`).
        func onNetwork(with settings: [String]) throws {
            try Data("Running\n".utf8).write(to: state.appendingPathComponent("backend"))
            try Data(settings.map { $0 + "\n" }.joined().utf8).write(to: state.appendingPathComponent("settings"))
        }

        /// The settings that Tailscale keeps on this machine, one flag a line.
        var settings: String {
            (try? String(contentsOf: state.appendingPathComponent("settings"), encoding: .utf8)) ?? ""
        }

        /// The owner's tailnet holds each new machine until an admin approves it (`tailscale`).
        func approveByHand() throws {
            try Data("yes\n".utf8).write(to: state.appendingPathComponent("approval"))
        }

        /// The `--timeout` of each `tailscale up`, in order; a `tailscale up` with none has no entry.
        var upWaits: [String] {
            ((try? String(contentsOf: state.appendingPathComponent("up-waits"), encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init)
        }

        /// The first updates of a new server, which hold the lock of dpkg for `seconds` more (`aptGet`).
        func holdAptLock(_ seconds: Int) throws {
            try Data("\(seconds)\n".utf8).write(to: state.appendingPathComponent("apt-lock"))
        }

        /// The seconds that each apt-get waited for the lock of dpkg, in order.
        var aptWaits: [Int] {
            ((try? String(contentsOf: state.appendingPathComponent("apt-waited"), encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        }

        /// curl gets no script from Tailscale's host the next `times` times (`curl`).
        func failCurl(_ times: Int) throws {
            try Data("\(times)\n".utf8).write(to: state.appendingPathComponent("curl-fails"))
        }

        /// The seconds of each `sleep`, in order.
        var slept: [Int] {
            ((try? String(contentsOf: state.appendingPathComponent("slept"), encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        }

        /// One line of the prompt, as the agent runs it in its own shell, with `HOST`, `SSHUSER` and `KEYFILE` set.
        /// The stand-in for `ssh` gives the login shell of the user the remote command, with `prefix` in front of it:
        /// for root (`prefix` nil), with the system's programs and the tools on its PATH and root's folders open;
        /// for the other user, with `sudo` alone on its PATH. `/root/` stands for the folder of this server.
        func run(_ line: String, prefix: String?, sh: String) throws -> Ran {
            let text = Self.ssh + line.replacingOccurrences(of: "/root/", with: root.path + "/")
            if prefix == nil { try open(true) }
            defer { if prefix == nil { try? open(false) } }
            let path = prefix == nil ? system.path + ":" + tools.path : user.path
            return try execute("/bin/sh", text, sh: sh, extra: ["HOST": "203.0.113.9", "KEYFILE": keyFile.path,
                                                               "SSHUSER": prefix == nil ? "root" : "deploy",
                                                               "PREFIX": prefix ?? "", "SERVER_PATH": path])
        }

        /// A remote command as the login shell of the user who is not root runs it.
        func remote(_ command: String, input: String = "") throws -> Ran {
            try execute("/bin/bash", command, sh: "/bin/sh", extra: ["PATH": user.path], input: input)
        }

        private func execute(_ shell: String, _ text: String, sh: String, extra: [String: String],
                             input: String = "") throws -> Ran {
            let out = folder.appendingPathComponent("out"), err = folder.appendingPathComponent("err")
            for file in [log, out, err] { try Data().write(to: file) }
            var environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "LOG": log.path, "ROOTHOME": root.path,
                               "SYSTEM": system.path, "TOOLS": tools.path, "STATE": state.path,
                               "TEMPLATE": template.path, "RECORD": record.path, "PROGRAM_SH": sh]
            environment.merge(extra) { $1 }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: shell)
            child.arguments = ["-c", text]
            child.environment = environment
            let outHandle = try FileHandle(forWritingTo: out), errHandle = try FileHandle(forWritingTo: err)
            defer { try? outHandle.close(); try? errHandle.close() }
            child.standardOutput = outHandle
            child.standardError = errHandle
            child.standardInput = FileHandle.nullDevice
            if !input.isEmpty {
                let file = folder.appendingPathComponent("input")
                try Data(input.utf8).write(to: file)
                child.standardInput = try FileHandle(forReadingFrom: file)
            }
            try child.run()
            child.waitUntilExit()
            return Ran(status: child.terminationStatus, out: try String(contentsOf: out, encoding: .utf8),
                       err: try String(contentsOf: err, encoding: .utf8), log: try String(contentsOf: log, encoding: .utf8))
        }

        /// The agent's `ssh`: it takes its options and the host off, and the rest is the remote command, its words
        /// joined with spaces, which the login shell of the user reads.
        static let ssh = #"""
            ssh() {
                while [ "$#" -gt 0 ]; do case $1 in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
                shift
                printf 'ssh sends [%s]\n' "$PREFIX$*" >> "$LOG"
                PATH=$SERVER_PATH /bin/bash -c "$PREFIX$*"
            }

            """#

        /// `sudo -n -i -- WORDS`: root's login shell gets the words joined with spaces, with a backslash before each
        /// byte that is not a letter, a digit, "_", "-" or "$" (`man sudo`, `-i`), and root's folders are open while
        /// it runs. `record` stands first, so that the log says what root's login shell made of the words.
        static let sudo = #"""
            #!/bin/sh
            LC_ALL=C; export LC_ALL
            while [ "$#" -gt 0 ]; do case $1 in --) shift; break ;; -*) shift ;; *) break ;; esac; done
            { printf 'sudo gets'; printf ' [%s]' "$@"; echo; } >> "$LOG"
            line=
            add() {
                rest=$1
                [ -z "$line" ] || line="$line "
                while [ -n "$rest" ]; do
                    after=${rest#?}; c=${rest%"$after"}; rest=$after
                    case $c in [A-Za-z0-9_-] | \$) line=$line$c ;; *) line=$line\\$c ;; esac
                done
            }
            add "$RECORD"
            for word in "$@"; do add "$word"; done
            /bin/chmod 700 "$ROOTHOME" && /bin/chmod 755 "$SYSTEM" || exit 1
            PATH=$SYSTEM:$TOOLS /bin/bash -c "$line"
            status=$?
            /bin/chmod 000 "$ROOTHOME"; /bin/chmod 555 "$SYSTEM"
            exit $status

            """#

        /// What root's login shell runs, word by word. Then it runs it, with the shell of the test as `/bin/sh`.
        static let record = #"""
            #!/bin/sh
            { printf 'root runs'; printf ' [%s]' "$@"; echo; } >> "$LOG"
            if [ "$1" = /bin/sh ]; then shift; exec "$PROGRAM_SH" "$@"; fi
            exec /bin/bash -c '"$@"' bash "$@"

            """#

        /// Tailscale's command, as far as the steps and the app's keyed network step use it, as Tailscale 1.104.6 did
        /// it in a Debian 12 container on 11 November 2026 (`cmd/tailscale/cli/up.go`). `up` takes the key from the
        /// file that it names. It keeps the settings that it was given (`STATE/settings`, one flag a line) before it
        /// waits, also when it never comes up. Without `--reset`, an `up` that does not name each kept setting again is
        /// refused with Tailscale's words (`checkForAccidentalSettingReverts`). Without a key it waits for a sign-in;
        /// on a tailnet that approves each new machine by hand (`approveByHand`) it waits with a key too: the machine
        /// then has its address, which `ip` gives, but it does not run until an admin approves it (NeedsMachineAuth).
        /// It waits up to its `--timeout` (`STATE/up-waits`), and then ends with Tailscale's words; the real one with
        /// no `--timeout` waits for ever, which this one says, and ends at once with 125, so that no test waits.
        /// `status` ends with 1 while Tailscale does not run, with the line that Tailscale 1.104.6 prints for that state on
        /// standard output (`cmd/tailscale/cli/status.go`), and `status --json` gives the state.
        static let tailscale = #"""
            #!/bin/sh
            case $1 in
            version) echo 1.90.6 ;;
            up) key= reset= wait= missing=
                for word in "$@"; do
                    case $word in
                    --auth-key=file:*) key=${word#--auth-key=file:} ;;
                    --reset) reset=yes ;;
                    --timeout=*) wait=${word#--timeout=} ;;
                    esac
                done
                if [ -z "$reset" ] && [ -s "$STATE/settings" ]; then
                    while IFS= read -r kept; do
                        case " $* " in *" ${kept%%=*} "* | *" ${kept%%=*}="*) ;; *) missing="$missing $kept" ;; esac
                    done < "$STATE/settings"
                fi
                if [ -n "$missing" ]; then
                    printf "Error: changing settings via 'tailscale up' requires mentioning all\nnon-default flags. \
            To proceed, either re-run your command with --reset or ...\n\n\ttailscale %s%s\n\n" "$*" "$missing" >&2
                    exit 1
                fi
                : > "$STATE/settings"
                for word in "$@"; do
                    case $word in
                    up | --auth-key=* | --reset | --timeout=*) ;;
                    *) echo "$word" >> "$STATE/settings" ;;
                    esac
                done
                [ -z "$wait" ] || echo "$wait" >> "$STATE/up-waits"
                if [ -n "$key" ]; then cat "$key" > "$STATE/key" || exit 1; fi
                if [ -n "$key" ] && [ ! -e "$STATE/approval" ]; then echo Running > "$STATE/backend"; exit 0; fi
                if [ -n "$key" ]; then
                    echo NeedsMachineAuth > "$STATE/backend"
                    printf '\nTo approve your machine, visit (as admin):\n\n\t%s\n\n' \
                        https://login.tailscale.com/admin/machines >&2
                else
                    printf '\nTo authenticate, visit:\n\n\thttps://login.tailscale.com/a/0123456789abc\n\n' >&2
                fi
                if [ -z "$wait" ]; then
                    echo "tailscale (a stand-in): with no --timeout, it waits here for ever" >&2
                    exit 125
                fi
                echo 'timeout waiting for Tailscale service to enter a Running state; check health with' \
                    '"tailscale status"' >&2
                exit 1 ;;
            ip) case $(cat "$STATE/backend" 2>/dev/null) in
                Running | NeedsMachineAuth) echo 100.64.2.1 ;;
                *) echo "no current Tailscale IPs; state: NeedsLogin" >&2; exit 1 ;;
                esac ;;
            status) if [ "$2" = --json ]; then
                        printf '{"BackendState": "%s"}\n' "$(cat "$STATE/backend" 2>/dev/null || echo NeedsLogin)"
                    else case $(cat "$STATE/backend" 2>/dev/null) in
                        Running) echo "100.64.2.1  server  linux  -" ;;
                        NeedsMachineAuth) echo "Machine is not yet approved by tailnet admin."; exit 1 ;;
                        Stopped) echo "Tailscale is stopped."; exit 1 ;;
                        *) echo "Logged out."; exit 1 ;;
                        esac
                    fi ;;
            *) exit 2 ;;
            esac

            """#

        /// `curl` gives Tailscale's install script, as far as it uses apt on Ubuntu and Debian: it stops at the first
        /// command that fails, and it runs `apt-get update` and then `apt-get install -y tailscale
        /// tailscale-archive-keyring` with no wait for apt's lock. That apt-get puts `tailscale` among the system's
        /// programs. While `STATE/curl-fails` has a number that is more than 0 (`failCurl`), it gets no script, as when
        /// the network of a new server is not ready yet.
        static let curl = #"""
            #!/bin/sh
            fails=0
            [ -s "$STATE/curl-fails" ] && fails=$(cat "$STATE/curl-fails")
            if [ "$fails" -gt 0 ]; then
                echo "$((fails - 1))" > "$STATE/curl-fails"
                echo "curl: (6) Could not resolve host: tailscale.com" >&2
                exit 6
            fi
            cat <<'SCRIPT'
            set -eu
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y tailscale tailscale-archive-keyring
            SCRIPT

            """#

        /// `apt-get`, as far as step 3 and Tailscale's installer use it. It asks nothing only when it is told so.
        /// While the first updates of a new server hold the lock of dpkg (`holdAptLock`: `STATE/apt-lock` has the
        /// seconds that they still hold it), each apt-get except `update` needs that lock, as apt's own does: when
        /// `-o DPkg::Lock::Timeout=` does not let it wait that long, it stops at once with apt's words; else it waits
        /// until the updates end, takes the lock, and writes the seconds that it waited to `STATE/apt-waited`.
        static let aptGet = #"""
            #!/bin/sh
            [ "${DEBIAN_FRONTEND:-}" = noninteractive ] || { echo "apt-get: it would ask" >&2; exit 1; }
            wait=0
            for word in "$@"; do case $word in DPkg::Lock::Timeout=*) wait=${word#*=} ;; esac; done
            case " $* " in *" update "*) exit 0 ;; esac
            held=0
            [ -s "$STATE/apt-lock" ] && held=$(cat "$STATE/apt-lock")
            if [ "$held" -gt 0 ]; then
                if [ "$wait" -lt "$held" ]; then
                    lock=/var/lib/dpkg/lock-frontend
                    echo "E: Could not get lock $lock. It is held by process 1234 (unattended-upgr)" >&2
                    exit 100
                fi
                echo "$held" >> "$STATE/apt-waited" && rm -f "$STATE/apt-lock"
            fi
            case " $* " in
            *" install "*" tailscale "*) cp "$TEMPLATE" "$SYSTEM/tailscale" && chmod 755 "$SYSTEM/tailscale" ;;
            esac

            """#

        /// `sleep`: it writes the seconds that it got to `STATE/slept`, and ends at once.
        static let sleep = #"""
            #!/bin/sh
            echo "$1" >> "$STATE/slept"

            """#

        /// GNU `stat -c %a FILE`, the one form that the steps use.
        #if os(macOS)
        static let stat = "#!/bin/sh\n[ \"$#\" = 3 ] && [ \"$1\" = -c ] && [ \"$2\" = %a ] || exit 2\n"
            + "exec /usr/bin/stat -f %Lp \"$3\"\n"
        #else
        static let stat = "#!/bin/sh\nexec /usr/bin/stat \"$@\"\n"
        #endif
    }
}
