#!/bin/zsh
# Fleet Vault's own updater on a Mac. The owner, 24 October 2026: "why are we not updating it automatically if it's
# part of the fleet?". On Linux each machine's server service brings vault.py up to date with a root command that the
# installer puts there once; this is the same thing for a Mac, whose vault is the signed Fleet Vault app in
# /Applications, which only root may replace.
#
# launchd runs it as root from /Library/LaunchDaemons/com.agentfleet.vault.update.plist, at load and every hour. It
# asks the release channel for the newest Mac build of its fleet's track — the manifest the Founderizer app updates
# itself from — takes the Fleet Vault that the build carries in Founderizer.app/Contents/Library, and puts it in place
# only when:
#   - the zip is the one the manifest names, by its SHA-256, from the channel's own host over HTTPS;
#   - the vault in it is signed by our Developer ID team with the vault's identifier, with the hardened runtime, its
#     provisioning profile and the one keychain group, as install.py checks a build that it installs;
#   - its build number is higher than the installed one's, so no channel can ever put an older vault back.
# Then launchd starts the worker's broker again for the user it runs as. The owner's Mac runs no broker: there the
# updater takes away the LaunchAgent of the old writer of Add secret, as `writer_gone` below says.
#
# The track (PRODUCT.md 4.3, "the two tracks") is the one that update.json names. The owner, 4 November 2026: "ok
# build your design". A fleet whose setting releases.early is on takes each build as it is published, as the
# Founderizer app that drives it does (`?track=early`), so a change to the vault runs on the owner's own Macs before
# any customer has it. Only the exact word early asks for that track; no value, or any other value, is the approved
# track that every customer takes. The track changes which manifest is read and nothing else: every check above stays.
#
# install.py writes this file, update.json beside it (the channel, the fleet's id and the track) and the daemon. A run
# that finds nothing newer prints nothing; its log is update.log beside it, in the folder that only root writes.
#
# The updater keeps itself current the same way: each vault build carries the updater it was built with, in
# Contents/Resources, sealed by the vault's signature, and one with a higher `updater=` number than this file's
# replaces this file for the next run. It puts the starter in place the same way (starter.zsh, with its `starter=`
# number, and its daemon), on a Mac whose vault runs as the agents' user.
updater=5
set -eu
umask 022

# The paths and the PATH are a test's to change. launchd gives this script no environment of its own, so on a Mac
# they are always the defaults.
base="${FLEET_VAULT_UPDATE_BASE:-/Library/Application Support/Fleet Vault}"
app="${FLEET_VAULT_UPDATE_APP:-/Applications/Fleet Vault.app}"
daemons="${FLEET_VAULT_UPDATE_DAEMONS:-/Library/LaunchDaemons}"
export PATH="${FLEET_VAULT_UPDATE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
# Who owns the vault in place, as install.py leaves it: root, with the group of /Applications. ditto keeps the owner
# that the zip names (the build Mac's user, which can be a user of this Mac), so the copy is given to root before
# it is checked and put in place.
owner="${FLEET_VAULT_UPDATE_OWNER-root:admin}"
team=6EBZ756H9Q
identifier=local.agent-fleet.vault
requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"$identifier\""

say() { print -r -- "$(date -u '+%Y-%m-%d %H:%M:%S') $*"; }
json() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }                     # one value of a JSON file
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }           # one value of a property list

channel=$(json channel "$base/update.json" || true)
fleet=$(json fleet "$base/update.json" || true)
track=$(json track "$base/update.json" || true)
[[ "$track" == early ]] || track=approved
if [[ ! "$channel" =~ '^https://[a-z0-9.-]+$' || ! "$fleet" =~ '^[0-9a-f]{16}$' ]]; then
    say "update.json names no channel and fleet; nothing changed"; exit 1
fi
label=com.agentfleet.vault
if [[ "$(json role "$base/config.json" || true)" == owner ]]; then
    role=owner; uid=$(json owner_uid "$base/config.json" || true)
else
    role=worker; uid=$(json worker_uid "$base/config.json" || true)
fi
[[ "$uid" =~ '^[0-9]+$' ]] || { say "config.json names no user that runs the vault; nothing changed"; exit 1; }
[[ ! -L "$app" ]] || { say "$app is a symbolic link; nothing changed"; exit 1; }

# One run at a time: the daemon starts one at load and every hour, and a person can start one too.
lock="$base/.update.lock"
mkdir "$lock" 2>/dev/null || exit 0
work=$(mktemp -d "${TMPDIR:-/private/var/tmp}/fleet-vault-update.XXXXXX")
trap 'rm -rf "$work"; rmdir "$lock" 2>/dev/null || true' EXIT

# Our vault, as install.py's verify() reads one: no build of anyone else's, and none signed for debugging.
signed() {
    codesign --verify --deep --strict -R "=$requirement" "$1" 2>/dev/null || return 1
    codesign -d --entitlements :- "$1" > "$work/entitlements.plist" 2>/dev/null || return 1
    [[ "$(plist keychain-access-groups:0 "$work/entitlements.plist")" == "$team.$identifier" ]] || return 1
    ! plist keychain-access-groups:1 "$work/entitlements.plist" >/dev/null || return 1
    local key
    for key in com.apple.security.get-task-allow get-task-allow com.apple.security.cs.disable-library-validation \
               com.apple.security.cs.allow-dyld-environment-variables; do
        [[ "$(plist "$key" "$work/entitlements.plist" || true)" != true ]] || return 1
    done
    codesign -dvv "$1" 2>&1 | grep -q '(runtime)' || return 1
    [[ -f "$1/Contents/embedded.provisionprofile" && ! -L "$1/Contents/embedded.provisionprofile" ]]
}

# The updater that the vault in place carries, when it is newer than this one: for the next run.
bundled="$app/Contents/Resources/update.zsh"
if [[ -f "$bundled" && ! -L "$bundled" ]]; then
    theirs=$(sed -n 's/^updater=\([0-9][0-9]*\)$/\1/p' "$bundled" | head -1)
    if [[ "$theirs" =~ '^[0-9]+$' ]] && (( theirs > updater )) && signed "$app"; then
        cp "$bundled" "$base/.update.zsh.new"
        chmod 755 "$base/.update.zsh.new"
        mv "$base/.update.zsh.new" "$base/update.zsh"
        say "the updater is now version $theirs, the one that the vault in place carries"
    fi
fi

# $1: the starter that the vault in place carries. Puts it beside this file with its daemon, which runs it as root every
# minute, and starts that daemon. 0 when all of it is in place.
starter_in_place() {
    local daemon="$daemons/com.agentfleet.starter.plist"
    [[ "$base" != *[\&\<\>]* ]] || return 1          # the folder goes into the daemon's XML as it is
    cp "$1" "$base/.starter.zsh.new" && chmod 755 "$base/.starter.zsh.new" \
        && mv "$base/.starter.zsh.new" "$base/starter.zsh" || return 1
    cat > "$base/.starter.plist.new" <<EOF || return 1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.agentfleet.starter</string>
	<key>ProgramArguments</key><array><string>/bin/zsh</string><string>$base/starter.zsh</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>60</integer>
	<key>StandardOutPath</key><string>$base/starter.log</string>
	<key>StandardErrorPath</key><string>$base/starter.log</string>
</dict>
</plist>
EOF
    chmod 644 "$base/.starter.plist.new" && mv "$base/.starter.plist.new" "$daemon" || return 1
    launchctl bootout system/com.agentfleet.starter >/dev/null 2>&1 || true
    launchctl bootstrap system "$daemon"
}

# The starter that the vault in place carries, when it is newer than the one beside this file: starter.zsh says what
# it is for. Only where the vault runs as the agents' user (the owner's own Mac runs no agent), and a starter that
# cannot be put in place stops no update of the vault.
carried="$app/Contents/Resources/starter.zsh"
if [[ "$role" == worker && -f "$carried" && ! -L "$carried" ]]; then
    theirs=$(sed -n 's/^starter=\([0-9][0-9]*\)$/\1/p' "$carried" | head -1)
    ours=$(sed -n 's/^starter=\([0-9][0-9]*\)$/\1/p' "$base/starter.zsh" 2>/dev/null | head -1)
    if [[ "$theirs" =~ '^[0-9]+$' ]] && (( theirs > ${ours:-0} )) && signed "$app"; then
        if starter_in_place "$carried"; then
            say "the starter is now version $theirs, the one that the vault in place carries, and runs every minute"
        else
            rm -f "$base/.starter.zsh.new" "$base/.starter.plist.new"
            say "the starter that the vault in place carries could not be put in place; the next run tries again"
        fi
    fi
fi

# The owner's Mac. Fleet Vault was the writer of the app's Add secret there: the owner's LaunchAgent
# com.agentfleet.vault.writer started it for its Mach service. The app seals each value into the hub's central vault
# now, and the writer mode of a vault that carries updater 5 or a newer one only deletes the old writer's Keychain
# items, prints one line and ends. So this starts it one time and waits for its end. When it ended with status 0, the
# LaunchAgent goes, and the file is removed as the owner, because root never writes into a home that its user controls.
# The next runs find no file and do nothing more for it. A vault in place that is older runs the old writer, so nothing
# starts it; a start that fails (the owner is not logged in) or a status that is not 0 leaves all for the next run.
writer=com.agentfleet.vault.writer
writer_gone() {
    [[ "$role" == owner ]] || return 0
    local agents="${FLEET_VAULT_UPDATE_AGENTS:-}" name home plist job code ours tries=0
    if [[ -z "$agents" ]]; then
        name=$(id -nu "$uid" 2>/dev/null) || return 0
        home=$(dscl . -read "/Users/$name" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
        [[ "$home" == /?* && -d "$home" ]] || return 0
        agents="$home/Library/LaunchAgents"
    fi
    plist="$agents/$writer.plist"
    [[ -f "$plist" || -L "$plist" ]] || return 0
    ours=$(sed -n 's/^updater=\([0-9][0-9]*\)$/\1/p' "$app/Contents/Resources/update.zsh" 2>/dev/null | head -1)
    [[ "$ours" =~ '^[0-9]+$' ]] && (( ours >= 5 )) && signed "$app" || return 0
    launchctl kickstart -k "gui/$uid/$writer" >/dev/null 2>&1 || return 0
    while job=$(launchctl print "gui/$uid/$writer" 2>/dev/null) && [[ "$job" == *"state = running"* ]] && (( ++tries < 30 )); do
        sleep 1
    done
    code=$(print -r -- "$job" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)
    if [[ "$code" != 0 ]]; then
        say "the old writer of Add secret did not end with status 0 (${code:-no status}); its LaunchAgent stays for the next run"
        return 0
    fi
    launchctl bootout "gui/$uid/$writer" >/dev/null 2>&1 || true
    if sudo -u "#$uid" /bin/rm -f -- "$plist"; then
        say "the old writer of Add secret has no Keychain items any more, and its LaunchAgent is gone"
    else
        say "the old writer of Add secret has no Keychain items any more; $plist could not be removed, and the next run tries again"
    fi
}
writer_gone

manifest="$channel/releases/app"
[[ "$track" != early ]] || manifest="${manifest}?track=early"
curl -fsS --proto '=https' --max-time 60 -H "Founderizer-Fleet: $fleet" -o "$work/manifest.json" "$manifest" \
    || { say "the channel gave no manifest of the $track track for fleet $fleet; nothing changed"; exit 1; }
[[ "$(json hold "$work/manifest.json" || true)" != true ]] || exit 0         # the channel holds its newest build back
url=$(json url "$work/manifest.json" || true)
digest=$(json sha256 "$work/manifest.json" || true)
if [[ "$url" != "$channel/"* || "$url" == *..* || ! "$digest" =~ '^[0-9a-f]{64}$' ]]; then
    say "the manifest names no build on $channel; nothing changed"; exit 1
fi
curl -fsS --proto '=https' --max-time 900 -o "$work/build.zip" "$url" \
    || { say "$url did not download; nothing changed"; exit 1; }
[[ "$(shasum -a 256 "$work/build.zip" | cut -d' ' -f1)" == "$digest" ]] \
    || { say "$url is not the file that the manifest names; nothing changed"; exit 1; }
ditto -x -k "$work/build.zip" "$work/build"
candidate="$work/build/Founderizer.app/Contents/Library/Fleet Vault.app"
[[ -d "$candidate" && ! -L "$candidate" ]] || exit 0                         # a build from before vaults rode along
signed "$candidate" || { say "the Fleet Vault in $url is not ours as signed; nothing changed"; exit 1; }
version=$(plist CFBundleShortVersionString "$candidate/Contents/Info.plist" || true)
new=$(plist CFBundleVersion "$candidate/Contents/Info.plist" || true)
old=$(plist CFBundleVersion "$app/Contents/Info.plist" || print 0)
[[ "$new" =~ '^[0-9]+$' && "$old" =~ '^[0-9]+$' ]] \
    || { say "the build numbers $new and $old are not numbers; nothing changed"; exit 1; }
(( new > old )) || exit 0

# Staged beside the installed app, on its own volume, and checked again where it will run: then two renames.
stage=$(mktemp -d "${app:h}/.FleetVault-update.XXXXXX")
ditto "$candidate" "$stage/new.app"
[[ -z "$owner" ]] || chown -R "$owner" "$stage/new.app"
signed "$stage/new.app" || { rm -rf "$stage"; say "the staged Fleet Vault did not verify; nothing changed"; exit 1; }
[[ -e "$app" ]] && mv "$app" "$stage/old.app"
mv "$stage/new.app" "$app"
rm -rf "$stage"
if [[ "$role" == owner ]]; then
    say "Fleet Vault $version (build $new) of the $track track replaced build $old on the owner's Mac"
    writer_gone
elif launchctl kickstart -k "gui/$uid/$label" >/dev/null 2>&1; then
    say "Fleet Vault $version (build $new) of the $track track replaced build $old, and $label started again" \
        "for user $uid"
else
    say "Fleet Vault $version (build $new) of the $track track replaced build $old; $label of user $uid starts it" \
        "at its next login"
fi
