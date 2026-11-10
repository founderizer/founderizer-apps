#!/bin/zsh
# Fleet's starter on a Mac. The owner, 4 November 2026: "Build the starter".
#
# That day macOS 27.2 installed itself on the Mac Studio and restarted it. Its Setup Assistant then stayed open on a
# screen that nobody watched, and while it is open launchd starts no job of that user by itself: not at load, not by
# its timer, and not again after an exit. Every Founderizer agent of that Mac, its server service and its vault stayed
# down until a person started each one with `launchctl kickstart`. This does the same from the system domain, which
# that state does not hold.
#
# launchd runs it as root every minute (com.agentfleet.starter, which update.zsh puts in place beside it). It starts a
# job of the vault's user only when launchd itself holds it back: the job is loaded (one that a person unloaded stays
# off), it is not running, and launchd keeps a start of it pending for any reason but "inefficient", its throttle of a
# job that keeps failing, which a start would only repeat. Each start is one line in starter.log beside it.
starter=1
set -u

# The paths and the PATH are a test's to change. launchd gives this script no environment of its own, so on a Mac they
# are always the defaults.
base="${FLEET_STARTER_BASE:-/Library/Application Support/Fleet Vault}"
export PATH="${FLEET_STARTER_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

uid=$(plutil -extract worker_uid raw -o - "$base/config.json" 2>/dev/null || true)
[[ "$uid" =~ '^[0-9]+$' ]] || exit 0                         # the owner's own Mac, whose vault runs no agent
domain=$(launchctl print "gui/$uid" 2>/dev/null) || exit 0    # that user is not logged in yet: the next minute
for label in ${(u)${(f)"$(print -r -- "$domain" | grep -oE 'com\.agentfleet\.[A-Za-z0-9._-]+')"}}; do
    job=$(launchctl print "gui/$uid/$label" 2>/dev/null) || continue
    [[ "$job" == *"state = not running"* ]] || continue
    pended=$(print -r -- "$job" | sed -n 's/^[[:space:]]*pended nondemand spawn = //p' | head -1)
    [[ -n "$pended" && "$pended" != inefficient ]] || continue
    if launchctl kickstart "gui/$uid/$label" >/dev/null 2>&1; then
        print -r -- "$(date -u '+%Y-%m-%d %H:%M:%S') started $label of user $uid, which launchd held ($pended)"
    fi
done
exit 0
