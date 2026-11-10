import Foundation

/// **The check of a server before an install** (the onboarding the owner approved on 4 November 2026: "Yes, build it").
/// For a VPS at any provider he types only its address, and the app reads that server once, before anything on it
/// changes: then one Install press with one line that says what changes, or one line that says why it stops.
///
/// One SSH session runs one POSIX `sh` script, `script`, as the user this Mac logs in as. It changes nothing on the
/// server, and it uses `sudo -n` only for the one thing that needs root: which program holds a port. It prints
/// `key=value` lines, which `read` takes and `verdict` judges, so every rule here is proved without a server. The same
/// script is the first step of both installs (`InstallPlan.hub`, `InstallPlan.join`), so the install checks the
/// server the screen checked.
public enum ServerCheck {
    /// The install step that runs the check, as the plans and their failures name it.
    public static let title = "Read the server"

    /// What the server must reach over HTTPS and IPv4: the code (GitHub), Tailscale's installer, and the two providers'
    /// runtimes and sign-ins.
    public static let hosts = ["github.com", "tailscale.com", "claude.ai", "chatgpt.com"]

    /// **First estimates**, to be set by what real servers do: about 1 GB of memory for the fleet's own VPS (the hub),
    /// about 2 GB for a server that runs agents, and 10 GB of free disk for the code, the runtimes and their updates. A
    /// plan sold as 1 GB reports some 950 MB to its system, so each floor sits a little under its round number.
    static let hubMemory = (megabytes: 900, words: "1 GB")
    static let agentMemory = (megabytes: 1800, words: "2 GB")
    static let freeDisk = (megabytes: 10 * 1024, words: "10 GB")

    /// While a server is busy with its first start, the install's own check reads it again this often, and this long.
    static let waitEvery = 15.0
    static let waitWithin = 1200.0

    /// The two kinds of machine the installers take, as `uname -m` says them, and as the summary says them.
    static let architectures = ["x86_64": "x86", "aarch64": "Arm"]

    // MARK: - The script

    /// **The script, read by `sh -s` from standard input**, so no shell on the server parses it as an argument, and
    /// wrapped in one block whose own input is `/dev/null`, so no program in it can eat the rest of it.
    ///
    /// Every key it prints, one per line: `user`, `uid`, `sudo` (`root`, `nopasswd`, `password` or `none`), `os_id`,
    /// `os_version` and `os_name` (`/etc/os-release`'s `ID`, `VERSION_ID` and `NAME`), `arch`, `memory_mb`,
    /// `disk_free_mb` (on /), `systemd` and `ipv4_route` (`yes` or `no`), one `reach=<host> yes|no|none` for each of
    /// `hosts` (`none`: neither curl nor wget is there, and the install brings curl), `cloud_init` (`running`, `done` or
    /// `none`), `dpkg_lock` (`yes` or `no`), one `listen=<proto>/<port>/<process>` for each port open to more than this
    /// machine and the private network (the process is `-` where only root may see it), `ufw` (`active`, `inactive` or
    /// `absent`), `tailscale` (`none`, `loggedout` or `running`) with `tailnet=<name>` when it runs, and `end=yes` last,
    /// so a reading that was cut short is no reading.
    ///
    /// The paths it reads start with `$FOUNDERIZER_CHECK_ROOT`, which no server sets: the tests give it a folder that
    /// stands for a machine, as `hub.sh` takes a root of its own.
    public static let script = #"""
    {
    PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; export PATH
    r="${FOUNDERIZER_CHECK_ROOT:-}"
    limited() { if command -v timeout >/dev/null 2>&1; then timeout 10 "$@"; else "$@"; fi; }
    uid=$(id -u)
    echo "user=$(id -un)"
    echo "uid=$uid"
    if [ "$uid" = 0 ]; then sudo=root
    elif ! command -v sudo >/dev/null 2>&1; then sudo=none
    elif sudo -n true >/dev/null 2>&1; then sudo=nopasswd
    elif id -nG | tr ' ' '\n' | grep -qx -e sudo -e admin -e wheel; then sudo=password
    else sudo=none; fi
    echo "sudo=$sudo"
    for f in "$r/etc/os-release" "$r/usr/lib/os-release"; do
        if [ -r "$f" ]; then (. "$f"; echo "os_id=${ID:-}"; echo "os_version=${VERSION_ID:-}"; echo "os_name=${NAME:-}"); break; fi
    done
    echo "arch=$(uname -m)"
    echo "memory_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' "$r/proc/meminfo" 2>/dev/null)"
    echo "disk_free_mb=$(df -Pk / 2>/dev/null | awk 'NR == 2 {print int($4 / 1024)}')"
    if [ -d "$r/run/systemd/system" ]; then echo systemd=yes; else echo systemd=no; fi
    if awk 'NR > 1 && $2 == "00000000" {f = 1} END {exit !f}' "$r/proc/net/route" 2>/dev/null; then echo ipv4_route=yes
    else echo ipv4_route=no; fi
    if command -v curl >/dev/null 2>&1; then fetch=curl; elif command -v wget >/dev/null 2>&1; then fetch=wget; else fetch=none; fi
    reach() {
        case $fetch in
            curl) if curl -4 -s -I -o /dev/null -m 5 "https://$1/"; then said=yes; else said=no; fi ;;
            wget) wget -4 -q --spider -T 5 -t 1 "https://$1/"; case $? in 0|8) said=yes ;; *) said=no ;; esac ;;
            *) said=none ;;
        esac
        echo "reach=$1 $said"
    }
    for h in github.com tailscale.com claude.ai chatgpt.com; do reach "$h" & done
    wait
    if command -v cloud-init >/dev/null 2>&1; then
        case $(limited cloud-init status 2>/dev/null | sed -n 's/^status: *//p' | head -n 1) in
            running|"degraded running") echo cloud_init=running ;;
            done|error|"degraded done") echo cloud_init=done ;;
            *) echo cloud_init=none ;;
        esac
    else echo cloud_init=none; fi
    lock=no
    for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
        i=$(stat -c %i "$r$f" 2>/dev/null) || continue
        awk -v i="$i" '{for (k = 1; k <= NF; k++) if ($k ~ /^[0-9a-f]+:[0-9a-f]+:[0-9]+$/) {split($k, a, ":"); if (a[3] == i) f = 1}}
            END {exit !f}' "$r/proc/locks" 2>/dev/null && lock=yes
    done
    echo "dpkg_lock=$lock"
    if command -v ss >/dev/null 2>&1; then
        case $sudo in
            root) ss -H -tulpn ;;
            nopasswd) sudo -n ss -H -tulpn ;;
            *) ss -H -tuln ;;
        esac 2>/dev/null | awk '
        { at = $5; port = at; sub(/.*:/, "", port)
          host = substr(at, 1, length(at) - length(port) - 1)
          gsub(/\[/, "", host); gsub(/\]/, "", host); sub(/%.*/, "", host); split(host, o, ".")
          if (host ~ /^127\./ || host == "::1" || host ~ /^::ffff:127\./ || host ~ /^169\.254\./ || host ~ /^fe[89ab]/ ||
              (o[1] == 100 && o[2] >= 64 && o[2] <= 127) || host ~ /^fd7a:115c:a1e0:/) next
          name = "-"; if (match($0, /\(\("[^"]*"/)) name = substr($0, RSTART + 3, RLENGTH - 4)
          print "listen=" $1 "/" port "/" name }' | sort -u
    fi
    if [ -x "$r/usr/sbin/ufw" ] || command -v ufw >/dev/null 2>&1; then
        if grep -qs '^ENABLED=yes' "$r/etc/ufw/ufw.conf"; then echo ufw=active; else echo ufw=inactive; fi
    else echo ufw=absent; fi
    if command -v tailscale >/dev/null 2>&1; then
        status=$(limited tailscale status --json 2>/dev/null)
        case $status in
            *'"BackendState": "Running"'*) echo tailscale=running
                printf '%s\n' "$status" | awk '/"CurrentTailnet"/ {t = 1}
                    t && /"Name":/ {sub(/^[^:]*: *"/, ""); sub(/".*$/, ""); print "tailnet=" $0; exit}' ;;
            *) echo tailscale=loggedout ;;
        esac
    else echo tailscale=none; fi
    echo end=yes
    } </dev/null
    """#

    // MARK: - What it read

    /// One server, as the script read it.
    public struct Reading: Equatable, Sendable {
        /// How the user this Mac logs in as becomes root: it is root, its `sudo` asks nothing, its `sudo` asks for a
        /// password, or it has no `sudo` at all.
        public enum Sudo: String, Equatable, Sendable { case root, nopasswd, password, none }
        /// Whether the server reached a host over HTTPS: `none` when it has neither curl nor wget to try with.
        public enum Reach: String, Equatable, Sendable { case yes, no, none }
        public enum CloudInit: String, Equatable, Sendable { case running, done, none }
        public enum Firewall: String, Equatable, Sendable { case active, inactive, absent }
        public enum Tailscale: Equatable, Sendable { case none, loggedOut, running(tailnet: String?) }
        /// One port open to more than the machine itself and the private network, and the program that holds it.
        public struct Listener: Equatable, Hashable, Sendable {
            public let proto: String
            public let port: Int
            /// The program's own name, or `-` where the user this Mac logs in as may not see it.
            public let process: String
        }

        public var user: String
        public var uid: Int
        public var sudo: Sudo
        /// `ID`, `VERSION_ID` and `NAME` of `/etc/os-release`: "ubuntu", "24.04", "Ubuntu".
        public var system: String
        public var version: String
        public var systemName: String
        /// `uname -m`: "x86_64" or "aarch64" on a machine the installers take.
        public var arch: String
        public var memoryMB: Int?
        public var diskFreeMB: Int?
        public var systemd: Bool
        public var ipv4Route: Bool
        public var reach: [String: Reach]
        public var cloudInit: CloudInit
        public var dpkgLock: Bool
        public var listeners: [Listener]
        public var firewall: Firewall
        public var tailscale: Tailscale
    }

    /// The script's answer as values, or nil when it is not one: a user, a uid and its last line are the least of it.
    /// Lines of anything else (a shell's or `sudo`'s own words on standard error) are left out.
    public static func read(_ output: String) -> Reading? {
        var one: [String: String] = [:], reach: [String: Reading.Reach] = [:], listeners: [Reading.Listener] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { continue }
            let key = String(line[..<equals]), value = String(line[line.index(after: equals)...])
            switch key {
            case "reach":
                let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, hosts.contains(parts[0]), let said = Reading.Reach(rawValue: parts[1]) {
                    reach[parts[0]] = said
                }
            case "listen":
                let parts = value.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3, ["tcp", "udp"].contains(parts[0]), let port = Int(parts[1]),
                      (1...65535).contains(port),
                      !listeners.contains(where: { $0.proto == parts[0] && $0.port == port }) else { continue }
                listeners.append(Reading.Listener(proto: parts[0], port: port, process: parts[2].isEmpty ? "-" : parts[2]))
            default:
                if one[key] == nil { one[key] = value }
            }
        }
        guard one["end"] == "yes", let user = one["user"], !user.isEmpty, let uid = one["uid"].flatMap({ Int($0) }) else {
            return nil
        }
        let tailscale: Reading.Tailscale
        switch one["tailscale"] {
        case "running": tailscale = .running(tailnet: one["tailnet"].flatMap { $0.isEmpty ? nil : $0 })
        case "loggedout": tailscale = .loggedOut
        default: tailscale = .none
        }
        return Reading(user: user, uid: uid, sudo: one["sudo"].flatMap(Reading.Sudo.init(rawValue:)) ?? .none,
                       system: one["os_id"] ?? "", version: one["os_version"] ?? "", systemName: one["os_name"] ?? "",
                       arch: one["arch"] ?? "", memoryMB: one["memory_mb"].flatMap { Int($0) },
                       diskFreeMB: one["disk_free_mb"].flatMap { Int($0) }, systemd: one["systemd"] == "yes",
                       ipv4Route: one["ipv4_route"] == "yes", reach: reach,
                       cloudInit: one["cloud_init"].flatMap(Reading.CloudInit.init(rawValue:)) ?? .none,
                       dpkgLock: one["dpkg_lock"] == "yes", listeners: listeners.sorted { ($0.proto, $0.port) < ($1.proto, $1.port) },
                       firewall: one["ufw"].flatMap(Reading.Firewall.init(rawValue:)) ?? .absent, tailscale: tailscale)
    }

    // MARK: - The verdict

    /// What the password is for, where the server asks for one: SSH itself, which takes none of this Mac's keys, or
    /// the `sudo` of the user this Mac logs in as (`PasswordOnce`).
    public enum PasswordNeed: String, Equatable, Sendable { case ssh, sudo }

    /// **The one answer of a check.**
    public enum Verdict: Equatable, Sendable {
        /// The install can start. `summary` is the server in a few words ("Ubuntu 24.04 · 4 GB · x86"), and `changes`
        /// the one line of what the install changes ("SSH moves to Tailscale. Ports 80 and 443 stay open.").
        case ready(summary: String, changes: String)
        /// The server is busy with its first start, and says with what. The same check later answers again.
        case wait(String)
        /// The server asks for a password this Mac does not hold.
        case needsPassword(PasswordNeed)
        /// The install cannot go on this server: one plain line of the cause and the fix.
        case stop(String)
    }

    /// **The verdict on one reading.** The stops come first, from what no wait can change to what the owner changes at
    /// his provider; then the password he gives; then the wait for a server that is still starting.
    ///
    /// `sshPort` is the port this Mac reaches the server on, which the install moves to the private network and so is
    /// not one of the ports that stay open. `holdsSudoPassword`: this install already holds the password of a `sudo`
    /// that asks for one. `tailnet` is the name of the fleet's own Tailscale network, where it is known.
    public static func verdict(_ reading: Reading, job: InstallJob, sshPort: Int = 22, holdsSudoPassword: Bool = false,
                               tailnet: String? = nil) -> Verdict {
        guard let system = InstallPlan.systems(job).first(where: { $0.id == reading.system && $0.version == reading.version })
        else { return .stop(job == .hub ? InstallPlan.hubSystems : InstallPlan.joinSystems) }
        guard let arch = architectures[reading.arch] else {
            let kind = reading.arch.isEmpty ? "of an unknown kind" : "a \(reading.arch) machine"
            return .stop("This server is \(kind), and this install needs a 64-bit x86 or Arm server.")
        }
        guard reading.systemd else {
            return .stop("This server does not run systemd, and this install needs a full VPS that does.")
        }
        if reading.sudo == .none { return .stop(notRoot(reading.user)) }
        let memory = job == .hub ? hubMemory : agentMemory
        if let have = reading.memoryMB, have < memory.megabytes {
            let what = job == .hub ? "the hub" : "a server for agents"
            return .stop("This server has \(size(have)) of memory, and \(what) needs about \(memory.words). "
                         + "Choose a plan with more memory.")
        }
        if let free = reading.diskFreeMB, free < freeDisk.megabytes {
            return .stop("This server has \(size(free)) of free disk, and the install needs about \(freeDisk.words). "
                         + "Free some space, or choose a bigger disk.")
        }
        guard reading.ipv4Route else {
            return .stop("This server has no IPv4 route, and GitHub answers over IPv4 only. "
                         + "Give it a public IPv4 address at your provider.")
        }
        // The fleet's own VPS runs no agent, so it needs neither AI's site. A server for agents needs the site of the
        // AI its agents run, which each agent's own page chooses later, so either one of the two is enough here.
        let ai = ["claude.ai", "chatgpt.com"]
        var unreached = hosts.filter { !ai.contains($0) && reading.reach[$0] == .no }
        if job == .join, ai.allSatisfy({ reading.reach[$0] == .no }) { unreached += ai }
        if !unreached.isEmpty {
            return .stop("This server cannot reach \(spoken(unreached, "or")) over HTTPS. Let it make outgoing HTTPS connections.")
        }
        if let tailnet, case .running(let theirs?) = reading.tailscale, theirs.lowercased() != tailnet.lowercased() {
            return .stop("This server is on another Tailscale network, \(theirs). Run tailscale logout on it, then check again.")
        }
        if reading.sudo == .password && !holdsSudoPassword { return .needsPassword(.sudo) }
        if reading.cloudInit == .running { return .wait("The server is still setting itself up after its first start.") }
        if reading.dpkgLock { return .wait("The server is installing its updates.") }
        return .ready(summary: "\(system.name) \(system.version) · \(roundGigabytes(reading.memoryMB)) · \(arch)",
                      changes: changes(reading, sshPort: sshPort))
    }

    /// **What the install changes, in one line**: SSH moves onto the private network, and every other TCP port that was
    /// open before stays open (the installers' firewall keeps each port that answered before the install, except SSH).
    static func changes(_ reading: Reading, sshPort: Int) -> String {
        let moves = "SSH moves to Tailscale."
        let ports = Set(reading.listeners.filter { $0.proto == "tcp" && $0.port != sshPort && !["sshd", "ssh"].contains($0.process) }
            .map(\.port)).sorted()
        switch ports.count {
        case 0: return moves
        case 1: return moves + " Port \(ports[0]) stays open."
        default: return moves + " Ports \(spoken(ports.map(String.init), "and")) stay open."
        }
    }

    // MARK: - The words

    /// The words of a user that cannot become root, the same as the install's own (`InstallError.notRoot`).
    public static func notRoot(_ user: String) -> String {
        "The user \(user) is not root on that server. Give a user that is root, or that can become root."
    }

    /// The words of a server that SSH did not reach at all, and of one that took none of this Mac's keys and takes no
    /// password either: the same as a stopped install's (`InstallError.plain`).
    public static func unreached(_ server: String) -> String { "This Mac could not reach \(server) over SSH." }
    public static func keyRefused(_ server: String) -> String { "\(server) did not take your SSH key. Choose its key." }
    /// A server whose host key is not the one this Mac kept for it: rebuilt, or not the server it was.
    public static func hostKeyChanged(_ server: String) -> String {
        "\(server) answers with another host key than this Mac knows. If the server was rebuilt, run "
            + "ssh-keygen -R \(server) on this Mac, then check again."
    }
    /// A server that took the connection and printed no reading.
    public static func noAnswer(_ server: String) -> String {
        "\(server) did not answer the check. Give a user that can run commands there."
    }

    /// "80 and 443", "github.com, claude.ai or chatgpt.com".
    static func spoken(_ items: [String], _ last: String) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(last) " + items[items.count - 1]
    }

    /// "640 MB", "1,9 GB": a size in this Mac's own numbers, as a server's page says one (`LoadWords.memory`).
    static func size(_ megabytes: Int) -> String { LoadWords.memory(Double(megabytes) * 1024 * 1024) }

    /// "4 GB": the memory of a plan in the round figure it is sold by.
    static func roundGigabytes(_ megabytes: Int?) -> String {
        guard let megabytes else { return "memory not read" }
        return "\(max(1, Int((Double(megabytes) / 1024).rounded()))) GB"
    }
}

#if os(macOS)
/// One program on this Mac and its answer: `LocalShell.run` in the app, a stand-in in the tests.
public typealias ShellRunner = @Sendable (_ executable: String, _ arguments: [String], _ stdin: Data?,
                                          _ timeout: Double) async throws -> LocalShell.Answer

public enum Shell {
    /// This Mac's own programs.
    public static let local: ShellRunner = { executable, arguments, stdin, timeout in
        try await LocalShell.run(executable, arguments, stdin: stdin, timeout: timeout)
    }
}

extension ServerCheck {
    /// One check and what it read: nil when the server could not be read at all.
    public struct Result: Equatable, Sendable {
        public let verdict: Verdict
        public let reading: Reading?
        /// The server as the check reached it: the target it was given, or that target with the key file of this Mac
        /// that let the check in (`keyFiles`), which the install then uses too.
        public let target: InstallTarget
    }

    /// **One check of one server**: one SSH session over the route the install uses (`InstallPlan.arguments`), as the
    /// user this Mac logs in as, with the script on standard input.
    ///
    /// **A refused key is not yet the end** (the proof run of 5 November 2026): a Mac whose SSH agent holds many keys,
    /// four Teleport identities there, offers them all first, and a server that lets six tries in hangs up before
    /// `~/.ssh/id_ed25519` comes. So this Mac's own key files in `keys` then go one at a time, each alone
    /// (`IdentitiesOnly`), before anything asks for a password, and the first that lets the check in is the target's
    /// key from then on (`Result.target`).
    ///
    /// Where SSH itself stops, its words say why: a server it did not reach, one with another host key, and one that
    /// took none of this Mac's keys. That last one asks for the password once (`PasswordOnce`) when the server lists a
    /// password among the ways it lets a user in, or when it hung up after too many keys before it said; a server that
    /// takes keys only stops with the install's own words for a refused key. `holdsSudoPassword` and `tailnet` are
    /// `verdict`'s.
    public static func run(_ target: InstallTarget, job: InstallJob, holdsSudoPassword: Bool = false, tailnet: String? = nil,
                           keys: URL = InstallTarget.keyFolder, ssh: String = "/usr/bin/ssh",
                           run: ShellRunner = Shell.local) async -> Result {
        var answer: LocalShell.Answer
        do {
            answer = try await session(target, job: job, ssh: ssh, run: run)
        } catch {
            return Result(verdict: .stop((error as? LocalizedError)?.errorDescription ?? unreached(target.host)), reading: nil,
                          target: target)
        }
        var reached = target
        if answer.status == 255, InstallError.keyRefused(answer.output) {
            for key in keyFiles(in: keys) where key != target.identityFile {
                var keyed = target
                keyed.identityFile = key
                guard let tried = try? await session(keyed, job: job, ssh: ssh, run: run), tried.status != 255 else { continue }
                answer = tried; reached = keyed
                break
            }
        }
        // 255 is `ssh` itself: the script ends with its own status, which is 0. Where no key file let the check in, the
        // words of the first session say why.
        if answer.status == 255 {
            return Result(verdict: sshRefused(answer.output, host: target.host), reading: nil, target: target)
        }
        guard let reading = read(answer.output) else {
            return Result(verdict: .stop(noAnswer(target.host)), reading: nil, target: reached)
        }
        return Result(verdict: verdict(reading, job: job, sshPort: target.port, holdsSudoPassword: holdsSudoPassword,
                                       tailnet: tailnet), reading: reading, target: reached)
    }

    /// One session of the check: the script on standard input, as the user this Mac logs in as.
    private static func session(_ target: InstallTarget, job: InstallJob, ssh: String,
                                run: ShellRunner) async throws -> LocalShell.Answer {
        let plan = InstallPlan(job: job, target: target, steps: [], redactions: [])
        return try await run(ssh, plan.arguments(for: "/bin/sh -s", runs: .login), Data(script.utf8), 120)
    }

    /// **This Mac's own private keys, in the order a check tries them alone**: the names `ssh-keygen` gives them, then
    /// the app's own (`AppSSHKey`). Only the files that are there, and only their paths: `ssh` reads them, nothing here.
    static func keyFiles(in folder: URL) -> [String] {
        (["id_ed25519", "id_ecdsa", "id_rsa"].map { folder.appendingPathComponent($0).path } + [AppSSHKey.path(in: folder)])
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// What `ssh`'s own words say when it did not let the script run. Words it has no rule for are a server it did not
    /// reach, as a stopped install says them.
    static func sshRefused(_ output: String, host: String) -> Verdict {
        let said = output.lowercased()
        if said.contains("host key verification failed") || said.contains("remote host identification has changed") {
            return .stop(hostKeyChanged(host))
        }
        if let denied = said.range(of: "permission denied (") {
            let ways = said[denied.upperBound...].prefix { $0 != ")" }
            return ways.contains("password") || ways.contains("keyboard-interactive") ? .needsPassword(.ssh)
                : .stop(keyRefused(host))
        }
        // An agent with many keys offers them all, and the server hangs up before it says what else it takes.
        if said.contains("too many authentication failures") { return .needsPassword(.ssh) }
        return .stop(unreached(host))
    }
}
#endif
