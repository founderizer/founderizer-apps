#!/bin/bash
# secret.sh: the hidden prompt of proof A (from add-test-pc.sh). The owner runs it in a Terminal on this Mac when the
# session says that a field of the clean PC's copy has the focus. It reads one value at a prompt that does not show it,
# and types it into that field through the VM's own keyboard (vm.sh type): the value is in no command line, no file, no
# log and no picture. It logs the field's name, never the value.
#
#   FZ_PROOF_A_COPY=<copy> secret.sh "<prompt>" [--field <automation id>] [--twice] [--no-enter]
#
#   "Tailscale token"            --field first-run-tailscale-key   (the key page)
#   "Hetzner token"              --field first-run-cloud-token     (the provider's page)
#   "New test server password"   --twice                           (bare-server.sh asks for this one itself)
#
# Before it types, the focus must be on an empty text field of Founderizer's window (and, with --field, on that one):
# else it types nothing. The keys that QEMU's keyboard types here are letters, digits, "-", "_" and "#"; a value with any
# other character is refused. After the keys it presses Enter (not with --no-enter), so that the page takes the value and
# clears its field, and it says whether the field is empty or gone. After the keys, on every path, it reads the focus
# (the program and the element's automation id) and the field's length against the count of characters: Enter goes
# only when the focus is still on that field of Founderizer.App and the field holds them all (only a password box may
# give no length). Else some keys can have gone to another window or element: no Enter, the mark stays, and the log
# names where the focus is and, apart from it, how many characters the field itself holds (names and counts, no value);
# the way out is both steps: empty the field, and close the window that took the keys with no save. From the keys
# until the field is empty or gone, the mark "value-on-screen" in the copy's folder stops vm.sh picture and vm.sh
# screen. On a copy with no QEMU keyboard (the x64 PC at Azure,
# azure-pc-make.sh forward), the value goes on SSH's standard input to a named pipe of the desktop session, whose typer
# (type-pipe.ps1) types it with Windows' own key events into that field only, stops when the window in front changes,
# and makes the same checks before Enter; the same characters.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077
use_copy

prompt="${1:-}"
[ -n "$prompt" ] && [ "${prompt#-}" = "$prompt" ] || { sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }
shift
field="" twice="" enter=yes
while [ $# -gt 0 ]; do
    case "$1" in
        --field) field="${2:-}"; shift 2 ;;
        --twice) twice=yes; shift ;;
        --no-enter) enter=""; shift ;;
        *) proof_die "unknown option $1" ;;
    esac
done
logfile="$proof_files/logs/secret.log"
mkdir -p "$proof_files/logs"
note() { printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FZ_PROOF_A_COPY" "$prompt" "$*" >> "$logfile"; }

# What has the focus: one line of fields name=value, tab-separated (focus.ps1). Never the field's words.
focus_line() { "$V" desktop "& C:\\fz\\proof-a\\focus.ps1 $1" 2>/dev/null | tr -d '\r' | grep -E '^(focus|element)' | tail -1; }
part() { printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p" | head -1; }
V="$vm_sh"

line="$(focus_line '')"
program="$(part "$line" program)"; id="$(part "$line" id)"; name="$(part "$line" name)"
type="$(part "$line" type)"; length="$(part "$line" length)"
# focus.ps1 and type-pipe.ps1 give the length "unknown" only for a password box, and "none" for an element with no value.
if [ "$program" != "Founderizer.App" ] || [ "$type" != "ControlType.Edit" ]; then
    note "refused: the focus is not on a field of Founderizer ($program, $type)"
    echo "The focus is not on a field of Founderizer in the test computer now. Nothing was asked or typed. Ask the session."
    exit 1
fi
if [ -n "$field" ] && [ "$id" != "$field" ]; then
    note "refused: the focus is on $id, not on $field"
    echo "The focus is on another field ($name) than the one for this value. Nothing was asked or typed. Ask the session."
    exit 1
fi
if [ "$length" = none ]; then
    note "refused: the field $id gives no length"
    echo "The field \"$name\" does not say how many characters it holds. Nothing was asked or typed. Ask the session."
    exit 1
fi
if [ "$length" != "0" ] && [ "$length" != "unknown" ]; then
    note "refused: the field $id is not empty"
    echo "The field \"$name\" is not empty. Nothing was asked or typed. Ask the session to empty it."
    exit 1
fi

if [ -t 0 ]; then printf '%s (it does not show) and press Return: ' "$prompt"; fi
IFS= read -r -s value || true
[ -t 0 ] && echo
if [ -n "$twice" ]; then
    [ -t 0 ] && printf 'Type it again: '
    IFS= read -r -s again || true
    [ -t 0 ] && echo
    if [ "$value" != "$again" ]; then
        unset value again
        note "refused: the two values were not the same"
        echo "The two were not the same. Nothing was typed; run the line again."
        exit 1
    fi
    unset again
fi
value="$(printf '%s' "$value" | tr -d '\r')"
if [ -z "$value" ] || ! [[ "$value" =~ ^[A-Za-z0-9_#-]+$ ]]; then
    unset value
    note "refused: empty, or a character that the VM's keyboard does not type here"
    echo "That value is empty or has a character other than letters, digits, \"-\", \"_\" and \"#\". Nothing was typed."
    exit 1
fi

# The focus again, just before the keys: the owner may have taken some time.
again_line="$(focus_line '')"
if [ "$(part "$again_line" id)" != "$id" ] || [ "$(part "$again_line" program)" != "Founderizer.App" ]; then
    unset value
    note "refused: the focus moved from $id before the keys"
    echo "The focus moved away from the field. Nothing was typed; ask the session, then run the line again."
    exit 1
fi
# From here until the field is empty or gone, a value can show on the screen (a token's field shows each character):
# vm.sh picture and vm.sh screen refuse while this mark is in the copy's folder.
mark="$FZ_VM_DIR/value-on-screen"
: > "$mark"
pressed="no"
# Whether the keys stayed in the field: read after the keys on every path, by the program, the field's automation id
# and the field's length against the count of characters (a password box gives no length). When they did not, the
# value can show in the window or the element that took them, and the mark stays, whatever the field says after.
kept="no"
count=${#value}
took=""
if [ -f "$FZ_VM_DIR/remote" ]; then
    # A PC with no QEMU keyboard: the typer of the desktop session takes the line from its pipe (type-pipe.ps1). It types
    # only while the focus is on this field of Founderizer's window, stops when the window in front changes, and presses
    # Enter only when the focus is still on this field and the field holds every character.
    run_ps type-task.ps1 do=start "enter=${enter:-no}" "field=$id" >/dev/null || { unset value; rm -f "$mark"; note "failed: no typer in the desktop session"; echo "The test computer's typer did not start. Nothing was typed; ask the session."; exit 1; }
    printf '%s\n' "$value" | vm_input '$line = [Console]::In.ReadLine(); $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "fz-proof-a-keys", [System.IO.Pipes.PipeDirection]::Out); $pipe.Connect(30000); $writer = New-Object System.IO.StreamWriter($pipe); $writer.WriteLine($line); $writer.Flush(); $pipe.Dispose(); $line = $null' >/dev/null
    unset value
    said="$(run_ps type-task.ps1 do=finish enter=no | tr -d '\r' | tail -1)"
    case "$said" in
        "typed $count of $count, Enter") pressed="yes"; kept="yes" ;;
        "typed $count of $count; focus Founderizer.App/$id; length $count"|"typed $count of $count; focus Founderizer.App/$id; length unknown") kept="yes" ;;
        "typed "*) took="the typer typed ${said#typed }" ;;
        "refused: "*) rm -f "$mark"; note "refused by the typer: ${said#refused: }"; echo "Nothing was typed: ${said#refused: }. Ask the session."; exit 1 ;;
        *) note "failed: the typer said: $said"; echo "The test computer did not take the keys ($said). Ask the session before you run the line again; take no picture."; exit 1 ;;
    esac
else
    if ! printf '%s\n' "$value" | "$V" type >/dev/null; then
        unset value
        note "failed: the VM did not take the keys for $id"
        echo "The test computer did not take the keys. Ask the session before you run the line again; take no picture."
        exit 1
    fi
    unset value
    # QEMU types a token in some seconds, and another window or element can take the focus meanwhile, and give it back.
    after_keys="$(focus_line '')"
    length="$(part "$after_keys" length)"
    if [ "$(part "$after_keys" id)" = "$id" ] && [ "$(part "$after_keys" program)" = "Founderizer.App" ] &&
        { [ "$length" = "$count" ] || [ "$length" = unknown ]; }; then
        kept="yes"
        if [ -n "$enter" ]; then "$V" keys ret; pressed="yes"; fi
    else
        took="the focus is on $(part "$after_keys" program)/$(part "$after_keys" id)"
    fi
fi
sleep 2
if [ "$kept" = no ]; then
    # Where the focus is says nothing of the field: the field's own count, read by its automation id. Some keys can be
    # in the field and some in the place that took the focus, so the way out is both steps, never one of them.
    in_field="$(focus_line "-Id $id")"
    if [ "$in_field" = $'element\tgone' ]; then held="the field $id is gone"
    elif [ -z "$in_field" ]; then held="the field $id could not be read"
    else
        case "$(part "$in_field" length)" in
            unknown) held="the field $id is a password box (no length; it shows no character)" ;;
            none|"") held="the field $id gives no length" ;;
            *) held="the field $id holds $(part "$in_field" length) of $count" ;;
        esac
    fi
    # A password box shows no character (and pick.ps1 -Field may not empty one): for it, only the window step.
    empty="emptied the field (pictures/pick.ps1 -Field \"$name\") and "
    [ "$(part "$in_field" password)" = True ] && empty=""
    result="the keys did not all stay in the field ($took; $held): the value can show in the field and where the keys went, so no Enter and no picture until the session has ${empty}closed the window that took the keys with no save (in Founderizer's own window, which stays open until the claim: emptied that element); then it removes the mark $mark"
else
    after="$(focus_line "-Id $id")"
    if [ "$after" = $'element\tgone' ]; then
        result="the field is gone (the page moved on)"
        rm -f "$mark"
    else
        case "$(part "$after" length)" in
            0) result="the field is empty"; rm -f "$mark" ;;
            unknown) result="a password field (its length cannot be read; it shows no character)"; rm -f "$mark" ;;
            "") result="the field could not be read: no picture is taken until it is empty (the mark $mark stays)" ;;
            *) result="the field still holds characters: no picture is taken until it is empty (the mark $mark stays)" ;;
        esac
    fi
fi
note "typed into $id ($name); Enter: $pressed; $result"
echo "Typed into \"$name\". Then: $result."
