import Foundation
import Testing
@testable import FleetCore

/// A server that stops restarts by itself, put right by the owner's Mac (`ServerRestart`): what a round reads, how a
/// run's output reads, and what the program does on a server. The program runs here in this Mac's `/bin/sh` and in
/// dash, the `/bin/sh` of Debian and Ubuntu, under a folder that stands for the server's root, with stand-ins for the
/// commands that need root or Linux. Each stand-in leaves what the real command leaves, as systemd 259 does it, which
/// opens the device at fewer moments than systemd 255: sysctl takes the file's value; modprobe loads softdog, a device
/// that nothing holds yet; enabling the unit makes its link, and reloads systemd unless it says
/// --no-reload; and once the join's drop-in is there, systemd tries to open the device at each reload, at most once in
/// five seconds of the test's clock, which only `sleep` moves.
struct ServerRestartTests {
    static let time: Double = 1_000_000
    static let shells = ["/bin/sh", "/bin/dash"]

    // MARK: what a round reads

    private func server(restarts: Bool?, hub: Bool = false) throws -> ServerEntry {
        // The memory limit holds on each: the round reads the restart's own fact, and no other.
        var security: [String: Any] = ["firewall": "active", "ssh_keys_only": true, "npm_rule": true, "memory_guard": true]
        if let restarts { security["restart_guard"] = restarts }
        var entry: [String: Any] = ["name": hub ? "hub" : "app-1", "hub": hub, "joined": !hub, "agents": [],
                                    "address": "100.80.1.7", "available": true, "why": []]
        if hub {
            var own: [String: Any] = ["ssh_keys_only": true, "npm_rule": true, "memory_guard": true,
                                      "at": Self.time - 60, "claimed_at": Self.time - 7200]
            if let restarts { own["restart_guard"] = restarts }
            entry["hardening"] = own
        } else {
            entry["kind"] = "linux"
            entry["reading"] = ["source": "server", "os": ["name": "Ubuntu 24.04"], "runtimes": [:],
                                "reported_at": Self.time - 60, "stale": false, "security": security] as [String: Any]
        }
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    @Test func aServerThatDoesNotRestartIsTheFaultAndNoFactSaysNothing() throws {
        for hub in [false, true] {
            #expect(ServerRestart.reading(of: try server(restarts: false, hub: hub), join: nil, at: Self.time) == .faulty)
            #expect(ServerRestart.reading(of: try server(restarts: true, hub: hub), join: nil, at: Self.time) == .holds)
            // A helper or a hub from before owner API 1.229, and a kernel that does not say what it does after a panic.
            #expect(ServerRestart.reading(of: try server(restarts: nil, hub: hub), join: nil, at: Self.time) == .unread)
        }
    }

    // MARK: how a run's output reads

    @Test func bothPartsDecideWhatARunCameTo() {
        let begun = "\n\(ServerRestart.started)\n", mark = ServerRestart.mark
        for panic in ["set", "held", "own"] {
            for watchdog in ["set", "held", "own"] {
                #expect(ServerRestart.outcome(begun + "\(mark) panic=\(panic) watchdog=\(watchdog)\n") == .holds)
            }
        }
        #expect(ServerRestart.outcome(begun + "\(mark) panic=unread watchdog=set\n") == .leftAsItIs)
        #expect(ServerRestart.outcome(begun + "\(mark) panic=set watchdog=no-systemd\n") == .leftAsItIs)
        #expect(ServerRestart.outcome(begun + "\(mark) panic=container watchdog=container\n") == .leftAsItIs)
        #expect(ServerRestart.outcome(begun + "Failed to connect to bus\n\(mark) panic=set watchdog=not-yet\n")
                == .failed("panic set, watchdog not-yet: Failed to connect to bus"))
        #expect(ServerRestart.outcome(begun + "\(mark) panic=not-written watchdog=\n")
                == .failed("panic not-written, watchdog ?"))
        #expect(ServerRestart.outcome(begun + "Connection closed.\n")
                == .failed("the program started and did not end: Connection closed."))
        guard case .notStarted = ServerRestart.outcome("sudo: a password is required\n") else {
            Issue.record("an ssh that started nothing reads as a run"); return
        }
        // No sweep's first line or last line is another's: the memory limit's run settles nothing here.
        #expect(Set([ServerRestart.started, ServerMemory.started, ServerHardening.started]).count == 3)
        #expect(ServerRestart.outcome(begun + "\(ServerMemory.mark) swap=held limit=set\n")
                == .failed("the program started and did not end: \(ServerMemory.mark) swap=held limit=set"))
    }

    // MARK: the program on a server

    /// A server's root under a new folder, as Ubuntu 24.04 at Hetzner has it: the kernel waits forever after a panic,
    /// there is no watchdog device, systemd runs the system, and its own file names the watchdog in a comment only.
    private struct Root {
        let folder: URL
        var root: URL { folder.appendingPathComponent("root") }
        var bin: URL { folder.appendingPathComponent("bin") }
        var panic: URL { root.appendingPathComponent("proc/sys/kernel/panic") }
        var device: URL { root.appendingPathComponent("sys/class/watchdog/watchdog0") }
        func at(_ path: String) -> URL { root.appendingPathComponent(String(path.dropFirst())) }

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("restart-" + UUID().uuidString)
            for made in ["root/proc/sys/kernel", "root/sys/class/watchdog", "root/run/systemd/system", "root/etc/sysctl.d",
                         "root/etc/systemd", "bin"] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(made),
                                                        withIntermediateDirectories: true)
            }
            try put(panic, "0\n")
            try put(at("/etc/systemd/system.conf"), "[Manager]\n#RuntimeWatchdogSec=off\n#RebootWatchdogSec=10min\n")
            let here = folder.path, r = root.path, device = device.path, unit = ServerRestart.unitName
            let wants = r + ServerRestart.wantsLink, wanted = (wants as NSString).deletingLastPathComponent
            // Each stand-in fails where a file `<name>-fails` is there (`systemctl` by its verb); no softdog loads
            // where `no-softdog` is there, and systemd opens no device where `no-open` is there. `clock` and `tried`
            // hold the test's clock and systemd's last try, in seconds.
            try stand("sysctl", """
                echo "sysctl $*" >> '\(here)/ran'
                [ -e '\(here)/sysctl-fails' ] && exit 255
                [ "$3" = '\(r)\(ServerRestart.panicFile)' ] && echo 10 > '\(r)\(ServerRestart.kernelPanic)'
                exit 0
                """)
            try stand("modprobe", """
                echo "modprobe $*" >> '\(here)/ran'
                if [ -e '\(here)/no-softdog' ]; then
                  echo "modprobe: FATAL: Module softdog not found in directory /lib/modules/6.8.0-149-generic" >&2; exit 1
                fi
                mkdir -p '\(device)'; [ -e '\(device)/state' ] || echo inactive > '\(device)/state'
                exit 0
                """)
            try stand("sleep", """
                echo "sleep $*" >> '\(here)/ran'
                echo $(( $(cat '\(here)/clock' 2>/dev/null || echo 0) + $1 )) > '\(here)/clock'
                exit 0
                """)
            try stand("systemctl", """
                echo "systemctl $*" >> '\(here)/ran'
                [ -e "\(here)/$1-fails" ] && { echo "Failed to $1 unit: Access denied" >&2; exit 1; }
                if [ "$*" = 'enable \(unit)' ] || [ "$*" = 'enable --no-reload \(unit)' ]; then
                  mkdir -p '\(wanted)'; [ -L '\(wants)' ] || ln -s '\(ServerRestart.unitFile)' '\(wants)'
                fi
                if { [ "$1" = daemon-reload ] || [ "$*" = 'enable \(unit)' ]; } && [ ! -e '\(here)/no-open' ] \\
                    && [ -e '\(r)\(ServerRestart.confFile)' ]; then
                  now=$(cat '\(here)/clock' 2>/dev/null || echo 0); last=$(cat '\(here)/tried' 2>/dev/null)
                  if [ -z "$last" ] || [ $((now - last)) -ge 5 ]; then
                    echo "$now" > '\(here)/tried'; [ -d '\(device)' ] && echo active > '\(device)/state'
                  fi
                fi
                exit 0
                """)
        }

        func put(_ url: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        func link(_ path: String) throws {
            try FileManager.default.createDirectory(at: at(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: at(path).path, withDestinationPath: "/dev/null")
        }
        func drop(_ path: String) throws { try FileManager.default.removeItem(at: at(path)) }
        func mark(_ name: String) throws { try Data().write(to: folder.appendingPathComponent(name)) }
        func unmark(_ name: String) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        private func stand(_ name: String, _ text: String) throws {
            let path = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + text + "\n").write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        /// The program in one shell, with the stand-ins first in its PATH: its last line, and all that it said.
        func run(_ shell: String = "/bin/dash") throws -> (last: String, output: String) {
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: shell)
            child.arguments = ["-c", ServerRestart.program(root: root.path)]
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
        func names(_ path: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: at(path).path)) ?? []).sorted() }
        /// The commands that ran, by their names and arguments, with the test's folder cut from each path.
        var ran: [String] {
            (text(folder.appendingPathComponent("ran")) ?? "").split(whereSeparator: \.isNewline)
                .map { $0.replacingOccurrences(of: root.path, with: "") }
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    @Test func aServerThatStopsGetsBothRestartsAndASecondRunChangesNothing() throws {
        for shell in Self.shells {
            let server = try Root()
            defer { server.remove() }
            let first = try server.run(shell)
            #expect(first.last == "\(ServerRestart.mark) panic=set watchdog=set", "\(shell): \(first.output)")
            #expect(first.output.hasPrefix("\n\(ServerRestart.started)\n"))
            // the link with no reload, then softdog, then the reload that reads the drop-in and opens the device then:
            // no wait on a new server
            #expect(server.ran == ["sysctl -q -p /etc/sysctl.d/60-fleet-restart.conf",
                                   "systemctl enable --no-reload fleet-watchdog.service", "modprobe softdog",
                                   "systemctl daemon-reload"])
            for (path, text) in [(ServerRestart.panicFile, ServerRestart.panicText),
                                 (ServerRestart.unitFile, ServerRestart.unitText),
                                 (ServerRestart.confFile, ServerRestart.confText)] {
                #expect(server.text(server.at(path)) == text, "\(shell): \(path)")
                #expect(try server.mode(server.at(path)) == 0o644, "\(shell): \(path)")
            }
            let second = try server.run(shell)
            #expect(second.last == "\(ServerRestart.mark) panic=held watchdog=held", "\(shell): \(second.output)")
            #expect(server.ran.count == 4, "a second run runs nothing")
            // A unit that is not enabled loads no softdog at the next start, though systemd holds the device now.
            try server.drop(ServerRestart.wantsLink)
            let third = try server.run(shell)
            #expect(third.last == "\(ServerRestart.mark) panic=held watchdog=set", "\(shell): \(third.output)")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: server.at(ServerRestart.wantsLink).path))
                    == ServerRestart.unitFile)
            // No file of the program's own stays behind, on the first run's way or on the second's.
            #expect(server.names("/etc/sysctl.d") == ["60-fleet-restart.conf"])
            #expect(server.names("/etc/systemd/system") == ["fleet-watchdog.service", "sysinit.target.wants"])
            #expect(server.names("/etc/systemd/system.conf.d") == ["00-fleet-watchdog.conf"])
        }
    }

    /// A sysctl file that sets kernel.panic (in a vendor's folder, or /etc/sysctl.conf), systemd's own file or a
    /// drop-in that sets RuntimeWatchdogSec, and a link at one of the join's files (a mask): each part writes and runs
    /// nothing, and the log names the place. A comment is no setting, a key that only starts with kernel.panic is
    /// another key, and a vendor's file is not read where /etc has a file of its name.
    @Test func aServerKeepsItsOwnFiles() throws {
        let server = try Root()
        defer { server.remove() }
        try server.put(server.at("/etc/sysctl.d/99-local.conf"), "kernel.panic_on_oops = 1\n# kernel.panic = 0\n")
        try server.put(server.at("/usr/lib/sysctl.d/50-kdump.conf"), "kernel.panic = 0\n")
        try server.put(server.at("/etc/sysctl.d/50-kdump.conf"), "# masks the vendor's file\n")
        try server.put(server.at("/etc/systemd/system.conf.d/90-own.conf"), "[Manager]\nRuntimeWatchdogSec=30s\n")
        var said = try server.run()
        #expect(said.last == "\(ServerRestart.mark) panic=set watchdog=own", "\(said.output)")
        #expect(said.output.contains("this server's own setting of the watchdog: /etc/systemd/system.conf.d/90-own.conf\n"))
        for path in ["/etc/sysctl.d/50-kdump.conf", ServerRestart.panicFile, "/etc/systemd/system.conf.d/90-own.conf"] {
            try server.drop(path)
        }
        try server.put(server.panic, "0\n")
        try server.put(server.at("/etc/systemd/system.conf"), "[Manager]\nRuntimeWatchdogSec=off\n")
        said = try server.run()
        #expect(said.last == "\(ServerRestart.mark) panic=own watchdog=own", "\(said.output)")
        #expect(said.output.contains("this server's own setting of kernel.panic: /usr/lib/sysctl.d/50-kdump.conf\n"))
        #expect(said.output.contains("this server's own setting of the watchdog: /etc/systemd/system.conf\n"))
        try server.drop("/usr/lib/sysctl.d/50-kdump.conf")
        try server.put(server.at("/etc/sysctl.conf"), "kernel.panic=0\n")
        try server.put(server.at("/etc/systemd/system.conf"), "[Manager]\n")
        try server.link(ServerRestart.unitFile)
        said = try server.run()
        #expect(said.last == "\(ServerRestart.mark) panic=own watchdog=own", "\(said.output)")
        #expect(said.output.contains("this server's own setting of kernel.panic: /etc/sysctl.conf\n"))
        #expect(said.output.contains("this server's own setting of the watchdog: a link at a file of this step's\n"))
        try server.drop("/etc/sysctl.conf")
        try server.link(ServerRestart.panicFile)
        said = try server.run()
        #expect(said.last == "\(ServerRestart.mark) panic=own watchdog=own", "\(said.output)")
        #expect(server.ran == ["sysctl -q -p /etc/sysctl.d/60-fleet-restart.conf"], "only the first run's panic part")
        #expect(server.names("/etc/sysctl.d") == ["60-fleet-restart.conf", "99-local.conf"], "the link stays")
        #expect(server.names("/etc/systemd/system.conf.d").isEmpty)
    }

    /// A kernel that restarts after a panic with no file of the join's (a boot parameter), the watchdog program, a
    /// watchdog that is active with no drop-in of the join's, and a container, which its host restarts: nothing is
    /// written and nothing runs.
    @Test func aServerKeepsItsOwnState() throws {
        let server = try Root()
        defer { server.remove() }
        try server.put(server.panic, "30\n")
        try server.put(server.at(ServerRestart.daemonFile), "watchdog-device = /dev/watchdog\n")
        #expect(try server.run().last == "\(ServerRestart.mark) panic=own watchdog=own")
        try server.drop(ServerRestart.daemonFile)
        try server.put(server.device.appendingPathComponent("state"), "active\n")
        #expect(try server.run().last == "\(ServerRestart.mark) panic=own watchdog=own")
        try server.put(server.at("/run/systemd/container"), "lxc\n")
        try server.put(server.panic, "0\n")
        #expect(try server.run().last == "\(ServerRestart.mark) panic=container watchdog=container")
        #expect(server.ran.isEmpty)
        #expect(server.names("/etc/sysctl.d").isEmpty && server.names("/etc/systemd/system").isEmpty)
    }

    /// A command that fails stops its part, and the server's reading then says that it does not restart by itself, so
    /// that a later round runs again: softdog that does not load, an enable that fails (before softdog loads, so that no
    /// device stays that no start would load again), a reload that fails, and a device that systemd does not open.
    /// Where the drop-in was in force before softdog loaded, systemd may have tried the device in the five seconds
    /// before, and the run has systemd read its files once more `ServerRestart.retry` seconds later.
    @Test func aPartThatIsNotInForceSaysSoAndTheNextRunPutsItInForce() throws {
        let server = try Root()
        defer { server.remove() }
        let enable = "systemctl enable --no-reload fleet-watchdog.service"
        var device: Bool { FileManager.default.fileExists(atPath: server.device.path) }
        try server.mark("sysctl-fails")
        try server.mark("no-softdog")
        var said = try server.run()
        #expect(said.last == "\(ServerRestart.mark) panic=not-yet watchdog=not-yet")
        #expect(said.output.contains("modprobe: FATAL: Module softdog not found"), "\(said.output)")
        #expect(server.ran.last == "modprobe softdog", "nothing of systemd's runs")
        server.unmark("sysctl-fails")
        server.unmark("no-softdog")
        try server.mark("enable-fails")
        said = try server.run()
        #expect(said.last == "\(ServerRestart.mark) panic=set watchdog=not-yet")
        #expect(said.output.contains("Failed to enable unit: Access denied\n"), "\(said.output)")
        #expect(server.ran.last == enable && !device, "no softdog, so the reading asks again")
        server.unmark("enable-fails")
        try server.mark("daemon-reload-fails")
        said = try server.run()
        #expect(said.last == "\(ServerRestart.mark) panic=held watchdog=not-yet")
        #expect(said.output.contains("Failed to daemon-reload unit: Access denied\n"), "\(said.output)")
        server.unmark("daemon-reload-fails")
        try server.mark("no-open")
        said = try server.run()
        #expect(said.last == "\(ServerRestart.mark) panic=held watchdog=not-yet")
        #expect(said.output.contains("systemd opened no watchdog device\n"), "\(said.output)")
        server.unmark("no-open")
        var before = server.ran.count
        #expect(try server.run().last == "\(ServerRestart.mark) panic=held watchdog=set")
        #expect(Array(server.ran.dropFirst(before)) == [enable, "modprobe softdog", "systemctl daemon-reload"])
        // A boot that loaded no softdog, and systemd tried the device a moment before this run.
        try FileManager.default.removeItem(at: server.device)
        try (server.text(server.folder.appendingPathComponent("clock")) ?? "0\n")
            .write(to: server.folder.appendingPathComponent("tried"), atomically: true, encoding: .utf8)
        before = server.ran.count
        said = try server.run()
        #expect(said.last == "\(ServerRestart.mark) panic=held watchdog=set", "\(said.output)")
        #expect(Array(server.ran.dropFirst(before)) == [
            enable, "modprobe softdog", "systemctl daemon-reload", "sleep \(ServerRestart.retry)",
            "systemctl daemon-reload"])
    }

    @Test func nothingRunsBeforeTheProgramsFirstLine() {
        #expect(ServerRestart.program().hasPrefix("printf '\\n%s\\n' \(ServerRestart.started) || exit 1\n"))
    }

    /// The files' texts, their places and the kernel's files are the join's own (`hubsetup.py`, `lifecycle.py`),
    /// where this repository has them: the public copy of the apps does not.
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
        func list(_ name: String, in text: String) throws -> [String] {
            let block = try #require(text.range(of: name + #" = \([^)]*\)"#, options: .regularExpression))
            let quoted = try NSRegularExpression(pattern: #""([^"]*)""#), found = String(text[block])
            return quoted.matches(in: found, range: NSRange(found.startIndex..., in: found)).map {
                String(found[Range($0.range(at: 1), in: found)!])
            }
        }
        #expect(try text("RESTART_PANIC_TEXT") == ServerRestart.panicText)
        #expect(try text("RESTART_UNIT_TEXT") == ServerRestart.unitText)
        #expect(try text("RESTART_CONF_TEXT") == ServerRestart.confText)
        #expect(try list("SYSCTL_SOURCES", in: source) == ServerRestart.sysctlPlaces)
        #expect(try list("RESTART_CONF_PLACES", in: source) == ServerRestart.confPlaces)
        for line in ["RESTART_PANIC_FILE = \"\(ServerRestart.panicFile)\"", "RESTART_UNIT_NAME = \"\(ServerRestart.unitName)\"",
                     "RESTART_UNIT = \"/etc/systemd/system/\" + RESTART_UNIT_NAME",
                     "RESTART_CONF_DIR = \"/etc/systemd/system.conf.d\"", "RESTART_CONF = RESTART_CONF_DIR + \"/00-fleet-watchdog.conf\"",
                     "SYSCTL_CONF = \"\(ServerRestart.sysctlFile)\"", "RESTART_PANIC_KEY = \"kernel.panic\"",
                     "RESTART_DAEMON = \"\(ServerRestart.daemonFile)\"",
                     "RESTART_WANTS = \"/etc/systemd/system/sysinit.target.wants/\" + RESTART_UNIT_NAME",
                     "RESTART_LOAD = \"\(ServerRestart.load)\"", "RESTART_RETRY = \(ServerRestart.retry)\n"] {
            #expect(source.contains(line), "\(line)")
        }
        let lifecycle = try String(contentsOf: ServerHardeningTests.hubsetup.deletingLastPathComponent()
            .appendingPathComponent("lifecycle.py"), encoding: .utf8)
        #expect(lifecycle.contains("PANIC_SECONDS = \"\(ServerRestart.kernelPanic)\""))
        #expect(lifecycle.contains("WATCHDOG_DEVICES = \"\(ServerRestart.watchdogs)\""))
        #expect(try list("CONTAINER_MARKS", in: lifecycle) == ServerRestart.containerMarks)
    }
}
