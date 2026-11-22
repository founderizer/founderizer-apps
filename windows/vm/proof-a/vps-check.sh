#!/bin/bash
# vps-check.sh: one "Other VPS" check of the app, in a copy of the clean PC, against a test server in a container on this
# Mac (U2's rig: the Remote tests' image, provider_standin.py for Tailscale's API), so that the SSH library that the app
# carries (SSH.NET, Renci.SshNet.dll) has made one connection on Windows before the owner's sitting. No owner, no cost,
# no real tailnet: this PC's Tailscale is a status file of the proofs' build, and the server's tailscale is a stand-in
# that waits 90 seconds and fails.
#
#   FZ_VM_USER=<session> vps-check.sh build [--ref origin/main] [--want 2026.0.1]
#       the proofs' build with the welcome page from that commit, in the build VM (held while it builds); it says the
#       version of Renci.SshNet.dll in the output and stops when it is not --want
#   FZ_PROOF_A_COPY=<copy> vps-check.sh run
#       the container (root with a password that is made here and typed by secret.sh, never shown), the providers'
#       stand-in, the build in the copy, the pages up to "Other VPS", the address, the password, and the check's result
#   vps-check.sh stop
#       the container and the stand-in end
#
# Out: FZ_PROOF_A_FILES/vps/ (the build's zip, made.txt, the run's log and its pictures, which show no secret).
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077

image="founderizer-remote-test-sshd:3"
container="founderizer-proof-a-vps"
vps_port=58452
files="$proof_files/vps"
mkdir -p "$files"
step() { printf '== %s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$files/run.log" >&2; }
ui() { "$vm_sh" desktop "& C:\\fz\\setup\\ui.ps1 $1" 2>&1 | tr -d '\r'; }
page() { ui '' | grep -o 'page: .*Back:' | sed -E 's/^page: +//; s/ +Back:.*$//'; }
picture() { "$vm_sh" picture "$files/$1.png" >/dev/null 2>&1 && step "picture $1.png"; }

stop_all() {
    docker rm -f "$container" >/dev/null 2>&1 && step "the container ended"
    local folder
    folder="$(sed -n 's/^folder //p' "$files/standin/out" 2>/dev/null | head -1)"
    # It reads its words at its next request: one request after the word.
    if [ -n "$folder" ] && [ -d "$folder" ]; then
        printf 'quit\n' >> "$folder/commands"
        curl -s -m 3 -o /dev/null "$(grep -o 'http://10.0.2.2:[0-9]*' "$files/standin/out" | head -1 | sed 's/10.0.2.2/127.0.0.1/')/" || true
        rm -f "$files/standin/out"
        step "the stand-in ends"
    fi
    return 0
}

case "${1:-}" in
build)
    shift
    ref="origin/main" want=""
    while [ $# -gt 0 ]; do
        case "$1" in --ref) ref="$2"; shift 2 ;; --want) want="$2"; shift 2 ;; *) proof_die "unknown option $1" ;; esac
    done
    [ -n "${FZ_VM_USER:-}" ] || proof_die "say who holds the build VM: FZ_VM_USER=<session>"
    use_build_vm
    repo="$(git -C "$proof_here" rev-parse --show-toplevel)"
    commit="$(git -C "$repo" rev-parse "$ref")" || proof_die "no commit $ref"
    if [ -f "$build_vm_dir/in-use" ] && [ "$(cut -f1 "$build_vm_dir/in-use")" != "$FZ_VM_USER" ]; then
        proof_die "the build VM is in use by $(cut -f1 "$build_vm_dir/in-use"): build when it is free"
    fi
    held_before=""; [ -f "$build_vm_dir/in-use" ] && held_before=yes
    "$vm_sh" hold || exit 1
    work="$(mktemp -d "${TMPDIR:-/tmp}/proof-a-vps.XXXXXX")"
    trap '[ -n "$held_before" ] || "$vm_sh" release; rm -rf "$work"' EXIT
    git -C "$repo" archive --format=tar "$commit" -- app/windows/Directory.Build.props app/windows/global.json \
        app/windows/nuget.config app/windows/Founderizer.Core app/windows/Founderizer.Install app/windows/Founderizer.Owner \
        app/windows/Founderizer.Remote app/windows/Founderizer.Setup app/windows/Founderizer.Windows \
        app/vectors/agent-marks.json | tar -x -C "$work"
    "$vm_sh" run 'if (Test-Path C:\fz\proof-a\vps) { Remove-Item -Recurse -Force C:\fz\proof-a\vps }; New-Item -ItemType Directory -Force -Path C:\fz\proof-a\vps\src\windows, C:\fz\proof-a\vps\src\vectors | Out-Null'
    ( cd "$work/app/windows" && "$vm_sh" copy Directory.Build.props global.json nuget.config Founderizer.Core Founderizer.Install \
        Founderizer.Owner Founderizer.Remote Founderizer.Setup Founderizer.Windows vm:C:/fz/proof-a/vps/src/windows/ )
    "$vm_sh" copy "$work/app/vectors/agent-marks.json" vm:C:/fz/proof-a/vps/src/vectors/
    step "the proofs' build of $commit"
    said="$(run_ps vps-build.ps1 "want=$want")" || { printf '%s\n' "$said"; proof_die "the build failed"; }
    printf '%s\n' "$said"
    "$vm_sh" copy vm:C:/fz/proof-a/vps/app.zip "$files/app.zip"
    { printf 'commit %s (%s)\nbuilt %s\n' "$commit" "$ref" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; printf '%s\n' "$said" | grep -E 'Renci|zip'; } > "$files/made.txt"
    cat "$files/made.txt"
    ;;
run)
    use_copy
    [ -f "$files/app.zip" ] || proof_die "no build: vps-check.sh build first"
    docker image inspect "$image" >/dev/null 2>&1 || proof_die "no image $image: run the Remote tests once (ContainerSshd builds it)"
    stop_all
    : > "$files/run.log"
    # The server: root by password over SSH (and keys), systemd's mark, and a tailscale that waits and fails.
    step "the test server: a container on 127.0.0.1:$vps_port"
    docker run -d --name "$container" -p "127.0.0.1:$vps_port:22" "$image" >/dev/null || proof_die "the container did not start"
    docker exec -i "$container" sh -c 'mkdir -p /run/systemd/system /etc/ssh/sshd_config.d &&
        printf "PermitRootLogin yes\n" > /etc/ssh/sshd_config.d/00-proof-a.conf &&
        printf "#!/bin/sh\nsleep 90\necho \"tailscale stand-in: no network here\" >&2\nexit 1\n" > /usr/local/bin/tailscale &&
        chmod 755 /usr/local/bin/tailscale && kill -HUP 1' < /dev/null || proof_die "the container was not set up"
    password="Pa-$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
    printf 'root:%s\n' "$password" | docker exec -i "$container" chpasswd || proof_die "no password for root"
    # The providers' stand-in, for this PC's Tailscale key page.
    mkdir -p "$files/standin"
    ( cd "$(git -C "$proof_here" rev-parse --show-toplevel)" && python3 -I app/windows/vm/provider_standin.py > "$files/standin/out" 2>&1 & )
    for _ in $(seq 1 20); do grep -q -o '10.0.2.2:[0-9]*' "$files/standin/out" 2>/dev/null && break; sleep 0.5; done
    providers="$(grep -o 'http://10.0.2.2:[0-9]*' "$files/standin/out" | head -1)"
    [ -n "$providers" ] || proof_die "the stand-in gave no address"
    step "the providers' stand-in at $providers"
    step "the build into the copy"
    "$vm_sh" run 'if (Test-Path C:\fz\proof-a\vps) { Remove-Item -Recurse -Force C:\fz\proof-a\vps }; New-Item -ItemType Directory -Force -Path C:\fz\proof-a\vps | Out-Null'
    "$vm_sh" copy "$files/app.zip" vm:C:/fz/proof-a/vps/
    # This PC's Tailscale, as the proofs' build reads it from a file: running, with an address of the test range.
    printf '%s\n' '{"BackendState":"Running","Self":{"HostName":"proof-a-pc","TailscaleIPs":["100.64.0.20"],"Online":true},"Peer":{}}' > "$files/status.json"
    "$vm_sh" copy "$files/status.json" vm:C:/fz/proof-a/vps/
    "$vm_sh" run 'Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::ExtractToDirectory("C:\fz\proof-a\vps\app.zip", "C:\fz\proof-a\vps\out"); "unpacked: " + (Get-ChildItem C:\fz\proof-a\vps\out).Count + " files"' ||
        proof_die "the build was not unpacked in the copy"
    "$vm_sh" desktop "\$env:FOUNDERIZER_TAILSCALE_STATUS = 'C:\\fz\\proof-a\\vps\\status.json'; \$env:FOUNDERIZER_PROVIDERS = '$providers'; Start-Process C:\\fz\\proof-a\\vps\\out\\Founderizer.App.exe" >/dev/null
    sleep 12
    step "page: $(page)"
    for press in '#first-run-set-up' '#first-run-reports-none' '#first-run-name-continue' '#first-run-ai-codex'; do
        ui "-Click \"$press\"" >/dev/null; sleep 3; step "pressed $press; page: $(page)"
    done
    # "1 server": the slider's left end, in the screen's 96-DPI points (1440 by 900).
    "$vm_sh" desktop '& C:\fz\setup\click.ps1 -X 488 -Y 398' >/dev/null 2>&1
    sleep 1
    ui '-Click "#first-run-servers-continue"' >/dev/null; sleep 4; step "1 server; page: $(page)"
    # The stand-in's Tailscale token (a token of no one), through the hidden prompt and its Enter.
    printf 'tskey-api-proofastandin-0000000000000000\n' |
        "$proof_here/secret.sh" "Tailscale token" --field first-run-tailscale-key >> "$files/run.log" 2>&1
    sleep 5; step "page: $(page)"
    ui '-Click "#first-run-cloud-other"' >/dev/null; sleep 3; step "Other VPS; page: $(page)"
    ui "-Field \"Address\" -Type \"10.0.2.2:$vps_port\"" >/dev/null
    for _ in $(seq 1 40); do
        "$vm_sh" desktop '& C:\fz\proof-a\focus.ps1' 2>/dev/null | grep -q 'id=first-run-vps-password' && break
        sleep 3
    done
    step "the address is typed; page: $(page)"
    printf '%s\n%s\n' "$password" "$password" |
        "$proof_here/secret.sh" "New test server password" --field first-run-vps-password --twice >> "$files/run.log" 2>&1
    unset password
    sleep 10
    step "page: $(page)"
    picture after-password
    step "the server's log: $(docker logs "$container" 2>&1 | grep -c '^Accepted') sign-ins accepted:"
    docker logs "$container" 2>&1 | grep '^Accepted' | sed 's/ SHA256:.*//' | tee -a "$files/run.log" >&2
    ui '-Click "Install"' >/dev/null; sleep 90
    picture after-install
    step "the install runs over SSH; the server's tailscale is a stand-in, so it stops at the private network. vps-check.sh stop ends the server"
    ;;
stop)
    stop_all
    ;;
*)
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
