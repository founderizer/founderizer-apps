#!/usr/bin/env python3
"""The compare of proof A: the hub's team as the clean PC read it (team.sh read) against the team that the Mac's install
line makes for the same choices (a team.json of the agent-install rig, team-reference.sh), "but for the names".

    python3 -I team_compare.py <reference> <read>

Each file is a team.json (it has "agents") or a read of team.sh (it has "lines"). Both become the view that the hub's
owner reads give of team.json:
- GET /ui/team (hub.py team_view, ui_team and machine_readiness): each agent's role, the agent it reports to, its
  machine, runtime, active, model, effort, can, title, expertise, vault and the agents that share its machine; each
  machine that has agents, with its agents and its SSH user and port;
- GET /ui/servers (servers_view): each server (every name of "addresses" but the owner's), whether it is the hub's,
  its agents that are placed (an agent with "placed": false is on no server) and its SSH user and port; whether the
  hub's server takes agents ("hub": {"shared": true}); and the step of the slider ("shape").
Then every agent and machine name is replaced by its place: the manager is <manager>, the others <agent 1>, <agent 2>
in the file's order; the hub's server is <hub>; the other machines are <machine 1>, <machine 2>, the manager's first,
then in the order of the lines and of the servers. Exit 0 when the two views are the same, else 1, with one line for
each difference.

What stays outside the compare, because no owner read gives it: each agent's start line, the goals, the hub's port,
the servers' "kind" and "user" entries, the owner's address and every address. Nothing of the hub's live readings
(sign-ins, versions, jobs, keys) is in a view."""
import json
import sys

SHAPE_STEPS = ("one", "two", "each")      # hub.py SHAPE_STEPS


def ssh_of(ways):
    return {"user": ways["ssh_user"], "port": ways.get("ssh_port", 22)} if (ways or {}).get("ssh_user") else None


def view_of_team(team):
    agents = team["agents"]
    manager = next((n for n, a in agents.items() if a.get("role") == "manager"), None)
    access = team.get("access") or {}
    lines = []
    for name, a in agents.items():
        reports = None if a.get("role") == "manager" else (
            a.get("reports_to") if a.get("reports_to") in agents else manager)
        lines.append({
            "agent": name, "role": a.get("role"), "reports_to": reports, "machine": a.get("machine"),
            "runtime": a.get("runtime"), "active": a.get("active", True) is not False, "model": a.get("model"),
            "effort": a.get("effort"), "can": list(a.get("can") or []), "title": a.get("title"),
            "expertise": list(a.get("expertise") or []), "vault": a.get("vault", "none"),
            "shared_with": sorted(n for n, x in agents.items() if n != name and x.get("machine") == a.get("machine")),
        })
    machines = {}
    for name, a in agents.items():
        machines.setdefault(a.get("machine"), {"agents": []})["agents"].append(name)
    for machine, m in machines.items():
        m["ssh"] = ssh_of(access.get(machine))
    hub = team.get("hub") if isinstance(team.get("hub"), dict) else {}
    servers = {name: {"hub": name == hub.get("machine"),
                      "agents": [n for n, a in agents.items() if a.get("machine") == name and a.get("placed") is not False],
                      "ssh": ssh_of(access.get(name))}
               for name in (team.get("addresses") or {}) if name != "owner"}
    shape = team.get("shape")
    return {"lines": lines, "machines": machines, "servers": servers, "hub_shared": hub.get("shared") is True,
            "shape": shape["step"] if isinstance(shape, dict) and shape.get("step") in SHAPE_STEPS else None}


def view_of_read(read):
    keys = ("agent", "role", "reports_to", "machine", "runtime", "active", "model", "effort", "can", "title",
            "expertise", "vault", "shared_with")
    lines = [{k: line.get(k) for k in keys} for line in read["lines"]]
    for line, raw in zip(lines, read["lines"]):
        if line["shared_with"] is None:     # a whole answer of GET /ui/team has it under placement
            line["shared_with"] = (raw.get("placement") or {}).get("shared_with")
        for k in ("can", "expertise", "shared_with"):
            line[k] = list(line[k] or [])
        line["shared_with"] = sorted(line["shared_with"])
    machines = {name: {"agents": list(m.get("agents") or []), "ssh": m.get("ssh")}
                for name, m in (read.get("machines") or {}).items()}
    # A read without the servers' part (a read of before this part) differs from every reference, as it should.
    servers = {name: {"hub": s.get("hub") is True, "agents": list(s.get("agents") or []), "ssh": s.get("ssh")}
               for name, s in (read.get("servers") or {}).items()}
    return {"lines": lines, "machines": machines, "servers": servers,
            "hub_shared": read.get("hub_shared"), "shape": read.get("shape")}


def without_names(view):
    agents, machines = {}, {}
    for line in view["lines"]:
        if line["role"] == "manager":
            agents[line["agent"]] = "<manager>"
    others = 0
    for line in view["lines"]:
        if line["agent"] not in agents:
            others += 1
            agents[line["agent"]] = f"<agent {others}>"
    for name, s in view["servers"].items():
        if s["hub"]:
            machines[name] = "<hub>"
    count = 0
    names = [line["machine"] for line in sorted(view["lines"], key=lambda x: x["role"] != "manager")]
    for name in names + list(view["machines"]) + list(view["servers"]):
        if name not in machines:
            count += 1
            machines[name] = f"<machine {count}>"
    a = lambda n: agents.get(n, n)
    m = lambda n: machines.get(n, n)
    lines = {}
    for line in view["lines"]:
        lines[a(line["agent"])] = dict(line, agent=a(line["agent"]), reports_to=a(line["reports_to"]) if line["reports_to"] else None,
                                       machine=m(line["machine"]), shared_with=sorted(a(n) for n in line["shared_with"]))
    return {"agents": lines,
            "machines": {m(n): {"agents": sorted(a(x) for x in v["agents"]), "ssh": v["ssh"]}
                         for n, v in view["machines"].items()},
            "servers": {m(n): {"hub": v["hub"], "agents": sorted(a(x) for x in v["agents"]), "ssh": v["ssh"]}
                        for n, v in view["servers"].items()},
            "hub_shared": view["hub_shared"], "shape": view["shape"]}


def flat(value, path=""):
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            out.update(flat(v, f"{path}.{k}" if path else k))
        return out or {path: {}}
    return {path: value}


def load(path):
    data = json.load(open(path, encoding="utf-8-sig"))
    if "agents" not in data and "servers" not in data:
        # A read of before GET /ui/servers was in it: two such reads would compare equal on their servers, shape and
        # hub_shared, which neither holds.
        sys.exit(f"{path}: a read with no servers part (made before team-read.ps1 read GET /ui/servers): read again")
    return without_names(view_of_team(data) if "agents" in data else view_of_read(data))


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    reference, read = flat(load(argv[1])), flat(load(argv[2]))
    differences = [(k, reference.get(k, "(absent)"), read.get(k, "(absent)"))
                   for k in sorted(set(reference) | set(read)) if reference.get(k, "(absent)") != read.get(k, "(absent)")]
    for key, want, got in differences:
        print(f"{key}: the reference has {json.dumps(want)}, the read has {json.dumps(got)}")
    print(f"{len(differences)} differences in {len(set(reference) | set(read))} values, but for the names")
    return 1 if differences else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
