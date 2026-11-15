#!/bin/bash
# add-test-pc.sh: the owner adds the Windows test computer (the build VM of this folder) to his fleet himself, with a
# code from his Mac app, as he would on a real PC. It takes no argument. It asks for the code at a prompt that does not
# show it, and types it into Add this PC through the VM's own keyboard (vm.sh type): the code is in no command line, no
# file and no log. The PC then enrolls by itself, as the page does for every owner. Then it shows the one test message
# and sends it to the Fleet Manager only when he types yes.
#
#   app/windows/vm/add-test-pc.sh
#
# Before it: the app runs in the VM on Add this PC (a session of this folder sets that up). Before it types anything, it
# checks that the VM reaches the hub only through its own Tailscale card and that the hub refuses an owner page with no
# key (403): else it stops and types nothing. For a test against a scratch hub only: FZ_TEST_MANAGER names the
# manager's row ("Manager"; "Fleet Manager" when it is not set), and FZ_TEST_SCRATCH=1 leaves out the Tailscale check.
set -uo pipefail
cd "$(dirname "$0")/../../.."
V=app/windows/vm/vm.sh
MANAGER="${FZ_TEST_MANAGER:-Fleet Manager}"
TEXT="This is a test message from the Windows app's proof run. No answer and no work are needed."

ui() { "$V" desktop "& C:\\fz\\setup\\ui.ps1 $1" 2>&1 | tr -d '\r'; }
page() { ui '' | grep -o 'page: .*Back:' | sed -E 's/^page: +//; s/ +Back:$//'; }
problem() { ui '-Read CodeProblem' | sed -n 's/^read CodeProblem: //p' | head -1; }

if [ "$(page)" != "Add this PC" ]; then
    echo "The test computer does not show Add this PC now. Nothing was sent. Ask the session that set it up."
    exit 1
fi
# The way to the hub: the device of the network that answers /health, reached through Tailscale's card, and an owner
# page with no key refused. Only yes or no comes back; no address leaves the VM.
if [ "${FZ_TEST_SCRATCH:-}" != "1" ]; then
    way=$("$V" run '
$ts = "C:\Program Files\Tailscale\tailscale.exe"
$hub = $null
foreach ($p in (& $ts status --json | ConvertFrom-Json).Peer.PSObject.Properties.Value) {
    $ip = $p.TailscaleIPs | Where-Object { $_ -match "^\d+\.\d+\.\d+\.\d+$" } | Select-Object -First 1
    if ((curl.exe -s -o NUL -w "%{http_code}" --max-time 4 "http://${ip}:8765/health") -eq "200") { $hub = $ip; break }
}
if (-not $hub) { "no hub"; return }
$card = (Find-NetRoute -RemoteIPAddress $hub | Where-Object { $_.InterfaceAlias } | Select-Object -First 1).InterfaceAlias
$owner = curl.exe -s -o NUL -w "%{http_code}" --max-time 8 "http://${hub}:8765/ui/state"
if ($card -eq "Tailscale" -and $owner -eq "403") { "safe" } else { "not safe" }' 2>&1 | tr -d '\r' | tail -1)
    if [ "$way" != "safe" ]; then
        echo "The test computer does not reach your hub only through its own private network now. Nothing was typed or sent."
        exit 1
    fi
fi
echo "Make a code in the Mac app: Settings, Servers, Add device, New code."
printf 'Type the code here (it does not show) and press Return: '
IFS= read -r -s code
echo
code=$(printf '%s' "$code" | tr -d ' \t' | tr '[:lower:]' '[:upper:]')
if ! [[ "$code" =~ ^[A-Z0-9]{4}-?[A-Z0-9]{4}$ ]]; then
    unset code
    echo "That is not a code of the form XXXX-XXXX. Nothing was sent; run this line again."
    exit 1
fi
"$V" desktop '& C:\fz\setup\pick.ps1 -Field "XXXX-XXXX"' >/dev/null 2>&1
printf '%s\n' "$code" | "$V" type >/dev/null || { unset code; echo "The test computer did not take the keys. Nothing was sent."; exit 1; }
unset code

# The page enrolls by itself with a whole code: it leaves Add this PC, or it says why the hub did not take it.
result=""
for _ in $(seq 1 25); do
    sleep 2
    words=$(problem)
    if [ -n "$words" ] && [ "$words" != "(none)" ]; then result="refused"; break; fi
    if [ "$(page)" != "Add this PC" ]; then result="added"; break; fi
done
case "$result" in
refused)
    echo "The hub did not take the code. The app says: $words"
    echo "Make a new code in the Mac app (Settings, Servers, Add device, New code) and run this line again."
    exit 1 ;;
added)
    echo "Done: the test computer is now a device of your fleet. Your Mac app shows it as \"PC\" in Settings, Servers,"
    echo "where you can remove it at any time." ;;
*)
    echo "The test computer shows no result after 50 seconds. Nothing more was sent; ask the session that set it up."
    exit 1 ;;
esac

echo
echo "One test message to the $MANAGER, with these words:"
echo "  $TEXT"
printf 'Send it? Type yes or no and press Return: '
IFS= read -r answer
if [ "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" != "yes" ]; then
    echo "Nothing was sent. The PC stays added."
    exit 0
fi
ui "-Click \"$MANAGER\"" >/dev/null
sleep 3
ui "-Field \"Message $MANAGER\" -Type \"$TEXT\"" >/dev/null
sent=""
for _ in $(seq 1 15); do
    sleep 2
    pending=$(ui '-Read PendingState' | sed -n 's/^read PendingState: //p' | head -1)
    shown=$(ui "-Has \"$TEXT\"" | grep -c ': True')
    if [ "$pending" == "(none)" ] && [ "$shown" -gt 0 ]; then sent="yes"; break; fi
done
if [ -n "$sent" ]; then
    echo "Sent: the hub took the message, and the $MANAGER's chat on the test computer shows it."
else
    echo "The message did not show as sent within 30 seconds. Ask the session that set it up; do not send it again."
    exit 1
fi
