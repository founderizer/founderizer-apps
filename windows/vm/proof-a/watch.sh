#!/bin/bash
# watch.sh: the window watcher of proof A in a clean PC's copy (watch.ps1): it logs each top-level window that becomes
# visible in the desktop session, with its class and its program, and the proof fails when a console showed.
#
#   FZ_PROOF_A_COPY=<name> watch.sh start   before the setup starts: the watcher runs, with no window of its own
#   FZ_PROOF_A_COPY=<name> watch.sh read    the log so far, and its summary
#   FZ_PROOF_A_COPY=<name> watch.sh stop    at the end of the run: the watcher stops; the log and its summary
#
# The log goes to FZ_PROOF_A_FILES/logs/<copy>-windows-<time>.log. The summary lists each new window by its class and
# its program, and exits 1 when one is a console or could not be read.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077
use_copy

summary() {
    python3 -I - "$1" <<'PY'
import sys
rows = [line.rstrip("\n").split("\t") for line in open(sys.argv[1], encoding="utf-8-sig") if line.strip()]
new = [r for r in rows if len(r) >= 9 and r[1] == "new"]
starts = [r for r in rows if len(r) >= 2 and r[1] == "watching"]
stops = [r for r in rows if len(r) >= 2 and r[1] == "stopped"]
print(f"watching since {starts[-1][0] if starts else '(no start line)'}"
      + (f", stopped {stops[-1][0]}" if stops else ", still running"))
print(f"{len(new)} new visible top-level windows")
for r in new:
    print(f"  {r[0]}  {r[3]}  {r[5].rsplit(chr(92), 1)[-1]}  {r[7]}  {r[8]}")
bad = [r for r in new if r[8] != "-"]
consoles = sum(1 for r in bad if r[8] == "console")
print(f"consoles: {consoles}; windows that could not be read: {len(bad) - consoles}")
sys.exit(1 if bad or not starts else 0)
PY
}

fetch() {
    local out="$1"
    mkdir -p "$proof_files/logs"
    "$vm_sh" copy "vm:C:/fz/proof-a/windows.log" "$out"
}

case "${1:-}" in
start)
    "$vm_sh" run 'New-Item -ItemType Directory -Force -Path C:\fz\proof-a | Out-Null'
    "$vm_sh" copy "$proof_here/watch.ps1" vm:C:/fz/proof-a/
    run_ps watch-task.ps1 do=start
    ;;
read)
    out="$proof_files/logs/$FZ_PROOF_A_COPY-windows-so-far.log"
    fetch "$out"
    summary "$out"
    ;;
stop)
    run_ps watch-task.ps1 do=stop
    out="$proof_files/logs/$FZ_PROOF_A_COPY-windows-$(date -u +%Y%m%dT%H%M%SZ).log"
    fetch "$out"
    proof_say "the log: $out"
    summary "$out"
    ;;
*)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
