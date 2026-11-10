#!/bin/sh
# The one root step of a new Mac (PRODUCT.md P3). The Founderizer installer runs this script once, behind macOS's own
# password dialog, so that a bare Mac needs no Terminal: Apple's developer tools, Homebrew, Tailscale, Chrome and the
# ChatGPT app, this Mac's settings, and then the hub's own join line, which installs the rest. The owner's password
# never reaches this script.
#
#   $1  the folder the installer made for this run. It belongs to the Mac user that runs the agents, and it holds
#       `line` (the join line, one line) and, when this Mac is not on the private network yet, `authkey`. Both leave
#       the disk as soon as they are read.
#   $2  this run's name. The script writes into a folder that only root can write, and the installer reads: `word`, the
#       one word it shows while it waits, `log`, which holds no secret, and at the end `exit`, this name and the status.
#
# Every step checks first, so the script is safe to run again after a failure or a power cut.
set -eu
trap '' HUP     # the dialog's own process ends at once, and this step goes on without it

work=${1:?}
run=${2:?}
state=/var/run/founderizer-setup
if [ -f "$state/pid" ] && kill -0 "$(cat "$state/pid")" 2>/dev/null; then
    exit 0              # one run at a time: the installer reads that one
fi
rm -rf "$state"
mkdir -m 755 "$state"
printf '%s\n' "$$" > "$state/pid"
trap 'status=$?; rm -f "$work/line" "$work/authkey"; printf "%s %s\n" "$run" "$status" > "$state/exit"; rm -f "$state/pid"' EXIT
user=$(stat -f %Su "$work")
home=$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')
prefix=/opt/homebrew
[ "$(uname -m)" = arm64 ] || prefix=/usr/local
# Root's own commands come from the system: the Mac user can change what stands in Homebrew's folders.
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$prefix/bin:$prefix/sbin
USER_PATH=$prefix/bin:$prefix/sbin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
log=$state/log
RESTART_MARK=/Users/Shared/.founderizer-restart
RESTART_DAEMON=/Library/LaunchDaemons/com.founderizer.restart-once.plist
HOMEBREW_TEAM=927JGANW46        # who signs Homebrew's own package
CHROME_TEAM=EQHXZ8M8AV          # who signs Google Chrome
CHATGPT_TEAM=2DC432GLL2         # who signs the ChatGPT app

word() { printf '%s\n' "$1" > "$state/word"; }
say() { printf '%s\n' "$*" >> "$log"; }
stop() { printf 'Founderizer setup stopped: %s\n' "$*" >> "$log"; exit 1; }
as_user() { sudo -u "$user" -H env PATH="$USER_PATH" HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 \
    HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 "$@" </dev/null; }

signed_by() {   # $1: an app; $2: the team that must have signed it
    codesign --verify "$1" 2>>"$log" && codesign -dv "$1" 2>&1 | grep -q "^TeamIdentifier=$2\$"
}

developer_tools() {     # A bare Mac's git and python3 are stubs that open a dialog, so these come first.
    xcode-select -p >/dev/null 2>&1 && return 0
    word "Developer tools"
    mark=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    touch "$mark"
    label=$(softwareupdate -l 2>>"$log" | sed -n 's/^\* Label: \(Command Line Tools for Xcode.*\)$/\1/p' | sort -V | tail -n 1)
    [ -n "$label" ] || { rm -f "$mark"; stop "Apple's update service offered no developer tools."; }
    softwareupdate -i "$label" >>"$log" 2>&1 || { rm -f "$mark"; stop "Apple's developer tools did not install."; }
    rm -f "$mark"
    xcode-select -s /Library/Developer/CommandLineTools
}

homebrew() {
    [ -x "$prefix/bin/brew" ] && return 0
    word "Homebrew"
    curl -fsSL --proto '=https' --max-time 1800 -o "$state/Homebrew.pkg" \
        https://github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg ||
        stop "Homebrew could not be downloaded."
    pkgutil --check-signature "$state/Homebrew.pkg" | grep -q "($HOMEBREW_TEAM)" || stop "Homebrew's package has no valid signature."
    installer -pkg "$state/Homebrew.pkg" -target / >>"$log" 2>&1 || stop "Homebrew did not install."
    rm -f "$state/Homebrew.pkg"
}

tools() {
    need=""
    for f in tmux git python tailscale; do
        as_user brew list --formula "$f" >/dev/null 2>&1 || need="$need $f"
    done
    [ -n "$need" ] || return 0
    word "Tools"
    # shellcheck disable=SC2086
    as_user brew install $need >>"$log" 2>&1 || stop "Homebrew could not install$need."
}

app() {         # $1: the word; $2: the cask; $3: the app in /Applications; $4: the team that signs it. An app that is
                # there stays as it is. A new one comes straight from what Homebrew fetched, so it carries no mark of a
                # download and macOS asks nothing at its first start: macOS keeps other apps from changing it later.
    if [ -d "/Applications/$3" ]; then
        signed_by "/Applications/$3" "$4" && return 0
        rm -rf "/Applications/$3" || true       # a copy that a power cut left half done
    fi
    word "$1"
    as_user brew fetch --cask "$2" >>"$log" 2>&1 || stop "$1 could not be downloaded."
    image=$(as_user brew --cache --cask "$2")
    xattr -c "$image"
    case "$image" in
        *.zip) as_user ditto -x -k "$image" /Applications || stop "$1 could not be installed." ;;
        *)  mount=$(mktemp -d /tmp/founderizer-image.XXXXXX)
            hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$image" || stop "$1 could not be opened."
            as_user ditto "$mount/$3" "/Applications/$3" ||
                { hdiutil detach -quiet "$mount"; stop "$1 could not be installed."; }
            hdiutil detach -quiet "$mount" || true ;;
    esac
    signed_by "/Applications/$3" "$4" || { rm -rf "/Applications/$3"; stop "$1 has no valid signature."; }
}

chrome_first_start() { # Chrome shows its prompt for Claude's extension only to a profile that has started before the
                       # extension's file arrived, and the join writes that file. The empty file spares its welcome.
    chrome="$home/Library/Application Support/Google/Chrome"
    [ -s "$chrome/Default/Preferences" ] && return 0
    word "Chrome"
    as_user mkdir -p "$chrome"
    as_user touch "$chrome/First Run"
    # By its path: macOS's list of app names can take minutes to learn an app that has just arrived.
    launchctl asuser "$(id -u "$user")" sudo -u "$user" /usr/bin/open -g -j "/Applications/Google Chrome.app" ||
        stop "Chrome did not start."
    i=0
    until [ -s "$chrome/Default/Preferences" ] || [ "$i" -ge 60 ]; do
        sleep 1
        i=$((i + 1))
    done
    pkill -TERM -x "Google Chrome" || true
    i=0
    while pgrep -x "Google Chrome" >/dev/null && [ "$i" -lt 20 ]; do
        sleep 1
        i=$((i + 1))
    done
    [ -s "$chrome/Default/Preferences" ] || stop "Chrome did not start."
}

network() {     # The hub's join line needs the private network, so Tailscale comes before it. tailscaled needs no
                # system extension, so nobody has to approve one at this Mac's screen.
    app_cli=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    if as_user sh -c 'command -v tailscale >/dev/null && tailscale status' >/dev/null 2>&1 ||
            { [ -x "$app_cli" ] && as_user "$app_cli" status >/dev/null 2>&1; }; then
        rm -f "$work/authkey"           # read as the Mac user: the app's own Tailscale answers only its user
        return 0
    fi
    word "Tailscale"
    [ -s "$work/authkey" ] || stop "This Mac is not on your private network."
    if [ ! -e /Library/LaunchDaemons/com.tailscale.tailscaled.plist ]; then
        tailscaled install-system-daemon >>"$log" 2>&1 || stop "Tailscale's service did not start."
    fi
    i=0
    until tailscale version >/dev/null 2>&1 && [ -S /var/run/tailscaled.socket ] || [ "$i" -ge 30 ]; do
        sleep 1
        i=$((i + 1))
    done
    tailscale up --auth-key="file:$work/authkey" --accept-dns=false --timeout=180s >>"$log" 2>&1 ||
        { rm -f "$work/authkey"; stop "Tailscale did not join with that auth key."; }
    rm -f "$work/authkey"
}

settings() {    # What keeps this Mac reachable and awake. Remote Login and Screen Sharing are the repair route.
    word "This Mac's settings"
    /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on >>"$log" 2>&1 || stop "The firewall did not turn on."
    launchctl enable system/com.openssh.sshd
    launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true      # it can run already
    launchctl print system/com.openssh.sshd >/dev/null 2>&1 || stop "Remote Login did not turn on."
    launchctl enable system/com.apple.screensharing
    launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
    launchctl print system/com.apple.screensharing >/dev/null 2>&1 || stop "Screen Sharing did not turn on."
    pmset -a sleep 0 disksleep 0 displaysleep 0 womp 1 >>"$log" 2>&1 || stop "This Mac's power settings did not change."
    pmset -a autorestart 1 >>"$log" 2>&1 || true        # a Mac without this setting has no such line
}

restart_daemon() { # The last press of the installer restarts this Mac, once. A LaunchDaemon does it, so it takes no
                   # second password: the file below starts it, and it removes itself before it restarts.
    cat > "$RESTART_DAEMON" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.founderizer.restart-once</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
<string>[ -e $RESTART_MARK ] || exit 0; rm -f $RESTART_MARK $RESTART_DAEMON; /sbin/shutdown -r now</string></array>
<key>WatchPaths</key><array><string>$RESTART_MARK</string></array>
</dict></plist>
EOF
    chmod 644 "$RESTART_DAEMON"
    launchctl bootout system/com.founderizer.restart-once 2>/dev/null || true
    launchctl bootstrap system "$RESTART_DAEMON"
}

join() {        # The hub's own line. It runs the Mac user's steps as that user, and its vault step as root.
    if [ ! -s "$work/line" ]; then      # a run after a power cut, on a Mac that has joined: the rest of this script
        [ -s "$home/.fleet/server.json" ] || stop "This Mac did not join your fleet."
        return 0
    fi
    word "Your fleet"
    IFS= read -r line < "$work/line"
    rm -f "$work/line"
    printf '%s\n' "$line" | grep -Eq '^curl -fsS http://[0-9A-Za-z.:-]+/join \| FLEET_JOIN=[A-Z0-9-]+ sh$' ||
        stop "This is not your hub's own join line."    # it runs as root
    tries=0
    # The line's status is its shell's, so a curl that failed reads as a pass: its server.json from this run says it.
    until FLEET_MAC_USER=$user HOME=$home sh -c "$line" >>"$log" 2>&1 && [ "$home/.fleet/server.json" -nt "$log.start" ]; do
        say "the join ended with a failure"
        tries=$((tries + 1))
        if [ "$tries" -ge 3 ]; then
            [ ! "$home/.fleet/server.json" -nt "$log.start" ] || stop "This Mac joined your fleet, but its vault did not install."
            stop "This Mac did not join your fleet."
        fi
        sleep 10
    done
}

: > "$log"
: > "$log.start"
exec >>"$log" 2>&1
developer_tools
homebrew
tools
app "Chrome" google-chrome "Google Chrome.app" "$CHROME_TEAM"
chrome_first_start      # beside its install: each part's word comes once, in the order of the installer's bar
app "ChatGPT" chatgpt "ChatGPT.app" "$CHATGPT_TEAM"
network
fdesetup status | grep -q "FileVault is On" || restart_daemon   # a Mac with FileVault on does not restart by itself
join
settings        # after the join: the firewall's start stops this Mac's network for some seconds
word ""
