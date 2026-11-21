import Foundation

/// **The one builder of the arguments of this Mac's `ssh`** (the build spec of the app's SSH key, 20 November 2026,
/// step 2): each caller gives its own parts (the connection, its own options of today, the program) and the builder
/// lays them out in one of two modes.
///
/// - **Owner mode** (`Key.owner`): the keys of the owner's own SSH configuration, his agent, or a key file of his. The
///   arguments are today's, unchanged, and `ssh` reads `~/.ssh/config` as it always did: a `Host` entry gives its
///   port, its user and its key, also its `Host *` keys.
/// - **App mode** (`Key.file`, `Key.agent`): the app's own key, and nothing else. `-F /dev/null` makes `ssh` read no
///   configuration at all, so no `Host *` key, no `ControlMaster`, no `ProxyCommand` and no `LocalCommand` of a
///   configuration comes in; `-a`, `-x` and the rules after them say the rest. The caller's host-key rule and its
///   timeouts of today stay. The port, the user and the address are the target's own: for a server whose `Host` entry
///   gives them, `InstallTarget.named` and `DoorAccess.configured` read them through `ssh -G` into the target, so
///   they go as `-p` and `user@host` and need no configuration.
///
/// Which mode a kept connection gets is `key(for:ledger:)`: app mode only for the app's own key file, and only once a
/// run with these arguments got in to that account (`SSHKeyLedger`, `SSHRun.prove`). Until then the account keeps
/// today's arguments, so a server that today lets this Mac in only through a key of the configuration, beside the
/// app's key, keeps working.
public struct SSHCall: Equatable, Sendable {
    /// The keys that one call offers.
    public enum Key: Equatable, Sendable {
        /// The owner's own: his configuration's keys and agent, or the key file of the target. Today's arguments.
        case owner
        /// The app's own key file (`AppSSHKey`, `~/.ssh/founderizer_ed25519`), alone.
        case file(String)
        /// The app's own key in the Secure Enclave, alone: its public half's file, which `ssh` matches to the one key
        /// that the run's agent socket serves. The socket's path is the runner's own, with no `%` and no `$`, which
        /// `ssh` would expand.
        case agent(publicKey: String, socket: String)
    }

    /// What the connection is for.
    public enum Shape: Equatable, Sendable {
        /// One program on the far side, its output read, and the connection closed.
        case command(String)
        /// A connection master that holds forwards for later requests on its control socket (`ScreenSharingConnection`).
        case master(controlPath: String)
    }

    public var host: String
    public var user: String
    public var port: Int
    /// The key file of an owner-mode call (`InstallTarget.identityFile`), offered alone with `IdentitiesOnly`, or nil
    /// for the keys that the configuration and the agent give. An app-mode call offers its `Key` instead.
    public var identityFile: String?
    /// The caller's own options of today, in their order: `-o` pairs ("-o", "Name=value") and lone flags. An
    /// owner-mode call gives them all; an app-mode call gives those that the app's rules do not set.
    public var options: [String]
    public var shape: Shape

    public init(host: String, user: String, port: Int, identityFile: String? = nil, options: [String], shape: Shape) {
        self.host = host; self.user = user; self.port = port; self.identityFile = identityFile
        self.options = options; self.shape = shape
    }

    /// The arguments of this call with `key`.
    public func arguments(_ key: Key) -> [String] {
        let identity: [String]
        switch key {
        case .owner:
            identity = identityFile.map { ["-o", "IdentitiesOnly=yes", "-i", $0] } ?? []
            switch shape {
            case .command(let program):
                return options + ["-p", String(port)] + identity + ["\(user)@\(host)", program]
            case .master(let path):
                return ["-N", "-n", "-T", "-S", path] + options + identity + ["-p", String(port), "-l", user, host]
            }
        case .file(let file):
            identity = ["-o", "IdentitiesOnly=yes", "-i", file]
        case .agent(let publicKey, let socket):
            identity = ["-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=\(socket)", "-i", publicKey]
        }
        let rules = Self.rules(shape)
        let own = Self.without(rules.map { $0.split(separator: "=")[0].lowercased() } + Self.identityNames,
                               flags: Self.flags, in: options)
        switch shape {
        case .command(let program):
            return ["-F", "/dev/null"] + Self.flags + identity + rules.flatMap { ["-o", $0] } + own
                + ["-p", String(port), "\(user)@\(host)", program]
        case .master(let path):
            return ["-F", "/dev/null", "-N", "-n", "-T"] + Self.flags + ["-S", path] + identity
                + rules.flatMap { ["-o", $0] } + own + ["-p", String(port), "-l", user, host]
        }
    }

    /// The lone flags of an app-mode call: no agent forwarding, no X11.
    static let flags = ["-a", "-x"]
    /// The options that name a key, which an app-mode call sets itself.
    static let identityNames = ["identitiesonly", "identityfile", "identityagent"]

    /// **The rules of an app-mode call**, before the caller's own options, so that none of the caller's can change one
    /// (`ssh` takes the first value of an option). Only the public key goes, with no prompt, no forwarding of any kind,
    /// no local command and no proxy. A command shares no connection master; a master keeps its own control options.
    static func rules(_ shape: Shape) -> [String] {
        let common = ["PreferredAuthentications=publickey", "BatchMode=yes", "NumberOfPasswordPrompts=0", "ForwardAgent=no",
                      "ClearAllForwardings=yes", "PermitLocalCommand=no"]
        switch shape {
        case .command: return common + ["ControlMaster=no", "ControlPath=none", "ProxyCommand=none"]
        case .master: return common + ["ProxyCommand=none"]
        }
    }

    /// The caller's options without the `-o` pairs whose names the app sets, and without its lone flags.
    static func without(_ names: [String], flags: [String], in options: [String]) -> [String] {
        var kept: [String] = [], index = 0
        while index < options.count {
            let option = options[index]
            if option == "-o", index + 1 < options.count {
                let name = options[index + 1].split(separator: "=", maxSplits: 1).first.map { $0.lowercased() } ?? ""
                if !names.contains(name) { kept += [option, options[index + 1]] }
                index += 2
                continue
            }
            if !flags.contains(option) { kept.append(option) }
            index += 1
        }
        return kept
    }

    /// **The key of a call to a kept connection**: app mode with the app's own key file when the connection names it
    /// and the ledger says that a run with that key alone got in to this account; else the owner's (today's
    /// arguments). `appKey`: the path of the app's key file, which only a test gives.
    public static func key(identityFile: String?, host: String, user: String, port: Int,
                           ledger: SSHKeyLedger = .shared, appKey: String? = nil) -> Key {
        guard let identityFile, let appKey = appKey ?? Self.appKey, identityFile == appKey,
              ledger.confined(SSHKeyLedger.Account(address: host, user: user, port: port)) else { return .owner }
        return .file(appKey)
    }

    /// The key of a call to `target` (`key(identityFile:host:user:port:ledger:appKey:)`).
    public static func key(for target: InstallTarget, ledger: SSHKeyLedger = .shared, appKey: String? = nil) -> Key {
        key(identityFile: target.identityFile, host: target.host, user: target.user, port: target.port, ledger: ledger,
            appKey: appKey)
    }

    /// The app's own key file on this Mac, or nil where there is none (iOS).
    static var appKey: String? {
        #if os(macOS)
        return AppSSHKey.path()
        #else
        return nil
        #endif
    }
}
