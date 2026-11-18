import Foundation
import Testing
@testable import FleetCore

/// The system packages of the fleet's pinned tools, put in place by the owner's Mac (`ServerLibraries`): which servers
/// a round runs the program on, what the program does on a server, and how its output reads. The program runs here
/// in this Mac's `/bin/sh` and in dash, the `/bin/sh` of Debian and Ubuntu, with stand-ins for `dpkg`, `dpkg-query`,
/// `apt-get` and `sleep`: the stand-in of `apt-get install` puts each package that it names among the installed
/// ones, for the server's own architecture (amd64), as the real one does, and records what each call of `apt-get`
/// asked for. The stand-in of `flock` locks the descriptor that it is given, as the real one does.
struct ServerLibrariesTests {
    static let time: Double = 1_000_000
    static let shells = ["/bin/sh", "/bin/dash"]

    // MARK: what a round reads

    private func server(hub: Bool = false, kind: String = "linux", job: String? = nil, source: String = "server",
                        reportedAt: Double = time - 60, claimed: Double = time - 7200) throws -> ServerEntry {
        var entry: [String: Any] = ["name": hub ? "hub" : "app-1", "hub": hub, "joined": !hub, "agents": [],
                                    "address": "100.80.1.7", "available": true, "why": []]
        if hub {
            entry["hardening"] = ["ssh_keys_only": true, "npm_rule": true, "at": reportedAt, "claimed_at": claimed]
        } else {
            entry["kind"] = kind
            entry["reading"] = ["source": source, "os": ["name": "Ubuntu 24.04"], "runtimes": [:],
                                "reported_at": reportedAt, "stale": false,
                                "security": ["firewall": "active", "tailscale": true]] as [String: Any]
        }
        if let job {
            entry["job"] = ["id": 4, "kind": "install", "agent": "dev-lead", "state": job, "created": Self.time - 100,
                            "updated": Self.time - 50] as [String: Any]
        }
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    private func read(_ server: ServerEntry, join: JoinState? = nil) -> ServerHardening.Reading {
        ServerLibraries.reading(of: server, join: join, at: Self.time)
    }

    /// No reading says whether the packages are there, so each server of the sweep with a current reading of its
    /// own is the program's to read: a Linux server that joined, and the hub's own server by the hub's own reading.
    /// Never a Mac, an old reading, a reading of an agent's helper, an open job of the server's service, or the hour
    /// after the server's join or the hub's claim, when the join or the hub's install still runs apt itself.
    @Test func theProgramRunsOnEachServerOfTheSweepWithACurrentReadingOnly() throws {
        #expect(read(try server()) == .faulty)
        #expect(read(try server(hub: true)) == .faulty)
        #expect(read(try server(kind: "mac")) == .unread)
        #expect(read(try server(reportedAt: Self.time - 3600)) == .unread)
        #expect(read(try server(hub: true, reportedAt: Self.time - 3600)) == .unread)
        #expect(read(try server(source: "agent")) == .unread)
        #expect(read(try server(job: "running")) == .unread)
        #expect(read(try server(hub: true, claimed: Self.time - 600)) == .unread)
        let joined = try JSONDecoder().decode(JoinState.self, from: JSONSerialization.data(withJSONObject: [
            "name": "", "kind": "linux", "created": Self.time - 600, "expires_at": Self.time + 3000, "state": "joined",
            "server": "app-1"] as [String: Any]))
        #expect(read(try server(), join: joined) == .unread)
    }

    // MARK: how a run's output reads

    @Test func packagesInPlaceSettleTheServerAndAllElseIsTriedAgain() {
        let begun = "\n\(ServerLibraries.started)\n"
        #expect(ServerLibraries.outcome(begun + "\(ServerLibraries.mark) packages=held\n") == .holds)
        #expect(ServerLibraries.outcome(begun + "installed: libatomic1\n\(ServerLibraries.mark) packages=installed\n")
                == .holds)
        #expect(ServerLibraries.outcome(begun + "\(ServerLibraries.mark) packages=no-apt\n") == .leftAsItIs)
        #expect(ServerLibraries.outcome(begun + "E: Unable to fetch some archives\n\(ServerLibraries.mark) packages=failed\n")
                == .failed("packages failed: E: Unable to fetch some archives"))
        #expect(ServerLibraries.outcome(begun + "\(ServerLibraries.mark) packages=busy\n") == .failed("packages busy"))
        #expect(ServerLibraries.outcome(begun + "\(ServerLibraries.mark) packages=\n") == .failed("packages ?"))
        #expect(ServerLibraries.outcome(begun + "Connection closed.\n")
                == .failed("the program started and did not end: Connection closed."))
        guard case .notStarted = ServerLibraries.outcome("sudo: a password is required\n") else {
            Issue.record("an ssh that started nothing reads as a run"); return
        }
        // The first line is no last line, and the program's own text, which a refusal can echo, is no first line.
        #expect(!ServerLibraries.started.hasPrefix(ServerLibraries.mark + " "))
        guard case .notStarted = ServerLibraries.outcome("refused:\n" + ServerLibraries.program()) else {
            Issue.record("the program's own text reads as its first line"); return
        }
    }

    // MARK: the program on a server

    /// A server under a new folder: the stand-ins, the folder of the program's lock, and the file `installed` of the
    /// packages that dpkg has, one line each: the package, its architecture, and "hold" for one on hold. By default
    /// it has none. With a file `update-fails` each update of apt's lists fails, with `install-fails` the install
    /// fails, and with `install-hangs-up` the install hangs up the program's whole process group, as the end of a
    /// terminal does, and sends PIPE to its shell, before it installs (`run(_:ownGroup:)`).
    private struct Server {
        let folder: URL
        var bin: URL { folder.appendingPathComponent("bin") }
        var root: URL { folder.appendingPathComponent("root") }

        init(installed: String = "") throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("libraries-" + UUID().uuidString)
            for made in [bin, root.appendingPathComponent("run")] {
                try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            }
            try installed.write(to: folder.appendingPathComponent("installed"), atomically: true, encoding: .utf8)
            let here = folder.path
            // It answers each instance of the package in the form that it is asked for: with its architecture, or
            // `${db:Status-Status}` alone, or the old `${Status}`.
            try stand("dpkg-query", """
                for a; do case "$a" in -f=*) f=$a ;; esac; p=$a; done
                grep -q "^$p " '\(here)/installed' || { echo "dpkg-query: no packages found matching $p" >&2; exit 1; }
                grep "^$p " '\(here)/installed' | while read -r n arch hold; do
                  case "$f" in
                    *Architecture*) printf '%s installed\\n' "$arch" ;;
                    *db:Status-Status*) printf 'installed' ;;
                    *) if [ "$hold" = hold ]; then printf 'hold ok installed'; else printf 'install ok installed'; fi ;;
                  esac
                done
                """)
            try stand("dpkg", "[ \"$1\" = --print-architecture ] && echo amd64")
            try stand("apt-get", """
                s=; n=; lock=no; recommends=yes; removals=yes; options=0; y=no
                for a; do
                  case "$a" in
                    DPkg::Lock::Timeout=*) lock=yes ;;
                    Dpkg::Options::=--force-confdef|Dpkg::Options::=--force-confold) options=$((options + 1)) ;;
                    --no-install-recommends) recommends=no ;;
                    --no-remove) removals=no ;;
                    -y) y=yes ;;
                    -*|*::*) ;;
                    update|install) s=$a ;;
                    *) n="$n $a" ;;
                  esac
                done
                q=yes; [ "$DEBIAN_FRONTEND" = noninteractive ] && { [ $s = update ] || { [ $y = yes ] && [ $options = 2 ]; }; } && q=no
                r=yes; [ "$NEEDRESTART_MODE" = l ] && r=no
                if [ $s = update ]; then
                  echo "update questions=$q lock=$lock" >> '\(here)/ran'
                  [ ! -e '\(here)/update-fails' ] || { echo 'E: Failed to fetch InRelease' >&2; exit 100; }
                  exit 0
                fi
                echo "install$n questions=$q lock=$lock recommends=$recommends removals=$removals restarts=$r" >> '\(here)/ran'
                [ ! -e '\(here)/install-fails' ] || { echo 'E: Unable to fetch some archives'; echo 'E: Sub-process failed' >&2; exit 100; }
                [ ! -e '\(here)/install-hangs-up' ] || { g=$(cat '\(here)/pid'); kill -HUP -- "-$g"; kill -PIPE "$g"; }
                for p in $n; do echo "$p amd64" >> '\(here)/installed'; done
                echo '0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.'
                """)
            try stand("flock", """
                exec /usr/bin/perl -MFcntl=:flock -e 'my ($n, $fd) = @ARGV; $n eq "-n" or exit 64;
                  open(my $h, "<&=", $fd) or exit 65; flock($h, LOCK_EX | LOCK_NB) or exit 1; exit 0' -- "$@"
                """)
            try stand("sleep", ":")
        }

        func mark(_ name: String) throws { try Data().write(to: folder.appendingPathComponent(name)) }
        private func stand(_ name: String, _ text: String) throws {
            let path = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + text + "\n").write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        /// The program in one shell, with the stand-ins first in its PATH (`standIns: false`, with none: a server
        /// with no apt): its last line, and all that it said. The shell's process id goes into `pid`; with `ownGroup`,
        /// the shell leads a process group of its own, so that a hang-up of that group reaches no process of the test.
        func run(_ shell: String, standIns: Bool = true,
                 ownGroup: Bool = false) throws -> (last: String, output: String) {
            let child = Process(), output = Pipe(), pid = folder.appendingPathComponent("pid").path
            let program = ServerLibraries.program(root: root.path)
            if ownGroup {
                child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                child.arguments = ["-e", "setpgrp(0, 0); open(my $f, '>', shift) or die; print $f $$; close $f; "
                                   + "exec @ARGV or die", pid, shell, "-c", program]
            } else {
                // The shell writes its own process id into `pid` and then becomes the shell that runs the program.
                child.executableURL = URL(fileURLWithPath: "/bin/sh")
                child.arguments = ["-c", "echo $$ > '\(pid)'; exec \"$0\" -c \"$1\"", shell, program]
            }
            child.standardOutput = output
            child.standardError = output
            child.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = (standIns ? bin.path + ":" : "") + "/usr/bin:/bin"
            environment["DEBIAN_FRONTEND"] = nil
            environment["NEEDRESTART_MODE"] = nil
            child.environment = environment
            try child.run()
            let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            child.waitUntilExit()
            return (said.split(whereSeparator: \.isNewline).last.map(String.init) ?? "", said)
        }

        /// What each call of `apt-get` asked for.
        var ran: [String] { lines("ran") }
        var installed: [String] { lines("installed") }
        var lock: String { root.path + ServerLibraries.lock }
        private func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).map(String.init)
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    /// An update and an install with no question, that wait for apt's lock, and an install of the missing packages
    /// only, with no recommended package, no removal and no restart of a service.
    static let update = "update questions=no lock=yes"
    static let install = "install libatomic1 questions=no lock=yes recommends=no removals=no restarts=no"

    @Test func aServerWithoutThePackagesGetsThemAndASecondRunChangesNothing() throws {
        for shell in Self.shells {
            let server = try Server()
            defer { server.remove() }
            // A lock file that is there already, with a mode for every user.
            FileManager.default.createFile(atPath: server.lock, contents: nil, attributes: [.posixPermissions: 0o644])
            let first = try server.run(shell)
            #expect(first.last == "\(ServerLibraries.mark) packages=installed", "\(shell): \(first.output)")
            #expect(first.output.hasPrefix("\n\(ServerLibraries.started)\n"))
            #expect(first.output.contains("\ninstalled: libatomic1\n"))
            #expect(server.ran == [Self.update, Self.install], "\(shell)")
            #expect(server.installed == ServerLibraries.packages.map { $0 + " amd64" })
            let mode = try FileManager.default.attributesOfItem(atPath: server.lock)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600, "no other user of the server can open the lock, and so none can hold it")
            let second = try server.run(shell)
            #expect(second.last == "\(ServerLibraries.mark) packages=held")
            #expect(server.ran.count == 2, "a server with its packages gets no apt at all")
        }
    }

    @Test func aPackageOnHoldIsThere() throws {
        for shell in Self.shells {
            let server = try Server(installed: "libatomic1 amd64 hold\n")
            defer { server.remove() }
            #expect(try server.run(shell).last == "\(ServerLibraries.mark) packages=held", "\(shell)")
            #expect(server.ran.isEmpty)
        }
    }

    /// The pinned tools are of the server's own architecture, and so must their libraries be.
    @Test func aPackageOfAnotherArchitectureAloneIsNotThere() throws {
        for shell in Self.shells {
            let server = try Server(installed: "libatomic1 i386\n")
            defer { server.remove() }
            #expect(try server.run(shell).last == "\(ServerLibraries.mark) packages=installed", "\(shell)")
            #expect(server.ran == [Self.update, Self.install])
        }
    }

    @Test func listsThatCannotBeUpdatedAreTriedThreeTimesAndTheInstallStillRuns() throws {
        for shell in Self.shells {
            let server = try Server()
            defer { server.remove() }
            try server.mark("update-fails")
            #expect(try server.run(shell).last == "\(ServerLibraries.mark) packages=installed")
            #expect(server.ran == [Self.update, Self.update, Self.update, Self.install], "\(shell)")
        }
    }

    @Test func anInstallThatFailsSaysAptsLastWordsAndSettlesNothing() throws {
        for shell in Self.shells {
            let server = try Server()
            defer { server.remove() }
            try server.mark("install-fails")
            let run = try server.run(shell)
            #expect(run.last == "\(ServerLibraries.mark) packages=failed", "\(shell): \(run.output)")
            #expect(ServerLibraries.outcome(run.output)
                    == .failed("packages failed: E: Unable to fetch some archives E: Sub-process failed"))
            #expect(server.installed.isEmpty)
        }
    }

    /// A run that comes while an earlier one still works on the server (this Mac stopped waiting for it) installs
    /// nothing beside it.
    @Test func aRunWhileAnEarlierOneStillWorksInstallsNothing() throws {
        for shell in Self.shells {
            let server = try Server()
            defer { server.remove() }
            let earlier = open(server.lock, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
            try #require(earlier >= 0)
            #expect(flock(earlier, LOCK_EX) == 0)
            #expect(try server.run(shell).last == "\(ServerLibraries.mark) packages=busy", "\(shell)")
            #expect(server.ran.isEmpty)
            flock(earlier, LOCK_UN)
            close(earlier)
            #expect(try server.run(shell).last == "\(ServerLibraries.mark) packages=installed", "\(shell)")
        }
    }

    /// The end of the connection, a stop of this Mac's `ssh` included, must not stop dpkg halfway through an install.
    @Test func theEndOfTheConnectionDoesNotStopAnInstall() throws {
        for shell in Self.shells {
            let server = try Server()
            defer { server.remove() }
            try server.mark("install-hangs-up")
            let run = try server.run(shell, ownGroup: true)
            #expect(run.last == "\(ServerLibraries.mark) packages=installed", "\(shell): \(run.output)")
            #expect(server.installed == ServerLibraries.packages.map { $0 + " amd64" })
        }
    }

    @Test func aServerWithNoAptIsLeftAsItIs() throws {
        for shell in Self.shells {
            let server = try Server()
            defer { server.remove() }
            #expect(try server.run(shell, standIns: false).last == "\(ServerLibraries.mark) packages=no-apt")
            #expect(server.ran.isEmpty)
        }
    }
}
