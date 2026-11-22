#!/bin/bash
# azure-pc-delete.sh: removes the x64 clean PC of proof A's run 2 right after the run (azure-pc-make.sh): the VM, its
# disk, NIC and public IP, its network and network security group, then its empty resource group. It acts only on a
# group whose tags say temporary=true and proof=a, in the subscription that FZ_AZURE_SUBSCRIPTION_NAME names
# (Pay-As-You-Go), never the CLI's default. Each removal is a line of FZ_PROOF_A_FILES/azure/record.log (the time,
# "removed", the id), and at the end each id that the group held is checked: gone.
#
#   azure-pc-delete.sh [--group proof-a-pc-rg] [--what-if]
#
# --what-if lists what it would remove, and removes nothing. At the end it removes the deployments of azure-pc-make.sh
# at the subscription and names each group that was not there before the make.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077

group="proof-a-pc-rg"
dry=""
while [ $# -gt 0 ]; do
    case "$1" in
        --group) group="$2"; shift 2 ;;
        --what-if) dry=yes; shift ;;
        *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done
[[ "$group" =~ ^[a-z0-9-]{1,40}$ ]] || proof_die "a group's name has small letters, digits and \"-\""
record="$proof_files/azure/record.log"
mkdir -p "$proof_files/azure"
note() { [ -n "$dry" ] || printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$record"; }

subscription_name="${FZ_AZURE_SUBSCRIPTION_NAME:-Pay-As-You-Go}"
# The tenant too: the CLI's profile holds several tenants, and a subscription of that name can be in more than one.
tenant="${FZ_AZURE_TENANT:-}"
[[ "$tenant" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    proof_die "set FZ_AZURE_TENANT to the tenant id of the subscription that pays (outside the repository; README.md, Proof A)"
ids="$(az account list --all --query "[?name=='$subscription_name' && state=='Enabled' && tenantId=='$tenant'].id" -o tsv)"
[ "$(printf '%s\n' "$ids" | grep -c .)" = 1 ] || proof_die "not one enabled subscription named $subscription_name in tenant FZ_AZURE_TENANT"
subscription="$ids"
az_sub() { az "$@" --subscription "$subscription"; }

# The deployments of azure-pc-make.sh at the subscription: each keeps its parameters, this Mac's public address too.
remove_deployments() {
    local deployment
    for deployment in $(az_sub deployment sub list --query "[?starts_with(name, 'proof-a-pc-')].name" -o tsv); do
        if [ -n "$dry" ]; then proof_say "what-if: the deployment $deployment would be removed"; continue; fi
        az_sub deployment sub delete --name "$deployment" -o none
        note removed "the deployment $deployment at the subscription"
        proof_say "removed the deployment $deployment"
    done
}

if [ "$(az_sub group exists -n "$group")" != true ]; then
    proof_say "no resource group $group in $subscription_name"
    remove_deployments
    exit 0
fi
tags="$(az_sub group show -n "$group" --query '[tags.temporary, tags.proof]' -o tsv | tr '\n\t' '  ' | xargs)"
[ "$tags" = "true a" ] || proof_die "the group $group is not a temporary group of proof A (tags: $tags); nothing was removed"
group_id="$(az_sub group show -n "$group" --query id -o tsv)"
held="$(az_sub resource list -g "$group" --query '[].[type, id]' -o tsv)"
proof_say "the group $group holds:"
printf '%s\n' "$held" | awk -F'\t' 'NF {sub(".*/", "", $2); print "  " $1 "  " $2}' >&2
if [ -n "$dry" ]; then
    proof_say "what-if: these and the group would be removed; nothing was removed"
    exit 0
fi

# The VM first (its disk, NIC and public IP go with it where the template said so), then the rest in the order of
# what holds what.
for type in Microsoft.Compute/virtualMachines Microsoft.Compute/disks Microsoft.Network/networkInterfaces \
            Microsoft.Network/publicIPAddresses Microsoft.Network/virtualNetworks Microsoft.Network/networkSecurityGroups; do
    for id in $(az_sub resource list -g "$group" --resource-type "$type" --query '[].id' -o tsv); do
        az_sub resource delete --ids "$id" -o none
        note removed "$id"
        proof_say "removed ${id##*/} ($type)"
    done
done
left="$(az_sub resource list -g "$group" --query '[].id' -o tsv)"
for id in $left; do
    az_sub resource delete --ids "$id" -o none
    note removed "$id"
    proof_say "removed ${id##*/}"
done
az_sub group delete -n "$group" --yes -o none
note removed "$group_id"
proof_say "removed the group $group"
missing=0
for id in $(printf '%s\n' "$held" | cut -f2) "$group_id"; do
    if az_sub resource show --ids "$id" -o none >/dev/null 2>&1; then
        note still "$id"
        proof_say "STILL THERE: $id"
        missing=1
    else
        note gone "$id"
    fi
done
[ "$(az_sub group exists -n "$group")" = false ] || { proof_say "the group $group still exists"; missing=1; }
# The forward of azure-pc-make.sh and its copy folder on this Mac go too.
azure_copy="$(copy_dir azure)"
if [ -f "$azure_copy/port" ]; then
    pkill -f "ssh .*-L 127.0.0.1:$(cat "$azure_copy/port"):127.0.0.1:22 " 2>/dev/null || true
    rm -rf "${azure_copy:?}"
    note removed "this Mac's SSH forward and the copy folder azure"
fi
rm -f "$proof_files/azure/address" "$proof_files/azure/known_hosts"
remove_deployments
# The groups now against the list before the make: a group that Azure made with the run (NetworkWatcherRG with the
# first virtual network of a region) is named, and stays for the owner's word.
if [ -f "$proof_files/azure/groups-before.txt" ]; then
    new_groups="$(az_sub group list --query '[].name' -o tsv | sort | comm -13 "$proof_files/azure/groups-before.txt" -)"
    if [ -n "$new_groups" ]; then
        for g in $new_groups; do
            note still "the group $g, not there before the make"
            proof_say "a group that was not there before the make: $g (az group delete -n $g --subscription <the subscription>, after a look)"
        done
        missing=1
    else
        note gone "no group but those of before the make"
    fi
fi
[ "$missing" = 0 ] && proof_say "each resource of $group is gone; the record: $record"
exit "$missing"
