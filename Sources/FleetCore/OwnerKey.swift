import CryptoKit
import Foundation
import Security
import Synchronization

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
    /// machine. **The machine is the one that the hub names for the agent at the moment of the Give**
    /// (`GrantSigning.grant`): a hub that is broken into can name another machine there, and the vault then seals the
    /// secret to that machine only while the owner pinned its key, also with a pin that he signs later (the vault
    /// manager's choice C50).
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

    /// The secret is in the grantable pool by the hub's default (owner feature `pool_default`): what the owner's app
    /// signs under the hood. The vault takes it as a `pool`, but never over the owner's own `unpool` of that secret,
    /// which only their own `pool` ends, so a hub that is broken into cannot undo their "Only you" (`vault.py`).
    public static func defaultPool(fleet: String, login: String, at: Int) -> String {
        canonical(["v": .number(1), "kind": .text("default_pool"), "fleet": .text(fleet),
                   "login": .text(login.lowercased()), "at": .number(at)])
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

/// **The time of the owner's next grant statement** for a fleet: whole Unix seconds, and one second after the last one
/// this Mac signed for it, or now when that is later. The central vault keeps a grant statement only when it is newer
/// than the one it holds for the same secret and agent, and two changes of one grant can come in one second.
///
/// **It is never more than `ahead` after this Mac's clock** (the vault manager's choice C50). The central vault
/// refuses a statement of any kind dated more than a day after its own clock (owner API 1.217; before it, only a pin
/// and an unpin), so a last time that is `ahead` or more after this Mac's clock, from a clock that ran ahead once, is
/// not followed, and the next statement is dated now. The app's own controls sign a give, a `pool` or a replace only
/// while this Mac's clock and the hub's are no more than an hour apart (`GrantSigning`, `VaultPlan.clockProblem`), so
/// for those a restart comes from a last time of a clock that ran ahead, not from a clock that is behind now; a
/// take-back, an `unpool` and the link tools do not check the clock. A statement that the vault already holds from
/// ahead stays there until its time, and this Mac's next change of that record is refused until then.
public enum GrantClock {
    static let key = "signedGrantClock"
    /// The most that a statement's time is after this Mac's clock: one hour less than the central vault's `PIN_AHEAD`
    /// (one day), so that a statement is not refused for its time while the two clocks are no more than an hour apart.
    /// So a last time from 23 to 24 hours ahead also starts again from now, where the vault would still take it.
    public static let ahead = 86400 - 3600

    public static func next(fleet: String, now: Int = OwnerStatement.now(), in defaults: UserDefaults = AppDefaults.store) -> Int {
        var all = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        let last = all[fleet] ?? 0
        let at = last >= now && last - now < ahead ? last + 1 : now     // no overflow, also for a damaged value
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

    public struct Failure: LocalizedError, Equatable, Sendable {
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

    /// **The item's data, or the keychain's status when it gives none**: `errSecItemNotFound` says that the item is not
    /// there; a locked keychain, a refusal, and a build with no Developer ID (`errSecInteractionNotAllowed`, which
    /// touches nothing) give another status. `read` gives nil for all of them.
    public func lookup(fleet: String) -> Result<Data, Failure> {
        guard Self.developerIDSigned else { return .failure(Failure(label: label, status: errSecInteractionNotAllowed)) }
        var request = query(fleet: fleet)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        guard status == errSecSuccess else { return .failure(Failure(label: label, status: status)) }
        guard let data = value as? Data else { return .failure(Failure(label: label, status: errSecDecode)) }
        return .success(data)
    }

    /// **A read of the item, told apart** (two Opus readers of the Windows owner key, and the Door area's read, 24
    /// November 2026): `none` only when the keychain says that the item is not there; `notNow` for any other status
    /// (locked, refused, a missing entitlement, a build with no Developer ID) and for held data that `decode` cannot
    /// read now. Only `none` may lead to a new value: else one passing error puts a new value over the one kept.
    public enum Held<Value> {
        case value(Value)
        case none
        case notNow(Failure)
    }

    /// `Held` of the keychain's answer `read`.
    public func held<Value>(_ read: Result<Data, Failure>, decode: (Data) -> Value?) -> Held<Value> {
        switch read {
        case .success(let data):
            if let value = decode(data) { return .value(value) }
            return .notNow(Failure(label: label, status: errSecDecode))
        case .failure(let failure):
            return failure.status == errSecItemNotFound ? .none : .notNow(failure)
        }
    }

    /// **A new value goes in only where the keychain says that the item is not there**: it throws for held data and for
    /// every other status, so nothing is kept over a value that a read could not give now.
    public func mayMake(_ read: Result<Data, Failure>) throws {
        switch read {
        case .failure(let failure) where failure.status == errSecItemNotFound: return
        case .failure(let failure): throw failure
        case .success: throw Failure(label: label, status: errSecDuplicateItem)
        }
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
/// the key itself. Only the central vault's install, its recovery key and its pins read it, and the sweep of the
/// server records (F17's SP1, `ServerMade.sweep`), which signs with it in the background: at most one round a minute,
/// until a round did all that it had in this start of the app. The sweep writes nothing to the Keychain.
public enum OwnerKeychain {
    public static let item = FleetKeychainItem(service: "com.founderizer.owner-key", label: "owner key")

    /// **Whether this Mac holds an owner key for the fleet that it can use**, with no read of the item's data and no
    /// signature on the caller's thread: the item is there, and no look of this run found that no chip of this Mac
    /// opens it (`otherMac`). Until the first look of a run for that fleet ends, the item's presence answers, as before
    /// the look, and this call starts that look (`look(fleet:)`, off the caller's actor, one at a time for each fleet);
    /// the vault's plan waits for it. So a Mac that Migration Assistant or a restore made from another Mac holds no key
    /// for the plan, whose row then says Set up, and no call of the main actor waits for the chip (the Door area's read
    /// of 25 November 2026: the four give paths of LinkTools call this on the main actor).
    public static func isHeld(fleet: String) -> Bool {
        let there = item.isHeld(fleet: fleet), known = seen.withLock { $0.other[fleet] }
        if there && known == nil { Task.detached { _ = await look(fleet: fleet) } }
        return there && known != true
    }

    /// Whether the run's look found that no chip of this Mac opens the fleet's item (`VaultFacts.keyOtherMac`).
    public static func isOtherMac(fleet: String) -> Bool { seen.withLock { $0.other[fleet] } == true }

    /// **`isHeld` off the main actor, one look at a time for each fleet** (the Door area's read of 24 November 2026): the
    /// first look of a run reads the item and signs once with the chip, and a chip or a token daemon that does not answer
    /// holds the thread that asks (one read waited 13 minutes on 24 November 2026). Each caller while a look runs waits
    /// for that same look, so a vault reading each minute holds one thread of the shared pool, never one more each minute.
    public static func look(fleet: String) async -> Bool {
        await look(fleet: fleet, in: looks) {
            isHeld(there: item.isHeld(fleet: fleet), known: seen.withLock { $0.other[fleet] }) { lookup(fleet: fleet) }
        }
    }

    /// The looks that run now, for each fleet (`look`), and how many callers wait for each: one record, so that a
    /// caller counts only once it waits for the look that runs.
    final class Looks: Sendable {
        struct Record {
            var running: [String: Task<Bool, Never>] = [:]
            var callers: [String: Int] = [:]
        }
        let record = Mutex(Record())
    }
    private static let looks = Looks()

    /// `look`'s rule, with the record of the looks that run and the look given.
    static func look(fleet: String, in looks: Looks, _ body: @escaping @Sendable () -> Bool) async -> Bool {
        let task = looks.record.withLock { record in
            record.callers[fleet, default: 0] += 1
            if let task = record.running[fleet] { return task }
            let task = Task.detached(operation: body)
            record.running[fleet] = task
            return task
        }
        let held = await task.value
        looks.record.withLock { record in
            if record.running[fleet] == task { record.running[fleet] = nil }
            let left = (record.callers[fleet] ?? 1) - 1
            record.callers[fleet] = left > 0 ? left : nil
        }
        return held
    }

    /// `isHeld`'s rule: whether the item is there, what this run knows of it, and the lookup for a first read.
    static func isHeld(there: Bool, known other: Bool?, lookup: () -> Lookup) -> Bool {
        guard there else { return false }
        if let other { return !other }
        if case .otherMac = lookup() { return false }
        return true
    }

    /// **What this Mac holds for the fleet, told apart** (two Opus readers of the Windows owner key, 24 November 2026):
    /// `none` only when the keychain says that the item is not there; `notNow` when the keychain gives another status
    /// (locked, refused, a build with no Developer ID) or the chip does not answer now. Only `none` and `otherMac` may
    /// lead to a new key: before, one passing error made `key` nil, and the install then made a new owner key over the
    /// old one, a new identity for the hub with no word to the owner, whose pins the Linux brokers refuse.
    public enum Lookup {
        case key(any OwnerKey)
        case none
        /// **Held data that no chip of this Mac can ever use** (the supervisor's item of 24 November 2026): the wrapped
        /// key of another Mac's enclave, which Migration Assistant or a Time Machine restore brings with the login
        /// keychain (the item is in the file-based keychain, where "this device only" does not hold), or a damaged
        /// item. Its key is lost on this Mac, so the owner's Set up makes this Mac's own key in its place: the path of
        /// a new Mac (VAULT.md, "Know what a new Mac changes").
        case otherMac
        case notNow(FleetKeychainItem.Failure)
    }

    /// The owner key this Mac holds for the fleet, told apart from none, from another Mac's and from a read that failed
    /// now. It keeps its answer for `isHeld`. `fresh`: past this run's marks, with a new proof (`make`).
    public static func lookup(fleet: String, fresh: Bool = false) -> Lookup {
        let read = item.lookup(fleet: fleet)
        let digest: Data?
        if case .success(let data) = read { digest = Data(SHA256.hash(data: data)) } else { digest = nil }
        return settle(lookup(read, open: { open($0, fresh: fresh) }), digest: digest, fleet: fleet)
    }

    /// The lookup's answer as this run keeps it for `isHeld`, under one lock with the record of the proved forms: a
    /// form that a look at the same moment proved is never another Mac's in this run (the coordinator's validator's
    /// M1), so the two looks agree that it is held, in whichever order they end; that look's answer is then not now.
    static func settle(_ found: Lookup, digest: Data?, fleet: String) -> Lookup {
        let provedNow = seen.withLock { seen -> Bool in
            if case .otherMac = found, let digest, seen.proved.contains(digest) {
                seen.other[fleet] = false
                return true
            }
            switch found {
            case .key: seen.other[fleet] = false
            case .otherMac: seen.other[fleet] = true
            case .none: seen.other[fleet] = nil
            case .notNow: if seen.other[fleet] == nil { seen.other[fleet] = false }    // looked: held, as before
            }
            return false
        }
        return provedNow ? .notNow(FleetKeychainItem.Failure(label: item.label, status: errSecNotAvailable)) : found
    }

    /// The owner key this Mac holds for the fleet, or nil (none, another Mac's, or not now): for a step that signs,
    /// which stops.
    public static func key(fleet: String) -> (any OwnerKey)? {
        if case .key(let key) = lookup(fleet: fleet) { return key }
        return nil
    }

    /// `lookup`'s rule, with the keychain's answer and the opening of its data given.
    static func lookup(_ read: Result<Data, FleetKeychainItem.Failure>, open: (Data) -> Opened) -> Lookup {
        switch item.held(read, decode: { Optional(open($0)) }) {
        case .value(.key(let key)): return .key(key)
        case .value(.otherMac): return .otherMac
        case .value(.notNow(let status)): return .notNow(FleetKeychainItem.Failure(label: item.label, status: status))
        case .none: return .none
        case .notNow(let failure): return .notNow(failure)
        }
    }

    /// What the item's data gives on this Mac.
    enum Opened {
        case key(any OwnerKey)
        case otherMac
        case notNow(OSStatus)
    }

    /// What this run knows: for each fleet, whether its item is another Mac's (`isHeld`); the SHA-256 of each wrapped
    /// form that this Mac's chip signed with already (`open`), so the proof costs one signature a run and the form is
    /// never another Mac's in the run; and of each one that the chip refused itself while a new key of this chip signed
    /// (`open`), so it reaches CryptoKit once a run. A form that makes CryptoKit fail in another way (the system's token
    /// daemon `ctkd` crashes or does not answer) gets no mark and reaches CryptoKit at each lookup, as before this
    /// check; launchd stops restarting that daemon after a run of crashes (it did after 17 on 24 November 2026), and
    /// every Secure Enclave key of the Mac then waits. A lookup comes at the first `isHeld` of a run and at each step
    /// that signs, never at each vault reading.
    private struct Seen {
        var other: [String: Bool] = [:]
        var proved: Set<Data> = []
        var refused: Set<Data> = []
    }
    private static let seen = Mutex(Seen())

    /// The statement of the proof that this Mac's chip opens a wrapped key. Nothing checks it but the chip's answer.
    static let proof = "Founderizer: this Mac's Secure Enclave opens its owner key"

    static func open(_ data: Data, fresh: Bool = false) -> Opened {
        open(data, chip: chip, enclave: SecureEnclave.isAvailable, fresh: fresh, wrapped: {
            EnclaveOwnerKey(key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: $0))
        }, control: {
            // a new key of this chip, kept nowhere, made as `make` makes one: CryptoKit's default access (when unlocked,
            // this device only, no user presence), so a locked Mac refuses it as it refuses the owner key, and it asks
            // the owner nothing
            _ = try EnclaveOwnerKey(key: SecureEnclave.P256.Signing.PrivateKey()).sign(proof)
        })
    }

    /// **Whether this Mac has a Secure Enclave, by its hardware** (the Door area's read of 24 November 2026): each
    /// Apple silicon Mac and each iPhone has one, and a simulator has none. CryptoKit's `SecureEnclave.isAvailable` asks
    /// the system's token daemon, which says no while it is down or held back (it was, on 24 November 2026), so it
    /// never decides alone that a Mac has no chip. nil on an Intel Mac, where only that daemon says it, and in a
    /// virtual machine on Apple silicon (Tart, UTM), which has no enclave of its own (the coordinator's validator's
    /// N1): there CryptoKit decides, and the vault's install makes a software key where it sees none.
    static var chip: Bool? {
        #if targetEnvironment(simulator)
        return chip(simulator: true, arm64: true, virtual: false)
        #elseif arch(arm64)
        return chip(simulator: false, arm64: true, virtual: virtualMachine)
        #else
        return chip(simulator: false, arm64: false, virtual: false)
        #endif
    }

    /// `chip`'s rule. Never false by the token daemon's word, which a passing fault gives (the Door area's read of
    /// d26776ffb): in a virtual machine CryptoKit decides, so a form moved into one stays not now and keeps the key.
    static func chip(simulator: Bool, arm64: Bool, virtual: Bool) -> Bool? {
        if simulator { return false }
        return arm64 && !virtual ? true : nil
    }

    /// Whether this system runs in a virtual machine, as the kernel says (`kern.hv_vmm_present`).
    static var virtualMachine: Bool {
        var present: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
    }

    /// **A software key from its raw form (32 bytes), else an enclave key from its wrapped form, proved by one
    /// signature.** The chip opens only its own wrapped keys, and CryptoKit says so only at a signature: the wrapped
    /// form of another Mac's chip opens and gives its public key, and its first signature fails (CryptoTokenKit's
    /// "corrupted data", measured on 24 November 2026). That failure, and a wrapped form that CryptoKit cannot read,
    /// are `otherMac` only where a control works at that moment (the coordinator's validator's M1: a new key of this
    /// chip signs the proof) and the held form, tried once more after it, fails the same way (the Door area's read). A
    /// locked Mac, a token daemon that restarts and each other passing state fail the control too, and are `notNow`
    /// with no mark; a form that this chip signed with in this run is never `otherMac`. A wrapped form on hardware with
    /// no chip is `otherMac`. Each other answer is `notNow`, which keeps the key: errSecNotAvailable for a state that
    /// passes (`available` false on a Mac with a chip, or on an Intel Mac, and another error), and errSecDecode only for
    /// a form that cannot be read (`passing`), and for a form whose public point is damaged. CryptoKit reads that point with a `try!` of its own, so
    /// `EnclaveBlob` reads it first, and a damaged one never reaches CryptoKit; it is `notNow`, never a new key, so a
    /// later inner layout of Apple's that this check does not know never leads every Mac to Set up. `fresh`: past this
    /// run's marks, with a new proof.
    static func open(_ data: Data, chip: Bool?, enclave available: Bool, fresh: Bool = false,
                     wrapped: (Data) throws -> any OwnerKey, control: () throws -> Void) -> Opened {
        if data.count == 32 {
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else { return .notNow(errSecDecode) }
            return .key(SoftwareOwnerKey(key))
        }
        if chip == false { return .otherMac }               // a wrapped form on hardware with no chip that opens it
        if EnclaveBlob.point(in: data) == .damaged { return .notNow(errSecDecode) }
        guard available else { return .notNow(errSecNotAvailable) }
        let digest = Data(SHA256.hash(data: data))
        let (proved, refused) = seen.withLock { ($0.proved.contains(digest), $0.refused.contains(digest)) }
        if !fresh, refused { return .otherMac }
        // The chip's own refusal (-3, -8) is another Mac's key only where the chip answers now (the control: a new key
        // of this chip signs) and still refuses this form after it (the held form, tried once more: the Door area's
        // read of 25 November 2026), so a state that ends in between (an unlock, the daemon back) gives the key.
        func refusal(_ error: Error, again: () throws -> any OwnerKey) -> Opened {
            guard Self.unusable(error) else { return .notNow(Self.passing(error)) }
            guard !proved else { return .notNow(errSecNotAvailable) }       // it signed in this run: a state that passes
            do { try control() } catch { return .notNow(errSecNotAvailable) }
            do {
                let key = try again()
                seen.withLock {
                    $0.proved.insert(digest)
                    $0.refused.remove(digest)
                }
                return .key(key)
            } catch let error where Self.unusable(error) {
                let marked = seen.withLock { seen -> Bool in
                    guard !seen.proved.contains(digest) else { return false }      // a look at the same moment proved it
                    seen.refused.insert(digest)
                    return true
                }
                return marked ? .otherMac : .notNow(errSecNotAvailable)
            } catch {
                return .notNow(Self.passing(error))
            }
        }
        let key: any OwnerKey
        do {
            key = try wrapped(data)
        } catch {
            return refusal(error) {
                let key = try wrapped(data)
                _ = try key.sign(proof)
                return key
            }
        }
        if !fresh, proved { return .key(key) }
        do {
            _ = try key.sign(proof)
        } catch {
            return refusal(error) {
                _ = try key.sign(proof)
                return key
            }
        }
        seen.withLock {
            $0.proved.insert(digest)
            $0.refused.remove(digest)
        }
        return .key(key)
    }

    /// The status of an open that failed in another way than the chip's own refusal (the Door area's reads of 25
    /// November 2026): errSecDecode (-26275) only where CryptoKit says that the form's sizes are wrong, the one code of
    /// a damaged item that VAULT.md item 7 names; errSecNotAvailable for each other error (the token's daemon does not
    /// answer, a locked Mac, a cancel), which passes, so that nobody takes a good key away during it.
    static func passing(_ error: Error) -> OSStatus {
        switch error as? CryptoKitError {
        case .incorrectKeySize?, .incorrectParameterSize?: return errSecDecode     // the form's own sizes
        default: return errSecNotAvailable      // another error can carry a locked Mac or a lost daemon
        }
    }

    /// CryptoTokenKit's "corrupted data" (-3) and "bad parameter" (-8): the chip or its token refuses the wrapped form
    /// itself, which no later try changes. Another error (the token's daemon does not answer, a cancel) may pass.
    static func unusable(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "CryptoTokenKit" && [-3, -8].contains(error.code)
    }

    /// A new owner key for the fleet. The install that follows gives the central vault its public half and takes the
    /// earlier one away, so one Mac at a time signs for a fleet. **Only where the keychain says that no owner key is
    /// there, or that it holds one that no chip of this Mac opens**, by a fresh look past this run's marks just before
    /// (the Door area's read): a held key that the chip opens now is given back, and no new identity is made; any other
    /// answer throws and keeps what is there. A software key only on a Mac with no Secure Enclave (`enclave`); an
    /// enclave that refuses a key now throws, and the next try makes one. **The key has no access control of its own**,
    /// only CryptoKit's default access (when unlocked, this device only, no user presence): its proof at the first look
    /// of each run asks the owner nothing, and one with an access control would ask at each launch. **A held item that
    /// no chip of this Mac opens is kept aside** (`aside`) before the new key takes its place, so that a wrong reading
    /// can be put back by hand (the coordinator's validator's S-a).
    public static func make(fleet: String) throws -> any OwnerKey {
        let found = lookup(fleet: fleet, fresh: true)
        if case .key(let held) = found { return held }
        try mayMake(found)
        if case .otherMac = found { try keepAside(item.lookup(fleet: fleet), fleet: fleet) }
        let made = try new(enclave: enclave(chip: chip, available: SecureEnclave.isAvailable)) {
            try SecureEnclave.P256.Signing.PrivateKey()
        }
        try item.keep(made.1, fleet: fleet)
        seen.withLock { $0.other[fleet] = false }
        return made.0
    }

    /// The item where `make` keeps the held data that no chip of this Mac opens, one for each fleet.
    public static let aside = FleetKeychainItem(service: "com.founderizer.owner-key.other-mac",
                                                label: "owner key of another Mac")

    /// `make`'s copy of the held data before a new key takes its place: a read that fails now, or a keep that fails,
    /// throws, and the item stays as it is. A copy that is there already stays (`kept`): the first old form may be the
    /// key that the vault and the brokers still pin (the Door area's NIT of 25 November 2026).
    static func keepAside(_ read: Result<Data, FleetKeychainItem.Failure>, fleet: String,
                          kept: (String) -> Bool = { aside.isHeld(fleet: $0) },
                          keep: (Data, String) throws -> Void = { try aside.keep($0, fleet: $1) }) throws {
        switch read {
        case .success(let data): if !kept(fleet) { try keep(data, fleet) }
        case .failure(let failure): throw failure
        }
    }

    /// Whether a new key is the enclave's: by the hardware where it says (`chip`), else by CryptoKit. A Mac with a chip
    /// whose token daemon does not answer now gets no key at all, never a software key (the Door area's read).
    static func enclave(chip: Bool?, available: Bool) throws -> Bool {
        if chip == true && !available { throw FleetKeychainItem.Failure(label: item.label, status: errSecNotAvailable) }
        return chip ?? available
    }

    /// `make`'s rule: a new key in place of none or of another Mac's, never in place of a key or of a read that failed
    /// now.
    static func mayMake(_ found: Lookup) throws {
        switch found {
        case .none, .otherMac: return
        case .key: throw FleetKeychainItem.Failure(label: item.label, status: errSecDuplicateItem)
        case .notNow(let failure): throw failure
        }
    }

    /// The new key: the enclave's where this Mac has one, and its error then goes up; a software key only where it has
    /// none.
    static func new(enclave available: Bool, enclave make: () throws -> SecureEnclave.P256.Signing.PrivateKey) throws
        -> (any OwnerKey, Data) {
        if available {
            let key = try make()
            return (EnclaveOwnerKey(key: key), key.dataRepresentation)
        }
        let key = P256.Signing.PrivateKey()
        return (SoftwareOwnerKey(key), key.rawRepresentation)
    }
}

/// **The public point inside a Secure Enclave key's wrapped form**, read before CryptoKit reads it (the supervisor's
/// item of 24 November 2026): CryptoKit takes that point from the form with a `try!` of its own, so a form whose point
/// is damaged stopped the app at each read of the owner key. Measured on 24 November 2026, each of bytes 0 to 261 of a
/// 284-byte form changed three ways: CryptoKit stops the process (`incorrectParameterSize`, `SEP_P256.swift`) for each
/// change of bytes 34 to 104, the entry `pub` (its name, its tag, its length and its 65-byte point), and for no other
/// of them. The form is DER: an OCTET STRING that holds one SET of SEQUENCEs of a name and a value. Where the data has
/// that outer form, only a valid `pub` point is `valid`, and anything else in it (no DER inside, no `pub`, a point
/// that is not one) is `damaged`. Data with another outer form is `unknown` and goes to CryptoKit as before (no change
/// of bytes 0 to 33 stopped the process), so a later form of Apple's is never taken for a damaged one. A change
/// elsewhere can still crash the system's token daemon, or make CryptoKit's read wait (byte 262, the tag of the entry
/// `ed`, did): `OwnerKeychain.open` gives such a form to CryptoKit once a run.
enum EnclaveBlob {
    enum Point: Equatable { case valid, damaged, unknown }

    static func point(in data: Data) -> Point {
        let bytes = [UInt8](data)
        guard let outer = items(bytes, 0..<bytes.count), outer.count == 1, outer[0].tag == 0x04,
              let set = items(bytes, outer[0].value), set.count == 1, set[0].tag == 0x31 else { return .unknown }
        guard let value = pub(bytes, set[0].value, depth: 0), value.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: value)) != nil else { return .damaged }
        return .valid
    }

    /// The value of the first SEQUENCE { UTF8String "pub", OCTET STRING } in `range`, through SETs and SEQUENCEs; nil
    /// when there is none, or when `range` is no DER.
    private static func pub(_ bytes: [UInt8], _ range: Range<Int>, depth: Int) -> [UInt8]? {
        guard depth < 8, let items = items(bytes, range) else { return nil }
        for (tag, value) in items where tag == 0x30 || tag == 0x31 {
            if tag == 0x30, let pair = Self.items(bytes, value), pair.count == 2, pair[0].tag == 0x0c,
               Array(bytes[pair[0].value]) == Array("pub".utf8), pair[1].tag == 0x04 {
                return Array(bytes[pair[1].value])
            }
            if let found = pub(bytes, value, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The tag and the value's range of each DER item that together fill `range` exactly, or nil.
    private static func items(_ bytes: [UInt8], _ range: Range<Int>) -> [(tag: UInt8, value: Range<Int>)]? {
        var out: [(tag: UInt8, value: Range<Int>)] = []
        var at = range.lowerBound
        while at < range.upperBound {
            guard at + 2 <= range.upperBound else { return nil }
            let tag = bytes[at]
            var length = Int(bytes[at + 1]), start = at + 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...2).contains(count), start + count <= range.upperBound else { return nil }
                length = 0
                for _ in 0..<count {
                    length = length << 8 | Int(bytes[start])
                    start += 1
                }
            }
            guard start + length <= range.upperBound else { return nil }
            out.append((tag, start..<start + length))
            at = start + length
        }
        return out
    }
}
