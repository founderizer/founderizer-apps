#!/usr/bin/env python3
"""Build the standalone Mac vault. Download pinned vendor sources; never read a vault credential."""
import hashlib
import io
import os
from pathlib import Path
import platform
import plistlib
from datetime import datetime, timezone
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "build/vault-dependencies"
REV = "0520690b9710af7a8b1e47aad776f002f369688f"  # Bitwarden SDK 2.1.0
SDK_SHA = "bc605f4a9b2dd1d4dfdfcb558d2c421cf6d74a87e6bb234ffe1a8176e85497bf"
AGE_SHA = {"arm64": "e2020b073c44f692685a24d6abc378817eb81ffaaf49fd0531ef8565f767f2f5",
           "amd64": "1d1e4bc66e1427edad7739ae7616157de0e79db8b6d2a1497d7d9925fb06a539"}
# The Developer ID Application identity that signs the vault, as `security find-identity -v -p codesigning` prints
# it. release.sh passes its own.
SIGNER = os.environ.get("FLEET_SIGN_IDENTITY", "")


def fetch(url, digest):
    with urllib.request.urlopen(url, timeout=60) as response:
        payload = response.read()
    if hashlib.sha256(payload).hexdigest() != digest:
        raise SystemExit("The vendor archive checksum does not match.")
    return payload


def run(*args, cwd=ROOT):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    if platform.system() != "Darwin" or not shutil.which("cargo"):
        raise SystemExit("Build on macOS with Rust 1.88 or later, Swift and a Developer ID signing identity.")
    if not SIGNER:
        raise SystemExit("Set FLEET_SIGN_IDENTITY to the Developer ID Application identity that signs the vault.")
    profile_path = os.environ.get("FLEET_VAULT_PROFILE")
    if not profile_path:
        raise SystemExit("Set FLEET_VAULT_PROFILE to the Apple Developer ID profile for local.agent-fleet.vault.")
    profile = Path(profile_path).resolve()
    decoded = subprocess.run(["security", "cms", "-D", "-i", str(profile)], capture_output=True, check=True)
    metadata = plistlib.loads(decoded.stdout)
    allowed = metadata.get("Entitlements", {})
    identifier = "6EBZ756H9Q.local.agent-fleet.vault"
    groups = allowed.get("keychain-access-groups", [])
    if not ("OSX" in metadata.get("Platform", []) and metadata.get("ExpirationDate", datetime.min).replace(tzinfo=timezone.utc) > datetime.now(timezone.utc)
            and allowed.get("com.apple.application-identifier") == identifier
            and allowed.get("com.apple.developer.team-identifier") == "6EBZ756H9Q"
            and not allowed.get("get-task-allow", False)
            and (identifier in groups or "6EBZ756H9Q.*" in groups)):
        raise SystemExit("The profile does not authorize this helper's private Keychain group for distribution.")
    CACHE.mkdir(parents=True, exist_ok=True)
    source = CACHE / ("sdk-sm-" + REV)
    # Extract the pinned source again, so edits in the build cache cannot enter a signed release.
    with tarfile.open(fileobj=io.BytesIO(fetch("https://codeload.github.com/bitwarden/sdk-sm/tar.gz/" + REV, SDK_SHA))) as archive:
        archive.extractall(CACHE, filter="data")
    ffi = source / "crates/bitwarden-c/src/lib.rs"
    ffi.write_text(ffi.read_text() + (ROOT / "Vault/ffi-memory.rs").read_text())
    run("cargo", "build", "--locked", "--release", "-p", "bitwarden-c", cwd=source)
    architecture = "arm64" if platform.machine() == "arm64" else "amd64"
    with tarfile.open(fileobj=io.BytesIO(fetch(
            f"https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-darwin-{architecture}.tar.gz",
            AGE_SHA[architecture]))) as archive:
        archive.extractall(CACHE, filter="data")
    run("swift", "build", "-c", "release", "--product", "FleetVault")
    app = ROOT / "build/Fleet Vault.app"
    for directory in ["MacOS", "Frameworks", "Helpers", "Resources"]:
        (app / "Contents" / directory).mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / ".build/release/FleetVault", app / "Contents/MacOS/FleetVault")
    shutil.copy2(ROOT / "Vault/Info.plist", app / "Contents/Info.plist")
    shutil.copy2(profile, app / "Contents/embedded.provisionprofile")
    library = app / "Contents/Frameworks/libbitwarden_c.dylib"
    shutil.copy2(source / "target/release/libbitwarden_c.dylib", library)
    shutil.copy2(source / "LICENSE", app / "Contents/Resources/Bitwarden-LICENSE")
    shutil.copy2(CACHE / "age/LICENSE", app / "Contents/Resources/age-LICENSE")
    # The Mac's root updater replaces itself with the one that a vault it has checked carries (Vault/update.zsh).
    shutil.copy2(ROOT / "Vault/update.zsh", app / "Contents/Resources/update.zsh")
    # Its installer rides along beside it, sealed by the same signature: a Mac's join line (the fleet's join.sh) checks
    # this vault and runs the install.py that it carries as root, with the update.zsh that install_updater needs.
    shutil.copy2(ROOT / "Vault/install.py", app / "Contents/Resources/install.py")
    # The starter that the updater puts in place on an agents' Mac (Vault/starter.zsh), sealed by the same signature.
    shutil.copy2(ROOT / "Vault/starter.zsh", app / "Contents/Resources/starter.zsh")
    for name in ["age", "age-keygen"]:
        target = app / "Contents/Helpers" / name
        shutil.copy2(CACHE / "age" / name, target)
        run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", SIGNER, str(target))
    # Library validation remains enabled. All executable code has the same Developer ID.
    run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", SIGNER, str(library))
    run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", SIGNER,
        "--entitlements", str(ROOT / "Vault/Entitlements.plist"), str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    print(app)


if __name__ == "__main__":
    main()
