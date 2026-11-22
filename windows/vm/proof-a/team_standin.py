#!/usr/bin/env python3
"""A stand-in of the hub's reads of team.sh, for a dry run of proof A with no hub (README.md of the folder above):
GET /ui/mobile, GET /ui/team and GET /ui/servers on 127.0.0.1, at port 58458 or the one given (the VM reaches this Mac only on
58440 to 58459). As the hub does for the owner's PC, it takes a call only with the Bearer key whose SHA-256 it was
given, and answers 403 to any other call and to a call with an Origin header. Its team is the team.json of its
argument, with the hub's live fields beside it (an address, a sign-in, a key's view, a login, an account), so that a
read shows that it leaves them out. It logs each request's method, path and whether the key was taken to requests.log
in its folder, never a header; the word "quit" in the file "commands" there ends it.

    python3 -I team_standin.py <team.json> <folder> [port] < digest   (one line: the digest that standin-key.ps1 printed;
                                                                    the port that its key names, 58458 when none)
"""
import hashlib
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from team_compare import view_of_team  # noqa: E402

DB = "standin-db-1"


def answer(team):
    view = view_of_team(team)
    addresses = team.get("addresses") or {}
    lines = []
    for line in view["lines"]:
        lines.append(dict({k: v for k, v in line.items() if k != "shared_with"},
                          settings_pending=False, web_hosts=[], reported_model={"model": "example-model", "effort": None, "at": 1},
                          placement={"machine": line["machine"], "runtime": line["runtime"],
                                     "address": addresses.get(line["machine"]), "shared_with": line["shared_with"]},
                          auth={"kind": "example", "fingerprint": "example-not-a-key"}, account=None))
    machines = {name: {"address": addresses.get(name), "agents": m["agents"], "ssh": m["ssh"], "worker_user": "fleet-example",
                       "runtimes": {"codex": {"version": "0.0.0-example", "signed_in": True}},
                       "add_agent": {"ready": False, "missing": ["shared_os_user"]}}
                for name, m in view["machines"].items()}
    return {"db": DB, "revision": "0" * 40, "sha256": hashlib.sha256(json.dumps(team).encode()).hexdigest(),
            "lines": lines, "open_tasks": {}, "accounts": {"example": {"title": "An example account"}},
            "logins": {"bws://00000000-0000-0000-0000-000000000000": {"title": "An example login"}},
            "created_logins": [], "machines": machines}


def servers_answer(team):
    view = view_of_team(team)
    addresses = team.get("addresses") or {}
    rows = [{"name": name, "kind": "linux", "address": addresses.get(name), "user": "fleet-example", "hub": s["hub"],
             "joined": True, "agents": s["agents"], "reading": {"stale": False, "runtimes": {"codex": {"signed_in": True}}},
             "available": False, "why": ["has_agent"], "job": None, "access": {"ssh": s["ssh"]}}
            for name, s in view["servers"].items()]
    return {"db": DB, "desired_revision": "0" * 40, "servers": rows, "apps": [], "hub_shared": view["hub_shared"],
            "shape": {"step": view["shape"]} if view["shape"] else None, "model_providers": [], "join": None}


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    team = json.load(open(sys.argv[1], encoding="utf-8"))
    folder = sys.argv[2]
    os.makedirs(folder, exist_ok=True)
    digest = sys.stdin.readline().strip()
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        sys.exit("give the key's SHA-256 (64 small hex letters) on standard input")
    log = open(os.path.join(folder, "requests.log"), "a", buffering=1)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send_json(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            url = urlparse(self.path)
            given = self.headers.get("Authorization", "")
            taken = given.startswith("Bearer ") and hashlib.sha256(given[7:].encode()).hexdigest() == digest
            log.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\tGET\t{url.path}\t"
                      f"{'key taken' if taken else 'refused'}\n")
            if self.headers.get("Origin") or not taken:
                return self.send_json(403, {"error": "this is not the key of the owner's computer", "auth": "owner_key_mismatch"})
            if url.path == "/ui/mobile":
                return self.send_json(200, {"db": DB, "agents": [], "tasks": []})
            if url.path == "/ui/team":
                if parse_qs(url.query).get("db") != [DB]:
                    return self.send_json(409, {"error": "hub generation changed; refresh state"})
                return self.send_json(200, answer(team))
            if url.path == "/ui/servers":
                if parse_qs(url.query).get("db") != [DB]:
                    return self.send_json(409, {"error": "hub generation changed; refresh state"})
                return self.send_json(200, servers_answer(team))
            return self.send_json(404, {"error": "not found"})

    port = int(sys.argv[3]) if len(sys.argv) == 4 else 58458
    if not 58440 <= port <= 58459 or not free(port):
        sys.exit(f"port {port} is not a free test port of the VM (58440 to 58459)")
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"team stand-in on 127.0.0.1:{port}; the VM reaches it at http://10.0.2.2:{port}", flush=True)
    commands = os.path.join(folder, "commands")
    while True:
        time.sleep(1)
        if os.path.exists(commands) and "quit" in open(commands).read():
            server.shutdown()
            return


def free(port):
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) != 0


if __name__ == "__main__":
    main()
