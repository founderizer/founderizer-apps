"""The vectors of the vault's core on the owner's computer (windows-app-plan-v2.md, 5.6, piece L5).

- `vault-seal.json` comes from FleetCore's own code, by the Swift writer test Tests/FleetCoreTests/VaultVectorsTests.swift.
  Its salted fingerprints and its canonical seeds are checked here with the vault's own `fingerprints` and
  `canonical_seed`, its AI providers' sites with `provider_site`, and its pool statements with `STATEMENTS` and
  `canonical`, so the Swift rule, the C# rule and the vault give one answer.
- `owner-replace.json`: the owner's signed replace of a value (`OwnerStatement.replace`, vault.py STATEMENTS "replace"),
  made with the vault's own canonical text and checked with its own `owner_signed`, as owner-statement.json is.

The C# tests of windows/Founderizer.Owner.Tests read both. The keys are test keys of fixed labels."""
import hashlib
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MADE_BY = "app/vectors/makers/vault_core.py"

SWIFT = {"vault-seal.json": "VaultVectorsTests"}


def tools():
    """The P-256 helpers of make_vectors.py: the fixed scalar of a label, its point, and RFC 6979's signature."""
    spec = importlib.util.spec_from_file_location("vector_maker_main", os.path.join(HERE, "make_vectors.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_seal_file(vault):
    """The committed vault-seal.json, held to the vault's own fingerprints and seeds (nothing when it is not made yet)."""
    path = os.path.join(HERE, "vault-seal.json")
    if not os.path.isfile(path):
        return
    with open(path, encoding="utf-8") as f:
        whole = json.load(f)
    secrets = whole["secrets"]
    salts = json.loads(secrets["salts"])
    for row in secrets["secrets"]:
        if row["value"] is None:
            continue
        mine = vault.fingerprints(json.loads(row["value"]), salts)
        if mine != row["fingerprints"]:
            raise SystemExit(f"vault-seal.json: the fingerprints of {row['name']!r} are not vault.fingerprints'")
    for row in secrets["seeds"]:
        if vault.canonical_seed(row["value"]) != row["seed"]:
            raise SystemExit(f"vault-seal.json: the seed of {row['value']!r} is not vault.canonical_seed's")
    for row in secrets["secrets"]:
        # each row that reaches the check of its site (a value with a fingerprint and an address): the Mac's line is the
        # provider's exactly where vault.provider_site says so, in capitals and with a dot at the end too
        if row["value"] is None or not row["fingerprints"] or not row["url"]:
            continue
        host = row["url"].split("://", 1)[-1].split("/", 1)[0].split(":", 1)[0]
        said = "AI provider's own sign-in site" in (row["vault_problem"] or "")
        if said != vault.provider_site(host):
            raise SystemExit(f"vault-seal.json: {row['name']!r}: the Mac says {said} of {host}, vault.provider_site the other")
    # the pool statements of the hub's default: the vault's own fields and canonical text
    for row in whole["vault"]["statements"]:
        fields = {"v": 1, "kind": row["kind"], "fleet": row["fleet"], "login": row["login"].lower(), "at": row["at"]}
        if set(fields) != vault.STATEMENTS[row["kind"]] or vault.canonical(fields) != row["statement"]:
            raise SystemExit(f"vault-seal.json: the {row['kind']} statement is not vault.canonical of vault.STATEMENTS")


def owner_replace(vault):
    make = tools()
    n = vault.P256_N
    d = make.scalar("owner key", n)
    public = make.point_b64(vault, d)
    sealed = "-----BEGIN AGE ENCRYPTED FILE-----\nZXhhbXBsZQ==\n-----END AGE ENCRYPTED FILE-----\n"
    given = "bws://0000000A-0000-4000-8000-00000000000A"
    fields = {"v": 1, "kind": "replace", "fleet": "0123456789abcdef", "login": given.lower(),
              "sha256": hashlib.sha256(sealed.encode("utf-8")).hexdigest(), "at": 1790000000}
    if set(fields) != vault.STATEMENTS["replace"]:
        raise SystemExit("the replace statement's fields are not vault.STATEMENTS['replace']")
    statement = vault.canonical(fields)
    r, s = make.ecdsa_sign(vault, d, statement)
    signature = make.b64(make.der(r, s))
    if not vault.owner_signed({"owner_keys": [public]}, statement, signature):
        raise SystemExit("vault.owner_signed refuses the replace vector's own signature")
    return {"about": "The owner's signed replace of a value under a reference that the central vault holds (vault.py "
                     "STATEMENTS 'replace', OwnerStatement.replace): the login in small letters, the SHA-256 of the sealed "
                     "copy's text, the canonical statement and its ECDSA P-256 signature (RFC 6979), which "
                     "vault.owner_signed takes.",
            "made_by": MADE_BY, "public_key": public, "login_given": given, "sealed": sealed, "fields": fields,
            "statement": statement, "signature": signature}


def python(hub, vault, releases, autopublish):
    check_seal_file(vault)
    return {"owner-replace.json": owner_replace(vault)}
