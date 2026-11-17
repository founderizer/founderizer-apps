#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product FleetSetupService >/dev/null
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fleet-setup-test.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
probe_app="$probe_dir/Fleet Setup Test.app"
probe_service="$probe_app/Contents/XPCServices/com.founderizer.setup.xpc"
mkdir -p "$probe_app/Contents/MacOS" "$probe_service/Contents/MacOS" "$probe_service/Contents/Resources/FleetKit"
probe_bin=$(swift build --show-bin-path)
# SwiftPM's own build system keeps a module in Modules/ and its objects in <target>.build/; the newer one (a toolchain
# whose bin path ends in out/Products/Debug) keeps both in the bin folder itself.
modules="$probe_bin/Modules"; [[ -e "$modules/FleetSetupIPC.swiftmodule" ]] || modules="$probe_bin"
ipc="$probe_bin/FleetSetupIPC.build/SetupIPC.swift.o"; [[ -f "$ipc" ]] || ipc="$probe_bin/FleetSetupIPC.o"
swiftc -parse-as-library -I "$modules" test-support/SetupProbe.swift "$ipc" -o "$probe_app/Contents/MacOS/SetupProbe"
cp "$probe_bin/FleetSetupService" "$probe_service/Contents/MacOS/FleetSetupService"
cp SetupService/Info.plist "$probe_service/Contents/Info.plist"
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SetupProbe</string>
<key>CFBundleIdentifier</key><string>com.founderizer.setup-test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cat > "$probe_service/Contents/Resources/FleetKit/onboard.py" <<'PY'
import json, select, signal, sys, time

def emit(seq, event_type, **fields):
    print(json.dumps(dict(v=1, run="fixture", seq=seq, type=event_type, **fields)), flush=True)
machine = sys.argv[sys.argv.index("--machine") + 1] if "--machine" in sys.argv else ""
if machine in ("stop.invalid", "ignore.invalid"):
    # Stop: say what this process got from the service for SIGTERM, then wait for it. The second form ignores
    # SIGTERM itself, as only a broken executor does.
    got = "ignored" if signal.getsignal(signal.SIGTERM) == signal.SIG_IGN else "default"
    blocked = "blocked" if signal.SIGTERM in signal.pthread_sigmask(signal.SIG_BLOCK, []) else "open"
    if machine == "ignore.invalid":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    emit(1, "step", id="wait", title="Synthetic wait", status="running", detail="SIGTERM " + got + " " + blocked)
    while True:
        time.sleep(0.1)
# A provider's setup for an existing agent, the executor's one run: exactly the agreed arguments, built by the service
# from typed fields.
expected = ["run", "--json", "--auth", "agent", "--hub", "http://localhost:8765/", "--repo", "git://localhost/fleet-pilot.git",
            "--prepare-runtime", "worker4", "--runtime", "claude", "--generation", "g1", "--machine", machine]
emit(1, "step", id="preflight", title="Synthetic preflight", status="running")
if sys.argv[1:] != expected:
    emit(2, "result", status="failed", summary="Unexpected preparation arguments: " + repr(sys.argv[1:]))
    sys.exit(0)
if machine == "secret.invalid":
    # A prompt that only the removed runs sent: the service takes it for an invalid status and stops this run.
    emit(2, "prompt", id="password", kind="secret", data={"label": "provider_password"})
    select.select([sys.stdin], [], [], 10.0)
    sys.exit(0)
emit(2, "step", id="preflight", title="Synthetic preflight", status="done")
# The first Claude sign-in card: an answer to a wrong-purpose prompt must never reach the executor.
command = "ssh -F /fixture/config -t 100.64.0.9 'runuser -u fleet -- bash -lc true'"
emit(3, "step", id="runtime_login", title="Synthetic sign-in", status="running")
emit(4, "prompt", id="bad-terminal", kind="terminal", data={"purpose": "codex_login", "command": command})
if select.select([sys.stdin], [], [], 2.0)[0]:
    emit(5, "result", status="failed", summary="The service forwarded an answer to a wrong-purpose prompt")
    sys.exit(0)
emit(5, "prompt", id="terminal", kind="terminal", data={"purpose": "claude_login", "command": command})
answer = json.loads(sys.stdin.readline())
assert answer == {"prompt": "terminal", "answer": "copied"}, answer
# A Tailscale sign-in link, which only the removed new-server run sent, is no link that the service passes on.
emit(6, "prompt", id="tailscale-link", kind="open_url", data={"purpose": "tailscale_login", "url": "https://login.tailscale.com/a/fixture"})
if select.select([sys.stdin], [], [], 2.0)[0]:
    emit(7, "result", status="failed", summary="The service forwarded an answer to a Tailscale link")
    sys.exit(0)
emit(7, "prompt", id="link", kind="open_url", data={"purpose": "codex_login", "url": "https://auth.openai.com/codex/device", "code": "TEST-ONLY"})
answer = json.loads(sys.stdin.readline())
assert answer == {"prompt": "link", "answer": "opened"}, answer
emit(8, "step", id="runtime_login", title="Synthetic sign-in", status="done")
emit(9, "result", status="ok", summary="Claude is prepared for worker4 on worker4.")
PY
codesign --force --sign - "$probe_service"
codesign --force --sign - --entitlements Entitlements.plist "$probe_app"
codesign --verify --deep --strict "$probe_app"
"$probe_app/Contents/MacOS/SetupProbe"
