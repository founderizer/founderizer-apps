#!/bin/bash
# primary-ips.sh: before run 1, how many primary IPs the Hetzner account has free. The account's limit counts the
# primary IPs of all its projects together, and run 1 makes two servers, each with one. Hetzner's API answers for one
# project at a time and does not give the limit, so this reads every hcloud context of this Mac (read only: a list, no
# change) and subtracts their sum from the limit that the owner reads on the console's Limits page.
#
#   primary-ips.sh [--limit 72] [--need 2]
#
# A project with no context on this Mac is not counted: the owner's own count on the Limits page decides.
set -uo pipefail
limit=72 need=2
while [ $# -gt 0 ]; do
    case "$1" in --limit) limit="$2"; shift 2 ;; --need) need="$2"; shift 2 ;; *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
done
ids=""
for context in $(hcloud context list -o noheader -o columns=name 2>/dev/null); do
    # Two contexts can name one project: an IP is counted once, by its id, which is the same in every context.
    if ! list="$(hcloud --context "$context" primary-ip list -o noheader -o columns=id 2>/dev/null)"; then
        echo "$context: not read"
        continue
    fi
    echo "$context: $(printf '%s\n' "$list" | grep -c .) primary IPs"
    ids="$ids
$list"
done
used="$(printf '%s\n' "$ids" | grep . | sort -u | grep -c .)"
free=$((limit - used))
echo "in use in the projects of this Mac's contexts: $used of $limit; free: $free; run 1 needs $need"
[ "$free" -ge "$need" ]
