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
import tempfile
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

# **One sample for each language of the app** (app/Localization/shipped, and English): a phone in Spanish sees a
# Spanish company's fleet, and the App Store's Spanish screenshots show it. Each language is made in its own process
# (`--one <language>`), because the hub's state is one per process.
LANGUAGES = ("en", "es")
LANGUAGE = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == "--one" else "en"
WORDS = {
    "en": {
        "titles": {"manager": "Fleet Manager", "wren": "Customer Support", "theo": "Developer", "pax": "DevOps",
                   "orla": "Marketing"},
        "tickets": ("Answer today's support tickets", "every ticket of today has an answer",
                    "Answer every support ticket that came in today."),
        "checkout": ("Fix the checkout error on iPhone", "a test order goes through on an iPhone",
                     "Some orders fail at checkout on iPhone. Find the cause, fix it and test it."),
        "email": ("Write the spring sale email", "the email is approved and scheduled",
                  "Write the email for the spring sale. It goes out once it is approved."),
        "certificate": ("Renew the shop's certificate", "the certificate is valid for 90 days",
                        "The shop's certificate ends this week. Renew it.", "Renewed the certificate"),
        "backups": ("Check last night's backups", "one restore is tested",
                    "Check that last night's backups ran, and test one restore.", "Tested one restore"),
        "arrivals": ("Post the new arrivals", "the post is live", "Post this week's new arrivals.",
                     "Posted the new arrivals"),
        "todo": "Press one, or write what you want instead.",
        "refund": ("Refund an order from 45 days ago?", "A customer asks for a refund 15 days after the 30-day window.",
                   ["Refund it", "Offer a 20% voucher", "Say no, politely"]),
        "approve": ("Send the spring sale email on Monday?", "Marketing finished the email. It goes to 4,800 subscribers.",
                    ["Send it on Monday", "Show me the email first"]),
        "orla": "The spring sale email is ready. I wrote two subject lines, and I test them on 10% of the list first.",
        "pax": "Backups ran at 03:00 and I tested one restore. The shop server uses 41% of its disk.",
        "theo": "I found the checkout error: Safari on iPhone sent the postcode twice. I test the fix with three cards "
                "before it goes live.",
        "wren": "I answered 23 tickets today. One customer asks for a refund outside the 30 days: it is in Needs you.",
        "owner": "Can we start the spring sale on Monday?",
        "manager": "Yes. Marketing has the email ready, and Developer puts the sale banner live on Sunday night. The "
                   "email waits for your yes in Needs you.",
    },
    "es": {
        "titles": {"manager": "Gestor del equipo", "wren": "Atención al cliente", "theo": "Desarrollador",
                   "pax": "DevOps", "orla": "Marketing"},
        "tickets": ("Responder los tickets de soporte de hoy", "cada ticket de hoy tiene respuesta",
                    "Responde cada ticket de soporte que llegó hoy."),
        "checkout": ("Corregir el error del pago en iPhone", "un pedido de prueba se completa en un iPhone",
                     "Algunos pedidos fallan en el pago en iPhone. Encuentra la causa, corrígela y pruébala."),
        "email": ("Escribir el correo de las rebajas de primavera", "el correo está aprobado y programado",
                  "Escribe el correo de las rebajas de primavera. Sale cuando esté aprobado."),
        "certificate": ("Renovar el certificado de la tienda", "el certificado es válido durante 90 días",
                        "El certificado de la tienda caduca esta semana. Renuévalo.", "Certificado renovado"),
        "backups": ("Comprobar las copias de seguridad de anoche", "una restauración está probada",
                    "Comprueba que las copias de anoche se hicieron y prueba una restauración.",
                    "Restauración probada"),
        "arrivals": ("Publicar las novedades", "la publicación está en línea", "Publica las novedades de esta semana.",
                     "Novedades publicadas"),
        "todo": "Pulsa una opción o escribe lo que quieres.",
        "refund": ("¿Reembolsar un pedido de hace 45 días?",
                   "Un cliente pide un reembolso 15 días después del plazo de 30 días.",
                   ["Reembolsarlo", "Ofrecer un vale del 20 %", "Decir que no, con amabilidad"]),
        "approve": ("¿Enviar el lunes el correo de las rebajas de primavera?",
                    "Marketing terminó el correo. Va a 4.800 suscriptores.", ["Enviarlo el lunes", "Ver antes el correo"]),
        "orla": "El correo de las rebajas de primavera está listo. Escribí dos asuntos y primero los pruebo con el 10 % "
                "de la lista.",
        "pax": "Las copias de seguridad se hicieron a las 03:00 y probé una restauración. El servidor de la tienda usa el "
               "41 % de su disco.",
        "theo": "Encontré el error del pago: Safari en iPhone enviaba el código postal dos veces. Pruebo la corrección "
                "con tres tarjetas antes de publicarla.",
        "wren": "Hoy respondí 23 tickets. Un cliente pide un reembolso fuera del plazo de 30 días. "
                "Dejé la solicitud en «Por atender».",
        "owner": "¿Podemos empezar las rebajas de primavera el lunes?",
        "manager": "Sí. Marketing tiene el correo listo, y Desarrollador publica el banner de las rebajas el domingo por "
                   "la noche. Puedes aprobar el envío en «Por atender».",
    },
}
W = WORDS[LANGUAGE]

TEAM = json.loads(json.dumps(uf.TEAM))
TEAM["agents"] = {
    "manager": {"role": "manager", "title": W["titles"]["manager"], "runtime": "claude", "machine": "hub", "can": []},
    "wren": {"role": "worker", "title": W["titles"]["wren"], "runtime": "claude", "machine": "vps",
             "can": ["shell", "web"]},
    "theo": {"role": "worker", "title": W["titles"]["theo"], "runtime": "codex", "machine": "vps",
             "can": ["shell", "web"]},
    "pax": {"role": "worker", "title": W["titles"]["pax"], "runtime": "codex", "machine": "mac-mini", "can": ["shell"]},
    "orla": {"role": "worker", "title": W["titles"]["orla"], "runtime": "claude", "machine": "mac-studio",
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
        self.task_at("wren", *W["tickets"], now - 3 * 3600, now - 6 * 60)
        self.task_at("theo", *W["checkout"], now - 150 * 60, now - 12 * 60)
        email = self.task_at("orla", *W["email"], now - 3600, now - 26 * 60)
        self.ended("pax", *W["certificate"], now - 3 * 3600)
        self.ended("pax", *W["backups"], now - 5 * 3600)
        self.ended("orla", *W["arrivals"], now - 20 * 3600)
        title, why, options = W["refund"]
        hub.ins("INSERT INTO needs(title,why,todo,raised,by,options) VALUES(?,?,?,?,'manager',?)",
                (title, why, W["todo"], now - 40 * 60, json.dumps(options, ensure_ascii=False)))
        title, why, options = W["approve"]
        approve = hub.ins("INSERT INTO needs(title,why,todo,raised,by,options) VALUES(?,?,?,?,'manager',?)",
                          (title, why, W["todo"], now - 25 * 60, json.dumps(options, ensure_ascii=False)))
        hub.q("UPDATE tasks SET waiting_on=? WHERE id=?", (f"N-{approve}", email))
        self.worker_says("orla", W["orla"], now - 26 * 60)
        self.worker_says("pax", W["pax"], now - 3 * 3600)
        self.worker_says("theo", W["theo"], now - 2 * 3600)
        self.worker_says("wren", W["wren"], now - 41 * 60)
        rid = self.request_id()
        with hub.LOCK, hub.transaction():
            hub.owner_message_rows(rid, "message", None, W["owner"], "iPhone", "manager", None, now - 9 * 60)
        self.tool("manager", "read_messages", {})
        hub.q("UPDATE events SET read_at=? WHERE agent='manager' AND kind='say'", (now - 9 * 60 + 20,))
        self.tool("manager", "tell_owner", {"text": W["manager"], "in_reply_to": rid})
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


def one():
    """The sample of this process's language, as its JSON, into a file (`--one <language> <file>`)."""
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
    with open(sys.argv[3], "w") as f:
        f.write(text)


def main():
    texts = {}
    with tempfile.TemporaryDirectory(prefix="sample-") as folder:
        for language in LANGUAGES:
            out = os.path.join(folder, language + ".json")
            subprocess.run([sys.executable, "-B", os.path.abspath(__file__), "--one", language, out], check=True)
            with open(out) as f:
                texts[language] = f.read()
    raw = lambda text: "#\"\"\"\n" + text + "\n\"\"\"#"
    others = "".join(f"        \"{language}\": {raw(texts[language])},\n" for language in LANGUAGES if language != "en")
    with open(OUT, "w") as f:
        f.write("// Made by app/ios/make_sample.py from the hub's own code: run it again, do not edit this file.\n"
                "// The sample fleet's reads as a hub answers them (SampleFleet.swift). \"@-480\" is a time eight\n"
                "// minutes before the phone opened the sample.\n\n"
                "enum SampleFleetData {\n"
                "    /// The sample in English, and in every other language of the app by its code (`localized`).\n"
                "    static let json = " + raw(texts["en"]) + "\n\n"
                "    static let localized: [String: String] = [\n" + others + "    ]\n}\n")
    data = json.loads(texts["en"])
    print(json.dumps({"languages": list(LANGUAGES), "agents": len(data["mobile"]["agents"]),
                      "needs": len(data["mobile"].get("needs") or []), "tasks": len(data["tasks"]),
                      "features": data["mobile"]["ui_features"], "bytes": os.path.getsize(OUT)}))


if __name__ == "__main__":
    one() if LANGUAGE != "en" or "--one" in sys.argv else main()
