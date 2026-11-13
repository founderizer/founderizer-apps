#!/usr/bin/env python3
"""Which feature names of the hub's owner API have no line in PARITY.md (windows-app-plan.md, section 7).

    python3 app/windows/parity.py                 # the hub of this checkout, two folders up
    python3 app/windows/parity.py --hub PATH      # another hub.py

It reads the names from hub.py without running it: the list UI_FEATURES, and the names that ui_features() adds while a
switch is on. It prints each name that PARITY.md does not have, then each line of PARITY.md whose name the hub no longer
serves, and the count of each state. It is a report, not a gate: it ends with 0 whatever it finds, and with 2 only when
it cannot read one of the two files.
"""

import argparse
import ast
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LINE = re.compile(r"^\|\s*`([a-z0-9_]+)`\s*\|\s*([^|]+?)\s*\|")
STATES = ("built", "waits", "not planned")


def hub_features(path):
    """The feature names of one hub.py: UI_FEATURES in its order, then the ones that ui_features() adds."""
    text = open(path, encoding="utf-8").read()
    names = None
    for node in ast.parse(text).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "UI_FEATURES" for t in node.targets):
            names = [item.value for item in node.value.elts]
    if names is None:
        raise ValueError(f"{path} has no UI_FEATURES list")
    function = re.search(r"\ndef ui_features\(\):.*?\n(?=\S)", text, re.S)
    added = re.findall(r'\(\["([a-z0-9_]+)"\] if', function.group(0)) if function else []
    return names + [name for name in added if name not in names]


def parity_lines(path):
    """{feature name: its state} of PARITY.md's table, and the lines whose state is none of the three."""
    found, strange = {}, []
    for line in open(path, encoding="utf-8"):
        match = LINE.match(line)
        if not match:
            continue
        name, state = match.group(1), match.group(2).strip()
        found[name] = state
        if not any(state.startswith(s) for s in STATES):
            strange.append(name)
    return found, strange


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hub", default=os.path.join(HERE, "..", "..", "hub.py"), help="the hub.py to compare with")
    ap.add_argument("--parity", default=os.path.join(HERE, "PARITY.md"), help="the PARITY.md to read")
    args = ap.parse_args()
    try:
        features = hub_features(args.hub)
        lines, strange = parity_lines(args.parity)
    except (OSError, ValueError, SyntaxError) as e:
        print(f"cannot compare: {e}", file=sys.stderr)
        return 2
    missing = [name for name in features if name not in lines]
    gone = [name for name in lines if name not in features]
    print(f"{len(features)} feature names in the hub, {len(lines)} lines in PARITY.md")
    for name in missing:
        print(f"no line:            {name}")
    for name in gone:
        print(f"not in the hub:     {name}")
    for name in strange:
        print(f"no known state:     {name} ({lines[name]})")
    counts = {state: sum(1 for name in features if lines.get(name, "").startswith(state)) for state in STATES}
    print("  ".join(f"{state}: {count}" for state, count in counts.items()) + f"  no line: {len(missing)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
