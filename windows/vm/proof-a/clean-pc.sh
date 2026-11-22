#!/bin/bash
# The clean PC of proof A (README.md of the folder above, "Proof A: the rig"): one base VM, made once with vm.sh create
# in a folder of its own, with no Tailscale and no developer tool; for each run an APFS copy of that folder (some
# seconds, little disk) with an SSH port of its own. The build VM ($HOME/VMs/founderizer-windows) is never touched.
#
#   clean-pc.sh base            make the base VM (about 12 minutes), check that it is clean, and stop it
#   clean-pc.sh copy <name>     an APFS copy of the stopped base for one run, started on its own port; the build VM's
#                               test certificate (its public part only) trusted for the setup's signature; the firewall
#                               rules of setup/first-logon.ps1 and the clean state checked; vm.sh hold for FZ_VM_USER
#   clean-pc.sh check <name>    the checks of copy again, with nothing changed
#   clean-pc.sh env <name>      the two lines that point vm.sh at that copy (eval "$(clean-pc.sh env run1)")
#   clean-pc.sh remove <name>   stop the copy and delete its folder
#   clean-pc.sh list            the base and the copies: folder, port, running or not, held by whom
#
# A name has small letters, digits and "-". FZ_VM_USER names the session that holds a copy (vm.sh hold refuses none).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077

downloads="$build_vm_dir/downloads"
windows_iso="${FZ_VM_WINDOWS_ISO:-$downloads/windows/Windows11_Client_arm64_en-us_26300_9457.iso}"
tools_iso="${FZ_VM_TOOLS_ISO:-$downloads/guest-tools/utm-guest-tools-0.1.271.iso}"

next_port() {
    local port=$((base_port + 1)) used
    used="$(cat "$proof_home"/founderizer-windows-proof-a-copy-*/port 2>/dev/null || true)"
    while printf '%s\n' "$used" | grep -qx "$port" || lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
        port=$((port + 1))
    done
    printf '%s' "$port"
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
base)
    [ -f "$base_dir/disk.qcow2" ] && proof_die "the base VM exists at $base_dir already"
    lsof -nP -iTCP:"$base_port" -sTCP:LISTEN >/dev/null 2>&1 && proof_die "port $base_port is in use: set FZ_PROOF_A_PORT"
    export FZ_VM_DIR="$base_dir" FZ_VM_PORT="$base_port" FZ_VM_WINDOWS_ISO="$windows_iso" FZ_VM_TOOLS_ISO="$tools_iso"
    export FZ_VM_CPUS="$clean_cpus" FZ_VM_MEMORY_MB="$clean_memory"
    "$vm_sh" create
    run_ps check-clean.ps1
    "$vm_sh" stop
    proof_say "the base VM is at $base_dir (port $base_port), stopped: clean-pc.sh copy <name> makes a run's copy"
    ;;
copy)
    name="${1:-}"
    copy_name_ok "$name" || proof_die "copy needs a name of small letters, digits and \"-\""
    [ -n "${FZ_VM_USER:-}" ] || proof_die "say who holds the copy: FZ_VM_USER=<your session's name> clean-pc.sh copy $name"
    [ -f "$base_dir/disk.qcow2" ] || proof_die "no base VM at $base_dir: clean-pc.sh base"
    vm_running_at "$base_dir" && proof_die "the base VM runs: stop it first (FZ_VM_DIR=$base_dir FZ_VM_PORT=$base_port vm.sh stop)"
    [ -f "$proof_files/founderizer-test-signing.cer" ] || proof_die "no test certificate in $proof_files: build-setup.sh first"
    dir="$(copy_dir "$name")"
    [ -e "$dir" ] && proof_die "a copy $name exists at $dir already: clean-pc.sh remove $name"
    port="$(next_port)"
    # An APFS clone of each file: the copy shares the base's blocks until it writes its own.
    cp -c -R "$base_dir" "$dir"
    rm -rf "${dir:?}/run" "$dir/in-use"
    mkdir -p "$dir/run"
    printf '%s\n' "$port" > "$dir/port"
    use_copy "$name"
    "$vm_sh" start
    "$vm_sh" run 'New-Item -ItemType Directory -Force -Path C:\fz\proof-a, C:\fz\setup | Out-Null'
    "$vm_sh" copy "$proof_files/founderizer-test-signing.cer" "$proof_here/focus.ps1" "$proof_here/watch.ps1" \
        "$proof_here/team-read.ps1" vm:C:/fz/proof-a/
    # The session's presses, as in the build VM (README.md of the folder above, "Pictures").
    "$vm_sh" copy "$proof_here/../pictures/ui.ps1" "$proof_here/../pictures/pick.ps1" "$proof_here/../pictures/rest.ps1" \
        "$proof_here/../pictures/click.ps1" "$proof_here/../pictures/elements.ps1" "$proof_here/../pictures/window.ps1" \
        vm:C:/fz/setup/
    run_ps trust-certificate.ps1 "expected=$(tr -d ' \r\n' < "$proof_files/founderizer-test-signing.thumbprint")"
    run_ps check-clean.ps1
    "$vm_sh" hold
    proof_say "copy $name: $dir, SSH on 127.0.0.1:$port, held by $FZ_VM_USER. The other tools take FZ_PROOF_A_COPY=$name"
    ;;
check)
    use_copy "${1:-}"
    run_ps check-clean.ps1
    ;;
env)
    use_copy "${1:-}"
    printf 'export FZ_VM_DIR=%q\nexport FZ_VM_PORT=%q\nexport FZ_VM_CPUS=%q\nexport FZ_VM_MEMORY_MB=%q\n' "$FZ_VM_DIR" "$FZ_VM_PORT" "$FZ_VM_CPUS" "$FZ_VM_MEMORY_MB"
    ;;
remove)
    use_copy "${1:-}"
    case "$FZ_VM_DIR" in "$proof_home"/founderizer-windows-proof-a-copy-*) ;; *) proof_die "not a copy's folder: $FZ_VM_DIR" ;; esac
    if vm_running_at "$FZ_VM_DIR"; then "$vm_sh" stop; fi
    vm_running_at "$FZ_VM_DIR" && proof_die "the copy still runs; nothing was deleted"
    rm -rf "${FZ_VM_DIR:?}"
    proof_say "copy $FZ_PROOF_A_COPY deleted"
    ;;
list)
    for dir in "$base_dir" "$proof_home"/founderizer-windows-proof-a-copy-*; do
        [ -d "$dir" ] || continue
        port="$base_port"; [ -f "$dir/port" ] && port="$(cat "$dir/port")"
        state=stopped; vm_running_at "$dir" && state=running
        held=""; [ -f "$dir/in-use" ] && held=", held by $(cut -f1 "$dir/in-use")"
        printf '%s  port %s  %s%s\n' "$dir" "$port" "$state" "$held"
    done
    ;;
*)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
