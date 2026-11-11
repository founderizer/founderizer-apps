#!/usr/bin/env python3
"""The Mac vault's updater (update.zsh) and the part of install.py that puts it on a Mac.

update.zsh runs as itself, with the Mac's own plutil, PlistBuddy, ditto and shasum, against a channel, a vault and a
launchd that are stand-ins: curl serves the fixtures, codesign answers as told, launchctl writes down what it was asked.
Run: python3 -m unittest Vault/test_update.py
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
FLEET = "0123456789abcdef"
CHANNEL = "https://channel.test"
GROUP = "6EBZ756H9Q.local.agent-fleet.vault"
UPDATER = int(re.search(r"(?m)^updater=(\d+)$", (HERE / "update.zsh").read_text()).group(1))   # this file's number

CURL = r"""#!/bin/sh
out=""; url=""; header=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H) header="$2"; shift 2 ;;
    --proto|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url|$header" >> "$FIXTURES/curl.log"
case "$url" in
  */releases/app) cp "$FIXTURES/manifest.json" "$out" ;;
  */releases/app\?track=early) cp "$FIXTURES/manifest-early.json" "$out" ;;
  *) [ -f "$FIXTURES/${url##*/}" ] || exit 22; cp "$FIXTURES/${url##*/}" "$out" ;;
esac
"""
CODESIGN = r"""#!/bin/sh
case " $* " in
  *" --verify "*) [ -f "$FIXTURES/unsigned" ] && exit 1; exit 0 ;;
  *" --entitlements "*) cat "$FIXTURES/entitlements.plist"; exit 0 ;;
  *" -dvv "*) echo "CodeDirectory v=20500 flags=0x10000(runtime) hashes=1+1 location=embedded" >&2; exit 0 ;;
esac
exit 1
"""
# `print` answers from a fixture of that job, as the real one prints it, and fails for one that is not loaded; every
# other call is written down, and a kickstart fails while the owner is not logged in (the fixture kickstart-fails).
LAUNCHCTL = r"""#!/bin/sh
case "$1" in
  print) f="$FIXTURES/print-$(echo "$2" | tr '/' '_')"; [ -f "$f" ] || exit 113; cat "$f"; exit 0 ;;
esac
echo "$*" >> "$FIXTURES/launchctl.log"
if [ "$1" = kickstart ] && [ -f "$FIXTURES/kickstart-fails" ]; then exit 1; fi
exit 0
"""
CHOWN = r"""#!/bin/sh
echo "$*" >> "$FIXTURES/chown.log"
"""
# Root's `sudo -u #<uid>`: written down, and the command runs as this test's own user.
SUDO = r"""#!/bin/sh
echo "$*" >> "$FIXTURES/sudo.log"
[ "$1" = -u ] && shift 2
exec "$@"
"""


def bundle(path, build, version=None, updater=None):
    """A stand-in vault bundle: what update.zsh reads of one, nothing more. `updater`: the number of the update.zsh
    that it carries, or none."""
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/MacOS/FleetVault").write_text("vault")
    (path / "Contents/embedded.provisionprofile").write_text("profile")
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps(
        {"CFBundleVersion": str(build), "CFBundleShortVersionString": version or f"0.{build}.0"}))
    if updater is not None:
        (path / "Contents/Resources").mkdir()
        (path / "Contents/Resources/update.zsh").write_text(f"#!/bin/zsh\nupdater={updater}\n")


@unittest.skipUnless(sys.platform == "darwin", "update.zsh uses the Mac's plutil, PlistBuddy and ditto")
class Updater(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.base, self.fixtures, self.bin = self.tmp / "base", self.tmp / "fixtures", self.tmp / "bin"
        for folder in (self.base, self.fixtures, self.bin, self.tmp / "Applications", self.tmp / "t",
                       self.tmp / "LaunchDaemons", self.tmp / "LaunchAgents"):
            folder.mkdir()
        for name, text in (("curl", CURL), ("codesign", CODESIGN), ("launchctl", LAUNCHCTL), ("chown", CHOWN),
                           ("sudo", SUDO)):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)
        self.app = self.tmp / "Applications/Fleet Vault.app"
        bundle(self.app, 2)
        self.settings({"channel": CHANNEL, "fleet": FLEET})
        (self.base / "config.json").write_text(json.dumps({"agent": "studio", "store": "fleet", "worker_uid": 501}))
        self.entitlements({"keychain-access-groups": [GROUP]})
        self.channel(3)

    def settings(self, value):
        (self.base / "update.json").write_text(json.dumps(value))

    def entitlements(self, value):
        (self.fixtures / "entitlements.plist").write_bytes(plistlib.dumps(value))

    def channel(self, build, vault=True, track="approved", updater=None, **manifest):
        """The channel's newest build of one track: a zip of Founderizer.app that carries a vault of this build number.
        The early track's build has a name of its own, so a test can tell which track a Mac took."""
        made = self.tmp / "made"
        shutil.rmtree(made, ignore_errors=True)
        (made / "Founderizer.app/Contents/MacOS").mkdir(parents=True)
        if vault:
            bundle(made / "Founderizer.app/Contents/Library/Fleet Vault.app", build, updater=updater)
        version = "0.1.38" if track == "approved" else "0.1.39"
        zip_path = self.fixtures / f"Founderizer-{version}.zip"
        zip_path.unlink(missing_ok=True)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", made / "Founderizer.app", zip_path], check=True)
        values = {"version": version, "build": 39, "url": f"{CHANNEL}/downloads/Founderizer-{version}.zip",
                  "sha256": hashlib.sha256(zip_path.read_bytes()).hexdigest(), "hold": False}
        name = "manifest.json" if track == "approved" else "manifest-early.json"
        (self.fixtures / name).write_text(json.dumps(dict(values, **manifest)))

    def run_updater(self):
        env = {"FLEET_VAULT_UPDATE_BASE": str(self.base), "FLEET_VAULT_UPDATE_APP": str(self.app),
               "FLEET_VAULT_UPDATE_DAEMONS": str(self.tmp / "LaunchDaemons"),
               "FLEET_VAULT_UPDATE_AGENTS": str(self.tmp / "LaunchAgents"),
               "FLEET_VAULT_UPDATE_PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(self.tmp / "t"),
               "FIXTURES": str(self.fixtures), "HOME": str(self.tmp)}
        return subprocess.run(["/bin/zsh", HERE / "update.zsh"], env=env, capture_output=True, text=True, timeout=60)

    def installed(self):
        return plistlib.loads((self.app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]

    def calls(self, name):
        log = self.fixtures / f"{name}.log"
        return log.read_text().splitlines() if log.exists() else []

    def assertUnchanged(self, done, code=0):
        self.assertEqual(done.returncode, code, done.stdout + done.stderr)
        self.assertEqual(self.installed(), "2")
        self.assertEqual(self.calls("launchctl"), [])
        self.assertEqual(sorted(p.name for p in (self.tmp / "Applications").iterdir()), ["Fleet Vault.app"])
        self.assertEqual(list((self.tmp / "t").iterdir()), [], "its work folder is gone")
        self.assertFalse((self.base / ".update.lock").exists())

    def test_a_newer_signed_vault_takes_the_old_ones_place_and_starts_again(self):
        done = self.run_updater()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.installed(), "3")
        self.assertEqual(self.calls("launchctl"), ["kickstart -k gui/501/com.agentfleet.vault"])
        self.assertIn("replaced build 2", done.stdout)
        (chown,) = self.calls("chown")              # root's, before it was checked and put in place
        self.assertRegex(chown, r"^-R root:admin .*/Applications/\.FleetVault-update\.[^/]+/new\.app$")
        manifest, download = self.calls("curl")
        self.assertEqual(manifest, f"{CHANNEL}/releases/app|Founderizer-Fleet: {FLEET}")
        self.assertEqual(download, f"{CHANNEL}/downloads/Founderizer-0.1.38.zip|")
        self.assertEqual(sorted(p.name for p in (self.tmp / "Applications").iterdir()), ["Fleet Vault.app"])
        again = self.run_updater()                  # the same build again changes nothing and says nothing
        self.assertEqual((again.returncode, again.stdout), (0, ""))
        self.assertEqual(len(self.calls("launchctl")), 1)

    WRITER = "com.agentfleet.vault.writer"

    def owner_s_mac(self, exit_code=0):
        """The owner's Mac as it is: its configuration of the old writer, and the writer's LaunchAgent. `exit_code`: the
        last status of the writer's job, as launchctl prints it after a start."""
        (self.base / "config.json").write_text(json.dumps({"role": "owner", "region": "eu",
                                                           "fleet_app": "/Applications/Founderizer.app", "owner_uid": 502}))
        plist = self.tmp / "LaunchAgents" / (self.WRITER + ".plist")
        plist.write_bytes(plistlib.dumps({"Label": self.WRITER, "ProgramArguments": [str(self.app), "writer"]}))
        self.writer_ended(exit_code)
        return plist

    def writer_ended(self, exit_code):
        (self.fixtures / f"print-gui_502_{self.WRITER}").write_text(
            f"gui/502/{self.WRITER} = {{\n\tstate = not running\n\truns = 1\n\tlast exit code = {exit_code}\n}}\n")

    def test_on_the_owner_s_mac_the_new_vault_deletes_the_old_writer_s_items_and_its_launch_agent_goes(self):
        """The owner, 11 November 2026: the fleet's own store is the only vault. The new vault's writer mode deletes the
        old writer's Keychain items; the updater starts it one time after the update, and takes its LaunchAgent away
        when it ended with status 0. The next runs do nothing more for it."""
        plist = self.owner_s_mac()
        self.channel(3, updater=UPDATER)
        done = self.run_updater()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.installed(), "3")
        self.assertEqual(self.calls("launchctl"), [f"kickstart -k gui/502/{self.WRITER}", f"bootout gui/502/{self.WRITER}"])
        self.assertEqual(self.calls("sudo"), [f"-u #502 /bin/rm -f -- {plist}"])           # as the owner, not as root
        self.assertFalse(plist.exists())
        self.assertIn("replaced build 2 on the owner's Mac", done.stdout)
        self.assertIn("its LaunchAgent is gone", done.stdout)
        again = self.run_updater()
        self.assertEqual((again.returncode, again.stdout), (0, ""))
        self.assertEqual(len(self.calls("launchctl")), 2)

    def test_the_old_writer_s_launch_agent_stays_until_its_cleanup_ended_well(self):
        plist = self.owner_s_mac(exit_code=1)
        (self.fixtures / "kickstart-fails").write_text("")                # the owner is not logged in
        self.channel(3, updater=UPDATER)
        done = self.run_updater()
        self.assertEqual((done.returncode, self.installed()), (0, "3"), done.stdout + done.stderr)
        self.assertEqual(self.calls("launchctl"), [f"kickstart -k gui/502/{self.WRITER}"])
        self.assertTrue(plist.exists())
        (self.fixtures / "kickstart-fails").unlink()                      # logged in, and the cleanup did not end well
        done = self.run_updater()
        self.assertIn("did not end with status 0 (1); its LaunchAgent stays for the next run", done.stdout)
        self.assertTrue(plist.exists())
        self.assertEqual(self.calls("sudo"), [])
        # A run with no newer vault still takes the LaunchAgent away once the cleanup ended well.
        self.writer_ended(0)
        done = self.run_updater()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertFalse(plist.exists())
        self.assertEqual(self.calls("launchctl")[-2:], [f"kickstart -k gui/502/{self.WRITER}", f"bootout gui/502/{self.WRITER}"])

    def test_a_vault_in_place_that_runs_the_old_writer_is_not_started(self):
        """A vault older than updater 5 has the old writer, which deletes nothing: nothing starts it, and its LaunchAgent
        stays until a newer vault is in place."""
        plist = self.owner_s_mac()
        for carried in (None, UPDATER - 1):
            with self.subTest(carried=carried):
                shutil.rmtree(self.app)
                bundle(self.app, 2, updater=carried)
                self.channel(2)                                           # nothing newer on the channel
                self.assertUnchanged(self.run_updater())
                self.assertTrue(plist.exists())

    def test_a_worker_s_mac_has_no_writer_to_take_away(self):
        plist = self.tmp / "LaunchAgents" / (self.WRITER + ".plist")
        plist.write_text("a file of that name")
        self.channel(3, updater=UPDATER)
        done = self.run_updater()
        self.assertEqual(self.calls("launchctl"), ["kickstart -k gui/501/com.agentfleet.vault"], done.stdout)
        self.assertTrue(plist.exists())

    def test_a_mac_of_an_early_fleet_takes_each_vault_as_it_is_published(self):
        """The owner, 4 November 2026: "ok build your design". His fleet takes each release early, and the Founderizer
        app that drives it asks for that track; the vault's updater asked for the approved one only, so his Mac Studio
        kept vault build 6 while the early track carried build 7."""
        self.settings({"channel": CHANNEL, "fleet": FLEET, "track": "early"})
        done = self.run_updater()                   # the approved track has build 3, the early track nothing yet
        self.assertUnchanged(done, 1)
        self.assertIn(f"the channel gave no manifest of the early track for fleet {FLEET}", done.stdout)
        (self.fixtures / "curl.log").unlink()
        self.channel(4, track="early")
        done = self.run_updater()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.installed(), "4")
        manifest, download = self.calls("curl")
        self.assertEqual(manifest, f"{CHANNEL}/releases/app?track=early|Founderizer-Fleet: {FLEET}")
        self.assertEqual(download, f"{CHANNEL}/downloads/Founderizer-0.1.39.zip|")
        self.assertIn("(build 4) of the early track replaced build 2", done.stdout)
        self.assertEqual(self.calls("launchctl"), ["kickstart -k gui/501/com.agentfleet.vault"])

    def test_only_the_word_early_asks_for_the_early_track(self):
        """Every customer's Mac takes the approved track, and so does a Mac whose update.json is older than the
        track."""
        self.channel(2)                             # nothing newer on the approved track
        self.channel(4, track="early")
        for track in (None, "approved", "Early", "early ", "beta", "", 1, True, ["early"]):
            with self.subTest(track=track):
                (self.fixtures / "curl.log").unlink(missing_ok=True)
                self.settings({"channel": CHANNEL, "fleet": FLEET} | ({} if track is None else {"track": track}))
                self.assertUnchanged(self.run_updater())
                self.assertEqual(self.calls("curl"), [f"{CHANNEL}/releases/app|Founderizer-Fleet: {FLEET}",
                                                      f"{CHANNEL}/downloads/Founderizer-0.1.38.zip|"])

    def on_each_track(self):
        """Each track in turn, from an update.json that names it: every check holds on both."""
        for track in ("approved", "early"):
            self.settings({"channel": CHANNEL, "fleet": FLEET, "track": track})
            yield track

    def test_no_build_that_is_not_newer(self):
        for track in self.on_each_track():
            for build in (2, 1):
                with self.subTest(track=track, build=build):
                    self.channel(build, track=track)
                    self.assertUnchanged(self.run_updater())

    def test_a_held_build_is_not_even_downloaded(self):
        for track in self.on_each_track():
            with self.subTest(track=track):
                (self.fixtures / "curl.log").unlink(missing_ok=True)
                self.channel(3, track=track, hold=True)
                self.assertUnchanged(self.run_updater())
                self.assertEqual(len(self.calls("curl")), 1)

    def test_a_build_from_before_vaults_rode_along_changes_nothing(self):
        self.channel(3, vault=False)
        self.assertUnchanged(self.run_updater())

    def test_what_is_not_the_channel_s_own_build_is_refused(self):
        for track in self.on_each_track():
            for manifest in ({"sha256": "0" * 64}, {"url": "https://elsewhere.test/downloads/Founderizer-0.1.38.zip"},
                             {"url": f"{CHANNEL}/../Founderizer-0.1.38.zip"}, {"sha256": "short"}):
                with self.subTest(track=track, manifest=manifest):
                    self.channel(3, track=track, **manifest)
                    done = self.run_updater()
                    self.assertUnchanged(done, 1)
                    self.assertIn("nothing changed", done.stdout)

    def test_a_vault_that_is_not_ours_as_signed_is_refused(self):
        cases = [("unsigned", None), (None, {"keychain-access-groups": [GROUP, "6EBZ756H9Q.other"]}),
                 (None, {"keychain-access-groups": ["XXXXXXXXXX.local.agent-fleet.vault"]}),
                 (None, {"keychain-access-groups": [GROUP], "com.apple.security.get-task-allow": True}),
                 (None, {"keychain-access-groups": [GROUP], "com.apple.security.cs.disable-library-validation": True})]
        for track in self.on_each_track():
            self.channel(3, track=track)
            for flag, entitlements in cases:
                with self.subTest(track=track, flag=flag, entitlements=entitlements):
                    (self.fixtures / "unsigned").unlink(missing_ok=True)
                    if flag:
                        (self.fixtures / "unsigned").write_text("")
                    self.entitlements(entitlements or {"keychain-access-groups": [GROUP]})
                    done = self.run_updater()
                    self.assertUnchanged(done, 1)
                    self.assertIn("is not ours as signed", done.stdout)

    def test_without_its_settings_it_changes_nothing(self):
        for value in ({}, {"channel": "http://channel.test", "fleet": FLEET}, {"channel": CHANNEL, "fleet": "short"}):
            with self.subTest(value=value):
                self.settings(value)
                done = self.run_updater()
                self.assertUnchanged(done, 1)
                self.assertEqual(self.calls("curl"), [])

    def bundled(self, number):
        """The installed vault carries an updater with this `updater=` number."""
        (self.app / "Contents/Resources").mkdir(exist_ok=True)
        text = re.sub(r"(?m)^updater=\d+$", f"updater={number}", (HERE / "update.zsh").read_text(), count=1)
        (self.app / "Contents/Resources/update.zsh").write_text(text)
        return text

    def test_a_newer_updater_that_the_vault_in_place_carries_takes_this_one_s_place(self):
        text = self.bundled(UPDATER + 1)
        self.channel(2)
        done = self.run_updater()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual((self.base / "update.zsh").read_text(), text)
        self.assertEqual((self.base / "update.zsh").stat().st_mode & 0o777, 0o755)
        self.assertIn(f"the updater is now version {UPDATER + 1}", done.stdout)
        self.assertFalse((self.base / ".update.zsh.new").exists())

    def test_an_updater_that_is_not_newer_or_not_signed_stays_out(self):
        for number, unsigned in ((UPDATER, False), (UPDATER - 1, False), (UPDATER + 1, True)):
            with self.subTest(number=number, unsigned=unsigned):
                (self.fixtures / "unsigned").unlink(missing_ok=True)
                if unsigned:
                    (self.fixtures / "unsigned").write_text("")
                self.bundled(number)
                self.channel(2)
                self.run_updater()
                self.assertFalse((self.base / "update.zsh").exists())

    def carried(self, number=None):
        """The vault in place carries starter.zsh, with this `starter=` number when one is given."""
        (self.app / "Contents/Resources").mkdir(exist_ok=True)
        text = (HERE / "starter.zsh").read_text()
        if number is not None:
            text = text.replace("\nstarter=1\n", f"\nstarter={number}\n", 1)
        (self.app / "Contents/Resources/starter.zsh").write_text(text)
        return text

    def test_the_starter_that_the_vault_in_place_carries_goes_in_place_with_its_daemon(self):
        """The owner, 4 November 2026: "Build the starter". It reaches a Mac with the vault, and runs every minute."""
        text = self.carried()
        self.channel(2)
        done = self.run_updater()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual((self.base / "starter.zsh").read_text(), text)
        self.assertEqual((self.base / "starter.zsh").stat().st_mode & 0o777, 0o755)
        daemon = self.tmp / "LaunchDaemons/com.agentfleet.starter.plist"
        self.assertEqual(plistlib.loads(daemon.read_bytes()), {
            "Label": "com.agentfleet.starter", "ProgramArguments": ["/bin/zsh", str(self.base / "starter.zsh")],
            "RunAtLoad": True, "StartInterval": 60, "StandardOutPath": str(self.base / "starter.log"),
            "StandardErrorPath": str(self.base / "starter.log")})
        self.assertEqual(daemon.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.calls("launchctl"), ["bootout system/com.agentfleet.starter",
                                                   f"bootstrap system {daemon}"])
        self.assertIn("the starter is now version 1", done.stdout)
        self.assertFalse([p.name for p in self.base.iterdir() if p.name.endswith(".new")])
        again = self.run_updater()                  # the same starter again changes nothing and says nothing
        self.assertEqual((again.returncode, again.stdout), (0, ""))
        self.assertEqual(len(self.calls("launchctl")), 2)
        self.carried(2)                             # a newer one takes its place
        self.assertIn("the starter is now version 2", self.run_updater().stdout)

    def test_a_starter_that_is_not_newer_not_signed_or_on_the_owner_s_mac_stays_out(self):
        for case in ("same", "unsigned", "owner"):
            with self.subTest(case=case):
                for name in ("starter.zsh", "unsigned", "launchctl.log"):
                    (self.base / name).unlink(missing_ok=True)
                    (self.fixtures / name).unlink(missing_ok=True)
                (self.base / "config.json").write_text(json.dumps({"agent": "studio", "store": "fleet", "worker_uid": 501}))
                self.carried(1)
                if case == "same":                  # the one in place has its number already
                    (self.base / "starter.zsh").write_text(self.carried(1))
                elif case == "unsigned":
                    (self.fixtures / "unsigned").write_text("")
                else:
                    (self.base / "config.json").write_text(json.dumps({"role": "owner", "owner_uid": 501}))
                self.channel(2)
                done = self.run_updater()
                self.assertNotIn("starter", done.stdout)
                self.assertFalse((self.tmp / "LaunchDaemons/com.agentfleet.starter.plist").exists())
                self.assertEqual([c for c in self.calls("launchctl") if "starter" in c], [])

    def test_one_run_at_a_time(self):
        (self.base / ".update.lock").mkdir()
        done = self.run_updater()
        self.assertEqual((done.returncode, self.installed(), self.calls("curl")), (0, "2", []))


# A launchd as the starter reads one: `print` answers from a fixture of that domain or job, as the real one prints it,
# and fails for one that is not loaded; `kickstart` writes down what it was asked.
STARTER_LAUNCHCTL = r"""#!/bin/sh
case "$1" in
  print) f="$FIXTURES/print-$(echo "$2" | tr '/' '_')"; [ -f "$f" ] || exit 113; cat "$f" ;;
  *) echo "$*" >> "$FIXTURES/launchctl.log" ;;
esac
"""
DOMAIN = """gui/501 = {
\ttype = gui
\tservices = {
\t\t       0      -   com.agentfleet.kai
\t\t    2130      -   com.agentfleet.web-lead
\t\t       0      1   com.agentfleet.server
\t\t       0      -   com.agentfleet.vault
\t\t       0      -   com.agentfleet.ivy
\t\t       0      0   com.agentfleet.done
\t\t       0      -   com.sam.keepawake
\t\t     611      -   com.apple.loginwindow
\t}
}
"""


def job(state, pended=None):
    """What `launchctl print gui/501/<label>` says of one job: its state, and the start that launchd keeps pending."""
    lines = [f"\tstate = {state}", "\tprogram = /opt/homebrew/opt/python@3.14/bin/python3.14", "\truns = 0"]
    if pended:
        lines.append(f"\tpended nondemand spawn = {pended}")
    return "gui/501/x = {\n" + "\n".join(lines + ["\tendpoints = {", "\t\tstate = active", "\t}"]) + "\n}\n"


@unittest.skipUnless(sys.platform == "darwin", "starter.zsh uses the Mac's plutil")
class Starter(unittest.TestCase):
    """starter.zsh as launchd runs it every minute: it starts the vault user's Founderizer jobs that launchd holds."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.base, self.fixtures, self.bin = self.tmp / "base", self.tmp / "fixtures", self.tmp / "bin"
        for folder in (self.base, self.fixtures, self.bin):
            folder.mkdir()
        (self.bin / "launchctl").write_text(STARTER_LAUNCHCTL)
        (self.bin / "launchctl").chmod(0o755)
        (self.base / "config.json").write_text(json.dumps({"agent": "studio", "store": "fleet", "worker_uid": 501}))
        (self.fixtures / "print-gui_501").write_text(DOMAIN)
        for label, state, pended in (("kai", "not running", "speculative"),       # held at load by Setup Assistant
                                     ("web-lead", "running", None),
                                     ("server", "not running", "inefficient"),   # keeps failing: no start repeats it
                                     ("vault", "not running", "interval"),       # its timer, held too
                                     ("done", "not running", None),              # nothing pending: left as it is
                                     ):
            (self.fixtures / f"print-gui_501_com.agentfleet.{label}").write_text(job(state, pended))
        (self.fixtures / "print-gui_501_com.sam.keepawake").write_text(job("not running", "speculative"))
        # com.agentfleet.ivy is in the domain's list and not loaded any more: `print` of it fails

    def run_starter(self):
        env = {"FLEET_STARTER_BASE": str(self.base), "FLEET_STARTER_PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
               "FIXTURES": str(self.fixtures), "HOME": str(self.tmp)}
        return subprocess.run(["/bin/zsh", HERE / "starter.zsh"], env=env, capture_output=True, text=True, timeout=60)

    def calls(self):
        log = self.fixtures / "launchctl.log"
        return log.read_text().splitlines() if log.exists() else []

    def test_it_starts_each_founderizer_job_that_launchd_holds_and_nothing_else(self):
        """Live, 4 November 2026: after macOS 27.2 installed itself, every agent of the Mac Studio was loaded with
        `runs = 0` and `pended nondemand spawn = speculative`, and only a kickstart started one."""
        done = self.run_starter()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.calls(), ["kickstart gui/501/com.agentfleet.kai", "kickstart gui/501/com.agentfleet.vault"])
        lines = done.stdout.splitlines()
        self.assertEqual(len(lines), 2)
        self.assertRegex(lines[0], r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d started com\.agentfleet\.kai of user 501, "
                                   r"which launchd held \(speculative\)$")
        self.assertTrue(lines[1].endswith("started com.agentfleet.vault of user 501, which launchd held (interval)"))

    def test_on_the_owner_s_mac_or_before_a_login_it_starts_nothing(self):
        (self.base / "config.json").write_text(json.dumps({"role": "owner", "owner_uid": 501}))
        self.assertEqual((self.run_starter().returncode, self.calls()), (0, []))
        (self.base / "config.json").write_text(json.dumps({"agent": "studio", "store": "fleet", "worker_uid": 501}))
        (self.fixtures / "print-gui_501").unlink()                       # nobody logged in: no gui domain yet
        done = self.run_starter()
        self.assertEqual((done.returncode, done.stdout, self.calls()), (0, "", []))


def installer():
    spec = importlib.util.spec_from_file_location("vault_install", HERE / "install.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Install(unittest.TestCase):
    """The part of install.py that puts the updater on a Mac. As root it also checks that each folder is root's own
    (`protected`); here the folders are a temporary one's, so that one check is left out."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.install = installer()
        folder = self.tmp / "Fleet Vault"
        folder.mkdir()
        (self.tmp / "LaunchDaemons").mkdir()
        for name, value in (("CONFIG", folder / "config.json"), ("UPDATER", folder / "update.zsh"),
                            ("UPDATE_SETTINGS", folder / "update.json"), ("UPDATE_LOG", folder / "update.log"),
                            ("UPDATE_DAEMON", self.tmp / "LaunchDaemons/com.agentfleet.vault.update.plist")):
            patcher = mock.patch.object(self.install, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        for patcher in (mock.patch.object(self.install, "protected"),):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_the_updater_its_settings_and_its_daemon(self):
        with mock.patch.object(self.install.subprocess, "run") as run:
            self.install.install_updater(FLEET, CHANNEL)
        self.assertEqual(self.install.UPDATER.read_bytes(), (HERE / "update.zsh").read_bytes())
        self.assertEqual(self.install.UPDATER.stat().st_mode & 0o777, 0o755)
        self.assertEqual(json.loads(self.install.UPDATE_SETTINGS.read_text()),
                         {"channel": CHANNEL, "fleet": FLEET, "track": "approved"})
        daemon = plistlib.loads(self.install.UPDATE_DAEMON.read_bytes())
        self.assertEqual(daemon, {"Label": "com.agentfleet.vault.update",
                                  "ProgramArguments": ["/bin/zsh", str(self.install.UPDATER)],
                                  "RunAtLoad": True, "StartInterval": 3600,
                                  "StandardOutPath": str(self.install.UPDATE_LOG),
                                  "StandardErrorPath": str(self.install.UPDATE_LOG)})
        self.assertEqual([c.args[0] for c in run.call_args_list],
                         [["launchctl", "bootout", "system/com.agentfleet.vault.update"],
                          ["launchctl", "bootstrap", "system", str(self.install.UPDATE_DAEMON)]])
        with mock.patch.object(self.install.subprocess, "run"):      # again, early: the same files, no leftover
            self.install.install_updater(FLEET, CHANNEL, "early")
        self.assertEqual(json.loads(self.install.UPDATE_SETTINGS.read_text()),
                         {"channel": CHANNEL, "fleet": FLEET, "track": "early"})
        self.assertEqual(sorted(p.name for p in self.install.UPDATER.parent.iterdir()), ["update.json", "update.zsh"])
        with mock.patch.object(self.install.subprocess, "run") as run, self.assertRaises(SystemExit):
            self.install.install_updater(FLEET, CHANNEL, "beta")             # no track that update.zsh does not read
        self.assertEqual((json.loads(self.install.UPDATE_SETTINGS.read_text())["track"], run.call_count), ("early", 0))

    def test_what_the_command_line_takes(self):
        refused = [[], ["--updater-only"], ["--updater-only", "--fleet", "0123"],
                   ["--updater-only", "--fleet", FLEET, "--channel", "http://channel.test"],
                   ["--updater-only", "--fleet", FLEET, "--app", "/tmp/x.app"],
                   ["--updater-only", "--fleet", FLEET, "--store"],
                   ["--updater-only", "--fleet", FLEET, "--track", "beta"],
                   ["--updater-only", "--fleet", FLEET, "--track", "Early"],
                   ["--fleet", FLEET, "--store", "--user", "sam", "--agent", "studio", "--hub", "http://100.64.0.1:8765"],
                   ["--fleet", FLEET, "--app", "/tmp/x.app", "--user", "sam", "--hub", "http://100.64.0.1:8765"]]
        # The options of the store that this vault opened before, and of the owner's old writer, are gone.
        worker = ["--fleet", FLEET, "--app", "/tmp/x.app", "--user", "sam", "--agent", "studio", "--hub", "http://100.64.0.1:8765"]
        refused += [worker + ["--region", "eu"], worker + ["--store", "--switch-store"],
                    ["--fleet", FLEET, "--app", "/tmp/x.app", "--user", "sam", "--owner", "--fleet-app", "/Applications/Founderizer.app"]]
        for argv in refused:
            with self.subTest(argv=argv), mock.patch.object(sys, "argv", ["install.py", *argv]), \
                    mock.patch("sys.stderr"), self.assertRaises(SystemExit) as stop:
                self.install.main()
            self.assertEqual(stop.exception.code, 2)
        with mock.patch.object(sys, "argv", ["install.py", "--updater-only", "--fleet", FLEET]), \
                mock.patch.object(self.install.os, "geteuid", return_value=0), \
                mock.patch.object(self.install, "install_updater") as updater, self.assertRaises(SystemExit) as stop:
            self.install.main()                     # no vault on this Mac yet: nothing to keep up to date
        self.assertIn("install the vault first", str(stop.exception))
        self.install.CONFIG.write_text("{}")
        for extra, track in (([], "approved"), (["--track", "early"], "early"), (["--track", "approved"], "approved")):
            with self.subTest(extra=extra), \
                    mock.patch.object(sys, "argv", ["install.py", "--updater-only", "--fleet", FLEET, *extra]), \
                    mock.patch.object(self.install.os, "geteuid", return_value=0), \
                    mock.patch.object(self.install, "install_updater") as updater:
                self.install.main()
            updater.assert_called_once_with(FLEET, "https://founderizer.com", track)
        # The owner's Mac keeps its configuration of the old writer: its updater still goes in, because it is what takes
        # that writer away.
        self.install.CONFIG.write_text(json.dumps({"role": "owner", "region": "eu", "fleet_app": "/Applications/Founderizer.app",
                                                   "owner_uid": 502}))
        with mock.patch.object(sys, "argv", ["install.py", "--updater-only", "--fleet", FLEET]), \
                mock.patch.object(self.install.os, "geteuid", return_value=0), \
                mock.patch.object(self.install, "install_updater") as updater:
            self.install.main()
        updater.assert_called_once_with(FLEET, "https://founderizer.com", "approved")

    def test_a_worker_s_configuration_names_the_fleet_s_own_store_in_the_bytes_that_the_vault_reads(self):
        """The Mac vault's test `theConfigurationThatTheInstallerWritesLoadsAsBefore` loads these same bytes."""
        user = mock.Mock(pw_uid=501, pw_dir="/Users/me")
        configuration = self.install.worker_configuration(mock.Mock(agent="studio", hub="http://100.96.10.20:8765/"), user)
        self.assertEqual(json.dumps(configuration),
                         '{"agent": "studio", "hub": "http://100.96.10.20:8765", "store": "fleet", "worker_uid": 501, '
                         '"socket": "/Users/me/Library/Application Support/AgentFleet/vault.sock"}')
        self.install.keep_configuration(configuration)                    # a new Mac: written as it is
        self.assertEqual(self.install.CONFIG.read_text(), json.dumps(configuration))
        self.install.keep_configuration(configuration)                    # the same again: kept
        with self.assertRaises(SystemExit) as stop:
            self.install.keep_configuration(dict(configuration, agent="other"))
        self.assertIn("different settings", str(stop.exception))

    def test_a_configuration_that_names_a_region_stops_the_install_and_changes_nothing(self):
        """The store that this vault opened before the fleet's own store became its only store: a worker's configuration
        of it, and the owner's, stop an install with words that say what to do."""
        user = mock.Mock(pw_uid=501, pw_dir="/Users/me")
        configuration = self.install.worker_configuration(mock.Mock(agent="studio", hub="http://100.96.10.20:8765"), user)
        for old in ({"agent": "studio", "hub": "http://100.96.10.20:8765", "region": "eu", "worker_uid": 501,
                     "socket": "/Users/me/Library/Application Support/AgentFleet/vault.sock"},
                    {"role": "owner", "region": "eu", "fleet_app": "/Applications/Founderizer.app", "owner_uid": 502}):
            with self.subTest(old=old):
                self.install.CONFIG.write_text(json.dumps(old))
                with self.assertRaises(SystemExit) as stop:
                    self.install.keep_configuration(configuration)
                self.assertIn("names a region", str(stop.exception))
                self.assertIn(f"remove {self.install.CONFIG} as root and install again", str(stop.exception))
                self.assertEqual(json.loads(self.install.CONFIG.read_text()), old)

    def test_the_vault_carries_its_installer_beside_its_updater(self):
        """A Mac's join line runs the install.py that a vault it has checked carries, as root, and install_updater
        takes the update.zsh beside it: both are in the vault's Contents/Resources, sealed by its signature."""
        build = (HERE / "build.py").read_text()
        for name in ("update.zsh", "install.py", "starter.zsh"):
            self.assertIn(f'shutil.copy2(ROOT / "Vault/{name}", app / "Contents/Resources/{name}")', build)


if __name__ == "__main__":
    unittest.main()
