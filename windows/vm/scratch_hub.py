#!/usr/bin/env python3
"""A scratch hub on this Mac for the Windows app's store, reached from the build VM (README.md, "The store against a
scratch hub"). Development only: it serves app_decode.py's scratch hub (a temporary database and configuration, nothing
of the machine's), makes the VM a PC owner device with an open code (app_decode.windows_rows: its address is
127.0.0.1, where QEMU's user network brings the VM's calls from), adds the VM's name of this Mac, 10.0.2.2, to the hub's
names, and prints one JSON line: the hub's address as the VM reaches it, and the code.

Then it waits for words in the file "commands" in its folder (one each line), and logs each change it makes, with the
time, to "changes.log" there:
    need    a new open Needs-you item from the manager: the pane's count goes up
    line    a new reply from the agent "vps": its row's line and time change
    code    a new code for the PC, in changes.log (the app keeps its key in memory, so each start needs one)
    settle  the helper confirms each hold that waits (a pause or a stop holds: state "stopped")
    two     the hub answers every open request but the two newest (for the taskbar's count from 2)
    quit    the hub stops

    python3 -I app/windows/vm/scratch_hub.py      (from the repository's root; run it in the background)
"""
import json
import os
import pathlib
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root))
os.chdir(root)
import app_decode  # noqa: E402
import hub  # noqa: E402

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
    def answer(self, *args):
        result = handler(self, *args)
        # An enrollment also names the kind of app that it sends (owner API 1.149): "windows" is a PC.
        kind = f", kind {self.form().get('kind')}" if name == "enroll" else ""
        note(f"answered {name}{kind}")
        return result
    return answer


hub.Handler.ui_wait = stamped("wait", hub.Handler.ui_wait)
hub.Handler.ui_mobile = stamped("mobile", hub.Handler.ui_mobile)
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
            elif word == "line":
                hub.ins("INSERT INTO owner_reports(text,about,created,agent,in_reply_to) VALUES(?,?,?,?,?)",
                        (f"The example build passed its checks ({count}).", "", hub.now(), "vps", None))
                hub.changed("state")
                note("line")
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
                sys.exit(0)
    time.sleep(0.2)
