#!/bin/bash
# cloud.sh: the Windows build machines at Azure, one for each builder lane (README.md in this folder): Windows Server 2025
# Datacenter with Desktop Experience, licence included, x64, driven over SSH with this Mac's key from this Mac's public
# address only, with vm.sh's verbs. A machine costs by the hour while it runs: stop deallocates it, and it deallocates
# itself at night (Azure's auto-shutdown, 01:00 Madrid time) and after 2 hours with no SSH connection and no build or
# test (its idle rule, idle.ps1). Its disk and address cost also while it is deallocated.
#
#   cloud.sh <lane> make [--size <size>] [--what-if]
#                                 make the machine of lane 1, 2 or 3 once: the checks of the subscription, the size and
#                                 its quota, the deployment (machine.json), the setup (setup.ps1, by Azure's run command,
#                                 which also brings back the SSH host key), the SDK (install-sdk.ps1) and the screen
#                                 (display.ps1). --what-if reads and checks only: nothing is made
#   cloud.sh <lane> start         start it, let this Mac's address in again if it changed, and wait for SSH and for the
#                                 desktop session of builder
#   cloud.sh <lane> stop          deallocate it: its processor and memory cost nothing until the next start
#   cloud.sh <lane> status        Azure's power state, the size, the address, who holds it
#   cloud.sh list                 each lane's machine and its power state
#   cloud.sh <lane> sync [<worktree>]
#                                 send the sources of a worktree (default: the worktree of the current folder) to
#                                 C:\fz\src (the folder app/ of the worktree: C:\fz\src\windows\...), as its files are
#                                 now, with or without a commit; each file that git does not track is named first; bin
#                                 and obj on the machine stay, for the next build
#   cloud.sh <lane> build [--proofs] [--no-sync]
#                                 sync of the current folder's worktree, then the x64 build: ../setup/build-window.ps1
#                                 -Arch x64 publishes and signs it into C:\fz\out\x64 (C:\fz\out\x64-proofs with --proofs)
#   cloud.sh <lane> test [--filter <expression>] [--no-sync]
#                                 sync of the current folder's worktree, then dotnet test of Founderizer.Windows.Tests
#                                 (a test that hangs for 30 minutes ends the run)
#   cloud.sh <lane> run <command>          as vm.sh run: one PowerShell command over SSH
#   cloud.sh <lane> copy <from> <to>       as vm.sh copy; vm:<path> is the machine's side
#   cloud.sh <lane> desktop <command>      as vm.sh desktop: in builder's desktop session
#   cloud.sh <lane> picture [file.png]     as vm.sh picture
#   cloud.sh <lane> screen [file.png]      the same picture: no display outside Windows is read here (no boot diagnostics)
#   cloud.sh <lane> keys <key...>          press keys in builder's desktop session (keys.ps1): QEMU's names, as vm.sh
#                                          keys takes them, or a chord such as ctrl-a or alt-f4
#   cloud.sh <lane> hold | release         as vm.sh hold and release (FZ_VM_USER names who holds the machine)
#
# Settings:
#   FZ_AZURE_TENANT   the tenant id of the subscription that pays, set in the session's shell and in no file of the
#                     repository; make, start, stop, status and list stop without it (as proof A's Azure tools)
#   FZ_AZURE_SUBSCRIPTION_NAME   the subscription that pays (Pay-As-You-Go): its id is read from `az account list`, and
#                     every call names it, never the CLI's default
#   FZ_AZURE_FROM     this Mac's public IPv4 address (read from api.ipify.org when it is not set)
#   FZ_CLOUD_HOME     the machines' folders on this Mac, outside any repository ($HOME/VMs/founderizer-cloud): lane-<n>
#                     holds the address, known_hosts, record.log, and vm.sh's marks (in-use, value-on-screen)
#   FZ_VM_KEY         the SSH key of this Mac ($HOME/.ssh/founderizer-windows-vm, the key of the Mac's VM)
set -euo pipefail
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
vm_sh="$here/../vm.sh"
home="${FZ_CLOUD_HOME:-$HOME/VMs/founderizer-cloud}"
key_file="${FZ_VM_KEY:-$HOME/.ssh/founderizer-windows-vm}"
# The SDK of the release builds (T1a): ../../release/global.json names it where that file exists, and must agree.
sdk="10.0.404"
default_size="Standard_D8s_v6"

say() { printf '%s\n' "$*" >&2; }
die() { say "cloud.sh: $*"; exit 1; }
usage() { sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }

# The SDK of the machines is the release builds' (release/global.json, where that file exists). Only make, build and
# test check it: stop and status never refuse.
check_sdk_pin() {
    local release_json="$here/../../release/global.json" pinned
    [ -f "$release_json" ] || return 0
    pinned="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["sdk"]["version"])' "$release_json")"
    [ "$pinned" = "$sdk" ] || die "release/global.json names the SDK $pinned and cloud.sh $sdk: change sdk in cloud.sh, then install it on each machine (install-sdk.ps1)"
}

region_of() {
    case "$1" in
        1) echo northeurope ;;
        # On 23 November 2026 westeurope refused every resource of the deployment ("The selected region is currently not
        # accepting new customers", RequestDisallowedByAzure), and spaincentral has no auto-shutdown
        # (Microsoft.DevTestLab/schedules); Azure's what-if passed the second one.
        2) echo francecentral ;;
        3) echo swedencentral ;;
        *) return 1 ;;
    esac
}

# The subscription that pays, by its name, in its own tenant: never the CLI's default.
subscription=""
azure() {
    [ -n "$subscription" ] && return 0
    local name="${FZ_AZURE_SUBSCRIPTION_NAME:-Pay-As-You-Go}" tenant="${FZ_AZURE_TENANT:-}" ids
    [[ "$tenant" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
        die "set FZ_AZURE_TENANT to the tenant id of the subscription that pays (outside the repository; README.md)"
    ids="$(az account list --all --query "[?name=='$name' && state=='Enabled' && tenantId=='$tenant'].id" -o tsv)"
    [ "$(printf '%s\n' "$ids" | grep -c .)" = 1 ] ||
        die "not one enabled subscription named $name in tenant FZ_AZURE_TENANT (found: $(printf '%s' "$ids" | grep -c .))"
    subscription="$ids"
}
az_sub() { az "$@" --subscription "$subscription"; }

mac_address() {
    local from="${FZ_AZURE_FROM:-$(curl -fsS -4 --max-time 10 https://api.ipify.org)}"
    [[ "$from" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "this Mac's public IPv4 address was not read"
    printf '%s' "$from"
}

note() { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$machine_dir/record.log"; }

# The machine's own SSH, with its key from known_hosts only: a key that is not there is refused.
machine_ssh() {
    ssh -n -F /dev/null -i "$key_file" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
        -o UserKnownHostsFile="$machine_dir/known_hosts" -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
        -o LogLevel=ERROR "builder@$address" "$@"
}

# The machine is ready when SSH (with a full token: Get-Process -IncludeUserName needs one) sees the setup's done file
# and the desktop session of builder.
ready() {
    machine_ssh 'powershell -NoProfile -Command "if (Test-Path C:\ProgramData\fz-cloud\done) { (Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Select-Object -First 1).UserName }"' 2>/dev/null |
        grep -qi builder
}
wait_ready() {
    local waited=0
    until ready; do
        [ "$waited" -ge "${1:-900}" ] && return 1
        sleep 10
        waited=$((waited + 10))
    done
}

# vm.sh's SSH verbs on this machine: its folder, its address, port 22, and known_hosts from Azure's run command.
use_machine() {
    [ -f "$machine_dir/address" ] && [ -s "$machine_dir/known_hosts" ] || die "no machine of lane $lane on this Mac: cloud.sh $lane make"
    # An IPv4 address of Azure, never an empty one: vm.sh with no FZ_VM_HOST reaches the Mac's own VM on 127.0.0.1.
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ && "$address" != 127.* ]] ||
        die "no IPv4 address of lane $lane's machine in $machine_dir/address"
    export FZ_VM_DIR="$machine_dir" FZ_VM_HOST="$address" FZ_VM_PORT=22 FZ_VM_KEY="$key_file"
}
answers() { nc -z -G 5 "$address" 22 >/dev/null 2>&1; }
vm() {
    use_machine
    local code=0
    "$vm_sh" "$@" || code=$?
    if [ "$code" -ne 0 ] && ! answers; then
        say "cloud.sh: the machine of lane $lane does not answer on SSH: it is deallocated (its idle rule, the night, or stop), or this Mac's address changed. cloud.sh $lane start"
    fi
    return "$code"
}
# One PowerShell text over vm.sh run.
vm_ps() { vm run "$1"; }

# The size: offered in the region with no restriction, x64, Gen2, Trusted launch; and the quota of its family.
check_size() {
    local sku facts quota
    sku="$(az_sub vm list-skus -l "$region" --size "$size" --resource-type virtualMachines -o json)"
    facts="$(printf '%s' "$sku" | python3 -I -c '
import json, sys
size = sys.argv[1]
skus = [s for s in json.load(sys.stdin) if s.get("name") == size]
if not skus:
    sys.exit(f"{size} is not offered in this region")
s = skus[0]
if s.get("restrictions"):
    sys.exit(f"{size} is restricted for this subscription here: " + json.dumps(s["restrictions"])[:300])
c = {x["name"]: x["value"] for x in s.get("capabilities", [])}
if c.get("CpuArchitectureType") != "x64":
    sys.exit(size + " is " + str(c.get("CpuArchitectureType")) + ", not x64")
if "V2" not in c.get("HyperVGenerations", ""):
    sys.exit(f"{size} takes no Gen2 image")
if c.get("TrustedLaunchDisabled") == "True":
    sys.exit(f"{size} has no Trusted launch")
if c.get("PremiumIO") != "True":
    sys.exit(f"{size} takes no Premium SSD")
print(s.get("family", ""), c.get("vCPUs", "0"), "NVMe" if "SCSI" not in c.get("DiskControllerTypes", "SCSI") else "SCSI")
' "$size")" || die "the size does not fit: see above (another x64 size with Trusted launch: --size)"
    read -r family vcpus controller <<<"$facts"
    quota="$(az_sub vm list-usage -l "$region" -o json | python3 -I -c '
import json, sys
family, need = sys.argv[1], int(sys.argv[2])
rows = {u["name"]["value"].lower(): u for u in json.load(sys.stdin)}
for name in (family.lower(), "cores"):
    u = rows.get(name)
    if u is None:
        sys.exit(f"no quota line {name}")
    free = int(u["limit"]) - int(u["currentValue"])
    if free < need:
        sys.exit(f"the quota {name} has {free} vCPUs free, and {need} are needed")
free = {n: int(rows[n]["limit"]) - int(rows[n]["currentValue"]) for n in (family.lower(), "cores")}
print("%s: %d vCPUs free; the region: %d free" % (family, free[family.lower()], free["cores"]))
' "$family" "$vcpus")" || die "no quota for $size in $region (another size whose family has quota: --size)"
    say "$size in $region: offered, x64, Gen2, Trusted launch, Premium SSD, $vcpus vCPUs, disk controller $controller; $quota"
}

make_machine() {
    local what_if="$1" from deployment arguments said hostkey state screen result vm_id principal
    azure
    for provider in Microsoft.Compute Microsoft.Network; do
        state="$(az_sub provider show -n "$provider" --query registrationState -o tsv)"
        [ "$state" = Registered ] || die "$provider is $state in the subscription, not Registered"
    done
    [[ "$size" =~ ^Standard_[A-Z]+[0-9]+([a-oq-z]*)_v[0-9]+$ ]] || die "not an x64 size of the form Standard_D8s_v6: $size"
    check_size
    if [ "$(az_sub group exists -n "$group")" = true ]; then
        die "the resource group $group exists already: lane $lane has its machine (cloud.sh $lane status)"
    fi
    [ -f "$key_file.pub" ] || die "no SSH key at $key_file.pub"
    from="$(mac_address)"
    deployment="$name-$(date -u +%Y%m%d%H%M%S)"
    arguments=(--location "$region" --template-file "$here/machine.json"
               --parameters group="$group" location="$region" name="$name" lane="$lane" size="$size"
               prefix="10.71.$lane.0/24" from="$from" diskController="$controller")
    # The admin password that Azure needs at the start: random, on standard input only (no argument, no file); the
    # setup replaces it with a password made in the machine.
    parameters() {
        python3 -I -c '
import json, secrets, string
letters = string.ascii_letters + string.digits
print(json.dumps({"adminPassword": {"value": "Fz-" + "".join(secrets.choice(letters) for _ in range(28)) + "-9a"}}))
'
    }
    if [ -n "$what_if" ]; then
        result="$(parameters | az_sub deployment sub what-if --name "$deployment" "${arguments[@]}" --parameters @/dev/stdin \
            --result-format ResourceIdOnly --no-pretty-print -o json)" || die "Azure's what-if refused the deployment (above); nothing was made"
        printf '%s' "$result" | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
if r.get("error"):
    sys.exit("what-if refused it: " + json.dumps(r["error"])[:800])
changes = r.get("changes", [])
for c in changes:
    print("  %-8s %s" % (c["changeType"], c["resourceId"].split("/providers/")[-1]))
print("what-if: %d changes; status %s; nothing was made" % (len(changes), r.get("status")))
'
        return 0
    fi

    mkdir -p "$machine_dir"
    chmod 700 "$home" "$machine_dir"
    rm -f "$machine_dir/address" "$machine_dir/known_hosts"
    note start "deployment $deployment: $name in $region, $size"
    if ! parameters | az_sub deployment sub create --name "$deployment" "${arguments[@]}" --parameters @/dev/stdin -o none; then
        note failed "deployment $deployment"
        say "the deployment failed; what it made is listed in $machine_dir/record.log"
    fi
    if [ "$(az_sub group exists -n "$group")" = true ]; then
        note made "$(az_sub group show -n "$group" --query id -o tsv)"
        az_sub resource list -g "$group" --query '[].id' -o tsv | while IFS= read -r id; do note made "$id"; done
    fi
    state="$(az_sub vm show -g "$group" -n "$name" --query provisioningState -o tsv 2>/dev/null || true)"
    [ "$state" = Succeeded ] || die "the machine is not made ($state); what was made costs until: az group delete -n $group --subscription <the subscription>"
    # Both ways of deallocating by itself, or no machine: Azure's auto-shutdown and the idle rule's role on its VM.
    az_sub resource show -g "$group" --resource-type Microsoft.DevTestLab/schedules -n "shutdown-computevm-$name" -o none 2>/dev/null ||
        die "no auto-shutdown (shutdown-computevm-$name) in $group; the machine costs until: az group delete -n $group --subscription <the subscription>"
    vm_id="$(az_sub vm show -g "$group" -n "$name" --query id -o tsv)"
    principal="$(az_sub vm show -g "$group" -n "$name" --query identity.principalId -o tsv)"
    [ "$(az_sub role assignment list --scope "$vm_id" \
        --query "length([?principalId=='$principal' && roleDefinitionName=='DevTest Labs User'])" -o tsv)" = 1 ] ||
        die "no role of the idle rule on $name; the machine costs until: az group delete -n $group --subscription <the subscription>"
    note checked "the auto-shutdown shutdown-computevm-$name and the idle rule's role (DevTest Labs User of the VM's identity at its scope)"
    address="$(az_sub network public-ip show -g "$group" -n "$name-ip" --query ipAddress -o tsv)"
    say "the machine $name is made at $address; its setup (Azure's run command, some minutes)"

    b64() { base64 < "$1" | tr -d '\n'; }
    said="$(az_sub vm run-command invoke -g "$group" -n "$name" --command-id RunPowerShellScript \
        --scripts @"$here/setup.ps1" \
        --parameters "Key64=$(b64 "$key_file.pub")" "From64=$(printf '%s' "$from" | base64 | tr -d '\n')" "Idle64=$(b64 "$here/idle.ps1")" \
        --query 'value[].message' -o tsv)"
    printf '%s\n' "$said" | grep -v '^hostkey ' >&2
    # The machine's SSH host key, as its own setup read it and Azure's run command brought it back: the first
    # connection checks it (no key is taken on trust from that connection).
    hostkey="$(printf '%s\n' "$said" | sed -n 's/^hostkey \(ssh-ed25519 [A-Za-z0-9+\/=]*\).*/\1/p' | head -1)"
    [ -n "$hostkey" ] || die "the setup gave no SSH host key; the machine costs until it is deallocated or removed"
    printf '%s %s\n' "$address" "$hostkey" > "$machine_dir/known_hosts"
    printf '%s\n' "$address" > "$machine_dir/address"
    note made "the SSH host key of $name: $(printf '%s' "$hostkey" | ssh-keygen -lf - | awk '{print $2}')"
    say "waiting for SSH with a full token and the desktop session of builder after the restart"
    wait_ready 900 || die "no SSH answer with a desktop session of builder in 15 minutes; the machine costs until: cloud.sh $lane stop"
    note ready "$name at $address: SSH by key, builder signed in"

    say "the SDK $sdk for x64"
    vm_ps 'New-Item -ItemType Directory -Force -Path C:\fz\setup | Out-Null'
    vm copy "$here/install-sdk.ps1" vm:C:/fz/setup/install-sdk.ps1
    vm_ps "& C:\\fz\\setup\\install-sdk.ps1 -Version $sdk"
    note setup "the SDK $sdk"
    say "the screen of builder's desktop session"
    screen="$(vm desktop "$(cat "$here/display.ps1")" | tr -d '\r')" || {
        printf '%s\n' "$screen" >&2
        die "the screen was not set (above); the machine is made and runs: cloud.sh $lane desktop \"\$(cat app/windows/vm/cloud/display.ps1)\", then cloud.sh $lane stop"
    }
    printf '%s\n' "$screen" >&2
    note setup "the screen: $(printf '%s\n' "$screen" | sed -n 's/^after: //p' | tail -1)"
    say "ready: lane $lane's machine $name at $address ($size, $region). It costs while it runs: cloud.sh $lane stop"
}

# A changed address of this Mac: the network security group's rule and Windows' firewall rule take the new one (the old
# one goes), through Azure only (SSH does not reach the machine from the new address).
let_mac_in() {
    local from rule
    from="$(mac_address)"
    rule="$(az_sub network nsg rule show -g "$group" --nsg-name "$name-nsg" -n ssh-from-one-address --query sourceAddressPrefix -o tsv)"
    [ "$rule" = "$from/32" ] && return 0
    say "this Mac's address changed (the rule had $rule): the machine takes $from/32 in its place"
    az_sub network nsg rule update -g "$group" --nsg-name "$name-nsg" -n ssh-from-one-address --source-address-prefixes "$from/32" -o none
    az_sub vm run-command invoke -g "$group" -n "$name" --command-id RunPowerShellScript \
        --scripts "Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -RemoteAddress '$from' -Profile Any -Enabled True; 'firewall: $from'" \
        --query 'value[0].message' -o tsv >&2
    note address "SSH from $from/32 (was $rule)"
}

power_state() {
    az_sub vm get-instance-view -g "$group" -n "$name" \
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv 2>/dev/null || echo "not made"
}

# The sources of a worktree as its files are now (tracked and new, not ignored), from app/: the projects of app/windows
# and the files outside it that they read (app/vectors, app/Localization, app/Sources, app/ios/Sources). With no
# argument, the worktree of the current folder: the builder's own, whichever worktree's cloud.sh runs.
sync_sources() {
    local tree="${1:-$PWD}" root commit changed others
    local parts=(app/windows app/vectors app/Localization app/Sources app/ios/Sources)
    root="$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" ||
        die "not in a worktree: $tree (run it from your worktree, or name one: cloud.sh $lane sync <worktree>)"
    [ -d "$root/app/windows" ] || die "no app/windows in $root"
    case "$root" in *"'"*|*$'\n'*|*$'\r'*) die "a worktree's path with a quote or a line end: $root" ;; esac
    commit="$(git -C "$root" rev-parse HEAD)"
    changed="$(git -C "$root" status --porcelain -- "${parts[@]}" | grep -c . || true)"
    # Each file that git does not track goes too: its name first, so that nothing goes unseen.
    others="$(git -C "$root" ls-files --others --exclude-standard -- "${parts[@]}")"
    if [ -n "$others" ]; then
        say "new files that git does not track, sent too:"
        printf '%s\n' "$others" | sed 's/^/  /' >&2
    fi
    tarball="$(mktemp "${TMPDIR:-/tmp}/fz-cloud-src.XXXXXX")"
    # The sources' archive goes when the script ends, also when its send fails.
    trap 'rm -f "${tarball:-}"' EXIT
    git -C "$root" ls-files -z --cached --others --exclude-standard -- "${parts[@]}" |
        python3 -I -c '
import os, sys
root = sys.argv[1]
for path in sys.stdin.buffer.read().split(b"\0"):
    if path.startswith(b"app/") and os.path.isfile(os.path.join(root.encode(), path)):
        sys.stdout.buffer.write(path[4:] + b"\0")
' "$root" | (cd "$root/app" && COPYFILE_DISABLE=1 tar -c -z -f "$tarball" --no-mac-metadata --no-xattrs --null -T -)
    say "sources: $root at ${commit:0:12}, $changed changed files ($(du -k "$tarball" | cut -f1) KB)"
    vm_ps 'New-Item -ItemType Directory -Force -Path C:\fz\incoming | Out-Null'
    vm copy "$tarball" vm:C:/fz/incoming/src.tgz
    rm -f "$tarball"
    vm_ps "\$root = '$root'; \$commit = '$commit'; \$changed = '$changed'
$(cat <<'PS'
$ErrorActionPreference = 'Stop'
$new = 'C:\fz\incoming\src'
if (Test-Path $new) { Remove-Item -Recurse -Force $new }
New-Item -ItemType Directory -Force -Path $new, 'C:\fz\src', 'C:\fz\setup' | Out-Null
& tar.exe -x -z -f C:\fz\incoming\src.tgz -C $new
if ($LASTEXITCODE -ne 0) { throw "tar could not unpack the sources: exit $LASTEXITCODE" }
# The same tree in C:\fz\src, with each removed file gone; bin and obj stay for the next build.
& robocopy.exe $new C:\fz\src /MIR /XD bin obj /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: exit $LASTEXITCODE" }
$global:LASTEXITCODE = 0
Remove-Item -Recurse -Force $new, C:\fz\incoming\src.tgz
Set-Content -Path C:\fz\src\SOURCE.txt -Value "$root at commit $commit, $changed changed files, sent $((Get-Date).ToUniversalTime().ToString('u'))"
# The pictures' scripts where the Mac's VM has them (C:\fz\setup), for the commands of vm/README.md.
Copy-Item -Path C:\fz\src\windows\vm\pictures\*.ps1 -Destination C:\fz\setup -Force
'C:\fz\src: ' + (Get-Content C:\fz\src\SOURCE.txt)
PS
)"
}

command_of_lane() {
    local verb="$1"
    shift
    case "$verb" in
        make)
            local what_if=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --size) size="$2"; shift 2 ;;
                    --what-if) what_if=yes; shift ;;
                    *) die "unknown option $1" ;;
                esac
            done
            make_machine "$what_if" ;;
        start)
            azure
            [ -f "$machine_dir/address" ] || die "no machine of lane $lane on this Mac: cloud.sh $lane make"
            az_sub vm start -g "$group" -n "$name" -o none
            note started "$name"
            let_mac_in
            wait_ready 900 || die "no SSH answer with a desktop session of builder in 15 minutes after the start"
            say "lane $lane's machine runs: $address. It costs while it runs: cloud.sh $lane stop" ;;
        stop)
            azure
            az_sub vm deallocate -g "$group" -n "$name" -o none
            note stopped "$name: deallocated"
            say "lane $lane's machine is deallocated: $(power_state)" ;;
        status)
            azure
            printf 'lane %s: %s in %s, %s, %s, %s\n' "$lane" "$name" "$region" \
                "$(az_sub vm show -g "$group" -n "$name" --query hardwareProfile.vmSize -o tsv 2>/dev/null || echo '-')" \
                "$(power_state)" "$(cat "$machine_dir/address" 2>/dev/null || echo 'no address on this Mac')"
            [ -f "$machine_dir/in-use" ] && printf 'held by %s since %s\n' "$(cut -f1 "$machine_dir/in-use")" "$(cut -f2 "$machine_dir/in-use")"
            return 0 ;;
        sync) sync_sources "$@" ;;
        build|test)
            local sync=yes proofs="" filter="" text
            while [ $# -gt 0 ]; do
                case "$1" in
                    --no-sync) sync=""; shift ;;
                    --proofs) [ "$verb" = build ] || die "--proofs is for build"; proofs=" -Proofs"; shift ;;
                    --filter) [ "$verb" = test ] || die "--filter is for test"; filter="$2"; shift 2 ;;
                    *) die "unknown option $1" ;;
                esac
            done
            [ -n "$sync" ] && sync_sources
            if [ "$verb" = build ]; then
                text="'source: ' + (Get-Content C:\\fz\\src\\SOURCE.txt)
Push-Location C:\\fz\\src\\windows\\Founderizer.Windows; 'dotnet ' + (& \"\$env:ProgramFiles\\dotnet\\dotnet.exe\" --version); Pop-Location
& C:\\fz\\src\\windows\\vm\\setup\\build-window.ps1 -Source C:\\fz\\src\\windows\\Founderizer.Windows -Arch x64$proofs"
            else
                case "$filter" in *$'\n'*|*$'\r'*) die "a filter of one line" ;; esac
                text="\$filter = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(printf '%s' "$filter" | base64 | tr -d '\n')'))
$(cat <<'PS'
'source: ' + (Get-Content C:\fz\src\SOURCE.txt)
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
$arguments = @('test', 'C:\fz\src\windows\Founderizer.Windows.Tests\Founderizer.Windows.Tests.csproj', '-nologo', '--blame-hang-timeout', '30m')
if ($filter) { $arguments += @('--filter', $filter) }
& "$env:ProgramFiles\dotnet\dotnet.exe" @arguments
PS
)"
            fi
            vm_ps "$text" ;;
        run) [ $# -gt 0 ] || die "run needs a command"; vm run "$@" ;;
        copy) [ $# -ge 2 ] || die "copy needs a source and a destination"; vm copy "$@" ;;
        desktop) [ $# -gt 0 ] || die "desktop needs a command"; vm desktop "$@" ;;
        picture|screen) vm picture "${1:-}" ;;
        keys)
            [ $# -gt 0 ] || die "keys needs key names"
            local word
            for word in "$@"; do
                [[ "$word" =~ ^[a-z0-9_]+(-[a-z0-9_]+)*$ ]] || die "not a key name or a chord: $word"
            done
            vm desktop "\$names = '$*'
$(cat "$here/keys.ps1")" ;;
        hold|release) vm "$verb" ;;
        *) usage ;;
    esac
}

lane="${1:-}"
[ $# -gt 0 ] && shift
if [ "$lane" = list ]; then
    azure
    for lane in 1 2 3; do
        name="fz-build-$lane"; group="$name-rg"; region="$(region_of "$lane")"
        printf 'lane %s: %s in %s, %s, %s\n' "$lane" "$name" "$region" \
            "$(az_sub vm show -g "$group" -n "$name" --query hardwareProfile.vmSize -o tsv 2>/dev/null || echo '-')" "$(power_state)"
    done
    exit 0
fi
region="$(region_of "$lane")" || usage
[ $# -gt 0 ] || usage
name="fz-build-$lane"
group="$name-rg"
size="$default_size"
machine_dir="$home/lane-$lane"
address="$(cat "$machine_dir/address" 2>/dev/null || true)"
case "$1" in make|build|test) check_sdk_pin ;; esac
command_of_lane "$@"
