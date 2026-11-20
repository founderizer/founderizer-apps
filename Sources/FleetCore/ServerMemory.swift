import Foundation

/// **A server's memory reserve and limit, put right by the owner's Mac** (the owner's "Yes, build it" of 17 November
/// 2026, to a fleet that looks after its own servers).
///
/// The join of a Linux server gives it a swap file and one memory limit for all users' processes together
/// (`hubsetup.py harden`, owner API 1.211): the agents' sessions, their helpers and each login are in systemd's
/// `user.slice`, and with the limit the kernel ends the largest process of that group when the group is full, so SSH,
/// Tailscale and the server's own services keep their memory and the server still answers. A server that joined
/// before that version has neither. In five days of November 2026 three such servers ran out of memory, one stayed
/// at 95% for 55 minutes with nothing that answered, and each repair came to the owner as a root command or a click
/// at the provider. The owner's Mac already reaches each Linux server of the fleet as root (`OwnerAccessModel`), so
/// it does it by itself, as it does for the join's SSH and npm (`ServerHardening`), with nothing on a page and a log
/// line only:
///
/// - **When.** A server that `ServerHardening` sweeps (a Linux server that joined, and the hub's own server by the
///   hub's own reading), whose current reading says that its users' processes have no memory limit (`memory_guard`
///   false), in two rounds in a row; never in the hour after its join or the hub's claim, and never while a job of
///   its service is open. A reading with no such fact (a helper or a hub from before owner API 1.211, a system whose
///   kernel has no such file) says nothing.
/// - **What.** `program`, as root: the swap file where the server has no swap, and the limit's file, each as the
///   join writes it, byte for byte. It is this app's own program and never code of the server's own checkout, which
///   the service's user can change.
/// - **How often, and never against a choice.** As `ServerHardening`: its `step`, its `turn` and its kept `Memory`,
///   under a record of this sweep's own, because a server whose SSH and npm were settled long ago still needs this.
///   A server is settled once a reading says that the limit holds, or once a run says so or says that the kernel has
///   no group to limit. The swap file is a best try: a server whose disk or file system cannot take one is settled
///   by its limit alone.
public enum ServerMemory {
    /// The swap file of the join, its line in the table and the kernel's setting beside it: `hubsetup.py`'s
    /// `SWAP_FILE`, `SWAP_LINE`, `SWAP_SYSCTL` and `SWAP_SYSCTL_TEXT`.
    public static let swapFile = "/swapfile"
    public static let swapLine = swapFile + " none swap sw 0 0"
    public static let table = "/etc/fstab"
    public static let swapSysctl = "/etc/sysctl.d/60-fleet-swap.conf"
    public static let swapSysctlText = "# Founderizer writes this file (hubsetup.py harden) with its swap file, "
        + "/swapfile: the kernel takes that swap\n# as a reserve for a moment of full memory, and not as working "
        + "memory.\n# To undo both: swapoff /swapfile, delete /swapfile, its line in /etc/fstab and this file, then "
        + "run\n# sysctl -w vm.swappiness=60\nvm.swappiness = 10\n"
    /// The limit's file and its text: `hubsetup.py`'s `MEMORY_DIR`, `MEMORY_LIMIT` and `MEMORY_TEXT`. The limit of
    /// swap is a percent of the memory too: on a server of less than 8 GB it is less than the swap file, so a job
    /// that leaks ends sooner there and a part of the swap stays free; on a larger server it is the whole file.
    /// The file's name sorts before the usual names of such files on purpose: systemd takes a unit's drop-ins from
    /// all its places in the order of their file names, and the last one that sets a value decides, so a file of the
    /// server's own decides over this one, also one that comes later, unless its name sorts before this one's.
    public static let limitFolder = "/etc/systemd/system/user.slice.d"
    public static let limitFile = limitFolder + "/00-fleet-memory.conf"
    public static let limitText = "# Founderizer writes this file (hubsetup.py harden): all users' processes together "
        + "(the agents' sessions and\n# their helpers, the fleet's own services, each login) get at most 85% of this "
        + "server's memory, and of its\n# swap as much as half of the memory. When both are full, the kernel ends the "
        + "largest process of that group.\n# SSH, Tailscale and the system's own services are not in the group and "
        + "keep the rest, so the server still\n# takes a login. systemd reads the percents at each start, so they "
        + "follow a server that grows.\n# A file of this server's own that sets MemoryMax for user.slice decides over "
        + "this one when its name sorts\n# after this file's: systemd takes such files in the order of their names, "
        + "and the last one decides.\n# To undo it: delete this file, then run  systemctl daemon-reload\n[Slice]\n"
        + "MemoryAccounting=yes\nMemoryMax=85%\nMemorySwapMax=50%\n"
    /// The kernel's own file for the limit of all users' processes (`lifecycle.USER_SLICE_MAX`).
    public static let kernelLimit = "/sys/fs/cgroup/user.slice/memory.max"
    /// The places where systemd reads a unit's files and its drop-ins (`hubsetup.py`'s `MEMORY_PLACES`): a file of
    /// the server's own in any of them that sets a limit for `user.slice` is the server's choice.
    public static let limitPlaces = ["/etc/systemd/system.control", "/run/systemd/system.control",
                                     "/run/systemd/transient", "/etc/systemd/system", "/run/systemd/system",
                                     "/usr/local/lib/systemd/system", "/usr/lib/systemd/system", "/lib/systemd/system"]
    /// The largest swap file in GiB, and the GiB of disk that stay free beside it (`SWAP_MOST`, `SWAP_SPARE`).
    public static let swapMost = 4
    public static let swapSpare = 5
    /// The first word of the program's last line, and its first line (`ServerHardening.started` says why it has one).
    static let mark = "founderizer-memory"
    public static let started = "founderizer-memory-started"

    // MARK: when

    /// What one round reads of a server's memory limit, in `ServerHardening`'s words: `.faulty` for no limit,
    /// `.holds` for a limit, `.unread` for everything that cannot say.
    public static func reading(of server: ServerEntry, join: JoinState?, at time: Double) -> ServerHardening.Reading {
        reading(of: server, join: join, at: time, hub: { $0.memory_guard }, server: { $0.memory_guard })
    }

    /// What one round reads of one fact of a server, as `reading(of:join:at:)` reads the memory limit's: the hub's own
    /// read of its own server (`hub`), else the server's own reading (`server`). `ServerRestart` reads its fact so.
    static func reading(of server: ServerEntry, join: JoinState?, at time: Double, hub own: (HubHardening) -> Bool?,
                        server fact: (ServerReading.Security) -> Bool?) -> ServerHardening.Reading {
        guard ServerHardening.applies(to: server), server.job?.isOpen != true else { return .unread }
        if let join, join.server == server.name, time - join.created < ServerHardening.joinGrace { return .unread }
        let holds: Bool?
        if server.hub {
            guard let read = server.hardening, read.isCurrent(at: time),
                  let claimed = read.claimed_at, time - claimed >= ServerHardening.joinGrace else { return .unread }
            holds = own(read)
        } else {
            guard let reading = server.reading, reading.source == "server", reading.isCurrent(at: time),
                  let security = reading.security else { return .unread }
            holds = fact(security)
        }
        return holds.map { $0 ? .holds : .faulty } ?? .unread
    }

    // MARK: what

    /// **The program, as root on the server**, in the order of `hubsetup.harden_swap` and `harden_memory`.
    ///
    /// The swap file first. Nothing where the kernel's list cannot be read, where the server has swap, where its
    /// table names a swap of its own, or where a file or a link is at the name. Else the size is the memory in whole
    /// GiB, `swapMost` at most; no file where the file system of `/` is not ext4 or the disk would keep less than
    /// `swapSpare` GiB free. The file is made for root only before it has any size, and only where nothing is at its
    /// name (`set -C`). A step that fails takes the file away again, and so does a stop of the program between the
    /// file's making and the table's line (`trap`, which takes nothing away once the table names the file: the swap
    /// is whole then); the table is written whole, beside itself and then moved, and a
    /// table that cannot be written takes the swap away too, so that no start finds half of it. A program that is
    /// killed outright in that time can leave the file with no line: each later run then leaves the swap as it is.
    ///
    /// Then the limit. Nothing where the kernel has no file for the users' group; nothing where a file of the
    /// server's own sets such a limit (`MemoryMax=`, or `MemoryLimit=` by its old name) for `user.slice` or for
    /// every slice, in any place that systemd reads, also one that systemd has not read yet (its name goes to the
    /// log); and nothing where that group has a limit and this file is not there. Else the file goes in place
    /// unless it holds the text already, systemd reads its files again, and the kernel's file says whether the limit
    /// holds.
    ///
    /// The last line is `mark` with what each part came to. `root` puts every path under a folder, for the tests; on
    /// a server it is "".
    public static func program(root: String = "") -> String {
        let r = InstallPlan.quote(root)
        return """
            printf '\\n%s\\n' \(started) || exit 1
            r=\(r); w=; l=; p="$r/proc/swaps"; t="$r\(table)"; f="$r\(swapFile)"; y="$r\(swapSysctl)"
            if [ ! -r "$p" ]; then w=unread
            elif [ -n "$(tail -n +2 "$p" | tr -d '[:space:]')" ]; then w=held
            elif [ -r "$t" ] && awk '$1 !~ /^#/ && $3 == "swap" {f = 1} END {exit !f}' "$t"; then w=named
            elif [ -e "$f" ] || [ -L "$f" ]; then w=file-there
            elif [ ! -r "$t" ]; then w=no-table
            else
              m=$(awk '/^MemTotal:/ {print $2; exit}' "$r/proc/meminfo" 2>/dev/null)
              case "$m" in ''|*[!0-9]*|0) w=no-memory;; esac
              if [ -z "$w" ]; then
                g=$(( (m + 1048575) / 1048576 )); [ "$g" -le \(swapMost) ] || g=\(swapMost)
                k=$(stat -f -c %T / 2>/dev/null)
                a=$(df -Pk "${r:-/}" 2>/dev/null | awk 'NR == 2 {print $4}')
                case "$a" in ''|*[!0-9]*) a=0;; esac
                if [ "$k" != ext2/ext3 ] && [ "$k" != ext4 ]; then w=no-system
                elif [ "$a" -lt $(( (g + \(swapSpare)) * 1048576 )) ]; then w=no-space
                elif ! { trap 'grep -q "^\(swapFile) " "$t" 2>/dev/null || { swapoff "$f" 2>/dev/null; rm -f "$f"; }
            exit 1' HUP INT TERM; ( umask 077; set -C; : > "$f" ) 2>/dev/null; }; then trap - HUP INT TERM; w=not-made
                elif o=$(fallocate -l $(( g * 1073741824 )) "$f" 2>&1) && o=$(mkswap -q "$f" 2>&1) \
            && o=$(swapon "$f" 2>&1); then
                  n=$(mktemp "$t.fleet-XXXXXX") && cp -p "$t" "$n" \
            && { [ -z "$(tail -c1 "$n")" ] || echo >> "$n"; } && printf '%s\\n' '\(swapLine)' >> "$n" \
            && mv -f "$n" "$t" || { [ -z "$n" ] || rm -f "$n"; swapoff "$f" 2>/dev/null; rm -f "$f"; w=no-table; }
                  trap - HUP INT TERM
                  if [ -z "$w" ]; then
                    mkdir -p "${y%/*}" && n=$(mktemp "$y.XXXXXX") \
            && printf '%s' \(InstallPlan.quote(swapSysctlText)) > "$n" && chmod 644 "$n" && mv -f "$n" "$y" \
            && sysctl -q -p "$y" >/dev/null 2>&1 || { [ -z "$n" ] || rm -f "$n"; }
                    w=made-${g}G
                  fi
                else
                  printf '%s\\n' "$o" | tail -n 2; swapoff "$f" 2>/dev/null; rm -f "$f"; trap - HUP INT TERM; w=failed
                fi
              fi
            fi
            c="$r\(kernelLimit)"; d="$r\(limitFolder)"; x="$r\(limitFile)"; n=
            v=$(cat "$c" 2>/dev/null)
            case "$v" in max) v=none;; ''|*[!0-9]*) v=;; *) v=limit;; esac
            q=$(for z in \(limitPlaces.joined(separator: " ")); do
              { find "$r$z/user.slice.d" -maxdepth 1 -name '*.conf' ! -name '.*' 2>/dev/null | sort
                echo "$r$z/user.slice"
                find "$r$z/slice.d" -maxdepth 1 -name '*.conf' ! -name '.*' 2>/dev/null | sort; } |
              while IFS= read -r e; do
                [ "$e" = "$x" ] || ! grep -E -q '^[[:space:]]*Memory(Max|Limit)[[:space:]]*=' "$e" 2>/dev/null \
            || echo "$e"
              done
            done | head -n 1)
            if [ -z "$v" ]; then l=no-group
            elif [ -n "$q" ]; then q=${q#"$r"}; echo "this server's own setting of the memory limit: $q"; l=own
            elif [ "$v" = limit ] && [ ! -e "$x" ]; then l=own
            else
              { [ -d "$d" ] || { mkdir -p "$d" && chmod 755 "$d"; }; } && n=$(mktemp "$d/.fleet-XXXXXX") \
            && printf '%s' \(InstallPlan.quote(limitText)) > "$n" && chmod 644 "$n" || l=not-written
              if [ -z "$l" ] && ! cmp -s "$n" "$x"; then mv -f "$n" "$x" || l=not-written; fi
              [ -z "$n" ] || rm -f "$n"
              if [ -z "$l" ]; then
                systemctl daemon-reload >/dev/null 2>&1
                v=$(cat "$c" 2>/dev/null)
                case "$v" in ''|*[!0-9]*) l=not-yet;; *) l=set;; esac
              fi
            fi
            echo "\(mark) swap=$w limit=$l"
            """
    }

    /// The run's output, read as `ServerHardening.outcome` reads its own, from the last `mark` line. The limit
    /// decides: it holds where the program set it or found the server's own, and a server whose kernel has no group
    /// to limit is left as it is. The swap file is a best try and never a failure of the run; the log has its word.
    public static func outcome(_ output: String) -> ServerHardening.Outcome {
        let (parts, before): ([String: String], String)
        switch marked(output, mark: mark, started: started) {
        case .ended(let words, let said): (parts, before) = (words, said)
        case .not(let outcome): return outcome
        }
        let swap = parts["swap"] ?? "", limit = parts["limit"] ?? ""
        if limit == "no-group" { return .leftAsItIs }
        if ["set", "own"].contains(limit) { return .holds }
        return .failed("limit \(limit.isEmpty ? "?" : limit), swap \(swap.isEmpty ? "?" : swap)"
                       + (before.isEmpty ? "" : ": " + String(before.prefix(300))))
    }

    /// A run's output up to its last `mark` line: that line's words as `name=value`, and the last three lines that the
    /// program said before it; else what a run with no such line came to. Output without one is a run that did not end
    /// where it has the program's first line (`started`): the connection broke, or the program was stopped. Without
    /// that line too, it reads as a program that did not start. `ServerRestart` reads its own output so.
    enum Marked {
        case ended([String: String], before: String)
        case not(ServerHardening.Outcome)
    }

    static func marked(_ output: String, mark: String, started: String) -> Marked {
        let all = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let lines = all.filter { $0 != started }
        guard let last = lines.last(where: { $0.hasPrefix(mark + " ") }) else {
            let said = lines.last(where: { !$0.isEmpty }).map { String($0.prefix(200)) } ?? "nothing"
            return .not(lines.count == all.count ? .notStarted("the program did not start: \(said)")
                        : .failed("the program started and did not end: \(said)"))
        }
        var parts: [String: String] = [:]
        for word in last.split(separator: " ").dropFirst() {
            let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parts[pair[0]] = pair[1] }
        }
        return .ended(parts, before: lines.prefix { $0 != last }.filter { !$0.isEmpty }.suffix(3)
            .joined(separator: " "))
    }
}
