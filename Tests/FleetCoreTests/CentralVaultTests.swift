import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// The fleet's central vault from the owner's Mac: the statements its key signs, the key, the recovery code, the reading
/// of `GET /ui/vault`, the fingerprints of a central save and the programs that run over his SSH connection.
/// Synthetic values only. The expected statements and fingerprints are what Python's `json.dumps` and the backend's
/// own `vault.py` printed for the same input, and the recovery vector is one that the real `age-keygen -y` and `age`
/// confirmed: the identity gives this recipient, and a file sealed to the recipient opens with the identity.
struct CentralVaultTests {
    static let recipient = "age1aahjzcwvvmrhch43mhx4w5pld4uwqvcv5wsyrf6k493ggmm3wqus7rxumd"
    static let fleet = "0f1e2d3c4b5a6978"
    static let reference = "bws://12345678-1234-4234-8234-123456789012"

    // MARK: statements

    @Test func aStatementIsTheJSONThatPythonWrites() {
        #expect(OwnerStatement.pin(fleet: Self.fleet, machine: "hel1", recipient: Self.recipient, at: 1_761_300_000)
                == #"{"at":1761300000,"fleet":"0f1e2d3c4b5a6978","kind":"pin","machine":"hel1","recipient":"age1aahjzcwvvmrhch43mhx4w5pld4uwqvcv5wsyrf6k493ggmm3wqus7rxumd","v":1}"#)
        #expect(OwnerStatement.unpin(fleet: Self.fleet, machine: "hel1", at: 1_761_300_001)
                == #"{"at":1761300001,"fleet":"0f1e2d3c4b5a6978","kind":"unpin","machine":"hel1","v":1}"#)
        #expect(OwnerStatement.recovery(fleet: Self.fleet, recipient: Self.recipient, at: 1_761_300_002)
                == #"{"at":1761300002,"fleet":"0f1e2d3c4b5a6978","kind":"recovery","recipient":"age1aahjzcwvvmrhch43mhx4w5pld4uwqvcv5wsyrf6k493ggmm3wqus7rxumd","v":1}"#)
        // Python's escapes with ensure_ascii=False: a quote, a backslash, the short escapes and \u00XX for the other
        // control characters, and everything else as it is: DEL, U+2028 and the letters that are not ASCII. Keys go
        // in the order of their code points, so "Z" before "a" and "été" last.
        let fields: [String: OwnerStatement.Value] = [
            "b": .text("say \"hi\" \\ back"), "a": .text("tab\there\nline\u{01}\u{1F}\u{7F}"),
            "\u{E9}t\u{E9}": .text("caf\u{E9} \u{2028} \u{DF}"), "Z": .number(-5)]
        let expected = #"{"Z":-5,"a":"tab\there\nline\u0001\u001f\#u{7F}","b":"say \"hi\" \\ back","\#u{E9}t\#u{E9}":"caf\#u{E9} \#u{2028} \#u{DF}"}"#
        #expect(OwnerStatement.canonical(fields) == expected)
        #expect(Data(OwnerStatement.canonical(fields).utf8).count == 91)       // the length of Python's UTF-8 bytes
        #expect(OwnerStatement.now() > 1_761_000_000)
    }

    /// The signed grants (owner feature `signed_grants`), byte for byte as the central vault's own `canonical` writes
    /// them: `vault.py` keeps exactly these fields of each kind, and a reference in lower case.
    @Test func aGrantStatementIsTheJSONThatTheVaultChecks() {
        let upper = "bws://12345678-1234-4234-8234-12345678ABCD"
        #expect(OwnerStatement.grant(fleet: Self.fleet, login: upper, agent: "vps", machine: "worker-1", at: 1_761_300_003)
                == #"{"agent":"vps","at":1761300003,"fleet":"0f1e2d3c4b5a6978","kind":"grant","login":"bws://12345678-1234-4234-8234-12345678abcd","machine":"worker-1","v":1}"#)
        #expect(OwnerStatement.ungrant(fleet: Self.fleet, login: Self.reference, agent: "vps", at: 1_761_300_004)
                == #"{"agent":"vps","at":1761300004,"fleet":"0f1e2d3c4b5a6978","kind":"ungrant","login":"bws://12345678-1234-4234-8234-123456789012","v":1}"#)
        #expect(OwnerStatement.pool(fleet: Self.fleet, login: Self.reference, at: 1_761_300_005)
                == #"{"at":1761300005,"fleet":"0f1e2d3c4b5a6978","kind":"pool","login":"bws://12345678-1234-4234-8234-123456789012","v":1}"#)
        #expect(OwnerStatement.unpool(fleet: Self.fleet, login: Self.reference, at: 1_761_300_006)
                == #"{"at":1761300006,"fleet":"0f1e2d3c4b5a6978","kind":"unpool","login":"bws://12345678-1234-4234-8234-123456789012","v":1}"#)
    }

    /// The owner's yes to a door call (owner feature `door_calls`), byte for byte as the door's check reads it
    /// (`door.approval`, with the central vault's `canonical`): exactly these six fields.
    @Test func aDoorCallStatementIsTheJSONThatTheDoorChecks() {
        let call = String(repeating: "c", count: 64)
        #expect(OwnerStatement.doorCall(fleet: Self.fleet, need: 7, call: call, at: 1_761_300_007)
                == #"{"at":1761300007,"call":"\#(call)","fleet":"0f1e2d3c4b5a6978","kind":"door-call","need":7,"v":1}"#)
    }

    /// The vault keeps a grant statement only when it is newer than the one it holds, so two changes in one second
    /// are two seconds apart here, for each fleet on its own.
    @Test func eachGrantStatementOfAFleetIsLaterThanTheLast() throws {
        let defaults = try #require(UserDefaults(suiteName: "founderizer-test-\(UUID().uuidString)"))
        #expect(GrantClock.next(fleet: Self.fleet, now: 1_761_300_000, in: defaults) == 1_761_300_000)
        #expect(GrantClock.next(fleet: Self.fleet, now: 1_761_300_000, in: defaults) == 1_761_300_001)
        #expect(GrantClock.next(fleet: Self.fleet, now: 1_761_299_000, in: defaults) == 1_761_300_002)    // a clock set back
        #expect(GrantClock.next(fleet: Self.fleet, now: 1_761_400_000, in: defaults) == 1_761_400_000)
        #expect(GrantClock.next(fleet: "0123456789abcdef", now: 1_761_300_000, in: defaults) == 1_761_300_000)
    }

    // MARK: the hub's machine

    @Test func theHubsMachineIsTheManagersWhateverTailscaleCallsIt() throws {
        func row(_ agent: String, _ machine: String, _ role: String) throws -> MachineStatus {
            let fields: [String: Any] = ["agent": agent, "machine": machine, "role": role, "update": [String: Any](),
                                         "runtime": ["signed_in": true], "security": [String: Any](), "os": [String: Any]()]
            return try JSONDecoder().decode(MachineStatus.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        // The hub follows each server's name in Tailscale (server_names), so its machine is not "hub" for long
        #expect(CentralVault.hubMachine(in: [try row("leo", "worker-1", "worker"), try row("manager", "worker-2", "manager")])
                == "worker-2")
        #expect(CentralVault.hubMachine(in: [try row("manager", "hub", "manager")]) == "hub")
        #expect(CentralVault.hubMachine(in: []) == "hub")
    }

    // MARK: the owner's key

    @Test func aSoftwareOwnerKeySignsWhatCryptoKitVerifies() throws {
        let key = SoftwareOwnerKey()
        #expect(key.publicKey.count == 88)
        let point = try #require(Data(base64Encoded: key.publicKey))
        #expect(point.count == 65 && point.first == 0x04)
        let statement = OwnerStatement.pin(fleet: Self.fleet, machine: "hel1", recipient: Self.recipient, at: 1_761_300_000)
        let der = try #require(Data(base64Encoded: try key.sign(statement)))
        // SEQUENCE { INTEGER r, INTEGER s }, which CryptoKit reads back.
        #expect(der.first == 0x30 && Int(der[1]) == der.count - 2 && der[2] == 0x02)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        let verifier = try P256.Signing.PublicKey(x963Representation: point)
        #expect(verifier.isValidSignature(signature, for: Data(statement.utf8)))
        #expect(!verifier.isValidSignature(signature, for: Data(statement.replacingOccurrences(of: "hel1", with: "hel2").utf8)))
        #expect(!SoftwareOwnerKey().publicKey.isEmpty && SoftwareOwnerKey().publicKey != key.publicKey)
    }

    /// A copy that is not the app as its Developer ID signed it, this test's runner too, touches none of the owner's
    /// keychain items: each such build has a signature of its own, and macOS would stop him for his password at each.
    /// Asking whether an item is there reads no secret, so even the owner's own Mac shows no prompt for this test.
    @Test func aCopyThatIsNotTheSignedAppTouchesNoKeychainItem() throws {
        try #require(!FleetKeychainItem.developerIDSigned)
        #expect(!OwnerKeychain.isHeld(fleet: Self.fleet) && !RecoveryKeychain.item.isHeld(fleet: Self.fleet))
        let item = FleetKeychainItem(service: "com.founderizer.test-\(UUID().uuidString)", label: "test item")
        #expect(throws: FleetKeychainItem.Failure.self) { try item.keep(Data("synthetic".utf8), fleet: Self.fleet) }
        #expect(item.read(fleet: Self.fleet) == nil)
    }

    // MARK: the recovery code

    @Test func aRecoveryCodeIs26CrockfordSymbolsInGroupsOfFour() throws {
        let code = try RecoveryCode.make()
        #expect(code.normalized.count == 26 && code.normalized.allSatisfy(RecoveryCode.alphabet.contains))
        #expect(code.grouped.range(of: "^([0-9A-HJKMNP-TV-Z]{4}-){6}[0-9A-HJKMNP-TV-Z]{2}$", options: .regularExpression) != nil)
        #expect(RecoveryCode(code.grouped) == code && RecoveryCode(code.grouped.lowercased()) == code)
        #expect(try RecoveryCode.make() != code)
        // Each symbol is the low five bits of one byte.
        let counted = try RecoveryCode.make { Data((0..<UInt8($0)).map { $0 }) }
        #expect(counted.normalized == "0123456789ABCDEFGHJKMNPQRS" && counted.grouped == "0123-4567-89AB-CDEF-GHJK-MNPQ-RS")
        #expect(try RecoveryCode.make { Data(repeating: 0xFF, count: $0) }.normalized == String(repeating: "Z", count: 26))
        #expect(throws: AgeSeal.Failure.random) { try RecoveryCode.make { _ in Data(count: 3) } }
        // Nothing prints it.
        #expect(!"\(code)".contains(code.normalized) && !String(reflecting: code).contains(code.normalized))
        #expect(Mirror(reflecting: code).children.isEmpty)
    }

    @Test func aCodeIsReadAsCrockfordReadsIt() {
        #expect(RecoveryCode.normalized(" o123-4567 89ab\ncdef-ghjk-mnpq-rs ") == "0123456789ABCDEFGHJKMNPQRS")
        #expect(RecoveryCode.normalized("Il1O0o") == "111000")
        #expect(RecoveryCode("OI23-4567-89AB-CDEF-GHJK-MNPQ-RS")?.normalized == "0123456789ABCDEFGHJKMNPQRS")
        #expect(RecoveryCode("0123-4567-89AB-CDEF-GHJK-MNPQ-R") == nil)          // 25 symbols
        #expect(RecoveryCode("0123-4567-89AB-CDEF-GHJK-MNPQ-RSS") == nil)        // 27
        #expect(RecoveryCode("U123-4567-89AB-CDEF-GHJK-MNPQ-RS") == nil)         // U is no symbol
    }

    @Test func aFixedCodeGivesItsAgeKeys() throws {
        let code = try #require(RecoveryCode("0123-4567-89AB-CDEF-GHJK-MNPQ-RS"))
        #expect(code.recipient == "age1wxf6a2an5vh325jh25qs9dpemgwrxp0lgsuxhkr9yqtpyzfq99assg55x8")
        #expect(code.identity == "AGE-SECRET-KEY-16AYRQTSV723Z8MZ5XNTT08DYJMKKQA6GDHCTM5Y9AR28KT28XRKQKH9VZX")
        // The recipient reads back through the decoder that seals every copy, as the X25519 key of the identity.
        let share = try #require(AgeSeal.publicKey(of: code.recipient))
        #expect(share == (try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: code.privateKey)).publicKey.rawRepresentation)
        #expect(AgeSeal.isSealed(try AgeSeal.seal(Data("synthetic backup key".utf8), to: code.recipient)))
    }

    @Test func bech32ReadsBackThroughTheDecoder() throws {
        #expect(AgeSeal.bech32("age", try #require(AgeSeal.publicKey(of: Self.recipient))) == Self.recipient)
        for _ in 0..<32 {
            let bytes = try AgeSeal.secureRandom(32)
            let text = AgeSeal.bech32("age", bytes)
            #expect(text.count == 62 && AgeSeal.publicKey(of: text) == bytes)
        }
        #expect(AgeSeal.bech32("AGE-SECRET-KEY-", Data(count: 32)).hasPrefix("age-secret-key-1"))
    }

    // MARK: GET /ui/vault

    static let unset = """
        {"db": "gen-1", "fleet": "0f1e2d3c4b5a6978", "central": null, "read_at": null,
         "error": "the central vault does not answer", "machines": [
          {"machine": "vps", "carrier": "vps", "broker_recipient": "\(recipient)", "pinned": null, "matches": false,
           "missing": ["not_pinned"]}], "held": {}}
        """

    static let set = """
        {"db": "gen-1", "fleet": "0f1e2d3c4b5a6978", "kit": "/home/fleet/fleet-pilot", "read_at": 1761300100.5, "error": null,
         "new_field": {"any": "thing"},
         "central": {"ok": true, "v": 2, "central": true, "recipient": "age1wxf6a2an5vh325jh25qs9dpemgwrxp0lgsuxhkr9yqtpyzfq99assg55x8",
                     "store_recipient": "\(recipient)", "fleet": "0f1e2d3c4b5a6978", "owner_keys": 1,
                     "pins": {"vps": {"recipient": "\(recipient)", "at": 1761300000}, "bad": "not a pin"},
                     "recovery": null, "items": 3, "source": "0f0f",
                     "grants": [{"login": "\(reference)", "agent": "vps", "machine": "vps"}, {"login": "not a reference"}],
                     "pool": ["\(reference)", "nope"]},
         "machines": [
          {"machine": "vps", "carrier": "vps", "broker_recipient": "\(recipient)", "pinned": "\(recipient)", "matches": true, "missing": []},
          {"machine": "worker4", "carrier": "worker4", "broker_recipient": "\(recipient)", "pinned": "age1wxf6a2an5vh325jh25qs9dpemgwrxp0lgsuxhkr9yqtpyzfq99assg55x8",
           "matches": false, "missing": ["pin_mismatch"]},
          {"machine": "mac-studio", "carrier": null, "broker_recipient": null, "pinned": null, "matches": false,
           "missing": ["broker_without_deposits"]},
          {"carrier": "nameless"}],
         "held": {"vps": ["\(reference)", "not a reference"]}}
        """

    @Test func aReadingWithoutACentralVaultStillNamesTheFleet() throws {
        let reading = try JSONDecoder().decode(VaultReading.self, from: Data(Self.unset.utf8))
        #expect(reading.central == nil && reading.fleetID == Self.fleet)
        #expect(reading.error == "the central vault does not answer" && reading.held.isEmpty)
        #expect(reading.trusted(pin: Self.recipient) == nil)
        let vps = try #require(reading.machines.first)
        #expect(vps.canBeTrusted && !vps.isTrusted && vps.why == "You have not trusted its vault yet.")
    }

    @Test func aReadingWithACentralVaultIsReadTolerantly() throws {
        let reading = try JSONDecoder().decode(VaultReading.self, from: Data(Self.set.utf8))
        let central = try #require(reading.central)
        #expect(central.ok && central.recipient == "age1wxf6a2an5vh325jh25qs9dpemgwrxp0lgsuxhkr9yqtpyzfq99assg55x8")
        #expect(central.store_recipient == Self.recipient && central.recovery == nil && central.owner_keys == 1 && central.items == 3)
        #expect(Array(central.pins.keys) == ["vps"] && central.pins["vps"]?.recipient == Self.recipient)
        // A "kit" that an older hub still sends names no path the app runs, and a grant it cannot read is left out.
        #expect(central.grants == [CentralStatus.Grant(login: Self.reference, agent: "vps", machine: "vps")])
        #expect(central.pool == [Self.reference])
        #expect(central.source == nil && reading.program == nil && reading.hub == nil && !reading.programBehind)
        #expect(reading.read_at == 1_761_300_100.5 && reading.error == nil)
        // The entry without a machine is left out; the rest stays.
        #expect(reading.machines.map(\.machine) == ["vps", "worker4", "mac-studio"])
        #expect(reading.held == ["vps": [Self.reference]])
        let (vps, worker4, mac) = (reading.machines[0], reading.machines[1], reading.machines[2])
        #expect(vps.isTrusted && vps.canBeTrusted)
        #expect(!worker4.isTrusted && worker4.canBeTrusted && worker4.why == "Its vault answers with another key than the one you trusted.")
        #expect(!mac.isTrusted && !mac.canBeTrusted && mac.why == VaultMachine.reason("broker_without_deposits"))
        // Add secret seals to the central vault only under the key this Mac pinned.
        #expect(reading.trusted(pin: central.recipient) == central.recipient)
        #expect(reading.trusted(pin: Self.recipient) == nil && reading.trusted(pin: nil) == nil)
        let stopped = Self.set.replacingOccurrences(of: #""ok": true"#, with: #""ok": false"#)
        #expect(try JSONDecoder().decode(VaultReading.self, from: Data(stopped.utf8)).trusted(pin: central.recipient) == nil)
    }

    /// UI-API 1.87: the hub names the `vault.py` of its release and the vault's own machine with its record; the vault
    /// names the program it runs. Where the two programs differ the vault is behind, and a side that says nothing is not.
    @Test func aReadingSaysWhetherTheVaultRunsTheProgramOfTheHubsRelease() throws {
        let release = String(repeating: "a", count: 64), running = String(repeating: "b", count: 64)
        let record = #"{"machine": "hub-1", "address": "100.64.0.2", "ssh": {"user": "root", "port": 22}}"#
        func reading(source: String?, program: String?, hub: String = record, ok: Bool = true) throws -> VaultReading {
            let json = Self.set
                .replacingOccurrences(of: #""source": "0f0f""#, with: #""source": "# + (source.map { "\"\($0)\"" } ?? "null"))
                .replacingOccurrences(of: #""new_field": {"any": "thing"},"#,
                                      with: #""program": "# + (program.map { "\"\($0)\"" } ?? "null") + #", "hub": "# + hub + ",")
                .replacingOccurrences(of: #""ok": true"#, with: #""ok": \#(ok)"#)
            return try JSONDecoder().decode(VaultReading.self, from: Data(json.utf8))
        }
        let behind = try reading(source: running, program: release)
        #expect(behind.central?.source == running && behind.program == release && behind.programBehind)
        #expect(try reading(source: release, program: release).programBehind == false)
        #expect(try reading(source: nil, program: release).programBehind == false)            // a vault that says nothing
        #expect(try reading(source: running, program: nil).programBehind == false)            // a hub that says nothing
        #expect(try reading(source: running, program: release, ok: false).programBehind == false)
        #expect(try reading(source: running.uppercased(), program: release).central?.source == nil)
        let hub = try #require(behind.hub)
        #expect(hub.machine == "hub-1" && hub.reach.onRecord?.address == "100.64.0.2")
        #expect(hub.reach.onRecord?.user == "root" && hub.reach.onRecord?.port == 22)
        let none = try reading(source: running, program: release, hub: #"{"machine": "hub-1", "address": "100.64.0.2", "ssh": null}"#)
        #expect(none.hub?.machine == "hub-1" && none.hub?.reach.onRecord == nil)
        #expect(try reading(source: running, program: release, hub: #"{"machine": "Not A Name"}"#).hub == nil)
        #expect(try reading(source: running, program: release, hub: "null").hub == nil)
    }

    @Test func aReadingDropsWhatIsNotAFleetOrAKey() throws {
        let odd = Self.unset.replacingOccurrences(of: "0f1e2d3c4b5a6978", with: "0F1E")
            .replacingOccurrences(of: Self.recipient, with: "age1notakey")
        let reading = try JSONDecoder().decode(VaultReading.self, from: Data(odd.utf8))
        #expect(reading.fleetID == nil && reading.machines.first?.broker_recipient == nil)
        #expect(reading.machines.first?.canBeTrusted == false)
    }

    // MARK: a save into the central vault

    static let salts = SecretSalts(login: reference, password: "00112233445566778899aabbccddeeff", totp: "ffeeddccbbaa99887766554433221100")

    static func value(_ fields: [String: String]) throws -> Data { try JSONSerialization.data(withJSONObject: fields) }

    @Test func fingerprintsAreTheOnesVaultPyMakes() throws {
        let password = SecretFingerprint(kind: "password", hash: "e6442df15d3680c714267590437b4751d2c6cec9a14301c0b6eb6d3d8e0a2685", len: 23)
        let seed = SecretFingerprint(kind: "totp", hash: "81442a2022bc44f2c685b2d1cb21bc97b783916b0e494c78fec4c0dcd71eeee1", len: 16)
        let address = "otpauth://totp/Example:alice?issuer=Ex+ample&secret=jbsw%20y3dp-ehpk3pxp&secret=OTHERSEED"
        #expect(try SecretFingerprint.of(Self.value(["username": "alice", "password": "synthetic-PASSWORD-0123", "url": "https://example.com/login",
                                                      "totp": address]), salts: Self.salts)
                == [password, SecretFingerprint(kind: "totp", hash: "678924c7f706cd9a14d00973a2013b9ca52c5b546e3fd74a635bd3ebc75b80fc", len: 89), seed])
        // A seed with spaces is no fingerprint as typed, and one in its canonical form.
        #expect(try SecretFingerprint.of(Self.value(["username": "alice", "password": "synthetic-PASSWORD-0123", "url": "https://example.com/login",
                                                      "totp": "JBSW Y3DP EHPK 3PXP"]), salts: Self.salts) == [password, seed])
        #expect(try SecretFingerprint.of(Self.value(["username": "", "password": "sk-synthetic-0123456789"]), salts: Self.salts)
                == [SecretFingerprint(kind: "password", hash: "286ba645598b385d4519dec653f80cd31b09a58e8032aed9a674bbf6eb8ef3a7", len: 23)])
        #expect(try SecretFingerprint.of(Self.value(["username": "", "password": "short7!"]), salts: Self.salts).isEmpty)
        #expect(try SecretFingerprint.of(Self.value(["username": "", "password": "has a space in it"]), salts: Self.salts).isEmpty)
        // A blank `secret` is skipped, the first one with a value wins, and nothing after "#" counts.
        let blank = "otpauth://totp/x?secret=&secret=ABCDEFGHIJKL#frag?secret=NO"
        #expect(try SecretFingerprint.of(Self.value(["username": "a", "password": "synthetic-PASSWORD-0123", "url": "https://e.com",
                                                      "totp": blank]), salts: Self.salts)
                == [password, SecretFingerprint(kind: "totp", hash: "2e33e284357c002e1ee75de12ab8a408d49bef77c77cabbd90331b20c6c0e95e", len: 59),
                    SecretFingerprint(kind: "totp", hash: "209c79f3d07150af1b00c22357404dd6280fb29860dfd3d2c9a0be38129473cc", len: 12)])
        #expect(SecretFingerprint.canonicalSeed("otpauth://totp/x?secret=ab%2Dcd%3Def%zz%4") == "ABCDEF%ZZ%4")
        #expect(throws: HubError.self) { try SecretFingerprint.of(Data("{}".utf8), salts: Self.salts) }
    }

    /// The central vault keeps a value only when every fingerprint `vault.py` makes of it is among the registered ones,
    /// the seed in its canonical form too whenever that differs from the seed as typed. So the add command of a central
    /// save registers all of them, from the form's own value: these are what `vault.py` made of the same login.
    @Test func aCentralSaveRegistersTheSeedInBothForms() throws {
        let password = "password e6442df15d3680c714267590437b4751d2c6cec9a14301c0b6eb6d3d8e0a2685 23"
        let canonical = "totp 81442a2022bc44f2c685b2d1cb21bc97b783916b0e494c78fec4c0dcd71eeee1 16"
        let seeds = [("otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example",
                      "totp d4f5767ce228afeb263d53e0c42a8600a6dbfb3d1e6a6911e77489390bf9fd3b 67"),
                     ("jbswy3dpehpk3pxp", "totp c65e4287811060531ba5832048bb5631a9d4444764e32c1ac1ce84d2eee7e55d 16")]
        for (seed, typed) in seeds {
            var login = LoginSecret()
            login.url = "https://example.com/login"; login.username = "alice"; login.password = "synthetic-PASSWORD-0123"; login.totp = seed
            #expect(login.problem == nil)
            let prints = try SecretFingerprint.of(login.value(), salts: Self.salts)
            let body = try SecretCommand.add(requestID: UUID(), database: "gen-1", login: Self.reference, title: login.title, kind: .login,
                                             variable: nil, fingerprints: prints)
            let sent = try #require((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["fingerprints"] as? [[String: Any]])
            let registered = sent.map { "\($0["kind"] as? String ?? "") \($0["hash"] as? String ?? "") \($0["len"] as? Int ?? 0)" }
            #expect(registered == [password, typed, canonical], "\(seed)")
        }
        // A seed already in its canonical form is one fingerprint, as in vault.py: the two forms are the same value.
        var plain = LoginSecret()
        plain.url = "https://example.com/login"; plain.username = "alice"; plain.password = "synthetic-PASSWORD-0123"; plain.totp = "JBSWY3DPEHPK3PXP"
        #expect(try SecretFingerprint.of(plain.value(), salts: Self.salts).map { "\($0.kind) \($0.hash) \($0.len)" } == [password, canonical])
    }

    @Test func aFormValueIsSealedForTheVaultAndNothingElseIsSent() throws {
        var login = LoginSecret()
        login.url = "https://example.com/login"; login.username = "alice"; login.password = "synthetic-PASSWORD-0123"
        let value = try login.value()
        #expect(SecretFingerprint.areValid(try SecretFingerprint.of(value, salts: Self.salts)))
        let sealed = try AgeSeal.seal(value, to: Self.recipient)
        let id = UUID()
        let body = try VaultCommand.intake(requestID: id, database: "gen-1", login: Self.reference, ciphertext: sealed)
        #expect(!String(decoding: body, as: UTF8.self).contains("synthetic-PASSWORD-0123"))
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(object == ["request_id": id.uuidString.lowercased(), "db": "gen-1", "login": Self.reference, "ciphertext": sealed])
        #expect(throws: HubError.self) {
            try VaultCommand.intake(requestID: id, database: "gen-1", login: Self.reference, ciphertext: "synthetic-PASSWORD-0123")
        }
        #expect(throws: HubError.self) { try VaultCommand.intake(requestID: id, database: "gen-1", login: "bws://nope", ciphertext: sealed) }
    }

    @Test func aSignedStatementGoesAsItIs() throws {
        let key = SoftwareOwnerKey(), id = UUID()
        let statement = OwnerStatement.recovery(fleet: Self.fleet, recipient: Self.recipient, at: 1_761_300_002)
        let signature = try key.sign(statement)
        let body = try VaultCommand.signed(requestID: id, database: "gen-1", statement: statement, signature: signature)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(object == ["request_id": id.uuidString.lowercased(), "db": "gen-1", "statement": statement, "signature": signature])
        #expect(throws: HubError.self) { try VaultCommand.signed(requestID: id, database: "gen-1", statement: statement, signature: "not base64") }
        #expect(throws: HubError.self) { try VaultCommand.signed(requestID: id, database: "gen-1", statement: "", signature: signature) }
    }

    @Test func thePinOfTheVaultsKeyIsKeptByHubAndFleet() throws {
        let suite = "central-vault-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = try HubClient.address("http://100.80.1.2:8765"), other = try HubClient.address("http://100.80.1.3:8765")
        #expect(CentralVaultPins.recipient(hub: hub, fleet: Self.fleet, in: defaults) == nil)
        CentralVaultPins.pin(Self.recipient, hub: hub, fleet: Self.fleet, in: defaults)
        #expect(CentralVaultPins.recipient(hub: hub, fleet: Self.fleet, in: defaults) == Self.recipient)
        #expect(CentralVaultPins.recipient(hub: other, fleet: Self.fleet, in: defaults) == nil)
        #expect(CentralVaultPins.recipient(hub: hub, fleet: "0000000000000000", in: defaults) == nil)
    }

    // MARK: over SSH

    @Test func theVaultsStepsCheckTheHostKeyStrictly() {
        let target = InstallTarget(host: "100.80.1.2", user: "sam", port: 2222, identityFile: "/Users/owner/.ssh/id_ed25519", becomeRoot: true)
        let arguments = CentralVaultRemote.arguments(target: target, program: "echo 'hi'")
        #expect(arguments.contains("StrictHostKeyChecking=yes") && !arguments.contains(where: { $0.contains("accept-new") }))
        #expect(arguments.contains("BatchMode=yes") && arguments.contains("2222") && arguments.contains("/Users/owner/.ssh/id_ed25519"))
        #expect(arguments.suffix(2) == ["sam@100.80.1.2", #"sudo -n -i -- /bin/sh -c 'echo '\''hi'\'''"#])
        let root = InstallTarget(host: "100.80.1.2")
        #expect(CentralVaultRemote.arguments(target: root, program: "echo hi").suffix(2) == ["root@100.80.1.2", "echo hi"])
    }

    /// DevOps plan V2: the install runs from root's own clone at its one fixed place, never from a path that the hub
    /// names, after the clone took the hub's newest signed release. The app's own install keeps another owner's vault.
    @Test func theInstallRunsFromRootsOwnCloneWithTheOwnersKey() throws {
        let key = SoftwareOwnerKey().publicKey
        #expect(CentralVaultRemote.rootKit == "/usr/local/lib/founderizer-kit")
        #expect(CentralVaultRemote.install(ownerKey: key, keepOwner: false)
                == CentralVaultRemote.bridge() + "; python3 /usr/local/lib/founderizer-kit/hubsetup.py kit-clone && "
                + "python3 /usr/local/lib/founderizer-kit/hubsetup.py central-vault --owner-key '\(key)'")
        #expect(CentralVaultRemote.install(ownerKey: key, keepOwner: true)
                == CentralVaultRemote.bridge() + "; python3 /usr/local/lib/founderizer-kit/hubsetup.py kit-clone && "
                + "python3 /usr/local/lib/founderizer-kit/hubsetup.py central-vault --owner-key '\(key)' --keep-owner")
        #expect(CentralVaultRemote.install(ownerKey: "AAAA", keepOwner: true) == nil)
        #expect(CentralVaultRemote.install(ownerKey: Data(count: 65).base64EncodedString(), keepOwner: false) == nil)
        // What hubsetup.py prints for a vault of another owner key, after whatever it said before.
        #expect(CentralVaultRemote.installed("Founderizer: root's own clone is at release 2026.11.200 already\n"
                + #"{"ok": false, "owner": "other", "error": "the central vault on this machine holds another owner key"}"# + "\n")
                == .otherOwner)
        #expect(CentralVaultRemote.installed(#"{"ok": false, "owner": "this", "error": "it stopped"}"#) == .refused("it stopped"))
    }

    /// UI-API 1.87, the bridge across the key change of 4 November 2026: root's clone of a hub installed before that
    /// day has no `early-key.pub`, and its own `kit-clone` checks a release with `release-key.pub` alone. Only in such
    /// a clone, the install first writes this build's own release keys into that file, never a key the hub names.
    /// The shell text runs here, in `/bin/sh`, on a folder that stands in for root's clone.
    @Test func theInstallBridgesOnlyAnOldCloneAndWithThisBuildsOwnKeys() throws {
        let ours = (AppUpdate.shippedKeys + "\n" + AppUpdate.earlyKeys).split(separator: "\n").map(String.init)
        #expect(ours.count == 3 && ours.allSatisfy { Data(base64Encoded: $0)?.count == 32 })
        #expect(CentralVaultRemote.bridge().hasPrefix("if test -d /usr/local/lib/founderizer-kit/.git && "
                                                     + "! test -e /usr/local/lib/founderizer-kit/early-key.pub; then "))
        func run(_ folder: URL) throws -> Int32 {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", CentralVaultRemote.bridge(in: folder.path)]
            try shell.run()
            shell.waitUntilExit()
            return shell.terminationStatus
        }
        let fm = FileManager.default
        let old = "# the website's key, which signed every release up to 2026.11.200\nWEBSITEKEYWEBSITEKEYWEBSITEKEYWEBSITEKEY12=\n"
        func clone(git: Bool, early: Bool) throws -> URL {
            let folder = fm.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if git { try fm.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true) }
            if early { try Data(AppUpdate.earlyKeys.utf8).write(to: folder.appendingPathComponent("early-key.pub")) }
            try Data(old.utf8).write(to: folder.appendingPathComponent("release-key.pub"))
            return folder
        }
        let before = try clone(git: true, early: false)              // a clone from before the key change
        defer { try? fm.removeItem(at: before) }
        #expect(try run(before) == 0)
        #expect(try String(contentsOf: before.appendingPathComponent("release-key.pub"), encoding: .utf8)
                == ours.joined(separator: "\n") + "\n")
        for (git, early) in [(true, true), (false, false)] {          // a clone of the change or later, and no clone
            let folder = try clone(git: git, early: early)
            defer { try? fm.removeItem(at: folder) }
            #expect(try run(folder) == 0)
            #expect(try String(contentsOf: folder.appendingPathComponent("release-key.pub"), encoding: .utf8) == old)
        }
    }

    @Test func theInstallsLastLineIsItsAnswer() {
        let fresh = "age-keygen: wrote /var/lib/fleet-vault-central/age.key\nCreated symlink …\n"
            + #"{"ok": true, "recipient": "\#(Self.recipient)", "store_recipient": "\#(Self.recipient)", "fleet": "0f1e2d3c4b5a6978"}"# + "\n"
        #expect(CentralVaultRemote.installed(fresh) == .installed(recipient: Self.recipient, fleet: Self.fleet))
        #expect(CentralVaultRemote.installed(#"{"ok": true}"# + "\n" + #"{"ok": false, "error": "this is not the hub's machine"}"#)
                == .refused("this is not the hub's machine"))
        #expect(CentralVaultRemote.installed(#"{"ok": true, "recipient": "age1notakey", "fleet": "0f1e2d3c4b5a6978"}"#)
                == .refused("It printed no vault key and no fleet that Founderizer can read."))
        #expect(CentralVaultRemote.installed("sudo: a password is required\n") == nil)
        #expect(CentralVaultRemote.installed("") == nil)
    }

    @Test func onlyAServersPublicKeyLineLeavesIt() {
        #expect(!CentralVaultRemote.readBrokerKey.contains("cat ") && CentralVaultRemote.readBrokerKey.contains(CentralVaultRemote.brokerConfig))
        #expect(CentralVaultRemote.readBrokerKey.contains(#"grep -m1 -E '^# public key: age1[0-9a-z]{58}$'"#))
        #expect(CentralVaultRemote.brokerKey(in: "# public key: \(Self.recipient)\n") == Self.recipient)
        #expect(CentralVaultRemote.brokerKey(in: "Welcome\n  # public key: \(Self.recipient)  \n") == Self.recipient)
        #expect(CentralVaultRemote.brokerKey(in: "# public key: age1wxf6a2an5vh325jh25qs9dpemgwrxp0lgsuxhkr9yqtpyzfq99assg55x8\n"
                                                  + "# public key: \(Self.recipient)\n") == nil)     // two keys are none
        #expect(CentralVaultRemote.brokerKey(in: "# public key: age1notakey\n") == nil)
        #expect(CentralVaultRemote.brokerKey(in: "Host key verification failed.\n") == nil)
        // A Mac's key: Founderizer Vault's own status, asked as its user through its socket, with no sudo and no file.
        let mac = CentralVaultRemote.readMacVaultKey
        #expect(mac.hasPrefix("python3 -c '") && !mac.contains("sudo") && !mac.contains("cat "))
        #expect(mac.contains(#"~/Library/Application Support/AgentFleet/vault.sock"#) && mac.contains(#"\"op\": \"status\""#))
        #expect(mac.contains(##"print("# public key: " + str(json.loads(s.makefile().readline()).get("recipient")))"##))
        #expect(CentralVaultRemote.brokerKey(in: "# public key: None\n") == nil)                  // a vault with no key
        #expect(CentralVault.isMachine("worker4") && !CentralVault.isMachine("Worker4") && !CentralVault.isMachine("4worker"))
        #expect(CentralVault.isFleet(Self.fleet) && !CentralVault.isFleet("0F1E2D3C4B5A6978"))
    }
}
