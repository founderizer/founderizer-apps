"""Checks one page of the Windows app, element by element, against a picture set's list (set8-elements.json): each word
of the picture's table is the whole name of a text, a button, a link or a field, and each control that the list
measures has its place and its size. The page is a dump of elements.ps1, in the screen's own pixels.

    python3 -I elements.py set8-elements.json 02-help-improve page.tsv [--scale 2] [host=10.0.2.2 ...]

A word is found only as the whole name of such an element: a line with a link is listed whole, and its link as an
element of its own ({"name": "Privacy", "type": "Hyperlink"}); a word that is a part of a longer name, or a page's own
automation name, is not found. Words of the picture's example data that a proof's stand-in gives otherwise (a server's
address, its system) are written {name} in the list, with the picture's own value in its "data"; name=value on the
command line gives the proof's.

Prints one line for each check and exits 1 when one fails."""
import json
import sys

# The kinds of element whose whole name is a word of the page (not a group's, a pane's or the window's name).
WORDED = {"Text", "Button", "Hyperlink", "Edit"}


def read(path, scale):
    rows = []
    for line in open(path, encoding="utf-8-sig"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 7:
            continue
        kind, ident, x, y, w, h, name = parts[:7]
        rows.append({"type": kind, "id": ident, "x": float(x) / scale, "y": float(y) / scale,
                     "w": float(w) / scale, "h": float(h) / scale, "name": name})
    return rows


def matches(row, want):
    return all(row.get(key) == value for key, value in want.items())


def main():
    argv = sys.argv[1:]
    scale = 2.0
    if "--scale" in argv:
        at = argv.index("--scale")
        scale = float(argv[at + 1])
        del argv[at:at + 2]
    given = dict(a.split("=", 1) for a in argv if "=" in a)
    spec_path, picture, dump = [a for a in argv if "=" not in a][:3]
    spec = json.load(open(spec_path, encoding="utf-8"))
    page = spec["pictures"][picture]
    common = spec["common"]
    data = {**spec.get("data", {}), **given}
    rows = read(dump, scale)
    failed = 0

    def say(ok, what):
        nonlocal failed
        failed += 0 if ok else 1
        print(("pass  " if ok else "FAIL  ") + what)

    def fill(value):
        if not isinstance(value, str):
            return value
        for name, words in data.items():
            value = value.replace("{" + name + "}", words)
        return value

    def filled(want):
        return {key: fill(value) for key, value in want.items()}

    for entry in page.get("words", []):
        want = filled({"name": entry} if isinstance(entry, str) else entry)
        kinds = {want["type"]} if "type" in want else WORDED
        found = any(r["name"] == want["name"] and r["type"] in kinds for r in rows)
        say(found, f'the words "{want["name"]}"' + (f' ({want["type"]})' if "type" in want else ""))

    for box in page.get("boxes", []):
        match = filled(box["match"])
        found = [r for r in rows if matches(r, match)]
        if len(found) != 1:
            say(False, f'{match}: {len(found)} elements')
            continue
        r = found[0]
        tol = box.get("tol", 1.5)
        checks = []
        for key in ("x", "y", "w", "h"):
            if key in box:
                checks.append((key, r[key], box[key]))
        if "cx" in box:
            checks.append(("cx", r["x"] + r["w"] / 2, box["cx"]))
        for key, got, want in checks:
            say(abs(got - want) <= tol, f'{match} {key} {got:.1f}, set 8 {want} (±{tol})')

    # The room between two elements, one over the other: from the lower edge of the first to the upper edge of the second.
    for gap in page.get("gaps", []):
        above = [r for r in rows if matches(r, filled(gap["above"]))]
        below = [r for r in rows if matches(r, filled(gap["below"]))]
        if len(above) != 1 or len(below) != 1:
            say(False, f'the gap {filled(gap["above"])} to {filled(gap["below"])}: {len(above)} and {len(below)} elements')
            continue
        got = below[0]["y"] - (above[0]["y"] + above[0]["h"])
        tol = gap.get("tol", 1.5)
        say(abs(got - gap["gap"]) <= tol,
            f'the gap {filled(gap["above"])} to {filled(gap["below"])} {got:.1f}, set 8 {gap["gap"]} (±{tol})')

    for gone in page.get("absent", []):
        found = [r for r in rows if matches(r, filled(gone))]
        say(not found, f"no element {filled(gone)}")

    if page.get("back", True):
        back = common["back"]
        say(any(matches(r, back["match"]) for r in rows), "Back")
        t = back["text"]
        texts = [r for r in rows if r["type"] == "Text" and r["name"] == t["name"] and r["y"] < 120]
        ok = len(texts) == 1 and abs(texts[0]["x"] - t["x"]) <= t["tol"] and abs(texts[0]["y"] - t["y"]) <= t["tol"]
        say(ok, f'Back\'s words at {t["x"]}, {t["y"]}: ' + (f'{texts[0]["x"]:.1f}, {texts[0]["y"]:.1f}' if texts else "none"))
    else:
        say(not any(r["id"] == common["back"]["match"]["id"] for r in rows), "no Back")

    if page.get("steps", True) and "at" in page:
        steps = common["steps"]
        # The first run's six steps, or a page's own (the manager's setup: step_names).
        names = page.get("step_names", steps["names"])
        n = len(names)
        for i, name in enumerate(names):
            found = [r for r in rows if r["type"] == "Text" and r["name"] == name and r["y"] < 130]
            if len(found) != 1:
                say(False, f'the step "{name}": {len(found)} elements')
                continue
            r = found[0]
            centre = r["x"] + r["w"] / 2
            lo = 720 + (i - (n - 1) / 2) * steps["step"][0]
            hi = 720 + (i - (n - 1) / 2) * steps["step"][1]
            ok = min(lo, hi) - steps["tol"] <= centre <= max(lo, hi) + steps["tol"] and abs(r["y"] - steps["top"]) <= steps["tol"]
            say(ok, f'the step "{name}" at {centre:.1f}, {r["y"]:.1f}')
    elif not page.get("steps", True):
        say(not any(r["type"] == "Text" and r["name"] == "Manager" and r["y"] < 130 for r in rows), "no steps")

    print(f"{picture}: {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
