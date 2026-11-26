#if os(macOS)
import Foundation

/// **The root route to the hub's own server, for a Mac that keeps no connection to it** (the owner, 25 November 2026,
/// about a test fleet whose central vault was never installed: "we need to resolve it"; the owner's rule of 24 October
/// 2026: "this should be automatically setup, even under the hood if we dont need anything!").
///
/// A Mac keeps a connection to a server only from its own install (`InstallTargets`), so a Mac that did not install the
/// hub, a hub that moved, and a Mac that lost its defaults keep none. The fleet's record of the hub's server names the
/// hub's own user, `fleet` (`hub.sh`), which no root step takes (M1 of the validation of 23 November 2026), or root,
/// whose connection offers the owner's own keys, not this Mac's (the tester's report of 25 November 2026: root held
/// this Mac's key and refused each try). Then the central vault's root steps try root itself, whatever user the record
/// names, at the Tailscale address of the node that the record's address is (`node`), with the host key that this Mac
/// knows for that node: its address's line of `known_hosts`, else the line of its whole name in this Mac's own
/// Tailscale (`hostKeyName`), never the record's string or a first label, at the record's port (22 where it names
/// none), with one harmless probe that prints root's user id and changes nothing:
///
/// 1. **This Mac's own key alone** (`AppSSHKey`), in app mode (`SSHCall`: `-F /dev/null`, `IdentitiesOnly`,
///    `BatchMode`), with the strict host key rule of every vault step (`InstallTarget.hostKeyOptions(strict: true)`):
///    the key that this Mac knows for that host already, at another port than 22 the one of its port 22, and never a
///    new one.
/// 2. **Only when root refused that key** (a refused host key, or no answer, opens nothing more): **the fleet's owner
///    access key** (`OwnerAccessKey`) from this Mac's keychain, alone, with the same host key rule, from a file of mode
///    600 in a folder of mode 700 of its own that goes when the call ends (`withKeyFile`). The same session puts the
///    line of this Mac's own key into root's `authorized_keys` (`OwnerAccess.install(line:)`), which is what the owner
///    access key is for (a Mac that is new to the fleet gives each server its own key). Then **this Mac's own key alone
///    again**, so that the connection that the Mac keeps is one that root takes with its own key, and no file of the
///    owner access key outlives the call.
///
/// Each call goes only where its key file is there right before it: `ssh` 10.3 drops a missing `-i` file and offers
/// `~/.ssh/id_*` instead, `IdentitiesOnly` notwithstanding (the Door area's measure of 25 November 2026).
///
/// The caller runs it only for the hub's own machine, only after this Mac's own Tailscale named the address and this
/// Mac's hub address as one node (`CentralVaultRemote.hubMachineStop`) and gave that node's system as Linux (root's
/// keys in `/root` are Linux's, and on a Mac each user can listen at port 22), and keeps the connection when root
/// answered.
public enum HubRootRoute {
    /// The probe: root's user id, in a line that only a session of root prints (`answersAsRoot`).
    static let probe = "echo founderizer-root=$(id -u)"
    static let rootMark = "founderizer-root=0"
    /// What the owner access key's session prints once the line of this Mac's own key is in root's file.
    static let appKeyInPlace = "founderizer-app-key-in-place"
    /// The start of the name of the owner access key's folder for one call (`withKeyFile`).
    static let keyFolderPrefix = "founderizer-key-"

    /// How the route ended.
    public enum Outcome: Equatable, Sendable {
        /// Root answered this Mac's own key alone: at once, or (`byOwnerAccess`) after the owner access key's session put
        /// that key into root's keys.
        case root(byOwnerAccess: Bool)
        /// Root refused each key that the route offered.
        case refused
        /// Nothing answered as root, in these words.
        case stopped(String)
    }

    /// **The route's connection**: root at the record's address and port, or port 22 where the record names none or
    /// one that is no port, with this Mac's own key; nil for a record with no address, or with one that is none.
    public static func target(record: MachineReach?, appKey: String) -> InstallTarget? {
        guard let address = record?.address, !address.isEmpty else { return nil }
        let port = record?.port.flatMap { (1...65535).contains($0) ? $0 : nil } ?? 22
        let target = InstallTarget(host: address, user: "root", port: port, identityFile: appKey)
        return target.isValid ? target : nil
    }

    /// One node of this Mac's Tailscale: its ID (or whole name), its whole MagicDNS name, its own address and its system.
    public struct Node: Equatable, Sendable {
        public let id: String
        public let name: String
        public let address: String
        public let os: String?
    }

    /// **The one node of this Mac's Tailscale that a host is** (as `MacNetwork.node(of:in:)` matches it: an address, the
    /// whole name, or a first label that one node has), with its whole name, its own Tailscale address (IPv4 first) and
    /// its system (`OS`). The route connects to that address, never to a name that `ssh` would look up elsewhere.
    public static func node(of host: String, in json: String) -> Node? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let wanted = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let peers = (object["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        let found = ([object["Self"] as? [String: Any]].compactMap { $0 } + peers).compactMap { node -> Node? in
            let full = ((node["DNSName"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let name = full.split(separator: ".").first.map(String.init), !name.isEmpty else { return nil }
            let addresses = ((node["TailscaleIPs"] as? [String]) ?? []).map { $0.lowercased() }
            guard addresses.contains(wanted) || wanted == full || wanted == name,
                  let address = addresses.first(where: { $0.contains(".") }) ?? addresses.first else { return nil }
            let id = (node["ID"] as? String).flatMap { $0.isEmpty ? nil : "id:" + $0 } ?? "name:" + full
            return Node(id: id, name: full, address: address, os: node["OS"] as? String)
        }
        return found.count == 1 ? found.first : nil
    }

    /// **The line of `known_hosts` that the route reads for a node** (the Door area's read of 25 November 2026): the line
    /// of its own address when this Mac's `known_hosts` has one (nil: no other name); else the line of its whole name in
    /// this Mac's own Tailscale, when there is one; else its address, whose words then give `ssh root@<address>`. Never
    /// the hub record's string and never a first label: the record is the hub's word, and a short label's line can belong
    /// to another machine. `known`: whether `known_hosts` has a line for a host (`ssh-keygen -F`).
    public static func hostKeyName(of node: Node, known: (String) async -> Bool) async -> String? {
        if await known(node.address) { return nil }
        return await known(node.name) ? node.name : nil
    }

    /// Whether this Mac's own `known_hosts` has a line for `host`: `ssh-keygen -F`, which reads hashed lines too.
    public static func knownHost(_ host: String) async -> Bool {
        (try? await Shell.local("/usr/bin/ssh-keygen", ["-F", host], nil, 20))?.ok == true
    }

    /// The arguments of one try: app mode with `keyFile` alone, as root, with the strict host key rule and the
    /// install's timeout of a connection.
    public static func arguments(_ target: InstallTarget, keyFile: String, program: String) -> [String] {
        SSHCall(host: target.host, user: "root", port: target.port,
                options: target.hostKeyOptions(strict: true) + ["-o", "ConnectTimeout=20"],
                shape: .command(program)).arguments(.file(keyFile))
    }

    /// Whether a session answered as root: it ended well and printed root's user id.
    static func answersAsRoot(_ answer: LocalShell.Answer) -> Bool {
        answer.ok && answer.lines.contains(rootMark)
    }

    /// **The tries of the route** (the type's own words): `appKey` is the path of this Mac's own key file and `appLine`
    /// its public line; `ownerAccess` gives the fleet's owner access key that this Mac's keychain holds, or nil, and is
    /// asked only after root refused this Mac's own key. `run`, `folder` (where the owner access key's folder goes) and
    /// `exists` (whether a key file is there): a test's.
    public static func reach(_ target: InstallTarget, machine: String, appKey: String, appLine: String,
                             ownerAccess: @Sendable () -> OwnerAccessKey?, run: ShellRunner = Shell.local,
                             folder: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) async -> Outcome {
        removeStaleKeyFolders(in: folder)
        let missing = String(l10n: "This Mac's key file \(appKey) is not there, so Founderizer tried no login.")
        guard let first = await call(target, keyFile: appKey, program: probe, run: run, exists: exists) else {
            return .stopped(missing)
        }
        if let first, answersAsRoot(first) { return .root(byOwnerAccess: false) }
        if let stop = stop(first, target: target, machine: machine) { return .stopped(stop) }
        guard let accessKey = ownerAccess() else { return .refused }
        let program = probe + "; " + OwnerAccess.install(line: appLine, mark: appKeyInPlace)
        let second: LocalShell.Answer?
        do {
            second = try await withKeyFile(accessKey.privateFile, in: folder) { (file: String) async -> LocalShell.Answer? in
                await call(target, keyFile: file, program: program, run: run, exists: exists) ?? nil
            }
        } catch {
            return .refused         // the key's file could not be written: root refused the one key that went
        }
        guard let second, answersAsRoot(second), OwnerAccess.isInPlace(second.output, mark: appKeyInPlace) else {
            return stop(second, target: target, machine: machine).map(Outcome.stopped) ?? .refused
        }
        guard let third = await call(target, keyFile: appKey, program: probe, run: run, exists: exists) else {
            return .stopped(missing)
        }
        if let third, answersAsRoot(third) { return .root(byOwnerAccess: true) }
        return .stopped(stop(third, target: target, machine: machine)
                        ?? String(l10n: "The root user of \(machine) still refuses this Mac's key, which is now in /root/.ssh/authorized_keys there. Make sure that its SSH server reads that file and lets root log in with a key, then try again."))
    }

    /// **One call of the route**: nil when its key file is not there right before it, so that no other key goes in its
    /// place; else `ssh`'s answer, nil when `ssh` did not start.
    static func call(_ target: InstallTarget, keyFile: String, program: String, run: ShellRunner,
                     exists: (String) -> Bool) async -> LocalShell.Answer?? {
        guard exists(keyFile) else { return nil }
        let answer = try? await run("/usr/bin/ssh", arguments(target, keyFile: keyFile, program: program), nil, 60)
        return .some(answer)
    }

    /// The words of a try that did not answer as root, or nil for a login that root refused: a refused host key (the
    /// owner's step for it, `InstallTarget.refusedHostKey`, and for a key that this Mac does not know yet the command
    /// that meets it, `unknownHostKey`), an `ssh` that did not reach the server (its own words,
    /// `ServerCheck.unreached(_:said:)`), and a session that got in and printed no root.
    static func stop(_ answer: LocalShell.Answer?, target: InstallTarget, machine: String) -> String? {
        guard let answer else { return ServerCheck.unreached(machine) }
        if let step = target.refusedHostKey(in: answer.lines, server: machine) {
            let changed = answer.output.lowercased().contains("remote host identification has changed")
            let aliased = target.hostKeyName.map { $0 != target.host } ?? false
            return (target.asksForItsPort && !aliased) || changed ? step : unknownHostKey(machine, target: target)
        }
        if SSHRun.refusedLogin(answer) { return nil }
        if answer.status == 255 { return ServerCheck.unreached(machine, said: answer.output.lowercased()) }
        return String(l10n: "The root login on \(machine) gave no answer that Founderizer can read.")
    }

    /// `root@<the node's address>`: what the owner types after `ssh` or `ssh-copy-id`, only at port 22, where on Linux
    /// only root's own `sshd` listens. The words never give a command at another port (the Door area's read of 25
    /// November 2026: a hub user can listen at the record's port with a key of another type, and the owner's own `ssh`
    /// would keep that key); the `ssh` at port 22 writes the line of the address, which the route reads first.
    static func login(_ target: InstallTarget) -> String { "root@\(target.host)" }

    /// The words of a host key that this Mac does not know yet: at port 22 the one command that writes the line of the
    /// node's address, which the route reads first (`ssh root@<address>`); at another port the owner's step of the
    /// port on the server's page (`InstallTarget.typeItsPort`), never a command at that port.
    static func unknownHostKey(_ machine: String, target: InstallTarget) -> String {
        guard target.port == 22 else { return InstallTarget.typeItsPort(machine) }
        return String(l10n: "This Mac does not know the host key of \(machine) yet. In Terminal, run ssh \(login(target)) once, check the key and answer yes, then try again.")
    }

    /// **The words of a root that refused this Mac's key**, with the owner's step: this Mac's key into root's
    /// `authorized_keys` on that server, with `ssh-copy-id` at port 22 where the owner still has a way in (never a
    /// command at another port, `login`), else in the server provider's console; and a server that lets root log in
    /// with a key.
    public static func refused(_ machine: String, target: InstallTarget) -> String {
        guard target.port == 22 else {
            return String(l10n: "The root user of \(machine) refused this Mac's key. Add ~/.ssh/founderizer_ed25519.pub to /root/.ssh/authorized_keys in the console of your server provider (for example Hetzner). Its SSH server must let root log in with a key (PermitRootLogin). Then try again.")
        }
        return String(l10n: "The root user of \(machine) refused this Mac's key. In Terminal, run ssh-copy-id -i ~/.ssh/founderizer_ed25519.pub \(login(target)) if you can still log in there, or add ~/.ssh/founderizer_ed25519.pub to /root/.ssh/authorized_keys in the console of your server provider (for example Hetzner). Its SSH server must let root log in with a key (PermitRootLogin). Then try again.")
    }

    /// **The words of a login that a server refused in a step's answer**, or nil when the answer holds no refused login
    /// (a refused host key has its own words, `InstallTarget.refusedHostKey`): for root with this Mac's own key, or for
    /// root where the root route runs at the next try (`routed`: the hub's own server, with no kept connection), the
    /// owner's step of `refused`; for another connection, the refusal itself, with its user. Until 25 November 2026 such
    /// a step said only that Founderizer could not read its answer.
    public static func refusedLogin(_ answer: LocalShell.Answer, target: InstallTarget, server: String,
                                    appKey: String = AppSSHKey.path(), routed: Bool = false) -> String? {
        guard SSHRun.refusedLogin(answer) else { return nil }
        if target.user == "root", target.identityFile == appKey || routed { return refused(server, target: target) }
        return String(l10n: "\(server) refused the SSH login of this Mac as \(target.user).")
    }

    /// The owner access key's folders that are older than this, which no call of this app uses any more: a call ends
    /// within 60 seconds of its start.
    static let staleKeyFolder: Double = 300

    /// **The owner access key's folders that a crash, a force quit or a power loss left in `base`**, older than
    /// `staleKeyFolder`, removed: at each run of the route, and before each new folder.
    static func removeStaleKeyFolders(in base: URL, now: Date = Date()) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix(keyFolderPrefix) {
            let old = base.appendingPathComponent(name)
            if let made = (try? manager.attributesOfItem(atPath: old.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(made) > staleKeyFolder {
                try? manager.removeItem(at: old)
            }
        }
    }

    /// **A private key for one call of `ssh`**: a folder of mode 700 of its own in `base` (this Mac user's own temporary
    /// folder), the key in a new file of mode 600 there, and both gone when `body` ends, also when it throws. The bytes
    /// that this function wrote are wiped. A folder of this name that a crash, a force quit or a power loss left in
    /// `base`, older than `staleKeyFolder`, goes first.
    static func withKeyFile<T>(_ text: String, in base: URL, now: Date = Date(),
                               _ body: (String) async throws -> T) async throws -> T {
        let manager = FileManager.default
        removeStaleKeyFolders(in: base, now: now)
        let folder = base.appendingPathComponent(keyFolderPrefix + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let file = folder.appendingPathComponent("key").path
        let out = Darwin.open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var bytes = Data(text.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(out, $0.baseAddress, $0.count) }
        PasswordOnce.wipe(&bytes)
        close(out)
        guard written == bytes.count else { throw POSIXError(.EIO) }
        return try await body(file)
    }
}
#endif
