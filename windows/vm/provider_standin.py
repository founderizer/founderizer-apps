#!/usr/bin/env python3
"""A stand-in of Tailscale's API and of Hetzner's API on this Mac, for the proofs of the first run's servers in the build
VM (piece U2 of windows-app-plan-v2.md; README.md, "The first run's servers against stand-ins").

A proofs' build of the window with FOUNDERIZER_PROVIDERS=http://10.0.2.2:<port> sends every request of a provider here
(Fleet/ProviderStandIn.cs), with the host it was written for in X-Founderizer-Host. The answers are those of the
library's own vector files (app/vectors/tailscale-requests.json and cloud-requests.json, which the Mac's code writes):
a Tailscale policy that the app may write, a fleet key, a join key for each server; a Hetzner token that may write, the
prices of its primary addresses, an account with no server, the app's SSH key registered, a firewall, and each server
made. The server types are the example data of picture set 8 (CX23 at 5.99 a month, CPX22 at 7.99), not a vector's. No
request leaves this Mac, and no token, key or code of a person reaches this program: the tokens of a proof are made for
the proof, and are no one's.

Words in the file "commands" of its folder change it while it runs, one word a line:
  hold     the next server waits at "Making your server" until "go" (the build at work)
  go       it is made
  refuse   each server of an agent is refused: Hetzner has no server free now (the owner's turn)
  take     servers of agents are made again
  quit     the stand-in ends

It writes each request (its method, its host and its path; no header and no body) and each change to "requests.log",
and the public line of the app's own SSH key that Hetzner was given to "app-key.pub", which the proof puts on the
container of the server it stands for. Run it from the repository's root, in the background:

    python3 -I app/windows/vm/provider_standin.py > standin.out &
"""
import base64
import hashlib
import http.server
import json
import pathlib
import sys
import tempfile
import threading
import time

root = pathlib.Path(__file__).resolve().parents[3]
vectors = root / "app" / "vectors"
tailscale = json.loads((vectors / "tailscale-requests.json").read_text(encoding="utf-8"))
cloud = json.loads((vectors / "cloud-requests.json").read_text(encoding="utf-8"))


def answers(cases, name):
    case = next(c for c in cases["cases"] if c["name"] == name)
    return {(a["method"], a["path"]): a for a in case["answers"] if a["status"] > 0}


policy = answers(tailscale, "A file that lets everything through gets the tag alone, and the key is made")
mint = answers(tailscale, "One key for one machine, for an hour")
offers = answers(cloud, "Hetzner: every type that fits a hub, cheapest first and nearest at one price")
token_check = answers(cloud, "Hetzner: a token that may write is kept")


def server_type(name, cores, memory, disk, gross):
    """A type of the example data of picture set 8: with the vector's primary addresses (0.5950 and 0.4998 a month at
    Falkenstein and Nuremberg), CX23 costs 5.99 a month and CPX22 7.99, as the pictures say."""
    places = ["fsn1", "nbg1"]
    return {"id": 100 + cores, "name": name, "cores": cores, "memory": memory, "disk": disk, "cpu_type": "shared",
            "architecture": "x86", "deprecation": None,
            "prices": [{"location": p, "price_monthly": {"net": "%.4f" % (gross / 1.19), "gross": "%.4f" % gross}} for p in places],
            "locations": [{"id": i + 1, "name": p, "deprecation": None, "available": True} for i, p in enumerate(places)]}


TYPES = [server_type("cx23", 2, 4.0, 40, 4.8952), server_type("cpx22", 3, 4.0, 80, 6.8952), server_type("cx33", 4, 8.0, 80, 7.6952)]

folder = pathlib.Path(tempfile.mkdtemp(prefix="founderizer-provider-standin-"))
(folder / "commands").write_text("", encoding="utf-8")
log = folder / "requests.log"
state = {"hold": False, "refuse": False, "keys": [], "servers": 0, "lock": threading.Lock()}


def note(line):
    with state["lock"]:
        with log.open("a", encoding="utf-8") as file:
            file.write(time.strftime("%H:%M:%S ") + line + "\n")


def commands():
    words = (folder / "commands").read_text(encoding="utf-8").split()
    (folder / "commands").write_text("", encoding="utf-8")
    for word in words:
        if word == "hold":
            state["hold"] = True
        elif word == "go":
            state["hold"] = False
        elif word == "refuse":
            state["refuse"] = True
        elif word == "take":
            state["refuse"] = False
        elif word == "quit":
            note("quit")
            threading.Thread(target=server.shutdown, daemon=True).start()
        if word:
            note("command " + word)


def fingerprint(line):
    blob = base64.b64decode(line.split()[1])
    digest = hashlib.md5(blob).hexdigest()
    return ":".join(digest[i:i + 2] for i in range(0, 32, 2))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def answer(self, status, body, headers=None):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def given(self, table, method, path):
        found = table.get((method, path))
        if found is None:
            return self.answer(404, '{"error":{"code":"not_found","message":"not found"}}')
        return self.answer(found["status"], found["body"], found.get("headers") or {})

    def handle_one(self, method):
        commands()
        host = self.headers.get("X-Founderizer-Host", "")
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        note(f"{method} {host} {path}")
        if host == "api.tailscale.com":
            if (method, path) == ("POST", "/api/v2/tailnet/-/keys"):
                asked = json.loads(body or b"{}")
                return self.given(mint if "capabilities" in asked else policy, method, path)
            if path == "/api/v2/oauth/token":
                return self.given(mint, method, path)
            if path == "/api/v2/tailnet/-/devices":
                return self.answer(200, '{"devices":[]}')
            return self.given(policy, method, path)
        if host == "api.hetzner.cloud":
            return self.hetzner(method, path, body)
        return self.answer(404, "{}")

    def hetzner(self, method, path, body):
        if path == "/v1/locations":
            return self.given(token_check, method, path)
        if path == "/v1/ssh_keys" and method == "GET":
            wanted = self.path.split("fingerprint=")[-1] if "fingerprint=" in self.path else None
            keys = [k for k in state["keys"] if wanted is None or k["fingerprint"] == wanted]
            return self.answer(200, json.dumps({"ssh_keys": keys, "meta": {"pagination": {"page": 1}}}))
        if path == "/v1/ssh_keys" and method == "POST":
            asked = json.loads(body or b"{}")
            if "public_key" not in asked:
                return self.given(token_check, method, path)
            line = asked["public_key"]
            (folder / "app-key.pub").write_text(line + "\n", encoding="utf-8")
            key = {"id": 43 + len(state["keys"]), "name": asked.get("name", ""), "fingerprint": fingerprint(line),
                   "public_key": line, "labels": asked.get("labels", {})}
            state["keys"].append(key)
            note("the app's key: " + key["fingerprint"])
            return self.answer(201, json.dumps({"ssh_key": key}))
        if path == "/v1/pricing":
            return self.given(offers, "GET", path)
        if path == "/v1/server_types":
            return self.answer(200, json.dumps({"server_types": TYPES, "meta": {"pagination": {"page": 1}}}))
        if path == "/v1/servers" and method == "GET":
            return self.answer(200, '{"servers":[],"meta":{"pagination":{"page":1,"next_page":null}}}')
        if path == "/v1/firewalls" and method == "POST":
            return self.answer(201, '{"firewall":{"id":77,"name":"x","rules":[]},"actions":[]}')
        if path.startswith("/v1/firewalls/") and method == "DELETE":
            return self.answer(204, "")
        if path == "/v1/servers" and method == "POST":
            asked = json.loads(body or b"{}")
            use = asked.get("labels", {}).get("founderizer", "")
            if use == "agent" and state["refuse"]:
                note("refused a server of an agent")
                return self.answer(422, '{"error":{"code":"placement_error","message":"no capacity"}}')
            while state["hold"]:
                time.sleep(1)
                commands()
            state["servers"] += 1
            made = {"id": 1000 + state["servers"], "name": asked.get("name", ""), "status": "initializing",
                    "public_net": {"ipv4": {"id": 5, "ip": "203.0.113.%d" % (9 + state["servers"])}, "ipv6": None}}
            note("made " + made["name"] + " for " + use)
            return self.answer(201, json.dumps({"server": made, "action": {"id": 500 + state["servers"], "command": "create_server",
                                                                           "status": "running", "error": None}}))
        if path.startswith("/v1/actions/"):
            number = path.rsplit("/", 1)[-1]
            return self.answer(200, '{"action":{"id":%s,"status":"success","error":null}}' % number)
        return self.answer(404, '{"error":{"code":"not_found","message":"not found"}}')

    def do_GET(self):
        self.handle_one("GET")

    def do_POST(self):
        self.handle_one("POST")

    def do_DELETE(self):
        self.handle_one("DELETE")


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


# The VM reaches this Mac at 10.0.2.2 only on the ports 58440 to 58459 (README.md, "The owner's private network"): the
# stand-in takes the first free one from the top, where the scratch hub takes them from 58444 up.
server = None
for port in range(58459, 58443, -1):
    try:
        server = Server(("127.0.0.1", port), Handler)
        break
    except OSError:
        continue
if server is None:
    raise SystemExit("no free port from 58444 to 58459 for the stand-in")
print(f"folder {folder}")
print(f"FOUNDERIZER_PROVIDERS=http://10.0.2.2:{port}")
sys.stdout.flush()
server.serve_forever()
