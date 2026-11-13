#!/bin/zsh
set -eu
cd "${0:A:h}"
swift build -c release
fleet_app="$PWD/build/Founderizer.app"
mkdir -p "$fleet_app/Contents/MacOS" "$fleet_app/Contents/Resources"
cp .build/release/Founderizer "$fleet_app/Contents/MacOS/Founderizer"
cp Info.plist "$fleet_app/Contents/Info.plist"
cp AppIcon.icns "$fleet_app/Contents/Resources/AppIcon.icns"
python3 Localization/l10n.py compile "$fleet_app/Contents/Resources"
fleet_setup="$fleet_app/Contents/XPCServices/com.founderizer.setup.xpc"
mkdir -p "$fleet_setup/Contents/MacOS" "$fleet_setup/Contents/Resources/FleetKit"
cp .build/release/FleetSetupService "$fleet_setup/Contents/MacOS/FleetSetupService"
cp SetupService/Info.plist "$fleet_setup/Contents/Info.plist"
fleet_kit_source="${FLEET_KIT_SOURCE:-$HOME/dev/founderizer-core}"
[[ -f "$fleet_kit_source/onboard.py" ]] || { print -u2 "Set FLEET_KIT_SOURCE to the Fleet worker repository, which contains onboard.py."; exit 1; }
git -C "$fleet_kit_source" show HEAD:onboard.py > "$fleet_setup/Contents/Resources/FleetKit/onboard.py"
codesign --force --sign - "$fleet_setup"
codesign --force --sign - --entitlements Entitlements.plist "$fleet_app"
codesign --verify --deep --strict "$fleet_app"
open "$fleet_app"
