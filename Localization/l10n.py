#!/usr/bin/env python3
"""The table of the apps' words: its keys, its check and its build step (README.md in this folder).

  python3 Localization/l10n.py keys [--ios]     # the compiler's keys of the shown words (.build/l10n/keys.json)
  python3 Localization/l10n.py sync [--ios]     # the same, then add each new key to the catalog, drop each key no code uses
  python3 Localization/l10n.py check [--ios]    # the same, then: every key has its words, with the English values
  python3 Localization/l10n.py compile <dir>    # the shipped languages' tables into an app's Contents/Resources

Each command builds the Mac app in `.build/l10n` (its own folder, which stays, so a second run compiles only what
changed). `--ios` also builds the iPhone app for the simulator; without it the iPhone's keys of the last `--ios` run
are kept.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
APP = HERE.parent
CATALOG = HERE / "Localizable.xcstrings"
SHIPPED = HERE / "shipped"
KEYS = APP / ".build" / "l10n" / "keys.json"     # a build product, never in git
# A key of its own for one meaning of a word ("Off (a server)") has its English text apart: {key: English}.
ENGLISH = APP / ".build" / "l10n" / "english.json"
# The folders whose words a person sees in the Mac app and the iPhone app.
MAC_SOURCES = ("Sources/Founderizer/", "Sources/FleetCore/", "Sources/FleetMark/")
IOS_SOURCES = ("ios/Sources/",)
LANGUAGES = ("es",)        # the languages that the catalog holds, shipped or not
SOURCE = "en"
# A key that only Windows uses has a comment that starts with this word, so no Swift code needs it.
WINDOWS = "Windows:"

SPEC = re.compile(r"%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDuUxXoOfeEgGcCsSpaAF%])")


def shipped():
    """The languages that a build carries: one code on each line of `shipped`, with `#` lines left out."""
    if not SHIPPED.exists():
        return []
    codes = [line.split("#")[0].strip() for line in SHIPPED.read_text().splitlines()]
    return [code for code in codes if code]


def values(text):
    """The values of a format, in the order that they go in: `[('1', '@'), ...]` (`%%` is no value)."""
    found, place = [], 0
    for match in SPEC.finditer(text):
        if match.group(2) == "%":
            continue
        place += 1
        kind = match.group(2).lower()
        kind = "d" if kind in "duxo" else kind
        found.append((match.group(1) or str(place), kind))
    return sorted(found)


def wordy(key):
    """A key with a word in it, not only values and marks."""
    return re.search(r"[^\W\d_]", SPEC.sub("", key)) is not None


def load():
    return json.loads(CATALOG.read_text()) if CATALOG.exists() else {"sourceLanguage": SOURCE, "strings": {}, "version": "1.0"}


def save(catalog):
    # Xcode's own layout, so that its editor and this script write the same file.
    text = json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True, separators=(",", " : "))
    CATALOG.write_text(text + "\n")


def units(entry, language):
    """Every text of one language in an entry: its one unit, or each plural or device form."""
    local = entry.get("localizations", {}).get(language)
    if not local:
        return []
    out = []

    def walk(node):
        if "stringUnit" in node:
            out.append(node["stringUnit"].get("value", ""))
        for forms in node.get("variations", {}).values():
            for form in forms.values():
                walk(form)
    walk(local)
    return out


def build_keys(ios=False):
    """The keys that the compiler finds in the shown words: {key: [file:line, ...]}."""
    found, english = {}, {}
    # A build folder of its own that stays, so a second run compiles only the changed files. The compiler writes a
    # file's keys only when it compiles that file, so the key files stay too; a file whose source is gone is left out.
    scratch = APP / ".build" / "l10n"
    out = scratch / "strings"
    out.mkdir(parents=True, exist_ok=True)
    flags = ["-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(out)]
    subprocess.run(["swift", "build", "--package-path", str(APP), "--scratch-path", str(scratch / "build"),
                    "--product", "Founderizer", *flags], check=True)
    files = list(out.glob("*.stringsdata"))
    if ios:
        derived = scratch / "ios"
        subprocess.run(["xcodebuild", "-project", str(APP / "ios/FleetMobile.xcodeproj"), "-scheme", "FleetMobile",
                        "-sdk", "iphonesimulator", "-configuration", "Debug", "-derivedDataPath", str(derived),
                        "CODE_SIGNING_ALLOWED=NO", "build", "-quiet"], check=True)
        files += list(derived.rglob("*.stringsdata"))
    seen = set()
    for path in files:
        data = json.loads(path.read_text())
        source = pathlib.Path(data.get("source", ""))
        if not source.exists():
            continue
        try:
            where = source.resolve().relative_to(APP).as_posix()
        except ValueError:
            continue
        if not where.startswith(MAC_SOURCES + IOS_SOURCES) or where in seen:
            continue
        seen.add(where)
        for table, rows in data.get("tables", {}).items():
            if table != "Localizable":
                continue
            for row in rows:
                found.setdefault(row["key"], []).append(f"{where}:{row['location']['startingLine']}")
                if row.get("value") and row["value"] != row["key"]:
                    english[row["key"]] = row["value"]
    ENGLISH.write_text(json.dumps(english, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
    return {key: sorted(set(places)) for key, places in sorted(found.items())}


def problems(catalog, keys, languages, english=None):
    """Each fault, as (language or "", line). `languages` are the ones to check. `english` gives the English text of a
    key that has its own ("Off (a server)" → "Off"); every other key is its English text."""
    english = english or {}
    out = []
    strings = catalog.get("strings", {})
    for key, places in keys.items():
        if re.search(r"%(?:\d+\$)?l?[fFeEgGaA]", english.get(key, key)):
            out.append(("", f"a Double goes into the lookup as %f, which writes 1.500000; make it a String first: {key!r} at {places[0]}"))
    for key in keys:
        if not wordy(english.get(key, key)):
            continue        # only values and marks ("%@ · %@"): the same in every language
        entry = strings.get(key)
        for language in languages:
            if not entry or not [text for text in units(entry, language) if text.strip()]:
                out.append((language, f"no {language} words: {key!r} at {keys[key][0]}"))
    for key, entry in strings.items():
        if key not in keys and not entry.get("comment", "").startswith(WINDOWS):
            out.append(("", f"no code shows it any more: {key!r}"))
        want = values(english.get(key, key))
        for language in languages + [SOURCE]:
            for text in units(entry, language):
                if text and values(text) != want:
                    out.append((language, f"the {language} words have other values than the key: {key!r} → {text!r}"))
    return out


def command_keys(args):
    keys = build_keys(ios="--ios" in args)
    if "--ios" not in args and KEYS.exists():
        # A Mac-only run keeps the iPhone's own keys of the last run with --ios.
        for key, places in json.loads(KEYS.read_text()).items():
            ios = [p for p in places if p.startswith(IOS_SOURCES)]
            if ios:
                keys[key] = sorted(set(keys.get(key, []) + ios))
    KEYS.write_text(json.dumps(dict(sorted(keys.items())), indent=1, ensure_ascii=False) + "\n")
    print(f"{len(keys)} keys")


def command_sync(args):
    command_keys(args)
    keys = json.loads(KEYS.read_text())
    catalog = load()
    strings = catalog.setdefault("strings", {})
    added = [key for key in keys if key not in strings]
    for key in added:
        strings[key] = {}
    gone = [key for key, entry in strings.items() if key not in keys and not entry.get("comment", "").startswith(WINDOWS)]
    for key in gone:
        del strings[key]
    save(catalog)
    print(f"{len(added)} keys added, {len(gone)} keys removed, {len(strings)} in the catalog")


def command_check(args):
    command_keys(args)
    keys = json.loads(KEYS.read_text())
    catalog = load()
    live = shipped()
    found = problems(catalog, keys, list(LANGUAGES), json.loads(ENGLISH.read_text()) if ENGLISH.exists() else {})
    for language, line in found:
        print(("FAULT " if not language or language in live else "todo  ") + line)
    faults = [line for language, line in found if not language or language in live]
    todo = len(found) - len(faults)
    print(f"{len(keys)} keys; {len(faults)} faults; {todo} words still to write in languages that no build carries yet")
    return 1 if faults else 0


def command_compile(args):
    if len(args) != 1:
        sys.exit("usage: l10n.py compile <Contents/Resources of an app>")
    languages = shipped()
    if not languages:
        return 0        # no language ships yet: the app is the same as before the table
    resources = pathlib.Path(args[0])
    with tempfile.TemporaryDirectory(prefix="l10n-") as scratch:
        subprocess.run(["xcrun", "xcstringstool", "compile", str(CATALOG), "--output-directory", scratch], check=True)
        for language in [SOURCE] + languages:
            built = pathlib.Path(scratch) / f"{language}.lproj"
            target = resources / f"{language}.lproj"
            if target.exists():
                shutil.rmtree(target)
            if built.exists():
                shutil.copytree(built, target)
            else:
                target.mkdir(parents=True)   # English with no plural forms still names its folder
    return 0


def main(argv):
    commands = {"keys": command_keys, "sync": command_sync, "check": command_check, "compile": command_compile}
    if not argv or argv[0] not in commands:
        sys.exit(__doc__)
    return commands[argv[0]](argv[1:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
