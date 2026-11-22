# The settings that the tools of proof A share (README.md of the folder above, "Proof A: the rig"). Each tool sources
# this file; nothing here runs by itself.
#
#   FZ_PROOF_A_HOME   the folder of the clean PC's base VM and its copies ($HOME/VMs), outside any repository
#   FZ_PROOF_A_FILES  the files that a run uses: the setup, the test certificate's public part, the logs
#                     ($FZ_PROOF_A_HOME/founderizer-windows-proof-a-files)
#   FZ_PROOF_A_PORT   the base VM's SSH port on 127.0.0.1 (52240); a copy takes the next free port after it
#   FZ_PROOF_A_COPY   the copy that a tool acts on (a name of letters, digits and "-", as `clean-pc.sh copy` made it)
#   FZ_VM_CPUS, FZ_VM_MEMORY_MB   2 and 8192 for the clean PC (vm.sh's own defaults are 6 and 16384): on 22 November
#                     2026, with the Mac's load average near 90, Windows with 6 cores stopped at its boot manager three
#                     times (all cores busy, no disk write), and a clean PC needs no build's cores
#
# The build VM (vm.sh's defaults, $HOME/VMs/founderizer-windows on 52222) is never one of these.

proof_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vm_sh="$proof_here/../vm.sh"
proof_home="${FZ_PROOF_A_HOME:-$HOME/VMs}"
proof_files="${FZ_PROOF_A_FILES:-$proof_home/founderizer-windows-proof-a-files}"
base_dir="$proof_home/founderizer-windows-proof-a"
base_port="${FZ_PROOF_A_PORT:-52240}"
build_vm_dir="$HOME/VMs/founderizer-windows"
clean_cpus="${FZ_VM_CPUS:-2}"
clean_memory="${FZ_VM_MEMORY_MB:-8192}"

proof_say() { printf '%s\n' "$*" >&2; }
proof_die() { proof_say "$(basename "$0"): $*"; exit 1; }

copy_name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]; }
copy_dir() { printf '%s/founderizer-windows-proof-a-copy-%s' "$proof_home" "$1"; }

# Points vm.sh at one copy: FZ_VM_DIR and FZ_VM_PORT, read from the copy's own folder. Never the build VM.
use_copy() {
    local name="${1:-${FZ_PROOF_A_COPY:-}}" dir
    [ -n "$name" ] || proof_die "name the copy: FZ_PROOF_A_COPY=<name> (clean-pc.sh list shows them)"
    copy_name_ok "$name" || proof_die "a copy's name has small letters, digits and \"-\" only: $name"
    dir="$(copy_dir "$name")"
    # A copy is a VM of this Mac (disk.qcow2), or a PC elsewhere that SSH reaches through a forward on this Mac's port
    # (remote: azure-pc-make.sh forward); vm.sh's run, copy, desktop and picture work on both, its QEMU parts on a VM.
    [ -f "$dir/disk.qcow2" ] || [ -f "$dir/remote" ] || proof_die "no copy $name at $dir: clean-pc.sh copy $name"
    [ -f "$dir/port" ] || proof_die "the copy $name has no port file"
    export FZ_VM_DIR="$dir"
    FZ_VM_PORT="$(cat "$dir/port")"
    export FZ_VM_PORT
    export FZ_PROOF_A_COPY="$name"
    export FZ_VM_CPUS="$clean_cpus" FZ_VM_MEMORY_MB="$clean_memory"
}

# Points vm.sh at the build VM, with its own defaults.
use_build_vm() {
    unset FZ_VM_DIR FZ_VM_PORT FZ_VM_CPUS FZ_VM_MEMORY_MB
}

vm_running_at() {
    local dir="$1"
    [ -f "$dir/run/qemu.pid" ] && kill -0 "$(cat "$dir/run/qemu.pid")" 2>/dev/null
}

# A PowerShell command in the copy over SSH, as vm.sh run sends one, but with this function's own standard input on the
# command's input: a value goes to the PC there and in no command line. vm_input <script> < value
vm_input() {
    local encoded
    encoded="$(printf '%s' "$1" | python3 -I -c 'import base64,sys; print(base64.b64encode(sys.stdin.read().encode("utf-16-le")).decode())')"
    ssh -F /dev/null -i "${FZ_VM_KEY:-$HOME/.ssh/founderizer-windows-vm}" -o IdentitiesOnly=yes -o IdentityAgent=none \
        -o BatchMode=yes -o UserKnownHostsFile="$FZ_VM_DIR/known_hosts" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 -o LogLevel=ERROR -p "$FZ_VM_PORT" builder@127.0.0.1 \
        "powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded"
}

# Runs one PowerShell file of this folder in the VM that FZ_VM_DIR names (vm.sh run), with variables set before it:
# run_ps <file> [name=value ...]. A value goes in single quotes, so it may hold no single quote and no line end.
run_ps() {
    local file="$proof_here/$1" text="" pair name value
    shift
    [ -f "$file" ] || proof_die "no file $file"
    for pair in "$@"; do
        name="${pair%%=*}"; value="${pair#*=}"
        [[ "$name" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || proof_die "not a variable name: $name"
        case "$value" in *"'"*|*$'\n'*|*$'\r'*) proof_die "the value of $name has a quote or a line end" ;; esac
        text+="\$$name = '$value'"$'\n'
    done
    text+="$(cat "$file")"
    "$vm_sh" run "$text"
}
