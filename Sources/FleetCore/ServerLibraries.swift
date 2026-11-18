import Foundation

/// **The system packages that the fleet's pinned tools load, put in place by the owner's Mac** (the owner's "Yes,
/// build it here" of 18 November 2026).
///
/// Each agent's helper installs the program of an npm MCP server with the fleet's pinned Node, and that Node loads
/// `libatomic.so.1`, which the image of Ubuntu 24.04 does not have: there the Node does not start, no npm program of
/// an MCP server installs, and the agent's session says why. The join and the hub's install put the package in place
/// (`join.sh` and `hub.sh`, since hub release 2026.11.569); a server that joined, or a hub that was installed, before
/// that does not have it. The owner's Mac already reaches each Linux server of the fleet as root
/// (`OwnerAccessModel`), so it installs the package by itself, as it puts the join's SSH, npm and memory right
/// (`ServerHardening`, `ServerMemory`), with nothing on a page and a log line only:
///
/// - **When.** A server that `ServerHardening` sweeps (a Linux server that joined, and the hub's own server by the
///   hub's own reading), with a current reading of its own service (on the hub's own server, of the hub itself), in
///   two rounds in a row; never in the hour after its join or the hub's claim, and never while a job of its service
///   is open. No reading says whether the packages are there, so the program reads it itself: each server gets one
///   run, and that run settles a server whose packages are there already.
/// - **What.** `program`, as root: `dpkg-query` reads each package of `packages`, and only where one is missing are
///   apt's lists updated and the missing ones installed, as the join installs its own packages. It is this app's own
///   program and never code of the server's own checkout.
/// - **How often, and never against a choice.** `ServerHardening`'s `step` and `turn`, with a record of this sweep's
///   own (`keptKey`, `record`), but a run that fails counts for one launch of the app only: its causes are mostly of
///   the moment (a package mirror, apt's lock, a dpkg that apt's daily run repairs), so each launch tries a server
///   again, six times at most and ten minutes apart. This Mac keeps a server only once it is settled: a run says that
///   the packages are there, or that the server has no apt. A later removal of a package is somebody's choice, and
///   this Mac does not act on it. A package that comes into `packages` later starts each server again (`record`).
public enum ServerLibraries {
    /// The packages of the system libraries that the fleet's pinned tools load: the values of `fleet.py`'s
    /// `PROGRAM_LIBRARIES`, which `join.sh` and `hub.sh` install too (`test_hub_install.PackageLists` holds the lists
    /// together).
    public static let packages = ["libatomic1"]
    /// The seconds that each `apt-get` of the program waits for the lock of dpkg, which apt's own daily run of
    /// updates holds for a few minutes.
    public static let lockWait = 180
    /// The seconds that this Mac gives one run: three updates of apt's lists with two pauses, the wait for the lock,
    /// and the install. A run that takes longer is stopped on this Mac, counts as a run that failed, and goes on on
    /// the server; a run that comes while it still works there finds its lock (`program`) and installs nothing.
    public static let runTime: Double = 300
    /// Where this Mac keeps the servers that are settled (`ServerHardeningModel` in the app; Start again clears this
    /// hub's records from it, `StartAgain.forgetKept`).
    public static let keptKey = "serverLibraries"
    /// The name of a server's record under `keptKey`: the name that the app keeps of the server, with `packages`, so
    /// that a package that comes into the list later starts each server again.
    public static func record(_ name: String) -> String { name + " " + packages.joined(separator: ",") }
    /// The first word of the program's last line, and its first line (`ServerHardening.started` says why it has one).
    static let mark = "founderizer-libraries"
    public static let started = "founderizer-libraries-started"
    /// The program's lock, so that one run at a time installs on a server.
    static let lock = "/run/founderizer-libraries.lock"

    // MARK: when

    /// What one round reads of a server, in `ServerHardening`'s words: `.faulty` for each server of this sweep with a
    /// current reading, because only the program can say whether the packages are there, and `.unread` for all else.
    public static func reading(of server: ServerEntry, join: JoinState?, at time: Double) -> ServerHardening.Reading {
        guard ServerHardening.applies(to: server), server.job?.isOpen != true else { return .unread }
        if let join, join.server == server.name, time - join.created < ServerHardening.joinGrace { return .unread }
        if server.hub {
            guard let own = server.hardening, own.isCurrent(at: time),
                  let claimed = own.claimed_at, time - claimed >= ServerHardening.joinGrace else { return .unread }
        } else {
            guard let reading = server.reading, reading.source == "server", reading.isCurrent(at: time) else {
                return .unread
            }
        }
        return .faulty
    }

    // MARK: what

    /// **The program, as root on the server.** Nothing where the server has no `dpkg-query` or no `apt-get`. Else
    /// `dpkg-query` reads each package of `packages`, which counts as there when it is installed for the server's own
    /// architecture or for all (one on hold too, and never one of another architecture alone, which the pinned tools
    /// cannot load); where all are there, the program changes nothing. Where one is missing, the program takes its lock
    /// (`lock`, a file for root alone, also where it was there before, so that no other user of the server can hold
    /// it), or says `busy` and does nothing while an earlier run still holds it. Then apt's lists are updated (three
    /// tries, 15 seconds apart: the daily run of apt's own updates holds the lock of the lists while it reads them, and
    /// apt waits only for the lock of dpkg), and the missing packages are installed as the join installs its own:
    /// `--no-install-recommends`, a wait of `lockWait` for the lock of dpkg, and no question. Unlike the join, the
    /// install removes no package (`--no-remove`: apt stops instead), keeps a configuration file that the server
    /// changed, and needrestart restarts no service (`NEEDRESTART_MODE=l`): what a dependency's upgrade brings (gcc's
    /// base packages, `libstdc++6`) reaches a service at its next start. An update that fails three times leaves the
    /// lists that the server has, and the install still runs; its exit status says whether the packages came, as in the
    /// join.
    ///
    /// **A lost connection does not stop the install.** Where `sudo` runs the program in a terminal of its own, the
    /// end of the connection hangs that terminal up, and each process of the program gets HUP; and a write to an
    /// output that has nobody at its end raises PIPE. The program ignores both, and the processes that it starts
    /// inherit that; apt's and dpkg's words go into a variable that the program's shell reads, never to that output.
    /// Where logind ends all processes of a login at its end (`KillUserProcesses=yes`, not the default of these
    /// systems, and never for a login as root), the install is stopped all the same: the daily run of unattended
    /// upgrades, which the join turns on, repairs a dpkg that was stopped, and a later try of this Mac installs the
    /// packages.
    ///
    /// Before all of that, `started` (as `ServerHardening.program` says). The last line is `mark` with what the
    /// packages came to; a line before it names the packages that the run installed and apt's summary, or apt's last
    /// words: apt's summary line is "N upgraded, M newly installed" before apt 3, and "Upgrading: N, Installing: M"
    /// from apt 3 (Debian 13, Ubuntu 26.04). `root` puts the lock under a folder, for the tests; on a server it is "".
    public static func program(root: String = "") -> String {
        let wait = "-o DPkg::Lock::Timeout=\(lockWait)"
        return """
            printf '\\n%s\\n' \(started) || exit 1
            PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"; export PATH
            r=\(InstallPlan.quote(root)); m=; w=; l="$r\(lock)"
            if ! command -v dpkg-query >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then w=no-apt
            else
              a=$(dpkg --print-architecture 2>/dev/null)
              for p in \(packages.joined(separator: " ")); do
                dpkg-query -W -f='${Architecture} ${db:Status-Status}\\n' "$p" 2>/dev/null \\
            | grep -qx -e "$a installed" -e 'all installed' || m="$m $p"
              done
              if [ -z "$m" ]; then w=held
              elif command -v flock >/dev/null 2>&1 && ( umask 077 && : >> "$l" && chmod 600 "$l" ) 2>/dev/null \\
            && { command exec 9<"$l"; } 2>/dev/null && ! flock -n 9; then w=busy
              else
                trap '' HUP PIPE
                DEBIAN_FRONTEND=noninteractive; NEEDRESTART_MODE=l; export DEBIAN_FRONTEND NEEDRESTART_MODE
                for t in 1 2 3; do
                  apt-get \(wait) update -q </dev/null >/dev/null 2>&1 && break
                  [ "$t" = 3 ] || sleep 15
                done
                if o=$(apt-get \(wait) -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \\
            install -y -q --no-install-recommends --no-remove $m </dev/null 2>&1); then
                  w=installed; echo "installed:$m"
                  printf '%s\\n' "$o" | grep -E 'newly installed|Upgrading: [0-9]' | tail -n 1
                else
                  w=failed; printf '%s\\n' "$o" | tail -n 2
                fi
              fi
            fi
            echo "\(mark) packages=$w"
            """
    }

    /// The run's output, read as `ServerHardening.outcome` reads its own, from the last `mark` line. Packages that
    /// were there or that the run installed settle the server, and so does a server with no apt, which is left as it
    /// is; all else is a run that failed, with apt's last words for the log, also `busy`: an earlier run still works
    /// there, and the next try finds what it did.
    public static func outcome(_ output: String) -> ServerHardening.Outcome {
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
        let packages = parts["packages"] ?? ""
        if packages == "no-apt" { return .leftAsItIs }
        if ["held", "installed"].contains(packages) { return .holds }
        let before = lines.prefix { $0 != last }.filter { !$0.isEmpty }.suffix(3).joined(separator: " ")
        return .failed("packages \(packages.isEmpty ? "?" : packages)"
                       + (before.isEmpty ? "" : ": " + String(before.prefix(300))))
    }
}
