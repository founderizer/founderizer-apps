#!/bin/zsh
# Builds the Founderizer installer for an always-on Mac (PRODUCT.md P3) as an app bundle.
#
# The customer downloads this app from their own download page, opens it on the Mac that will run their agents, and
# types the link code it shows into Founderizer on their own Mac. Nothing else is typed there.
#
# This script signs it ad hoc, for a run on this Mac. The notarized build the download page serves is signed with
# the owner's Developer ID and stapled: see APPLE-SETUP.md.
set -eu
cd "${0:A:h}"
swift build -c release --product FounderizerInstaller
app="$PWD/build/Founderizer Installer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/FounderizerInstaller "$app/Contents/MacOS/FounderizerInstaller"
cp Installer/Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Installer/setup.sh "$app/Contents/Resources/setup.sh"
codesign --force --sign - --entitlements Installer/Entitlements.plist "$app"
codesign --verify --deep --strict "$app"
print "Built $app"
[[ "${1:-}" == "--open" ]] && open "$app"
