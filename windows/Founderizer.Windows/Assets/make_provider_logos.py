#!/usr/bin/env python3
"""Writes the logo of each AI provider beside this file (claude.png, codex.png, grok.png), byte for byte as the Mac and
iPhone apps hold them in app/Sources/FleetMark/ProviderLogo.swift: the icon of each provider's own Mac app at 128
pixels, which the panel beside a chat shows under "Runs on". The logos are their owners' marks: Founderizer shows them
only to name the provider. Run it again after ProviderLogo.swift changes; --check exits 1 when a copy is old.

    python3 app/windows/Founderizer.Windows/Assets/make_provider_logos.py [--check]
"""
import base64
import pathlib
import re
import sys

here = pathlib.Path(__file__).resolve().parent
swift = (here.parents[2] / "Sources" / "FleetMark" / "ProviderLogo.swift").read_text(encoding="utf-8")
files = {"claude.png": "claudeBytes", "codex.png": "chatGPTBytes", "grok.png": "grokBytes"}
old = []
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
