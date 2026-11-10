import Foundation
import Network

/// Installing a Linux machine of a fleet from the owner's own Mac, over their own SSH connection (PRODUCT.md P3,
/// and the commands of INSTALL-PROMPT.md, which an agent of theirs would run instead).
///
/// There are two jobs, and the owner never opens a console for either:
///
///   - `hub`: the first machine. The private network, the code, the plan, the installer itself, the claim that
///     proves this Mac to the hub, and `verify`.
///   - `join`: every machine after it. The private network, the join line the hub gave for that machine, and
///     `verify`.
///
/// Two things about the owner's own material are rules here, not choices. **Their SSH key never leaves this Mac**:
/// its path goes to `ssh`, which reads it, and the app never opens, copies or sends it. **The Tailscale auth key
/// travels on standard input only**, into a file of mode 600 that the install removes, so it is in no argument, no
/// log line and nothing this app keeps.
/// Which machine of a fleet is being checked, which says where its checkout is and as whom `verify` runs there.
public enum MachineCheckout: String, Codable, Equatable, Sendable, CaseIterable {
    /// The hub's own machine: `fleet-pilot`, owned by the service user.
    case hub
    /// A Linux machine that joined: `fleet-server`, owned by the service user.
    case linuxWorker
    /// A Mac that joined: `fleet-server` in the home of the Mac user whose LaunchAgents run its agents.
    case macWorker
}

public enum InstallJob: String, Codable, Equatable, Sendable, CaseIterable {
    /// The hub itself: `hub.sh` on a machine that has nothing.
    case hub
    /// A machine that joins a hub which runs already: `join.sh`, with the line from the app.
    case join
}

/// The machine, as the owner gives it: an address, a user, and the key they already use.
public struct InstallTarget: Equatable, Sendable {
    /// Where the owner's own SSH keys are, which the panel that picks a key opens on.
    public static var keyFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
    }

    public var host: String
    public var user: String
    public var port: Int
    /// The path of the owner's own private key on this Mac, or nil to use the keys their SSH agent holds.
    public var identityFile: String?
    /// The user is not root and becomes root with `sudo`. Every remote command then runs through it.
    public var becomeRoot: Bool

    public init(host: String, user: String = "root", port: Int = 22, identityFile: String? = nil,
                becomeRoot: Bool = false) {
        self.host = host; self.user = user; self.port = port
        self.identityFile = identityFile; self.becomeRoot = becomeRoot
    }

    /// Why this machine cannot be installed as given, in the owner's own words, or nil.
    public var problem: String? {
        guard host.range(of: "^[a-zA-Z0-9]([a-zA-Z0-9.:-]{0,252}[a-zA-Z0-9])?$", options: .regularExpression) != nil else {
            return "Enter the address or host name of the server, as you reach it over SSH."
        }
        guard user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
            return "Enter the user you reach that server with: root, or a user that can become root."
        }
        guard (1...65535).contains(port) else { return "The SSH port is between 1 and 65535." }
        if let identityFile {
            guard identityFile.hasPrefix("/"), !identityFile.contains("\0"), identityFile.count <= 4096 else {
                return "Choose the private key file you already use for that server."
            }
        }
        return nil
    }

    public var isValid: Bool { problem == nil }
    /// What `ssh` is given: never a password, and never a key the app itself read.
    public var destination: String { "\(user)@\(host)" }

    /// Whether `host` is an address on the public internet, written as one: not a name, and not a private, loopback,
    /// link-local or multicast address, nor one of the private network's (100.64.0.0/10, fd7a:115c:a1e0::/48). A Linux
    /// machine of a fleet lets no SSH in at such an address once its installer has run (`hubsetup.py firewall`).
    public static func isPublicAddress(_ host: String) -> Bool {
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            let other = b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 || (b[0] == 100 && (64...127).contains(b[1]))
                || (b[0] == 169 && b[1] == 254) || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            return !other
        }
        if let v6 = IPv6Address(host) { return [UInt8](v6.rawValue)[0] & 0xe0 == 0x20 }    // 2000::/3, global unicast
        return false
    }

    /// **The server an address names, as this Mac's own `ssh` reaches it.** The owner types one address: an address, a
    /// host name, `user@` either, or a `Host` alias of his `~/.ssh/config`. `options` is what `ssh -G` printed for that
    /// address, and its hostname, user and port are the ones his own `ssh` would use. A user is taken from it only
    /// where his configuration names one (the default is this Mac's own user, `localUser`), else root, as a VPS has.
    ///
    /// **Only the key his configuration gives this one host goes with the target**, because the install then passes it
    /// with `IdentitiesOnly`: `general` is what `ssh -G` printed for a name that no `Host` block of his names, and the
    /// keys in both are his keys for every server, which `ssh` offers by itself wherever the install connects. A key
    /// only an alias names would not be offered once the install reaches the server at its private address.
    public static func named(_ address: String, options: SSHOptions?, general: SSHOptions? = nil, localUser: String,
                             home: String, exists: (String) -> Bool) -> InstallTarget {
        let typed = address.trimmingCharacters(in: .whitespaces)
        let at = typed.lastIndex(of: "@")
        let given = at.map { String(typed[..<$0]) }
        let host = at.map { String(typed[typed.index(after: $0)...]) } ?? typed
        guard let options else {
            let user = given ?? "root"
            return InstallTarget(host: host, user: user, becomeRoot: user != "root")
        }
        let user = given ?? (options.user == localUser ? "root" : options.user)
        let key = options.identityFiles.filter { !(general?.identityFiles ?? []).contains($0) }.lazy
            .compactMap { SSHOptions.path($0, home: home, localUser: localUser, host: options.hostname, user: user) }
            .first(where: exists)
        return InstallTarget(host: options.hostname, user: user, port: options.port, identityFile: key,
                             becomeRoot: user != "root")
    }
}

/// What `ssh -G` prints for one host: the options this Mac's own `ssh` uses for it, after `~/.ssh/config`.
public struct SSHOptions: Equatable, Sendable {
    public var hostname: String
    public var user: String
    public var port: Int
    /// As the configuration writes them: `~/.ssh/id_vps`, `%d/.ssh/id_vps`.
    public var identityFiles: [String]

    public init(hostname: String, user: String, port: Int, identityFiles: [String] = []) {
        self.hostname = hostname; self.user = user; self.port = port; self.identityFiles = identityFiles
    }

    /// The four options out of `ssh -G`'s lines, or nil when it printed no host.
    public static func read(_ output: String) -> SSHOptions? {
        var hostname: String?, user: String?, port: Int?, files: [String] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let space = line.firstIndex(of: " ") else { continue }
            let value = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            switch line[..<space] {
            case "hostname": hostname = hostname ?? value
            case "user": user = user ?? value
            case "port": port = port ?? Int(value)
            case "identityfile": files.append(value)
            default: continue
            }
        }
        guard let hostname, !hostname.isEmpty, let user, let port else { return nil }
        return SSHOptions(hostname: hostname, user: user, port: port, identityFiles: files)
    }

    /// An identity file's own path: `~` and `ssh`'s `%d`, `%u`, `%h`, `%r` and `%%` filled in. A path with another of its
    /// tokens, or one that is not absolute after that, is nil, and the key is left to `ssh` itself.
    static func path(_ written: String, home: String, localUser: String, host: String, user: String) -> String? {
        let percent = "\u{0}"       // `%%` is one `%`, and no token
        var path = (written.hasPrefix("~/") ? home + written.dropFirst() : written)
            .replacingOccurrences(of: "%%", with: percent)
        for (token, value) in [("%d", home), ("%u", localUser), ("%h", host), ("%r", user)] {
            path = path.replacingOccurrences(of: token, with: value)
        }
        guard !path.contains("%") else { return nil }
        path = path.replacingOccurrences(of: percent, with: "%")
        return path.hasPrefix("/") ? path : nil
    }
}

/// One step of an install, in the order it runs.
public struct InstallStep: Equatable, Sendable, Identifiable {
    /// What the runner does with this step.
    public enum Action: Equatable, Sendable {
        /// The check of the server (`ServerCheck.script`), as the user this Mac logs in as and before anything changes.
        /// A server that is busy with its first start is read again every `every` seconds, for at most `within`.
        case check(every: Double, within: Double)
        /// One command on the machine, over SSH.
        case run(String)
        /// The hub's own join line. Both installers end in `verify`, and `verify` fails on a machine that is not
        /// signed in to its provider yet — which every machine is, because the installer signs in to nothing and
        /// only the owner can. So the line ends in failure on a clean install, and this step reads the machine's
        /// own last word instead of the exit status: the checks that follow say what is true.
        case join(String)
        /// One command whose standard input is the Tailscale auth key, so the key is in no argument.
        case sendAuthKey(String)
        /// One command, started and left running on the machine, with its output in a log the next steps read.
        case detach(String)
        /// Read this command's output every `every` seconds until it holds the mark, for at most `within` seconds.
        case waitFor(String, mark: String, every: Double, within: Double)
        /// Start Tailscale's own sign-in on the machine, and read `check` until the machine is on the private network.
        /// The link it prints goes to the screen as the step's lines, and the owner approves it (`NetworkSignIn`).
        case signIn(start: String, check: String, every: Double, within: Double)
        /// This Mac proves its own address to the new hub with the code the installer printed (`hubsetup.py claim`).
        case claim
        /// `verify --json` on the machine, whose answers become the checklist.
        case verify(String)
    }

    public let id: String
    public let title: String
    /// What this step is for, in one line the owner can read while it runs.
    public let says: String
    public let action: Action
}

/// The ordered steps of one install, with what must never be written down.
public struct InstallPlan: Equatable, Sendable {
    public let job: InstallJob
    public let target: InstallTarget
    public let steps: [InstallStep]
    /// The strings that are removed from every line this app shows or keeps: the Tailscale auth key and the
    /// one-time join code. The hub keeps only the code's SHA-256, and this app keeps neither.
    public let redactions: [String]

    /// The line an installer prints when it stops, in either brand. The installers are renamed in their own
    /// repository, and the two sides must never be wrong at the same time: the side that moves first widens, and
    /// the side that follows narrows later if it ever matters (COORDINATION.md, the additive rule). `hub.sh` says
    /// "install" and `join.sh` says "join", and this app reads both.
    public static let stopMarks = ["Founderizer install stopped:", "Fleet install stopped:",
                                   "Founderizer join stopped:", "Fleet join stopped:"]

    /// Whether an install stopped only because the machine could not get onto the owner's private network by itself
    /// and no Tailscale key was given. Then the key is the one question left, and the install goes again: every step
    /// of both installers checks first, so nothing is done twice.
    public static func needsNetworkKey(_ says: String) -> Bool {
        let said = says.lowercased()
        return said.contains("not on your private network") || said.contains("no tailscale auth key came in")
            || said.contains("did not join with that auth key")
    }

    /// The line of an installer's output that says it stopped, or nil.
    public static func stopLine(in lines: [String]) -> String? {
        lines.first { line in stopMarks.contains { line.contains($0) } }
    }

    /// One system an installer takes: `ID` and `VERSION_ID` of its `/etc/os-release`, and the name it goes by.
    public struct System: Equatable, Sendable {
        public let id: String
        public let version: String
        public let name: String
    }

    /// **The systems each installer takes**, the one table that the check of a server and the words below both read.
    /// The join (`join.sh`) and the hub's own installer (`hub.sh`) take the same ones: the join took Ubuntu 26.04 first
    /// (Fleet 2026.11.170), and on 5 November 2026 both took Debian 13 and the hub Ubuntu 26.04 too, each proved on a
    /// new server of that system.
    public static let joinTakes = [System(id: "ubuntu", version: "22.04", name: "Ubuntu"),
                                   System(id: "ubuntu", version: "24.04", name: "Ubuntu"),
                                   System(id: "ubuntu", version: "26.04", name: "Ubuntu"),
                                   System(id: "debian", version: "12", name: "Debian"),
                                   System(id: "debian", version: "13", name: "Debian")]
    public static let hubTakes = joinTakes

    public static func systems(_ job: InstallJob) -> [System] { job == .hub ? hubTakes : joinTakes }

    /// The systems each installer takes, as it says them when a server is another one.
    public static let joinSystems = systemsLine(joinTakes)
    public static let hubSystems = systemsLine(hubTakes)

    /// "This install needs Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13."
    static func systemsLine(_ systems: [System]) -> String {
        var names: [String] = []
        for system in systems where !names.contains(system.name) { names.append(system.name) }
        let each = names.map { name in
            name + " " + ServerCheck.spoken(systems.filter { $0.name == name }.map(\.version), "or")
        }
        let all = each.count > 1 ? each.dropLast().joined(separator: ", ") + ", or " + each[each.count - 1] : each.joined()
        return "This install needs \(all)."
    }

    /// The published Founderizer repository, which a customer's download page may replace with one of its own. It
    /// has one answer, so the wizard fills it in instead of asking (PRODUCT.md 4.3's `release_upstream`).
    public static let defaultSource = "https://github.com/miguelpieras/founderizer-fleet.git"

    /// **This app gives the manager a server of its own in its setup** (`AgentSetupFlow.serverFeature`), and says so to
    /// the hub's installer, which then runs no agent on the hub's server. A new hub clones the newest release, which
    /// reaches it before the app that the download page gives does, so the installer waits for this word: without it
    /// the manager runs on the hub's server, as an app from before needs (Fleet 2026.11.208). An installer from before
    /// ignores it, and its manager is then signed in on the hub, as before.
    static let managerServer = "FLEET_MANAGER_SERVER=later"

    /// The log the detached hub install writes, and the two steps that read it.
    static let hubLog = "/root/fleet-install.log"
    /// Where the installer's own copy of the Founderizer code goes on a new hub.
    static let hubKit = "/root/fleet-kit"
    /// The file the Tailscale auth key is written into, and which the install removes.
    static let authKeyFile = "/root/fleet-authkey"
    /// The checkout each kind of machine ends up with, and the user that owns it (`hub.sh`, `join.sh`).
    static let hubCheckout = "/home/fleet/fleet-pilot"
    static let joinCheckout = "/home/fleet/fleet-server"
    static let serviceUser = "fleet"

    /// The install of a new hub: the one machine that has no hub to ask for a line (INSTALL-PROMPT.md job A).
    ///
    /// `source` is the address of the Founderizer repository, which the owner's own download page gives them. The
    /// installer waits up to 30 minutes for the claim, so it runs detached with its output in a log, and this Mac
    /// claims the hub itself: the address that claim comes from is the address the hub serves the owner's pages to.
    public static func hub(target: InstallTarget, source: String, authKey: String?) -> InstallPlan {
        let kit = hubKit, log = hubLog
        let steps: [InstallStep] = [
            .init(id: "read", title: ServerCheck.title, says: "Which system it is, and whether we are root there.",
                  action: readAction),
            // First, because the installer lets SSH in over the private network only: every step after this one
            // reaches the server at the address it gets there (`MachineInstaller.reached`).
            .init(id: "network", title: "The private network",
                  says: authKey == nil ? "This server is already on your private network, so no key is needed."
                      : "Tailscale, with your key on standard input, and the address it gets.",
                  action: authKey == nil ? .run(onNetwork) : keyedNetwork),
            .init(id: "code", title: "The Founderizer code", says: "A copy of the code on the server, from your own download page.",
                  action: .run("command -v git >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get "
                               + "-o DPkg::Lock::Timeout=\(aptLockWait) -q update && DEBIAN_FRONTEND=noninteractive "
                               + "apt-get -o DPkg::Lock::Timeout=\(aptLockWait) -y -q install git; }; "
                               + "if test -d \(kit)/.git; then git -C \(kit) pull -q --ff-only; "
                               + "else git clone -q -- \(quote(source)) \(kit); fi; "
                               + "git -C \(kit) rev-parse --short HEAD; ls \(kit)/hub.sh")),
            .init(id: "plan", title: "The plan", says: "Every step the install would take. It changes nothing.",
                  action: .run("\(managerServer) sh \(kit)/hub.sh --check")),
            .init(id: "start", title: "Install the hub", says: "The installer runs on the server and writes what it does to a log.",
                  action: .detach("setsid sh -c '\(managerServer) sh \(kit)/hub.sh < /dev/null > \(log) 2>&1' "
                                  + "> /dev/null 2>&1 < /dev/null &")),
            .init(id: "wait_claim", title: "Wait for the link code", says: "The installer makes a one-time code for this Mac.",
                  action: .waitFor("tail -n 60 \(log)", mark: ClaimCode.logMark, every: 10, within: 1200)),
            .init(id: "claim", title: "Claim the hub", says: "This Mac sends the code back, and the hub serves your pages to it alone.",
                  action: .claim),
            .init(id: "wait_ready", title: "Finish the install", says: "The security updates and the checks take some minutes.",
                  action: .waitFor("tail -n 40 \(log)", mark: "READY", every: 20, within: 1800)),
            .init(id: "verify", title: "Check the server", says: "Every check of the server.",
                  action: .verify(verifyCommand(.hub))),
        ]
        return InstallPlan(job: .hub, target: target, steps: steps, redactions: [authKey].compactMap { $0 })
    }

    /// The first step of both installs: the check of the server, read again while the server is busy with its first start.
    static let readAction: InstallStep.Action = .check(every: ServerCheck.waitEvery, within: ServerCheck.waitWithin)

    /// **How long each apt-get of an install waits for apt's lock**: a new server runs its first security updates for
    /// about nine minutes after its first start, and they hold the lock (the proof run of 5 November 2026). `hub.sh`,
    /// `join.sh`, `hubsetup.py` and `onboard.py` wait as long.
    static let aptLockWait = 1200

    /// Tailscale's own installer, on a machine that has none. It comes over curl, which a bare server may not have
    /// either, and the check lets such a server through (`ServerCheck.script`'s `reach=<host> none`): so curl first.
    /// Tailscale's installer runs apt-get with no wait for its lock, so each try waits for the lock first, and a try
    /// that the server's own updates got in the way of is made again, three times at most.
    static let tailscaleInstall = "command -v tailscale >/dev/null 2>&1 || { command -v curl >/dev/null 2>&1 || "
        + "{ export DEBIAN_FRONTEND=noninteractive; apt-get -o DPkg::Lock::Timeout=\(aptLockWait) -q update >/dev/null && "
        + "apt-get -o DPkg::Lock::Timeout=\(aptLockWait) -y -q install curl ca-certificates >/dev/null; }; "
        + "for try in 1 2 3; do apt-get -o DPkg::Lock::Timeout=\(aptLockWait) -q install </dev/null >/dev/null 2>&1; "
        + "curl -fsSL https://tailscale.com/install.sh | sh && break; sleep 20; done; }; "

    /// The machine onto the private network with the key on standard input, and the address it gets there.
    static let keyedNetwork: InstallStep.Action = .sendAuthKey(
        "umask 077; cat > \(authKeyFile); " + tailscaleInstall
            + "tailscale status >/dev/null 2>&1 || tailscale up --auth-key=file:\(authKeyFile) --accept-dns=false; "
            + "rm -f \(authKeyFile); tailscale ip -4")

    /// The address of a machine that is on the private network already; on one that is not, the words that ask for the
    /// key (`needsNetworkKey`).
    static let onNetwork = "tailscale ip -4 2>/dev/null | grep . || { echo '\(NetworkSignIn.notOnNetwork)'; exit 1; }"

    /// The machine's address on the private network, as the network step printed it (`tailscale ip -4`), or nil.
    public static func privateAddress(in lines: [String]) -> String? {
        lines.last(where: ClaimCode.isPrivateAddress)
    }

    /// A machine that joins a hub which runs already (INSTALL-PROMPT.md job B).
    ///
    /// `line` is the join line the hub gave for this machine (`POST /ui/servers/join`): it carries the hub's own
    /// address and the one-time code, and it is run exactly as the hub wrote it.
    public static func join(target: InstallTarget, line: String, code: String, authKey: String?) -> InstallPlan {
        let network: InstallStep.Action = authKey == nil
            ? NetworkSignIn.action(install: tailscaleInstall, tags: NetworkSignIn.tags(inLine: line))
            : keyedNetwork
        let steps: [InstallStep] = [
            .init(id: "read", title: ServerCheck.title, says: "Which system it is, and whether we are root there.",
                  action: readAction),
            .init(id: "network", title: "The private network",
                  says: authKey == nil ? "Tailscale, with a sign-in link for you when this server is not on it yet."
                      : "Tailscale, with your key on standard input, and the address it gets.",
                  action: network),
            .init(id: "join", title: "Join the fleet", says: "The line your hub gave for this server, as it wrote it.",
                  action: .join(line)),
            .init(id: "verify", title: "Check the server", says: "Every check of the server.",
                  action: .verify(verifyCommand(.linuxWorker))),
        ]
        return InstallPlan(job: .join, target: target, steps: steps, redactions: [authKey, code].compactMap { $0 })
    }

    /// Only the checks of one machine, and no install: `python3 fleet.py verify --json` there, over the owner's own
    /// SSH connection (PRODUCT.md 4.1). A machine answers for itself, and the app shows that answer as a checklist.
    public static func check(target: InstallTarget, machine: MachineCheckout) -> InstallPlan {
        let step = InstallStep(id: "verify", title: "Check the server",
                               says: "Every check of that server.",
                               action: .verify(verifyCommand(machine)))
        return InstallPlan(job: .join, target: target, steps: [step], redactions: [])
    }

    /// A restart of one machine, over the owner's own SSH connection, and the proof that it came back: the checks
    /// of PRODUCT.md 4.1 again, read on the machine itself.
    ///
    /// **This Mac restarts the machine, and not the hub**, because the machine that most often asks for a restart
    /// is the hub itself, and a hub cannot watch its own reboot: it would have to answer the owner before it dies
    /// and have nothing left watching after. This Mac's own connection has both ends of it.
    ///
    /// How it knows the machine really came back: `/run` is a tmpfs on every machine these installers take
    /// (`joinTakes`), so the file the first step writes is gone exactly once the machine
    /// has booted again — an answer from a machine that is only slow to go down cannot be read as a restart. It
    /// then waits for systemd to say the boot is finished, so that `verify` does not report services that are
    /// still starting. A machine that does not come back times out and says so; nothing here guesses.
    public static func restart(target: InstallTarget, machine: MachineCheckout) -> InstallPlan {
        let mark = restartMark, back = bootedMark
        let steps: [InstallStep] = [
            .init(id: "mark", title: "Mark this boot",
                  says: "A file in the server's own /run, which only a restart clears.",
                  action: .run("touch \(mark) && test -f \(mark) && echo marked")),
            .init(id: "restart", title: "Restart the server",
                  says: "The server restarts, after this connection closes.",
                  action: .detach("setsid sh -c 'sleep 2; systemctl reboot || reboot' > /dev/null 2>&1 < /dev/null &")),
            // It has come back when its /run is empty (so it really booted), its units have started, and its clock
            // has caught up — or it has been up two minutes, after which whatever the checks say about the clock is
            // the truth and not a machine still looking for a time server. Without that last part the very first
            // restart of the owner's own hub reported "Clock failed" on a machine whose clock was right thirty
            // seconds later, and a page that cries wolf after a restart is worth less than no page.
            .init(id: "back", title: "Wait for it to come back",
                  says: "The server answers again, with its /run empty, its units started and its clock caught up.",
                  action: .waitFor("test -f \(mark) || { systemctl is-system-running 2>/dev/null "
                                   + "| grep -q -e running -e degraded && { timedatectl show -p NTPSynchronized "
                                   + "--value 2>/dev/null | grep -q yes || test \"$(cut -d. -f1 /proc/uptime)\" "
                                   + "-gt 120; } && echo \(back); }",
                                   mark: back, every: 10, within: 900)),
            .init(id: "verify", title: "Check the server",
                  says: "Every check again, to say where the server stands after its restart.",
                  action: .verify(verifyCommand(machine))),
        ]
        return InstallPlan(job: .join, target: target, steps: steps, redactions: [])
    }

    /// The configuration ref, which is the one branch a fleet runs (`lifecycle.CONFIG_BRANCH`, RULES.md). The code
    /// branch reaches a machine with a deployment and never with a pull, so an update of a helper's checkout is this
    /// ref and nothing else — also for a checkout that has drifted onto another branch, which `update` refuses to
    /// move rather than guess.
    public static let configRef = "config"
    /// What the first step of an update prints when the checkout can be moved on and nothing is lost by moving it.
    static let canUpdateMark = "FLEET_CAN_UPDATE"
    /// What the last step prints once that agent's helper service is running again.
    static let helperUpMark = "FLEET_HELPER_UP"

    /// One agent's own OS user on a Linux machine of a fleet, whose home holds that agent's checkout, its runtime,
    /// its credential and its service (`hubsetup.AGENT_USER`, `server.AGENT_USER`): `fleet-<agent>`.
    public static func agentUser(_ agent: String) -> String { "fleet-\(agent)" }

    /// One program as that agent's own OS user, from that user's own home, PATH and user services — the shape both
    /// installers use (`hub.sh`'s `as_agent`, `server.as_agent`). That home is of mode 700, so this is the only way
    /// anything reaches the agent's own checkout.
    static func asAgent(_ agent: String, run inner: String) -> String {
        let user = agentUser(agent)
        return "runuser -u \(user) -- env HOME=/home/\(user) XDG_RUNTIME_DIR=/run/user/$(id -u \(user)) "
            + "PATH=/home/\(user)/.local/bin:/usr/local/bin:/usr/bin:/bin sh -c \(quote(inner))"
    }

    /// The update of one agent's helper, driven from this Mac over the owner's own SSH connection: the three things
    /// the helper's own `lifecycle.apply` does — fetch, fast-forward onto the configuration ref, restart that
    /// agent's user service — and then the checks of PRODUCT.md 4.1 again, as `restart` ends, so the page says
    /// where the machine stands afterwards and not before.
    ///
    /// **Why this exists next to the hub's own route.** An agent updates itself through the hub
    /// (`POST /ui/machines/<agent>/update`), which waits for that helper to be idle, and the hub takes every agent
    /// of the fleet — the manager on the hub machine included, since 19 October 2026. What is left for this Mac is
    /// a helper whose hub has not got the feature that reaches it: today a lead on a hub without `leads`. So this
    /// is offered for the helpers the hub will not take and for no others: a second way to do one thing is the
    /// noise this page exists to remove. `MachineStatus.updatesThroughHub(leads:)` holds that one rule.
    ///
    /// **The restart is the part that matters.** A helper reports the revision it loaded when it started
    /// (`lifecycle.running`), and its checkout is already brought onto the ref before each task session
    /// (`fleet.sync_checkout`), so a helper reads "behind" while its files are current and only a restart of its
    /// service loads them. The fetch and the merge are therefore a no-op on a checkout that is already there, and
    /// the plan still ends the same way.
    ///
    /// **Nothing moves that cannot move.** The first step only reads: after the fetch it refuses, in the fleet's own
    /// words and with nothing changed, a checkout that has its own changes or that holds commits the configuration
    /// ref does not. `--ff-only` would refuse the second case as well; it is said here so that the owner reads the
    /// reason and the way out instead of a git error.
    public static func update(target: InstallTarget, machine: MachineCheckout, agent: String) -> InstallPlan {
        let kit = "/home/\(agentUser(agent))/fleet-\(agent)", ref = "refs/remotes/origin/\(configRef)"
        let unit = "fleet-\(agent).service"
        let read = "cd \(kit) 2>/dev/null || { echo 'the checkout \(kit) is not there'; exit 1; }; "
            + "said=$(git fetch -q origin 2>&1) || { echo \"the fetch of origin failed: $said\"; exit 1; }; "
            + "git rev-parse --verify --quiet \(ref) >/dev/null || "
            + "{ echo 'origin has no \(configRef) ref, so there is nothing to move onto'; exit 1; }; "
            + "test -z \"$(git status --porcelain --untracked-files=no)\" || "
            + "{ echo 'the checkout has its own changes, so it stays where it is'; exit 1; }; "
            + "git merge-base --is-ancestor HEAD \(ref) || "
            + "{ echo 'the checkout holds commits that \(configRef) does not, so it cannot be moved on. "
            + "Push them, or look at the checkout.'; exit 1; }; echo \(canUpdateMark)"
        let move = "cd \(kit) || exit 1; said=$(git merge -q --ff-only \(ref) 2>&1) || "
            + "{ echo \"the checkout did not move onto \(configRef): $said\"; exit 1; }; git rev-parse --short HEAD"
        let service = "systemctl --user restart \(unit) || { echo '\(unit) did not restart'; exit 1; }; "
            + "systemctl --user is-active -q \(unit) || "
            + "{ echo '\(unit) is not running after its restart'; exit 1; }; echo \(helperUpMark)"
        let who = agent.agentLabel
        let steps: [InstallStep] = [
            // Not the id "read": that one is the first step of an install, and the runner reads a machine's own user
            // and system out of it.
            .init(id: "checkout", title: "Read the checkout",
                  says: "What Founderizer on \(who)'s server has, and whether it can move on without losing anything.",
                  action: .run(asAgent(agent, run: read))),
            .init(id: "move", title: "Move the checkout on",
                  says: "It fast-forwards onto \(configRef), as Founderizer's own update does.",
                  action: .run(asAgent(agent, run: move))),
            .init(id: "service", title: "Restart Founderizer",
                  says: "\(who)'s own service, which is what loads the new checkout.",
                  action: .run(asAgent(agent, run: service))),
            .init(id: "verify", title: "Check the server",
                  says: "Every check again, to say where the server stands after the update.",
                  action: .verify(verifyCommand(machine))),
        ]
        return InstallPlan(job: .join, target: target, steps: steps, redactions: [])
    }

    /// The file a restart writes before it goes, in a directory the machine clears when it boots.
    static let restartMark = "/run/founderizer-restart"
    /// What the machine prints once it has booted again and finished starting its units.
    static let bootedMark = "FLEET_BOOTED"

    /// `verify --json` in that machine's checkout, as the user whose services it reads. `verify` answers for one
    /// user's services, so on a Linux machine it runs as the user the installers gave it (`hub.sh`, `join.sh`); on a
    /// Mac the agents are that Mac user's own LaunchAgents, so it runs as the user this Mac connects with.
    public static func verifyCommand(_ machine: MachineCheckout) -> String {
        guard machine != .macWorker else {
            return "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; cd \"$HOME/fleet-server\" "
                + "&& python3 fleet.py verify --json"
        }
        let checkout = machine == .hub ? hubCheckout : joinCheckout
        let inner = "cd \(checkout) && python3 fleet.py verify --json"
        return "runuser -u \(serviceUser) -- env HOME=/home/\(serviceUser) "
            + "XDG_RUNTIME_DIR=/run/user/$(id -u \(serviceUser)) "
            + "PATH=/home/\(serviceUser)/.local/bin:/usr/local/bin:/usr/bin:/bin sh -c \(quote(inner))"
    }

    /// The arguments of `ssh` for one remote program: the owner's own connection, nothing interactive, and no
    /// password anywhere. A host this Mac has never met is accepted once and kept, as a person typing `yes` does.
    /// `reaching` is where an install reaches the machine now (`MachineInstaller.reached`); else the plan's target.
    public func arguments(for program: String, reaching: InstallTarget? = nil) -> [String] {
        arguments(for: program, reaching: reaching, runs: .root)
    }

    /// As whom a remote program runs.
    enum Runs: Equatable, Sendable {
        /// As the user this Mac logs in as: the check of the server, and the app's own key going onto it.
        case login
        /// As root, through `sudo -n` for a user that is not root.
        case root
        /// As root, through a `sudo` that asks for a password: `sudo -S` reads it from the first line of standard input,
        /// where this install puts the password it holds in memory (`PasswordOnce`), and never from an argument. `-k`
        /// makes it ask every time, so a `sudo` that remembered an earlier answer cannot leave the password unread for
        /// the program, and `-p ''` keeps its prompt out of the lines.
        case rootWithPassword
    }

    func arguments(for program: String, reaching: InstallTarget? = nil, runs: Runs) -> [String] {
        let target = reaching ?? target
        var values = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=20",
                      "-o", "ServerAliveInterval=30", "-o", "NumberOfPasswordPrompts=0", "-p", String(target.port)]
        if let key = target.identityFile { values += ["-o", "IdentitiesOnly=yes", "-i", key] }
        values.append(target.destination)
        switch runs {
        case .root where target.becomeRoot: values.append("sudo -n -i -- /bin/sh -c \(InstallPlan.quote(program))")
        case .rootWithPassword where target.becomeRoot:
            values.append("sudo -S -k -p '' -i -- /bin/sh -c \(InstallPlan.quote(program))")
        default: values.append(program)
        }
        return values
    }

    /// The same line with the owner's own secrets taken out of it. Everything this app shows, keeps or reports
    /// goes through here.
    public func redact(_ text: String) -> String {
        var line = text
        for secret in redactions where secret.count >= 8 {
            line = line.replacingOccurrences(of: secret, with: "(not shown)")
        }
        return line
    }

    /// One shell word, for a program that is put inside another one.
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// A machine that is not on the owner's private network, and no credential on this Mac to mint it a key: Tailscale's own
/// sign-in, the one step of an install that asks the owner for something. The owner, 31 October 2026, after adding three
/// servers: a link to approve in place of a credential, which a tailnet whose policy is kept in a repository cannot take
/// (`tag:founderizer` in its policy, and a machine with a tag that the policy gives no rights). The machine prints the
/// link, the screen shows it on the page of a machine that is not on the network (`MachineInstallRun`), and the install
/// goes on by itself when the owner has approved it.
///
/// `tailscale up` waits for that approval, and `LocalShell` answers only when a program ends, so it runs in the
/// background on the machine with its output in a file that each read of the step looks at. The tags are the ones in
/// the hub's own join line. A tailnet that refuses them gets the credential's question instead.
public struct NetworkSignIn: Equatable, Sendable {
    public let url: URL
    /// The machine's own name, which Tailscale shows on the page the link opens. Nil when it did not say.
    public let server: String?

    static let log = "/tmp/fleet-tailscale-up.log"
    /// What `check` prints once the machine is on the network.
    static let onMark = "fleet-on-network"
    /// What the sign-in leaves in its log when it ended, with its status.
    static let endMark = "fleet-sign-in-ended"
    static let nameMark = "fleet-machine-name="
    /// How long the owner has. A link that nobody approves ends the install instead of leaving it waiting for ever.
    static let waitMinutes = 15
    /// `tailscale up` itself stops after `waitMinutes`, so this is only for a machine that stopped answering.
    static let within = Double(waitMinutes * 60 + 60)
    /// One new SSH connection for each read, and a machine's firewall may limit them, so not faster than this.
    static let every = 8.0
    /// The words that reach the credential's question (`InstallPlan.needsNetworkKey`).
    public static let notOnNetwork = "This machine is not on your private network. Give the Tailscale key of your fleet."
    public static let notApproved = "The link was not approved in time."
    public static let notStarted = "Tailscale did not start on this server."

    /// The action for this machine.
    static func action(install: String, tags: [String]) -> InstallStep.Action {
        let tagged = tags.isEmpty ? "" : "--advertise-tags=\(tags.joined(separator: ",")) "
        let up = "tailscale up \(tagged)--accept-dns=false --timeout=\(waitMinutes)m"
        // The log of an earlier try goes first, also when Tailscale runs: its end is not this try's.
        let start = install + "umask 077; rm -f \(log); tailscale status >/dev/null 2>&1 && exit 0; "
            + "setsid sh -c '\(up); echo \(endMark) $?' > \(log) 2>&1 < /dev/null &"
        // `tailscale status` also says yes while Tailscale starts, and the join's next step needs the network itself.
        let check = "echo \(nameMark)$(hostname); tailscale status --json 2>/dev/null | grep -q '\"BackendState\": \"Running\"' && "
            + "{ echo \(onMark); tailscale ip -4; rm -f \(log); exit 0; }; cat \(log) 2>/dev/null; true"
        return .signIn(start: start, check: check, every: every, within: within)
    }

    /// The `--advertise-tags` of the hub's join line, each one a tag this app would write itself; else none: they stand
    /// inside the single quotes of the `sh -c` that runs the sign-in, so a word with a quote in it would break out of them.
    public static func tags(inLine line: String) -> [String] {
        guard let found = line.range(of: "--advertise-tags=[^ ;&|]+", options: .regularExpression) else { return [] }
        let tags = line[found].dropFirst("--advertise-tags=".count).split(separator: ",").map(String.init)
        return tags.allSatisfy(PolicyFile.isTag) ? tags : []
    }

    /// What one read of the step found.
    enum Reading: Equatable {
        case on, ended(says: String), waiting(NetworkSignIn?)
    }

    static func read(_ lines: [String]) -> Reading {
        if lines.contains(onMark) { return .on }
        if let end = lines.first(where: { $0.hasPrefix(endMark) }) {
            // Status 0 with no mark yet is the moment before Tailscale says it runs: the next read has it.
            if end == "\(endMark) 0" { return .waiting(nil) }
            let said = lines.map { $0.lowercased() }
            if said.contains(where: { $0.hasPrefix("timeout waiting for tailscale") }) { return .ended(says: notApproved) }
            // Only a tailnet that refused the tags has the credential for an answer: that key carries a tag of its own.
            let refused = said.contains { $0.contains("requested tags") }
            return .ended(says: refused ? notOnNetwork : notStarted)
        }
        return .waiting(found(in: lines))
    }

    /// The link in these lines. Only Tailscale's own sign-in page: this text comes from a machine, and the screen
    /// opens it in the owner's browser, where he is signed in as an admin of his tailnet.
    public static func found(in lines: [String]) -> NetworkSignIn? {
        let pattern = "^https://login\\.tailscale\\.com/a/[0-9a-zA-Z]{6,64}$"
        guard let link = lines.last(where: { $0.range(of: pattern, options: .regularExpression) != nil }),
              let url = URL(string: link) else { return nil }
        let name = lines.first { $0.hasPrefix(nameMark) }.map { String($0.dropFirst(nameMark.count)) }
        let named = name?.range(of: Servers.namePattern, options: .regularExpression) != nil
        return NetworkSignIn(url: url, server: named ? name : nil)
    }
}

/// The one-time code a new hub's installer prints for the owner's Mac, and the claim that Mac then makes
/// (`hubsetup.py claim`). The code is twelve characters in three groups of four; the hub keeps only its SHA-256.
public enum ClaimCode {
    /// The line the installer writes into its log, which carries the code and the address to send it to.
    public static let logMark = "FLEET_CLAIM="
    /// The alphabet of a code (`hub.LINK_ALPHABET`): no letters or digits that are read for one another.
    public static let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    /// A code as the owner may give it: case, spaces and hyphens are forgiven, because they read it off a screen.
    public static func read(_ given: String) -> String? {
        let code = given.uppercased().filter { alphabet.contains($0) }
        return code.count == 12 ? code : nil
    }

    /// The code written as the installer shows it, in three groups of four.
    public static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { start in
            String(code.dropFirst(start).prefix(4))
        }.joined(separator: "-")
    }

    /// The code and the claim address out of the installer's own log line, which looks like
    /// `FLEET_CLAIM=ABCD-EFGH-JKLM sh -c "$(curl -fsS http://100.x.y.z:8765/claim)"`. Only a code of the right shape
    /// and a plain HTTP address on the fleet's own private network are taken: the log comes from a machine, and a
    /// machine must not be able to point this Mac at an address of its own choosing.
    public static func found(in log: String) -> (code: String, claim: URL)? {
        for line in log.split(separator: "\n").reversed() where line.contains(logMark) {
            let text = String(line)
            guard let mark = text.range(of: logMark) else { continue }
            let rest = text[mark.upperBound...]
            guard let code = read(String(rest.prefix(while: { !$0.isWhitespace }))),
                  let found = rest.range(of: "http://[0-9.]+:[0-9]{1,5}/claim", options: .regularExpression),
                  let url = URL(string: String(rest[found])), let host = url.host, isPrivateAddress(host)
            else { continue }
            return (code, url)
        }
        return nil
    }

    /// The hub's address out of whatever the owner pasted: the claim line their agent printed, a full address, or
    /// the bare address of the machine, which carries the hub's own port. nil when it is neither.
    public static func hubAddress(in text: String) -> String? {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = found(in: said), let host = found.claim.host { return "http://\(host):8765" }
        if let found = said.range(of: "https?://[0-9A-Za-z.:-]+", options: .regularExpression),
           (try? HubClient.address(String(said[found]))) != nil {
            return String(said[found])      // as the owner wrote it: the client is what normalizes an address
        }
        if said.range(of: "^[0-9]{1,3}(\\.[0-9]{1,3}){3}(:[0-9]{1,5})?$", options: .regularExpression) != nil {
            return said.contains(":") ? "http://\(said)" : "http://\(said):8765"
        }
        return nil
    }

    /// A Tailscale address of the fleet's own network (100.64.0.0/10), which is the only place a claim is made.
    public static func isPrivateAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}
