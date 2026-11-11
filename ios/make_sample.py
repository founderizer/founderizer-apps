#!/usr/bin/env python3
"""Makes the iPhone app's sample fleet, `Sources/SampleFleetData.swift`, from the hub's own code.

    python3 -B app/ios/make_sample.py

The sample is a made-up company's fleet (five agents, two requests, three open tasks and three that ended), which a
phone with no hub can look at: what a new owner sees before their fleet exists, and what App Review uses (guideline
2.1 asks for a demo, 4.2.3 for an app that works on its own). The hub's own routes answer the phone's reads here, on
loopback, from a temporary database, so the sample is exactly what a hub says. Run it again when the phone's routes
change: the Swift file is its only output, and nothing here reaches a fleet.

Every time in the output is relative to the moment the phone opens the sample: "@-480" is eight minutes before it.
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, ROOT)
import hub              # noqa: E402
import ui_fixture as uf     # noqa: E402

OUT = os.path.join(HERE, "Sources", "SampleFleetData.swift")
DATABASE = "sample"
# What a sample does not do: wait on changes, ask for pings, or take a recovery copy. Each would call the network.
NOT_IN_SAMPLE = {"push", "sealed_push", "live_changes", "recovery_copy"}

TEAM = json.loads(json.dumps(uf.TEAM))
TEAM["agents"] = {
    "manager": {"role": "manager", "title": "Fleet Manager", "runtime": "claude", "machine": "hub", "can": []},
    "wren": {"role": "worker", "title": "Customer Support", "runtime": "claude", "machine": "vps",
             "can": ["shell", "web"]},
    "theo": {"role": "worker", "title": "Developer", "runtime": "codex", "machine": "vps", "can": ["shell", "web"]},
    "pax": {"role": "worker", "title": "DevOps", "runtime": "codex", "machine": "mac-mini", "can": ["shell"]},
    "orla": {"role": "worker", "title": "Marketing", "runtime": "claude", "machine": "mac-studio",
             "can": ["shell", "web", "browser"]},
}
TEAM["chat_apps"] = {}
uf.TEAM = TEAM


class Sample(uf.Fixture):
    """The fixture's real hub with the sample's own team and words. No timer runs, so no task goes quiet."""

    def __init__(self):
        try:
            super().__init__(0, False)
        except BaseException:       # a seed that fails leaves no temporary folder behind
            if getattr(self, "tmp", None):
                shutil.rmtree(self.tmp, ignore_errors=True)
            raise

    def private_kit(self):
        def git(*args, cwd=None):
            subprocess.run(["git", "-c", "user.name=sample", "-c", "user.email=sample@invalid", "-c",
                            "init.defaultBranch=main", "-c", "commit.gpgsign=false", *args],
                           cwd=cwd, check=True, capture_output=True)
        seed = os.path.join(self.tmp, "seed")
        os.makedirs(os.path.join(seed, "profiles"))
        with open(os.path.join(seed, "team.json"), "w") as f:
            json.dump(TEAM, f, indent=2)
        for agent in TEAM["agents"]:        # made-up profiles only: never one of the repository's
            with open(os.path.join(seed, "profiles", agent + ".md"), "w") as f:
                f.write(hub.render_profile(agent, [
                    {"key": "character", "title": "Character", "text": "Calm and brief."},
                    {"key": "responsible_for", "title": "Responsible for", "text": TEAM["agents"][agent]["title"]},
                    {"key": "may_do", "title": "May do without asking", "text": "Its own work."},
                    {"key": "must_ask", "title": "Must ask first", "text": "Money and anything public."}]))
        git("init", "-q", seed)
        git("add", "-A", cwd=seed)
        git("commit", "-q", "-m", "sample seed", cwd=seed)
        git("clone", "-q", "--bare", seed, os.path.join(self.tmp, "origin.git"))
        git("clone", "-q", os.path.join(self.tmp, "origin.git"), os.path.join(self.tmp, "kit"))
        return os.path.join(self.tmp, "kit", "team.json")

    def heartbeat(self):
        open_tasks = {r["id"]: r["owner"] for r in hub.q(
            "SELECT id, owner FROM tasks WHERE state NOT IN ('completed','failed','rejected','canceled')")}
        for agent in TEAM["agents"]:
            windows = ["manager"] if agent == "manager" else [
                f"T-{tid}" for tid, owner in open_tasks.items() if owner == agent]
            hub.know(agent)
            hub.q("UPDATE agents SET last_seen=?, alive=?, alive_ts=?, client=COALESCE(client,'sample'), "
                  "client_seen=? WHERE name=?", (hub.now(), ",".join(windows), hub.now(), hub.now(), agent))
        hub.q("UPDATE events SET read_at=? WHERE agent='manager' AND kind='say' AND read_at IS NULL", (hub.now(),))

    def tool(self, agent, name, args, context=None):
        text, error = hub.call_tool(agent, name, args, context)
        if error:
            raise RuntimeError(f"{agent} {name}: {text}")
        return text

    def request_id(self):
        """A request number that is the same at every run, so that the output changes only when the sample does."""
        self.requests = getattr(self, "requests", 0) + 1
        return str(uuid.UUID(int=self.requests))

    def worker_says(self, agent, text, at):
        self.tool(agent, "message_owner", {"request_id": self.request_id(), "text": text}, (self.db, "owner-chat", "1"))
        report = hub.q1("SELECT MAX(id) AS id FROM owner_reports")["id"]
        hub.q("UPDATE owner_reports SET created=? WHERE id=?", (at, report))

    def task_at(self, owner, title, done_when, details, created, active):
        """A task with its own words and times: asked at `created`, started a minute later, last busy at `active`."""
        tid = self.task(owner, title, done_when)
        hub.q("UPDATE tasks SET details=?, created=?, started=?, last_activity=? WHERE id=?",
              (details, created, created + 60, active, tid))
        hub.q("UPDATE notes SET ts=? WHERE task=?", (created + 120, tid))
        return tid

    def ended(self, owner, title, done_when, details, what, ended):
        tid = self.task_at(owner, title, done_when, details, ended - 2 * 3600, ended)
        hub.q("UPDATE tasks SET state='completed', outcome='completed', what=?, where_='outputs/', how='Checked it', "
              "delivered=?, accepted=1, checked_at=? WHERE id=?", (what, ended, ended + 60, tid))
        return tid

    def seed(self, manager_limited):
        now = hub.now()
        self.heartbeat()
        self.task_at("wren", "Answer today's support tickets", "every ticket of today has an answer",
                     "Answer every support ticket that came in today.", now - 3 * 3600, now - 6 * 60)
        self.task_at("theo", "Fix the checkout error on iPhone", "a test order goes through on an iPhone",
                     "Some orders fail at checkout on iPhone. Find the cause, fix it and test it.",
                     now - 150 * 60, now - 12 * 60)
        email = self.task_at("orla", "Write the spring sale email", "the email is approved and scheduled",
                             "Write the email for the spring sale. It goes out once it is approved.",
                             now - 3600, now - 26 * 60)
        self.ended("pax", "Renew the shop's certificate", "the certificate is valid for 90 days",
                   "The shop's certificate ends this week. Renew it.", "Renewed the certificate", now - 3 * 3600)
        self.ended("pax", "Check last night's backups", "one restore is tested",
                   "Check that last night's backups ran, and test one restore.", "Tested one restore",
                   now - 5 * 3600)
        self.ended("orla", "Post the new arrivals", "the post is live", "Post this week's new arrivals.",
                   "Posted the new arrivals", now - 20 * 3600)
        hub.ins("INSERT INTO needs(title,why,todo,raised,by,options) VALUES(?,?,?,?,'manager',?)",
                ("Refund an order from 45 days ago?",
                 "A customer asks for a refund 15 days after the 30-day window.",
                 "Press one, or write what you want instead.", now - 40 * 60,
                 json.dumps(["Refund it", "Offer a 20% voucher", "Say no, politely"])))
        approve = hub.ins("INSERT INTO needs(title,why,todo,raised,by,options) VALUES(?,?,?,?,'manager',?)",
                          ("Send the spring sale email on Monday?",
                           "Marketing finished the email. It goes to 4,800 subscribers.",
                           "Press one, or write what you want instead.", now - 25 * 60,
                           json.dumps(["Send it on Monday", "Show me the email first"])))
        hub.q("UPDATE tasks SET waiting_on=? WHERE id=?", (f"N-{approve}", email))
        self.worker_says("orla", "The spring sale email is ready. I wrote two subject lines, and I test them on 10% "
                         "of the list first.", now - 26 * 60)
        self.worker_says("pax", "Backups ran at 03:00 and I tested one restore. The shop server uses 41% of its "
                         "disk.", now - 3 * 3600)
        self.worker_says("theo", "I found the checkout error: Safari on iPhone sent the postcode twice. I test the "
                         "fix with three cards before it goes live.", now - 2 * 3600)
        self.worker_says("wren", "I answered 23 tickets today. One customer asks for a refund outside the 30 days: "
                         "it is in Needs you.", now - 41 * 60)
        rid = self.request_id()
        with hub.LOCK, hub.transaction():
            hub.owner_message_rows(rid, "message", None, "Can we start the spring sale on Monday?", "iPhone",
                                   "manager", None, now - 9 * 60)
        self.tool("manager", "read_messages", {})
        hub.q("UPDATE events SET read_at=? WHERE agent='manager' AND kind='say'", (now - 9 * 60 + 20,))
        self.tool("manager", "tell_owner", {
            "text": "Yes. Marketing has the email ready, and Developer puts the sale banner live on Sunday night. "
                    "The email waits for your yes in Needs you.", "in_reply_to": rid})
        report = hub.q1("SELECT MAX(id) AS id FROM owner_reports")["id"]
        hub.q("UPDATE owner_reports SET created=? WHERE id=?", (now - 8 * 60, report))
        self.heartbeat()        # again, now that the tasks exist: each worker is alive in its task's window
        return {}


def read(base, route):
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(base + route, timeout=10) as answer:
        return json.load(answer)


def relative(value, now, generation):
    """Every time becomes "@<whole seconds before now>" ("@i<seconds>" for a time that is a whole number, which
    stays one), and the generation becomes the sample's own name. No time is after the sample's moment."""
    if isinstance(value, dict):
        return {k: relative(v, now, generation) for k, v in value.items()}
    if isinstance(value, list):
        return [relative(v, now, generation) for v in value]
    if isinstance(value, str):
        if value == generation:
            return DATABASE
        if value.startswith("@"):
            raise ValueError(f"a word of the sample starts with @: {value!r}")
        return value
    if isinstance(value, int) and not isinstance(value, bool) and abs(value - now) < 400 * 86400:
        return f"@i{min(0, value - int(now))}"
    if isinstance(value, float) and abs(value - now) < 400 * 86400:
        return f"@{min(0, int(round(value - now)))}"
    return value


def main():
    # The hub's clock stands still at one whole second while the sample is made, so that every time is a whole number
    # of seconds before it and two runs write the same file.
    moment = float(int(time.time()))
    hub.now = lambda: moment
    sample = Sample()
    try:
        mobile = read(sample.base, "/ui/mobile")
        mobile["ui_features"] = [f for f in mobile.get("ui_features") or [] if f not in NOT_IN_SAMPLE]
        mobile.pop("token", None)       # the change token is for live_changes, which the sample does not do
        mobile["time"] = moment
        chats = {a["name"]: read(sample.base, f"/ui/mobile/chat/{a['name']}") for a in mobile["agents"]}
        ids = sorted({t["id"] for t in (mobile.get("tasks") or []) + (mobile.get("recent") or [])})
        tasks = {str(i): read(sample.base, f"/ui/mobile/task/{i}") for i in ids}
        data = relative({"mobile": mobile, "chats": chats, "tasks": tasks}, moment, sample.db)
    finally:
        sample.close()
    text = json.dumps(data, indent=1, ensure_ascii=False, sort_keys=True)
    if '"""#' in text:
        raise ValueError("the sample cannot stand in a Swift raw string")
    with open(OUT, "w") as f:
        f.write("// Made by app/ios/make_sample.py from the hub's own code: run it again, do not edit this file.\n"
                "// The sample fleet's reads as a hub answers them (SampleFleet.swift). \"@-480\" is a time eight\n"
                "// minutes before the phone opened the sample.\n\n"
                "enum SampleFleetData {\n"
                "    static let json = #\"\"\"\n" + text + "\n\"\"\"#\n}\n")
    print(json.dumps({"agents": len(mobile["agents"]), "needs": len(mobile.get("needs") or []), "tasks": len(ids),
                      "features": data["mobile"]["ui_features"], "bytes": os.path.getsize(OUT)}))


if __name__ == "__main__":
    main()
