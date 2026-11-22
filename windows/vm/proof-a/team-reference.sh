#!/bin/bash
# team-reference.sh: the reference team.json of proof A, made by the Mac's install line for the same choices
# (app/vectors/remote-install.json, the Mac's own plans) in the agent-install rig: Ubuntu VMs of Tart on a Headscale test
# network on this Mac, with no owner, no cost and no real tailnet. The PC's read (team.sh read) is compared with it
# "but for the names" (team.sh compare).
#
#   team-reference.sh one     "1 server": the hub and the manager "juno" on Codex on one server (run 2's choices)
#   team-reference.sh two     "2 servers": the hub with its manager to place later, then a second server joined with
#                             the hub's join code and the manager moved to it with Codex (run 1's choices)
#   team-reference.sh place-two         the join and the move of "two" on a hub that answers, then its team
#   team-reference.sh keep-one|keep-two   keeps the team of a hub that answers, after an installer that stopped late
#   team-reference.sh remove  stops and deletes this script's VMs (ait-ref-*), by their exact names
#
# FZ_REF_RIG is the rig's folder (rig.sh, rigkey: $HOME/dev/founderizer-plans/agent-install-test/rig). The VMs are
# ait-ref-hub, ait-ref-mgr and ait-ref-own (the owner's computer: it claims the hub and makes the owner's calls with its
# own key, which stays in it). The network's key is the rig's own (Headscale) and goes to each VM on standard input. Out,
# in FZ_PROOF_A_FILES/reference/: <one|two>-team.json (team.json at the hub's revision), <one|two>-ui-team.json (the
# hub's GET /ui/team, without its keys' views), and the compare of the two (it must find no difference).
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077

rig="${FZ_REF_RIG:-$HOME/dev/founderizer-plans/agent-install-test/rig}"
tart="$HOME/.tart/onboard-rig/tart.app/Contents/MacOS/tart"
vectors="$proof_here/../../../vectors/remote-install.json"
out="$proof_files/reference"
# A command as root in a VM, through Tart's own agent: the hub's install closes SSH on the plain network (its firewall
# lets only the private network in), as on a real server.
on() { local vm="$1"; shift; "$tart" exec -i "$vm" sudo bash -c "$*"; }
step() { printf '== %s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# One program of a plan of the vectors, as root, with its standard input.
program() {
    python3 -I - "$vectors" "$1" "$2" <<'PY'
import json, sys
plans = {p["name"]: p for p in json.load(open(sys.argv[1]))["plans"]}
step = next(s for s in plans[sys.argv[2]]["steps"] if s["id"] == sys.argv[3])
print(step["programs"][0]["as_root"])
PY
}
run_step() {    # run_step <vm> <plan> <step id> [input]
    local text
    text="$(program "$2" "$3")" || proof_die "no step $3 in the plan $2"
    # Tart's agent runs a command in its own service's group of processes, and an update that restarts the agent ends
    # them all: the installer that the start step leaves running gets a scope of its own, as an SSH session gives it.
    [ "$3" = start ] && text="systemd-run --scope --quiet bash -c $(printf '%q' "$text")"
    if [ $# -ge 4 ]; then printf '%s\n' "$4" | on "$1" "$text"; else on "$1" "$text" < /dev/null; fi
}
new_vm() {      # a VM of this script that exists already is used again: a run that broke off goes on where it stopped
    local name="$1"
    if "$tart" list 2>/dev/null | awk -v n="ait-$name" '$2 == n {f=1} END {exit !f}'; then
        "$tart" list 2>/dev/null | awk -v n="ait-$name" '$2 == n && /running/ {f=1} END {exit !f}' ||
            zsh "$rig/rig.sh" up "ait-$name" >&2
        step "ait-$name exists: it is used as it is"
        return 0
    fi
    zsh "$rig/rig.sh" server "$name" >&2 || proof_die "the rig did not make ait-$name"
}
network_key() {
    docker exec ait-headscale headscale preauthkeys create --user 1 --reusable --expiration 2h -o json 2>/dev/null |
        python3 -I -c 'import json,sys; print(json.load(sys.stdin)["key"])'
}
# The owner's call from its computer: the key from its own file there, to curl's configuration on standard input.
owner_call() {  # owner_call <method> <path> [json]
    on ait-ref-own "f=\$(ls /root/.founderizer/owner-keys/ | grep -v -e pending -e '^\\.' | head -1); h=\${f%_*}; p=\${f##*_};
        { printf 'header = \"Authorization: Bearer %s\"\n' \"\$(cat /root/.founderizer/owner-keys/\$f)\"; printf 'header = \"Content-Type: application/json\"\nheader = \"X-Fleet-Client: founderizer-proof-a-reference/1\"\n'; } |
        curl -fsS -m 30 -K - -X $1 ${3:+--data-binary @/root/body.json} \"http://\$h:\$p$2\"" < /dev/null
}
owner_post() {  # owner_post <path> <json>
    printf '%s' "$2" | on ait-ref-own 'cat > /root/body.json' && owner_call POST "$1" body
}
db() { owner_call GET /ui/mobile | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["db"])'; }

install_hub() {   # install_hub <plan>: the Mac's steps of that plan, on ait-ref-hub, with the claim from ait-ref-own
    local plan="$1" key line
    if on ait-ref-hub 'pgrep -f "[s]h /root/fleet-kit/hub.sh" >/dev/null' < /dev/null; then
        step "the hub's install runs already: on to its link code"
    else
        key="$(network_key)"; [ -n "$key" ] || proof_die "Headscale gave no key"
        step "the owner's computer joins the test network"
        run_step ait-ref-own "hub, one server, a manager named juno on Codex" network "$key" >/dev/null || proof_die "ait-ref-own did not join"
        step "the hub's server joins the test network (the plan's own key step)"
        run_step ait-ref-hub "hub, one server, a manager named juno on Codex" network "$key" || proof_die "ait-ref-hub did not join"
        unset key
        for id in code plan start; do step "the plan's step $id"; run_step ait-ref-hub "$plan" "$id" || proof_die "step $id failed"; done
    fi
    step "wait for the link code (FLEET_CLAIM=)"
    for _ in $(seq 1 120); do
        line="$(run_step ait-ref-hub "$plan" wait_claim | grep 'FLEET_CLAIM=' | tail -1 | sed 's/^[[:space:]]*//')"
        [ -n "$line" ] && break
        sleep 10
    done
    [ -n "$line" ] || proof_die "no link code in 20 minutes"
    step "the claim, from the owner's computer"
    on ait-ref-own "$line" < /dev/null >/dev/null
    # The line's own curl can fail inside sh -c with no exit code: the key's file says whether the hub took it.
    on ait-ref-own 'ls /root/.founderizer/owner-keys/ | grep -v -e pending -e "^\\." | grep -q .' < /dev/null ||
        proof_die "the claim failed: the owner's computer holds no key of the hub"
    step "wait for READY"
    for _ in $(seq 1 90); do run_step ait-ref-hub "$plan" wait_ready | grep -q READY && return 0; sleep 20; done
    proof_die "no READY in 30 minutes"
}

keep() {    # keep <one|two>: team.json at the hub's revision, and the hub's own owner reads of it (GET /ui/team without
            # the keys' views, and GET /ui/servers: each server's hub, agents and SSH, hub_shared and shape)
    mkdir -p "$out"
    on ait-ref-hub "runuser -u fleet -- env HOME=/home/fleet XDG_RUNTIME_DIR=/run/user/\$(id -u fleet) sh -c 'kit=\$(systemctl --user show -p WorkingDirectory --value fleet-hub); git -C \"\${kit:-/home/fleet/fleet-pilot}\" show HEAD:team.json'" \
        < /dev/null > "$out/$1-team.json" || proof_die "team.json was not read"
    local generation reads
    generation="$(db)"
    reads="$(mktemp -d "${TMPDIR:-/tmp}/proof-a-reads.XXXXXX")"
    owner_call GET "/ui/team?db=$generation" > "$reads/team.json" || proof_die "GET /ui/team was not read"
    owner_call GET "/ui/servers?db=$generation" > "$reads/servers.json" || proof_die "GET /ui/servers was not read"
    python3 -I - "$reads/team.json" "$reads/servers.json" > "$out/$1-ui-team.json" <<'PY' || proof_die "the reads were not kept"
import json, sys
team, fleet = (json.load(open(path)) for path in sys.argv[1:3])
for line in team["lines"]:
    for k in ("auth", "vault_grant", "vault_create_grant"):
        line.pop(k, None)
print(json.dumps({"revision": team["revision"], "sha256": team["sha256"], "lines": team["lines"],
                  "machines": {n: {"agents": m["agents"], "ssh": m["ssh"]} for n, m in team["machines"].items()},
                  "servers": {s["name"]: {"hub": s["hub"], "agents": s["agents"], "ssh": (s.get("access") or {}).get("ssh")}
                              for s in fleet["servers"]},
                  "hub_shared": fleet.get("hub_shared"), "shape": (fleet.get("shape") or {}).get("step")}, indent=2))
PY
    rm -rf "$reads"
    step "kept $out/$1-team.json and $1-ui-team.json; the compare of the two forms:"
    python3 -I "$proof_here/team_compare.py" "$out/$1-team.json" "$out/$1-ui-team.json"
}

place() {      # "two": the manager's server joins the test network and the fleet, and the manager moves to it
    step "the manager's server joins the test network, then the fleet with a join code"
    key="$(network_key)"
    run_step ait-ref-mgr "hub, one server, a manager named juno on Codex" network "$key" || proof_die "ait-ref-mgr did not join"
    unset key
    join="$(owner_post /ui/servers/join "{\"request_id\": \"$(uuidgen | tr A-Z a-z)\", \"db\": \"$(db)\", \"kind\": \"linux\"}")" ||
        proof_die "no join code"
    line="$(printf '%s' "$join" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["line"])')"
    on ait-ref-mgr "systemd-run --scope --quiet bash -c $(printf %q "$line")" < /dev/null || proof_die "the join line failed"
    unset line join
    step "wait until the hub lists the joined server as free"
    for _ in $(seq 1 60); do
        server="$(owner_call GET "/ui/servers?db=$(db)" | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
rows = s.get("servers") or []
print(next((r["name"] for r in rows if r.get("available") and not r.get("hub")), ""))')"
        [ -n "$server" ] && break
        sleep 15
    done
    [ -n "$server" ] || proof_die "the joined server is not free in 15 minutes"
    step "the manager on $server with Codex (POST /ui/team/agents/juno/move)"
    sha="$(owner_call GET "/ui/team?db=$(db)" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')"
    owner_post /ui/team/agents/juno/move "{\"request_id\": \"$(uuidgen | tr A-Z a-z)\", \"db\": \"$(db)\", \"base_sha256\": \"$sha\", \"server\": \"$server\", \"runtime\": \"codex\"}" ||
        proof_die "the move was refused"
    echo
}

case "${1:-}" in
one|two)
    [ -x "$tart" ] && [ -f "$rig/rig.sh" ] && [ -f "$rig/rigkey" ] || proof_die "no agent-install rig at $rig"
    shape="$1"
    step "the VMs: the owner's computer and the hub's server"
    new_vm ref-own; new_vm ref-hub
    [ "$shape" = two ] && new_vm ref-mgr
    zsh "$rig/rig.sh" net-up >&2 || proof_die "the test network did not start"
    if [ "$shape" = one ]; then
        install_hub "hub, one server, a manager named juno on Codex"
    else
        install_hub "hub, two servers, a manager named juno"
        place
    fi
    keep "$shape"
    ;;
place-two)
    # A hub of "two" whose install answers: the manager's server and its move, then the team.
    place
    keep two
    ;;
keep-one|keep-two)
    # A run whose installer stopped after its team.json and its claim (the hub answers): keep what the hub has now.
    keep "${1#keep-}"
    ;;
remove)
    for vm in ait-ref-own ait-ref-hub ait-ref-mgr; do
        "$tart" list 2>/dev/null | awk -v n="$vm" '$2 == n {f=1} END {exit !f}' || continue
        "$tart" stop "$vm" >/dev/null 2>&1 || true
        "$tart" delete "$vm" && rm -f "$rig/ip-$vm" "$rig/run-$vm.log" && echo "deleted $vm"
    done
    ;;
*)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
