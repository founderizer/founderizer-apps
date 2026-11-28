#!/usr/bin/env python3
"""Writes the logo of each AI provider and of each cloud provider beside this file, byte for byte as the Mac and iPhone
apps hold them: claude.png, codex.png and grok.png from app/Sources/FleetMark/ProviderLogo.swift (the icon of each
provider's own Mac app at 128 pixels, which the panel beside a chat shows under "Runs on"), opencode-mark.png from the same
file (OpenCode's mark on its tile, only for the mark of an AI session on a bubble: a name that is no runtime's, so that
the panel shows no new logo), and hetzner.png, digitalocean.png, vultr.png and akamai.png from
app/Sources/FleetMark/CloudLogo.swift (each provider's mark from Simple Icons in its own colour, which the first run's
VPS pages show on a white tile). The logos are their owners' marks: Founderizer shows them only to name the provider.
Run it again after either Swift file changes; --check exits 1 when a copy is old.

    python3 app/windows/Founderizer.Windows/Assets/make_provider_logos.py [--check]
"""
import base64
import pathlib
import re
import sys

here = pathlib.Path(__file__).resolve().parent
fleetmark = here.parents[2] / "Sources" / "FleetMark"
sources = {
    "ProviderLogo.swift": {"claude.png": "claudeBytes", "codex.png": "chatGPTBytes", "grok.png": "grokBytes",
                           "opencode-mark.png": "openCodeBytes"},
    "CloudLogo.swift": {"hetzner.png": "hetznerBytes", "digitalocean.png": "digitalOceanBytes", "vultr.png": "vultrBytes",
                        "akamai.png": "akamaiBytes"},
}
old = []
for source, files in sources.items():
    swift = (fleetmark / source).read_text(encoding="utf-8")
    for name, field in files.items():
        data = base64.b64decode(re.search(rf'static let {field} = "([^"]+)"', swift).group(1))
        target = here / name
        if "--check" in sys.argv[1:]:
            if not target.exists() or target.read_bytes() != data:
                old.append(name)
            continue
        target.write_bytes(data)
        print(target)
if "--check" in sys.argv[1:]:
    print("the logos are current" if not old else "old: " + ", ".join(old) + ": run make_provider_logos.py")
    sys.exit(1 if old else 0)
