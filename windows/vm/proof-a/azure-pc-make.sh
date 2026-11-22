#!/bin/bash
# azure-pc-make.sh: the x64 clean PC of proof A's run 2 at Azure (azure-pc.json): Windows Server 2025 Datacenter with
# Desktop Experience, licence included, x64, Trusted launch with Secure Boot and a vTPM, a Standard SSD, in North
# Europe. The only way in is SSH with this Mac's key from this Mac's public address; no RDP rule exists. It costs money
# by the hour until azure-pc-delete.sh: the owner's yes comes first, and only at the run.
#
#   azure-pc-make.sh what-if [options]   reads and checks only: the subscription, the providers, the size in the region
#                                        and its quota, and Azure's what-if of the deployment. Nothing is made.
#   azure-pc-make.sh create [options]    the same checks, then the deployment, the VM's setup (azure-pc-setup.ps1 with
#                                        Azure's run command), a wait for SSH after its restart, and forward
#   azure-pc-make.sh forward             SSH's forward from 127.0.0.1:52260 on this Mac to the PC's SSH, and the copy
#                                        "azure" for the other tools (FZ_PROOF_A_COPY=azure): vm.sh run, copy, desktop
#                                        and picture reach the PC through it, and secret.sh types through its pipe
#   azure-pc-make.sh elevated <since>    the starts with a full administrator's token of the user builder since that
#                                        time (UTC), from Windows' audit of process creation: the run's record. On this
#                                        PC an administrator's rise has no question (run 1 on the ARM VM proves it)
#   azure-pc-make.sh probe               the first step of the run on this PC: one elevated start on purpose (whoami.exe
#                                        as an administrator, from the desktop session); the list must hold it
#
# Options: --size Standard_D2s_v6 (an x64 size with Trusted launch; never an Arm "p" size), --location northeurope,
# --group proof-a-pc-rg, --name proof-a-pc. FZ_AZURE_SUBSCRIPTION_NAME names the subscription that pays
# (Pay-As-You-Go): its id is read from `az account list`, and every call names it, never the CLI's default.
# FZ_AZURE_FROM is this Mac's public IPv4 address (read from api.ipify.org when it is not set).
#
# Each resource that create makes is a line of FZ_PROOF_A_FILES/azure/record.log (the time, "made", its id). The admin
# password that Azure needs at the start is random, goes on the deployment's standard input (no argument, no file), and
# the setup replaces it with a password made in the VM. The address goes to FZ_PROOF_A_FILES/azure/address.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077

size="Standard_D2s_v6"
location="northeurope"
group="proof-a-pc-rg"
name="proof-a-pc"
command="${1:-}"
[ $# -gt 0 ] && shift
since=""
if [ "$command" = elevated ] && [ $# -gt 0 ]; then since="$1"; shift; fi
while [ $# -gt 0 ]; do
    case "$1" in
        --size) size="$2"; shift 2 ;;
        --location) location="$2"; shift 2 ;;
        --group) group="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        *) proof_die "unknown option $1" ;;
    esac
done
case "$command" in what-if|create|forward|elevated|probe) ;; *) sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;; esac
key_file="${FZ_VM_KEY:-$HOME/.ssh/founderizer-windows-vm}"

# The forward and the copy "azure": a PC that vm.sh's SSH parts and the other tools reach as they reach a VM's copy.
forward() {
    local address dir port
    address="$(cat "$proof_files/azure/address" 2>/dev/null)" || proof_die "no address: azure-pc-make.sh create first"
    dir="$(copy_dir azure)"
    mkdir -p "$dir"
    port="$(cat "$dir/port" 2>/dev/null || echo $((base_port + 20)))"
    printf '%s\n' "$port" > "$dir/port"
    printf '%s\n' "$address" > "$dir/remote"
    pkill -f "ssh .*-L 127.0.0.1:$port:127.0.0.1:22 " 2>/dev/null || true
    ssh -f -N -F /dev/null -i "$key_file" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
        -o UserKnownHostsFile="$proof_files/azure/known_hosts" -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 -o LogLevel=ERROR -L "127.0.0.1:$port:127.0.0.1:22" "builder@$address" ||
        proof_die "no SSH forward to $address"
    # vm.sh's SSH goes to 127.0.0.1:<port>: the same host key under that name.
    sed -n "s|^[^ ]* |[127.0.0.1]:$port |p" "$proof_files/azure/known_hosts" > "$dir/known_hosts"
    use_copy azure
    "$vm_sh" run 'New-Item -ItemType Directory -Force -Path C:\fz\proof-a, C:\fz\setup | Out-Null'
    "$vm_sh" copy "$proof_here/focus.ps1" "$proof_here/watch.ps1" "$proof_here/team-read.ps1" "$proof_here/type-pipe.ps1" vm:C:/fz/proof-a/
    "$vm_sh" copy "$proof_here/../pictures/ui.ps1" "$proof_here/../pictures/pick.ps1" "$proof_here/../pictures/rest.ps1" \
        "$proof_here/../pictures/click.ps1" "$proof_here/../pictures/elements.ps1" "$proof_here/../pictures/window.ps1" vm:C:/fz/setup/
    proof_say "copy azure: $address through 127.0.0.1:$port; the tools take FZ_PROOF_A_COPY=azure"
}
if [ "$command" = forward ]; then forward; exit 0; fi
if [ "$command" = probe ]; then
    # The list's own proof: a start that Windows elevates must be in it (its user is in the event's TargetUserName).
    use_copy azure
    since="$(date -u -v-1M +%Y-%m-%dT%H:%MZ)"
    "$vm_sh" desktop 'Start-Process -FilePath "$env:WINDIR\System32\whoami.exe" -Verb RunAs -WindowStyle Hidden -Wait; "one elevated start of whoami.exe"'
    sleep 3
    list="$(run_ps azure-pc-elevated.ps1 "since=$since")" || proof_die "the list of elevated starts did not run"
    printf '%s\n' "$list"
    printf '%s\n' "$list" | grep -qi 'whoami.exe' ||
        proof_die "the list does not hold the elevated start on purpose: on this PC the record of elevated starts proves nothing"
    # elevated reads only on a PC whose probe passed; the time says from when the list holds the probe's own start.
    date -u +%Y-%m-%dT%H:%M:%SZ > "$FZ_VM_DIR/elevated-probe"
    proof_say "the list holds the elevated start on purpose: the run's record of elevated starts can be read"
    exit 0
fi
if [ "$command" = elevated ]; then
    [[ "${since:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z$ ]] || proof_die "elevated needs a time such as 2026-11-22T10:00Z"
    use_copy azure
    [ -f "$FZ_VM_DIR/elevated-probe" ] ||
        proof_die "no probe passed on this PC: azure-pc-make.sh probe first (else an empty list can be a list that sees nothing)"
    probe_at="$(cat "$FZ_VM_DIR/elevated-probe")"
    since_s="$since"; [[ "$since_s" =~ T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || since_s="${since_s%Z}:00Z"
    [[ "$since_s" < "$probe_at" ]] &&
        proof_say "note: the probe's own elevated start of whoami.exe ($probe_at) is in this list, because it starts before it"
    mkdir -p "$proof_files/logs"
    out="$proof_files/logs/azure-elevated-$(date -u +%Y%m%dT%H%M%SZ).txt"
    run_ps azure-pc-elevated.ps1 "since=$since" | tee "$out"
    proof_say "the record: $out"
    exit 0
fi
[[ "$group" =~ ^[a-z0-9-]{1,40}$ && "$name" =~ ^[a-z0-9-]{1,15}$ && "$location" =~ ^[a-z0-9]+$ ]] ||
    proof_die "the group, the name (at most 15 letters) and the place have small letters, digits and \"-\""
# An Arm size has "p" in its family (Dpsv6, Dplsv6, Dpdsv6, Epsv6 ...): this PC is for x64.
[[ "$size" =~ ^Standard_[A-Z]+[0-9]+([a-oq-z]*)_v[0-9]+$ ]] || proof_die "not an x64 size of the form Standard_D2s_v6: $size"

record="$proof_files/azure/record.log"
mkdir -p "$proof_files/azure"
note() { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$record"; }

# The subscription that pays, by its name, in its own tenant: never the CLI's default.
subscription_name="${FZ_AZURE_SUBSCRIPTION_NAME:-Pay-As-You-Go}"
# The tenant too: the CLI's profile holds several tenants, and a subscription of that name can be in more than one.
tenant="${FZ_AZURE_TENANT:-}"
[[ "$tenant" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    proof_die "set FZ_AZURE_TENANT to the tenant id of the subscription that pays (outside the repository; README.md, Proof A)"
ids="$(az account list --all --query "[?name=='$subscription_name' && state=='Enabled' && tenantId=='$tenant'].id" -o tsv)"
[ "$(printf '%s\n' "$ids" | grep -c .)" = 1 ] || proof_die "not one enabled subscription named $subscription_name in tenant FZ_AZURE_TENANT (found: $(printf '%s' "$ids" | grep -c .))"
subscription="$ids"
az_sub() { az "$@" --subscription "$subscription"; }

for provider in Microsoft.Compute Microsoft.Network; do
    state="$(az_sub provider show -n "$provider" --query registrationState -o tsv)"
    [ "$state" = Registered ] || proof_die "$provider is $state in $subscription_name, not Registered"
done
proof_say "subscription $subscription_name: Microsoft.Compute and Microsoft.Network are Registered"

# The size: offered in the region with no restriction, x64, Gen2, Trusted launch; and the quota of its family.
sku="$(az_sub vm list-skus -l "$location" --size "$size" --resource-type virtualMachines -o json)"
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
print(s.get("family", ""), c.get("vCPUs", "0"), "NVMe" if "SCSI" not in c.get("DiskControllerTypes", "SCSI") else "SCSI")
' "$size")" || proof_die "the size does not fit: see above"
read -r family vcpus controller <<<"$facts"
quota="$(az_sub vm list-usage -l "$location" -o json | python3 -I -c '
import json, sys
family, need = sys.argv[1], int(sys.argv[2])
rows = {u["name"]["value"]: u for u in json.load(sys.stdin)}
for name in (family, "cores"):
    u = rows.get(name)
    if u is None:
        sys.exit(f"no quota line {name}")
    free = int(u["limit"]) - int(u["currentValue"])
    if free < need:
        sys.exit(f"the quota {name} has {free} vCPUs free, and {need} are needed")
free = {n: int(rows[n]["limit"]) - int(rows[n]["currentValue"]) for n in (family, "cores")}
print("%s: %d vCPUs free; regional: %d free" % (family, free[family], free["cores"]))
' "$family" "$vcpus")" || proof_die "no quota for $size in $location"
proof_say "$size in $location: offered, x64, Gen2, Trusted launch, $vcpus vCPUs, disk controller $controller; $quota"

if [ "$(az_sub group exists -n "$group")" = true ]; then
    proof_die "the resource group $group exists already: azure-pc-delete.sh first, or another --group"
fi
from="${FZ_AZURE_FROM:-$(curl -fsS -4 --max-time 10 https://api.ipify.org)}"
[[ "$from" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || proof_die "this Mac's public IPv4 address was not read"
[ -f "$key_file.pub" ] || proof_die "no SSH key at $key_file.pub"

# The parameters, with a random admin password on standard input only.
parameters() {
    python3 -I -c '
import json, secrets, string, sys
letters = string.ascii_letters + string.digits
word = "".join(secrets.choice(letters) for _ in range(28))
print(json.dumps({"adminPassword": {"value": "Fz-" + word + "-9a"}}))
'
}
deployment="proof-a-pc-$(date -u +%Y%m%d%H%M%S)"
arguments=(--location "$location" --template-file "$proof_here/azure-pc.json"
           --parameters group="$group" location="$location" name="$name" size="$size" from="$from" diskController="$controller")

if [ "$command" = what-if ]; then
    parameters | az_sub deployment sub what-if --name "$deployment" "${arguments[@]}" --parameters @/dev/stdin \
        --result-format ResourceIdOnly --no-pretty-print -o json | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
if r.get("error"):
    sys.exit("what-if refused it: " + json.dumps(r["error"])[:600])
changes = r.get("changes", [])
for c in changes:
    print("  %-8s %s" % (c["changeType"], c["resourceId"].split("/providers/")[-1]))
print("what-if: %d changes; status %s; nothing was made" % (len(changes), r.get("status")))
'
    exit 0
fi

# The groups of the subscription before: azure-pc-delete.sh compares at its end (Azure can make NetworkWatcherRG with the
# first virtual network of a region).
az_sub group list --query '[].name' -o tsv | sort > "$proof_files/azure/groups-before.txt"
note start "deployment $deployment in $subscription_name, $location, $size"
if ! parameters | az_sub deployment sub create --name "$deployment" "${arguments[@]}" --parameters @/dev/stdin -o none; then
    note failed "deployment $deployment"
    proof_say "the deployment failed; what it made is listed next, for azure-pc-delete.sh"
fi
if [ "$(az_sub group exists -n "$group")" = true ]; then
    note made "$(az_sub group show -n "$group" --query id -o tsv)"
    az_sub resource list -g "$group" --query '[].id' -o tsv | while IFS= read -r id; do note made "$id"; done
fi
state="$(az_sub vm show -g "$group" -n "$name" --query provisioningState -o tsv 2>/dev/null || true)"
[ "$state" = Succeeded ] || proof_die "the VM is not made ($state). Remove what was made: azure-pc-delete.sh --group $group"
address="$(az_sub network public-ip show -g "$group" -n "$name-ip" --query ipAddress -o tsv)"
printf '%s\n' "$address" > "$proof_files/azure/address"
proof_say "the VM $name is made at $address; its setup (Azure's run command, some minutes)"

b64() { base64 < "$1" | tr -d '\n'; }
from64="$(printf '%s' "$from" | base64 | tr -d '\n')"
said="$(az_sub vm run-command invoke -g "$group" -n "$name" --command-id RunPowerShellScript \
    --scripts @"$proof_here/azure-pc-setup.ps1" \
    --parameters "Key64=$(b64 "$key_file.pub")" "From64=$from64" "Cer64=$(b64 "$proof_files/founderizer-test-signing.cer")" \
    --query 'value[].message' -o tsv)"
printf '%s\n' "$said" | grep -v '^hostkey ' >&2
# The PC's SSH host key, as its own setup read it and Azure's run command brought it back: the first connection
# checks it (no key is taken on trust from that connection).
hostkey="$(printf '%s\n' "$said" | sed -n 's/^hostkey \(ssh-ed25519 [A-Za-z0-9+\/=]*\).*/\1/p' | head -1)"
[ -n "$hostkey" ] || proof_die "the setup gave no SSH host key; the VM costs until azure-pc-delete.sh"
known="$proof_files/azure/known_hosts"
printf '%s %s\n' "$address" "$hostkey" > "$known"
note made "the SSH host key of $name: $(printf '%s' "$hostkey" | ssh-keygen -lf - | awk '{print $2}')"
# Whether the admin user is the built-in Administrator (-500): the setup gives it Admin Approval Mode either way.
printf '%s\n' "$said" | grep '^account: ' | while IFS= read -r line; do note setup "$line"; done
for _ in $(seq 1 60); do
    sleep 10
    if ssh -n -F /dev/null -i "$key_file" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
        -o UserKnownHostsFile="$known" -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
        "builder@$address" 'powershell -NoProfile -Command "if (Test-Path C:\ProgramData\fz-proof-a\done) { (Get-Process explorer -IncludeUserName | Select-Object -First 1).UserName }"' 2>/dev/null |
        grep -q builder; then
        note ready "$name at $address: SSH by key, builder signed in"
        proof_say "ready: SSH as builder with the key, from this address only. Delete it after the run: azure-pc-delete.sh"
        forward
        exit 0
    fi
done
proof_die "no SSH answer with a desktop session of builder in 10 minutes; the VM costs until azure-pc-delete.sh"
