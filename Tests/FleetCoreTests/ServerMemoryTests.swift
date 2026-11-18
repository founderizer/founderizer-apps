import Foundation
import Testing
@testable import FleetCore

/// A server's memory reserve and limit, put right by the owner's Mac (`ServerMemory`): what a round reads, what the
/// program does on a server, and how its output reads. The program runs here in this Mac's `/bin/sh` and in dash, the
/// `/bin/sh` of Debian and Ubuntu, under a folder that stands for the server's root, with stand-ins for the commands
/// that need root or Linux. Each stand-in leaves what the real command leaves: `swapon` puts the file into the
/// kernel's list, and systemd's reload makes the kernel's limit follow the file that is written.
struct ServerMemoryTests {
    static let time: Double = 1_000_000
    static let shells = ["/bin/sh", "/bin/dash"]

    // MARK: what a round reads

    private func server(guarded: Bool?, hub: Bool = false, job: String? = nil, source: String = "server",
                        reportedAt: Double = time - 60, claimed: Double = time - 7200) throws -> ServerEntry {
        var security: [String: Any] = ["firewall": "active", "tailscale": true, "ssh_keys_only": true, "npm_rule": true]
        if let guarded { security["memory_guard"] = guarded }
        var entry: [String: Any] = ["name": hub ? "hub" : "app-1", "hub": hub, "joined": !hub, "agents": [],
                                    "address": "100.80.1.7", "available": true, "why": []]
        if hub {
            var own: [String: Any] = ["ssh_keys_only": true, "npm_rule": true, "at": reportedAt, "claimed_at": claimed]
            if let guarded { own["memory_guard"] = guarded }
            entry["hardening"] = own
        } else {
            entry["kind"] = "linux"
            entry["reading"] = ["source": source, "os": ["name": "Ubuntu 24.04"], "runtimes": [:],
                                "reported_at": reportedAt, "stale": false, "security": security] as [String: Any]
        }
        if let job {
            entry["job"] = ["id": 4, "kind": "install", "agent": "dev-lead", "state": job, "created": Self.time - 100,
                            "updated": Self.time - 50] as [String: Any]
        }
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    private func read(_ server: ServerEntry, join: JoinState? = nil) -> ServerHardening.Reading {
        ServerMemory.reading(of: server, join: join, at: Self.time)
    }

    @Test func noLimitIsTheFaultALimitHoldsAndNoFactSaysNothing() throws {
        #expect(read(try server(guarded: false)) == .faulty)
        #expect(read(try server(guarded: true)) == .holds)
        // A helper or a hub from before owner API 1.211, and a system whose kernel has no such file.
        #expect(read(try server(guarded: nil)) == .unread)
        // The hub's own server, by the hub's own reading of it.
        #expect(read(try server(guarded: false, hub: true)) == .faulty)
        #expect(read(try server(guarded: true, hub: true)) == .holds)
        #expect(read(try server(guarded: nil, hub: true)) == .unread)
    }

    @Test func whatTheSweepDoesNotRead() throws {
        // A job of the server's service that is open, a reading of an agent's helper, an old reading, the hour after
        // the hub's claim, and the hour after the server's join.
        #expect(read(try server(guarded: false, job: "running")) == .unread)
        #expect(read(try server(guarded: false, source: "agent")) == .unread)
        #expect(read(try server(guarded: false, reportedAt: Self.time - 3600)) == .unread)
        #expect(read(try server(guarded: false, hub: true, claimed: Self.time - 600)) == .unread)
        let joined = try JSONDecoder().decode(JoinState.self, from: JSONSerialization.data(withJSONObject: [
            "name": "", "kind": "linux", "created": Self.time - 600, "expires_at": Self.time + 3000, "state": "joined",
            "server": "app-1"] as [String: Any]))
        #expect(read(try server(guarded: false), join: joined) == .unread)
    }

    /// The sweep takes `ServerHardening`'s own rounds: the fault in two rounds in a row runs the program, a run that
    /// sets the limit settles the server, and the log gets this sweep's own words.
    @Test func aRoundRunsThisSweepsOwnProgramAndReadsItsOwnOutput() async {
        var memory = ServerHardening.Memory()
        var unreached: VaultTries?
        let first = await ServerHardening.turn(
            .faulty, memory: &memory, unreached: &unreached, seenBefore: false, now: Self.time,
            started: ServerMemory.started, outcome: { ServerMemory.outcome($0) }, settledLine: "its memory limit is in order",
            connection: { throw CancellationError() }, run: { _ in "" })
        #expect(first == ServerHardening.Turn(seen: true))
        let second = await ServerHardening.turn(
            .faulty, memory: &memory, unreached: &unreached, seenBefore: true, now: Self.time,
            started: ServerMemory.started, outcome: { ServerMemory.outcome($0) }, settledLine: "its memory limit is in order",
            connection: { InstallTarget(host: "100.80.1.7") },
            run: { _ in "\n\(ServerMemory.started)\n\(ServerMemory.mark) swap=made-4G limit=set\n" })
        #expect(memory.settled)
        #expect(second.lines == ["\(ServerMemory.mark) swap=made-4G limit=set", "its memory limit is in order"])
        // The other sweep's last line settles nothing here.
        var other = ServerHardening.Memory()
        _ = await ServerHardening.turn(
            .faulty, memory: &other, unreached: &unreached, seenBefore: true, now: Self.time,
            started: ServerMemory.started, outcome: { ServerMemory.outcome($0) },
            connection: { InstallTarget(host: "100.80.1.7") },
            run: { _ in "\n\(ServerMemory.started)\n\(ServerHardening.mark) ssh=keys-only npm=held\n" })
        #expect(!other.settled && other.failures == 1)
    }

    // MARK: how a run's output reads

    @Test func theLimitDecidesWhatARunCameTo() {
        let begun = "\n\(ServerMemory.started)\n"
        for swap in ["made-4G", "held", "named", "file-there", "no-system", "no-space", "failed", "unread", "no-table"] {
            #expect(ServerMemory.outcome(begun + "\(ServerMemory.mark) swap=\(swap) limit=set\n") == .holds, "\(swap)")
        }
        #expect(ServerMemory.outcome(begun + "\(ServerMemory.mark) swap=held limit=own\n") == .holds)
        #expect(ServerMemory.outcome(begun + "\(ServerMemory.mark) swap=made-1G limit=no-group\n") == .leftAsItIs)
        #expect(ServerMemory.outcome(begun + "Failed to connect to bus\n\(ServerMemory.mark) swap=held limit=not-yet\n")
                == .failed("limit not-yet, swap held: Failed to connect to bus"))
        #expect(ServerMemory.outcome(begun + "\(ServerMemory.mark) swap=held limit=\n") == .failed("limit ?, swap held"))
        #expect(ServerMemory.outcome(begun + "Connection closed.\n") == .failed("the program started and did not end: Connection closed."))
        guard case .notStarted = ServerMemory.outcome("sudo: a password is required\n") else {
            Issue.record("an ssh that started nothing reads as a run"); return
        }
        // Neither sweep's first line is the other's, and the first line is no last line.
        #expect(ServerMemory.started != ServerHardening.started)
        #expect(!ServerMemory.started.hasPrefix(ServerMemory.mark + " "))
        guard case .notStarted = ServerMemory.outcome("refused:\n" + ServerMemory.program()) else {
            Issue.record("the program's own text reads as its first line"); return
        }
    }

    // MARK: the program on a server

    /// A server's root under a new folder: the kernel's files, the table, and the stand-ins. By default 4 GB of
    /// memory, no swap, no limit, ext4 and 30 GiB of free disk.
    private struct Root {
        let folder: URL
        var root: URL { folder.appendingPathComponent("root") }
        var bin: URL { folder.appendingPathComponent("bin") }
        var swaps: URL { root.appendingPathComponent("proc/swaps") }
        var table: URL { root.appendingPathComponent("etc/fstab") }
        var swapFile: URL { root.appendingPathComponent("swapfile") }
        var sysctl: URL { root.appendingPathComponent("etc/sysctl.d/60-fleet-swap.conf") }
        var kernelLimit: URL { root.appendingPathComponent("sys/fs/cgroup/user.slice/memory.max") }
        var limitFile: URL { root.appendingPathComponent("etc/systemd/system/user.slice.d/00-fleet-memory.conf") }
        static let head = "Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n"
        static let tableText = "LABEL=cloudimg-rootfs\t/\t ext4\tdiscard,commit=30,errors=remount-ro\t0 1\n"

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("memory-" + UUID().uuidString)
            for made in ["root/proc", "root/etc", "root/sys/fs/cgroup/user.slice", "bin"] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(made),
                                                        withIntermediateDirectories: true)
            }
            try put(swaps, Self.head)
            try put(root.appendingPathComponent("proc/meminfo"), "MemTotal:        3910656 kB\nMemFree:          171428 kB\n")
            try put(table, Self.tableText)
            try put(kernelLimit, "max\n")
            try put(folder.appendingPathComponent("fs"), "ext2/ext3\n")
            try put(folder.appendingPathComponent("free-kb"), "\(30 * 1_048_576)\n")
            let here = folder.path, r = root.path
            try stand("stat", "cat '\(here)/fs'")
            try stand("df", "printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/sda1 39956590 9 %s 25%% /\\n' \"$(cat '\(here)/free-kb')\"")
            // Each of the three steps says its own words and fails where a file `<name>-fails` is there. With
            // `<name>-stops`, the step tells the program's own shell to stop (TERM), as a stop of the run does, and
            // ends well itself: `run` keeps that shell's process id in `pid`.
            for name in ["fallocate", "mkswap", "swapon"] {
                try stand(name, """
                    echo "\(name) $*" >> '\(here)/ran'
                    [ -e '\(here)/\(name)-fails' ] && { echo '\(name): it failed: Operation not permitted' >&2; exit 1; }
                    [ -e '\(here)/\(name)-stops' ] && kill -TERM "$(cat '\(here)/pid')"
                    [ \(name) != swapon ] || printf '%s  file\\t\\t4194300\\t\\t0\\t\\t-2\\n' /swapfile >> '\(r)/proc/swaps'
                    exit 0
                    """)
            }
            // mv is the real one, but for the table where `table-stays` is there: a table that cannot be replaced.
            // With `table-then-stops`, the table is replaced and the program's shell is then told to stop.
            try stand("mv", """
                for last; do :; done
                [ -e '\(here)/table-stays' ] && [ "$last" = '\(r)/etc/fstab' ] && { echo 'mv: Read-only file system' >&2; exit 1; }
                /bin/mv "$@" || exit 1
                [ -e '\(here)/table-then-stops' ] && [ "$last" = '\(r)/etc/fstab' ] && kill -TERM "$(cat '\(here)/pid')"
                exit 0
                """)
            try stand("swapoff", "echo \"swapoff $*\" >> '\(here)/ran'; printf '%s' '\(Self.head)' > '\(r)/proc/swaps'")
            try stand("sysctl", "echo \"sysctl $*\" >> '\(here)/ran'")
            try stand("systemctl", """
                echo "systemctl $*" >> '\(here)/ran'
                [ -e '\(here)/reload-stops' ] && kill -TERM "$(cat '\(here)/pid')"
                [ -e '\(here)/systemd-deaf' ] && exit 1
                [ -e '\(r)\(ServerMemory.limitFile)' ] && echo 3473678336 > '\(r)\(ServerMemory.kernelLimit)'
                exit 0
                """)
        }

        func put(_ url: URL, _ text: String) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
        func mark(_ name: String) throws { try Data().write(to: folder.appendingPathComponent(name)) }
        private func stand(_ name: String, _ text: String) throws {
            let path = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + text + "\n").write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        /// The program in one shell, with the stand-ins first in its PATH: its last line, and all that it said.
        func run(_ shell: String) throws -> (last: String, output: String) {
            let child = Process(), output = Pipe()
            // The shell writes its own process id into `pid` and then becomes the shell that runs the program.
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "echo $$ > '\(folder.path)/pid'; exec \"$0\" -c \"$1\"", shell,
                               ServerMemory.program(root: root.path)]
            child.standardOutput = output
            child.standardError = output
            child.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = bin.path + ":/usr/bin:/bin"
            child.environment = environment
            try child.run()
            let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            child.waitUntilExit()
            return (said.split(whereSeparator: \.isNewline).last.map(String.init) ?? "", said)
        }

        func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        func mode(_ url: URL) throws -> Int {
            try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
        }
        func exists(_ url: URL) -> Bool { (try? url.checkResourceIsReachable()) ?? false }
        /// The commands that ran, by their names and arguments, with the test's folder cut from each path.
        var ran: [String] {
            (text(folder.appendingPathComponent("ran")) ?? "").split(whereSeparator: \.isNewline)
                .map { $0.replacingOccurrences(of: root.path, with: "") }
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    @Test func aServerWithNoSwapAndNoLimitGetsBothAndASecondRunChangesNothing() throws {
        for shell in Self.shells {
            let server = try Root()
            defer { server.remove() }
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: server.table.path)
            let first = try server.run(shell)
            #expect(first.last == "\(ServerMemory.mark) swap=made-4G limit=set", "\(shell): \(first.output)")
            #expect(first.output.hasPrefix("\n\(ServerMemory.started)\n"))
            #expect(server.ran == ["fallocate -l 4294967296 /swapfile", "mkswap -q /swapfile", "swapon /swapfile",
                                   "sysctl -q -p /etc/sysctl.d/60-fleet-swap.conf", "systemctl daemon-reload"])
            #expect(try server.mode(server.swapFile) == 0o600, "for root only, from before it has any size")
            #expect(server.text(server.table) == Root.tableText + ServerMemory.swapLine + "\n")
            #expect(try server.mode(server.table) == 0o640, "the table keeps its mode")
            #expect(server.text(server.sysctl) == ServerMemory.swapSysctlText)
            #expect(server.text(server.limitFile) == ServerMemory.limitText)
            #expect(try server.mode(server.limitFile) == 0o644)
            #expect(try FileManager.default.contentsOfDirectory(atPath: server.table.deletingLastPathComponent().path)
                .sorted() == ["fstab", "sysctl.d", "systemd"], "no file of the program's own stays behind")
            let second = try server.run(shell)
            #expect(second.last == "\(ServerMemory.mark) swap=held limit=set")
            #expect(server.ran.suffix(1) == ["systemctl daemon-reload"] && server.ran.count == 6)
            #expect(server.text(server.table) == Root.tableText + ServerMemory.swapLine + "\n")
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: server.limitFile.deletingLastPathComponent().path) == ["00-fleet-memory.conf"])
        }
    }

    @Test func theSwapFileIsTheMemoryInWholeGibAndFourAtMost() throws {
        for (kb, gib) in [(954_000, 1), (1_048_576, 1), (1_048_577, 2), (16_311_184, 4)] {
            let server = try Root()
            defer { server.remove() }
            try server.put(server.root.appendingPathComponent("proc/meminfo"), "MemTotal:       \(kb) kB\n")
            #expect(try server.run("/bin/dash").last == "\(ServerMemory.mark) swap=made-\(gib)G limit=set")
            #expect(server.ran.first == "fallocate -l \(gib * 1_073_741_824) /swapfile")
        }
    }

    @Test func aServerKeepsTheSwapThatItHasOrNames() throws {
        for shell in Self.shells {
            for (word, change) in [
                ("held", { (s: Root) in try s.put(s.swaps, Root.head + "/dev/sda2  partition\t2097148\t0\t-2\n") }),
                ("named", { s in try s.put(s.table, Root.tableText + "# /old none swap sw 0 0\nUUID=1a2b none swap sw 0 0\n") }),
                ("file-there", { s in try s.put(s.swapFile, "") }),
                ("file-there", { s in try FileManager.default.createSymbolicLink(atPath: s.swapFile.path, withDestinationPath: "/nowhere") }),
                ("unread", { s in try FileManager.default.removeItem(at: s.swaps) }),
                ("no-table", { s in try FileManager.default.removeItem(at: s.table) }),
                ("no-memory", { s in try s.put(s.root.appendingPathComponent("proc/meminfo"), "") }),
                ("no-system", { s in try s.put(s.folder.appendingPathComponent("fs"), "btrfs\n") }),
                ("no-space", { s in try s.put(s.folder.appendingPathComponent("free-kb"), "\(8 * 1_048_576)\n") }),
            ] as [(String, (Root) throws -> Void)] {
                let server = try Root()
                defer { server.remove() }
                try change(server)
                let table = server.text(server.table)
                #expect(try server.run(shell).last == "\(ServerMemory.mark) swap=\(word) limit=set", "\(shell) \(word)")
                #expect(server.ran == ["systemctl daemon-reload"], "\(word): no command of the swap file ran")
                #expect(server.text(server.table) == table)
                #expect(!server.exists(server.sysctl))
            }
            // A comment in the table is no line of it.
            let server = try Root()
            defer { server.remove() }
            try server.put(server.table, Root.tableText + "# /swapfile none swap sw 0 0\n")
            #expect(try server.run(shell).last == "\(ServerMemory.mark) swap=made-4G limit=set")
        }
    }

    @Test func aStepThatFailsTakesTheFileAwayAndLeavesTheTable() throws {
        for shell in Self.shells {
            for step in ["fallocate", "mkswap", "swapon"] {
                let server = try Root()
                defer { server.remove() }
                try server.mark("\(step)-fails")
                let run = try server.run(shell)
                #expect(run.last == "\(ServerMemory.mark) swap=failed limit=set", "\(shell) \(step)")
                #expect(run.output.contains("\(step): it failed: Operation not permitted"), "the command's own words")
                #expect(!server.exists(server.swapFile))
                #expect(server.text(server.table) == Root.tableText)
                #expect(!server.exists(server.sysctl))
                #expect(server.ran.contains("swapoff /swapfile"))
                #expect(ServerMemory.outcome(run.output) == .holds, "the limit alone settles the server")
            }
        }
    }

    /// A table that cannot be replaced after the swap is on, and a stop of the program between the file's making
    /// and the table's line: the swap and the file go away again, the table is as it was, and no file of the
    /// program's own stays beside it. A table with no last line end gets one before the swap line.
    @Test func aTableThatCannotBeWrittenAndAStopInTheMiddleTakeTheSwapAway() throws {
        for shell in Self.shells {
            let fixed = try Root()
            defer { fixed.remove() }
            try fixed.mark("table-stays")
            let run = try fixed.run(shell)
            #expect(run.last == "\(ServerMemory.mark) swap=no-table limit=set", "\(shell): \(run.output)")
            #expect(fixed.ran.suffix(3) == ["swapon /swapfile", "swapoff /swapfile", "systemctl daemon-reload"])
            #expect(!fixed.exists(fixed.swapFile) && fixed.text(fixed.table) == Root.tableText)
            #expect(fixed.text(fixed.swaps) == Root.head && !fixed.exists(fixed.sysctl))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixed.table.deletingLastPathComponent().path)
                .sorted() == ["fstab", "systemd"])

            for step in ["fallocate", "mkswap", "swapon"] {
                let stopped = try Root()
                defer { stopped.remove() }
                try stopped.mark("\(step)-stops")
                let cut = try stopped.run(shell)
                #expect(!cut.output.contains(ServerMemory.mark + " "), "\(shell) \(step): the program ended there")
                #expect(stopped.ran.last == "swapoff /swapfile", "\(shell) \(step): \(stopped.ran)")
                #expect(!stopped.exists(stopped.swapFile) && stopped.text(stopped.table) == Root.tableText)
                guard case .failed = ServerMemory.outcome(cut.output) else { Issue.record("\(cut.output)"); continue }
            }

            // A stop just after the table's line is written, and one later, while systemd reads its files again:
            // the swap is whole, so the file and its line both stay. A cleanup there would leave a line for a file
            // that is gone, and no later run would make swap again.
            for late in ["table-then-stops", "reload-stops"] {
                let whole = try Root()
                defer { whole.remove() }
                try whole.mark(late)
                let cut = try whole.run(shell)
                #expect(!cut.output.contains(ServerMemory.mark + " "), "\(shell) \(late): the program ended there")
                #expect(whole.exists(whole.swapFile), "\(shell) \(late)")
                #expect(whole.text(whole.table) == Root.tableText + ServerMemory.swapLine + "\n")
                #expect(!whole.ran.contains("swapoff /swapfile") && whole.text(whole.swaps)?.contains("/swapfile") == true)
            }

            let open = try Root()
            defer { open.remove() }
            try open.put(open.table, String(Root.tableText.dropLast()))
            #expect(try open.run(shell).last == "\(ServerMemory.mark) swap=made-4G limit=set")
            #expect(open.text(open.table) == Root.tableText + ServerMemory.swapLine + "\n")
        }
    }

    @Test func aLimitOfTheServersOwnStaysAndASystemWithNoGroupGetsNoFile() throws {
        for shell in Self.shells {
            let own = try Root()
            defer { own.remove() }
            try own.put(own.kernelLimit, "3221225472\n")
            #expect(try own.run(shell).last == "\(ServerMemory.mark) swap=made-4G limit=own")
            #expect(!own.exists(own.limitFile) && !own.ran.contains("systemctl daemon-reload"))

            let none = try Root()
            defer { none.remove() }
            try FileManager.default.removeItem(at: none.kernelLimit)
            let run = try none.run(shell)
            #expect(run.last == "\(ServerMemory.mark) swap=made-4G limit=no-group")
            #expect(!none.exists(none.limitFile.deletingLastPathComponent()))
            #expect(ServerMemory.outcome(run.output) == .leftAsItIs)

            let deaf = try Root()
            defer { deaf.remove() }
            try deaf.mark("systemd-deaf")
            let said = try deaf.run(shell)
            #expect(said.last == "\(ServerMemory.mark) swap=made-4G limit=not-yet")
            #expect(deaf.text(deaf.limitFile) == ServerMemory.limitText, "systemd takes the file at the next start")
            guard case .failed = ServerMemory.outcome(said.output) else { Issue.record("\(said.output)"); continue }
        }
    }

    /// The owner wrote a limit and did not make systemd read it yet, so the kernel still says none: this program's
    /// file would win by its name. And a limit that `systemctl set-property` wrote, in the place that systemd reads
    /// first. With such a file nothing is written, and the log has the file's name.
    @Test func aFileOfTheServersOwnThatSetsALimitDecidesAlsoBeforeSystemdReadIt() throws {
        for shell in Self.shells {
            // The last two: a file for every slice, which this program's file would win over whatever its name, and
            // the limit's old name.
            for (place, line) in [("etc/systemd/system/user.slice.d/10-site.conf", "  MemoryMax = 3G"),
                                  ("etc/systemd/system.control/user.slice.d/50-MemoryMax.conf", "MemoryMax=infinity"),
                                  ("usr/lib/systemd/system/user.slice", "MemoryMax=3G"),
                                  ("etc/systemd/system/slice.d/10-all.conf", "MemoryMax=2G"),
                                  ("run/systemd/system/user.slice.d/20-old.conf", "MemoryLimit=2G")] {
                let server = try Root()
                defer { server.remove() }
                let own = server.root.appendingPathComponent(place)
                try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
                try server.put(own, "[Slice]\n\(line)\n")
                let run = try server.run(shell)
                #expect(run.last == "\(ServerMemory.mark) swap=made-4G limit=own", "\(shell) \(place): \(run.output)")
                #expect(run.output.contains("this server's own setting of the memory limit: /\(place)\n"))
                #expect(!server.exists(server.limitFile) && !server.ran.contains("systemctl daemon-reload"))
                #expect(ServerMemory.outcome(run.output) == .holds)
            }
            // A file that sets another thing of the slice, a comment, and a file whose name starts with a dot (systemd
            // does not read one) are no limit. The folder that is there keeps its mode.
            let server = try Root()
            defer { server.remove() }
            let other = server.root.appendingPathComponent("etc/systemd/system/user.slice.d/10-site.conf")
            try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: other.deletingLastPathComponent().path)
            try server.put(other, "[Slice]\n# MemoryMax=1G\nMemoryHigh=2G\nTasksMax=4096\n")
            try server.put(other.deletingLastPathComponent().appendingPathComponent(".hidden.conf"), "[Slice]\nMemoryMax=1G\n")
            #expect(try server.run(shell).last == "\(ServerMemory.mark) swap=made-4G limit=set")
            #expect(server.text(server.limitFile) == ServerMemory.limitText)
            #expect(try server.mode(other.deletingLastPathComponent()) == 0o750)
        }
    }

    @Test func aFileOfAnEarlierTextIsWrittenAgain() throws {
        let server = try Root()
        defer { server.remove() }
        try FileManager.default.createDirectory(at: server.limitFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try server.put(server.limitFile, "[Slice]\nMemoryMax=80%\n")
        try server.put(server.kernelLimit, "3270000000\n")
        #expect(try server.run("/bin/dash").last == "\(ServerMemory.mark) swap=made-4G limit=set")
        #expect(server.text(server.limitFile) == ServerMemory.limitText)
    }

    @Test func onAServerTheProgramWritesTheJoinsOwnPaths() {
        let program = ServerMemory.program()
        #expect(program.contains("\nr=''; w=; l=; p=\"$r/proc/swaps\"; t=\"$r/etc/fstab\"; f=\"$r/swapfile\"; "
                                 + "y=\"$r/etc/sysctl.d/60-fleet-swap.conf\"\n"))
        #expect(program.contains("c=\"$r/sys/fs/cgroup/user.slice/memory.max\"; d=\"$r/etc/systemd/system/user.slice.d\"; "
                                 + "x=\"$r/etc/systemd/system/user.slice.d/00-fleet-memory.conf\""))
        #expect(program.hasPrefix("printf '\\n%s\\n' \(ServerMemory.started) || exit 1\n"))
        #expect(!program.contains("/home/"), "root runs no code that the service's user can change")
    }

    /// The files' texts, their places and the two sizes are the join's own (`hubsetup.py`), where this repository has
    /// it: the public copy of the apps does not.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: ServerHardeningTests.hubsetup.path)))
    func theFilesAndTheirTextsAreTheJoinsOwn() throws {
        let source = try String(contentsOf: ServerHardeningTests.hubsetup, encoding: .utf8)
        func text(_ name: String) throws -> String {
            let block = try #require(source.range(of: name + #" = \((?:\s*"(?:[^"\\]|\\.)*")+\)"#, options: .regularExpression))
            let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#), found = String(source[block])
            return literal.matches(in: found, range: NSRange(found.startIndex..., in: found)).map {
                String(found[Range($0.range(at: 1), in: found)!])
            }.joined().replacingOccurrences(of: "\\n", with: "\n")
        }
        #expect(try text("SWAP_SYSCTL_TEXT") == ServerMemory.swapSysctlText)
        #expect(try text("MEMORY_TEXT") == ServerMemory.limitText)
        for line in ["SWAP_FILE = \"\(ServerMemory.swapFile)\"", "SWAP_LINE = SWAP_FILE + \" none swap sw 0 0\"",
                     "FSTAB = \"\(ServerMemory.table)\"", "SWAP_SYSCTL = \"\(ServerMemory.swapSysctl)\"",
                     "MEMORY_DIR = \"\(ServerMemory.limitFolder)\"", "MEMORY_LIMIT = MEMORY_DIR + \"/00-fleet-memory.conf\"",
                     "SWAP_MOST = \(ServerMemory.swapMost) << 30", "SWAP_SPARE = \(ServerMemory.swapSpare) << 30",
                     "SWAP_SYSTEMS = (\"ext2/ext3\", \"ext4\")"] {
            #expect(source.contains(line), "\(line)")
        }
        let places = try #require(source.range(of: #"MEMORY_PLACES = \([^)]*\)"#, options: .regularExpression))
        let quoted = try NSRegularExpression(pattern: #""([^"]*)""#), listed = String(source[places])
        #expect(quoted.matches(in: listed, range: NSRange(listed.startIndex..., in: listed)).map {
            String(listed[Range($0.range(at: 1), in: listed)!])
        } == ServerMemory.limitPlaces)
        let lifecycle = try String(contentsOf: ServerHardeningTests.hubsetup.deletingLastPathComponent()
            .appendingPathComponent("lifecycle.py"), encoding: .utf8)
        #expect(lifecycle.contains("USER_SLICE_MAX = \"\(ServerMemory.kernelLimit)\""))
    }
}
