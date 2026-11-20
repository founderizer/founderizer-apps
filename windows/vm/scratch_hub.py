#!/usr/bin/env python3
"""A scratch hub on this Mac for the Windows app's store, reached from the build VM (README.md, "The store against a
scratch hub"). Development only: it serves app_decode.py's scratch hub (a temporary database and configuration, nothing
of the machine's), makes the VM a PC owner device with an open code (app_decode.windows_rows: its address is
127.0.0.1, where QEMU's user network brings the VM's calls from), adds the VM's name of this Mac, 10.0.2.2, to the hub's
names, and prints one JSON line: the hub's address as the VM reaches it, and the code.

Then it waits for words in the file "commands" in its folder (one each line), and logs each change it makes, with the
time, to "changes.log" there:
    need    a new open Needs-you item from the manager: the pane's count goes up
    quick   a new open item with no options of its own: "Done", "Not now" and "Tell me more" send at once
    ticks   a new open item whose three options combine (multi): he ticks some and sends them with "Send N"
    line    a new reply from the agent "vps": its row's line and time change
    marks   a reply from "vps" with the inline marks of Markdown: bold, italic, inline code and a link
    markdown  a reply from "vps" in Markdown: a heading, a list, inline code, a code block and a link
    result  Task 1 ends with its result accepted by the manager: what was done, how it was checked, and when
    outputs  Task 1's result names two checked outputs in a Git repository of the folder: a text file and a picture
            (picture.png of the folder when it is there, else a plain one); "View outputs" lists them
    nooutputs  Task 1's result names no checked output
    steps   Task 2's thread: its session on Claude Code, 8 steps (one failed, one changed a file), the agent's message
            and 2 steps more
    step    one more step at the end of Task 2's thread
    manysteps  120 steps more at the end of Task 2's thread, in its last run (a long run for the virtualized list)
    permission  Task 2 waits for a permission of the tool Bash, with its command
    park    the agent parks Task 2 until the next full hour (a reminder, and the live path that says so)
    thought, script, child, plan, cut  Task 2's thread gets a thought in a run, a Codex script that made a call, a child
            agent with three steps and its words, the plan of the work that runs with a step that runs, the record's cut
    error   Task 2's attempt ends with a call that never finished and an error; attempt 2 starts with two steps
    guidance  his guidance to Task 2, read by its agent
    long    90 rows more in Task 2's thread (a step and the agent's words, 45 times)
    subtasks  Task 2 belongs to a parent task, and has two subtasks
    failread / readok  each read of Task 2's record fails (503), or answers again
    ended400  400 ended tasks over the last six days: 3 failed, 60 runs of one schedule (about 11 a day), the rest
            done with a title of their own; the Ended lane counts them and opens them by day
    unchecked  two ended tasks of a few minutes ago: a result that waits for its check, and a canceled task (each says
            its state word in Ended's opened rest)
    slowchat  each read of a chat (GET /ui/mobile/chat/<agent>) answers 8 s late, so that its first read shows
    fastchat  the reads of a chat answer at once again
    code    a new code for the PC, in changes.log (the app keeps its key in memory, so each start needs one)
    settle  the helper confirms each hold that waits (a pause or a stop holds: state "stopped")
    two     the hub answers every open request but the two newest (for the taskbar's count from 2)
    quit    the hub stops, and its folder goes (the hub's own files are in it: app_decode.serve passes hub_files)

    python3 -I app/windows/vm/scratch_hub.py      (from the repository's root; run it in the background)
"""
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

root = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root))
os.chdir(root)
import app_decode  # noqa: E402
import hub  # noqa: E402

# The VM's firewall lets it reach this Mac at 10.0.2.2 only on the ports 58440 to 58459 (README.md, "The owner's
# private network"): the test channel has 58443, and the scratch hub takes the first free one of 58444 to 58459.
PORTS = range(58444, 58460)


class RangedServer(app_decode.Server):
    """app_decode's server, bound to the first free port of PORTS where app_decode asks for any port."""
    def __init__(self, address, handler, *args, **kwargs):
        if address[1] != 0:
            super().__init__(address, handler, *args, **kwargs)
            return
        for port in PORTS:
            try:
                super().__init__((address[0], port), handler, *args, **kwargs)
                return
            except OSError:
                continue
        raise OSError(f"no free port from {PORTS.start} to {PORTS.stop - 1} for the scratch hub")


app_decode.Server = RangedServer

folder = pathlib.Path(tempfile.mkdtemp(prefix="fz-scratch-hub-"))
address, generation = app_decode.serve(str(folder), False)
port = int(address.rsplit(":", 1)[1])
rows = app_decode.windows_rows(str(folder))
with hub.LOCK:
    hub.TEAM["hub"] = dict(hub.TEAM["hub"], extra_hosts=[f"10.0.2.2:{port}"])
print(json.dumps({"hub": f"http://10.0.2.2:{port}", "code": rows["FLEET_E2E_DEVICE_CODE"], "db": generation,
                  "folder": str(folder)}), flush=True)

log = folder / "changes.log"
commands = folder / "commands"
count = 0


def note(words):
    with open(log, "a") as f:
        f.write(f"{time.time():.3f} {words}\n")


def stamped(name, handler):
    """The hub's handler, with the moment it answered in changes.log: for the reading of the time from a wait's answer
    to the next reading of GET /ui/mobile, on this Mac's one clock."""
    def answer(self, *args, **kwargs):
        result = handler(self, *args, **kwargs)
        # An enrollment also names the kind of app that it sends (owner API 1.149): "windows" is a PC.
        kind = f", kind {self.form().get('kind')}" if name == "enroll" else ""
        # The list of a task's checked outputs, or one of its files.
        kind += ", one file" if kwargs.get("binary") else ""
        note(f"answered {name}{kind}")
        return result
    return answer


hub.Handler.ui_wait = stamped("wait", hub.Handler.ui_wait)
slow_chat = False
_chat = hub.Handler.ui_mobile_chat


def late_chat(self, agent, query):
    """A chat's read, 8 s late while the word slowchat holds: the PC's first read of it shows "Reading…"."""
    if slow_chat:
        time.sleep(8)
    return _chat(self, agent, query)


hub.Handler.ui_mobile_chat = late_chat
fail_read = False
_events = hub.Handler.ui_events


def failing_events(self, task_id, query):
    """A read of Task 2's record that fails while the word failread holds: the PC shows the read's failure."""
    if fail_read and task_id == "2":
        return self.json(503, {"error": "the record is not readable now"})
    return _events(self, task_id, query)


hub.Handler.ui_events = failing_events

CERTIFICATE = ("subject=CN = shop.example.com\nissuer=C = US, O = Example CA, CN = Example CA R3\n"
               "notBefore=Nov 13 10:58:04 2026 GMT\nnotAfter=Feb 11 10:58:03 2027 GMT\n")
SESSION = "1" * 8 + "-1111-4111-8111-" + "1" * 12


def plain_png(width=1208, height=680):
    """A picture with no library: a light green field under a grey bar, as the approved picture's colours."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\0" + (bytes((0xEF, 0xEF, 0xEF)) if y < 68 else bytes((0xDC, 0xEB, 0xD3))) * width
                    for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def outputs():
    """Task 1's checked outputs: a Git repository of the folder with the two files, which the hub reads them from."""
    repo = folder / "outputs-repo"
    files = repo / "outputs" / "T-1"
    files.mkdir(parents=True, exist_ok=True)
    (files / "certificate.txt").write_text(CERTIFICATE)
    picture = folder / "picture.png"
    (files / "shop-page.png").write_bytes(picture.read_bytes() if picture.exists() else plain_png())
    git = ["git", "-C", str(repo), "-c", "user.name=Example", "-c", "user.email=example@example.com",
           "-c", "commit.gpgsign=false"]
    subprocess.run(git + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "The example's outputs"], check=True)
    hub.CFG["artifact_repo"] = str(repo)
    hub.q("UPDATE tasks SET where_=? WHERE id=1", ("outputs/T-1/certificate.txt and outputs/T-1/shop-page.png",))


seq = 0


attempt = 1


def event(record, **data):
    """One record of Task 2's thread (thread_events), as a helper sends it, in its attempt now."""
    global seq
    seq += 1
    hub.ins("INSERT INTO thread_events(task,attempt,session,seq,ts,type,data,created) VALUES(2,?,?,?,?,?,?,?)",
            (attempt, SESSION[:-1] + str(attempt), seq, hub.now(), record, json.dumps(data), hub.now()))


def call(title, kind, status="completed", output="", changes=None, parent=None, subagent=None):
    data = dict(tool_call_id=f"call-{seq + 1}", title=title, kind=kind, status=status, output=output)
    if changes:
        data["changes"] = changes
    if parent:
        data["parent"] = parent
    if subagent:
        data["subagent"] = {"name": subagent}
    event("tool_call", **data)
    return data["tool_call_id"]


def steps():
    event("session", runtime="claude")
    call("Fetch https://help.example.com/api/tickets?status=open", "fetch", output="23 open tickets")
    call("Read knowledge/refund-policy.md", "read")
    call("Read knowledge/shipping-times.md", "read")
    call("Search tracking in replies", "search")
    call("python3 replies/make_reply.py 10482", "execute", "failed", "KeyError: 'tracking'")
    call("Edit replies/make_reply.py", "edit", changes=[dict(path="replies/make_reply.py", action="modify", added=4,
                                                             removed=1)])
    call("python3 replies/make_reply.py 10482", "execute")
    call("python3 replies/make_reply.py 10517", "execute")
    event("agent_message", text="I answered 23 tickets today. One customer asks for a refund outside the 30 days: "
                                "it is in Needs you.")
    call("Read replies/10517.json", "read")
    call("python3 replies/check_reply.py 10517", "execute")
hub.Handler.ui_mobile = stamped("mobile", hub.Handler.ui_mobile)
hub.Handler.ui_artifacts = stamped("artifacts", hub.Handler.ui_artifacts)
hub.Handler.ui_events = stamped("events", hub.Handler.ui_events)
hub.Handler.ui_owner_enroll = stamped("enroll", hub.Handler.ui_owner_enroll)


while True:
    if commands.exists():
        lines = commands.read_text().split()
        commands.unlink()
        for word in lines:
            count += 1
            if word == "need":
                hub.ins("INSERT INTO needs(title,why,todo,raised,by,options) VALUES(?,?,?,?,'manager',?)",
                        (f"Which day does the example ship? ({count})", "A change for the Windows app's proof.",
                         "Press one.", hub.now(), json.dumps(["Friday", "Monday"])))
                hub.changed("state")
                note("need")
            elif word == "quick":
                # A request with no options of its own: the app's three quick replies, which send at once.
                hub.ins("INSERT INTO needs(title,why,todo,raised,by,options) VALUES(?,?,?,?,'manager',?)",
                        (f"Is the example deploy done? ({count})", "A change for the Windows app's proof.",
                         "Say when it is done.", hub.now(), None))
                hub.changed("state")
                note("quick")
            elif word == "ticks":
                # A request whose options combine (multi): he ticks any of them and sends them with "Send N".
                hub.ins("INSERT INTO needs(title,why,todo,raised,by,options,multi) VALUES(?,?,?,?,'manager',?,1)",
                        (f"Which platforms get the example? ({count})", "A change for the Windows app's proof.",
                         "Tick any of them.", hub.now(), json.dumps(["On Windows", "On the Mac", "On iPhone"])))
                hub.changed("state")
                note("ticks")
            elif word == "line":
                hub.ins("INSERT INTO owner_reports(text,about,created,agent,in_reply_to) VALUES(?,?,?,?,?)",
                        (f"The example build passed its checks ({count}).", "", hub.now(), "vps", None))
                hub.changed("state")
                note("line")
            elif word == "marks":
                hub.ins("INSERT INTO owner_reports(text,about,created,agent,in_reply_to) VALUES(?,?,?,?,?)",
                        (f"The build **passed** its checks, *one* test was slow, and `make.py` is next: "
                         f"see [the notes](https://example.com/notes) ({count}).", "", hub.now(), "vps", None))
                hub.changed("state")
                note("marks")
            elif word == "markdown":
                hub.ins("INSERT INTO owner_reports(text,about,created,agent,in_reply_to) VALUES(?,?,?,?,?)",
                        ("### The example's backups\n\nAll three ran at 03:00.\n\n- **Database:** complete.\n"
                         "- **Files:** complete. The newest copy is `files.tar`.\n\nTo see them:\n\n"
                         f"```\nls -lh /backups\n```\n\nThe log is in [the report](https://example.com/report) ({count}).",
                         "", hub.now(), "vps", None))
                hub.changed("state")
                note("markdown")
            elif word == "result":
                hub.q("UPDATE tasks SET state='completed', what='Renewed the example certificate', how='Checked it', "
                      "delivered=?, accepted=1, checked_at=? WHERE id=1", (hub.now() - 60, hub.now()))
                hub.changed("state")
                note("result")
            elif word == "outputs":
                outputs()
                hub.changed("state")
                note("outputs")
            elif word == "nooutputs":
                hub.q("UPDATE tasks SET where_=? WHERE id=1", ("The certificate is on the shop's server.",))
                hub.changed("state")
                note("nooutputs")
            elif word == "steps":
                steps()
                hub.changed("state")
                note("steps")
            elif word == "step":
                call(f"python3 replies/make_reply.py {10600 + count}", "execute")
                hub.changed("state")
                note(f"step {seq}")
            elif word == "manysteps":
                for n in range(120):
                    call(f"python3 replies/make_reply.py {11000 + n}", "execute")
                hub.changed("state")
                note(f"manysteps {seq}")
            elif word == "thought":
                event("agent_thought", text="Two tickets ask where a parcel is. I read the shipping times first.")
                call("Read knowledge/shipping-times.md", "read", output="Standard: 2 to 4 days.")
                call("Fetch https://track.example.com/10482", "fetch", output="In transit")
                hub.changed("state")
                note("thought")
            elif word == "script":
                found = "Sources/Checkout/AddressFields.swift:41:    form.postcode = field.postcode"
                script = f"call-{seq + 1}"
                event("tool_call", tool_call_id=script, title='exec: text(await tools.exec_command({cmd:"rg -n postcode"}))',
                      kind="execute", status="in_progress")
                call("rg -n postcode Sources/Checkout", "execute", output=found)
                event("tool_call_update", tool_call_id=script, status="completed",
                      output="Script completed\nWall time 0.4 seconds\nOutput:\n" + found)
                hub.changed("state")
                note("script")
            elif word == "child":
                child = call("Agent", "other", output="Two parcels are late: 10482 (2 days) and 10517 (1 day).",
                             subagent="Check the tracking of late parcels")
                call("Read knowledge/shipping-times.md", "read", parent=child)
                call("Fetch https://track.example.com/10482", "fetch", parent=child)
                call("Fetch https://track.example.com/10517", "fetch", parent=child)
                event("agent_message", text="Two parcels are late: 10482 (2 days) and 10517 (1 day).", parent=child)
                hub.changed("state")
                note("child")
            elif word == "plan":
                call("python3 replies/make_reply.py 10531", "execute", status="in_progress")
                event("plan", entries=[{"content": "Read today's tickets", "status": "completed"},
                                       {"content": "Answer the shipping questions", "status": "in_progress"},
                                       {"content": "Write the refund case for Needs you", "status": "pending"}])
                hub.changed("state")
                note("plan")
            elif word == "cut":
                event("truncated")
                hub.changed("state")
                note("cut")
            elif word == "error":
                call("python3 replies/make_reply.py 10600", "execute", status="in_progress")
                event("error", message="The connection to the AI provider was lost: the program ended with code 1.")
                attempt = 2
                hub.q("INSERT OR IGNORE INTO attempts(task,attempt,created) VALUES(2,2,?)", (hub.now(),))
                hub.q("UPDATE tasks SET attempt=2, restarts=1 WHERE id=2")
                event("session", runtime="claude")
                call("python3 replies/make_reply.py 10600", "execute")
                call("python3 replies/make_reply.py 10601", "execute")
                hub.changed("state")
                note("error")
            elif word == "guidance":
                text = "Answer the refund ticket last: it waits for my decision in Needs you."
                eid = hub.ins("INSERT INTO events(agent,kind,task,text,created,read_at) VALUES('vps','steer',2,?,?,?)",
                              (text, hub.now(), hub.now() + 1))
                hub.ins("INSERT INTO steers(task,attempt,text,event_id,request_id,client,created) VALUES(2,?,?,?,?,?,?)",
                        (attempt, text, eid, f"00000000-0000-4000-8000-{count:012d}", "PC", hub.now()))
                hub.changed("state")
                note("guidance")
            elif word == "long":
                for n in range(45):
                    call(f"python3 replies/make_reply.py {12000 + n}", "execute")
                    event("agent_message", text=f"I answered ticket {12000 + n}.")
                hub.changed("state")
                note(f"long {seq}")
            elif word == "subtasks":
                row = hub.q1("SELECT * FROM tasks WHERE id=2")
                for tid, title, state, parent in ((7, "Get the example shop ready", "working", None),
                                                  (8, "Test the example checkout", "working", 2),
                                                  (9, "Tell the example customers", "submitted", 2)):
                    hub.q("INSERT OR REPLACE INTO tasks(id,title,details,done_when,needs,owner,requester,state,created,"
                          "attempt,parent) VALUES(?,?,'','done','none','vps','manager',?,?,1,?)",
                          (tid, title, state, row["created"], parent))
                hub.q("UPDATE tasks SET parent=7 WHERE id=2")
                hub.changed("state")
                note("subtasks")
            elif word == "ended400":
                t0 = hub.now()
                first = (hub.q1("SELECT MAX(id) m FROM tasks")["m"] or 0) + 1
                for n in range(400):
                    at = t0 - 600 - n * 1290          # 400 tasks over about six days, newest first
                    schedule = 99 if n % 6 == 0 and n < 360 else None
                    state = "failed" if n in (5, 17, 31) else "completed"
                    title = "Check the example queue" if schedule else f"Example ended task {n}"
                    hub.q("INSERT INTO tasks(id,title,details,done_when,needs,owner,requester,state,created,started,"
                          "last_activity,delivered,attempt,accepted,trigger_id) VALUES(?,?,'','done','none','vps',"
                          "'manager',?,?,?,?,?,1,?,?)",
                          (first + n, title, state, at - 300, at - 290, at, at, None if state == "failed" else 1,
                           schedule))
                hub.changed("state")
                note(f"ended400 {first} to {first + 399}")
            elif word == "unchecked":
                t0 = hub.now()
                first = (hub.q1("SELECT MAX(id) m FROM tasks")["m"] or 0) + 1
                for n, (title, state) in enumerate((("Draft the example reply", "completed"), ("Tag the example orders", "canceled"))):
                    at = t0 - 120 - n * 60
                    hub.q("INSERT INTO tasks(id,title,details,done_when,needs,owner,requester,state,created,started,"
                          "last_activity,delivered,attempt,accepted) VALUES(?,?,'','done','none','vps','manager',?,?,?,?,?,1,NULL)",
                          (first + n, title, state, at - 300, at - 290, at, at if state == "completed" else None))
                hub.changed("state")
                note(f"unchecked {first} and {first + 1}")
            elif word in ("failread", "readok"):
                fail_read = word == "failread"
                hub.changed("state")
                note(word)
            elif word == "permission":
                hub.ins("INSERT INTO prompts(task,agent,tool,input,key,created) VALUES(2,'vps','Bash',?,?,?)",
                        ("curl -s -X POST https://help.example.com/api/tickets/10517/reply -d @replies/10517.json",
                         f"bash-{count}", hub.now()))
                hub.changed("state")
                note("permission")
            elif word == "park":
                due = (int(hub.now()) // 3600 + 1) * 3600
                hub.ins("INSERT INTO reminders(due,note,agent,task,created) VALUES(?,?,'vps',2,?)",
                        (due, "Check the replies again", hub.now()))
                hub.q("UPDATE tasks SET live_path=? WHERE id=2", (hub.PARKED_PATH + hub.clock(due),))
                hub.changed("state")
                note(f"park {due}")
            elif word in ("slowchat", "fastchat"):
                slow_chat = word == "slowchat"
                note(word)
            elif word == "settle":
                held = hub.q("SELECT id FROM holds WHERE state='requested'")
                for row in held:
                    hub.q("UPDATE holds SET state='stopped', confirmed=? WHERE id=?", (hub.now(), row["id"]))
                hub.changed("state")
                note(f"settle {len(held)}")
            elif word == "two":
                keep = [r["id"] for r in hub.q("SELECT id FROM needs WHERE answered IS NULL ORDER BY id DESC LIMIT 2")]
                rest = hub.q("SELECT id FROM needs WHERE answered IS NULL")
                for row in rest:
                    if row["id"] not in keep:
                        hub.q("UPDATE needs SET answered=?, answer='Option A' WHERE id=?", (hub.now(), row["id"]))
                hub.changed("state")
                note(f"two {keep}")
            elif word == "code":
                note("code " + hub.new_device_code(app_decode.WINDOWS_DEVICE)["code"])
            elif word == "quit":
                note("quit")
                shutil.rmtree(folder, ignore_errors=True)
                sys.exit(0)
    time.sleep(0.2)
