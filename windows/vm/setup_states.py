"""Writes the stand-in readings of each state of the manager's setup (piece U3, Fleet/SetupStandIn.cs of a proofs'
build): a folder for each state, with servers.json, machines.json, fleet.json and team.json, in the shapes that the
library's decoders of GET /ui/servers, /ui/machines and /ui/team take. Example data only (set 8's worker-2 and
KDRT-7QXP). README.md, "The manager's setup against a stand-in".

    python3 -I app/windows/vm/setup_states.py <folder>
    app/windows/vm/vm.sh copy <folder>/install/servers.json <folder>/install/machines.json \\
        <folder>/install/fleet.json <folder>/install/team.json vm:C:/fz/u3/readings/"""
import json
import os
import sys

out = sys.argv[1]
hub_row = {"name": "worker-1", "hub": True, "joined": True, "agents": [], "available": False, "why": []}
team = {"db": "db-1", "revision": "a" * 40, "sha256": "b" * 64, "lines": [{"agent": "juno", "role": "manager"}], "open_tasks": {}}


def servers(agents, available, job=None):
    row = {"name": "worker-2", "hub": False, "joined": True, "agents": agents, "available": available, "why": []}
    if job:
        row["job"] = job
    return {"db": "db-1", "time": 1763700100, "servers": [hub_row, row]}


def machines(runtime=None, signed_in=False, login=None):
    if runtime is None:
        return {"db": "db-1", "machines": []}
    machine = {"agent": "juno", "machine": "worker-2", "role": "manager", "update": {"state": "current"}, "security": {}, "os": {},
               "reported_at": 1763700090, "stale": False, "runtime": {"name": runtime, "signed_in": signed_in}}
    if login:
        machine["login"] = login
    return {"db": "db-1", "machines": [machine]}


def fleet(runtime="claude", **more):
    return {"runtime": runtime, "title": "Fleet Manager", "alive": "", **more}


job = {"id": 7, "kind": "install", "state": "running", "created": 1763700000, "updated": 1763700090, "agent": "juno",
       "runtime": "claude", "step": "runtime", "steps": ["user", "checkout", "runtime", "service"]}
claude_login = {"id": 7, "runtime": "claude", "state": "needs_owner", "started_at": 1763700000, "updated_at": 1763700060,
                "wants_code": True, "url": "https://claude.ai/oauth/authorize?code=true"}
codex_login = {"id": 7, "runtime": "codex", "state": "needs_owner", "started_at": 1763700000, "updated_at": 1763700060,
               "wants_code": False, "url": "https://auth.openai.com/codex/device", "shows_code": "KDRT-7QXP"}
states = {
    # picture 18: the install on worker-2, at its third step
    "install": (servers(["juno"], False, job), machines(), fleet()),
    # picture 19: Claude Code's sign-in waits for its code
    "claude": (servers(["juno"], False), machines("claude", False, claude_login), fleet()),
    # picture 20: Codex's device code
    "codex": (servers(["juno"], False), machines("codex", False, codex_login), fleet("codex")),
    # no picture: signed in, the manager's session starts
    "settingup": (servers(["juno"], False), machines("claude", True), fleet()),
    # no picture: a manager with no server yet and no provider chosen, the server that joined for it there
    "provider": (servers([], True), machines(), fleet(joined="worker-2")),
    # no picture: the manager runs, and its chat takes the page
    "runs": (servers(["juno"], False), machines("claude", True), fleet(alive="manager")),
}
for name, (s, m, f) in states.items():
    folder = os.path.join(out, name)
    os.makedirs(folder, exist_ok=True)
    for file, value in (("servers.json", s), ("machines.json", m), ("fleet.json", f), ("team.json", team)):
        with open(os.path.join(folder, file), "w", encoding="utf-8") as handle:
            json.dump(value, handle)
print("states:", ", ".join(states))
