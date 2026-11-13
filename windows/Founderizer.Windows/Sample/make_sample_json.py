#!/usr/bin/env python3
"""Writes SampleFleet.json beside this file: the sample fleet's reads as app/ios/Sources/SampleFleetData.swift holds
them, byte for byte. That Swift file is made by app/ios/make_sample.py from the hub's own code; the Windows app reads
the same reads through its library's decoders. Run it again after make_sample.py; --check exits 1 when the copy is old.

    python3 app/windows/Founderizer.Windows/Sample/make_sample_json.py [--check]
"""
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
swift = here.parents[2] / "ios" / "Sources" / "SampleFleetData.swift"
text = swift.read_text(encoding="utf-8")
start = text.index('#"""') + len('#"""')
end = text.index('"""#', start)
data = text[start:end].strip("\n") + "\n"
target = here / "SampleFleet.json"
if "--check" in sys.argv[1:]:
    same = target.exists() and target.read_text(encoding="utf-8") == data
    print("SampleFleet.json is current" if same else "SampleFleet.json is old: run make_sample_json.py")
    sys.exit(0 if same else 1)
target.write_text(data, encoding="utf-8")
print(target)
