import Foundation

/// **The join's hardening, put right again by the owner's Mac** (the owner's "Yes, all of it" of 14 November 2026).
///
/// The join of a Linux server makes its SSH take keys only and gives npm its seven-day rule (`hubsetup.py harden`). On
/// 14 November 2026 the first server that Add server made at a provider kept password login: the join's security
/// updates stopped OpenSSH, so `sshd -t` could not answer, and the step took its own file back. The fleet's manager then
/// asked the owner to run a root command by hand. A server that joined with that fault keeps it until its hardening
/// runs again as root, and the owner's Mac already reaches each Linux server of the fleet as root (`OwnerAccessModel`).
/// So the Mac does it by itself, with nothing on a page and a log line only:
///
/// - **When.** A Linux server that joined and is not the hub's own machine, whose own service's current reading says
///   that SSH lets passwords in (`ssh_keys_only` false) or that npm has no seven-day rule (`npm_rule` false), in two
///   rounds in a row (`step`); never in the hour after its join (`joinGrace`, as the hub's own `JOIN_GRACE`), and never
///   while a job of its service is open. The hub's own server the same way, by the hub's own reading of it
///   (`ServerEntry.hardening`, owner API 1.170) and never by a reading of a service there: never in the hour after the
///   hub's claim (its install hardens it after the claim), and never from a hub that does not give that reading (one
///   on a Mac, or one from before it). A hub installed before release 2026.11.441 had no hardening of its own at all.
/// - **What.** `program`, as root: the file in sshd's folder that the join writes, byte for byte, checked with
///   `sshd -t` and taken back when sshd refuses it, sshd reloaded and read back with `sshd -T`; and npm's line in
///   `/etc/npmrc`. It is this app's own program, as the owner's access line is, and never code of the server's own
///   checkout: the service's user can change that checkout, and root runs nothing that it can change
///   (`CentralVaultRemote.rootKit`).
/// - **How often.** A run that leaves the fault is tried again after ten minutes, six times at most (`VaultTries`),
///   and then never again. The count is kept on this Mac (`Memory`), so a new launch of the app does not start again.
///   **Only a run that started on the server is in that count**, and the program says so itself: its first line
///   (`started`), before it reads or changes anything. A try that ran nothing there has the same wait and six tries
///   too, but for one launch of the app only, as the tries of the owner's access line have, and it is never in the
///   kept count (`step`'s `unreached`, `Memory.ofRuns`): no connection to the server on record, or an `ssh` whose
///   output has none of the program's lines, because the host key or the login was refused, nothing answered, or
///   `sudo` asked for a password. So a server whose connection or login comes right later still gets its run.
/// - **Never against a choice.** A server is settled once a reading says that its hardening holds, or once a run says
///   so or says that no account there has an SSH key (the join then keeps password login too: with keys only, nobody
///   could log in). A later change of a settled server's SSH is somebody's choice, and this Mac does not act on it.
public enum ServerHardening {
    /// The hub's `JOIN_GRACE`: the hour after a join in which the join itself still updates, closes and hardens the
    /// server, so a reading of that time says nothing. And the hour after the hub's claim, after which its install
    /// updates and hardens the hub's own server.
    public static let joinGrace: Double = 3600
    /// The file that the join's hardening writes in sshd's folder, and its text: byte for byte `hubsetup.py`'s
    /// `SSHD_HARDENING` and `SSHD_TEXT`, so that a later run of either finds the other's file in place.
    public static let sshdFolder = "/etc/ssh/sshd_config.d"
    public static let sshdFile = sshdFolder + "/10-fleet-hardening.conf"
    public static let sshdText = "# Founderizer's join writes this file (hubsetup.py harden): SSH takes keys only, and no X11 "
        + "forwarding.\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nX11Forwarding no\n"
    /// npm's line for every user of the system (`hubsetup.py`'s `NPMRC` and `NPM_RULE`).
    public static let npmrc = "/etc/npmrc"
    public static let npmRule = "min-release-age=7"
    /// The first word of the program's last line, which says what each part came to.
    static let mark = "founderizer-hardening"
    /// **The program's first line, alone on its line, before it reads or changes anything on the server.** `ssh` gives
    /// the same status (255) when it could not log in and when the connection broke while the program ran, so its
    /// status cannot say whether anything ran there. This line can: output with it is of a program that started, and
    /// output with neither this line nor a `mark` line reads as an `ssh` that started nothing (`Outcome.notStarted`).
    /// The program goes on only when it wrote the line, so it changes nothing where the server closed its output
    /// already. One case reads wrong: the server took the line (its sshd, or a `sudo` that passes the output on), and
    /// the line did not reach this Mac, because the connection broke or this Mac's `ssh` ended just then. That program
    /// runs on, and nobody reads it; the six tries of one launch are the most for it.
    static let started = mark + "-started"

    // MARK: when

    /// Whether this Mac puts the hardening of this server right at all: a Linux server that joined, and the hub's own
    /// server where the hub gives its own reading of it, which it does on Linux only. Not a Mac that joined as a server,
    /// whose agents run as a person's own user.
    public static func applies(to server: ServerEntry) -> Bool {
        server.hub ? server.hardening != nil && !server.isMac : server.kind == "linux" && server.joined
    }

    /// What one round reads of a server's hardening.
    public enum Reading: Equatable, Sendable {
        /// Nothing that counts: not a server of this sweep, no current reading of its own service (on the hub's own
        /// server, of the hub), a reading that carries neither fact, the hour after its join or the hub's claim, or a
        /// job of its service that is open.
        case unread
        /// SSH takes keys only, and npm's rule is not missing.
        case holds
        /// SSH lets passwords in, or npm has no seven-day rule.
        case faulty
    }

    /// `join` is the newest join of the fleet (`ServerList.join`), and `time` the hub's clock (`ServerList.time`), which
    /// the reading, the join and the hub's claim are all on.
    public static func reading(of server: ServerEntry, join: JoinState?, at time: Double) -> Reading {
        guard applies(to: server), server.job?.isOpen != true else { return .unread }
        if let join, join.server == server.name, time - join.created < joinGrace { return .unread }
        let ssh: Bool?, npm: Bool?
        if server.hub {
            // The hub's own read, also where its server has a service with a reading of its own: one source, as the
            // hub's own watch has, so that the two never disagree.
            guard let own = server.hardening, own.isCurrent(at: time),
                  let claimed = own.claimed_at, time - claimed >= joinGrace else { return .unread }
            (ssh, npm) = (own.ssh_keys_only, own.npm_rule)
        } else {
            guard let reading = server.reading, reading.source == "server", reading.isCurrent(at: time),
                  let security = reading.security else { return .unread }
            (ssh, npm) = (security.ssh_keys_only, security.npm_rule)
        }
        if ssh == false || npm == false { return .faulty }
        return ssh == true ? .holds : .unread
    }

    /// What this Mac keeps of one server, from one launch to the next.
    public struct Memory: Codable, Equatable, Sendable {
        /// The runs in a row that did not settle the server, the time of the last one, and what it said.
        public var failures = 0
        public var last: Double = 0
        public var reason = ""
        /// Its hardening held once, or a run left it as the join leaves it: this Mac never acts on it again.
        public var settled = false

        public init() {}

        public var tries: VaultTries? {
            failures == 0 ? nil : VaultTries(failures: failures, last: last, reason: reason)
        }

        /// One more run that did not settle the server.
        public mutating func failed(at now: Double, reason: String) {
            let next = VaultTries.failed(after: tries, at: now, reason: reason)
            (failures, last, self.reason) = (next.failures, next.last, next.reason)
        }

        /// The reason that the builds from Founderizer 0.1.225 to the fix of 15 November 2026 kept for a try that found
        /// no connection to the server. No run has it: a run's reason is one of `outcome`'s for a program that started.
        static let noConnection = "noConnection"
        /// The first words of the reason that each build from Founderizer 0.1.225 until this one kept for output with no
        /// `mark` line. Their program had no first line of its own, so those words were for both an `ssh` that started
        /// nothing and a run that broke. No run of this build has them: `outcome` says "started and did not end".
        static let didNotEnd = "the program did not end: "

        /// **The count of the runs alone.** The builds before this one also counted a try that ran nothing on the
        /// server as a run: one that found no connection to it (none to a hub's own server with no agent), and one
        /// whose `ssh` could not log in. Six such tries in the first hour, and then that server was left for good, with
        /// its fault, also after the login came right. A kept count whose last reason is one of those two starts again:
        /// its last try most likely ran nothing on the server, and the tries before it most often ran nothing either.
        /// A count of six runs that broke gets six more that way, one time for each of the two reasons: 17 runs at
        /// the very most, of a program that leaves the server as it was where its file and npm's line are in place,
        /// apart from a reload of sshd and from `/run/sshd`, which it makes where that folder is missing. A count that
        /// such a build kept for an `ssh` that did not start on that Mac (`cannotStart`) stays. A server that is
        /// settled stays settled.
        public var ofRuns: Memory {
            settled || !(reason == Self.noConnection || reason.hasPrefix(Self.didNotEnd)) ? self : Memory()
        }

        /// What this Mac kept of one server, out of the bytes that it kept (`encoded`), with the count of the runs
        /// alone; a new memory where it kept nothing, or nothing that reads.
        public static func kept(_ data: Data?) -> Memory {
            (data.flatMap { try? JSONDecoder().decode(Memory.self, from: $0) } ?? Memory()).ofRuns
        }
    }

    /// What one round does with one server.
    public enum Step: Equatable, Sendable {
        /// Nothing: the reading says nothing, or the server is settled. A fault seen before is forgotten.
        case nothing
        /// The hardening holds: the server is settled.
        case settle
        /// The fault, in the first round that reads it: the next round decides.
        case seen
        /// The fault again, but its next try is not due yet, or all six were spent.
        case wait
        /// The fault in a second round in a row, and a try is due: the program runs.
        case run
    }

    /// `seenBefore`: the round before this one read the same fault. `now` is this Mac's clock, as `memory`'s times.
    /// `unreached`: the tries of this launch that ran nothing on the server (no connection to it, or an `ssh` that did
    /// not start the program), which are not in `memory`; nil where this launch had none.
    public static func step(_ reading: Reading, memory: Memory, seenBefore: Bool, now: Double,
                            unreached: VaultTries? = nil) -> Step {
        guard !memory.settled else { return .nothing }
        switch reading {
        case .unread: return .nothing
        case .holds: return .settle
        case .faulty:
            guard seenBefore else { return .seen }
            guard unreached.map({ $0.isDue(at: now) }) ?? true else { return .wait }
            return memory.tries.map { $0.isDue(at: now) } ?? true ? .run : .wait
        }
    }

    /// What one round did with one server.
    public struct Turn: Equatable, Sendable {
        /// The round read the fault: the next round's `seenBefore`.
        public var seen = false
        /// What goes to the log, and nowhere else.
        public var lines: [String] = []
    }

    /// **One round's work for one server**: `step`, and for a run the connection, the program and what each came to.
    /// `memory` is what this Mac keeps of the server, and the caller keeps it again when this changed it; `unreached`
    /// is this launch's tries that ran nothing on the server. `connection` gives the connection to the server or
    /// throws (`ServerRecords.connection`); `run` runs `program` there as root and gives its output, or throws when
    /// `ssh` did not start on this Mac.
    ///
    /// **A try is a kept run only when the program started on the server**, which its own output says (`outcome`).
    /// A try that ran nothing there is counted in `unreached` and never in `memory`: no connection to the server, an
    /// `ssh` that did not start on this Mac, or an `ssh` whose output reads as a program that did not start
    /// (`Outcome.notStarted`). Nothing ends that count in a launch, also not a run between two such tries: six are
    /// the most for one launch, so that a run that reads as not started cannot come more often than that. A run that
    /// started and did not settle the server is counted in `memory`, also when it did not end: the program ran in
    /// part, and six such runs are the most for good.
    public static func turn(_ reading: Reading, memory: inout Memory, unreached: inout VaultTries?, seenBefore: Bool,
                            now: Double, connection: @Sendable () async throws -> InstallTarget,
                            run: @Sendable (InstallTarget) async throws -> String) async -> Turn {
        switch step(reading, memory: memory, seenBefore: seenBefore, now: now, unreached: unreached) {
        case .nothing: return Turn()
        case .seen, .wait: return Turn(seen: true)
        case .settle:
            memory.settled = true
            return Turn()
        case .run:
            var turn = Turn(seen: true)
            // Why this try ran nothing on the server; nil when the program started there.
            var nothingRan: String?
            do {
                let output = try await run(try await connection())
                turn.lines = Array(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0 != started }.suffix(6))
                switch outcome(output) {
                case .holds, .leftAsItIs: memory.settled = true
                case .failed(let said): memory.failed(at: now, reason: said)
                case .notStarted(let said): nothingRan = said
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
                return turn
            }
            if memory.settled {
                turn.lines.append("its hardening is in order")
            } else if memory.tries?.givenUp == true {
                turn.lines.append("left after \(memory.failures) tries (\(memory.reason))")
            }
            return turn
        }
    }

    // MARK: what

    /// **The program, as root on the server.** SSH first, as `hubsetup.harden_ssh` does it: nothing where OpenSSH
    /// does not run, and nothing where no account has a key line in an `authorized_keys` of root or of a user in
    /// `/home`. Else sshd's privilege separation folder is made when it is missing (with it missing, `sshd -t` refuses
    /// every file: the cause of 14 November 2026), the file goes in place unless it holds the text already, `sshd -t`
    /// checks it, and a refused file is taken back, the earlier one where there was one. sshd is reloaded, and
    /// `sshd -T` says whether the three settings hold. Then npm's line, where `/etc/npmrc` has no `min-release-age`
    /// line yet, so a line of the owner's own stays as it is. The last line is `mark` with what each part came to.
    ///
    /// **Before all of that, `started`**, after an empty line and in one write: so it is alone on its line also where
    /// root's login shell printed words with no new line before the program began. Where that write fails, the
    /// program ends there: it changes nothing where the server closed the program's output before the program began.
    /// It cannot know of an output that the server still holds open with nobody at its end (`started`).
    ///
    /// `root` puts every path under a folder, for the tests; on a server it is "".
    public static func program(root: String = "") -> String {
        let r = InstallPlan.quote(root)
        return """
            printf '\\n%s\\n' \(started) || exit 1
            r=\(r); d="$r\(sshdFolder)"; f="$r\(sshdFile)"; s=; n=; b=
            if ! systemctl is-active ssh.service ssh.socket 2>/dev/null | grep -qx active; then s=off
            elif ! ( for k in "$r"/root/.ssh/authorized_keys "$r"/root/.ssh/authorized_keys2 \
            "$r"/home/*/.ssh/authorized_keys "$r"/home/*/.ssh/authorized_keys2; do
              [ -f "$k" ] && grep -qv -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$k" && exit 0; done; exit 1 ); then s=no-key
            elif [ ! -d "$d" ]; then s=no-folder
            else
              [ -d "$r/run/sshd" ] || { mkdir "$r/run/sshd" && chmod 755 "$r/run/sshd"; } 2>/dev/null
              n=$(mktemp "$d/.fleet-XXXXXX") && printf '%s' \(InstallPlan.quote(sshdText)) > "$n" && chmod 644 "$n" \
            || s=not-written
              if [ -z "$s" ] && ! cmp -s "$n" "$f"; then
                if [ -f "$f" ]; then b=$(mktemp "$d/.fleet-XXXXXX") && cp -p "$f" "$b" || s=not-written; fi
                if [ -z "$s" ]; then
                  mv -f "$n" "$f"; n=
                  if ! o=$(sshd -t 2>&1); then
                    if [ -n "$b" ]; then mv -f "$b" "$f"; b=; else rm -f "$f"; fi
                    printf '%s\\n' "$o" | tail -n 3; s=refused
                  fi
                fi
              fi
              [ -z "$n" ] || rm -f "$n"; [ -z "$b" ] || rm -f "$b"
              if [ -z "$s" ]; then
                systemctl try-reload-or-restart ssh.service >/dev/null 2>&1
                t=$(sshd -T 2>/dev/null)
                if printf '%s\\n' "$t" | grep -qx 'passwordauthentication no' \
            && printf '%s\\n' "$t" | grep -qx 'kbdinteractiveauthentication no' \
            && printf '%s\\n' "$t" | grep -qx 'x11forwarding no'; then s=keys-only; else s=not-yet; fi
              fi
            fi
            m="$r\(npmrc)"
            if [ -f "$m" ] && grep -q '^[[:space:]]*min-release-age[[:space:]]*=' "$m"; then p=held
            elif [ ! -e "$m" ]; then
              if printf '%s\\n' '\(npmRule)' > "$m" && chmod 644 "$m"; then p=made; else p=failed; fi
            elif { [ -z "$(tail -c1 "$m")" ] || echo; printf '%s\\n' '\(npmRule)'; } >> "$m"; then p=made
            else p=failed
            fi
            echo "\(mark) ssh=$s npm=$p"
            """
    }

    /// What one run came to.
    public enum Outcome: Equatable, Sendable {
        /// SSH takes keys only, or no OpenSSH runs there; and npm has its line.
        case holds
        /// No account there has an SSH key: password login stays, as the join leaves it.
        case leftAsItIs
        /// Anything else of a program that started, with the words for the log: a part that failed, or a run that did
        /// not end.
        case failed(String)
        /// The output reads as a program that did not start: `ssh`'s or `sudo`'s own refusal, with the words for the
        /// log. Then nothing ran on the server, but for the one case that `started` names.
        case notStarted(String)
    }

    /// The run's output, read from its last `mark` line. Output without one is a run that did not end, where it has
    /// the program's first line (`started`): the connection broke, or the program was stopped. Without that line too,
    /// it reads as a program that did not start: `ssh` did not connect or log in, or `sudo` refused. That reading is
    /// wrong only in the case that `started` names: the server took the program's first line, and this Mac did not
    /// get it.
    public static func outcome(_ output: String) -> Outcome {
        let all = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let lines = all.filter { $0 != started }
        guard let last = lines.last(where: { $0.hasPrefix(mark + " ") }) else {
            let said = lines.last(where: { !$0.isEmpty }).map { String($0.prefix(200)) } ?? "nothing"
            return lines.count == all.count ? .notStarted("the program did not start: \(said)")
                : .failed("the program started and did not end: \(said)")
        }
        var parts: [String: String] = [:]
        for word in last.split(separator: " ").dropFirst() {
            let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parts[pair[0]] = pair[1] }
        }
        let ssh = parts["ssh"] ?? "", npm = parts["npm"] ?? ""
        if ssh == "no-key" { return .leftAsItIs }
        if ["keys-only", "off"].contains(ssh), ["held", "made"].contains(npm) { return .holds }
        let before = lines.prefix { $0 != last }.filter { !$0.isEmpty }.suffix(3).joined(separator: " ")
        return .failed("ssh \(ssh.isEmpty ? "?" : ssh), npm \(npm.isEmpty ? "?" : npm)"
                       + (before.isEmpty ? "" : ": " + String(before.prefix(300))))
    }
}
