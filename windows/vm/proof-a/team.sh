#!/bin/bash
# team.sh: the hub's team.json in proof A, as the clean PC reads it (team-read.ps1), and its compare with the team that
# the Mac's install line makes for the same choices (team_compare.py), "but for the names".
#
#   FZ_PROOF_A_COPY=<copy> team.sh read     the read in the copy's desktop session, with the PC's own key from the app's
#                                           secret box (in memory only); the file has no key and no address
#   team.sh compare <reference> <read>      the compare; exit 1 with one line for each difference
#
# The read goes to FZ_PROOF_A_FILES/logs/<copy>-team-<time>.json. The references are in FZ_PROOF_A_FILES/reference/
# (team-reference.sh).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077

case "${1:-}" in
read)
    use_copy
    "$vm_sh" run 'New-Item -ItemType Directory -Force -Path C:\fz\proof-a | Out-Null'
    "$vm_sh" copy "$proof_here/team-read.ps1" vm:C:/fz/proof-a/
    "$vm_sh" desktop '& C:\fz\proof-a\team-read.ps1 -Out C:\fz\proof-a\team-read.json'
    mkdir -p "$proof_files/logs"
    out="$proof_files/logs/$FZ_PROOF_A_COPY-team-$(date -u +%Y%m%dT%H%M%SZ).json"
    "$vm_sh" copy vm:C:/fz/proof-a/team-read.json "$out"
    "$vm_sh" run 'Remove-Item -Path C:\fz\proof-a\team-read.json'
    proof_say "the read: $out"
    ;;
compare)
    [ $# -eq 3 ] || proof_die "compare needs the reference and the read"
    python3 -I "$proof_here/team_compare.py" "$2" "$3"
    ;;
*)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
