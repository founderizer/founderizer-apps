"""The vector of the record `server-made` (F17 design A, Setup's piece SP1): one server that a client made, as the
canonical statement that the client's owner key signs, its signature, the signer's `by`, and the texts and signatures
that a reader refuses. FleetCore's `ServerMade` (Tests/FleetCoreTests/ServerMadeTests.swift) reads it; the hub's form
check of `POST /ui/servers/made` reads the same file in its own test.

Made with the hub's own code, as make_vectors.py makes the owner's statement: the text with `vault.canonical`, the
signature with the P-256 arithmetic of `vault.py` and an RFC 6979 nonce, each checked with `vault.owner_signed`."""

import hashlib
import importlib.util
import os

NAME = "server-made.json"
MADE_BY = "app/vectors/makers/server_made.py"
FLEET = "0123456789abcdef"


def helpers():
    """make_vectors.py's own key and signature helpers (`scalar`, `point_b64`, `ecdsa_sign`, `der`, `b64`)."""
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "make_vectors.py")
    spec = importlib.util.spec_from_file_location("make_vectors_for_server_made", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def python(hub, vault, releases, autopublish):
    h = helpers()
    n = vault.P256_N
    d = h.scalar("server-made signer", n)
    public = h.point_b64(vault, d)
    vault.owner_key(public)
    other = h.point_b64(vault, h.scalar("server-made stranger", n))
    fields = {"v": 1, "kind": "server-made", "fleet": FLEET, "machine": "worker-3", "provider": "hetzner",
              "id": "58213977", "use": "agent", "at": 1790000000}
    statement = vault.canonical(fields)
    r, s = h.ecdsa_sign(vault, d, statement)
    signature = h.b64(h.der(r, s))
    conf = {"owner_keys": [public]}
    if not vault.owner_signed(conf, statement, signature):
        raise SystemExit("vault.owner_signed refuses the server-made vector's own signature")
    import base64
    by = hashlib.sha256(base64.b64decode(public)).hexdigest()
    r2, s2 = h.ecdsa_sign(vault, d, vault.canonical(dict(fields, id="58213978")))
    refused_signatures = [
        {"name": "the signature of another server's statement", "signature": h.b64(h.der(r2, s2))},
        {"name": "r with a zero byte in front that it does not need", "signature": h.b64(h.der(r, s, pad_r=True))},
        {"name": "a byte after the sequence", "signature": h.b64(h.der(r, s) + b"\x00")},
        {"name": "base64 without its padding", "signature": signature.rstrip("=")},
        {"name": "r and s side by side, not DER", "signature": h.b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))},
    ]
    for case in refused_signatures:
        if case["signature"] == signature or vault.owner_signed(conf, statement, case["signature"]):
            raise SystemExit(f"vault.owner_signed takes {case['name']}")

    def text(**change):
        value = dict(fields, **change)
        return vault.canonical({k: v for k, v in value.items() if v is not None})

    refused_statements = [
        {"name": "another fleet", "statement": text(fleet="fedcba9876543210")},
        {"name": "another kind", "statement": text(kind="owner-device")},
        {"name": "another version", "statement": text(v=2)},
        {"name": "a field more", "statement": text(project="example")},
        {"name": "no use", "statement": text(use=None)},
        {"name": "a provider that the app does not rent at", "statement": text(provider="aws")},
        {"name": "a use that is neither hub nor agent", "statement": text(use="door")},
        {"name": "a name in capitals", "statement": text(machine="Worker-3")},
        {"name": "an id with a slash", "statement": text(id="58213977/1")},
        {"name": "the time as text", "statement": text(at="1790000000")},
        {"name": "a time before 1970", "statement": text(at=-1)},
        {"name": "the version as true", "statement": statement.replace('"v":1', '"v":true')},
        {"name": "the keys out of their order", "statement": '{"v":1,' + statement[1:].replace(',"v":1', '')},
        {"name": "a space after a colon", "statement": statement.replace('"use":"agent"', '"use": "agent"')},
        {"name": "a key twice", "statement": statement.replace('"machine":"worker-3"',
                                                                '"machine":"worker-3","machine":"worker-3"')},
        {"name": "an escape for a plain letter", "statement": statement.replace('"worker-3"', '"\\u0077orker-3"')},
    ]
    for case in refused_statements:
        if case["statement"] == statement:
            raise SystemExit(f"{case['name']} is the vector's own statement")
    return {NAME: {
        "about": "One record server-made (F17 design A, SP1): the canonical statement that the owner key of the client "
                 "that made the server signs (ECDSA P-256 over SHA-256 of its UTF-8 bytes, DER, standard base64, which "
                 "vault.owner_signed checks; the nonce is RFC 6979's), and by, the signer's name in a record: SHA-256 "
                 "of the key's 65 bytes, lower-case hex. A reader refuses each refused signature and each refused "
                 "statement (another fleet's too, with fleet as the reader's), and a record by another key.",
        "made_by": MADE_BY, "fleet": FLEET, "private_scalar_hex": d.to_bytes(32, "big").hex(), "public_key": public,
        "by": by, "other_public_key": other, "fields": fields, "statement": statement, "signature": signature,
        "refused_signatures": refused_signatures, "refused_statements": refused_statements}}
