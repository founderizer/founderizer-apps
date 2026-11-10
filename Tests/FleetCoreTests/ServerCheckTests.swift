import Foundation
import Testing
@testable import FleetCore

/// **The check of a server before an install** (`ServerCheck`): the script's own lines under a real `sh`, what they
/// read as, every verdict, the one SSH session through a stand-in runner, and the address read through `ssh -G`.
struct ServerCheckTests {
    /// A server that can take either install, as the script prints it.
    static let ready = MachineInstallTests.ready

    private static func reading(_ changes: [String] = []) throws -> ServerCheck.Reading {
        let keys = Set(changes.map { String($0.split(separator: "=")[0]) })
        let lines = ready.filter { !keys.contains(String($0.split(separator: "=")[0])) } + changes
        return try #require(ServerCheck.read(lines.joined(separator: "\n")))
    }

    private static func verdict(_ changes: [String], job: InstallJob = .join, tailnet: String? = nil,
                                holds: Bool = false) throws -> ServerCheck.Verdict {
        ServerCheck.verdict(try reading(changes), job: job, holdsSudoPassword: holds, tailnet: tailnet)
    }

    // MARK: what the script prints, read

    @Test func aReadingHasEveryKeyTheScriptPrints() throws {
        let text = (Self.ready + ["listen=tcp/80/nginx", "listen=tcp/80/nginx", "listen=udp/41641/-", "listen=tcp/x/y",
                                  "reach=evil.example yes", "sudo: a password is required", "tailnet=owner@example.com"])
            .joined(separator: "\r\n").replacingOccurrences(of: "tailscale=none", with: "tailscale=running")
        let reading = try #require(ServerCheck.read(text))
        #expect(reading.user == "root" && reading.uid == 0 && reading.sudo == .root)
        #expect((reading.system, reading.version, reading.systemName) == ("ubuntu", "24.04", "Ubuntu"))
        #expect(reading.arch == "x86_64" && reading.memoryMB == 3911 && reading.diskFreeMB == 70000)
        #expect(reading.systemd && reading.ipv4Route && !reading.dpkgLock && reading.cloudInit == .done)
        #expect(reading.reach == ["github.com": .yes, "tailscale.com": .yes, "claude.ai": .yes, "chatgpt.com": .yes])
        #expect(reading.listeners.map { "\($0.proto)/\($0.port)/\($0.process)" }
                == ["tcp/22/sshd", "tcp/80/nginx", "tcp/443/caddy", "udp/41641/-"])
        #expect(reading.firewall == .inactive)
        #expect(reading.tailscale == .running(tailnet: "owner@example.com"))
    }

    /// A reading cut short, or not one at all, is no reading: the session dropped, or the user has no shell.
    @Test func aReadingWithoutItsLastLineIsNone() {
        #expect(ServerCheck.read(Self.ready.dropLast().joined(separator: "\n")) == nil)
        #expect(ServerCheck.read("This account is currently not available.") == nil)
        #expect(ServerCheck.read("user=root\nend=yes") == nil)
    }

    // MARK: the script itself, under the shell a Debian or Ubuntu server has

    /// A folder that stands for a server: its files under `root`, and stand-ins for its programs in `bin`.
    private final class Machine {
        let folder: URL
        var root: URL { folder.appendingPathComponent("root") }
        var bin: URL { folder.appendingPathComponent("bin") }

        init() throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fleet-check-" + UUID().uuidString)
            for path in ["root/proc/net", "root/etc/ufw", "root/var/lib/dpkg", "root/usr/sbin", "bin"] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(path), withIntermediateDirectories: true)
            }
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        func file(_ path: String, _ text: String, mode: Int = 0o644) throws {
            let url = root.appendingPathComponent(path)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }

        func program(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        /// The script as a server runs it: `sh -s`, reading it on standard input.
        func check() throws -> String {
            let shell = Process(), out = Pipe(), input = Pipe()
            shell.executableURL = URL(fileURLWithPath: "/bin/dash")
            shell.arguments = ["-s"]
            shell.environment = ["PATH": bin.path + ":/usr/bin:/bin", "FOUNDERIZER_CHECK_ROOT": root.path]
            shell.standardOutput = out; shell.standardError = FileHandle.nullDevice; shell.standardInput = input
            try shell.run()
            try input.fileHandleForWriting.write(contentsOf: Data(ServerCheck.script.utf8))
            try input.fileHandleForWriting.close()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            shell.waitUntilExit()
            return text
        }
    }

    /// A user of the `sudo` group whose `sudo` asks for a password, on Ubuntu 24.04 with nginx, a first boot that is
    /// still running, apt holding its lock, and one host that does not answer.
    private func busyServer() throws -> Machine {
        let machine = try Machine()
        try FileManager.default.createDirectory(at: machine.root.appendingPathComponent("run/systemd/system"),
                                                withIntermediateDirectories: true)
        try machine.file("etc/os-release", "NAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\nID=ubuntu\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\n")
        try machine.file("proc/meminfo", "MemTotal:        4004636 kB\nMemFree:          123456 kB\n")
        try machine.file("proc/net/route", "Iface\tDestination\tGateway\tFlags\nens3\t00000000\t0101A8C0\t0003\n")
        try machine.file("proc/locks", "1: POSIX  ADVISORY  WRITE 2381 fd:01:4242 0 EOF\n2: FLOCK  ADVISORY  WRITE 99 00:19:7 0 EOF\n")
        try machine.file("var/lib/dpkg/lock-frontend", "")
        try machine.file("usr/sbin/ufw", "", mode: 0o755)
        try machine.file("etc/ufw/ufw.conf", "ENABLED=yes\nLOGLEVEL=low\n")
        try machine.program("id", """
        case "$1" in -u) echo 1000 ;; -un) echo deploy ;; -nG) echo "deploy adm sudo users" ;; esac
        """)
        try machine.program("sudo", "echo 'sudo: a password is required' >&2; exit 1")
        try machine.program("uname", "echo x86_64")
        try machine.program("df", "echo 'Filesystem 1024-blocks Used Available Capacity Mounted'; echo '/dev/sda1 81000000 9000000 71680000 12% /'")
        try machine.program("stat", "case \"$3\" in *lock-frontend) echo 4242 ;; *) exit 1 ;; esac")
        try machine.program("curl", "for a in \"$@\"; do last=\"$a\"; done; case \"$last\" in *chatgpt.com*) exit 28 ;; esac")
        try machine.program("cloud-init", "echo 'status: running'")
        try machine.program("ss", """
        case "$*" in *p*) echo 'ss -p as a user that may not' >&2; exit 1 ;; esac
        echo 'tcp   LISTEN 0 4096   0.0.0.0:22        0.0.0.0:*'
        echo 'tcp   LISTEN 0 511       [::]:80           [::]:*'
        echo 'tcp   LISTEN 0 511    0.0.0.0:80        0.0.0.0:*'
        echo 'udp   UNCONN 0 0    127.0.0.53%lo:53    0.0.0.0:*'
        echo 'tcp   LISTEN 0 5   [fe80::1%eth0]:546      [::]:*'
        echo 'tcp   LISTEN 0 5    100.90.1.2:8765     0.0.0.0:*'
        echo 'tcp   LISTEN 0 5 [fd7a:115c:a1e0::1]:9418  [::]:*'
        echo 'tcp   LISTEN 0 5          [::1]:631        [::]:*'
        echo 'tcp   LISTEN 0 5              *:443           *:*'
        """)
        try machine.program("tailscale", #"printf '{\n\t"BackendState": "Running",\n\t"CurrentTailnet": {\n\t\t"Name": "owner@example.com",\n\t\t"MagicDNSSuffix": "tail1234.ts.net"\n\t},\n\t"User": {"1": {"LoginName": "x"}}\n}\n'"#)
        return machine
    }

    @Test func theScriptReadsAServerUnderDash() throws {
        let machine = try busyServer()
        let output = try machine.check()
        let reading = try #require(ServerCheck.read(output), "\(output)")
        #expect(reading.user == "deploy" && reading.uid == 1000 && reading.sudo == .password)
        #expect((reading.system, reading.version, reading.systemName) == ("ubuntu", "24.04", "Ubuntu"))
        #expect(reading.arch == "x86_64" && reading.memoryMB == 3910 && reading.diskFreeMB == 70000)
        #expect(reading.systemd && reading.ipv4Route)
        #expect(reading.reach == ["github.com": .yes, "tailscale.com": .yes, "claude.ai": .yes, "chatgpt.com": .no])
        #expect(reading.cloudInit == .running && reading.dpkgLock)
        // Loopback, link-local and the private network are no public port; v4 and v6 of one port are one.
        #expect(reading.listeners.map { "\($0.proto)/\($0.port)/\($0.process)" } == ["tcp/22/-", "tcp/80/-", "tcp/443/-"])
        #expect(reading.firewall == .active)
        #expect(reading.tailscale == .running(tailnet: "owner@example.com"))
        #expect(output.split(separator: "\n").last == "end=yes")
    }

    /// Root sees which program holds a port, and a server with nothing on it says so in its own words.
    @Test func theScriptReadsABareServerAsRoot() throws {
        let machine = try Machine()
        try machine.file("etc/os-release", "NAME=\"Debian GNU/Linux\"\nVERSION_ID=\"12\"\nID=debian\n")
        try machine.file("proc/meminfo", "MemTotal:        1004636 kB\n")
        try machine.file("proc/net/route", "Iface\tDestination\tGateway\tFlags\n")
        try machine.file("proc/locks", "")
        try machine.program("id", "case \"$1\" in -u) echo 0 ;; -un) echo root ;; -nG) echo root ;; esac")
        try machine.program("uname", "echo aarch64")
        try machine.program("df", "echo 'Filesystem 1024-blocks Used Available Capacity Mounted'; echo '/dev/vda1 20000000 2000000 17000000 10% /'")
        try machine.program("ss", """
        case "$*" in *p*) ;; *) exit 1 ;; esac
        echo 'tcp   LISTEN 0 4096   0.0.0.0:22   0.0.0.0:*   users:(("sshd",pid=773,fd=3),("systemd",pid=1,fd=56))'
        echo 'tcp   LISTEN 0 511       [::]:80      [::]:*   users:(("nginx",pid=9,fd=7))'
        """)
        // This Mac has a curl and may have a tailscale of its own, which the script finds after the stand-ins: so the
        // stand-ins answer as a server whose network is closed and whose Tailscale is logged out.
        try machine.program("curl", "exit 7")
        try machine.program("tailscale", "exit 1")
        let reading = try #require(ServerCheck.read(try machine.check()))
        #expect(reading.sudo == .root && reading.system == "debian" && reading.arch == "aarch64" && reading.memoryMB == 981)
        #expect(!reading.ipv4Route && !reading.dpkgLock && reading.cloudInit == .none && !reading.systemd)
        #expect(Set(reading.reach.values) == [.no] && reading.reach.count == 4)
        #expect(reading.listeners.map { "\($0.proto)/\($0.port)/\($0.process)" } == ["tcp/22/sshd", "tcp/80/nginx"])
        #expect(reading.firewall == .absent && reading.tailscale == .loggedOut)
        #expect(ServerCheck.verdict(reading, job: .join) == .stop(
            "This server does not run systemd, and this install needs a full VPS that does."))
    }

    // MARK: every verdict

    @Test func aServerThatCanTakeTheInstallIsReadyWithOneLineOfWhatChanges() throws {
        #expect(try Self.verdict([]) == .ready(summary: "Ubuntu 24.04 · 4 GB · x86",
                                               changes: "SSH moves to Tailscale. Port 443 stays open."))
        #expect(try Self.verdict(["os_id=debian", "os_version=12", "arch=aarch64", "memory_mb=1940"])
                == .ready(summary: "Debian 12 · 2 GB · Arm", changes: "SSH moves to Tailscale. Port 443 stays open."))
        // No curl and no wget: the install brings curl, so nothing stops.
        if case .ready = try Self.verdict(["reach=github.com none"]) {} else { Issue.record("no fetcher stopped the check") }
    }

    @Test func theLineOfWhatChangesNamesEveryOtherTCPPort() throws {
        func changes(_ listeners: [String], port: Int = 22) throws -> String {
            ServerCheck.changes(try Self.reading(listeners), sshPort: port)
        }
        #expect(try changes(["listen=tcp/22/sshd"]) == "SSH moves to Tailscale.")
        #expect(try changes(["listen=tcp/22/-", "listen=tcp/80/nginx", "listen=tcp/443/nginx", "listen=udp/41641/tailscaled"])
                == "SSH moves to Tailscale. Ports 80 and 443 stay open.")
        #expect(try changes(["listen=tcp/80/-", "listen=tcp/443/-", "listen=tcp/8080/node"])
                == "SSH moves to Tailscale. Ports 80, 443 and 8080 stay open.")
        // SSH on its own port, and an sshd on a second one, both move.
        #expect(try changes(["listen=tcp/2222/-", "listen=tcp/22/sshd", "listen=tcp/80/-"], port: 2222)
                == "SSH moves to Tailscale. Port 80 stays open.")
    }

    @Test func aServerStillStartingIsWaitedFor() throws {
        #expect(try Self.verdict(["cloud_init=running"]) == .wait("The server is still setting itself up after its first start."))
        #expect(try Self.verdict(["dpkg_lock=yes"]) == .wait("The server is installing its updates."))
    }

    @Test func aSudoThatAsksForAPasswordAsksForItOnce() throws {
        #expect(try Self.verdict(["user=deploy", "uid=1000", "sudo=password"]) == .needsPassword(.sudo))
        if case .ready = try Self.verdict(["user=deploy", "uid=1000", "sudo=password"], holds: true) {} else {
            Issue.record("a held password did not open the check")
        }
        if case .ready = try Self.verdict(["user=deploy", "uid=1000", "sudo=nopasswd"]) {} else {
            Issue.record("a sudo that asks nothing was stopped")
        }
        // A password is asked before a wait: he gives it while the server finishes.
        #expect(try Self.verdict(["sudo=password", "uid=1000", "cloud_init=running"]) == .needsPassword(.sudo))
    }

    /// The systems come from the one table the installers' own words come from.
    @Test func anotherSystemStopsWithTheSystemsEachInstallTakes() throws {
        #expect(try Self.verdict(["os_id=fedora", "os_version=41"]) == .stop(InstallPlan.joinSystems))
        #expect(try Self.verdict(["os_id=ubuntu", "os_version=20.04"], job: .hub) == .stop(InstallPlan.hubSystems))
        // Both installers take Ubuntu 26.04 and Debian 13, each proved on a new server of that system.
        for job in InstallJob.allCases {
            if case .ready = try Self.verdict(["os_version=26.04"], job: job) {} else {
                Issue.record("the \(job) refused Ubuntu 26.04")
            }
            if case .ready = try Self.verdict(["os_id=debian", "os_version=13", "os_name=Debian GNU/Linux"], job: job) {}
            else { Issue.record("the \(job) refused Debian 13") }
        }
        #expect(try Self.verdict(["os_id=debian", "os_version=14"], job: .hub) == .stop(InstallPlan.hubSystems))
        #expect(InstallPlan.joinSystems == "This install needs Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13.")
        #expect(InstallPlan.hubSystems == InstallPlan.joinSystems)
        #expect(try Self.verdict(["arch=riscv64"])
                == .stop("This server is a riscv64 machine, and this install needs a 64-bit x86 or Arm server."))
        #expect(try Self.verdict(["systemd=no"])
                == .stop("This server does not run systemd, and this install needs a full VPS that does."))
    }

    @Test func eachStopSaysItsCauseAndItsFix() throws {
        let decimal = (0.5).formatted(.number.precision(.fractionLength(1))).dropFirst().first.map(String.init) ?? "."
        #expect(try Self.verdict(["user=deploy", "uid=1000", "sudo=none"]) == .stop(ServerCheck.notRoot("deploy")))
        #expect(ServerCheck.notRoot("deploy") == InstallError.notRoot("deploy").errorDescription)
        #expect(try Self.verdict(["memory_mb=1500"]) == .stop("This server has 1\(decimal)5 GB of memory, and a server "
                                                              + "for agents needs about 2 GB. Choose a plan with more memory."))
        if case .ready = try Self.verdict(["memory_mb=960"], job: .hub) {} else { Issue.record("the hub's 1 GB VPS was stopped") }
        #expect(try Self.verdict(["memory_mb=480"], job: .hub)
                == .stop("This server has 480 MB of memory, and the hub needs about 1 GB. Choose a plan with more memory."))
        #expect(try Self.verdict(["disk_free_mb=6348"]) == .stop("This server has 6\(decimal)2 GB of free disk, and the install "
                                                                 + "needs about 10 GB. Free some space, or choose a bigger disk."))
        #expect(try Self.verdict(["ipv4_route=no"]) == .stop("This server has no IPv4 route, and GitHub answers over IPv4 only. "
                                                            + "Give it a public IPv4 address at your provider."))
        #expect(try Self.verdict(["reach=tailscale.com no"])
                == .stop("This server cannot reach tailscale.com over HTTPS. Let it make outgoing HTTPS connections."))
        // One AI's site is enough for a server for agents, and the fleet's own VPS needs neither.
        if case .ready = try Self.verdict(["reach=claude.ai no"]) {} else { Issue.record("one AI's site was enough") }
        if case .ready = try Self.verdict(["reach=claude.ai no", "reach=chatgpt.com no"], job: .hub) {}
        else { Issue.record("the fleet's own VPS runs no agent") }
        #expect(try Self.verdict(["reach=claude.ai no", "reach=chatgpt.com no"])
                == .stop("This server cannot reach claude.ai or chatgpt.com over HTTPS. Let it make outgoing HTTPS connections."))
        #expect(try Self.verdict(["reach=github.com no", "reach=claude.ai no", "reach=chatgpt.com no", "reach=tailscale.com yes"])
                == .stop("This server cannot reach github.com, claude.ai or chatgpt.com over HTTPS. "
                         + "Let it make outgoing HTTPS connections."))
    }

    @Test func aServerOnAnotherTailnetStops() throws {
        let other = ["tailscale=running", "tailnet=someone@example.org"]
        #expect(try Self.verdict(other, tailnet: "owner@example.com")
                == .stop("This server is on another Tailscale network, someone@example.org. "
                         + "Run tailscale logout on it, then check again."))
        if case .ready = try Self.verdict(["tailscale=running", "tailnet=Owner@Example.com"], tailnet: "owner@example.com") {} else {
            Issue.record("the fleet's own tailnet was stopped")
        }
        // Without the fleet's own network to compare with, and on a server that is logged out, nothing stops.
        if case .ready = try Self.verdict(other) {} else { Issue.record("an unknown fleet network stopped the check") }
        if case .ready = try Self.verdict(["tailscale=loggedout"], tailnet: "owner@example.com") {} else {
            Issue.record("a logged-out Tailscale stopped the check")
        }
    }

    // MARK: one SSH session, through a stand-in runner

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(executable: String, arguments: [String], stdin: Data?)] = []
        func add(_ executable: String, _ arguments: [String], _ stdin: Data?) {
            lock.withLock { seen.append((executable, arguments, stdin)) }
        }
        var all: [(executable: String, arguments: [String], stdin: Data?)] { lock.withLock { seen } }
    }

    /// A folder with no key in it, so a check tries none of the key files of the Mac that runs the tests.
    private static let noKeys = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fleet-no-keys-" + UUID().uuidString)

    private func check(_ status: Int32, _ output: String, target: InstallTarget = InstallTarget(host: "203.0.113.9"),
                       calls: Calls = Calls()) async -> ServerCheck.Result {
        await ServerCheck.run(target, job: .join, keys: Self.noKeys, ssh: "/usr/bin/ssh") { executable, arguments, stdin, _ in
            calls.add(executable, arguments, stdin)
            return LocalShell.Answer(status: status, output: output)
        }
    }

    @Test func oneSessionRunsTheScriptAsTheLoginUser() async throws {
        let calls = Calls()
        let target = InstallTarget(host: "203.0.113.9", user: "deploy", port: 2222, identityFile: "/Users/me/.ssh/id_vps",
                                   becomeRoot: true)
        let result = await check(0, Self.ready.joined(separator: "\n"), target: target, calls: calls)
        // SSH is on 2222 here, and the sshd on 22 moves to Tailscale as well.
        #expect(result.verdict == .ready(summary: "Ubuntu 24.04 · 4 GB · x86",
                                         changes: "SSH moves to Tailscale. Port 443 stays open."))
        #expect(result.reading?.user == "root")
        let call = try #require(calls.all.first)
        #expect(calls.all.count == 1)
        #expect(call.executable == "/usr/bin/ssh")
        #expect(Array(call.arguments.suffix(2)) == ["deploy@203.0.113.9", "/bin/sh -s"])
        #expect(call.arguments.contains("BatchMode=yes") && call.arguments.contains("/Users/me/.ssh/id_vps"))
        #expect(call.arguments.contains("2222"))
        #expect(call.stdin == Data(ServerCheck.script.utf8))
    }

    @Test func whatSshSaysWhenItDidNotRunTheScript() async {
        #expect(await check(255, "root@203.0.113.9: Permission denied (publickey,password).").verdict == .needsPassword(.ssh))
        #expect(await check(255, "deploy@203.0.113.9: Permission denied (publickey,keyboard-interactive).").verdict
                == .needsPassword(.ssh))
        #expect(await check(255, "Received disconnect from 203.0.113.9 port 22:2: Too many authentication failures").verdict
                == .needsPassword(.ssh))
        #expect(await check(255, "root@203.0.113.9: Permission denied (publickey).").verdict
                == .stop("203.0.113.9 did not take your SSH key. Choose its key."))
        #expect(await check(255, "ssh: connect to host 203.0.113.9 port 22: Connection refused").verdict
                == .stop("This Mac could not reach 203.0.113.9 over SSH."))
        #expect(await check(255, "").verdict == .stop("This Mac could not reach 203.0.113.9 over SSH."))
        let changed = await check(255, "@@@@@@@@\nWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.")
        #expect(changed.verdict == .stop(ServerCheck.hostKeyChanged("203.0.113.9")))
        #expect(ServerCheck.hostKeyChanged("203.0.113.9").contains("ssh-keygen -R 203.0.113.9"))
        #expect(await check(1, "This account is currently not available.").verdict
                == .stop(ServerCheck.noAnswer("203.0.113.9")))
        // The words the install itself says for the same two stops.
        #expect(ServerCheck.unreached("h") == InstallError.step("Read the server", "ssh: connect to host h port 22: "
                                                                + "Connection refused").plain(host: "h"))
        #expect(ServerCheck.keyRefused("h") == InstallError.step("Read the server", "Permission denied (publickey).")
                    .plain(host: "h"))
    }

    // MARK: this Mac's own key files, one at a time

    /// A folder that stands for `~/.ssh`, with an empty file for each name: the check gives `ssh` paths and reads none.
    private static func keyFolder(_ names: [String]) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fleet-keys-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data().write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    /// The key file one session was given, or nil where it left the keys to `ssh` and its agent.
    private static func key(_ arguments: [String]) -> String? {
        arguments.firstIndex(of: "-i").map { arguments[$0 + 1] }
    }

    private static let tooMany = "Received disconnect from 203.0.113.9 port 22:2: Too many authentication failures\n"
        + "Disconnected from 203.0.113.9 port 22"

    @Test func theKeyFilesAreTheStandardNamesThenTheAppsOwnOfThoseThatAreThere() throws {
        let folder = try Self.keyFolder(["id_rsa", "founderizer_ed25519", "id_ed25519", "id_dsa", "id_ecdsa.pub", "config"])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ServerCheck.keyFiles(in: folder)
                == ["id_ed25519", "id_rsa", "founderizer_ed25519"].map { folder.appendingPathComponent($0).path })
        #expect(ServerCheck.keyFiles(in: folder.appendingPathComponent("nothing")).isEmpty)
    }

    /// The proof run of 5 November 2026: this Mac's agent offered four Teleport identities, and the server hung up before
    /// `~/.ssh/id_ed25519` came. Each key file then goes alone, in order, and the first that opens the server is its key.
    @Test func aRefusedAgentGoesOnToEachKeyFileAloneUntilOneOpensTheServer() async throws {
        let folder = try Self.keyFolder(["id_ed25519", "id_ecdsa", "id_rsa", "founderizer_ed25519"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = ServerCheck.keyFiles(in: folder), calls = Calls()
        let target = InstallTarget(host: "203.0.113.9")
        let result = await ServerCheck.run(target, job: .hub, keys: folder, ssh: "/usr/bin/ssh") { executable, arguments, stdin, _ in
            calls.add(executable, arguments, stdin)
            switch Self.key(arguments) {
            case nil: return LocalShell.Answer(status: 255, output: Self.tooMany)
            case keys[1]: return LocalShell.Answer(status: 0, output: Self.ready.joined(separator: "\n"))
            default: return LocalShell.Answer(status: 255, output: "root@203.0.113.9: Permission denied (publickey).")
            }
        }
        #expect(calls.all.map { Self.key($0.arguments) } == [nil, keys[0], keys[1]])
        // Each key file goes alone, and none of them can ask for a passphrase.
        #expect(calls.all.allSatisfy { $0.arguments.contains("BatchMode=yes") && $0.stdin == Data(ServerCheck.script.utf8) })
        #expect(calls.all.map { $0.arguments.contains("IdentitiesOnly=yes") } == [false, true, true])
        if case .ready = result.verdict {} else { Issue.record("the key that opened the server did not make it ready") }
        #expect(result.reading?.user == "root")
        #expect(result.target == InstallTarget(host: "203.0.113.9", identityFile: keys[1]))
    }

    /// No key file opened it: the check says what its first session heard, as before, and keeps the target as it was.
    /// The target's own key is not tried a second time.
    @Test func aServerThatNoKeyFileOpensSaysWhatTheFirstSessionHeard() async throws {
        let folder = try Self.keyFolder(["id_ed25519", "id_rsa", "founderizer_ed25519"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = ServerCheck.keyFiles(in: folder), calls = Calls()
        let target = InstallTarget(host: "203.0.113.9", identityFile: keys[1])
        let result = await ServerCheck.run(target, job: .join, keys: folder, ssh: "/usr/bin/ssh") { executable, arguments, stdin, _ in
            calls.add(executable, arguments, stdin)
            return LocalShell.Answer(status: 255, output: Self.key(arguments) == keys[1]
                                     ? "root@203.0.113.9: Permission denied (publickey,password)."
                                     : "root@203.0.113.9: Permission denied (publickey).")
        }
        #expect(calls.all.map { Self.key($0.arguments) } == [keys[1], keys[0], keys[2]])
        #expect(result.verdict == .needsPassword(.ssh))
        #expect(result.target == target)
    }

    /// Only a refused key leads to the key files: a server that was not reached, that changed its host key, that takes
    /// no keys at all, or that let the first session in gets one session.
    @Test func aSessionThatNoKeyStoppedTriesNoKeyFile() async throws {
        let folder = try Self.keyFolder(["id_ed25519", "founderizer_ed25519"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let answers: [(Int32, String)] = [
            (255, "ssh: connect to host 203.0.113.9 port 22: Connection refused"),
            (255, "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed."),
            (255, "root@203.0.113.9: Permission denied (password)."),
            (0, Self.ready.joined(separator: "\n")),
        ]
        for (status, output) in answers {
            let calls = Calls()
            let target = InstallTarget(host: "203.0.113.9")
            let result = await ServerCheck.run(target, job: .join, keys: folder, ssh: "/usr/bin/ssh") { executable, arguments, stdin, _ in
                calls.add(executable, arguments, stdin)
                return LocalShell.Answer(status: status, output: output)
            }
            #expect(calls.all.count == 1, "\(output)")
            #expect(result.target == target, "\(output)")
        }
    }

    // MARK: an address, through `ssh -G`

    private static let home = "/Users/me"

    private static func options(_ text: String) -> SSHOptions? { SSHOptions.read(text) }

    @Test func sshGIsReadForItsFourOptions() throws {
        let options = try #require(SSHOptions.read("""
        Pseudo-terminal will not be allocated because stdin is not a terminal.
        host myvps
        user deploy
        hostname 203.0.113.9
        port 2222
        batchmode no
        identityfile ~/.ssh/vps_key
        identityfile %d/.ssh/other key
        identityfile ~/.ssh/general
        """))
        #expect(options == SSHOptions(hostname: "203.0.113.9", user: "deploy", port: 2222,
                                      identityFiles: ["~/.ssh/vps_key", "%d/.ssh/other key", "~/.ssh/general"]))
        #expect(SSHOptions.read("ssh: Could not resolve hostname") == nil)
        #expect(SSHOptions.path("~/.ssh/vps_key", home: Self.home, localUser: "me", host: "h", user: "u") == "/Users/me/.ssh/vps_key")
        #expect(SSHOptions.path("%d/.ssh/%r@%h", home: Self.home, localUser: "me", host: "h", user: "u") == "/Users/me/.ssh/u@h")
        #expect(SSHOptions.path("/keys/100%%", home: Self.home, localUser: "me", host: "h", user: "u") == "/keys/100%")
        #expect(SSHOptions.path("%C/key", home: Self.home, localUser: "me", host: "h", user: "u") == nil)
        #expect(SSHOptions.path("relative_key", home: Self.home, localUser: "me", host: "h", user: "u") == nil)
    }

    @Test func anAliasGivesItsHostnameUserPortAndOwnKey() {
        let alias = SSHOptions(hostname: "203.0.113.9", user: "deploy", port: 2222,
                               identityFiles: ["~/.ssh/missing", "~/.ssh/vps_key", "~/.ssh/general"])
        let general = SSHOptions(hostname: "founderizer-x.invalid", user: "me", port: 22, identityFiles: ["~/.ssh/general"])
        let target = InstallTarget.named("myvps", options: alias, general: general, localUser: "me", home: Self.home) {
            $0 != "/Users/me/.ssh/missing"
        }
        #expect(target == InstallTarget(host: "203.0.113.9", user: "deploy", port: 2222,
                                        identityFile: "/Users/me/.ssh/vps_key", becomeRoot: true))
        // The keys his configuration gives every server stay ssh's own to offer: none goes with IdentitiesOnly.
        let everywhere = SSHOptions(hostname: "198.51.100.7", user: "me", port: 22, identityFiles: ["~/.ssh/general"])
        #expect(InstallTarget.named("198.51.100.7", options: everywhere, general: general, localUser: "me",
                                    home: Self.home) { _ in true }
                == InstallTarget(host: "198.51.100.7", user: "root", port: 22, identityFile: nil, becomeRoot: false))
        // A user he typed wins over the configuration's.
        #expect(InstallTarget.named("admin@myvps", options: alias, general: general, localUser: "me", home: Self.home) { _ in false }
                == InstallTarget(host: "203.0.113.9", user: "admin", port: 2222, becomeRoot: true))
        // No answer from ssh -G leaves the address as he typed it.
        #expect(InstallTarget.named("ubuntu@198.51.100.7", options: nil, localUser: "me", home: Self.home) { _ in true }
                == InstallTarget(host: "198.51.100.7", user: "ubuntu", becomeRoot: true))
    }

    @Test func anAddressIsReadThroughSshGAndNothingElse() async {
        let calls = Calls()
        let target = await InstallTarget.named("myvps", ssh: "/usr/bin/ssh") { executable, arguments, stdin, _ in
            calls.add(executable, arguments, stdin)
            let probe = arguments.last?.hasSuffix(".invalid") == true
            return LocalShell.Answer(status: 0, output: probe ? "hostname x\nuser \(NSUserName())\nport 22\n"
                                     : "host myvps\nhostname 203.0.113.9\nuser deploy\nport 2222\nidentityfile /nonexistent/key\n")
        }
        #expect(target == InstallTarget(host: "203.0.113.9", user: "deploy", port: 2222, becomeRoot: true))
        #expect(calls.all.map(\.arguments.first) == ["-G", "-G"])
        #expect(calls.all.first?.arguments == ["-G", "myvps"])
        #expect(calls.all.last?.arguments.last?.hasPrefix("founderizer-") == true)
        // A name ssh would read as one of its own options never reaches it.
        let none = Calls()
        let typed = await InstallTarget.named("-oProxyCommand=evil", ssh: "/usr/bin/ssh") { executable, arguments, stdin, _ in
            none.add(executable, arguments, stdin)
            return LocalShell.Answer(status: 0, output: "")
        }
        #expect(none.all.isEmpty)
        #expect(typed.isValid == false)
    }
}
