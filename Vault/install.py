#!/usr/bin/env python3
"""Install the signed Mac vault. Never read or migrate a credential."""
import argparse
import base64
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

APP = Path("/Applications/Fleet Vault.app")
CONFIG = Path("/Library/Application Support/Fleet Vault/config.json")
LABEL = "com.agentfleet.vault"
REQUIREMENT = 'anchor apple generic and certificate leaf[subject.OU] = "6EBZ756H9Q" and identifier "local.agent-fleet.vault"'
# The vault's own updater (update.zsh): root, from a daemon, at load and every hour.
UPDATER = CONFIG.parent / "update.zsh"
UPDATE_SETTINGS = CONFIG.parent / "update.json"     # the channel, the fleet's id and its track: no secret
TRACKS = ("approved", "early")                       # PRODUCT.md 4.3, "the two tracks"; update.zsh reads which
UPDATE_LABEL = "com.agentfleet.vault.update"
UPDATE_DAEMON = Path("/Library/LaunchDaemons") / (UPDATE_LABEL + ".plist")
UPDATE_LOG = CONFIG.parent / "update.log"           # in the protected folder: /Library/Logs is the admin group's
CHANNEL = "https://founderizer.com"
# The owner's public keys in a worker Mac's configuration (--owner-keys-only): with them, the vault hands a login over
# only to a key that the owner signed a pin of (Sources/FleetVaultCore/VaultOwnerPin.swift), as a Linux broker does with
# the keys that `hubsetup.py vault --owner-key` gives it. The hub never writes them: a hub that is broken into could
# name a key of its own.
WORKER_KEYS = {"agent", "hub", "store", "socket", "worker_uid"}
OWNER_KEYS = 8                          # the most owner keys that may sign (vault.py OWNER_KEYS)
OWNER_KEYS_BUILD = 12                   # the first Fleet Vault build that reads owner_keys and fleet
P256_P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
P256_B = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b
LAUNCHCTL = "/bin/launchctl"            # by its path: as root, never a program that a PATH of the agents' user names
# What a child of the worker's user runs to ask the vault for its status after the owner's keys went in: the vault serves
# its worker's user alone, and closes a connection of root's. Any answer counts: the vault opens its socket only after it
# loaded its configuration, so an answer of `"ok": false` (a store that does not open) still proves the file.
STATUS_PROBE = r"""
import json, socket, sys, time
end = time.time() + float(sys.argv[2])
while time.time() < end:
    try:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(3)
            connection.connect(sys.argv[1])
            connection.sendall(json.dumps({"v": 2, "op": "status"}).encode() + b"\n")
            answer = json.loads(connection.makefile().readline())
        sys.exit(0 if isinstance(answer, dict) and answer.get("v") == 2 else 1)
    except (OSError, ValueError):
        time.sleep(1)
sys.exit(1)
"""


def worker_configuration(args, user):
    """The configuration of a worker Mac: its agent, its hub, the store that it opens, its user and its socket. The
    store is always the fleet's own encrypted file on this Mac (`"store": "fleet"`): a configuration names one store,
    never two, and it is the only one that this vault opens (vault.py reads its own configuration the same way)."""
    return {"agent": args.agent, "hub": args.hub.rstrip("/"), "store": "fleet", "worker_uid": user.pw_uid,
            "socket": user.pw_dir + "/Library/Application Support/AgentFleet/vault.sock"}


def old_store(current):
    """The words that stop an install on a configuration of the store that this vault opened before the fleet's own
    store became its only store: it names a `region`. Else None."""
    if isinstance(current, dict) and "region" in current:
        return ("This Mac's vault configuration names a region, so it is for a store that this vault does not open any "
                "more. No change was made. To give this Mac the fleet's own store, remove " + str(CONFIG) + " as root "
                "and install again. No value moves to the new store.")
    return None


def keep_configuration(configuration):
    """Write the configuration, or keep the one that is there. A configuration that names a region stops the install
    with its own words (`old_store`); any other difference stops it too, as before."""
    if not (CONFIG.exists() or CONFIG.is_symlink()):
        protected(CONFIG.parent.parent)
        CONFIG.parent.mkdir(mode=0o755, exist_ok=True)
        protected(CONFIG.parent)
        with CONFIG.open("x") as handle:
            json.dump(configuration, handle)
        CONFIG.chmod(0o644)
        protected(CONFIG)
        return
    protected(CONFIG)
    current = json.loads(CONFIG.read_text())
    stop = old_store(current)
    if stop:
        raise SystemExit(stop)
    # The owner's keys and the fleet's id that root gave this Mac (--owner-keys-only) are no setting of an install: they
    # stay in the file, so a second install keeps the owner's pin check.
    if isinstance(current, dict):
        current = {key: value for key, value in current.items() if key not in ("owner_keys", "fleet")}
    if current != configuration:
        raise SystemExit("An existing vault has different settings. No change was made.")


def owner_key(text):
    """One public key of the owner, as their app gives it: the standard base64, padded, of 65 bytes 04 || X || Y that is a
    point of P-256 (vault.py owner_key). SystemExit for anything else, before anything is written."""
    try:
        raw = base64.b64decode(text, validate=True)
    except ValueError:
        raw = b""
    x, y = int.from_bytes(raw[1:33], "big"), int.from_bytes(raw[33:], "big")
    if base64.b64encode(raw).decode() != text or len(raw) != 65 or raw[0] != 4 or not (
            x < P256_P and y < P256_P and (y * y - x * x * x + 3 * x - P256_B) % P256_P == 0):
        raise SystemExit("Each --owner-key is the base64 of the owner's 65-byte P-256 public key, as their app gives it.")
    return text


def build_of(app):
    """The CFBundleVersion of an app bundle as a number, or 0."""
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            return int(plistlib.load(handle)["CFBundleVersion"])
    except (OSError, KeyError, TypeError, ValueError, plistlib.InvalidFileException):
        return 0


def keys_need_build(source):
    """True when this Mac's configuration holds the owner's keys and `source` is a vault build that does not read them."""
    try:
        current = json.loads(CONFIG.read_text())
    except (OSError, ValueError):
        return False
    return isinstance(current, dict) and "owner_keys" in current and build_of(source) < OWNER_KEYS_BUILD


def give_owner_keys(keys, fleet):
    """--owner-keys-only, as root on a worker Mac whose vault is installed: the owner's public keys and the fleet's id go
    into its configuration, every other setting stays as it is, and the vault starts again to read them. From then on it
    hands a login over only to a key that the owner signed a pin of. The keys given replace the ones there, so for a new
    owner Mac give its key and the old one together until the pins are signed again: a kept pin carries the old key's
    signature. It reads and writes no credential."""
    protected(CONFIG)
    current = json.loads(CONFIG.read_text())
    stop = old_store(current)
    if stop:
        raise SystemExit(stop)
    if not isinstance(current, dict) or set(current) - {"owner_keys", "fleet"} != WORKER_KEYS:
        raise SystemExit("This Mac's vault configuration is not a worker's, so it takes no owner key. No change was made.")
    try:
        settings = json.loads(UPDATE_SETTINGS.read_text())
    except (OSError, ValueError):
        settings = None
    if not isinstance(settings, dict) or settings.get("fleet") != fleet:
        raise SystemExit(f"{UPDATE_SETTINGS} does not name the fleet id {fleet}: give the id that this Mac's vault updater "
                         f"names. No change was made.")
    build = build_of(APP)
    if build < OWNER_KEYS_BUILD:
        raise SystemExit(f"The Fleet Vault on this Mac reads the owner's keys from build {OWNER_KEYS_BUILD} on, and this one "
                         f"is build {build or 'unknown'}: run this again once its updater has put a newer one in place. No "
                         f"change was made.")
    configuration = {key: value for key, value in current.items() if key not in ("owner_keys", "fleet")}
    configuration.update(owner_keys=keys, fleet=fleet)
    old = CONFIG.read_bytes()
    uid = current["worker_uid"]
    try:
        pwd.getpwuid(uid)                   # the worker's user must exist before anything is written
    except KeyError:
        raise SystemExit("This Mac has no user with the vault's worker_uid. No change was made.") from None
    written(CONFIG, json.dumps(configuration).encode(), 0o644)
    try:
        subprocess.run([LAUNCHCTL, "kickstart", "-k", f"gui/{uid}/{LABEL}"], capture_output=True)
        up = vault_answers(uid, current["socket"])
    except BaseException:                   # an interrupt or a failure after the write: the old file goes back
        written(CONFIG, old, 0o644)
        subprocess.run([LAUNCHCTL, "kickstart", "-k", f"gui/{uid}/{LABEL}"], capture_output=True)   # and the vault reads it
        raise
    if not up:
        # A vault that does not come up with the new file serves nothing: the old file goes back, and so does the vault.
        written(CONFIG, old, 0o644)
        subprocess.run([LAUNCHCTL, "kickstart", "-k", f"gui/{uid}/{LABEL}"], capture_output=True)
        raise SystemExit("Fleet Vault did not answer after its restart, so its old configuration is back in place and no "
                         "key was added. The worker's user must be logged in, because the vault runs in its session.")
    print(f"Fleet Vault holds {len(keys)} key(s) of the owner for fleet {fleet}: it hands a login over only to a key that "
          f"the owner signed a pin of.")


def vault_answers(uid, socket_path, wait=30):
    """True when the vault of the worker's user `uid` answers `status` on its socket within `wait` seconds. A child of
    that user asks, in Python's isolated mode, because the vault closes a connection that is not its worker's."""
    try:
        user = pwd.getpwuid(uid)

        def worker_identity():
            os.setgroups([])
            os.setgid(user.pw_gid)
            os.setuid(user.pw_uid)
        return subprocess.run([sys.executable, "-I", "-c", STATUS_PROBE, socket_path, str(wait)],
                              preexec_fn=worker_identity, capture_output=True, timeout=wait + 10).returncode == 0
    except Exception:                       # no user, no child, or no answer in time: the vault did not come up
        return False


def protected(path):
    for current in [path, *path.parents]:
        info = current.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise SystemExit("The vault configuration path is not protected: " + str(current))


def verify(app):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + REQUIREMENT, str(app)], check=True)
    result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout)
    if entitlements.get("keychain-access-groups") != ["6EBZ756H9Q.local.agent-fleet.vault"] or any(
        entitlements.get(key) for key in ["com.apple.security.get-task-allow", "get-task-allow",
                                         "com.apple.security.cs.disable-library-validation",
                                         "com.apple.security.cs.allow-dyld-environment-variables"]
    ):
        raise SystemExit("The app does not have the required Keychain and code protections.")
    result = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True, check=True)
    if "(runtime)" not in result.stderr or not (app / "Contents/embedded.provisionprofile").is_file():
        raise SystemExit("The app needs hardened runtime and an Apple provisioning profile.")


def written(path, data, mode):
    """One root-owned file in a protected folder, written beside its place and renamed into it, so that a reader never
    sees half of it and no link that somebody put there is followed."""
    protected(path.parent)
    staged = path.parent / ("." + path.name + ".new")
    if staged.is_symlink() or staged.exists():
        staged.unlink()
    with os.fdopen(os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode), "wb") as handle:
        handle.write(data)
    staged.chmod(mode)
    staged.replace(path)


def install_updater(fleet, channel, track="approved"):
    """The vault's own updater: update.zsh in the vault's protected folder, the channel, the fleet's id and its release
    track beside it, and one root daemon that runs it at load and every hour. From then on each newer signed vault of
    that track reaches this Mac by itself; update.zsh says how it checks one. Running this again writes the three files
    again and restarts the daemon. It reads and writes no credential."""
    if track not in TRACKS:
        raise SystemExit("The track is approved or early.")
    source = Path(__file__).resolve().parent / "update.zsh"
    if source.is_symlink() or not source.is_file():
        raise SystemExit("update.zsh must be beside install.py.")
    written(UPDATER, source.read_bytes(), 0o755)
    written(UPDATE_SETTINGS, json.dumps({"channel": channel, "fleet": fleet, "track": track}).encode(), 0o644)
    written(UPDATE_DAEMON, plistlib.dumps({"Label": UPDATE_LABEL, "ProgramArguments": ["/bin/zsh", str(UPDATER)],
                                           "RunAtLoad": True, "StartInterval": 3600,
                                           "StandardOutPath": str(UPDATE_LOG), "StandardErrorPath": str(UPDATE_LOG)}),
            0o644)
    subprocess.run(["launchctl", "bootout", f"system/{UPDATE_LABEL}"], capture_output=True)
    subprocess.run(["launchctl", "bootstrap", "system", str(UPDATE_DAEMON)], check=True)
    print(f"Fleet Vault now updates itself: every hour it takes the newest signed vault of the {track} track from "
          f"{channel}. Its log is {UPDATE_LOG}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="The signed build to install. Not with --updater-only.")
    parser.add_argument("--user", help="The local user that runs the vault. Not with --updater-only.")
    parser.add_argument("--agent")
    parser.add_argument("--hub")
    parser.add_argument("--store", action="store_true",
                        help="Accepted, and not necessary: the vault always opens the fleet's own store, one locked "
                             "file of the helper on this Mac, and makes its key and an empty store itself. A join line "
                             "passes it.")
    parser.add_argument("--fleet", help="The fleet's id: the 16 hex characters that the release channel knows it by "
                                        "(the hub's GET /ui/releases, entitlement.fleet). The vault's updater sends it.")
    parser.add_argument("--channel", default=CHANNEL, help="The release channel that the updater reads.")
    parser.add_argument("--track", choices=TRACKS, default="approved",
                        help="The fleet's release track, which the updater reads: early only for a fleet whose setting "
                             "releases.early is on (the hub's GET /ui/releases, early), which takes each vault build as "
                             "it is published; approved, the default, takes only the builds that the owner approved.")
    parser.add_argument("--owner-key", action="append",
                        help="With --owner-keys-only: one public key of the owner, the base64 of 65 bytes as their app "
                             "gives it. Give it once for each key, at most 8.")
    parser.add_argument("--owner-keys-only", action="store_true",
                        help="Only the owner's keys, on a Mac whose vault is installed: they go into its configuration "
                             "with --fleet, and the vault then hands a login over only to a key that the owner signed a "
                             "pin of. No app and no other setting changes.")
    parser.add_argument("--updater-only", action="store_true",
                        help="Only the vault's updater, on a Mac whose vault is installed already: no app and no "
                             "configuration change. The updater then puts the newest vault in place within the hour.")
    args = parser.parse_args()
    if not (args.fleet and re.fullmatch(r"[0-9a-f]{16}", args.fleet)):
        parser.error("--fleet takes the fleet's id: 16 lowercase hex characters")
    if not re.fullmatch(r"https://[a-z0-9.-]+", args.channel):
        parser.error("--channel takes https://<host> and nothing after it")
    if args.owner_keys_only:
        if any([args.app, args.user, args.agent, args.hub, args.store, args.updater_only]) or not args.owner_key \
                or len(args.owner_key) > OWNER_KEYS or args.channel != CHANNEL or args.track != "approved":
            parser.error("--owner-keys-only takes --fleet and one to eight --owner-key, and nothing else")
        keys = list(dict.fromkeys(owner_key(key) for key in args.owner_key))
        if os.geteuid() != 0:
            raise SystemExit("Run this installer with sudo.")
        if not CONFIG.is_file():
            raise SystemExit("This Mac has no Fleet Vault configuration: install the vault first.")
        give_owner_keys(keys, args.fleet)
        return
    if args.owner_key:
        parser.error("--owner-key goes with --owner-keys-only")
    if args.updater_only:
        if any([args.app, args.user, args.agent, args.hub, args.store]):
            parser.error("--updater-only takes --fleet, --channel and --track, and nothing else")
        if os.geteuid() != 0:
            raise SystemExit("Run this installer with sudo.")
        if not CONFIG.is_file():
            raise SystemExit("This Mac has no Fleet Vault configuration: install the vault first.")
        install_updater(args.fleet, args.channel, args.track)
        return
    if not (args.app and args.user and args.agent and args.hub):
        parser.error("--app, --user, --agent and --hub are required, except with --updater-only")
    if os.geteuid() != 0:
        raise SystemExit("Run this installer with sudo on the worker Mac.")
    user = pwd.getpwnam(args.user)
    if user.pw_uid < 500 or not re.fullmatch(r"[a-z][a-z0-9-]{1,30}", args.agent):
        raise SystemExit("Select the worker's local user and Fleet agent name.")
    hub = urlsplit(args.hub)
    try:
        private = ipaddress.ip_address(hub.hostname or "") in ipaddress.ip_network("100.64.0.0/10")
    except ValueError:
        private = False
    if not (hub.hostname and (hub.scheme == "https" or (hub.scheme == "http" and private))
            and not hub.username and not hub.password and not hub.query and not hub.fragment
            and hub.path in ["", "/"]):
        raise SystemExit("Use the private Fleet hub URL or HTTPS.")
    source = args.app.resolve(strict=True)
    if source == APP or source.suffix != ".app":
        raise SystemExit("Select the signed build to install.")
    verify(source)
    if keys_need_build(source):
        raise SystemExit(f"This Mac's vault configuration holds the owner's keys, which a Fleet Vault reads from build "
                         f"{OWNER_KEYS_BUILD} on, and the build to install is older. No change was made.")
    keep_configuration(worker_configuration(args, user))
    if APP.is_symlink():
        raise SystemExit("The installed app path must not be a symbolic link.")
    # Stage and verify the new app before stopping an existing helper.
    with tempfile.TemporaryDirectory(prefix=".FleetVault-install-", dir="/Applications") as temporary:
        staged = Path(temporary) / APP.name
        shutil.copytree(source, staged, symlinks=True)
        for relative in ["Contents/MacOS/FleetVault", "Contents/Helpers/age", "Contents/Helpers/age-keygen"]:
            program = staged / relative
            if program.is_symlink() or not program.is_file():
                raise SystemExit("The signed app is missing a required executable.")
            program.chmod(0o755)
        verify(staged)
        subprocess.run(["launchctl", "bootout", f"gui/{user.pw_uid}/{LABEL}"], capture_output=True)
        if APP.exists():
            shutil.rmtree(APP)
        staged.rename(APP)
    launch_folder = Path(user.pw_dir) / "Library/LaunchAgents"
    launch = launch_folder / (LABEL + ".plist")
    launch_data = plistlib.dumps({"Label": LABEL,
        "ProgramArguments": [str(APP / "Contents/MacOS/FleetVault")],
        "RunAtLoad": True, "KeepAlive": True, "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive", "ThrottleInterval": 10,
        "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"})
    def worker_identity():
        os.setgroups([])
        os.setgid(user.pw_gid)
        os.setuid(user.pw_uid)
    # Never write into an agent-controlled home as root.
    subprocess.run([sys.executable, "-c", """
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
p.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
with os.fdopen(fd, 'wb') as f:
    f.write(sys.stdin.buffer.read())
""", str(launch)], input=launch_data, preexec_fn=worker_identity, check=True)
    subprocess.run(["launchctl", "bootstrap", f"gui/{user.pw_uid}", str(launch)], check=True)
    print("Fleet Vault installed for " + args.agent + ". It opens this fleet's own store on this Mac and needs no "
          "setup: it makes the store key, the handover key and an empty store at its first request.")
    print("Check it as that worker: python3 fleet.py check " + args.agent)
    print("The worker's existing vault mode and credential files were not changed.")
    install_updater(args.fleet, args.channel, args.track)


if __name__ == "__main__":
    main()
