import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// **The vectors of the vault's core on the owner's computer** (windows-app-plan-v2.md, 5.6, piece L5): what the Windows
/// app's library (`windows/Founderizer.Owner/Vault`) must make and decide, made by FleetCore's own code for fixed example
/// inputs, in `vault-seal.json`:
///
/// - an age seal with a fixed file key, a fixed ephemeral key and a fixed nonce (`AgeSeal.seal(_:to:random:)`), the
///   sealed lengths, the reading of recipients and of sealed copies;
/// - the recovery code's normal form, its groups, its recipient and the SHA-256 of its identity, from fixed random bytes;
/// - the recovery code's copy for one phone (`RecoverySeal`), with a fixed ephemeral key and a fixed nonce: the writer
///   lays out `RecoverySeal`'s own `derive` and `bound` around them, and `RecoverySeal.open` opens the box;
/// - the salted fingerprints of example item values, and the canonical seed of example authenticator values;
/// - the owner access key's lines and its OpenSSH private key file for a fixed seed;
/// - the secrets of the form (`LoginSecret`): the title, the variable, the table's address, the problems in the Mac's
///   English and the item value;
/// - example readings of `GET /ui/vault`, what they decide (`VaultSealKey`, `VaultReading.trusted`), the pool
///   statements that they owe (`poolDue`) and what the plan does with them (`VaultPlan.of`); the statements of the pool's
///   default (`OwnerStatement.defaultPool`, `unpool`);
/// - the reading of the form's addresses and blanks, the request's fields, its note and what it fits (`NeedSecret`), the
///   rows of a replace (`SecretReplaceAccess`), a key card's look (`KeySaveLook`, `KeySaveCard`) and the times of the
///   owner's statements (`GrantClock`).
///
/// With `FOUNDERIZER_VECTORS_OUT` set, the test writes the file into that folder (`app/vectors/make_vectors.py` does, and
/// its `--check` compares); without it, it holds the committed file equal to what FleetCore gives now.
struct VaultVectorsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")
    static let file = "vault-seal.json"
    static let madeBy = "app/Tests/FleetCoreTests/VaultVectorsTests.swift"
    static let now = 1_763_700_000.0
    static let fleet = "0123456789abcdef"

    static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    /// 32 bytes of a fixed label: the same bytes each run, and no key of anything else.
    static func fixed(_ label: String, _ count: Int = 32) -> Data {
        var out = Data()
        var round = 0
        while out.count < count {
            out += Data(SHA256.hash(data: Data("founderizer vault vector \(label) \(round)".utf8)))
            round += 1
        }
        return out.prefix(count)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The age recipient of the X25519 key of a fixed label.
    static func recipient(_ label: String) -> String {
        let key = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: fixed(label))
        return AgeSeal.bech32("age", key.publicKey.rawRepresentation)
    }

    static func reference(_ n: Int) -> String { String(format: "bws://%08x-0000-4000-8000-%012x", n, n) }

    // MARK: - The seal

    static func sealCase(_ name: String, value: Data, rule: String?, whole: Bool) throws -> [String: Any] {
        let to = recipient("vault")
        let fileKey = fixed("file key \(name)", 16), ephemeral = fixed("ephemeral \(name)"), nonce = fixed("nonce \(name)", 16)
        var given = [fileKey, ephemeral, nonce]
        let sealed = try AgeSeal.seal(value, to: to) { count in
            let next = given.removeFirst()
            #expect(next.count == count)
            return next
        }
        #expect(AgeSeal.isSealed(sealed))
        #expect(sealed.count == AgeSeal.sealedLength(of: value.count))
        var out: [String: Any] = ["name": name, "recipient": to, "file_key_hex": hex(fileKey), "ephemeral_hex": hex(ephemeral),
                                  "nonce_hex": hex(nonce), "length": value.count,
                                  "sealed_sha256": hex(Data(SHA256.hash(data: Data(sealed.utf8))))]
        if let rule { out["value_rule"] = rule } else { out["value_b64"] = value.base64EncodedString() }
        if whole { out["sealed"] = sealed }
        return out
    }

    static func sealDocument() throws -> [String: Any] {
        let item = Data(#"{"password":"correct horse battery staple","url":"https://example.com/sign-in","username":"ana@example.com"}"#.utf8)
        let long = Data((0..<65_537).map { UInt8($0 % 251) })
        let seals = [try sealCase("an empty value", value: Data(), rule: nil, whole: true),
                     try sealCase("a login's item", value: item, rule: nil, whole: true),
                     try sealCase("two chunks", value: long, rule: "byte i is i mod 251, for i from 0 to 65536", whole: false)]
        let lengths = [0, 1, 2, 3, 100, 12_000, 65_536, 65_537, 200_000].map { ["count": $0, "length": AgeSeal.sealedLength(of: $0)] }
        let good = recipient("vault")
        var flipped = Array(good)
        flipped[20] = flipped[20] == "q" ? "p" : "q"
        let recipients: [[String: Any]] = [
            ["text": good, "public_key_hex": orNull(AgeSeal.publicKey(of: good).map(hex))],
            ["text": String(flipped), "public_key_hex": orNull(AgeSeal.publicKey(of: String(flipped)).map(hex))],
            ["text": good.uppercased(), "public_key_hex": orNull(AgeSeal.publicKey(of: good.uppercased()).map(hex))],
            ["text": String(good.dropLast()), "public_key_hex": orNull(AgeSeal.publicKey(of: String(good.dropLast())).map(hex))],
            ["text": "age1" + String(repeating: "q", count: 58), "public_key_hex": orNull(AgeSeal.publicKey(of: "age1" + String(repeating: "q", count: 58)).map(hex))],
        ]
        let sealedText = seals[1]["sealed"] as! String
        let isSealed: [[String: Any]] = [sealedText, sealedText.replacingOccurrences(of: "\n", with: "\r\n"), String(sealedText.dropLast()),
                                         "-----BEGIN AGE ENCRYPTED FILE-----\nYWdl\n-----END AGE ENCRYPTED FILE-----\n", "plain text"]
            .map { ["text": $0, "sealed": AgeSeal.isSealed($0)] }
        return ["seals": seals, "sealed_lengths": lengths, "max_copy": AgeSeal.maxCopy,
                "longest_sealed": AgeSeal.longestSealed(within: AgeSeal.maxCopy), "recipients": recipients, "is_sealed": isSealed]
    }

    // MARK: - The recovery code and its copy for a phone

    static func recoveryDocument() throws -> [String: Any] {
        var codes: [[String: Any]] = []
        for label in ["first", "second"] {
            let bytes = fixed("recovery \(label)", 26)
            let code = try RecoveryCode.make { count in #expect(count == 26); return bytes }
            codes.append(["random_hex": hex(bytes), "normalized": code.normalized, "grouped": code.grouped,
                          "recipient": code.recipient, "identity_sha256": hex(Data(SHA256.hash(data: Data(code.identity.utf8))))])
        }
        let first = try RecoveryCode.make { _ in fixed("recovery first", 26) }
        let typed: [[String: Any]] = [first.grouped.lowercased(), first.grouped.replacingOccurrences(of: "-", with: " "),
                                      "0ILO-" + String(first.normalized.dropFirst(4)), first.normalized + "0", "U" + String(first.normalized.dropFirst())]
            .map { ["text": $0, "normalized": orNull(RecoveryCode($0)?.normalized)] }
        // The phone's copy: an ephemeral key and a nonce of fixed labels around RecoverySeal's own derivation.
        let phone = try P256.KeyAgreement.PrivateKey(rawRepresentation: fixed("phone recovery key"))
        let mine = try P256.KeyAgreement.PrivateKey(rawRepresentation: fixed("recovery seal ephemeral"))
        let device = "ana-iphone"
        let code = Data(first.normalized.utf8)
        let ephemeral = mine.publicKey.x963Representation
        let key = RecoverySeal.derive(try mine.sharedSecretFromKeyAgreement(with: phone.publicKey), ephemeral: ephemeral, device: device)
        let nonce = fixed("recovery seal nonce", 12)
        let box = try AES.GCM.seal(code, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: RecoverySeal.bound(device))
        let sealed = (ephemeral + box.combined!).base64EncodedString()
        let opened = try RecoverySeal.open(sealed, device: device) { try phone.sharedSecretFromKeyAgreement(with: $0) }
        #expect(opened == code)
        // and a box of RecoverySeal's own, with its own random key, opens with the phone's key too
        let own = try RecoverySeal.seal(code, to: phone.publicKey.x963Representation.base64EncodedString(), device: device)
        #expect(try RecoverySeal.open(own, device: device) { try phone.sharedSecretFromKeyAgreement(with: $0) } == code)
        let seal: [String: Any] = ["code": first.normalized, "device": device, "phone_private_hex": hex(phone.rawRepresentation),
                                   "phone_public": phone.publicKey.x963Representation.base64EncodedString(),
                                   "ephemeral_private_hex": hex(mine.rawRepresentation), "nonce_hex": hex(nonce), "box": sealed,
                                   "info": RecoverySeal.info]
        return ["codes": codes, "typed": typed, "seal": seal]
    }

    // MARK: - The fingerprints, the owner access key and the form's secrets

    static let salts = #"{"login": "bws://00000001-0000-4000-8000-000000000001", "password": "00112233445566778899aabbccddeeff", "totp": "ffeeddccbbaa99887766554433221100"}"#

    static func secret(_ kind: LoginSecret.Kind, url: String = "", username: String = "", password: String = "", totp: String = "",
                       env: String = "") -> LoginSecret {
        var made = LoginSecret()
        made.kind = kind; made.url = url; made.username = username; made.password = password; made.totp = totp; made.env = env
        return made
    }

    static let secrets: [(String, LoginSecret)] = [
        ("a login", secret(.login, url: "https://Example.COM/sign-in", username: " ana@example.com ", password: "correct horse battery staple")),
        ("a login with a seed", secret(.login, url: "https://app.example.com/login", username: "ana", password: "Tr0ub4dor&3xyz",
                                       totp: "jbsw y3dp-ehpk 3pxp=")),
        ("a login with an otpauth seed", secret(.login, url: "https://app.example.com/login", username: "ana", password: "Tr0ub4dor&3xyz",
                                                totp: "otpauth://totp/Example:ana?secret=JBSWY3DPEHPK3PXP&issuer=Example")),
        ("a short password", secret(.login, url: "http://example.com:8080/ok", username: "a", password: "short")),
        ("a password with a space", secret(.login, url: "https://example.com", username: "a", password: "two words here")),
        ("not http", secret(.login, url: "ftp://example.com", username: "a", password: "correct horse battery staple")),
        ("a user part", secret(.login, url: "https://user@example.com/x", username: "a", password: "correct horse battery staple")),
        ("no address", secret(.login, url: "example.com", username: "a", password: "correct horse battery staple")),
        ("no user name", secret(.login, url: "https://example.com", username: "  ", password: "correct horse battery staple")),
        ("no password", secret(.login, url: "https://example.com", username: "a")),
        ("a seed that is not one", secret(.login, url: "https://example.com", username: "a", password: "correct horse battery staple", totp: "18!")),
        // a password with a fingerprint, so that the check of the site is reached; the host in capitals and with a dot
        ("an AI provider's sign-in site", secret(.login, url: "https://Claude.AI./login", username: "a", password: "Tr0ub4dor&3xyz")),
        ("a long title", secret(.login, url: "https://accounts.example.com/sign-in", username: "a.very.long.user.name.for.this.example@example.com",
                                password: "correct horse battery staple")),
        ("a password beyond ASCII", secret(.login, url: "https://example.com", username: "ana", password: "contraseña-ñandú-🔑-\"quoted\"\\")),
        ("an API key", secret(.apiKey, password: "sk-test-0123456789abcdefghij", env: " openai_api_key ")),
        ("an API key with an address", secret(.apiKey, url: "https://api.example.com:8443/v1/hooks?x=1#f", password: "sk-test-0123456789abcdefghij",
                                              env: "EXAMPLE_KEY")),
        ("an API key with an http address", secret(.apiKey, url: "http://api.example.com/v1", password: "sk-test-0123456789abcdefghij",
                                                   env: "EXAMPLE_KEY")),
        ("an API key of a key site", secret(.apiKey, url: "https://platform.claude.com/settings", password: "sk-test-0123456789abcdefghij",
                                            env: "EXAMPLE_KEY")),
        ("an API key of a sign-in site", secret(.apiKey, url: "https://chatgpt.com", password: "sk-test-0123456789abcdefghij", env: "EXAMPLE_KEY")),
        ("an API key of a sign-in site in capitals and with a dot", secret(.apiKey, url: "https://ChatGPT.COM./v1",
                                                                          password: "sk-test-0123456789abcdefghij", env: "EXAMPLE_KEY")),
        ("an API key of a key site in capitals and with a dot", secret(.apiKey, url: "https://Platform.Claude.COM./settings",
                                                                       password: "sk-test-0123456789abcdefghij", env: "EXAMPLE_KEY")),
        ("a value too long", secret(.apiKey, password: String(repeating: "k", count: LoginSecret.maxValueBytes), env: "EXAMPLE_KEY")),
        ("a reserved name", secret(.apiKey, password: "sk-test-0123456789abcdefghij", env: "PATH")),
        ("a name of a session", secret(.apiKey, password: "sk-test-0123456789abcdefghij", env: "FLEET_TOKEN")),
        ("a name that is not one", secret(.apiKey, password: "sk-test-0123456789abcdefghij", env: "1ABC")),
        ("no key", secret(.apiKey, env: "EXAMPLE_KEY")),
        ("a key with a bad address", secret(.apiKey, url: "https://", password: "sk-test-0123456789abcdefghij", env: "EXAMPLE_KEY")),
    ]

    static func secretsDocument() throws -> [String: Any] {
        let salts = try JSONDecoder().decode(SecretSalts.self, from: Data(Self.salts.utf8))
        #expect(salts.isValid)
        let rows: [[String: Any]] = Self.secrets.map { name, made in
            let value = try? made.value()
            let printed = value.flatMap { try? SecretFingerprint.of($0, salts: salts) }
            return ["name": name, "kind": made.kind.rawValue, "url": made.url, "username": made.username, "password": made.password,
                    "totp": made.totp, "env": made.env, "title": made.title, "variable": orNull(made.variable),
                    "table_address": orNull(made.tableAddress), "problem": orNull(made.problem), "vault_problem": orNull(made.vaultProblem),
                    "value": orNull(value.map { String(decoding: $0, as: UTF8.self) }),
                    "fingerprints": orNull(printed.map { $0.map { ["kind": $0.kind, "hash": $0.hash, "len": $0.len] as [String: Any] } })]
        }
        let seeds = ["JBSWY3DPEHPK3PXP", "jbsw y3dp-ehpk\t3pxp==", "otpauth://totp/Example:ana?secret=JBSW%20Y3DP+EHPK&issuer=Example",
                     "otpauth://totp/x?issuer=a&secret=&secret=abc", "otpauth://totp/x#secret=NO?secret=X", "otpauth://totp/x?a=1&secret=%E2%82%ACq%zz",
                     "otpauth://totp/x?secret=ab\ncd", "\u{1F}seed\u{3000}two"]
            .map { ["value": $0, "seed": SecretFingerprint.canonicalSeed($0)] }
        return ["salts": Self.salts, "max_value_bytes": LoginSecret.maxValueBytes, "max_label": LoginSecret.maxLabel, "secrets": rows,
                "seeds": seeds]
    }

    // MARK: - The fields' reading, the request, the rows of a replace and the card's look

    /// Addresses as an owner can type or paste one, whole and broken.
    static let addresses = ["https://example.com", "https://exa mple.com", "https://example.com/ a", "HTTPS://example.com", "https://example.com:99999",
                            "https://example.com:", "https://[::1]:8443/x", "https://user:pw@example.com", "https://@example.com",
                            "https://ex%61mple.com/x", "https://münchen.example/ü", "https://example.com?x", "https:example.com", "https:///x",
                            "//example.com", "https://example.com#f", "https://a_b.example.com", "https://example.com:80a", "https://.",
                            "http://127.0.0.1:8080/", "https://example.com\\x", "https://example.com/\"q\"", "https://example.com/%zz",
                            "https://example.com:0443/a", "https://example.com/a@b", "https://EXAMPLE.com:443", "https://exa\"mple.com",
                            "https://example.com/a|b", "https://example.com/{x}", "https://example.com/#a#b", "https://", "http://h", "",
                            "ftp://example.com", "example.com", "https://exa<mple.com", "https://example.com:-1", "https://[::1", "https://exa$mple.com",
                            "https://exa%zzmple.com", "https://[::ffff:127.0.0.1]/", "https://a@b@example.com", "https://exa^mple.com"]

    static func readingDocument() -> [String: Any] {
        func blanks(_ set: CharacterSet) -> [Int] {
            (0..<0x3100).filter { value in
                Unicode.Scalar(value).map { (String(Character($0)) + "x").trimmingCharacters(in: set) == "x" } ?? false
            }
        }
        let spaces = (0..<0x1_0000).filter { Unicode.Scalar($0).map(SecretFingerprint.isWhitespace) ?? false }
        let lines = (0..<0x3100).filter { Unicode.Scalar($0).map { Character($0).isNewline } ?? false }
        return ["addresses": addresses.map { text -> [String: Any] in
                    ["text": text, "is_address": LoginSecret.isAddress(text), "host": orNull(URLComponents(string: text)?.host),
                     "table": orNull(secret(.apiKey, url: text, password: "sk-test-0123456789abcdefghij", env: "EXAMPLE_KEY").tableAddress)]
                },
                "trims": ["whitespaces_and_newlines": blanks(.whitespacesAndNewlines), "whitespaces": blanks(.whitespaces),
                          "python_space": spaces, "newlines": lines],
                "provider_sites": ProviderSites.sites, "provider_key_sites": ProviderSites.keySites,
                "access_reasons": Dictionary(uniqueKeysWithValues: ["agent_without_key", "helper_without_broker_callers", "no_vault_store",
                    "broker_status_unknown", "vault_store_mismatch", "broker_without_callers", "another"].map { ($0, VaultAccessControl.reason($0)) })]
    }

    static func requestDocument() throws -> [String: Any] {
        let made = [
            #"{"kind": "api_key", "env": "EXAMPLE_KEY", "site": "https://api.example.com/v1", "give": {"atlas": "use", "nova": "read", "iris": "own"}}"#,
            #"{"kind": "login", "site": "https://example.com/sign-in", "account": " ana@example.com ", "note": "The second shop", "replaces": "\#(reference(3))"}"#,
            #"{"env": "example_key", "site": "ftp://example.com", "give": {"atlas": 3}, "saved": "nope", "note": "two\nlines", "account": ""}"#,
            #"{"kind": "api_key", "env": "EXAMPLE_KEY", "replaces": "\#(reference(3))", "saved": "\#(reference(4))", "clarified": 12.5}"#,
            #"{"kind": "api_key", "env": "EXAMPLE_KEY", "replaces": "bws://NOPE", "note": "\#(String(repeating: "n", count: 201))"}"#,
            #"{"kind": "api_key", "env": "EXAMPLE_KEY", "note": "\#(String(repeating: "…", count: 67))"}"#,
            #"{"kind": "api_key", "env": "EXAMPLE_KEY", "site": "https://evil.example.com/v1", "replaces": "\#(reference(3))"}"#,
        ]
        let entries = [TeamLogin(title: "example.com · ana@example.com", protected: true),
                       TeamLogin(title: "example.com · ANA@example.com", protected: true, note: ""),
                       TeamLogin(title: "example.com · other@example.com", protected: true),
                       TeamLogin(title: "example.com · ana@example.com", protected: true, note: "its own"),
                       TeamLogin(title: "EXAMPLE_KEY", protected: true, kind: "api_key", env: "EXAMPLE_KEY")]
        let requests = try made.map { text -> [String: Any] in
            let asked = try JSONDecoder().decode(NeedSecret.self, from: Data(text.utf8))
            return ["json": text, "kind": asked.kind.rawValue, "env": orNull(asked.env), "site": orNull(asked.site),
                    "give": asked.give.mapValues(\.rawValue), "saved": orNull(asked.saved), "note": orNull(asked.note),
                    "account": orNull(asked.account), "replaces": orNull(asked.replaces), "form_address": SecretValueReplace.formAddress(asked),
                    "note_goes": entries.map { asked.noteGoes(to: $0) }, "fits": entries.map { asked.fits(title: $0.name) }]
        }
        let notes = ["plain", "…", "ﬁne", "e\u{301}", "👩‍👩‍👧", "a\r\nb\u{2028}c", "  two  words\u{00A0}", String(repeating: "…", count: 80),
                     String(repeating: "👩‍👩‍👧", count: 60)]
            .map { ["text": $0, "length": NeedSecret.length($0), "note_length": NeedSecret.noteLength($0), "one_line": NeedSecret.oneLine($0, most: 200),
                    "cut_note": NeedSecret.cut($0, most: 30, note: true), "cut": NeedSecret.cut($0, most: 30)] as [String: Any] }
        let holds = [("correct horse", "is it correct horse?"), ("secret12", "mysecret12"), ("secret12", "secret12!"), ("secret12", "x secret12a, secret12"),
                     ("short", "short"), ("  secret12\n", "the secret12 one"), ("password", "passwords"), ("secret12", "secret12②"), ("sécret12", "the se\u{301}cret12 one")]
            .map { ["value": $0.0, "words": $0.1, "holds": NeedSecret.holds(value: $0.0, in: $0.1)] as [String: Any] }
        return ["requests": requests, "entries": entries.map { ["title": $0.title, "kind": orNull($0.kind), "env": orNull($0.env), "note": orNull($0.note)] },
                "notes": notes, "holds": holds]
    }

    /// The rows of a replace (`SecretReplaceAccess`): every choice of the level of now, of his own row, of a proposal, for
    /// one agent, and what Save then does.
    static func rowsDocument() -> [String: Any] {
        func word(_ grant: SecretGrant?) -> Any { orNull(grant?.rawValue) }
        var cases: [[String: Any]] = []
        for now in [nil, "use", "read", "own"] as [String?] {
            for pick in [nil, .use, .read] as [SecretGrant?] {
                for touched in [false, true] {
                    for proposal in [nil, .use, .read] as [SecretGrant?] {
                        let held = now.map { ["atlas": $0, "other": "use"] }
                        var set: [String: SecretGrant] = ["door": .use]
                        set["atlas"] = pick ?? (touched ? nil : proposal)
                        let touches: Set<String> = touched ? ["atlas"] : [], proposed: Set<String> = proposal != nil && !touched ? ["atlas"] : []
                        let offer: [String: SecretGrant] = proposal.map { ["atlas": $0] } ?? [:]
                        let shown = SecretReplaceAccess.rows(now: held, holders: ["atlas", "nova"], set: set, touched: touches, proposed: proposed)
                        let own = SecretReplaceAccess.own(rows: shown.rows, holders: ["atlas", "nova"], touched: shown.touched, raised: shown.raised,
                                                          proposal: offer, proposed: proposed)
                        let changes = SecretReplaceAccess.changes(now: held, holders: ["atlas", "nova"], rows: shown.rows, set: shown.touched,
                                                                  proposed: proposed, raised: shown.raised)
                        // the level went away meanwhile: what the form shows and what Save then does
                        let later = SecretReplaceAccess.changes(now: ["nova": "read"], holders: ["atlas", "nova"], rows: shown.rows, set: shown.touched,
                                                                proposed: proposed, raised: shown.raised)
                        cases.append(["now": orNull(held), "set": set.mapValues(\.rawValue), "touched": touches.sorted(), "proposed": proposed.sorted(),
                                      "proposal": offer.mapValues(\.rawValue), "rows": shown.rows.mapValues(\.rawValue),
                                      "kept": shown.touched.sorted(), "raised": shown.raised.mapValues(\.rawValue), "own": own.mapValues(\.rawValue),
                                      "changes": changes.map { [$0.agent, word($0.grant)] as [Any] }, "later": later.map { [$0.agent, word($0.grant)] as [Any] }])
                    }
                }
            }
        }
        return ["holders": ["atlas", "nova"], "cases": cases]
    }

    static func lookName(_ look: KeySaveLook?) -> Any {
        switch look {
        case nil: return NSNull()
        case .goes?: return "goes"
        case .saved?: return "saved"
        case .failed?: return "failed"
        }
    }

    static func lookDocument() -> [String: Any] {
        var looks: [[String: Any]] = []
        for done in [nil, false, true] as [Bool?] {
            for warned in [false, true] {
                for busy in [false, true] {
                    for saving in [false, true] {
                        looks.append(["done": orNull(done), "warned": warned, "busy": busy, "saving": saving,
                                      "look": lookName(KeySaveLook.of(done: done, warned: warned, busy: busy, saving: saving))])
                    }
                }
            }
        }
        var card = KeySaveCard(), steps: [[String: Any]] = []
        let script: [(String, KeySaveLook?)] = [("take", .goes), ("take", .goes), ("take", .saved), ("take", nil), ("settle", nil), ("take", .saved),
                                                ("take", .goes), ("settle", nil), ("take", .failed), ("end", nil), ("take", nil), ("settle", nil)]
        for (act, look) in script {
            var took: Any = NSNull()
            switch act {
            case "take": took = card.take(look)
            case "settle": card.settle()
            default: card.end()
            }
            steps.append(["act": act, "given": lookName(look), "took": took, "look": lookName(card.look), "settled": card.settled,
                          "collapsed": card.collapsed(expanded: false), "collapsed_expanded": card.collapsed(expanded: true), "holds": card.holds,
                          "folds": card.folds(answered: true, expanded: false), "folds_open": card.folds(answered: false, expanded: false),
                          "folds_expanded": card.folds(answered: true, expanded: true), "form_open": card.showsForm(open: true),
                          "form_answered": card.showsForm(open: false)])
        }
        return ["looks": looks, "card": steps]
    }

    /// The times of statements of two fleets, one after the other (`GrantClock.next`).
    static func clockDocument() -> [[String: Any]] {
        let defaults = TestDefaults("founderizer-vault-vectors")
        let first = 1_763_700_000, other = "fedcba9876543210"
        return [(fleet, first), (fleet, first), (fleet, first - 1000), (other, first - 1000), (fleet, first + 100), (fleet, first + 100 - GrantClock.ahead),
                (fleet, first + 99), (fleet, first + 100 - GrantClock.ahead + 2)]
            .map { ["fleet": $0.0, "now": $0.1, "at": GrantClock.next(fleet: $0.0, now: $0.1, in: defaults)] }
    }

    /// **A key file with `{BEGIN}` and `{END}` in place of its two armor lines**: the public copy of the apps refuses a text
    /// that has the form of a private key (`public-copy/make.py`), also a test key of a fixed label, and the C# test puts the
    /// two lines back.
    static func armorless(_ file: String) -> String {
        file.replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "{BEGIN}")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "{END}")
    }

    /// The key file with one bit of its body changed at `offset` (from the end when it is negative), in lines of 70.
    static func altered(_ file: String, at offset: Int) -> String {
        let lines = file.split(separator: "\n").map(String.init)
        var body = Data(base64Encoded: lines.dropFirst().dropLast().joined())!
        body[offset < 0 ? body.count + offset : offset] ^= 1
        let text = body.base64EncodedString()
        var out = [lines.first!]
        var at = text.startIndex
        while at < text.endIndex {
            let end = text.index(at, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[at..<end]))
            at = end
        }
        return (out + [lines.last!]).joined(separator: "\n") + "\n"
    }

    static func accessDocument() -> [String: Any] {
        let seed = fixed("owner access")
        let key = OwnerAccessKey(seed: seed)!
        #expect(OwnerAccessKey(privateFile: key.privateFile) == key)
        let other = OwnerAccessKey(seed: fixed("another owner access"))!
        // The body of a key file: the magic (15), two "none" (16), the empty options (4), the count (4), the public blob
        // (4 + 51: from 39), and the private part (4 + 160: from 94): two check numbers (98 and 102), the kind (106), the
        // public half (121, its bytes from 125), the private and public halves (157), the comment (225) and the padding.
        let files: [(String, String)] = [
            ("line ends of Windows", key.privateFile.replacingOccurrences(of: "\n", with: "\r\n")),
            ("another key", other.privateFile),
            ("the public blob's half changed", altered(key.privateFile, at: 70)),
            ("the private part's public half changed", altered(key.privateFile, at: 130)),
            ("the two check numbers differ", altered(key.privateFile, at: 101)),
            ("the private half changed", altered(key.privateFile, at: 170)),
            ("the comment's length changed into the padding", altered(key.privateFile, at: -30)),
            ("the padding changed", altered(key.privateFile, at: -1)),
        ]
        return ["seed_hex": hex(seed), "public_line": key.publicLine, "fingerprint": key.fingerprint, "private_file": armorless(key.privateFile),
                "read": files.map { name, text in
                    ["name": name, "text": armorless(text), "seed_hex": orNull(OwnerAccessKey(privateFile: text).map { hex($0.seed) })] as [String: Any]
                }]
    }

    // MARK: - The readings of GET /ui/vault, and what they decide

    static let program = String(repeating: "a", count: 64), release = String(repeating: "b", count: 64)

    static let hub = #"{"machine": "hub", "address": "100.64.0.1", "ssh": {"user": "root", "port": 22}}"#

    static func reading(central: String?, machines: String = "[]", program: String? = nil, fleet: String? = Self.fleet,
                        hub: String = Self.hub, standing: String? = nil) -> String {
        var fields = [#""db": "db-1""#, #""read_at": 1763699990.5"#, #""machines": \#(machines)"#,
                      #""held": {"worker-1": ["\#(reference(1))", "not a reference"], "worker-2": []}"#, #""hub": \#(hub)"#]
        if let standing { fields.append(#""standing": \#(standing)"#) }
        if let fleet { fields.append(#""fleet": "\#(fleet)""#) }
        if let central { fields.append(#""central": \#(central)"#) }
        if let program { fields.append(#""program": "\#(program)""#) }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// The vault's status. Its pins hold three that are no pin (a number, a recipient that is no text, a time that is no
    /// number), and `counts` writes its two whole numbers.
    static func central(recovery: Bool = true, recipient: String = Self.recipient("vault"), source: String = Self.program,
                        counts: (String, String) = ("1", "3")) -> String {
        #"{"ok": true, "recipient": "\#(recipient)", "fleet": "\#(fleet)", "owner_keys": \#(counts.0), "pins": {"worker-1": {"recipient": "\#(Self.recipient("worker-1"))", "at": 1763600000}, "bad": 3, "wrong": {"recipient": 5}, "late": {"at": "soon"}}, "#
            + (recovery ? #""recovery": "\#(Self.recipient("recovery"))", "# : "")
            + #""grants": [{"login": "\#(reference(1))", "agent": "atlas", "machine": "worker-1"}, {"login": "nope", "agent": "x", "machine": "y"}, 7], "#
            + #""pool": ["\#(reference(2))", "nope"], "items": \#(counts.1), "source": "\#(source)"}"#
    }

    static let machines = #"[{"machine": "worker-1", "carrier": "atlas", "broker_recipient": "\#(recipient("worker-1"))", "pinned": "\#(recipient("worker-1"))", "matches": true, "missing": [], "kept_pin_at": 1763000000}, "#
        + #"{"machine": "worker-2", "carrier": "nova", "broker_recipient": "\#(recipient("worker-2"))", "pinned": null, "matches": false, "missing": ["not_pinned"]}, "#
        + #"{"machine": "worker-3", "broker_recipient": "not a key", "matches": "yes", "missing": ["no_broker_access"]}, {"carrier": "x"}]"#

    static func tries(_ failures: Int, last: Double = Self.now - 60, reason: String = "It did not answer.") -> VaultTries {
        VaultTries(failures: failures, last: last, reason: reason)
    }

    static func facts(keyHeld: Bool = true, pin: String? = Self.recipient("vault"), hubOnRecord: Bool = true, otherOwner: Bool = false,
                      install: VaultTries? = nil, recovery: VaultTries? = nil, servers: [String: VaultTries] = [:],
                      update: VaultTries? = nil, removed: Set<String> = [], signedAt: [String: Double] = [:],
                      confirmedPins: [String: String] = [:]) -> VaultFacts {
        VaultFacts(keyHeld: keyHeld, pin: pin, hubOnRecord: hubOnRecord, otherOwner: otherOwner, confirmedPins: confirmedPins,
                   signedAt: signedAt, install: install, recovery: recovery, servers: servers, update: update, removed: removed, now: Self.now)
    }

    static func factsValue(_ facts: VaultFacts) -> [String: Any] {
        func value(_ tries: VaultTries?) -> Any {
            orNull(tries.map { ["failures": $0.failures, "last": $0.last, "reason": $0.reason] as [String: Any] })
        }
        return ["key_held": facts.keyHeld, "pin": orNull(facts.pin), "hub_on_record": facts.hubOnRecord, "other_owner": facts.otherOwner,
                "confirmed_recovery": orNull(facts.confirmedRecovery), "confirmed_pins": facts.confirmedPins, "signed_at": facts.signedAt,
                "install": value(facts.install), "recovery": value(facts.recovery), "servers": facts.servers.mapValues(value),
                "update": value(facts.update), "removed": facts.removed.sorted(), "removed_known": facts.removedKnown,
                "update_known": facts.updateKnown, "now": facts.now]
    }

    static func stepName(_ step: VaultStep) -> [String: Any] {
        switch step {
        case .nothing: return ["step": "nothing"]
        case .install: return ["step": "install"]
        case .recover: return ["step": "recover"]
        case .update: return ["step": "update"]
        case .takeOver: return ["step": "take_over"]
        case .trust(let machines): return ["step": "trust", "machines": machines]
        }
    }

    static func planValue(_ plan: VaultPlan) -> [String: Any] {
        var out = stepName(plan.step)
        switch plan.vault {
        case nil: out["vault"] = NSNull()
        case .retry(let step, let reason)?: out["vault"] = ["retry": stepName(step), "reason": reason]
        case .setUp(let words)?: out["vault"] = ["set_up": orNull(words)]
        }
        out["servers"] = plan.servers.map { ["machine": $0.machine, "reason": $0.reason] }
        return out
    }

    static func vaultDocument() throws -> [String: Any] {
        let readings: [(String, String)] = [
            ("a vault with its recovery key", reading(central: central(), machines: machines, program: program)),
            ("a vault with no recovery key", reading(central: central(recovery: false), machines: machines, program: program)),
            ("a vault that does not answer", reading(central: #"{"ok": false, "recipient": "\#(recipient("vault"))"}"#)),
            ("no vault", reading(central: nil, machines: machines)),
            ("no fleet", reading(central: central(), fleet: nil)),
            ("a vault of another key", reading(central: central(recipient: recipient("intruder")), machines: machines)),
            ("a fleet that is no id, and a vault's fleet", reading(central: central(), fleet: "Fleet")),
            ("a vault whose program is behind", reading(central: central(), machines: machines, program: release)),
            // after the readings that the plans name by their place
            ("a hub whose address is no text", reading(central: central(), hub: #"{"machine": "hub", "address": 7}"#)),
            ("a hub whose ssh is no object", reading(central: central(), hub: #"{"machine": "hub", "address": "100.64.0.1", "ssh": "x"}"#)),
            ("a hub whose port has a fraction", reading(central: central(), hub: #"{"machine": "hub", "ssh": {"user": "root", "port": 22.5}}"#)),
            ("a hub whose user is no text", reading(central: central(), hub: #"{"machine": "hub", "ssh": {"user": 0, "port": 22}}"#)),
            ("whole numbers written with a fraction of zero and an exponent",
             reading(central: central(counts: ("1.0", "3e0")), machines: #"[{"machine": "worker-1", "carrier": "atlas", "broker_recipient": "\#(recipient("worker-1"))", "pinned": "\#(recipient("worker-1"))", "matches": true, "missing": [], "kept_pin_at": 1763000000.0}]"#,
                     hub: #"{"machine": "hub", "address": "100.64.0.1", "ssh": {"user": "root", "port": 22.0}}"#)),
            ("the pool statements owed", reading(central: central(), standing: #"{"grants": [], "pool": [], "due": [{"login": "\#(reference(5))", "in": false}, {"login": "\#(reference(6))", "in": true}, {"login": "not a reference", "in": true}, {"login": "\#(reference(7))"}, {"login": "\#(reference(8))", "in": 1}, 3]}"#)),
            ("a standing whose due is no list", reading(central: central(), standing: #"{"due": "\#(reference(5))"}"#)),
        ]
        var rows: [[String: Any]] = []
        for (name, text) in readings {
            let read = try JSONDecoder().decode(VaultReading.self, from: Data(text.utf8))
            func sealKey(_ served: Bool, _ pin: String?) -> String {
                switch VaultSealKey.of(read, served: served, pin: pin) {
                case .key(let key): return key
                case .noVault: return "no_vault"
                case .noPin: return "no_pin"
                case .otherKey: return "other_key"
                case .noRecovery: return "no_recovery"
                }
            }
            let central = read.central
            rows.append(["name": name, "json": text, "fleet_id": orNull(read.fleetID), "program_behind": read.programBehind,
                         "trusted": orNull(read.trusted(pin: recipient("vault"))),
                         "central": orNull(central.map { c -> [String: Any] in
                             ["ok": c.ok, "recipient": orNull(c.recipient), "fleet": orNull(c.fleet), "owner_keys": orNull(c.owner_keys),
                              "pins": c.pins.mapValues { ["recipient": orNull($0.recipient), "at": orNull($0.at)] },
                              "recovery": orNull(c.recovery), "grants": c.grants.map { ["login": $0.login, "agent": $0.agent, "machine": $0.machine] },
                              "pool": c.pool, "items": orNull(c.items), "source": orNull(c.source)]
                         }),
                         "machines": read.machines.map { ["machine": $0.machine, "carrier": orNull($0.carrier), "broker_recipient": orNull($0.broker_recipient),
                                                          "pinned": orNull($0.pinned), "matches": $0.matches, "missing": $0.missing,
                                                          "kept_pin_at": orNull($0.kept_pin_at), "kept_pin_known": $0.keptPinKnown,
                                                          "is_trusted": $0.isTrusted, "can_be_trusted": $0.canBeTrusted] },
                         "held": read.held,
                         "hub": orNull(read.hub.map { ["machine": $0.machine, "address": orNull($0.address), "user": orNull($0.ssh?.user),
                                                       "port": orNull($0.ssh?.port)] }),
                         "pool_due": read.poolDue.map { ["login": $0.login, "in": $0.in] },
                         "seal_key": ["served, pinned": sealKey(true, recipient("vault")), "not served": sealKey(false, recipient("vault")),
                                      "no pin": sealKey(true, nil), "another pin": sealKey(true, recipient("other"))]])
        }
        let read = { (index: Int) in try JSONDecoder().decode(VaultReading.self, from: Data(readings[index].1.utf8)) }
        let plans: [(String, Int?, VaultFacts)] = [
            ("no reading", nil, facts()),
            ("no vault: the install", 3, facts()),
            ("no vault and no record of the hub's machine", 3, facts(hubOnRecord: false)),
            ("no vault, another owner", 3, facts(otherOwner: true)),
            ("no vault, the install gave up", 3, facts(install: tries(6))),
            ("no vault, the install waits", 3, facts(install: tries(2))),
            ("this computer holds no key", 0, facts(keyHeld: false)),
            ("this computer pinned another key", 0, facts(pin: recipient("other"))),
            ("no recovery key", 1, facts()),
            ("no recovery key, its tries gave up", 1, facts(recovery: tries(6), update: tries(0, last: now - 7200))),
            ("the trust of a new server and a stale pin", 0, facts()),
            ("a server whose trust gave up", 0, facts(servers: ["worker-2": tries(6)])),
            ("a server removed here", 0, facts(removed: ["worker-2"])),
            ("a pin signed today", 0, facts(signedAt: ["worker-1": now - 600], confirmedPins: ["worker-2": recipient("worker-2")])),
            ("the program is behind", 7, facts()),
            ("the update gave up an hour ago", 7, facts(update: tries(6, last: now - 3601))),
            ("the update gave up a minute ago", 7, facts(update: tries(6))),
        ]
        var planRows: [[String: Any]] = []
        for (name, index, made) in plans {
            let reading = try index.map(read)
            planRows.append(["name": name, "reading": orNull(index.map { readings[$0].0 }), "facts": factsValue(made),
                             "plan": planValue(VaultPlan.of(reading, facts: made))])
        }
        let pairs: [(Double, Double?)] = [(now, now + 3600), (now, now + 3601), (now + 3601, now), (now, nil)]
        let clock = pairs.map { hub, read -> [String: Any] in
            ["hub_time": hub, "read_at": orNull(read), "problem": orNull(VaultPlan.clockProblem(hubTime: hub, readAt: read))]
        }
        // the pool statements of the hub's default and their ends, with a login in capitals (`OwnerStatement`)
        let given = reference(9).uppercased(), at = 1_790_000_000
        let statements: [[String: Any]] = [
            ["kind": "default_pool", "fleet": fleet, "login": given, "at": at, "statement": OwnerStatement.defaultPool(fleet: fleet, login: given, at: at)],
            ["kind": "unpool", "fleet": fleet, "login": given, "at": at, "statement": OwnerStatement.unpool(fleet: fleet, login: given, at: at)],
        ]
        return ["readings": rows, "plans": planRows, "clock": clock, "statements": statements, "pin_refresh": VaultPlan.pinRefresh, "resign_wait": VaultPlan.resignWait,
                "retry_every": VaultPlan.retryEvery, "tries_wait": VaultTries.wait, "tries_most": VaultTries.most,
                "grant_clock_ahead": GrantClock.ahead]
    }

    static func document() throws -> [String: Any] {
        ["about": "The vault's core on the owner's computer (windows-app-plan-v2.md, 5.6, piece L5), made by FleetCore for fixed inputs: "
            + "an age seal, the recovery code and its copy for a phone, the salted fingerprints, the owner access key, the form's secrets, "
            + "and the readings of GET /ui/vault with what the seal and the plan decide. Every key here is a test key of a fixed label.",
         "made_by": madeBy, "seal": try sealDocument(), "recovery": try recoveryDocument(), "secrets": try secretsDocument(),
         "owner_access": accessDocument(), "vault": try vaultDocument(), "reading": readingDocument(), "request": try requestDocument(),
         "rows": rowsDocument(), "look": lookDocument(), "grant_clock": clockDocument()]
    }

    @Test("The vault's vectors are what FleetCore gives now")
    func theVaultVectorsAreTheCommittedFile() throws {
        let made = try Localized.$bundle.withValue(WordsVectorsTests.noTable) {
            try JSONSerialization.data(withJSONObject: Self.document(), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                + Data("\n".utf8)
        }
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            try made.write(to: URL(fileURLWithPath: out).appendingPathComponent(Self.file))
            return
        }
        let committed = try Data(contentsOf: Self.folder.appendingPathComponent(Self.file))
        #expect(committed == made, "app/vectors/\(Self.file) is not what FleetCore gives: run app/vectors/make_vectors.py")
    }
}
