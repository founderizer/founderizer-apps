import CryptoKit
import Foundation

/// **The agents' browser parts on a Linux server, put in place and taken away by the owner's Mac** (the owner's "Every
/// agent with shell" of 17 November 2026; build plan 04, slice S1b, decisions D11 to D15).
///
/// An agent with the Browser box on a Linux worker gets a Chrome of its own there (S2). Its parts need root: Google's
/// Chrome with its APT source and key, Xvfb, Openbox, x11vnc, nftables, the fonts, Chrome's policies, the agents' ports
/// and the fleet's own nftables table that guards them. No agent exists when a server joins, and the hub's own server
/// gets no browser, so the parts come only from here, by themselves, as part 1's memory limit does (`ServerMemory`):
/// over the root connection that this Mac already has to each Linux server (`OwnerAccessModel`), with a log line only.
/// The devops repository's `scripts/fleet-browser/README.md` is the contract of each root file's bytes, which a checker
/// on the fleet's workers holds too; this file's tests hold the same bytes.
///
/// - **When.** A Linux server that joined and is not the hub's own, whose service's current reading carries the parts
///   (`ServerReading.browser`, owner API 1.224), with no open job of its service, no task that makes the step wait (a
///   task in state working whose `works` is not false) and not in the hour after its join (`work`). Never on a server
///   that reads `unsupported` (x86 Ubuntu 24.04 and 26.04 only). It installs where an agent there has the Browser box
///   and the Shell box and runs as its own OS user (`wanted`), and a part is missing, a file is not this app's, the
///   table's unit does not run or the live proof found the table gone; it writes the agents' ports and the table again
///   where they differ from the wanted agents (the vault's broker can come to a server after its parts); and it takes
///   the parts away where no agent there wants them.
/// - **What.** `program`, as root: it starts the step in a transient system unit of its own, with its own memory
///   limit, a low CPU priority and idle disk priority (part 1 gives `system.slice` no limit), and ends at once. The
///   step reads nothing of the server's own checkout and changes only what differs. A package system that another
///   program holds fails the step at once: no wait for the lock. The step records each package that it added, and its
///   removal takes away only those that nothing else needs now (never one that the server had before, Chrome with
///   `purge`), and its own files. `libatomic1` and `nftables` go in and are never recorded (below).
/// - **How often.** The same want in two rounds in a row runs the program (`turn`). Each start is a try, ten minutes
///   apart and six at most for one want (`VaultTries`), kept on this Mac across launches (`Memory`); a step that still
///   runs is no try. The next run reads what the step before it said. A new want (a tick, an untick, a new agent, a
///   new broker, a new list of providers) starts the count again, and a reading that matches the want ends it.
public enum ServerBrowser {
    // MARK: the contract

    public static let unitPath = "/etc/systemd/system/fleet-browser-ports.service"
    public static let dropinPath = "/etc/systemd/system/nftables.service.d/fleet-browser.conf"
    public static let defaultPath = "/etc/default/google-chrome"
    public static let originPath = "/etc/apt/apt.conf.d/53fleet-google-chrome"
    public static let fixedPath = "/etc/opt/chrome/policies/managed/fleet-fixed.json"
    public static let policyPath = "/etc/opt/chrome/policies/managed/fleet-providers.json"
    public static let portsPath = "/etc/fleet-browser/ports"
    public static let tablePath = "/etc/fleet-browser/table.nft"
    public static let sourcePath = "/etc/apt/sources.list.d/google-chrome.sources"
    public static let keyPath = "/usr/share/keyrings/google-chrome.gpg"
    /// What the server's reading names each of them (`lifecycle.BROWSER_PARTS`).
    public static let parts = ["unit": unitPath, "dropin": dropinPath, "default": defaultPath, "origin": originPath,
                               "fixed": fixedPath, "policy": policyPath, "ports": portsPath, "table": tablePath,
                               "source": sourcePath, "key": keyPath]
    /// `lifecycle.BROWSER_PACKAGES`.
    public static let packages = ["google-chrome-stable", "xvfb", "xauth", "openbox", "x11vnc", "ffmpeg", "nftables",
                                  "fonts-noto-core", "fonts-noto-color-emoji", "libatomic1"]
    /// Installed, and never recorded as added, so that no removal takes them away: `libatomic1`, which every npm
    /// program of the fleet needs (plan 04, D13), and `nftables`, which other parts of the fleet use too (the outgoing
    /// gate): its removal would stop `nftables.service`, whose stop flushes every table of the server.
    static let keptPackages = ["libatomic1", "nftables"]
    static let broker = "fleet-vault"

    /// The table's unit: devops's `fleet-browser-ports.service`, pinned there. It loads the table at boot, and again
    /// at each reload of `nftables.service` (`ReloadPropagatedFrom=`, which no drop-in can take away); after a start
    /// and a stop of `nftables.service` the drop-in loads it (`dropinText`). A stop of `nftables.service` does not
    /// stop this unit, so its own stop never deletes the table then.
    public static let unitText = """
        [Unit]
        Description=Founderizer browser ports: the fleet's own nftables table for the agents' browser ports
        After=nftables.service
        ReloadPropagatedFrom=nftables.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/sbin/nft -f /etc/fleet-browser/table.nft
        ExecReload=/usr/sbin/nft -f /etc/fleet-browser/table.nft
        ExecStop=-/usr/sbin/nft delete table inet fleet_browser

        [Install]
        WantedBy=multi-user.target nftables.service

        """
    /// **The table again after each start, reload and stop of `nftables.service`** (devops's `fleet-browser.conf`):
    /// each of them flushes the whole ruleset, and a start of an inactive `nftables.service` (Ubuntu's own is not
    /// enabled) left the table's unit active with no table, which the server's live proof found only at its next
    /// reading (live, 17 November 2026; the outgoing gate's lane found it). Its own file in that folder: other parts of
    /// the fleet put theirs beside it. A later drop-in that empties one of these lists takes its line away; the
    /// server's reading reads the lists that systemd runs (`lifecycle.browser_reading`), and then names the drop-in
    /// missing.
    public static let dropinText = """
        # Founderizer's browser parts: each start, reload and stop of nftables.service flushes the whole ruleset, so
        # the fleet's own table of the agents' browser ports is loaded again after each of them (plan 04, D11).
        [Service]
        ExecStartPost=-/usr/sbin/nft -f /etc/fleet-browser/table.nft
        ExecReload=-/usr/sbin/nft -f /etc/fleet-browser/table.nft
        ExecStopPost=-/usr/sbin/nft -f /etc/fleet-browser/table.nft

        """
    /// Chrome's daily job adds no source of its own (devops's `google-chrome.default`).
    public static let defaultText = "repo_add_once=\"false\"\nrepo_reenable_on_distupgrade=\"false\"\n"
    /// Unattended upgrades take Chrome's updates (devops's `53fleet-google-chrome`).
    public static let originText = """
        // Founderizer's browser parts, written and removed with them by the owner's Mac:
        // unattended upgrades take Google Chrome's updates too.
        Unattended-Upgrade::Origins-Pattern {
                "origin=Google LLC,codename=stable,label=Google";
        };

        """
    /// The fixed Chrome policy (devops's `fleet-fixed.json`; plan 04, D12).
    public static let fixedText = "{\"RestoreOnStartup\": 1, \"PasswordManagerEnabled\": false, \"BrowserSignin\": 0, "
        + "\"SyncDisabled\": true, \"DiskCacheSize\": 104857600}\n"
    /// Chrome's package's own APT source, which the step writes before the first install and the package then owns
    /// (devops's `contract/google-chrome.sources`; plan 04, D13).
    public static let sourceText = """
        ### THIS FILE IS AUTOMATICALLY CONFIGURED ###
        # Changes to this file will not be preserved.
        # This file will not be recreated if removed.
        X-Repolib-Name: Google Chrome
        Types: deb
        URIs: https://dl.google.com/linux/chrome-stable/deb/
        Suites: stable
        Components: main
        Architectures: amd64
        Signed-By: /usr/share/keyrings/google-chrome.gpg

        """
    /// **The policy from this app's own lists** (`ProviderSites`, which the app's tests keep equal to `vault.py`): no
    /// agent opens a file of its server, Chrome's password manager or a provider's sign-in, and the providers' consoles
    /// stay open (plan 04, D12). The format of devops's `contract/providers.json`.
    public static var policyText: String {
        func list(_ items: [String]) -> String { "[" + items.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }
        return "{\"URLBlocklist\": \(list(["file://*", "chrome://password-manager"] + ProviderSites.sites)), "
            + "\"URLAllowlist\": \(list(ProviderSites.keySites))}\n"
    }
    static let tableComment = "# Founderizer writes this table whole from /etc/fleet-browser/ports (plan 04, D11)."
    /// **Google's signing key, the pinned primary key alone with its subkeys** (plan 04, D13): `gpg --export` of
    /// `EB4C 1BFD 4F04 2F6D DDCC EC91 7721 F63B D38B 4796` from Google's published file of 17 November 2026
    /// (https://dl.google.com/linux/linux_signing_key.pub), which held that one primary key and eight subkeys. The step
    /// writes it only where no key is there; Chrome's package then writes its own key data at that path, with Google's
    /// newer subkeys.
    static let keyData = Data(base64Encoded: [
        "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",
        "a2N+cNFSkXzUmw0Rj/iUmZcSITcM8QOSK6U="].joined())!

    /// **One agent's two ports** (a line of `/etc/fleet-browser/ports`).
    public struct Ports: Codable, Equatable, Sendable {
        public let user: String
        public let devtools: Int
        public let screen: Int
        public init(user: String, devtools: Int, screen: Int) {
            self.user = user; self.devtools = devtools; self.screen = screen
        }
    }

    public static let devtoolsPorts = 9300...9399
    public static let screenPorts = 5910...5999

    /// The table of no line, its last rule alone: every port of both ranges closed (the removal's first step).
    static let emptyTable = table([], uids: [:], broker: nil, worker: 0)!

    /// The ports file of these rows.
    public static func portsText(_ rows: [Ports]) -> String {
        rows.map { "\($0.user) \($0.devtools) \($0.screen)\n" }.joined()
    }

    /// **The table of these rows**, byte for byte as the contract gives it. Each rule holds only for a packet to this
    /// server itself (`oifname "lo"`: also one to its own public address), so a connection to another host on a port of
    /// these ranges, and a reply to a remote client's port, are left alone. Each DevTools port refuses every user but
    /// root, the broker and the agent with a reset; each screen-sharing port every user but root and the worker user; a
    /// packet from either port whose socket is not the agent's is dropped; and what is left for the agent's two ports
    /// passes (`accept`). The last rule refuses each new connection to every other port of both ranges, to every user
    /// (a SYN without its ACK: a packet of a connection that the rules let in before, or one with no socket, is left
    /// alone), so a port whose row went
    /// is closed, never open: a Browser or Shell box that goes off takes the row away at the next round, while the
    /// agent's Chrome can still run for an open task (the S3b review, rounds 3 and 4). So both ranges are reserved
    /// for the agents' browsers on this server. nil where a row's user has no uid.
    public static func table(_ rows: [Ports], uids: [String: Int], broker: Int?, worker: Int) -> String? {
        var lines = [tableComment, "table inet fleet_browser", "delete table inet fleet_browser",
                     "table inet fleet_browser {", "\tchain out {", "\t\ttype filter hook output priority 0; policy accept;"]
        for row in rows {
            guard let uid = uids[row.user] else { return nil }
            let allowed = ([0] + (broker.map { [$0] } ?? []) + [uid]).map(String.init).joined(separator: ", ")
            lines += ["\t\toifname \"lo\" tcp dport \(row.devtools) meta skuid != { \(allowed) } reject with tcp reset",
                      "\t\toifname \"lo\" tcp dport \(row.screen) meta skuid != { 0, \(worker) } reject with tcp reset",
                      "\t\toifname \"lo\" tcp sport { \(row.devtools), \(row.screen) } meta skuid != \(uid) drop",
                      "\t\toifname \"lo\" tcp dport { \(row.devtools), \(row.screen) } accept"]
        }
        lines.append("\t\toifname \"lo\" tcp flags & (syn | ack) == syn tcp dport { \(screenPorts.lowerBound)-\(screenPorts.upperBound), "
                     + "\(devtoolsPorts.lowerBound)-\(devtoolsPorts.upperBound) } reject with tcp reset")
        return (lines + ["\t}", "}"]).joined(separator: "\n") + "\n"
    }

    /// **The rows for the wanted users**: each row of a user that is still wanted keeps its place and its ports, the
    /// rows of the others go, and each new user takes the lowest ports that no row of `current` has (so that a port
    /// given up now goes to nobody else in the same step). As many new users as there are free ports.
    public static func assign(_ current: [Ports], wanted: [String]) -> [Ports] {
        let want = Set(wanted)
        var rows = current.filter { want.contains($0.user) }
        var devtools = Set(current.map(\.devtools)), screens = Set(current.map(\.screen))
        for user in wanted where !rows.contains(where: { $0.user == user }) {
            guard let next = devtoolsPorts.first(where: { !devtools.contains($0) }),
                  let screen = screenPorts.first(where: { !screens.contains($0) }) else { break }
            rows.append(Ports(user: user, devtools: next, screen: screen))
            devtools.insert(next)
            screens.insert(screen)
        }
        return rows
    }

    // MARK: when

    /// **The OS users of the agents on this server that want a browser**, in the order of the server's agents: the
    /// Browser box and the Shell box on (no Linux browser for a closed agent, plan 04, D2), and a user of its own there
    /// by the server's reading, which is neither the server service's user (one uid for several agents: no browser)
    /// nor the vault broker's. An agent whose user is not made yet (the reading names it with no user) is not among
    /// them. **nil where the reading does not name such an agent at all**: a reading from before the agent came, or
    /// from a service that started again under another name and reads no agent yet. Then the round does nothing, and
    /// never takes the parts or an agent's ports away for an agent that it cannot see.
    public static func wanted(on server: ServerEntry, agents: [FleetAgent]) -> [String]? {
        guard let reading = server.reading, let users = reading.agents?.users else { return nil }
        let byName = Dictionary(agents.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [String] = []
        for name in server.agents {
            guard let agent = byName[name], agent.can.contains("browser"), agent.can.contains("shell") else { continue }
            guard let entry = users[name] else { return nil }
            guard let user = entry.user, user != reading.user, user != broker, !out.contains(user),
                  user.range(of: "^fleet-[a-z][a-z0-9-]{1,25}$", options: .regularExpression) != nil else { continue }
            out.append(user)
        }
        return out
    }

    /// What the parts of one server need now.
    public enum Work: Equatable, Sendable {
        /// They are as they should be: no agent wants them and none is there, or they are all in place.
        case nothing
        case install(Want)
        case remove

        /// What the count of tries is of: the same want keeps its count, and a new one starts it again.
        public var digest: String? {
            switch self {
            case .nothing: nil
            case .install(let want): want.digest
            case .remove: "remove"
            }
        }
    }

    /// **The parts as the wanted agents need them**: their ports, the table of those ports, the users and their uids
    /// that the table was made from (the step checks them again on the server, where a user can have been made again
    /// since the reading), the broker's uid, and the worker user, whose live proof gets a folder of its own.
    public struct Want: Equatable, Sendable {
        public let rows: [Ports]
        public let table: String
        public let uids: [String: Int]
        public let broker: Int?
        public let worker: String
        public let workerID: Int

        public var digest: String {
            let users = rows.map { "\($0.user) \(uids[$0.user] ?? -1)" }.joined(separator: ",")
            let text = [portsText(rows), table, policyText, users, broker.map(String.init) ?? "-", worker,
                        String(workerID)].joined(separator: "\u{1}")
            return String(hash(text).prefix(16))
        }
    }

    /// The SHA-256 of a text, as the server's reading gives a file's.
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// **What one round does with one server**, or nil where the round says nothing: not a server of this sweep (a Mac,
    /// the hub's own server, a server that did not join), an open job of its service, the hour after its join, a
    /// reading that is not current or not its service's own, a reading without the parts (a server from before owner
    /// API 1.224), a task that makes the step wait, or a want whose users the reading does not name. A task in state
    /// working makes the step wait unless its `works` (owner API 1.147) is false: no turn of it runs and its records
    /// show no open background call (a Codex background shell or a detached process of it does not count). A task with
    /// no `works` (an older hub, a session that has no turn yet) makes it wait, as before. On 19 November 2026 a lead's
    /// task that had done nothing for five hours kept a server's parts out.
    public static func work(for server: ServerEntry, agents: [FleetAgent], tasks: [FleetTask], join: JoinState?,
                            at time: Double) -> Work? {
        guard server.kind == "linux", server.joined, !server.hub, server.job?.isOpen != true else { return nil }
        if let join, join.server == server.name, time - join.created < ServerHardening.joinGrace { return nil }
        guard let reading = server.reading, reading.source == "server", reading.isCurrent(at: time),
              let parts = reading.browser, let state = parts.state else { return nil }
        if state == "unsupported" { return .nothing }
        let here = Set(server.agents)
        guard !tasks.contains(where: { here.contains($0.owner) && $0.state == "working" && $0.works != false }),
              let wanted = wanted(on: server, agents: agents) else { return nil }
        if wanted.isEmpty {
            // Chrome's own files (its source, its key, /etc/default/google-chrome) are not among these: where Chrome stays
        // after a removal (the server had it before, or a package of its own needs it), they stay with it.
        let ours = ["unit", "dropin", "origin", "fixed", "policy", "ports", "table"].contains { parts.files[$0] != nil }
            return parts.added || ours || !(parts.ports ?? []).isEmpty ? .remove : .nothing
        }
        let users = reading.agents?.users ?? [:]
        var uids: [String: Int] = [:]
        for entry in users.values {
            if let user = entry.user, let uid = entry.uid { uids[user] = uid }
        }
        let rows = assign(parts.ports ?? [], wanted: wanted)
        guard let worker = reading.user, let workerID = parts.worker,
              let table = table(rows, uids: uids, broker: parts.broker, worker: workerID) else { return nil }
        let want = Want(rows: rows, table: table, uids: uids.filter { user, _ in rows.contains { $0.user == user } },
                        broker: parts.broker, worker: worker, workerID: workerID)
        let expected = ["unit": hash(unitText), "dropin": hash(dropinText), "default": hash(defaultText),
                        "origin": hash(originText),
                        "fixed": hash(fixedText), "policy": hash(policyText), "ports": hash(portsText(rows)),
                        "table": hash(table)]
        let inPlace = state == "ready" && parts.missing.isEmpty && parts.unit == "active"
            && expected.allSatisfy { parts.files[$0.key] == $0.value }
            && parts.files["source"] != nil && parts.files["key"] != nil && parts.proofKept != false
        return inPlace ? .nothing : .install(want)
    }

    // MARK: how often

    /// What this Mac keeps of one server, from one launch to the next: the want that its tries are of, and the tries.
    public struct Memory: Codable, Equatable, Sendable {
        public var digest = ""
        public var failures = 0
        public var last: Double = 0
        public var reason = ""

        public init(digest: String = "") { self.digest = digest }

        public var tries: VaultTries? {
            failures == 0 ? nil : VaultTries(failures: failures, last: last, reason: reason)
        }

        mutating func tried(at now: Double, reason: String) {
            let next = VaultTries.failed(after: tries, at: now, reason: reason)
            (failures, last, self.reason) = (next.failures, next.last, next.reason)
        }

        /// What this Mac kept of one server, out of the bytes that it kept; a new memory where it kept nothing that
        /// reads.
        public static func kept(_ data: Data?) -> Memory {
            data.flatMap { try? JSONDecoder().decode(Memory.self, from: $0) } ?? Memory()
        }
    }

    /// What one round did with one server.
    public struct Turn: Equatable, Sendable {
        /// The round read work to do: the next round's `seenBefore`, for the same want.
        public var seen = false
        /// What goes to the log, and nowhere else.
        public var lines: [String] = []
    }

    /// **One round's work for one server.** `work` is this round's (`work(for:)`); `memory` is what this Mac keeps of
    /// the server, and the caller keeps it again when this changed it; `unreached` is this launch's tries that ran
    /// nothing on the server, which are never in `memory` (as in `ServerHardening.turn`); `seenBefore` says that the
    /// round before this one read the same want. `connection` gives the connection to the server or throws; `run` runs
    /// a program there as root and gives its output, or throws when `ssh` did not start on this Mac.
    public static func turn(_ work: Work?, memory: inout Memory, unreached: inout VaultTries?, seenBefore: Bool,
                            now: Double, connection: @Sendable () async throws -> InstallTarget,
                            run: @Sendable (InstallTarget, String) async throws -> String) async -> Turn {
        guard let work else { return Turn() }
        guard let digest = work.digest else {
            if memory != Memory() { memory = Memory() }
            return Turn()
        }
        if memory.digest != digest { memory = Memory(digest: digest) }
        guard seenBefore else { return Turn(seen: true) }
        guard unreached?.isDue(at: now) ?? true, memory.tries?.isDue(at: now) ?? true else { return Turn(seen: true) }
        var turn = Turn(seen: true), nothingRan: String?
        do {
            let output = try await run(try await connection(), program(work))
            switch outcome(output) {
            case .started(let last):
                memory.tried(at: now, reason: last.isEmpty ? "started" : "the step before said: \(last)")
                turn.lines.append("a step to \(work == .remove ? "remove" : "put in place") the parts started"
                                  + (last.isEmpty ? "" : "; the step before it said: \(last)"))
            case .running(let last):
                turn.lines.append("a step still runs" + (last.isEmpty ? "" : " (\(last))"))
            case .failed(let said):
                memory.tried(at: now, reason: said)
                turn.lines.append("no step started: \(said)")
            case .notStarted(let said):
                nothingRan = said
            }
        } catch {
            nothingRan = String(describing: error)
        }
        if let nothingRan {
            let tries = VaultTries.failed(after: unreached, at: now, reason: nothingRan)
            unreached = tries
            if tries.givenUp {
                turn.lines.append("nothing ran there in \(tries.failures) tries (\(tries.reason)): "
                                  + "left until this app starts again")
            }
        } else if memory.tries?.givenUp == true {
            turn.lines.append("left after \(memory.failures) tries (\(memory.reason)) until the want changes")
        }
        return turn
    }

    // MARK: what

    /// The first word of the program's last line, and its first line (`ServerHardening.started` says why it has one).
    static let mark = "founderizer-browser"
    public static let started = "founderizer-browser-started"
    /// The transient unit of the step, and its limits.
    static let stepUnit = "fleet-browser-step"
    static let stepLimits = ["MemoryMax=768M", "Nice=10", "IOSchedulingClass=idle", "RuntimeMaxSec=3600"]
    /// The step's folder, its record of what it added, and the live proof's folder (`lifecycle.BROWSER_RECORD`,
    /// `BROWSER_PROOF`).
    static let folder = "/var/lib/fleet-browser"

    /// **The program, as root on the server**: its first line (`started`), what the step before it said (`<want>
    /// <word>` of its result file; a step that ended with no word of its own says `stopped`), and then, unless a step
    /// still runs, the step (`step`) written as root's own file and started in its transient unit. It waits for
    /// nothing: the next round reads the reading, and the next run what the step said. Its last line is `mark` with
    /// `started`, `running` or `failed`, and what the step before it said. It sets its own umask: root's login can have
    /// another, and the worker user must enter the step's folder to keep the live proof there. `root` puts every path
    /// under a folder and `path` is the step's own PATH, for the tests; on a server they are "" and the system's own.
    public static func program(_ work: Work, root: String = "", path: String = "/usr/sbin:/usr/bin:/sbin:/bin") -> String {
        let limits = stepLimits.map { "-p \($0)" }.joined(separator: " ")
        return """
            printf '\\n%s\\n' \(started) || exit 1
            umask 022
            r=\(InstallPlan.quote(root)); d="$r\(folder)"; s="$d/step"; n=
            l=$(head -n 1 "$d/result" 2>/dev/null | tr -cd 'a-z0-9 -')
            if systemctl is-active --quiet \(stepUnit).service 2>/dev/null; then echo "\(mark) running $l"; exit 0; fi
            case "$l" in *' running') l="${l% running} stopped";; esac
            if mkdir -p "$s" && chmod 755 "$d" && chmod 700 "$s" && n=$(mktemp "$s/.run-XXXXXX") \
            && printf '%s' \(InstallPlan.quote(step(work, root: root, path: path))) > "$n" && mv -f "$n" "$s/run.sh"; then
              if o=$(systemd-run --quiet --collect --no-block --unit=\(stepUnit) \(limits) /bin/sh "$s/run.sh" 2>&1); then
                echo "\(mark) started $l"
              else printf '%s\\n' "$o" | tail -n 2; echo "\(mark) failed $l"
              fi
            else [ -z "$n" ] || rm -f "$n"; echo "\(mark) failed $l"
            fi
            """
    }

    /// The lock that the step and the root helper's removal of an agent (`fleet-agent-user --remove=`) take before
    /// they change the ports file and the table, and of which the server service takes a shared hold to read and prove
    /// them: root's file in a folder that only root can write, of mode 640 and of the worker user's group, so that no
    /// agent can open it, and no agent can hold it (`flock` takes a file that is open only to read).
    static let lockPath = "/etc/fleet-browser/lock"

    /// **The step, in its transient unit as root.** It says `running` first, and at its end one word: `ok`, or why it
    /// stopped (`users-changed`, `write-failed`, `apt-busy`, `update-failed`, `install-failed`, `lock-busy`,
    /// `table-failed`, `purge-failed`, `remove-failed`, `units-running`, `ss-failed`). Each file is written whole and moved into place (a policy file
    /// from Chrome's policy folder, so that the checker never meets a file of another name in `managed/`); a file that
    /// holds the text already is left as it is. A package counts as there when it is installed (also on hold) for this
    /// server's architecture or for all.
    ///
    /// **Install**, in the contract's order, so that Chrome never exists without its policies: the users still have
    /// the uids that the table was made from; the folders, the live proof's of the worker user; the APT key and source
    /// where none is there, and `/etc/default/google-chrome` (each recorded where the step made it); the two policies
    /// and the origin file; the packages that are missing, with nothing removed and the server's own configuration
    /// files kept. Each package that came, also one that dpkg left unpacked or half configured and also when the
    /// install stopped part of the way, is recorded against the list of the packages from before the install, and
    /// `requested` where it is one of `packages`; `keptPackages` never. That list goes as the record is written: only a
    /// step that was ended between the two leaves it, and the next step, an install or a removal, records against it
    /// first of all, before anything that could end that step. Then, under the lock and
    /// with the users read again (an agent can be deleted while the packages come), the ports, the table, its unit and
    /// the drop-in for `nftables.service`, then the unit enabled and loaded again.
    ///
    /// **Remove**, in the contract's order: first an empty ports file and the table of no line (its last rule alone,
    /// loaded at once), so that no agent's browser starts any more (a helper's start and the live proof need its line)
    /// and every port of both ranges is closed, as devops's checker takes it; then the browser and screen-sharing units
    /// of every agent user of the server stop, through each user's own systemd where it runs (no user unit runs
    /// without it), also of an agent whose line an earlier round took away, an open task's too; and while anything
    /// still listens on a port of either range the step ends there
    /// (`units-running` and those ports, or `ss-failed` where `ss` did not answer) with those two files in place, so that
    /// a Chrome that an open task keeps never listens with no rule, and a program of another kind on a reserved port
    /// keeps the parts in place (the S3b review, rounds 4 to 6); then the drop-in (and its folder where no other file
    /// is in it), so that no
    /// start of `nftables.service` loads the table again in the middle; the table's unit (which takes the table away),
    /// the table, the ports and the origin file; then Chrome with `purge` and the other packages that the step asked
    /// for with `remove`, each only where it is installed (also half way) and not on hold, and apt's own simulation
    /// names it, and names no package that is not recorded or is on hold; then the packages that came with them and
    /// that nothing needs now; then the two policies; and where Chrome is gone, Chrome's files that the step made.
    /// Last the record and the live proof's folder.
    static func step(_ work: Work, root: String, path: String) -> String {
        let q = InstallPlan.quote
        let list = packages.joined(separator: " "), lock = "$r\(lockPath)"
        let head = """
            set -u
            umask 022
            PATH=\(q(path)); export PATH; DEBIAN_FRONTEND=noninteractive; export DEBIAN_FRONTEND; LC_ALL=C; export LC_ALL
            r=\(q(root)); v=\(q(work.digest ?? "-")); d="$r\(folder)"; a="$d/added"; s="$d/step"; w=
            say() { printf '%s %s\\n' "$v" "$1" > "$d/.result" && mv -f "$d/.result" "$d/result"; }
            own() { [ "$(id -u)" != 0 ] || chown "${2:-root:root}" "$1"; }
            put() {
              p="$r$1"; g="${2:-${p%/*}}"; shift 2; n=
              n=$(mktemp "$g/.fleet-XXXXXX") && "$@" > "$n" && chmod 644 "$n" || { [ -z "$n" ] || rm -f "$n"; return 1; }
              if [ -f "$p" ] && [ ! -L "$p" ] && cmp -s "$n" "$p"; then rm -f "$n"; chmod 644 "$p"; own "$p"; return 0; fi
              own "$n"; mv -f "$n" "$p" || { rm -f "$n"; return 1; }
            }
            text() { printf '%s' "$1"; }
            key() { printf '%s' "$1" | base64 -d; }
            merge() { { cat "$a" 2>/dev/null; cat "$1"; } | sort -u > "$a.new" && chmod 644 "$a.new" && own "$a.new" && mv -f "$a.new" "$a"; }
            note() { printf '%s\\n' "$1" > "$s/one" && merge "$s/one"; }
            pkgs() { dpkg-query -W -f='${Package}\\t${Architecture}\\t${db:Status-Abbrev}\\n' "$@" 2>/dev/null; }
            installed() { pkgs "$@" | awk -F '\\t' '($2 == "amd64" || $2 == "all") && $3 ~ /^.i/ {print $1}' | sort -u; }
            removable() { pkgs "$@" | awk -F '\\t' '($2 == "amd64" || $2 == "all") && $3 ~ /^i[^nc]/ {print $1}' | sort -u; }
            present() { pkgs "$@" | awk -F '\\t' '($2 == "amd64" || $2 == "all") && $3 !~ /^.[nc]/ {print $1}' | sort -u; }
            every() {
              pkgs > "$1.all" && [ -s "$1.all" ] \
            && awk -F '\\t' '($2 == "amd64" || $2 == "all") && $3 !~ /^.[nc]/ {print $1}' "$1.all" | sort -u > "$1" && [ -s "$1" ]
            }
            ag() {
              o=$(apt-get -q -o Dpkg::Use-Pty=0 "$@" 2>&1) && return 0
              case "$o" in *'Could not get lock'*|*'is another process using it'*) w=apt-busy;; esac
              return 1
            }
            gone() { apt-get -s "$@" 2>/dev/null | awk '$1 == "Purg" || $1 == "Remv" {sub(/:.*/, "", $2); print $2}'; }
            came() {
              every "$s/after" && { for p in $(comm -13 "$s/before" "$s/after"); do
                case ' \(keptPackages.joined(separator: " ")) ' in *" $p "*) continue;; esac
                echo "package $p"
                case ' \(packages.joined(separator: " ")) ' in *" $p "*) echo "requested $p";; esac
              done; } > "$s/new" && merge "$s/new" && rm -f "$s/before" "$s/before.all" "$s/after" "$s/after.all" "$s/new"
            }
            chmod 755 "$d"
            say running
            [ ! -s "$s/before" ] || came || { say write-failed; exit 0; }

            """
        switch work {
        case .nothing:
            return head + "say ok\n"
        case .remove:
            let browserFolder = (portsPath as NSString).deletingLastPathComponent
            let kept = keptPackages.map { "-e " + $0 }.joined(separator: " ")
            return head + """
                if [ -f "\(lock)" ]; then
                  command exec 9<"\(lock)" && flock -w 60 9 || { say lock-busy; exit 0; }
                fi
                if [ -f "$r\(portsPath)" ] || [ -f "$r\(tablePath)" ]; then
                  put \(portsPath) "" text '' && put \(tablePath) "" text \(q(emptyTable)) || { say write-failed; exit 0; }
                  systemctl reload-or-restart fleet-browser-ports.service >/dev/null 2>&1 \
                  || nft -f "$r\(tablePath)" >/dev/null 2>&1 || { say table-failed; exit 0; }
                fi
                for u in $(getent passwd | awk -F: '$1 ~ /^fleet-[a-z][a-z0-9-]*$/ {print $1}'); do
                  systemctl is-active --quiet "user@$(id -u "$u").service" 2>/dev/null || continue
                  systemctl --user --machine="$u@.host" stop fleet_browser.service fleet_vnc.service >/dev/null 2>&1
                done
                ss -Htln > "$s/listening" 2>/dev/null || { rm -f "$s/listening"; say ss-failed; exit 0; }
                l=$(awk '{n = split($4, a, ":"); p = a[n] + 0}
                  p >= \(screenPorts.lowerBound) && p <= \(screenPorts.upperBound) || p >= \(devtoolsPorts.lowerBound) && p <= \(devtoolsPorts.upperBound) {print p}' \
                  "$s/listening" | sort -nu | head -n 5 | tr '\n' ' '); rm -f "$s/listening"
                [ -z "$l" ] || { say "units-running ${l% }"; exit 0; }
                rm -f "$r\(dropinPath)"
                rmdir "$r\((dropinPath as NSString).deletingLastPathComponent)" 2>/dev/null
                systemctl daemon-reload >/dev/null 2>&1
                systemctl disable --now fleet-browser-ports.service >/dev/null 2>&1
                nft delete table inet fleet_browser >/dev/null 2>&1
                rm -f "$r\(unitPath)" "$r\(tablePath)" "$r\(portsPath)" "$r\(originPath)"
                systemctl daemon-reload >/dev/null 2>&1
                # a record from before keptPackages may name one of them: it stays all the same
                q=$(sed -n 's/^requested //p' "$a" 2>/dev/null | grep -vxF \(kept)); k=$(sed -n 's/^package //p' "$a" 2>/dev/null \
                | grep -vxF \(kept))
                f=$(sed -n 's/^file //p' "$a" 2>/dev/null); e=; c=; y=$([ -z "$k" ] || removable $k)
                [ -z "$q" ] || for p in $(removable $q); do
                  x=remove; [ "$p" != google-chrome-stable ] || x=purge
                  t=; o=1
                  for g in $(gone $x "$p"); do [ "$g" != "$p" ] || t=1; printf '%s\\n' "$y" | grep -qxF "$g" || o=; done
                  [ -n "$t" ] && [ -n "$o" ] || continue
                  if [ $x = purge ]; then c=1; else e="$e $p"; fi
                done
                [ -z "$c" ] || ag purge -y google-chrome-stable || { say "${w:-purge-failed}"; exit 0; }
                [ -z "$e" ] || ag remove -y $e || { say "${w:-remove-failed}"; exit 0; }
                e=; for g in $(gone autoremove); do printf '%s\\n' "$k" | grep -qxF "$g" && e="$e $g"; done
                [ -z "$e" ] || ag remove -y $e || { say "${w:-remove-failed}"; exit 0; }
                rm -f "$r\(fixedPath)" "$r\(policyPath)"
                if [ -z "$(present google-chrome-stable)" ]; then
                  for x in $f; do
                    case "$x" in \(defaultPath)|\(sourcePath)|\(keyPath)) rm -f "$r$x";; esac
                  done
                fi
                rm -rf "$d/proof"; rm -f "$a" "\(lock)"; rmdir "$r\(browserFolder)" 2>/dev/null
                say ok

                """
        case .install(let want):
            let users = want.rows.map { "\($0.user) \(want.uids[$0.user] ?? -1)\n" }.joined()
            let policies = (policyPath as NSString).deletingLastPathComponent
            let stage = (policies as NSString).deletingLastPathComponent
            return head + """
                b=\(q(want.broker.map(String.init) ?? "")); u=\(q(want.worker)); i=\(want.workerID)
                same() { [ "$(id -u "$1" 2>/dev/null)" = "$2" ]; }
                users() {
                  c=1
                  printf '%s' \(q(users)) | { while read -r x y; do same "$x" "$y" || exit 1; done; } || c=
                  { same "$u" "$i" && [ "$i" != 0 ]; } || c=
                  if [ -n "$b" ]; then same \(broker) "$b" || c=; elif id -u \(broker) >/dev/null 2>&1; then c=; fi
                  [ -n "$c" ]
                }
                users || { say users-changed; exit 0; }
                for x in "$r\((portsPath as NSString).deletingLastPathComponent)" "$r\(policies)" "$d/proof" \
                "$r\((dropinPath as NSString).deletingLastPathComponent)"; do
                  mkdir -p "$x" && chmod 755 "$x" || { say write-failed; exit 0; }
                done
                own "$d/proof" "$u:" || { say write-failed; exit 0; }
                if [ ! -e "$r\(keyPath)" ]; then
                  put \(keyPath) "" key \(q(keyData.base64EncodedString())) && note 'file \(keyPath)' \
                || { say write-failed; exit 0; }
                fi
                if [ ! -e "$r\(sourcePath)" ]; then
                  put \(sourcePath) "" text \(q(sourceText)) && note 'file \(sourcePath)' || { say write-failed; exit 0; }
                fi
                x=; [ -e "$r\(defaultPath)" ] || x=1
                put \(defaultPath) "" text \(q(defaultText)) && { [ -z "$x" ] || note 'file \(defaultPath)'; } \
                && put \(fixedPath) "$r\(stage)" text \(q(fixedText)) \
                && put \(policyPath) "$r\(stage)" text \(q(policyText)) \
                && put \(originPath) "" text \(q(originText)) || { say write-failed; exit 0; }
                h=$(installed \(list)); m=
                for p in \(list); do printf '%s\\n' "$h" | grep -qxF "$p" || m="$m $p"; done
                if [ -n "$m" ]; then
                  ag update || { say "${w:-update-failed}"; exit 0; }
                  every "$s/before" || { say write-failed; exit 0; }
                  z=0; ag install -y --no-install-recommends --no-remove -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold $m || z=1
                  came || { say write-failed; exit 0; }
                  [ "$z" = 0 ] || { say "${w:-install-failed}"; exit 0; }
                  apt-get clean >/dev/null 2>&1
                fi
                [ -f "\(lock)" ] || ( umask 077 && : > "\(lock)" ) || { say write-failed; exit 0; }
                own "\(lock)" "root:$(id -gn "$u")" && chmod 640 "\(lock)" || { say write-failed; exit 0; }
                command exec 9<"\(lock)" && flock -w 60 9 || { say lock-busy; exit 0; }
                users || { say users-changed; exit 0; }
                put \(portsPath) "" text \(q(portsText(want.rows))) && put \(tablePath) "" text \(q(want.table)) \
                && put \(unitPath) "" text \(q(unitText)) && put \(dropinPath) "" text \(q(dropinText)) \
                || { say write-failed; exit 0; }
                systemctl daemon-reload >/dev/null 2>&1 || { say table-failed; exit 0; }
                systemctl enable fleet-browser-ports.service >/dev/null 2>&1 \
                && systemctl reload-or-restart fleet-browser-ports.service >/dev/null 2>&1 || { say table-failed; exit 0; }
                say ok

                """
        }
    }

    /// What one run came to.
    public enum Outcome: Equatable, Sendable {
        /// A step started now; what the one before it said ("" for none).
        case started(String)
        /// A step still runs: nothing started.
        case running(String)
        /// The program ran and started no step, with the words for the log.
        case failed(String)
        /// The output reads as a program that did not start: nothing ran on the server.
        case notStarted(String)
    }

    /// The run's output, read from its last `mark` line, as `ServerHardening.outcome` reads its own.
    public static func outcome(_ output: String) -> Outcome {
        let all = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let lines = all.filter { $0 != started }
        guard let last = lines.last(where: { $0.hasPrefix(mark + " ") }) else {
            let said = lines.last(where: { !$0.isEmpty }).map { String($0.prefix(200)) } ?? "nothing"
            return lines.count == all.count ? .notStarted("the program did not start: \(said)")
                : .failed("the program started and did not end: \(said)")
        }
        let words = last.split(separator: " ").dropFirst().map(String.init)
        let before = words.dropFirst().joined(separator: " ")
        switch words.first {
        case "started": return .started(before)
        case "running": return .running(before)
        default:
            let said = lines.prefix { $0 != last }.filter { !$0.isEmpty }.suffix(2).joined(separator: " ")
            return .failed("no step started" + (said.isEmpty ? "" : ": " + String(said.prefix(300))))
        }
    }
}

/// **Whom each agent of a server runs as** (owner API 1.224), as its service read it: by the agent's name, its OS user
/// and that user's uid; nil for an agent whose user is not made yet. A value that does not read is none.
public struct ServerAgentUsers: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let user: String?
        public let uid: Int?
        private enum Keys: String, CodingKey { case user, uid }
        public init(user: String?, uid: Int?) { self.user = user; self.uid = uid }
        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Keys.self)
            self.init(user: (try? keys?.decodeIfPresent(String.self, forKey: .user)) ?? nil,
                      uid: (try? keys?.decodeIfPresent(Int.self, forKey: .uid)) ?? nil)
        }
    }

    public let users: [String: Entry]
    public init(users: [String: Entry]) { self.users = users }
    public init(from decoder: Decoder) throws {
        users = (try? decoder.singleValueContainer().decode([String: Entry].self)) ?? [:]
    }
}

/// **A Linux server's browser parts, as its service read them** (`lifecycle.browser_reading`, owner API 1.224): its
/// state (`ready`, `missing`, `table_missing` or `unsupported`), Chrome's version, the packages that are missing, the
/// SHA-256 of each file of the parts that is there, the word of the table's unit, the agents' ports (nil for a file
/// that is not of the contract), whether the step keeps a record of what it added, the uids of the broker and of the
/// worker user, how many agents got each verdict of the live proof, and whether the service could keep those verdicts
/// for the agents' helpers (nil where it had no ports to prove). A field that does not read is none: it never hides the server.
public struct ServerBrowserReading: Decodable, Equatable, Sendable {
    public let state: String?
    public let chrome: String?
    public let missing: [String]
    public let files: [String: String]
    public let unit: String?
    public let ports: [ServerBrowser.Ports]?
    public let added: Bool
    public let broker: Int?
    public let worker: Int?
    public let proof: [String: Int]?
    public let proofKept: Bool?

    public init(state: String?, chrome: String? = nil, missing: [String] = [], files: [String: String] = [:],
                unit: String? = nil, ports: [ServerBrowser.Ports]? = [], added: Bool = false, broker: Int? = nil,
                worker: Int? = nil, proof: [String: Int]? = nil, proofKept: Bool? = nil) {
        self.state = state; self.chrome = chrome; self.missing = missing; self.files = files; self.unit = unit
        self.ports = ports; self.added = added; self.broker = broker; self.worker = worker; self.proof = proof
        self.proofKept = proofKept
    }

    private enum Keys: String, CodingKey {
        case state, chrome, missing, files, unit, ports, added, broker, worker, proof, proof_kept
    }
    public init(from decoder: Decoder) throws {
        let keys = try? decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String? { (try? keys?.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func number(_ key: Keys) -> Int? { (try? keys?.decodeIfPresent(Int.self, forKey: key)) ?? nil }
        let files = ((try? keys?.decodeIfPresent([String: String?].self, forKey: .files)) ?? nil) ?? [:]
        self.init(state: text(.state), chrome: text(.chrome),
                  missing: ((try? keys?.decodeIfPresent([String].self, forKey: .missing)) ?? nil) ?? [],
                  files: files.compactMapValues { $0 }, unit: text(.unit),
                  ports: (try? keys?.decodeIfPresent([ServerBrowser.Ports].self, forKey: .ports)) ?? nil,
                  added: ((try? keys?.decodeIfPresent(Bool.self, forKey: .added)) ?? nil) ?? false,
                  broker: number(.broker), worker: number(.worker),
                  proof: (try? keys?.decodeIfPresent([String: Int].self, forKey: .proof)) ?? nil,
                  proofKept: (try? keys?.decodeIfPresent(Bool.self, forKey: .proof_kept)) ?? nil)
    }
}
