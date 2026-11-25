"""The vectors of the list of the owner's devices (F17, piece P1): the canonical text of each statement about the list,
as a device signs it and the central vault checks it (vault.py, signed_statement), and the name of a key in an end.

client-list.json is read by the central vault's test (test_vault_central.ClientVectors). The apps' own tests read it
with the piece that gives each device its list key: the Swift and the C# writer must give these texts, byte for byte,
and the refused ones are texts that the vault takes from nobody.

Each key is the public half of a scalar from a fixed label, so a run writes the same bytes each time. No private half
is written here, and no statement of this file is signed."""
import base64
import hashlib

MADE_BY = "app/vectors/makers/client_list.py"
NAME = "client-list.json"
FLEET = "0123456789abcdef"
AT = 1790000000


def key(vault, label):
    """The public key of one fixed label: the base64 of 04, X, Y, as CryptoKit's x963Representation."""
    d = int.from_bytes(hashlib.sha256(("founderizer vectors: client list, " + label).encode()).digest(), "big")
    x, y = vault.point_times(d % (vault.P256_N - 1) + 1, vault.P256_G)
    return base64.b64encode(b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big")).decode()


def refusal(vault, kind, statement):
    """What the vault says of this text with no signature: the refusal of its form, or of its signature when the form
    is right."""
    try:
        vault.signed_statement({"fleet": FLEET}, {"statement": statement, "signature": ""}, kind, [])
    except vault.Refused as e:
        return str(e)
    raise SystemExit("a statement with no signature was taken")


def python(hub, vault, releases, autopublish):
    mac = {"device": "mac", "os": "mac", "label": "Ana's Mac", "sign": key(vault, "mac sign"),
           "list": key(vault, "mac list")}
    phone = {"device": "iphone", "os": "iphone", "label": "iPhone", "sign": key(vault, "iphone sign"),
             "list": key(vault, "iphone list"), "save": key(vault, "iphone save")}
    pc = {"device": "pc-2", "os": "windows", "label": "Café — \"PC\" \\ 2", "sign": key(vault, "pc sign"),
          "list": key(vault, "pc list")}

    def hashes(*devices):
        return sorted(vault.key_hash(d[name]) for d in devices for name in ("sign", "list", "save") if name in d)

    def added(one, /, **changes):
        return dict({"v": 1, "kind": "client-add", "fleet": FLEET, "at": AT}, **dict(one, **changes))

    def ended(keys, **changes):
        return dict({"v": 1, "kind": "client-end", "fleet": FLEET, "at": AT, "keys": keys}, **changes)

    taken = [("a Mac", added(mac)), ("an iPhone, with its save key", added(phone)),
             ("a PC, with a label that JSON escapes and one that it does not", added(pc)),
             ("the Mac of the list's first list key", added(mac, kind="client-first")),
             ("the end of one Mac", ended(",".join(hashes(mac)))),
             ("the end of one iPhone", ended(",".join(hashes(phone)))),
             ("the end of three devices", ended(",".join(hashes(mac, phone, pc))))]
    first = hashes(mac)
    many = sorted(hashlib.sha256(str(n).encode()).hexdigest() for n in range(17))
    refused = [("a list key that is the sign key", added(mac, list=mac["sign"])),
               ("an iPhone with no save key", {k: v for k, v in added(phone).items() if k != "save"}),
               ("a save key on a Mac", added(mac, save=phone["save"])),
               ("a kind of device that the vault does not know", added(mac, os="Mac")),
               ("an iPhone as the first list key's device", added({k: v for k, v in phone.items() if k != "save"},
                                                                    kind="client-first")),
               ("a device's name with a capital", added(mac, device="Mac")),
               ("a label of two lines", added(mac, label="one\ntwo")),
               ("a label of 41 characters", added(mac, label="x" * 41)),
               ("no label", added(mac, label="")),
               ("a key that is no point of the curve", added(mac, list=base64.b64encode(b"\x04" + bytes(64)).decode())),
               ("a field more", added(mac, note="x")),
               ("the key of an end as itself and not as its hash", ended(mac["sign"])),
               ("the keys of an end not sorted", ended(",".join(reversed(first)))),
               ("one key two times in an end", ended(",".join([first[0], first[0]]))),
               ("an end of no key", ended("")),
               ("an end of 17 keys", ended(",".join(many))),
               ("a hash in capitals", ended(first[0].upper())),
               ("the keys of an end as a list", ended(first))]
    cases = []
    for name, fields in taken:
        text = vault.canonical(fields)
        said = refusal(vault, fields["kind"], text)
        if "does not carry a valid signature" not in said:
            raise SystemExit(f"the vault refuses the form of {name!r}: {said}")
        cases.append({"name": name, "kind": fields["kind"], "fields": fields, "statement": text,
                      "statement_sha256_hex": hashlib.sha256(text.encode("utf-8")).hexdigest()})
    wrong = []
    for name, fields in refused:
        text = vault.canonical(fields)
        if refusal(vault, fields["kind"], text) != f"the statement is not a valid {fields['kind']} statement":
            raise SystemExit(f"the vault takes the form of {name!r}")
        wrong.append({"name": name, "kind": fields["kind"], "statement": text})
    keys = [{"key": d[name], "hash": vault.key_hash(d[name])} for d in (mac, phone, pc)
            for name in ("sign", "list", "save") if name in d]
    return {NAME: {
        "about": "The statements about the list of the owner's devices: the canonical text (vault.canonical) of exactly "
                 "the fields of each kind, whose UTF-8 bytes a device signs (statement_sha256_hex is of those bytes); "
                 "`keys`, the name of a public key in an end and in a record: the SHA-256 of its 65 bytes, in lowercase "
                 "hex. An end names its keys by these, sorted and joined with commas. refused: texts whose form the "
                 "vault takes from nobody.",
        "made_by": MADE_BY, "keys": keys, "cases": cases, "refused": wrong}}
