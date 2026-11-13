#!/usr/bin/env python3
"""The shared test vectors of the apps: inputs and expected bytes that Python makes with the hub's own code, and that
the Swift tests (Tests/FleetCoreTests/SharedVectorsTests.swift) and the C# tests (windows/Founderizer.Core.Tests) read.

    python3 app/vectors/make_vectors.py              # write the vector files beside this script
    python3 app/vectors/make_vectors.py --check      # make them in memory; end with 1 when a committed file differs
    python3 app/vectors/make_vectors.py --into DIR   # write them into another folder
    python3 app/vectors/make_vectors.py --no-swift   # only the files that Python makes

Two files come from the Swift code itself, because the rule that they hold is Swift's: `agent-marks.json` (FleetMark's
marks, by Tests/FleetMarkTests/MarkVectorsTests.swift) and `swift-words.json` (FleetCore's words, by
Tests/FleetCoreTests/WordsVectorsTests.swift). The maker runs those two tests with FOUNDERIZER_VECTORS_OUT set to a
temporary folder (`swift test`, so a first build takes minutes), and writes or compares what they wrote. Without that
variable, each of the two tests holds the committed file equal to what the Swift code gives.

Each vector is made with the code that checks it on the hub's side: the canonical text with `vault.canonical`, the
owner's signature with the P-256 arithmetic and the strict DER reading of `vault.py` (`owner_signed`), the release
manifests with the Ed25519 of `releases.py` and the line formats of `releases.signed_text` and `autopublish.app_text`,
and the device binding with the shape check of `hub.device_signing`. Each vector is checked with that code before it
is written, so a file here is never something that the hub would read otherwise.

Nothing is random: every key comes from a fixed label, and the P-256 signature takes its nonce by RFC 6979. So a run
writes the same bytes each time, and `--check` proves that the committed files are what the hub's code makes now.

The keys here are test keys of this file and sign nothing else. The values are examples (example.com, `app-1`).
This script needs the hub's checkout (`hub.py`, `vault.py`, `releases.py`, `autopublish.py` two folders up), so it runs
in the private repository and not in the public copy of the apps, which carries only the files that it wrote.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MADE_BY = "app/vectors/make_vectors.py"


def hub_code():
    """The hub's modules, from the checkout two folders up."""
    if not all(os.path.isfile(os.path.join(ROOT, name)) for name in ("hub.py", "vault.py", "releases.py",
                                                                      "autopublish.py")):
        sys.exit(f"{MADE_BY} makes the vectors with the hub's own code, and {ROOT} has no hub.py, vault.py, "
                 "releases.py and autopublish.py: run it in the private repository")
    sys.path.insert(0, ROOT)
    import autopublish  # noqa: E402
    import hub  # noqa: E402
    import releases  # noqa: E402
    import vault  # noqa: E402
    return hub, vault, releases, autopublish


def label_bytes(label):
    """32 bytes that a fixed label gives: the source of every key and value here."""
    return hashlib.sha256(("founderizer vectors: " + label).encode()).digest()


def b64(data):
    return base64.b64encode(data).decode()


def b64url(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


# ---------------------------------------------------------------- the canonical text

def canonical_cases(vault):
    """Each character class that the .NET writer gets wrong (windows-app-probes/dotnet-crypto-probe.txt), and the
    rules of the form itself: the key order by code point, the escapes, numbers, and nested values. `flat` marks the
    objects of text and whole numbers that fit in 64 bits, which is all that the Swift writer (OwnerStatement) takes."""
    big = 2 ** 63 - 1
    cases = [
        ("ascii", True, {"a": "plain words", "n": 7}),
        ("e-acute and other Latin letters", True, {"text": "caf\u00e9 na\u00efve \u00c5ngstr\u00f6m"}),
        ("the characters a web encoder escapes", True, {"text": "<a&b> 'x' + `y` = /z/"}),
        ("the line and paragraph separators", True, {"text": "one\u2028two\u2029three"}),
        ("delete and the C1 controls", True, {"text": "\u007f \u0080 \u0085 \u009f"}),
        ("the controls below U+0020", True, {"text": "".join(chr(c) for c in range(0x20))}),
        ("quote and backslash", True, {"text": "say \"hi\" \\ there"}),
        ("characters outside the BMP", True, {"text": "\U0001f600 \U00010000 \U0010ffff"}),
        ("invisible and combining characters", True, {"text": "e\u0301 \u200b \u200d \ufeff \u00a0"}),
        ("scripts of other directions", True, {"text": "\u4e2d\u6587 \u0639\u0631\u0628\u064a \u05e2\u05d1\u05e8\u05d9\u05ea"}),
        ("the edges of the surrogate range", True, {"text": "\ud7ff \ue000 \uffff \ufffd"}),
        ("keys in code point order", True, {"\uffff": 1, "\U00010000": 2, "a": 3, "B": 4, "\u00e9": 5, "": 6,
                                             "aa": 7, "a\u0000": 8}),
        ("whole numbers", True, {"zero": 0, "negative": -42, "largest": big, "smallest": -big - 1}),
        ("an owner statement", True, {"v": 1, "kind": "owner-device", "fleet": "0123456789abcdef", "device": "pc",
                                      "key": b64(b"\x04" + bytes(range(64))), "at": 1790000000}),
        ("an empty object", False, {}),
        ("a number past 64 bits", False, {"n": 123456789012345678901234567890, "m": -(2 ** 64)}),
        ("numbers with a fraction, as Python's repr writes them", False,
         {"half": 0.5, "third": 1 / 3, "one": 1.0, "minus zero": -0.0, "e15": 1e15, "e16": 1e16, "e17": 1.2345678901234568e17,
          "ten thousandth": 1e-4, "hundred thousandth": 1e-5, "tiny": 5e-324, "largest": 1.7976931348623157e308,
          "negative": -2.5e-7, "pi": 3.141592653589793, "point one": 0.1}),
        ("true, false and null", False, {"yes": True, "no": False, "none": None}),
        ("nested values", False, {"list": [1, "two", True, False, None, {"b": [], "a": {}}, [[]]],
                                  "object": {"z": None, "y": {"\u00e9": "\u2028"}}}),
    ]
    out = []
    for name, flat, value in cases:
        text = vault.canonical(value)
        if json.loads(text) != value:
            raise SystemExit(f"the canonical text of {name!r} does not read back as its value")
        out.append({"name": name, "flat": flat, "object": value, "canonical": text,
                    "utf8_hex": text.encode("utf-8").hex()})
    # Texts that are not the canonical form of what they hold: vault.owner_statement refuses each one.
    refused = ['{"b":1,"a":2}', '{"a": 1}', '{"a":1,"a":1}', '{"a":"caf\\u00e9"}', '{"a":"\\u2028"}',
               '{"a":1.00}', '{"a":1e2}', '{"a":-0}', '{"a":1E+16}', '{"a":"\\/"}', ' {"a":1}', '{"a":1}\n', '{"a":"\\u001F"}']
    for text in refused:
        try:
            value = json.loads(text)
        except ValueError:
            continue
        if vault.canonical(value) == text:
            raise SystemExit(f"{text!r} is canonical, and the vector says that it is not")
    accepted = [c["canonical"] for c in out if isinstance(c["object"], dict)]
    return {"about": "Python's json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False), as "
                     "vault.canonical writes it: the text that the owner's key signs. utf8_hex is the exact bytes.",
            "made_by": MADE_BY, "cases": out, "not_canonical": refused, "canonical_objects": accepted}


# ---------------------------------------------------------------- the owner's P-256 signature

def scalar(label, n):
    return int.from_bytes(label_bytes(label), "big") % (n - 1) + 1


def point_b64(vault, d):
    x, y = vault.point_times(d, vault.P256_G)
    return b64(b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big"))


def rfc6979_nonce(d, digest, n):
    """The nonce of RFC 6979 (3.2) for P-256 and SHA-256: deterministic, so the vector is the same at each run."""
    x = d.to_bytes(32, "big")
    h = (int.from_bytes(digest, "big") % n).to_bytes(32, "big")
    v, k = b"\x01" * 32, b"\x00" * 32
    k = hmac.new(k, v + b"\x00" + x + h, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    k = hmac.new(k, v + b"\x01" + x + h, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        v = hmac.new(k, v, hashlib.sha256).digest()
        found = int.from_bytes(v, "big")
        if 1 <= found < n:
            return found
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()


def ecdsa_sign(vault, d, statement):
    """(r, s) over SHA-256 of the statement's UTF-8 bytes, with the curve arithmetic of vault.py."""
    n = vault.P256_N
    digest = hashlib.sha256(statement.encode()).digest()
    e = int.from_bytes(digest, "big")
    k = rfc6979_nonce(d, digest, n)
    r = vault.point_times(k, vault.P256_G)[0] % n
    s = pow(k, -1, n) * (e + r * d) % n
    if not r or not s:
        raise SystemExit("the RFC 6979 nonce gave a zero r or s")
    return r, s


def der_integer(value, pad=False):
    raw = value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")
    if raw[0] & 0x80 or pad:
        raw = b"\x00" + raw
    return b"\x02" + bytes([len(raw)]) + raw


def der(r, s, pad_r=False, raw_r=None):
    body = (raw_r if raw_r is not None else der_integer(r, pad_r)) + der_integer(s)
    return b"\x30" + bytes([len(body)]) + body


def owner_statement(hub, vault):
    n = vault.P256_N
    d = scalar("owner key", n)
    public = point_b64(vault, d)
    vault.owner_key(public)                         # a point of the curve, in the one form the vault reads
    device_key = point_b64(vault, scalar("device key", n))
    fields = {"v": 1, "kind": "owner-device", "fleet": "0123456789abcdef", "device": "pc", "key": device_key,
              "at": 1790000000}
    statement = vault.canonical(fields)
    r, s = ecdsa_sign(vault, d, statement)
    signature = b64(der(r, s))
    conf = {"owner_keys": [public]}
    if not vault.owner_signed(conf, statement, signature):
        raise SystemExit("vault.owner_signed refuses the vector's own signature")
    accepted = [{"name": "the same signature with the other s (the vault has no low-s rule)",
                 "signature": b64(der(r, n - s))}]
    other = vault.canonical(dict(fields, at=fields["at"] + 1))
    r2, s2 = ecdsa_sign(vault, d, other)
    zero_r = b"\x02\x01\x00"
    refused = [
        {"name": "a signature of another statement", "signature": b64(der(r2, s2))},
        {"name": "r with a zero byte in front that it does not need", "signature": b64(der(r, s, pad_r=True))},
        {"name": "a byte after the sequence", "signature": b64(der(r, s) + b"\x00")},
        {"name": "r of zero", "signature": b64(der(0, s, raw_r=zero_r))},
        {"name": "r as a negative number", "signature": b64(der(r, s, raw_r=b"\x02\x20" + (r | (1 << 255)).to_bytes(32, "big")))},
        {"name": "the long form of the sequence's length",
         "signature": b64(b"\x30\x81" + der(r, s)[1:2] + der(r, s)[2:])},
        {"name": "base64 without its padding", "signature": signature.rstrip("=")},
        {"name": "r and s side by side, not DER", "signature": b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))},
        {"name": "s of n", "signature": b64(der(r, n))},
    ]
    for case in accepted:
        if not vault.owner_signed(conf, statement, case["signature"]):
            raise SystemExit(f"vault.owner_signed refuses {case['name']}")
    for case in refused:
        if case["signature"] == signature or vault.owner_signed(conf, statement, case["signature"]):
            raise SystemExit(f"vault.owner_signed takes {case['name']}")
    hub_rule = json.dumps(json.loads(statement), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    if hub_rule != statement or not hub.device_signing({"signing_key": device_key,
                                                         "binding": b64(bytes(32))}):
        raise SystemExit("the statement is not the one that hub.certify_device takes")
    return {"about": "The owner key's certificate of a phone's signing key (hub.certify_device, OwnerStatement."
                     "ownerDevice): the canonical statement, and its ECDSA P-256 signature over SHA-256 of the UTF-8 "
                     "bytes, DER, standard base64, which vault.owner_signed checks. The nonce is RFC 6979's.",
            "made_by": MADE_BY, "private_scalar_hex": d.to_bytes(32, "big").hex(), "public_key": public,
            "fields": fields, "statement": statement, "statement_sha256_hex": hashlib.sha256(statement.encode()).hexdigest(),
            "signature": signature, "accepted": accepted, "refused": refused}


# ---------------------------------------------------------------- the device binding

def device_binding(hub, vault):
    bind_raw = label_bytes("bind")
    bind = b64url(bind_raw)
    key = point_b64(vault, scalar("device key", vault.P256_N))
    binding = b64(hmac.new(bind_raw, base64.b64decode(key), hashlib.sha256).digest())
    if hub.device_signing({"signing_key": key, "binding": binding}) != {"key": key, "binding": binding}:
        raise SystemExit("hub.device_signing refuses the vector's key and binding")
    recovery = point_b64(vault, scalar("recovery key", vault.P256_N))
    recovery_binding = b64(hmac.new(bind_raw, base64.b64decode(recovery), hashlib.sha256).digest())
    taken = hub.device_signing({"signing_key": key, "binding": binding, "recovery_key": recovery,
                                "recovery_binding": recovery_binding})
    if taken.get("recovery_binding") != recovery_binding:
        raise SystemExit("hub.device_signing refuses the vector's recovery key")
    return {"about": "A phone's signing key bound to the one-time value of the Mac's QR (DeviceBinding): "
                     "HMAC-SHA256 with the 32 bytes of bind (base64url, no padding) as its key, over the 65 bytes of "
                     "the uncompressed P-256 point, in standard base64. hub.device_signing takes both pairs.",
            "made_by": MADE_BY, "bind": bind, "key": key, "binding": binding, "recovery_key": recovery,
            "recovery_binding": recovery_binding}


# ---------------------------------------------------------------- the release manifests

def release_manifests(releases, autopublish):
    seed = label_bytes("release key")
    public = releases.public_key(seed)
    other = releases.public_key(label_bytes("another release key"))
    keys_text = "# the release key of the vectors\n" + b64(public) + "\n"
    if releases.parse_keys(keys_text) != (public,):
        raise SystemExit("releases.parse_keys does not read the vector's key file")
    bad_keys = ["# no key\n", b64(public) + "\n" + b64(public[:31]) + "\n", "\n".join([b64(public)] * 5) + "\n",
                b64(public)[:-1] + "\n"]
    for text in bad_keys:
        if releases.parse_keys(text):
            raise SystemExit(f"releases.parse_keys reads {text!r}")

    # A fleet release (releases.read_manifest and signed_text).
    fleet = {"revision": hashlib.sha1(b"founderizer vectors: revision").hexdigest(), "version": "2026.11.400",
             "notes": "https://example.com/releases/2026.11.400", "minimum": None, "hold": False}
    fleet_text = releases.signed_text(fleet)
    fleet_manifest = dict(fleet, signature=b64(releases.sign(seed, fleet_text)))
    releases.check(fleet_manifest, (public,))
    fleet_refused = [
        {"name": "a later version under the same signature", "manifest": dict(fleet_manifest, version="2026.11.401")},
        {"name": "the hold taken out", "manifest": dict(fleet_manifest, hold=True)},
        {"name": "a short revision", "manifest": dict(fleet_manifest, revision=fleet["revision"][:12])},
    ]
    for case in fleet_refused:
        try:
            releases.check(case["manifest"], (public,))
        except releases.Untrusted:
            continue
        raise SystemExit(f"releases.check takes {case['name']}")

    # A build of the app (AppUpdate.signedText, autopublish.app_text), which the app reads with AppUpdate.check.
    channel = "https://releases.example.com"
    build = {"version": "0.1.200", "build": 201, "url": channel + "/app/Founderizer-0.1.200.zip",
             "sha256": hashlib.sha256(b"founderizer vectors: build").hexdigest(), "size": 12345678,
             "minimum": "15.0", "notes": channel + "/notes/0.1.200", "hold": False}
    app_text = autopublish.app_text(build)
    app_manifest = dict(build, signature=b64(releases.sign(seed, app_text.encode())))
    if not releases.verify_signature(public, app_text.encode(), base64.b64decode(app_manifest["signature"])):
        raise SystemExit("releases.verify_signature refuses the build's signature")
    signature_refused = [
        ("a later build under the same signature", dict(app_manifest, build=202)),
        ("the hold taken out", dict(app_manifest, hold=True)),
        ("another download under the same signature", dict(app_manifest, sha256="0" * 64)),
        ("no notes under a signature of the notes", dict(app_manifest, notes="")),
        ("the fleet release's signature", dict(app_manifest, signature=fleet_manifest["signature"])),
        ("a signature by a key that the app does not trust",
         dict(app_manifest, signature=b64(releases.sign(label_bytes("another release key"), app_text.encode())))),
    ]
    app_refused = []
    for name, manifest in signature_refused:
        text = autopublish.app_text(dict(manifest, minimum=manifest["minimum"] or None,
                                         notes=manifest["notes"] or None))
        if releases.verify_signature(public, text.encode(), base64.b64decode(manifest["signature"])):
            raise SystemExit(f"releases.verify_signature takes {name}")
        app_refused.append({"name": name, "refused_by": "signature", "manifest": manifest})
    shape_refused = [
        ("a download on another host", dict(app_manifest, url="https://example.net/app/Founderizer-0.1.200.zip")),
        ("a download over HTTP", dict(app_manifest, url="http://releases.example.com/app/Founderizer-0.1.200.zip")),
        ("a download that is no zip", dict(app_manifest, url=channel + "/app/Founderizer-0.1.200.dmg")),
        ("a build number as text", dict(app_manifest, build="201")),
        ("a build number with a fraction", dict(app_manifest, build=201.5)),
        ("a version with a newline", dict(app_manifest, version="0.1.200\n201")),
        ("a checksum in capitals", dict(app_manifest, sha256=build["sha256"].upper())),
        ("a hold that is not true or false", dict(app_manifest, hold="false")),
        ("no signature", {k: v for k, v in app_manifest.items() if k != "signature"}),
        ("notes on another host", dict(app_manifest, notes="https://example.net/notes")),
        ("a size of zero", dict(app_manifest, size=0)),
    ]
    app_refused += [{"name": name, "refused_by": "shape", "manifest": manifest} for name, manifest in shape_refused]

    # The two shapes of an Ed25519 signature that verify only where a check is loose, which releases.verify_signature
    # refuses: the identity as the public key (with R the identity and S zero it signs every message), and S + L.
    identity = b"\x01" + bytes(31)
    message = b"founderizer vectors: any message"
    loose = [{"name": "the identity as the key", "public_key": b64(identity),
              "signature": b64(identity + bytes(32)), "message_hex": message.hex()}]
    good = releases.sign(seed, message)
    l_order = 2 ** 252 + 27742317777372353535851937790883648493
    s_plus_l = (int.from_bytes(good[32:], "little") + l_order).to_bytes(32, "little")
    loose.append({"name": "S + L", "public_key": b64(public), "signature": b64(good[:32] + s_plus_l),
                  "message_hex": message.hex()})
    for case in loose:
        if releases.verify_signature(base64.b64decode(case["public_key"]), message,
                                     base64.b64decode(case["signature"])):
            raise SystemExit(f"releases.verify_signature takes {case['name']}")
    if not releases.verify_signature(public, message, good):
        raise SystemExit("releases.verify_signature refuses a good signature")
    return {"about": "Ed25519 release manifests: a fleet release (releases.signed_text, founderizer-release-1) and a "
                     "build of the app (autopublish.app_text = AppUpdate.signedText, founderizer-app-1), signed by "
                     "releases.sign with a test key. The keys file is read as releases.parse_keys reads it.",
            "made_by": MADE_BY, "public_key": b64(public), "other_public_key": b64(other),
            "keys_text": keys_text, "keys_text_refused": bad_keys,
            "fleet": {"manifest": fleet_manifest, "signed_text": fleet_text.decode(), "refused": fleet_refused},
            "app": {"channel": channel, "manifest": app_manifest, "signed_text": app_text, "refused": app_refused},
            "message_hex": message.hex(), "message_signature": b64(good), "loose": loose}


# ---------------------------------------------------------------- the files

def files():
    hub, vault, releases, autopublish = hub_code()
    made = {"canonical-json.json": canonical_cases(vault),
            "owner-statement.json": owner_statement(hub, vault),
            "device-binding.json": device_binding(hub, vault),
            "release-manifests.json": release_manifests(releases, autopublish)}
    # ASCII only, so that every character class travels as an escape that no editor or git setting changes.
    return {name: (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode("ascii")
            for name, value in made.items()}


SWIFT_FILES = {"agent-marks.json": "MarkVectorsTests", "swift-words.json": "WordsVectorsTests"}


def swift_files():
    """The files that the Swift writer tests make, by name: one run of `swift test` on the app's package."""
    out = tempfile.mkdtemp(prefix="founderizer-vectors-")
    try:
        done = subprocess.run(["swift", "test", "--package-path", os.path.dirname(HERE), "--filter",
                               "|".join(sorted(SWIFT_FILES.values()))],
                              env=dict(os.environ, FOUNDERIZER_VECTORS_OUT=out), capture_output=True, text=True,
                              timeout=3600)
        made = {}
        for name in SWIFT_FILES:
            path = os.path.join(out, name)
            if os.path.isfile(path):
                made[name] = open(path, "rb").read()
        if done.returncode != 0 or len(made) != len(SWIFT_FILES):
            tail = "\n".join((done.stdout + done.stderr).splitlines()[-30:])
            raise SystemExit(f"the Swift writers did not write {sorted(set(SWIFT_FILES) - set(made))}:\n{tail}")
        return made
    finally:
        shutil.rmtree(out, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="compare with the committed files; end with 1 on a change")
    ap.add_argument("--into", default=HERE, help="the folder to write into (default: beside this script)")
    ap.add_argument("--no-swift", action="store_true", help="only the files that Python makes, not the Swift ones")
    args = ap.parse_args()
    made = files()
    if args.no_swift:
        print("not made: " + ", ".join(sorted(SWIFT_FILES)) + " (--no-swift)")
    else:
        made.update(swift_files())
    if args.check:
        changed = []
        for name, data in sorted(made.items()):
            path = os.path.join(HERE, name)
            held = open(path, "rb").read() if os.path.isfile(path) else None
            print(f"{'same' if held == data else 'DIFFERENT'}  {name}  {len(data)} bytes")
            if held != data:
                changed.append(name)
        return 1 if changed else 0
    os.makedirs(args.into, exist_ok=True)
    for name, data in sorted(made.items()):
        with open(os.path.join(args.into, name), "wb") as f:
            f.write(data)
        print(f"wrote {os.path.join(args.into, name)}  {len(data)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
