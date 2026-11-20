import Foundation

/// **A server that stops restarts by itself, put right by the owner's Mac** (the owner's "Yes, build it" of 17
/// November 2026, to a fleet that looks after its own servers).
///
/// The join of a Linux server has it restart by itself when it stops (`hubsetup.py harden`, owner API 1.229): the
/// kernel restarts it 10 seconds after a kernel panic, where Ubuntu's default waits forever, and the kernel's software
/// watchdog restarts it when systemd stops for 10 minutes. A server at Hetzner has no watchdog device of its own, and
/// in November 2026 a server that stopped answered nothing until a restart at its provider, which came to the owner as
/// a card. A server that joined before that version has neither. As `ServerMemory` does for the memory limit, the
/// owner's Mac puts it right by itself, with nothing on a page and a log line only:
///
/// - **When.** A server that `ServerHardening` sweeps, whose current reading says that it does not restart by itself
///   (`restart_guard` false), in two rounds in a row; never in the hour after its join or the hub's claim, and never
///   while a job of its service is open (`ServerMemory.reading`). A reading with no such fact says nothing.
/// - **What.** `program`, as root: each file as the join writes it, byte for byte, and the join's own commands. It is
///   this app's own program and never code of the server's own checkout, which the service's user can change.
/// - **How often, and never against a choice.** As `ServerMemory`, under a record of its own (`keptKey`). Each
///   setting of the server's own stays, as the join leaves it: a sysctl file that sets kernel.panic, a kernel that
///   restarts after a panic with no file of the join's, a file of systemd's own that sets RuntimeWatchdogSec, a link
///   at one of the join's files, the watchdog program, and a watchdog that is active. A container, a system that
///   systemd does not run, and a kernel that does not say what it does after a panic are left as they are.
public enum ServerRestart {
    /// What this Mac keeps of each server for this part (`ServerHardening.Memory`, as the memory limit's
    /// `serverMemoryLimit`), which Start again forgets for a hub (`StartAgain.forgetKept`).
    public static let keptKey = "serverRestart"
    /// The restart after a kernel panic: `hubsetup.py`'s `RESTART_PANIC_FILE` and `RESTART_PANIC_TEXT`.
    public static let panicFile = "/etc/sysctl.d/60-fleet-restart.conf"
    public static let panicText = "# Founderizer writes this file (hubsetup.py harden): after a kernel panic the kernel "
        + "restarts this server\n# after 10 seconds, where with its default (0) it waits forever and the server answers "
        + "nothing.\n# To undo it: delete this file, then run  sysctl -w kernel.panic=0\nkernel.panic = 10\n"
    /// The unit that loads the kernel's software watchdog at each start, and systemd's own drop-in that has systemd
    /// ping it: `RESTART_UNIT_NAME`, `RESTART_UNIT`, `RESTART_UNIT_TEXT`, `RESTART_CONF` and `RESTART_CONF_TEXT`.
    /// systemd reads the drop-in again at `systemctl daemon-reload`, so the program gives it no time of its own.
    public static let unitName = "fleet-watchdog.service"
    public static let unitFile = "/etc/systemd/system/" + unitName
    public static let unitText = "# Founderizer writes this file (hubsetup.py harden): it loads the kernel's software "
        + "watchdog at each start,\n# which systemd pings (00-fleet-watchdog.conf). Ubuntu lists softdog among the "
        + "modules that never load by\n# themselves, and systemd's own loader keeps that list, so a file in "
        + "modules-load.d would not load it.\n# To undo it: systemctl disable fleet-watchdog.service, delete this file "
        + "and 00-fleet-watchdog.conf, then\n# run  systemctl daemon-reload\n[Unit]\nDescription=The kernel's software "
        + "watchdog, which systemd pings\nDefaultDependencies=no\nBefore=sysinit.target\n\n[Service]\nType=oneshot\n"
        + "TimeoutStartSec=30s\nExecStart=-/sbin/modprobe softdog\n\n[Install]\nWantedBy=sysinit.target\n"
    public static let confFile = "/etc/systemd/system.conf.d/00-fleet-watchdog.conf"
    public static let confText = "# Founderizer writes this file (hubsetup.py harden): systemd pings the watchdog "
        + "device that\n# fleet-watchdog.service loads, and when systemd stops for 10 minutes the watchdog restarts "
        + "this server.\n# A drop-in of this server's own that sets RuntimeWatchdogSec decides over this one when its "
        + "name sorts\n# after this file's: systemd takes such files in the order of their names, and the last one "
        + "decides.\n# To undo it: delete this file, then run  systemctl daemon-reload\n[Manager]\n"
        + "RuntimeWatchdogSec=10min\n"
    /// Where a start reads sysctl's files (`SYSCTL_SOURCES`, then `SYSCTL_CONF`), and where systemd reads its own
    /// configuration (`RESTART_CONF_PLACES`: its file first, then the folders of its drop-ins).
    public static let sysctlPlaces = ["/etc/sysctl.d", "/run/sysctl.d", "/usr/local/lib/sysctl.d", "/usr/lib/sysctl.d",
                                      "/lib/sysctl.d"]
    public static let sysctlFile = "/etc/sysctl.conf"
    public static let confPlaces = ["/etc/systemd/system.conf", "/etc/systemd/system.conf.d", "/run/systemd/system.conf.d",
                                    "/usr/local/lib/systemd/system.conf.d", "/usr/lib/systemd/system.conf.d"]
    /// The watchdog program itself (`RESTART_DAEMON`; its file in /etc stays after an `apt remove`), and the marks of a
    /// container (`lifecycle.CONTAINER_MARKS`), both in /run, so that no disk image made from a container keeps them.
    public static let daemonFile = "/usr/sbin/watchdog"
    public static let containerMarks = ["/run/systemd/container", "/run/.containerenv"]
    /// The link that enabling the unit makes (`RESTART_WANTS`), softdog's load now (`RESTART_LOAD`), and the seconds
    /// after which systemd reads its files once more where no watchdog is active (`RESTART_RETRY`): systemd 259 tries
    /// to open a device at most once in five seconds, so a try before softdog loaded can hold back the reload's.
    public static let wantsLink = "/etc/systemd/system/sysinit.target.wants/" + unitName
    public static let load = "modprobe softdog"
    public static let retry = 6
    /// The kernel's own files that the server's reading says it by (`lifecycle.PANIC_SECONDS`, `WATCHDOG_DEVICES`).
    public static let kernelPanic = "/proc/sys/kernel/panic"
    public static let watchdogs = "/sys/class/watchdog"
    /// The first word of the program's last line, and its first line (`ServerHardening.started` says why it has one).
    static let mark = "founderizer-restart"
    public static let started = "founderizer-restart-started"

    // MARK: when

    /// What one round reads of a server's restart, in `ServerHardening`'s words: `.faulty` when it does not restart by
    /// itself, `.holds` when it does, `.unread` for everything that cannot say.
    public static func reading(of server: ServerEntry, join: JoinState?, at time: Double) -> ServerHardening.Reading {
        ServerMemory.reading(of: server, join: join, at: time, hub: { $0.restart_guard }, server: { $0.restart_guard })
    }

    // MARK: what

    /// **The program, as root on the server**, in the order of `hubsetup.harden_panic` and `harden_watchdog`, with
    /// their rules.
    ///
    /// Nothing in a container. The restart after a kernel panic: nothing where a sysctl file of the server's own sets
    /// kernel.panic (a line, not a comment, whose key names it as systemd-sysctl reads a key: "/" as ".", a "-" before
    /// it, a glob; of each file name only the one in the first folder that has it, as a start reads them; of those
    /// the first by name, then `/etc/sysctl.conf`), where a link is at the join's file, where the kernel's file cannot
    /// be read, and where the kernel restarts after a panic with no file of the join's; the setting's place goes to
    /// the log. Else the file goes in place unless it holds the text already, and sysctl takes it unless the kernel's
    /// value is in force already.
    ///
    /// Then the watchdog. Nothing where systemd does not run the system, where a file of systemd's own configuration
    /// sets RuntimeWatchdogSec, where a link is at one of the join's two files, where the watchdog program is
    /// installed, and where a watchdog is active with no drop-in of the join's. Else each file goes in place unless it
    /// holds its text already (the drop-in only once the unit is written), and unless both hold their texts, the unit
    /// is enabled and a watchdog is active, the unit is enabled with no reload (an enable that fails leaves no device,
    /// so the server's reading stays false and a later round runs again), softdog loads, and systemd reads its files
    /// again, which opens the device; where no watchdog is active then, systemd reads its files once more `retry`
    /// seconds later. A command that fails says so, and the kernel's own files then say whether a watchdog is active.
    ///
    /// Each file is written whole beside itself, under a name with a dot that no reader takes, and then moved. The
    /// last line is `mark` with what each part came to. `root` puts every path under a folder, for the tests; on a
    /// server it is "". A pattern of `case` has its `(` before it: bash 3.2, the `/bin/sh` of a Mac, otherwise ends a
    /// `$(...)` at the pattern's `)`.
    public static func program(root: String = "") -> String {
        let r = InstallPlan.quote(root)
        return #"""
            printf '\n%s\n' \#(started) || exit 1
            r=\#(r); p=; w=; n=; x=
            k="$r\#(kernelPanic)"; y="$r\#(panicFile)"; u="$r\#(unitFile)"; c="$r\#(confFile)"
            put() {
              n=; { [ -d "${1%/*}" ] || { mkdir -p "${1%/*}" && chmod 755 "${1%/*}"; }; } \
            && n=$(mktemp "${1%/*}/.fleet-XXXXXX") && printf '%s' "$2" > "$n" && chmod 644 "$n" \
            || { [ -z "$n" ] || rm -f "$n"; return 2; }
              if cmp -s "$n" "$1"; then rm -f "$n"; return 1; fi
              mv -f "$n" "$1" || { rm -f "$n"; return 2; }
            }
            sets() {
              awk 'NR == 1 { sub(/^\357\273\277/, "") }
                { sub(/^[ \t\r]+/, ""); sub(/[ \t\r]+$/, "") }
                $0 == "" || /^[#;]/ || !index($0, "=") { next }
                { k = substr($0, 1, index($0, "=") - 1); sub(/[ \t]+$/, "", k); sub(/^-+/, "", k); sub(/^[ \t]+/, "", k)
                  gsub(/\//, ".", k); if (k != "") print k }' "$1" 2>/dev/null |
              while IFS= read -r t; do case kernel.panic in ($t) echo y; break;; esac; done
            }
            active() {
              for s in "$r\#(watchdogs)"/watchdog*/state; do [ "$(cat "$s" 2>/dev/null)" = active ] && return 0; done
              return 1
            }
            tell() { [ -z "$h" ] || printf '%s\n' "$h" | tail -n 2; }
            for m in \#(containerMarks.joined(separator: " ")); do { [ -e "$r$m" ] || [ -L "$r$m" ]; } && x=y; done
            o=$(s=/
              for z in \#(sysctlPlaces.joined(separator: " ")); do
                for e in "$r$z"/*.conf; do
                  b=${e##*/}; case "$s" in (*"/$b/"*) continue;; esac; s="$s$b/"
                  [ -f "$e" ] && [ "$e" != "$y" ] && [ -n "$(sets "$e")" ] && printf '%s/%s\n' "$b" "$e"
                done
              done | LC_ALL=C sort | head -n 1 | sed 's|^[^/]*/||')
            [ -n "$o" ] || { [ -f "$r\#(sysctlFile)" ] && [ -n "$(sets "$r\#(sysctlFile)")" ] && o="$r\#(sysctlFile)"; }
            v=$(cat "$k" 2>/dev/null)
            if [ -n "$x" ]; then p=container
            elif [ -n "$o" ] && [ -e "$y" ] && [ ! -L "$y" ]; then
              echo "this server's own setting of kernel.panic: ${o#"$r"}, beside this step's file of an earlier run"; p=own
            elif [ -n "$o" ]; then echo "this server's own setting of kernel.panic: ${o#"$r"}"; p=own
            elif [ -L "$y" ]; then echo "this server's own setting of kernel.panic: a link at ${y#"$r"}"; p=own
            else
              case "$v" in (''|*[!0-9-]*) p=unread;; esac
              if [ -n "$p" ]; then :
              elif [ ! -e "$y" ] && [ "$v" != 0 ]; then
                echo "this server's own setting of kernel.panic: the kernel restarts $v seconds after one"; p=own
              else
                put "$y" \#(InstallPlan.quote(panicText)); e=$?
                if [ "$e" = 2 ]; then p=not-written
                elif [ "$e" = 1 ] && [ "$v" != 0 ]; then p=held
                else
                  sysctl -q -p "$y" >/dev/null 2>&1
                  v=$(cat "$k" 2>/dev/null)
                  case "$v" in (''|0|*[!0-9-]*) p=not-yet;; (*) p=set;; esac
                fi
              fi
            fi
            if [ -n "$x" ]; then w=container
            elif [ ! -d "$r/run/systemd/system" ]; then w=no-systemd
            else
              q=$( { [ ! -f "$r\#(confPlaces[0])" ] || echo "$r\#(confPlaces[0])"
                     for z in \#(confPlaces.dropFirst().joined(separator: " ")); do
                       find -L "$r$z" -maxdepth 1 -name '*.conf' ! -name '.*' 2>/dev/null | LC_ALL=C sort
                     done; } |
                   while IFS= read -r e; do
                     [ "$e" = "$c" ] || ! grep -E -q '^[[:blank:]]*RuntimeWatchdogSec[[:blank:]]*=' "$e" 2>/dev/null \
            || echo "$e"
                   done | head -n 1)
              if [ -n "$q" ] && [ -e "$c" ] && [ ! -L "$c" ]; then
                echo "this server's own setting of the watchdog: ${q#"$r"}, beside this step's file of an earlier run"
                w=own
              elif [ -n "$q" ]; then echo "this server's own setting of the watchdog: ${q#"$r"}"; w=own
              elif [ -L "$u" ] || [ -L "$c" ]; then
                echo "this server's own setting of the watchdog: a link at a file of this step's"; w=own
              elif [ -e "$r\#(daemonFile)" ] || [ -L "$r\#(daemonFile)" ]; then
                echo "this server's own watchdog program is installed: \#(daemonFile)"; w=own
                [ ! -e "$c" ] || echo "this step's files of an earlier run take the device from it at each start"
              elif active && [ ! -e "$c" ]; then w=own
              else
                put "$u" \#(InstallPlan.quote(unitText)); f=$?
                if [ "$f" = 2 ]; then g=2; else put "$c" \#(InstallPlan.quote(confText)); g=$?; fi
                if [ "$f" = 2 ] || [ "$g" = 2 ]; then w=not-written
                elif [ "$f" = 1 ] && [ "$g" = 1 ] && [ -L "$r\#(wantsLink)" ] && active; then w=held
                elif ! h=$(systemctl enable --no-reload \#(unitName) 2>&1); then tell; w=not-yet
                elif ! h=$(\#(load) 2>&1); then tell; w=not-yet
                else
                  h=$(systemctl daemon-reload 2>&1)
                  active || { sleep \#(retry); h=$(systemctl daemon-reload 2>&1); }
                  if active; then w=set; else h=${h:-systemd opened no watchdog device}; tell; w=not-yet; fi
                fi
              fi
            fi
            echo "\#(mark) panic=$p watchdog=$w"
            """#
    }

    /// The run's output, read as `ServerMemory.outcome` reads its own (`ServerMemory.marked`). Both parts decide: the
    /// server is settled where each part holds (set, held, or the server's own), and left as it is in a container,
    /// where the kernel does not say what it does after a panic, and where systemd does not run it.
    public static func outcome(_ output: String) -> ServerHardening.Outcome {
        let (parts, before): ([String: String], String)
        switch ServerMemory.marked(output, mark: mark, started: started) {
        case .ended(let words, let said): (parts, before) = (words, said)
        case .not(let outcome): return outcome
        }
        let panic = parts["panic"] ?? "", watchdog = parts["watchdog"] ?? ""
        if ["unread", "container"].contains(panic) || ["no-systemd", "container"].contains(watchdog) { return .leftAsItIs }
        let done = ["set", "held", "own"]
        if done.contains(panic) && done.contains(watchdog) { return .holds }
        return .failed("panic \(panic.isEmpty ? "?" : panic), watchdog \(watchdog.isEmpty ? "?" : watchdog)"
                       + (before.isEmpty ? "" : ": " + String(before.prefix(300))))
    }
}
