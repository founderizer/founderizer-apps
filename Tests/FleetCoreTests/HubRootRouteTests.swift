import Foundation
import Testing
@testable import FleetCore

/// **The root route to the hub's own server** (`HubRootRoute`; the owner, 25 November 2026, about a test fleet whose
/// central vault was never installed: "we need to resolve it"). The app's own tests hold where the route runs (only the
/// hub's Linux machine, only after the Tailscale check) and what it keeps; these hold the tries themselves.
struct HubRootRouteTests {
    private static let appLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExampleEx founderizer@mac"
    private static let refused = LocalShell.Answer(status: 255, output: "root@100.80.1.2: Permission denied (publickey).\r\n")
    private static let root = LocalShell.Answer(status: 0, output: "founderizer-root=0\n")
    private static let placed = LocalShell.Answer(status: 0, output: "founderizer-root=0\nfounderizer-app-key-in-place\n")

    /// What `ssh` was asked, in order, and the owner access key's file as it was during its call.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [[String]] = []
        private var file: (text: String, mode: Int, folderMode: Int)?
        private let appKey: String
        init(appKey: String) { self.appKey = appKey }
        var all: [[String]] { lock.withLock { made } }
        var keyFile: (text: String, mode: Int, folderMode: Int)? { lock.withLock { file } }
        /// Notes one call, and gives how many came before it.
        func note(_ arguments: [String]) -> Int {
            var seen: (text: String, mode: Int, folderMode: Int)?
            if let at = arguments.firstIndex(of: "-i"), arguments[at + 1] != appKey {
                let path = arguments[at + 1]
                func mode(_ path: String) -> Int {
                    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1
                }
                seen = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "", mode(path),
                        mode((path as NSString).deletingLastPathComponent))
            }
            return lock.withLock {
                made.append(arguments)
                if let seen { file = seen }
                return made.count - 1
            }
        }
        /// A stand-in `ssh` that answers `answers` in their order, the last one again.
        func run(_ answers: [LocalShell.Answer]) -> ShellRunner {
            { _, arguments, _, _ in answers[min(self.note(arguments), answers.count - 1)] }
        }
    }

    /// A folder of the test's own, with a stand-in of this Mac's own key file in it.
    private static func folder() throws -> (base: URL, appKey: String) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("root-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let appKey = base.appendingPathComponent("founderizer_ed25519").path
        try "stand-in\n".write(toFile: appKey, atomically: true, encoding: .utf8)
        return (base, appKey)
    }

    /// The owner access key's folders that `base` holds.
    private static func keyFolders(_ base: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.hasPrefix("founderizer-key-") }
    }

    private static func target(_ appKey: String) throws -> InstallTarget {
        try #require(HubRootRoute.target(record: MachineReach(address: "100.80.1.2"), appKey: appKey))
    }

    /// **The probe logs in as root with one key alone and only with a host key that this Mac knows already**, at the
    /// record's address and port, 22 where it names none (`HubRootRoute.target`, `arguments`). Bugs: the probe takes a new
    /// host key (`accept-new`), so at the hub's own port a program of the hub's user answers as root and its key is kept
    /// for every strict step after it; the probe offers the keys of the owner's agent or configuration, which the server
    /// counts against its `MaxAuthTries`; it logs in as the record's `fleet`, whose `authorized_keys` decides the answer;
    /// at the node's own address it reads the key under that address, which the owner's `ssh` never met, or the words
    /// send the owner to the wrong `ssh-keygen -R` line; at the record's port the words give a command that keeps a hub
    /// user's key of another type under the node's name.
    @Test func theProbeIsRootWithOneKeyAloneAndAKnownHostKey() throws {
        let appKey = "/Users/owner/.ssh/founderizer_ed25519"
        let plain = try #require(HubRootRoute.target(record: MachineReach(address: "100.80.1.2", user: "fleet"), appKey: appKey))
        #expect(plain == InstallTarget(host: "100.80.1.2", user: "root", port: 22, identityFile: appKey))
        let args = HubRootRoute.arguments(plain, keyFile: appKey, program: HubRootRoute.probe)
        #expect(args.starts(with: ["-F", "/dev/null"]) && args.contains("StrictHostKeyChecking=yes")
                && args.contains("BatchMode=yes") && args.contains("IdentitiesOnly=yes"))
        #expect(!args.contains(where: { $0.contains("accept-new") }))
        let identity = try #require(args.firstIndex(of: "-i"))
        #expect(args.filter { $0 == "-i" }.count == 1 && args[identity + 1] == appKey)
        #expect(Array(args.suffix(4)) == ["-p", "22", "root@100.80.1.2", HubRootRoute.probe])
        // a port of the record: the key of the host's port 22, never a new one
        let high = try #require(HubRootRoute.target(record: MachineReach(address: "100.80.1.2", user: "fleet", port: 2222),
                                                    appKey: appKey))
        let highArgs = HubRootRoute.arguments(high, keyFile: appKey, program: HubRootRoute.probe)
        #expect(highArgs.contains("HostKeyAlias=100.80.1.2") && highArgs.contains("2222"))
        #expect(HubRootRoute.target(record: MachineReach(address: nil, user: "root", port: 22), appKey: appKey) == nil)
        // at the node's own address, the key under the record's own form of it (`hostKeyName`), at any port; the words
        // of an unknown or a changed key name that form
        let name = "hub-box.tail1234.ts.net"
        for port in [22, 2222] {
            let named = InstallTarget(host: "100.80.1.2", port: port, identityFile: appKey, hostKeyName: name)
            let namedArgs = HubRootRoute.arguments(named, keyFile: appKey, program: HubRootRoute.probe)
            #expect(namedArgs.contains("HostKeyAlias=\(name)") && namedArgs.contains("StrictHostKeyChecking=yes")
                    && !namedArgs.contains("HostKeyAlias=100.80.1.2") && namedArgs.contains("root@100.80.1.2"), "\(port)")
        }
        let named = InstallTarget(host: "100.80.1.2", identityFile: appKey, hostKeyName: name)
        #expect(HubRootRoute.unknownHostKey("hub-box", target: named).contains("run ssh root@100.80.1.2 once"))
        #expect(named.refusedHostKey(in: ["@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@",
                                          "Host key verification failed."], server: "hub-box")
                == ServerCheck.hostKeyChanged(name))
        // at another port the name's own line too: no words of the port, and a command that writes that line
        let high2222 = InstallTarget(host: "100.80.1.2", port: 2222, identityFile: appKey, hostKeyName: name)
        #expect(high2222.refusedHostKey(in: ["@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@",
                                             "Host key verification failed."], server: "hub-box")
                == ServerCheck.hostKeyChanged(name))
        // a key of another type at the record's port, where a hub user can listen (the Door area's read of 25 November
        // 2026): the owner's step of the port, never a command at that port that would keep that key under the name
        let otherType = LocalShell.Answer(status: 255, output: "No ECDSA host key is known for \(name) and you have requested "
                                          + "strict checking.\r\nHost key verification failed.\r\n")
        let words = HubRootRoute.stop(otherType, target: high2222, machine: "hub-box")
        #expect(words == InstallTarget.typeItsPort("hub-box") && words?.contains("-p") == false)
    }

    /// **The route goes to the node's own Tailscale address, with the node's system** (`HubRootRoute.node`), for an
    /// address, a whole name or a first label that one node has, and to no node where two have that label; it reads the
    /// host key under the address's line, else the whole name's. Bugs: the route connects to a first label, which `ssh`
    /// looks up through DNS on another machine; it reads a first label's line, which can belong to another machine.
    @Test func theRouteGoesToTheNodesOwnAddress() async throws {
        let status = #"""
        {"Self": {"DNSName": "owner-mac.tail1234.ts.net.", "TailscaleIPs": ["100.70.0.1"], "OS": "macOS"},
         "Peer": {"a": {"ID": "n1", "DNSName": "hub-box.tail1234.ts.net.", "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.80.1.2"],
                        "OS": "linux"},
                  "b": {"ID": "n2", "DNSName": "twin.tail1234.ts.net.", "TailscaleIPs": ["100.80.1.7"], "OS": "linux"},
                  "c": {"ID": "n3", "DNSName": "twin.example.ts.net.", "TailscaleIPs": ["100.80.1.8"], "OS": "linux"}}}
        """#
        for host in ["hub-box", "hub-box.tail1234.ts.net", "100.80.1.2"] {
            let node = HubRootRoute.node(of: host, in: status)
            #expect(node?.address == "100.80.1.2" && node?.os == "linux" && node?.id == "id:n1"
                    && node?.name == "hub-box.tail1234.ts.net", "\(host)")
        }
        #expect(HubRootRoute.node(of: "twin", in: status) == nil)
        #expect(HubRootRoute.node(of: "100.80.1.8", in: status)?.address == "100.80.1.8")
        // the host key's line: the address's, else the whole name's, never a first label's (`hostKeyName`)
        let node = try #require(HubRootRoute.node(of: "hub-box", in: status))
        #expect(await HubRootRoute.hostKeyName(of: node, known: { ["100.80.1.2", "hub-box.tail1234.ts.net"].contains($0) }) == nil)
        #expect(await HubRootRoute.hostKeyName(of: node, known: { $0 == "hub-box.tail1234.ts.net" }) == "hub-box.tail1234.ts.net")
        #expect(await HubRootRoute.hostKeyName(of: node, known: { $0 == "hub-box" }) == nil)
    }

    /// **The owner access key goes only after root refused this Mac's own key, alone, from a file of mode 600 in a folder
    /// of mode 700 that is gone after the call, and the connection counts only once this Mac's own key gets in after it**
    /// (`HubRootRoute.reach`, `withKeyFile`). A folder that a crash left goes before the next one. Bugs: the fleet's owner
    /// access key goes first, or where this Mac's key works; its file stays on the disk, or others can read it; a
    /// leftover of a crash keeps the key in the temporary folder for good; the Mac keeps a connection that root refuses.
    @Test func theOwnerAccessKeyGoesOnlyAfterARefusalFromAFileThatGoes() async throws {
        let (base, appKey) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = try #require(OwnerAccessKey(seed: Data(repeating: 7, count: 32)))
        let target = try Self.target(appKey)
        // a crash's folder goes at the route's next run, another call's young folder stays
        let stale = base.appendingPathComponent("founderizer-key-stale"), young = base.appendingPathComponent("founderizer-key-young")
        for folder in [stale, young] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: stale.path)
        // root takes this Mac's own key: one call, and the owner access key is not even read
        let works = Calls(appKey: appKey)
        let first = await HubRootRoute.reach(target, machine: "hub-box", appKey: appKey, appLine: Self.appLine,
                                             ownerAccess: { Issue.record("read"); return key }, run: works.run([Self.root]),
                                             folder: base)
        #expect(first == .root(byOwnerAccess: false) && works.all.count == 1)
        #expect(Self.keyFolders(base) == ["founderizer-key-young"], "the crash's folder is gone")
        // root refuses it: the owner access key, from its own file, with the line of this Mac's key, then this Mac's key
        let calls = Calls(appKey: appKey)
        let second = await HubRootRoute.reach(target, machine: "hub-box", appKey: appKey, appLine: Self.appLine,
                                              ownerAccess: { key }, run: calls.run([Self.refused, Self.placed, Self.root]),
                                              folder: base)
        #expect(second == .root(byOwnerAccess: true) && calls.all.count == 3)
        let file = try #require(calls.keyFile)
        #expect(file.text == key.privateFile && file.mode == 0o600 && file.folderMode == 0o700)
        let program = try #require(calls.all.dropLast().last?.last)
        #expect(program.hasPrefix(HubRootRoute.probe + "; ") && program.contains(Self.appLine)
                && program.contains(OwnerAccess.rootKeys))
        #expect(calls.all.last?.contains(appKey) == true, "this Mac's own key once more")
        #expect(Self.keyFolders(base) == ["founderizer-key-young"], "the key's folder and the crash's are gone")
    }

    /// **Nothing counts as root unless root printed root's id and, after the owner access key, this Mac's own key got
    /// in; and the key's folder goes on each of those ends, and when the call throws.** Bugs: a session that printed
    /// another user's id counts as root; an owner access session whose write did not happen, or a server that still
    /// refuses this Mac's key after it, leaves a kept connection that root refuses, which the route never tries again;
    /// the key's file stays after a failure.
    @Test func theRouteKeepsNothingUnlessThisMacsKeyGetsIn() async throws {
        let (base, appKey) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = try #require(OwnerAccessKey(seed: Data(repeating: 7, count: 32)))
        let target = try Self.target(appKey)
        let noRoot = "The root login on hub-box gave no answer that Founderizer can read."
        let other = LocalShell.Answer(status: 0, output: "founderizer-root=1000\n")
        let still = "The root user of hub-box still refuses this Mac's key, which is now in /root/.ssh/authorized_keys there. "
            + "Make sure that its SSH server reads that file and lets root log in with a key, then try again."
        let cases: [([LocalShell.Answer], HubRootRoute.Outcome, Int)] = [
            ([other], .stopped(noRoot), 1),                                   // another user's id
            ([Self.refused, Self.root], .stopped(noRoot), 2),                 // root, and no line in place
            ([Self.refused, Self.placed, Self.refused], .stopped(still), 3),   // this Mac's key refused after it
            ([Self.refused, Self.refused], .refused, 2)]                      // both keys refused
        for (answers, outcome, count) in cases {
            let calls = Calls(appKey: appKey)
            let got = await HubRootRoute.reach(target, machine: "hub-box", appKey: appKey, appLine: Self.appLine,
                                               ownerAccess: { key }, run: calls.run(answers), folder: base)
            #expect(got == outcome && calls.all.count == count, "\(answers.map(\.output))")
            #expect(Self.keyFolders(base).isEmpty)
        }
        struct Thrown: Error {}
        await #expect(throws: Thrown.self) {
            try await HubRootRoute.withKeyFile(key.privateFile, in: base) { _ -> Int in throw Thrown() }
        }
        #expect(Self.keyFolders(base).isEmpty)
    }

    /// **A refused host key, no answer or a missing key file offers no other key, and each stop has its own words**
    /// (`HubRootRoute.stop`, `call`). Bugs: after a host key that this Mac does not know, the fleet's owner access key goes
    /// to that host too, and the words give no command to meet the key; a timeout reads as a refused key, so the owner
    /// adds a key that was never the cause; with no key file `ssh` offers `~/.ssh/id_*` in its place (`IdentitiesOnly`
    /// notwithstanding); root that refuses both keys ends with no words of the owner's step.
    @Test func aRefusedHostKeyOrNoAnswerOffersNoSecondKey() async throws {
        let (base, appKey) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = try #require(OwnerAccessKey(seed: Data(repeating: 7, count: 32)))
        let target = try Self.target(appKey)
        let unknown = LocalShell.Answer(status: 255, output: "No ED25519 host key is known for 100.80.1.2.\r\nHost key verification failed.\r\n")
        let timeout = LocalShell.Answer(status: 255, output: "ssh: connect to host 100.80.1.2 port 22: Operation timed out\r\n")
        let unknownWords = HubRootRoute.unknownHostKey("hub-box", target: target)
        #expect(unknownWords.contains("run ssh root@100.80.1.2 once"))
        for (answer, words) in [(unknown, unknownWords),
                                (timeout, ServerCheck.unreached("hub-box", said: timeout.output.lowercased()))] {
            let calls = Calls(appKey: appKey)
            let outcome = await HubRootRoute.reach(target, machine: "hub-box", appKey: appKey, appLine: Self.appLine,
                                                   ownerAccess: { key }, run: calls.run([answer]), folder: base)
            #expect(outcome == .stopped(words) && calls.all.count == 1)
        }
        let both = Calls(appKey: appKey)
        #expect(await HubRootRoute.reach(target, machine: "hub-box", appKey: appKey, appLine: Self.appLine, ownerAccess: { key },
                                         run: both.run([Self.refused]), folder: base) == .refused && both.all.count == 2)
        #expect(await HubRootRoute.reach(target, machine: "hub-box", appKey: appKey, appLine: Self.appLine, ownerAccess: { nil },
                                         run: both.run([Self.refused]), folder: base) == .refused)
        // no key file: no call at all
        let none = Calls(appKey: appKey)
        let missing = await HubRootRoute.reach(target, machine: "hub-box", appKey: appKey, appLine: Self.appLine,
                                               ownerAccess: { key }, run: none.run([Self.root]), folder: base,
                                               exists: { _ in false })
        #expect(missing == .stopped("This Mac's key file \(appKey) is not there, so Founderizer tried no login.")
                && none.all.isEmpty)
    }

    /// **A step whose login the server refused says so** (`HubRootRoute.refusedLogin`; the tester's report of 25
    /// November 2026): for root with this Mac's own key, or where the root route runs at the next try, the owner's step,
    /// with `ssh-copy-id` first and the exact address at port 22 only; for another connection, the refusal and its user.
    /// Bugs: the refusal reads as "could not read the install's answer", and the owner, who holds the key that root
    /// takes, has no idea why; the words send the owner's own `ssh-copy-id`, and a password, to the record's port, where
    /// a hub user can listen.
    @Test func aRefusedLoginSaysSoAndTheStepForRoot() {
        let appKey = "/Users/owner/.ssh/founderizer_ed25519"
        let root = InstallTarget(host: "100.80.1.2", identityFile: appKey)
        let step = HubRootRoute.refused("hub-box", target: root)
        #expect(HubRootRoute.refusedLogin(Self.refused, target: root, server: "hub-box", appKey: appKey) == step)
        #expect(step.contains("ssh-copy-id -i ~/.ssh/founderizer_ed25519.pub root@100.80.1.2")
                && step.contains("/root/.ssh/authorized_keys") && step.contains("PermitRootLogin"))
        #expect(HubRootRoute.refused("hub-box", target: InstallTarget(host: "100.80.1.2", port: 2222))
                    .contains("ssh-copy-id") == false)
        // root with the owner's own keys: the step where the route runs at the next try, else the refusal
        let owners = InstallTarget(host: "100.80.1.2")
        #expect(HubRootRoute.refusedLogin(Self.refused, target: owners, server: "hub-box", appKey: appKey, routed: true)
                == HubRootRoute.refused("hub-box", target: owners))
        #expect(HubRootRoute.refusedLogin(Self.refused, target: owners, server: "hub-box", appKey: appKey)
                == "hub-box refused the SSH login of this Mac as root.")
        let admin = InstallTarget(host: "100.80.1.2", user: "admin", becomeRoot: true)
        #expect(HubRootRoute.refusedLogin(Self.refused, target: admin, server: "hub-box", appKey: appKey, routed: true)
                == "hub-box refused the SSH login of this Mac as admin.")
        // a host key and no answer are not refused logins: they have their own words
        let unknown = LocalShell.Answer(status: 255, output: "Host key verification failed.\r\n")
        #expect(HubRootRoute.refusedLogin(unknown, target: root, server: "hub-box", appKey: appKey) == nil)
        #expect(HubRootRoute.refusedLogin(Self.root, target: root, server: "hub-box", appKey: appKey) == nil)
    }
}
