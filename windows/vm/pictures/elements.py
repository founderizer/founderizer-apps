"""Checks one page of the Windows app, element by element, against a picture set's list (set8-elements.json): each word
of the picture's table is an element's name (or in one, for a line with a link), and each control that the list
measures has its place and its size. The page is a dump of elements.ps1, in the screen's own pixels.

    python3 -I elements.py set8-elements.json 02-help-improve page.tsv [--scale 2]

Prints one line for each check and exits 1 when one fails."""
import json
import sys


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
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    scale = float(sys.argv[sys.argv.index("--scale") + 1]) if "--scale" in sys.argv else 2.0
    spec_path, picture, dump = args[0], args[1], args[2]
    spec = json.load(open(spec_path, encoding="utf-8"))
    page = spec["pictures"][picture]
    common = spec["common"]
    rows = read(dump, scale)
    failed = 0

    def say(ok, what):
        nonlocal failed
        failed += 0 if ok else 1
        print(("pass  " if ok else "FAIL  ") + what)

    names = [r["name"] for r in rows if r["name"]]
    for words in page.get("words", []):
        say(words in names or any(words in n for n in names), f'the words "{words}"')

    for box in page.get("boxes", []):
        found = [r for r in rows if matches(r, box["match"])]
        if len(found) != 1:
            say(False, f'{box["match"]}: {len(found)} elements')
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
            say(abs(got - want) <= tol, f'{box["match"]} {key} {got:.1f}, set 8 {want} (±{tol})')

    for gone in page.get("absent", []):
        found = [r for r in rows if matches(r, gone)]
        say(not found, f"no element {gone}")

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
        n = len(steps["names"])
        for i, name in enumerate(steps["names"]):
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
