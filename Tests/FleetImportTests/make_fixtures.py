"""Synthetic export files for the tests of the secrets import (`Fixtures.swift`), made with Python's `cryptography`
(OpenSSL) and not with the Swift code under test, so that the Swift reader is checked against another implementation.
Every value in them is invented. Run it again, from `app/`, after a change here:

    python3 -I Tests/FleetImportTests/make_fixtures.py > Tests/FleetImportTests/Fixtures.swift
"""
import base64, hashlib, hmac, io, json, sys, zipfile
from cryptography.hazmat.primitives import hashes, padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.argon2 import Argon2id
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

def stretch(key):
    return HKDFExpand(hashes.SHA256(), 32, b"enc").derive(key), HKDFExpand(hashes.SHA256(), 32, b"mac").derive(key)

def seal(plain, enc, mac, iv):
    padder = padding.PKCS7(128).padder()
    body = padder.update(plain) + padder.finalize()
    encryptor = Cipher(algorithms.AES(enc), modes.CBC(iv)).encryptor()
    ct = encryptor.update(body) + encryptor.finalize()
    tag = hmac.new(mac, iv + ct, hashlib.sha256).digest()
    return "2." + "|".join(base64.b64encode(x).decode() for x in (iv, ct, tag))

inner = {"encrypted": False, "folders": [], "items": [
    {"id": "11111111-1111-4111-8111-111111111111", "type": 1, "name": "Shop admin", "notes": None, "favorite": False,
     "login": {"username": "owner@example.test", "password": "synthetic-pass-phrase-1",
               "totp": "otpauth://totp/Shop:owner?secret=JBSWY3DPEHPK3PXP&issuer=Shop",
               "uris": [{"match": None, "uri": "androidapp://com.example"}, {"match": None, "uri": "https://shop.example.test/login"}]}},
    {"id": "22222222-2222-4222-8222-222222222222", "type": 1, "name": "Stripe live key", "login": {"username": "", "password": "sk_test_synthetic_000111", "uris": []}},
    {"id": "33333333-3333-4333-8333-333333333333", "type": 2, "name": "Wi-Fi notes", "secureNote": {"type": 0}, "notes": "synthetic"},
    {"id": "44444444-4444-4444-8444-444444444444", "type": 3, "name": "Company card", "card": {"number": "4111111111111111"}},
    {"id": "55555555-5555-4555-8555-555555555555", "type": 1, "name": "No password here", "login": {"username": "x", "password": None}},
]}
plain = json.dumps(inner).encode()

def protected(kdf, salt, password, iterations, memory=None, parallelism=None):
    if kdf == 0:
        key = PBKDF2HMAC(hashes.SHA256(), 32, salt.encode(), iterations).derive(password.encode())
    else:
        key = Argon2id(salt=hashlib.sha256(salt.encode()).digest(), length=32, iterations=iterations, lanes=parallelism,
                       memory_cost=memory * 1024).derive(password.encode())
    enc, mac = stretch(key)
    return json.dumps({"encrypted": True, "passwordProtected": True, "salt": salt, "kdfType": kdf, "kdfIterations": iterations,
                       "kdfMemory": memory, "kdfParallelism": parallelism,
                       "encKeyValidation_DO_NOT_EDIT": seal(b"6b9cdc0a-7d10-4c5b-9b2c-0f6c2d1e5a11", enc, mac, b"\x01" * 16),
                       "data": seal(plain, enc, mac, b"\x02" * 16)})

out = {
    "bitwardenPlain": json.dumps(inner),
    "bitwardenPBKDF2": protected(0, "c3ludGhldGljLXNhbHQtMQ==", "export pass synthetic", 5000),
    "bitwardenArgon2": protected(1, "c3ludGhldGljLXNhbHQtMg==", "export pass synthetic", 2, 16, 1),
    "bitwardenAccount": json.dumps({"encrypted": True, "encKeyValidation_DO_NOT_EDIT": "2.AAAA|BBBB|CCCC", "folders": [], "items": []}),
    "secretsManager": json.dumps({"projects": [{"id": "66666666-6666-4666-8666-666666666666", "name": "Backend"}], "secrets": [
        {"id": "77777777-7777-4777-8777-777777777777", "organizationId": "88888888-8888-4888-8888-888888888888",
         "projectIds": ["66666666-6666-4666-8666-666666666666"], "key": "openai api-key", "value": "sk-synthetic-0000001", "note": "n"},
        {"id": "99999999-9999-4999-8999-999999999999", "organizationId": "88888888-8888-4888-8888-888888888888",
         "projectIds": [], "key": "EMPTY_ONE", "value": "", "note": ""}]}),
}

data = {"accounts": [{"attrs": {"accountName": "Synthetic"}, "vaults": [{"attrs": {"name": "Private"}, "items": [
    {"uuid": "a1", "state": "active", "categoryUuid": "001",
     "overview": {"title": "GitHub", "url": "https://github.example.test/login", "urls": [{"label": "", "url": "https://github.example.test/login"}]},
     "details": {"loginFields": [{"value": "octo-synthetic", "designation": "username", "fieldType": "T"},
                                 {"value": "synthetic-github-pass", "designation": "password", "fieldType": "P"}],
                 "sections": [{"fields": [{"title": "one-time password", "id": "TOTP_1", "value": {"totp": "JBSWY3DPEHPK3PXP"}}]}]}},
    {"uuid": "a2", "state": "active", "categoryUuid": "005", "overview": {"title": "Mailgun key"}, "details": {"password": "key-synthetic-123456"}},
    {"uuid": "a3", "state": "active", "categoryUuid": "112", "overview": {"title": "Twilio API"},
     "details": {"sections": [{"fields": [{"id": "credential", "value": {"concealed": "tw-synthetic-credential"}},
                                         {"id": "hostname", "value": {"string": "https://api.twilio.example.test"}}]}]}},
    {"uuid": "a4", "state": "archived", "categoryUuid": "001", "overview": {"title": "Old login"}, "details": {}},
    {"uuid": "a5", "state": "active", "categoryUuid": "003", "overview": {"title": "A note"}, "details": {"notesPlain": "x"}},
]}]}]}
buffer = io.BytesIO()
with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("export.attributes", json.dumps({"version": 3, "description": "1Password Unencrypted Export"}))
    z.writestr("export.data", json.dumps(data))
    z.writestr("files/a.bin", b"\x00" * 5000)
out["onePassword1PUX"] = base64.b64encode(buffer.getvalue()).decode()
out["onePasswordCSV"] = ('Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\r\n'
                         '"Bank, main",https://bank.example.test,me@example.test,"pa""ss-synthetic-9",,false,false,,"two\nlines"\r\n'
                         'API token,,,tok-synthetic-55555,,false,false,,\r\n'
                         'Old,https://old.example.test,u,p-synthetic-0000,,false,true,,\r\n')
print("// Made by make_fixtures.py with Python's cryptography 45 (OpenSSL); every value is invented.")
print("enum Fixtures {")
for name, value in out.items():
    print(f"    static let {name} = {json.dumps(value)}")
print("}")
