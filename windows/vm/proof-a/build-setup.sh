#!/bin/bash
# build-setup.sh: the setup of proof A, built in the build VM from this checkout's commit, with the first run's welcome
# page (windows-app-plan-v2.md, section 13: only a build with -p:FounderizerWelcome=true has it; no build that a person
# gets has it yet). The release script stays as it is: the build VM gets a copy of release/build-release.ps1 in which
# that one word is true, and the copy is in no commit.
#
#   FZ_VM_USER=<session> build-setup.sh [--ref HEAD] [--version 0.1.0-proof-a] [--build 1] [--arch arm64|arm64,x64]
#
# Before the build it holds the build VM (vm.sh hold: refused while another session holds it) and stops when any
# variable whose name starts with "Founderizer" is set in the build VM, for the machine, the user or the build's own
# process: FounderizerProofsOn=true turns the proofs' parts on in any build (lanes/windows-screens.md, owed after U3,
# item b), and FounderizerWelcome would turn the welcome page off. MSBuild's reused nodes are shut down first and not
# used. After the build it checks that builds.json says no proofs, that Founderizer.App.dll names no
# GetEnvironmentVariable, and that Windows finds the setup's signature valid. It releases the hold that it took.
#
# Out, on this Mac, in FZ_PROOF_A_FILES (lib.sh): build/<version>-<build>/ with the setup, builds.json and made.txt
# (the commit and the checks), and founderizer-test-signing.cer and .thumbprint: the public part of the build VM's
# test certificate, which clean-pc.sh copy trusts in each copy. No private key leaves the build VM.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077

version="0.1.0-proof-a"
build=1
arch="arm64"
ref="HEAD"
while [ $# -gt 0 ]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --build) build="$2"; shift 2 ;;
        --arch) arch="$2"; shift 2 ;;
        --ref) ref="$2"; shift 2 ;;
        *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,40}$ ]] || proof_die "not a version name: $version"
[[ "$build" =~ ^[0-9]{1,9}$ ]] || proof_die "not a build number: $build"
[[ "$arch" =~ ^(arm64|x64|arm64,x64|x64,arm64)$ ]] || proof_die "the kinds of PC are arm64 and x64: $arch"
[ -n "${FZ_VM_USER:-}" ] || proof_die "say who holds the build VM: FZ_VM_USER=<your session's name> build-setup.sh"

use_build_vm
repo="$(git -C "$proof_here" rev-parse --show-toplevel)"
commit="$(git -C "$repo" rev-parse "$ref")" || proof_die "no commit $ref"
sources=(app/windows/Directory.Build.props app/windows/global.json app/windows/nuget.config app/windows/Founderizer.Core
         app/windows/Founderizer.Install app/windows/Founderizer.Launcher app/windows/Founderizer.Owner
         app/windows/Founderizer.Remote app/windows/Founderizer.Setup app/windows/Founderizer.Windows
         app/windows/release app/vectors/agent-marks.json)
[ -z "$(git -C "$repo" status --porcelain -- "${sources[@]}")" ] ||
    proof_say "note: the sources have changes that are not committed; the build takes the commit $commit, not them"

# The hold: refused while another session holds the build VM. A hold of this session from before stays after.
held_before=""
if [ -f "$build_vm_dir/in-use" ]; then
    [ "$(cut -f1 "$build_vm_dir/in-use")" = "$FZ_VM_USER" ] ||
        proof_die "the build VM is in use by $(cut -f1 "$build_vm_dir/in-use") since $(cut -f2 "$build_vm_dir/in-use"): build when it is free"
    held_before=yes
fi
started=""
if ! vm_running_at "$build_vm_dir"; then "$vm_sh" start; started=yes; fi
"$vm_sh" hold
finish() {
    local code=$?
    [ -n "$held_before" ] || "$vm_sh" release || proof_say "the build VM's hold was not released: FZ_VM_USER=$FZ_VM_USER vm.sh release"
    [ -z "$started" ] || "$vm_sh" stop || true
    rm -rf "${work:-/nonexistent-proof-a}"
    exit "$code"
}
work="$(mktemp -d "${TMPDIR:-/tmp}/proof-a-build.XXXXXX")"
trap finish EXIT

# The sources of the commit, nothing else: no build folder of a checkout, no file that is not committed.
git -C "$repo" archive --format=tar "$commit" -- "${sources[@]}" | tar -x -C "$work"
# The copy of the release script with the welcome page: exactly one word changes, or nothing is built.
python3 -I - "$work/app/windows/release/build-release.ps1" "$work/build-release-welcome.ps1" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8-sig").read()
old, new = "'-p:FounderizerWelcome=false'", "'-p:FounderizerWelcome=true'"
if text.count(old) != 1 or new in text:
    sys.exit("build-release.ps1 does not have the one word -p:FounderizerWelcome=false: the copy is not made")
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(old, new))
PY

"$vm_sh" run 'if (Test-Path C:\fz\proof-a\src) { Remove-Item -Recurse -Force C:\fz\proof-a\src }; New-Item -ItemType Directory -Force -Path C:\fz\proof-a\src\windows, C:\fz\proof-a\src\vectors | Out-Null'
( cd "$work/app/windows" && "$vm_sh" copy Directory.Build.props global.json nuget.config Founderizer.Core Founderizer.Install \
    Founderizer.Launcher Founderizer.Owner Founderizer.Remote Founderizer.Setup Founderizer.Windows release vm:C:/fz/proof-a/src/windows/ )
"$vm_sh" copy "$work/app/vectors/agent-marks.json" vm:C:/fz/proof-a/src/vectors/
"$vm_sh" copy "$work/build-release-welcome.ps1" vm:C:/fz/proof-a/

proof_say "the build in the build VM ($arch; 10 to 45 minutes)"
said="$(run_ps build-in-vm.ps1 "version=$version" "build=$build" "arch=$arch")" || { printf '%s\n' "$said"; proof_die "the build failed"; }
printf '%s\n' "$said"

target="$proof_files/build/$version-$build"
mkdir -p "$target"
"$vm_sh" copy "vm:C:/fz/proof-a/release/$version-$build/builds.json" "$target/"
for a in ${arch//,/ }; do "$vm_sh" copy "vm:C:/fz/proof-a/release/$version-$build/Founderizer-Setup-$version-$a.exe" "$target/"; done
"$vm_sh" copy "vm:C:/fz/proof-a/release/$version-$build/founderizer-test-signing.cer" \
    "vm:C:/fz/proof-a/release/$version-$build/founderizer-test-signing.thumbprint" "$proof_files/"
{
    printf 'commit %s\nbuilt %s\nversion %s, build %s, %s\n' "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$version" "$build" "$arch"
    printf 'welcome page: -p:FounderizerWelcome=true (a copy of release/build-release.ps1 in the build VM only)\n'
    printf 'checked: no Founderizer* variable; builds.json proofs false; Founderizer.App.dll names no GetEnvironmentVariable; setup signature Valid\n'
    printf '%s\n' "$said" | grep '^Renci'
    ( cd "$target" && shasum -a 256 Founderizer-Setup-*.exe )
} > "$target/made.txt"
cat "$target/made.txt"
proof_say "the setup is in $target"
