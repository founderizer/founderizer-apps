#!/bin/bash
# Makes the setup disc of the Windows build VM (README.md): the answer file at
# its root, and fz-setup/ with the first-logon script, the host's public SSH key
# and the ARM64 virtio drivers from UTM's guest tools disc.
#
#   make-setup-iso.sh <utm-guest-tools.iso> <ssh public key> <output .iso>
#
# The disc holds no secret: the key is the public half, and the answer file's
# password is replaced at the first sign-in (setup/first-logon.ps1).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tools_iso="${1:?the path of the UTM guest tools disc}"
public_key="${2:?the path of the public SSH key of the host}"
out="${3:?the path of the disc to write}"

work="$(mktemp -d "${TMPDIR:-/tmp}/fz-setup-iso.XXXXXX")"
mount_point="$work/tools"
tree="$work/tree"
mkdir -p "$mount_point" "$tree/fz-setup/drivers"
cleanup() {
    hdiutil detach "$mount_point" -quiet 2>/dev/null || true
    rm -rf "${work:?}"
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$tools_iso" >/dev/null

# The drivers of the devices that vm.sh gives the VM, for Windows 11 on ARM64.
for driver in NetKVM Balloon vioserial viorng pvpanic viogpudo; do
    source_dir="$mount_point/Drivers/$driver/w11/ARM64"
    if [ ! -d "$source_dir" ]; then
        echo "missing on the guest tools disc: Drivers/$driver/w11/ARM64" >&2
        exit 1
    fi
    cp -R "$source_dir" "$tree/fz-setup/drivers/$driver"
done
cp "$mount_point/virtio-win_license.txt" "$tree/fz-setup/drivers/"

cp "$here/autounattend.xml" "$tree/autounattend.xml"
cp "$here/setup/first-logon.ps1" "$tree/fz-setup/first-logon.ps1"
cp "$public_key" "$tree/fz-setup/authorized_keys"

rm -f "$out"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name FZSETUP -o "$out" "$tree"
echo "$out"
