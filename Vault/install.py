#!/usr/bin/env python3
"""Install the signed Mac vault. Never read or migrate a credential."""
import argparse
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
WRITER_LABEL = "com.agentfleet.vault.writer"         # the owner's Mac: the writer of the app's Add secret
WRITER_SERVICE = "local.agent-fleet.vault.writer"
REQUIREMENT = 'anchor apple generic and certificate leaf[subject.OU] = "6EBZ756H9Q" and identifier "local.agent-fleet.vault"'
# The vault's own updater (update.zsh): root, from a daemon, at load and every hour.
UPDATER = CONFIG.parent / "update.zsh"
UPDATE_SETTINGS = CONFIG.parent / "update.json"     # the channel, the fleet's id and its track: no secret
TRACKS = ("approved", "early")                       # PRODUCT.md 4.3, "the two tracks"; update.zsh reads which
UPDATE_LABEL = "com.agentfleet.vault.update"
UPDATE_DAEMON = Path("/Library/LaunchDaemons") / (UPDATE_LABEL + ".plist")
UPDATE_LOG = CONFIG.parent / "update.log"           # in the protected folder: /Library/Logs is the admin group's
CHANNEL = "https://founderizer.com"


def store_keys(args):
    """Which store the vault opens, as the configuration names it: the fleet's own encrypted file on this Mac
    (`store`), or a Bitwarden Secrets Manager project (`region`). Never both, because then no answer would say which
    one holds a login (vault.py reads its own configuration the same way)."""
    return {"store": "fleet"} if args.store else {"region": args.region}


def keep_configuration(configuration, switch):
    """Write the configuration, or keep the one that is there. A configuration that differs only in its store is
    replaced when the owner asked for that switch: the vault then opens the other store and **reaches none of the
    items of the first one** — no value is moved, and the owner adds each secret again. Any other difference stops
    the install, as before."""
    if not (CONFIG.exists() or CONFIG.is_symlink()):
        protected(CONFIG.parent.parent)
        CONFIG.parent.mkdir(mode=0o755, exist_ok=True)
        protected(CONFIG.parent)
        with CONFIG.open("x") as handle:
            json.dump(configuration, handle)
        CONFIG.chmod(0o644)
        protected(CONFIG)
        return False
    protected(CONFIG)
    current = json.loads(CONFIG.read_text())
    if current == configuration:
        return False
    def without_store(one):
        return {k: v for k, v in one.items() if k not in ("region", "store")}
    if not (switch and without_store(current) == without_store(configuration)):
        raise SystemExit("An existing vault has different settings. No change was made.")
    # Written beside the old one and then put in its place, so a failure leaves the vault as it was.
    nxt = CONFIG.parent / (CONFIG.name + ".new")
    with nxt.open("w") as handle:
        json.dump(configuration, handle)
    nxt.chmod(0o644)
    nxt.replace(CONFIG)
    protected(CONFIG)
    return True


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


def install_writer(args, user):
    """The owner's Mac: the same signed app, an owner configuration and one LaunchAgent that starts the app's writer
    mode for its Mach service. No worker, no socket and no worker LaunchAgent. No token is read or written here."""
    if user.pw_uid < 500:
        raise SystemExit("Select the owner's local user.")
    fleet = args.fleet_app
    if not fleet.is_absolute() or fleet.suffix != ".app" or fleet.is_symlink() or not fleet.is_dir() or "\0" in str(fleet):
        raise SystemExit("Give the full path of the Founderizer app that may use the writer.")
    source = args.app.resolve(strict=True)
    if source == APP or source.suffix != ".app":
        raise SystemExit("Select the signed build to install.")
    verify(source)
    configuration = {"role": "owner", **store_keys(args), "fleet_app": str(fleet), "owner_uid": user.pw_uid}
    switched = keep_configuration(configuration, args.switch_store)
    if APP.is_symlink():
        raise SystemExit("The installed app path must not be a symbolic link.")
    with tempfile.TemporaryDirectory(prefix=".FleetVault-install-", dir="/Applications") as temporary:
        staged = Path(temporary) / APP.name
        shutil.copytree(source, staged, symlinks=True)
        for relative in ["Contents/MacOS/FleetVault", "Contents/Helpers/age", "Contents/Helpers/age-keygen"]:
            program = staged / relative
            if program.is_symlink() or not program.is_file():
                raise SystemExit("The signed app is missing a required executable.")
            program.chmod(0o755)
        verify(staged)
        subprocess.run(["launchctl", "bootout", f"gui/{user.pw_uid}/{WRITER_LABEL}"], capture_output=True)
        if APP.exists():
            shutil.rmtree(APP)
        staged.rename(APP)
    launch = Path(user.pw_dir) / "Library/LaunchAgents" / (WRITER_LABEL + ".plist")
    # launchd starts the writer only when Fleet connects to its service. It has no window and no socket.
    launch_data = plistlib.dumps({"Label": WRITER_LABEL,
        "ProgramArguments": [str(APP / "Contents/MacOS/FleetVault"), "writer"],
        "MachServices": {WRITER_SERVICE: True}, "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive", "ThrottleInterval": 10,
        "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"})
    write_launch_agent(user, launch, launch_data)
    subprocess.run(["launchctl", "bootstrap", f"gui/{user.pw_uid}", str(launch)], check=True)
    if args.store:
        print("Fleet Vault installed as the writer of Fleet's Add secret. It keeps this fleet's own store on this Mac "
              "and needs no token: add a secret in Founderizer.")
    else:
        print("Fleet Vault installed as the writer of Fleet's Add secret. Open its window to enter the Bitwarden write token and the project ID.")
    if switched:
        print("The store was switched. No value was moved: the items of the other store are not reachable, so add "
              "each secret again and register the new reference.")
    install_updater(args.fleet, args.channel, args.track)


def write_launch_agent(user, launch, launch_data):
    def owner_identity():
        os.setgroups([])
        os.setgid(user.pw_gid)
        os.setuid(user.pw_uid)
    # Never write into a user-controlled home as root.
    subprocess.run([sys.executable, "-c", """
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
p.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
with os.fdopen(fd, 'wb') as f:
    f.write(sys.stdin.buffer.read())
""", str(launch)], input=launch_data, preexec_fn=owner_identity, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="The signed build to install. Not with --updater-only.")
    parser.add_argument("--user", help="The local user that runs the vault. Not with --updater-only.")
    parser.add_argument("--agent")
    parser.add_argument("--hub")
    parser.add_argument("--region", choices=["eu", "us"],
                        help="The Bitwarden region of the project that this vault opens. Not with --store.")
    parser.add_argument("--store", action="store_true",
                        help="This vault opens the fleet's own store: one locked file of the helper on this Mac, with "
                             "no Bitwarden account. The helper makes its key and an empty store itself.")
    parser.add_argument("--switch-store", action="store_true",
                        help="With --store or --region on a Mac whose vault already opens the other store: change it. "
                             "No value is moved and the items of the other store are then unreachable.")
    parser.add_argument("--owner", action="store_true",
                        help="The owner's Mac, which has no worker: install the writer of Fleet's Add secret.")
    parser.add_argument("--fleet-app", type=Path, help="With --owner: the Founderizer app that may use the writer.")
    parser.add_argument("--fleet", help="The fleet's id: the 16 hex characters that the release channel knows it by "
                                        "(the hub's GET /ui/releases, entitlement.fleet). The vault's updater sends it.")
    parser.add_argument("--channel", default=CHANNEL, help="The release channel that the updater reads.")
    parser.add_argument("--track", choices=TRACKS, default="approved",
                        help="The fleet's release track, which the updater reads: early only for a fleet whose setting "
                             "releases.early is on (the hub's GET /ui/releases, early), which takes each vault build as "
                             "it is published; approved, the default, takes only the builds that the owner approved.")
    parser.add_argument("--updater-only", action="store_true",
                        help="Only the vault's updater, on a Mac whose vault is installed already: no app and no "
                             "configuration change. The updater then puts the newest vault in place within the hour.")
    args = parser.parse_args()
    if not (args.fleet and re.fullmatch(r"[0-9a-f]{16}", args.fleet)):
        parser.error("--fleet takes the fleet's id: 16 lowercase hex characters")
    if not re.fullmatch(r"https://[a-z0-9.-]+", args.channel):
        parser.error("--channel takes https://<host> and nothing after it")
    if args.updater_only:
        if any([args.app, args.user, args.agent, args.hub, args.region, args.store, args.switch_store, args.owner,
                args.fleet_app]):
            parser.error("--updater-only takes --fleet, --channel and --track, and nothing else")
        if os.geteuid() != 0:
            raise SystemExit("Run this installer with sudo.")
        if not CONFIG.is_file():
            raise SystemExit("This Mac has no Fleet Vault configuration: install the vault first.")
        install_updater(args.fleet, args.channel, args.track)
        return
    if not args.app or not args.user:
        parser.error("--app and --user are required, except with --updater-only")
    if bool(args.store) == bool(args.region):
        parser.error("name one store: --store (the fleet's own) or --region (a Bitwarden project), never both")
    if args.owner:
        if args.agent or args.hub or not args.fleet_app:
            parser.error("--owner takes --app, --user, one store and --fleet-app, and no --agent or --hub")
    elif not args.agent or not args.hub or args.fleet_app:
        parser.error("a worker Mac needs --agent and --hub, and no --fleet-app")
    if os.geteuid() != 0:
        raise SystemExit("Run this installer with sudo on the worker Mac." if not args.owner else
                         "Run this installer with sudo on the owner's Mac.")
    user = pwd.getpwnam(args.user)
    if args.owner:
        install_writer(args, user)
        return
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
    configuration = {"agent": args.agent, "hub": args.hub.rstrip("/"), **store_keys(args),
                     "worker_uid": user.pw_uid,
                     "socket": user.pw_dir + "/Library/Application Support/AgentFleet/vault.sock"}
    switched = keep_configuration(configuration, args.switch_store)
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
    if args.store:
        print("Fleet Vault installed for " + args.agent + ". It opens this fleet's own store on this Mac and needs no "
              "token: it makes the store key, the handover key and an empty store at its first request.")
        print("Check it as that worker: python3 fleet.py check " + args.agent)
    else:
        print("Fleet Vault installed for " + args.agent + ". Open its window to enter the token and import the handover key.")
    print("The worker's existing vault mode and credential files were not changed.")
    if switched:
        print("The store was switched. No value was moved: the items of the other store are not reachable, so the "
              "owner adds each secret again and the hub gets the new reference.")
    install_updater(args.fleet, args.channel, args.track)


if __name__ == "__main__":
    main()
