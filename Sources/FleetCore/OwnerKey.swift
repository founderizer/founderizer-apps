import CryptoKit
import Foundation
import Security

/// **What the owner signs for the fleet's central vault** (owner feature `central_vault`), in the one spelling that
/// vault checks.
///
/// The central vault on the hub's server trusts the hub as before with one exception, which is the reason it exists:
/// it seals a copy of a secret only to a server key that the owner signed, and its backup only to a recovery key that
/// the owner signed. So a hub that is broken into cannot name a server of its own and pull every secret through it.
///
/// A statement is the canonical JSON of one flat object of text and whole numbers: keys sorted, no white space,
/// non-ASCII as it is, and Python's string escapes. It must equal Python's `json.dumps(obj, sort_keys=True,
/// separators=(",", ":"), ensure_ascii=False)` of the object it parses to, which is how `vault.py` checks it, so the
/// app and the vault sign and verify the same bytes and neither depends on how the other happens to print JSON.
public enum OwnerStatement {
    /// One value of a statement. The vault's statements hold text and whole numbers and nothing else.
    public enum Value: Equatable, Sendable { case text(String), number(Int) }

    /// The canonical JSON of a flat object.
    public static func canonical(_ fields: [String: Value]) -> String {
        // Python sorts keys by their code points, and so does a comparison of the scalars; `<` on two Strings would
        // compare them as Unicode text instead, which is not the same order for every pair.
        let keys = fields.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        let members = keys.map { key -> String in
            switch fields[key]! {
            case .text(let text): return quoted(key) + ":" + quoted(text)
            case .number(let number): return quoted(key) + ":" + String(number)
            }
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    /// One string as Python's encoder writes it with `ensure_ascii=False`: `"` and `\` escaped, the five control
    /// characters that have a short escape written with it, every other one below U+0020 as `\u` and four lower-case
    /// hex digits, and everything else as it is — U+007F and the line separators too, which Python leaves alone.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The central vault may seal a copy for `machine` to `recipient`, the key of that machine's own vault.
    public static func pin(fleet: String, machine: String, recipient: String, at: Int = now()) -> String {
        canonical(["v": .number(1), "kind": .text("pin"), "fleet": .text(fleet), "machine": .text(machine),
                   "recipient": .text(recipient), "at": .number(at)])
    }

    /// The central vault may no longer seal anything for `machine`.
    public static func unpin(fleet: String, machine: String, at: Int = now()) -> String {
        canonical(["v": .number(1), "kind": .text("unpin"), "fleet": .text(fleet), "machine": .text(machine), "at": .number(at)])
    }

    /// The central vault seals its backup to `recipient`, the key of the owner's recovery code.
    public static func recovery(fleet: String, recipient: String, at: Int = now()) -> String {
        canonical(["v": .number(1), "kind": .text("recovery"), "fleet": .text(fleet), "recipient": .text(recipient), "at": .number(at)])
    }

    /// The central vault may seal `login` to the vault of `machine` for `agent`: the owner gave the agent this secret
    /// (owner feature `signed_grants`). Without such a statement, or the secret in the pool, the vault seals it for no
    /// machine, so a hub that is broken into cannot send a secret to a machine the owner did not give it to.
    public static func grant(fleet: String, login: String, agent: String, machine: String, at: Int) -> String {
        canonical(["v": .number(1), "kind": .text("grant"), "fleet": .text(fleet), "login": .text(login.lowercased()),
                   "agent": .text(agent), "machine": .text(machine), "at": .number(at)])
    }

    /// The owner took the secret back from the agent: its grant no longer lets the vault seal it.
    public static func ungrant(fleet: String, login: String, agent: String, at: Int) -> String {
        canonical(["v": .number(1), "kind": .text("ungrant"), "fleet": .text(fleet), "login": .text(login.lowercased()),
                   "agent": .text(agent), "at": .number(at)])
    }

    /// The secret is in the grantable pool: the fleet manager may give it to an agent on any machine, so the vault may
    /// seal it to any machine that the owner pinned.
    public static func pool(fleet: String, login: String, at: Int) -> String {
        canonical(["v": .number(1), "kind": .text("pool"), "fleet": .text(fleet), "login": .text(login.lowercased()),
                   "at": .number(at)])
    }

    /// The owner's yes to one door call (owner feature `door_calls`, DevOps plan 5.4): the door lets the call whose hash
    /// is `call` through once, for the Needs-you item `need`. The door checks this signature against the owner keys of
    /// its own access file, so the hub that carries it can hold it back and forge none.
    public static func doorCall(fleet: String, need: Int, call: String, at: Int = now()) -> String {
        canonical(["v": .number(1), "kind": .text("door-call"), "fleet": .text(fleet), "need": .number(need),
                   "call": .text(call), "at": .number(at)])
    }

    /// The owner's mode of one server (owner feature `door_modes`, the door-modes proposal, step 4): `full` is the door
    /// card's second answer, Full access on that server, which lets every later root script there through. The door
    /// keeps the newest statement of each server and checks it against the owner keys of its own access file, so the
    /// hub that carries it can hold it back and forge none.
    public static func doorMode(fleet: String, host: String, mode: String, at: Int = now()) -> String {
        canonical(["v": .number(1), "kind": .text("door-mode"), "fleet": .text(fleet), "host": .text(host),
                   "mode": .text(mode), "at": .number(at)])
    }

    /// The owner key's certificate of one phone's own signing key (owner feature `door_calls`): the door accepts that
    /// phone's yes to a door call only through it. The Mac signs it once the phone's binding matched its QR.
    public static func ownerDevice(fleet: String, device: String, key: String, at: Int = now()) -> String {
        canonical(["v": .number(1), "kind": .text("owner-device"), "fleet": .text(fleet), "device": .text(device),
                   "key": .text(key), "at": .number(at)])
    }

    /// The owner puts a new value under a reference that the central vault holds (owner feature `secret_replace`).
    /// `sha256` is of the sealed copy that this app made (`checksum`), so the statement is about that one copy and no
    /// other: the vault takes the new value only with it, and the hub that carries both can forge neither.
    public static func replace(fleet: String, login: String, sha256: String, at: Int) -> String {
        canonical(["v": .number(1), "kind": .text("replace"), "fleet": .text(fleet), "login": .text(login.lowercased()),
                   "sha256": .text(sha256), "at": .number(at)])
    }

    /// The SHA-256 of a sealed copy's text, in lower-case hex: what a replace statement says of its copy.
    public static func checksum(_ sealed: String) -> String {
        SHA256.hash(data: Data(sealed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The secret is out of the grantable pool again.
    public static func unpool(fleet: String, login: String, at: Int) -> String {
        canonical(["v": .number(1), "kind": .text("unpool"), "fleet": .text(fleet), "login": .text(login.lowercased()),
                   "at": .number(at)])
    }

    /// The time a statement carries: whole Unix seconds. The vault refuses a statement that is not newer than the last
    /// one of its kind (for the same machine), except that same statement again, so a retry is safe.
    public static func now() -> Int { Int(Date().timeIntervalSince1970) }
}

/// **The time of the owner's next grant statement** for a fleet: whole Unix seconds, and always later than the last one
/// this Mac signed for it. The central vault keeps a grant statement only when it is newer than the one it holds for
/// the same secret and agent, and two changes of one grant can come in one second.
public enum GrantClock {
    static let key = "signedGrantClock"

    public static func next(fleet: String, now: Int = OwnerStatement.now(), in defaults: UserDefaults = .standard) -> Int {
        var all = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        let at = max(now, (all[fleet] ?? 0) + 1)
        all[fleet] = at
        defaults.set(all, forKey: key)
        return at
    }
}

/// **The owner's signing key**: ECDSA P-256, in this Mac's Secure Enclave where it has one, so that its private half
/// never exists outside that chip, and a software key on a Mac without one. The central vault keeps the public half
/// (`owner_keys`, written by the install) and takes a pin or a recovery key only with its signature. A protocol, so
/// that a test signs with a software key and never touches the Keychain.
public protocol OwnerKey {
    /// Base64 (standard, padded) of the 65-byte uncompressed point, `0x04 || X || Y`: what the install hands the vault.
    var publicKey: String { get }
    /// Base64 of the DER signature (SEQUENCE { INTEGER r, INTEGER s }) over SHA-256 of the statement's UTF-8 bytes.
    func sign(_ statement: String) throws -> String
}

/// An owner key in this app's memory, for a Mac without a Secure Enclave and for the tests.
public struct SoftwareOwnerKey: OwnerKey {
    let key: P256.Signing.PrivateKey
    public init(_ key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) { self.key = key }
    public var publicKey: String { key.publicKey.x963Representation.base64EncodedString() }
    public func sign(_ statement: String) throws -> String {
        try key.signature(for: Data(statement.utf8)).derRepresentation.base64EncodedString()
    }
}

/// An owner key in this Mac's Secure Enclave: CryptoKit hands the chip the statement, and the chip hands back the
/// signature.
public struct EnclaveOwnerKey: OwnerKey {
    let key: SecureEnclave.P256.Signing.PrivateKey
    public var publicKey: String { key.publicKey.x963Representation.base64EncodedString() }
    public func sign(_ statement: String) throws -> String {
        try key.signature(for: Data(statement.utf8)).derRepresentation.base64EncodedString()
    }
}

/// **One generic password of this app for each fleet**, readable while this Mac is unlocked, on this Mac only, and
/// never in iCloud: the app has no keychain access group, so the item stays in this Mac's login keychain. It is how
/// the owner key and the recovery code are kept, and nothing else of the central vault is.
///
/// **Only the app as its Developer ID signed it touches the item.** The keychain trusts the signature of the app that
/// wrote it, and a copy signed ad hoc (`run.sh`, a test, a screenshot) has a new signature at each build, so macOS
/// stops the owner for his login password at every copy that reads it, and "Always Allow" holds for that one copy
/// only. So a copy holds, reads and keeps nothing here, and asks him nothing.
public struct FleetKeychainItem: Sendable {
    public let service: String
    /// What the item is, in the owner's words, for the keychain's own list and for a refusal.
    public let label: String

    /// Whether this process is signed with a Developer ID, as every build that `release.sh` makes is. Read once.
    public static let developerIDSigned: Bool = {
        #if os(macOS)
        // Apple's mark of a Developer ID application on the leaf, and of the Developer ID authority on its issuer.
        let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        var me: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(me, [], requirement) == errSecSuccess
        #else
        return true         // an iPhone's keychain asks nobody about the app's own items
        #endif
    }()

    public struct Failure: LocalizedError, Equatable {
        public let label: String
        public let status: OSStatus
        public var errorDescription: String? { String(l10n: "This Mac's keychain did not keep the \(label) (\(Int(status))).") }
    }

    private func query(fleet: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: fleet]
    }

    /// Whether the item is there, without reading it, so that a reading every minute costs no prompt.
    public func isHeld(fleet: String) -> Bool {
        guard Self.developerIDSigned else { return false }
        var request = query(fleet: fleet)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    public func read(fleet: String) -> Data? {
        guard Self.developerIDSigned else { return nil }
        var request = query(fleet: fleet)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }

    /// Takes the item away. One that is not there is no failure.
    public func remove(fleet: String) {
        guard Self.developerIDSigned else { return }
        SecItemDelete(query(fleet: fleet) as CFDictionary)
    }

    /// Keeps `data` in place of anything this item held.
    public func keep(_ data: Data, fleet: String) throws {
        guard Self.developerIDSigned else { throw Failure(label: label, status: errSecInteractionNotAllowed) }
        let values: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                     kSecAttrSynchronizable as String: false,
                                     kSecAttrLabel as String: "Founderizer · \(label)"]
        var add = query(fleet: fleet)
        add.merge(values) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(query(fleet: fleet) as CFDictionary, values as CFDictionary)
            guard updated == errSecSuccess else { throw Failure(label: label, status: updated) }
        } else if status != errSecSuccess {
            throw Failure(label: label, status: status)
        }
    }
}

/// **Where the owner key is kept** (service `com.founderizer.owner-key`, account the fleet's id). For an enclave key
/// the item holds the chip's own wrapped form (`dataRepresentation`), which opens on no other Mac; for a software key,
/// the key itself. Nothing but the central vault's install, its recovery key and its pins reads it.
public enum OwnerKeychain {
    public static let item = FleetKeychainItem(service: "com.founderizer.owner-key", label: "owner key")

    /// Whether this Mac holds an owner key for the fleet, without reading it.
    public static func isHeld(fleet: String) -> Bool { item.isHeld(fleet: fleet) }

    /// The owner key this Mac holds for the fleet, or nil.
    public static func key(fleet: String) -> (any OwnerKey)? {
        guard let data = item.read(fleet: fleet) else { return nil }
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            return EnclaveOwnerKey(key: key)
        }
        return (try? P256.Signing.PrivateKey(rawRepresentation: data)).map { SoftwareOwnerKey($0) }
    }

    /// A new owner key for the fleet, kept in place of any earlier one. The install that follows gives the central
    /// vault its public half and takes the earlier one away, so one Mac at a time signs for a fleet.
    public static func make(fleet: String) throws -> any OwnerKey {
        let made: (any OwnerKey, Data)
        // A Mac whose enclave refuses a key still gets one: a software key, kept the same way.
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            made = (EnclaveOwnerKey(key: key), key.dataRepresentation)
        } else {
            let key = P256.Signing.PrivateKey()
            made = (SoftwareOwnerKey(key), key.rawRepresentation)
        }
        try item.keep(made.1, fleet: fleet)
        return made.0
    }
}
