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
swiftc -parse-as-library -I "$probe_bin/Modules" test-support/SetupProbe.swift "$probe_bin/FleetSetupIPC.build/SetupIPC.swift.o" -o "$probe_app/Contents/MacOS/SetupProbe"
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
import json, os, select, sys

def emit(seq, event_type, **fields):
    print(json.dumps(dict(v=1, run="fixture", seq=seq, type=event_type, **fields)), flush=True)
if "--prepare-runtime" in sys.argv:
    # A provider's setup for an existing agent: exactly the agreed arguments, built by the service from typed fields.
    expected = ["run", "--json", "--auth", "agent", "--hub", "http://localhost:8765/", "--repo", "git://localhost/fleet-pilot.git",
                "--prepare-runtime", "worker4", "--runtime", "claude", "--generation", "g1", "--machine", "worker4"]
    emit(1, "step", id="preflight", title="Synthetic preflight", status="running")
    if sys.argv[1:] != expected:
        emit(2, "result", status="failed", summary="Unexpected preparation arguments: " + repr(sys.argv[1:]))
        sys.exit(0)
    emit(2, "step", id="preflight", title="Synthetic preflight", status="done")
    emit(3, "result", status="ok", summary="Claude Code is ready on worker4.")
    sys.exit(0)
if "stop.invalid" in sys.argv or "ignore.invalid" in sys.argv:
    # Stop: say what this process got from the service for SIGTERM, then wait for it. The second form ignores
    # SIGTERM itself, as only a broken executor does.
    import signal, time
    got = "ignored" if signal.getsignal(signal.SIGTERM) == signal.SIG_IGN else "default"
    blocked = "blocked" if signal.SIGTERM in signal.pthread_sigmask(signal.SIG_BLOCK, []) else "open"
    if "ignore.invalid" in sys.argv:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    emit(1, "step", id="wait", title="Synthetic wait", status="running", detail="SIGTERM " + got + " " + blocked)
    while True:
        time.sleep(0.1)
emit(1, "step", id="provider_login", title="Synthetic login", status="running")
if "fixture.invalid" not in sys.argv:
    emit(2, "result", status="failed", summary="Unexpected fixture arguments: " + repr(sys.argv))
    sys.exit(0)
emit(2, "prompt", id="password", kind="secret", data={"label": "provider_password"})
try:
    secret = os.fdopen(3).readline().rstrip("\n")
except OSError:
    emit(3, "result", status="failed", summary="FD 3 not open")
    sys.exit(0)
answer = json.loads(sys.stdin.readline())
assert secret == "synthetic-fd3-canary"
assert answer == {"prompt": "password", "answer": "sent"}
assert secret not in str(sys.argv) and secret not in str(dict(os.environ))
emit(3, "step", id="provider_login", title="Synthetic login", status="done")
# The first Claude sign-in card: an answer to a wrong-purpose prompt must never reach the executor.
command = "ssh -F /fixture/config -t 100.64.0.9 'runuser -u fleet -- bash -lc true'"
emit(4, "step", id="runtime_login", title="Synthetic Claude sign-in", status="running")
emit(5, "prompt", id="bad-terminal", kind="terminal", data={"purpose": "codex_login", "command": command})
if select.select([sys.stdin], [], [], 2.0)[0]:
    emit(6, "result", status="failed", summary="The service forwarded an answer to a wrong-purpose prompt")
    sys.exit(0)
emit(6, "prompt", id="terminal", kind="terminal", data={"purpose": "claude_login", "command": command})
answer = json.loads(sys.stdin.readline())
assert answer == {"prompt": "terminal", "answer": "copied"}, answer
emit(7, "step", id="runtime_login", title="Synthetic Claude sign-in", status="done")
emit(8, "result", status="ok", machine={"name": "fixture", "security": {"pending_security": 3, "reboot_required": True}}, summary="Private pipe checked")
PY
codesign --force --sign - "$probe_service"
codesign --force --sign - --entitlements Entitlements.plist "$probe_app"
codesign --verify --deep --strict "$probe_app"
"$probe_app/Contents/MacOS/SetupProbe"
