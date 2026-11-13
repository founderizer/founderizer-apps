#!/bin/bash
# Builds fz-qemu-launcher (README.md, "Why a launcher") for this Mac.
#
#   build.sh <output path> [UTM.app]
#
# It links the program to UTM's frameworks folder and signs it ad hoc with
# entitlements.plist: the hypervisor entitlement and nothing else.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?the output path of the launcher}"
utm="${2:-/Applications/UTM.app}"
frameworks="$utm/Contents/Frameworks"
if [ ! -d "$frameworks" ]; then
    echo "no UTM frameworks at $frameworks" >&2
    exit 1
fi

mkdir -p "$(dirname "$out")"
xcrun clang -O2 -Wall -Wextra -arch arm64 -mmacosx-version-min=13.0 \
    -Wl,-rpath,"$frameworks" \
    -o "$out" "$here/fz-qemu-launcher.c"
codesign --force --sign - --entitlements "$here/entitlements.plist" "$out"
codesign -d --entitlements - "$out" 2>/dev/null | grep -q 'com.apple.security.hypervisor'
echo "$out"
