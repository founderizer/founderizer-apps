#!/usr/bin/env python3
"""Local agent-setup preview. Synthetic data only; no fleet, credentials or AI."""
import hashlib
import json
import os
import time
import uuid
from http.server import HTTPServer
from urllib.parse import urlsplit
from fault_hub import FaultHandler


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


class SetupHandler(FaultHandler):
    def do_GET(self):
        if not self.allowed():
            return
        path = urlsplit(self.path).path
        data = self.server.data
        now = time.time()
        common = dict(db=data["db"], revision=data["revision"])
        if path == "/ui/state":
            agents = [dict(name=row["agent"], runtime="codex", last_seen=now, **{
                k: row[k] for k in ("role", "reports_to", "active", "can")}) for row in data["lines"]]
            result = dict(schema_version=1, time=now, db=data["db"],
                manager_flag="LOCAL SETUP TEST · synthetic data · no agents run",
                ui_features=["profiles", "reporting_lines", "agent_setup", "machines", "machine_check", "direct_chat"],
                agents=agents, tasks=[], notes=[], needs=[], permissions=[], reports=[], messages=[],
                knowledge=[dict(path="knowledge/sample.md", title="Sample guide", text="Synthetic context", commit=data["revision"])])
        elif path == "/ui/team":
            result = dict(**common, sha256=digest(data["lines"]), lines=data["lines"], open_tasks={})
        elif path == "/ui/profiles":
            result = dict(**common, profiles=[dict(agent="sample", path="profiles/sample.md", text="Synthetic profile",
                sha256=digest(data["sections"]), sections=data["sections"])])
        elif path == "/ui/machines":
            pending = now < data["settings_due"]
            row = data["lines"][1]
            machine = dict(agent="sample", machine="Local preview", role="worker", reported_at=now,
                revision=data["revision"], stale=False, update=dict(state="waiting_idle" if pending else "current"),
                settings_pending=pending, settings={k: row[k] for k in ("model", "effort", "can")},
                runtime=dict(name="codex", version="Synthetic runtime", signed_in=True), security={}, os=dict(name="Synthetic Linux"),
                models=dict(runtime="codex", ok=True, read_at=now, source="Synthetic options", other_names=False,
                    options=[dict(model="sample-model", display_name="Sample model", default=True, efforts=["low", "high", "ultra"], default_effort="high")]),
                check=data["check"], verify=data["verify"])
            result = dict(db=data["db"], desired_revision=data["revision"], machines=[machine])
        elif path == "/test/summary":
            result = dict(db=data["db"], requests=data["requests"], active=data["lines"][1]["active"], ai_dispatches=0)
        else:
            return self.json_response(404, dict(error="Unknown preview route"))
        self.json_response(200, result)

    def do_POST(self):
        if not self.allowed():
            return
        data = self.server.data
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= 65536:
                raise ValueError()
            body = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeDecodeError):
            return self.json_response(400, dict(error="Invalid preview request"))
        if self.path == "/test/pass-login" and self.headers.get("X-Fleet-Harness-Control") == "test-only":
            data["login_ok"] = True
            return self.json_response(200, dict(ok=True))
        client = self.headers.get("X-Fleet-Client")
        if body.get("db") != data["db"] or not client:
            return self.json_response(409, dict(error="Preview identity mismatch"))
        request_id = body.get("request_id")
        if request_id in data["receipts"]:
            return self.json_response(200, dict(data["receipts"][request_id], replayed=True))
        receipt = dict(ok=True, request_id=request_id, client=client, replayed=False, agent="sample")
        if self.path == "/ui/machines/sample/check":
            now = time.time()
            check_id = 1 if data["check"] is None else data["check"]["id"] + 1
            receipt["check"] = dict(id=check_id, state="requested", requested_at=now)
            data["check"] = dict(id=check_id, state="completed", requested_at=now, completed_at=now)
            data["verify"] = dict(check=check_id, checked_at=now, revision=data["revision"], items=[
                dict(kind="runtime", ref="codex", state="ok", detail="Synthetic runtime is ready.", required=True),
                dict(kind="login", ref="Sample login", state="ok" if data["login_ok"] else "failed",
                     detail="readable" if data["login_ok"] else "no_access", required=True),
                dict(kind="capability", ref="web", state="not_verified", detail="Requires a real session.", required=False)])
        elif self.path in ("/ui/team/agents/sample", "/ui/profiles/sample", "/ui/team/lines"):
            is_profile = self.path == "/ui/profiles/sample"
            if body.get("base_sha256") != digest(data["sections"] if is_profile else data["lines"]):
                return self.json_response(409, dict(error="Saved settings changed"))
            if is_profile:
                data["sections"] = body["sections"]
                receipt.update(sha256=digest(data["sections"]), unchanged=False)
            else:
                changes = []
                if self.path == "/ui/team/lines":
                    for row, new in zip(data["lines"], body["lines"]):
                        row.update({k: new[k] for k in ("role", "reports_to")})
                else:
                    row = data["lines"][1]
                    if body.get("active") and (data["verify"] is None or not data["login_ok"] or time.time() < data["settings_due"]):
                        return self.json_response(409, dict(error="Required checks have not passed"))
                    for key in ("active", "model", "effort", "can"):
                        if key in body and body[key] != row[key]:
                            changes.append(dict(field=key, before=row[key], after=body[key]))
                            row[key] = body[key]
                    settings_change = any(c["field"] != "active" for c in changes)
                    if settings_change:
                        data["settings_due"] = time.time() + 8
                    receipt.update(updates_requested=["sample"] if settings_change else [], settings_pending=settings_change,
                        activation={k: data["verify"][k] for k in ("check", "checked_at")} if body.get("active") and changes else None)
                receipt.update(sha256=digest(data["lines"]), changed=changes)
            data["revision"] = hashlib.sha1(str(uuid.uuid4()).encode()).hexdigest()
            receipt.update(revision=data["revision"], commit=data["revision"])
        else:
            return self.json_response(404, dict(error="Unsupported preview write"))
        data["requests"].append(self.path)
        data["receipts"][request_id] = receipt
        self.json_response(200, receipt)


if __name__ == "__main__":
    with HTTPServer(("127.0.0.1", 0), SetupHandler) as server:
        server.data = dict(db="synthetic-setup-" + str(uuid.uuid4()), revision="b" * 40,
            lines=[dict(agent="manager", role="manager", reports_to=None, active=True, model=None, effort=None, can=["shell"]),
                   dict(agent="sample", role="worker", reports_to="manager", active=False, model=None, effort=None, can=["shell", "web"])],
            sections=[dict(key=key, title=title, text=text) for key, title, text in [
                ("character", "Character", "Short and clear."), ("responsible_for", "Responsible for", "Read synthetic data."),
                ("may_do", "May do without asking", "Read local test files."), ("must_ask", "Must ask first", "Ask before external changes.")]],
            settings_due=0, check=None, verify=None, login_ok=False, requests=[], receipts={})
        print(json.dumps(dict(pid=os.getpid(), app_url=f"http://localhost:{server.server_port}", db=server.data["db"])), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
