import CryptoKit
import FleetCore
import Foundation
import LocalAuthentication
import Security
import Synchronization

/// This phone's own key for the hub (MOBILE-APP.md 7). The hub keeps only the key's SHA-256 and gives the key out
/// once, at enrollment; this holder keeps it in the keychain of this one device, locked to an unlocked phone and to
/// the owner's presence (Face ID or the passcode), and gives it back for the bearer token of a read or a write.
///
/// It holds no key in phase 1: the hub does not know owner devices yet, and the app reads from the owner's own
/// address, which needs none. `has` therefore says "not stored yet", and nothing else on the phone depends on a key.
/// The enrollment and the bearer token come with the hub slice; this file is where the key lives when they do.
///
/// **One copy more, for a press on a notification.** A ping's answer buttons (`PushNotifications.swift`) run in the
/// background, where no Face ID sheet can show, so the same key is kept a second time, locked to an unlocked phone
/// and to nothing else. Every answer button asks iOS for an unlocked phone (`.authenticationRequired`) before it runs,
/// so a press on a locked phone asks for Face ID or the passcode first. The app's own pages still read the first copy
/// behind Face ID. Both copies are saved together and removed together.
struct DeviceKey: Sendable {
    private let service = "com.pieras.fleet.mobile"
    private let account: String
    private let pressAccount: String
    #if DEBUG
    /// A check's keychain that fails, and its stand-in for the read behind Face ID (`KeyFault`, `PresenceStandIn`):
    /// only a debug build has them, and the app's holder has neither.
    private var fault: KeyFault?
    private var presence: PresenceStandIn?

    /// This holder, with a check's keychain that fails.
    func failing(_ fault: KeyFault?) -> DeviceKey {
        var holder = self
        holder.fault = fault
        return holder
    }

    /// This holder, whose read behind Face ID the check answers.
    func answering(_ presence: PresenceStandIn) -> DeviceKey {
        var holder = self
        holder.presence = presence
        return holder
    }
    #endif

    /// This phone's own key. A check names an item of its own (review B9i), so that a test run never removes the key
    /// of a phone that is enrolled.
    init(account: String = "device-key") {
        self.account = account
        pressAccount = account + "-press"
    }

    /// A key is in the keychain, as far as a question without a prompt can tell. Only "no such item" means no key:
    /// every other answer means the item is there but guarded, and the keychain does not say which guard in the same
    /// words on every iOS. Nothing decides on this alone — `key(reason:)` is the authority, because it does the read.
    var has: Bool {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
    }

    /// The key, after the owner proves presence; nil when this phone has none. It is not isolated to an actor, so the
    /// keychain's prompt never blocks the screen.
    func key(reason: String) async throws -> String? {
        #if DEBUG
        if let presence { return await presence.read() }
        #endif
        // `SecItemCopyMatching` blocks its thread for as long as the Face ID sheet is up, which can be as long as
        // the owner takes. Swift's cooperative pool holds about one thread per core, so doing this inside an async
        // function parks one of them; a few at once starve the pool and nothing else of the app runs — not the read
        // loop, not even the Unlock that would end it. So the blocking call goes on a thread of its own.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = reason
                // No `touchIDAuthenticationAllowableReuseDuration` here. It asks LocalAuthentication to accept a
                // recent device unlock in the place of a check, which this item's `.userPresence` control does not
                // take: the read then fails at once with errSecAuthFailed (-25293) and no sheet is ever shown. The
                // owner is asked once each time the app comes back from the background, and that is the price of a
                // key that only his face releases.
                var query = self.base
                query[kSecReturnData as String] = true
                query[kSecUseAuthenticationContext as String] = context
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                switch status {
                case errSecSuccess:
                    guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                        return continuation.resume(throwing: DeviceKeyError.unreadable)
                    }
                    continuation.resume(returning: key)
                case errSecItemNotFound:
                    continuation.resume(returning: nil)
                case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                    continuation.resume(throwing: DeviceKeyError.notProven(status))
                default:
                    continuation.resume(throwing: DeviceKeyError.keychain(status))
                }
            }
        }
    }

    /// Keeps the key that the hub gave at enrollment, in the place of any older one.
    func save(_ key: String) throws {
        guard !key.isEmpty, key.count <= 512, let data = key.data(using: .utf8) else { throw DeviceKeyError.unreadable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .userPresence, &error) else {
            throw error?.takeRetainedValue() ?? DeviceKeyError.unreadable
        }
        try remove()
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
        // **Both copies are kept, or neither is** (the validator's round 2 of the enroll key fix): a key whose copy for
        // a press failed stayed, so the enrolment said that it failed and undid the signing and recovery keys, and the
        // next return to the app opened the new key and linked the phone with its old signing key, with no word. When
        // the key cannot be taken away again either, it stays, and the save says so (`KeyStays`): the keys that go
        // with it stay too, and the next unlock writes its copy for a press.
        // The key stays only when its own item could not be deleted (the second reader's rounds 5 and 6): a removal
        // that took the key and then failed at its copy left no key, and `has` answers "there" for each error.
        do { try keepForPress(key) } catch let pressFailure {
            do { try deleteKey() } catch { throw KeyStays() }
            try? deletePressCopy()
            throw pressFailure
        }
    }

    /// The key that a save wrote stays, without its copy for a press, which the next unlock writes.
    struct KeyStays: Error {}

    /// The copy for a press on a notification, or nil when this phone has none. It asks for nothing: it is readable
    /// whenever the phone is unlocked, which is the only time iOS runs an answer button.
    func pressKey() throws -> String? {
        var query = press
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                throw DeviceKeyError.unreadable
            }
            return key
        case errSecItemNotFound: return nil
        default: throw DeviceKeyError.keychain(status)
        }
    }

    /// Writes the copy for a press, in the place of an older one. The key itself writes it at enrollment; a phone
    /// that enrolled before pings existed gets it the next time Face ID opens the key (`MobileStore.unlock`).
    func keepForPress(_ key: String) throws {
        guard (try? pressKey()) != key else { return }
        guard let data = key.data(using: .utf8) else { throw DeviceKeyError.unreadable }
        SecItemDelete(press as CFDictionary)
        #if DEBUG
        if fault?.refusesAdd() == true { throw DeviceKeyError.keychain(errSecNotAvailable) }
        #endif
        var item = press
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
    }

    /// Forgets the key, both copies. The owner's phone then reads nothing until it enrolls again, and the hub keeps
    /// its own record until the owner removes the device there.
    func remove() throws {
        try deleteKey()
        try deletePressCopy()
    }

    private func deleteKey() throws {
        #if DEBUG
        if fault?.refusesRemovalAfterAdd() == true { throw DeviceKeyError.keychain(errSecNotAvailable) }
        #endif
        try DeviceKeyItem.delete(base)
    }

    private func deletePressCopy() throws {
        #if DEBUG
        if fault?.refusesPressDeleteAfterAdd() == true { throw DeviceKeyError.keychain(errSecNotAvailable) }
        #endif
        try DeviceKeyItem.delete(press)
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private var press: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: pressAccount]
    }
}

enum DeviceKeyError: LocalizedError {
    case notProven(OSStatus), unreadable, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        // The number is the keychain's own, and it is the one fact that tells these apart: -128 is the owner
        // saying no, -25293 is the check failing, -25308 is the screen not being available to ask on.
        case .notProven(let status): String(l10n: "The key stays locked: this phone did not prove that you are here (\(Int(status))).")
        case .unreadable: String(l10n: "The saved key cannot be read.")
        case .keychain(let status): String(l10n: "The keychain refused the key (\(Int(status))).")
        }
    }
}

/// **This phone's own signing key** (owner feature `door_calls`, UI-API 1.81): a P-256 key in the Secure Enclave, apart
/// from the bearer key that the hub gave. The phone sends its public half at enrollment, bound by an HMAC to the one-time
/// value of the Mac's QR (`DeviceBinding`), and the Mac certifies it with the owner key. With it the phone signs the
/// owner's yes to a door call, in the app and on a notification's button, so that this yes counts as one on the Mac.
/// Only this phone's Secure Enclave can sign with it: the keychain keeps that chip's handle, for this device alone, while
/// it is unlocked. The simulator has no Secure Enclave and gets a software key.
struct DeviceSigningKey: Sendable {
    private let service = "com.pieras.fleet.mobile.signing"
    private let account: String
    #if DEBUG
    /// A check's keychain that fails (`KeyFault`): only a debug build has it, and the app's holder has none.
    private var fault: KeyFault?

    /// This holder, with a check's keychain that fails.
    func failing(_ fault: KeyFault?) -> DeviceSigningKey {
        var holder = self
        holder.fault = fault
        return holder
    }
    #endif

    init(account: String = "signing-key") { self.account = account }

    /// **A new key in memory only, and its public half** (an enrolment by the Mac's picture): nothing is written until
    /// the hub has taken the code (`EnrolmentKeys.moveIn`), so a refused code leaves this phone's key as it was, and
    /// each of two enrolments at once keeps the key that it sent. Before, the new key went into a keychain item before
    /// the hub answered: first this phone's own, so any link with a wrong code took away the key that signs the
    /// owner's yes to a door call; then one pending item, which two enrolments at once shared.
    func new() throws -> NewDeviceKey {
        #if DEBUG
        if fault?.refusesNew == true { throw DeviceKeyError.unreadable }
        #endif
        if SecureEnclave.isAvailable {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            return NewDeviceKey(bytes: Data([1]) + key.dataRepresentation,
                                publicKey: key.publicKey.x963Representation.base64EncodedString())
        }
        let key = P256.Signing.PrivateKey()
        return NewDeviceKey(bytes: Data([0]) + key.rawRepresentation,
                            publicKey: key.publicKey.x963Representation.base64EncodedString())
    }

    /// The DER signature (standard base64) of the statement's UTF-8 bytes, or nil when this phone has no signing key.
    func sign(_ statement: String) throws -> String? {
        guard let data = try data() else { return nil }
        guard let kind = data.first else { throw DeviceKeyError.unreadable }
        let body = Data(data.dropFirst()), message = Data(statement.utf8)
        if kind == 1 {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body).signature(for: message)
                .derRepresentation.base64EncodedString()
        }
        return try P256.Signing.PrivateKey(rawRepresentation: body).signature(for: message).derRepresentation
            .base64EncodedString()
    }

    /// The owner's signed yes to a door call: the statement and its signature, or nil for an item with no door call,
    /// another option or a phone with no signing key. The hub then refuses the unsigned yes, and the item stays open.
    ///
    /// **On the door's card of a run** (an item with a `door_host`) it signs only the hash that this phone computed from
    /// the script that the card shows (`NeedScript`), by the Mac's own check (`DoorCall.checked(_:)`, the call that the
    /// Mac makes), and nothing when that check fails (the lane "Give on the iPhone"; the owner's "Show the script" of
    /// 19 November 2026). Before, the phone signed the hub's hash of a script that it never showed.
    func approval(for need: OwnerNeed, choice: Int) -> (statement: String, signature: String)? {
        guard choice == 0, var call = need.door_call, let fleet = need.door_fleet else { return nil }
        if let checked = DoorCall.checked(need) {
            guard case .success(let computed) = checked else { return nil }
            call = computed
        }
        let statement = OwnerStatement.doorCall(fleet: fleet, need: need.id, call: call)
        guard let signature = try? sign(statement) else { return nil }
        return (statement, signature)
    }

    func remove() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceKeyError.keychain(status) }
    }

    /// The item's bytes (a kind byte, then the key), or nil when it holds none.
    fileprivate func data() throws -> Data? {
        #if DEBUG
        if fault?.refusesRead() == true { throw DeviceKeyError.keychain(errSecInteractionNotAllowed) }
        #endif
        return try DeviceKeyItem.data(base)
    }

    /// The item holds `data` in the place of what it held, or nothing when `data` is nil.
    fileprivate func put(_ data: Data?) throws {
        try DeviceKeyItem.delete(base)
        guard let data else { return }
        #if DEBUG
        if fault?.refusesAdd() == true { throw DeviceKeyError.keychain(errSecNotAvailable) }
        #endif
        try DeviceKeyItem.add(base, data)
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// A new key of an enrolment, in memory: its bytes for the keychain item (a kind byte, then the key) and its public
/// half for the hub (standard base64 of `04 || X || Y`).
struct NewDeviceKey: Sendable {
    let bytes: Data
    let publicKey: String
}

/// **The keys of an enrolment that the hub took move into this phone's own items: all of them, or none.** Each item
/// gets what the hub keeps now: the new key that went with the code, or no key where none went, because the hub drops
/// the signing key and the recovery key of an enrolment that carries none (the second reader's round 4, items 1 and
/// 2). When a write fails, each move that ran, the failed one too, gets its item's old bytes back, and the move
/// throws; a move that never ran is not touched (item 4). The undo that a move gives puts all of them back after a
/// later step of the enrolment fails (the save of the hub's key). A key that stayed old beside one that moved in left
/// the phone signing its yes to a door call with a key that the hub no longer named, or holding a recovery key that
/// opens no box of the hub's, and nothing said so.
enum EnrolmentKeys {
    /// What puts each item's old bytes back.
    struct Undo {
        fileprivate let steps: [() -> Void]
        func callAsFunction() { steps.forEach { $0() } }
    }

    /// Each holder's item gets `bytes`, or nothing when they are nil. A holder that is nil is not touched.
    ///
    /// **An old item that cannot be read does not stop the move** (the second reader's round 6): it is replaced or
    /// deleted as the others are, and only it has no undo, because there is nothing to put back. Else an unreadable
    /// old recovery key stopped every enrolment, and only Forget the key, which must keep the recovery copy, could
    /// have cleared it.
    static func moveIn(signing: (holder: DeviceSigningKey, bytes: Data?)?,
                       recovery: (holder: DeviceRecoveryKey, bytes: Data?)?) throws -> Undo {
        // `old` is nil for an item that could not be read, and `.some(nil)` for one that holds no key. Written out:
        // `try?` of an optional flattens the two into one nil, and the undo then deleted the new key of an item that
        // could not be read (the second reader's round 7).
        func old(_ read: () throws -> Data?) -> Data?? {
            do { return .some(try read()) } catch { return .none }
        }
        var moves: [(old: Data??, new: Data?, put: (Data?) throws -> Void)] = []
        if let signing { moves.append((old(signing.holder.data), signing.bytes, signing.holder.put)) }
        if let recovery { moves.append((old(recovery.holder.data), recovery.bytes, recovery.holder.put)) }
        func back(_ move: (old: Data??, new: Data?, put: (Data?) throws -> Void)) {
            if let old = move.old { try? move.put(old) }
        }
        var ran = 0
        do {
            for move in moves {
                ran += 1
                try move.put(move.new)
            }
        } catch {
            moves.prefix(ran).reversed().forEach(back)
            throw error
        }
        return Undo(steps: moves.reversed().map { move in { back(move) } })
    }
}

#if DEBUG
/// **A check's keychain that fails** (the enrolment's checks; a debug build only): it makes no new key
/// (`refusesNew`), or it refuses the write of an item after its delete, `adds` times, as a keychain that fails does;
/// once it has refused a write, it goes on as a keychain that has begun to fail: it refuses the removal of the phone's
/// key before it starts (`removalsAfterAdd`), or after the key went and before its copy for a press goes
/// (`pressDeletesAfterAdd`). It can refuse the read of a signing key's or a recovery key's item too, `reads` times. The
/// app's holders have none.
final class KeyFault: Sendable {
    let refusesNew: Bool
    private let left: Mutex<(adds: Int, removals: Int, pressDeletes: Int, reads: Int, refused: Bool)>

    init(refusesNew: Bool = false, adds: Int = 0, removalsAfterAdd: Int = 0, pressDeletesAfterAdd: Int = 0,
         reads: Int = 0) {
        self.refusesNew = refusesNew
        left = Mutex((adds, removalsAfterAdd, pressDeletesAfterAdd, reads, false))
    }

    /// This read of a signing key's or a recovery key's item is refused; each refusal counts one.
    func refusesRead() -> Bool {
        left.withLock { left in
            guard left.reads > 0 else { return false }
            left.reads -= 1
            return true
        }
    }

    /// This write is refused; each refusal counts one.
    func refusesAdd() -> Bool {
        left.withLock { left in
            guard left.adds > 0 else { return false }
            left.adds -= 1
            left.refused = true
            return true
        }
    }

    /// This removal of the phone's key is refused before it starts, after a refused write; each refusal counts one.
    func refusesRemovalAfterAdd() -> Bool {
        left.withLock { left in
            guard left.refused, left.removals > 0 else { return false }
            left.removals -= 1
            return true
        }
    }

    /// This delete of the copy for a press is refused, after a refused write; each refusal counts one.
    func refusesPressDeleteAfterAdd() -> Bool {
        left.withLock { left in
            guard left.refused, left.pressDeletes > 0 else { return false }
            left.pressDeletes -= 1
            return true
        }
    }
}

/// **A check's stand-in for the read behind Face ID** (a debug build only): the read waits until the check answers it,
/// with the key that the check gives, as a sheet that the owner answers late does. The app's holder has none.
final class PresenceStandIn: Sendable {
    private let waiting = Mutex<CheckedContinuation<String?, Never>?>(nil)

    /// A read waits for its answer.
    var asked: Bool { waiting.withLock { $0 != nil } }

    func read() async -> String? {
        await withCheckedContinuation { continuation in waiting.withLock { $0 = continuation } }
    }

    func answer(_ key: String?) {
        waiting.withLock { waiter -> CheckedContinuation<String?, Never>? in
            defer { waiter = nil }
            return waiter
        }?.resume(returning: key)
    }
}
#endif

/// The keychain steps that the signing key and the recovery key share: one item of this device alone, while it is
/// unlocked.
private enum DeviceKeyItem {
    static func data(_ base: [String: Any]) throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw DeviceKeyError.keychain(status) }
        return data
    }

    /// The item holds nothing, whether it held something or not.
    static func delete(_ base: [String: Any]) throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceKeyError.keychain(status) }
    }

    static func add(_ base: [String: Any], _ data: Data) throws {
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
    }
}

/// **This phone's own recovery key** (owner feature `recovery_copy`, UI-API 1.95, DevOps plan V12): a second P-256 key in
/// the Secure Enclave, a key agreement key, apart from the signing key. The phone sends its public half at enrollment,
/// bound by an HMAC to the same one-time value of the Mac's QR, and the Mac seals the recovery code to it
/// (`RecoverySeal`). Only this phone's chip opens that box; the simulator has no Secure Enclave and gets a software key.
struct DeviceRecoveryKey: Sendable {
    private let service = "com.pieras.fleet.mobile.recovery-key"
    private let account: String
    #if DEBUG
    /// A check's keychain that fails (`KeyFault`): only a debug build has it, and the app's holder has none.
    private var fault: KeyFault?

    /// This holder, with a check's keychain that fails.
    func failing(_ fault: KeyFault?) -> DeviceRecoveryKey {
        var holder = self
        holder.fault = fault
        return holder
    }
    #endif

    init(account: String = "recovery-key") { self.account = account }

    /// A new key in memory only, and its public half, as for the signing key (`DeviceSigningKey.new`).
    func new() throws -> NewDeviceKey {
        #if DEBUG
        if fault?.refusesNew == true { throw DeviceKeyError.unreadable }
        #endif
        if SecureEnclave.isAvailable {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            return NewDeviceKey(bytes: Data([1]) + key.dataRepresentation,
                                publicKey: key.publicKey.x963Representation.base64EncodedString())
        }
        let key = P256.KeyAgreement.PrivateKey()
        return NewDeviceKey(bytes: Data([0]) + key.rawRepresentation,
                            publicKey: key.publicKey.x963Representation.base64EncodedString())
    }

    /// The code that a box of the Mac's holds, opened with this key, or nil when this phone has no recovery key.
    func open(_ box: String, device: String) throws -> Data? {
        guard let data = try DeviceKeyItem.data(base) else { return nil }
        guard let kind = data.first else { throw DeviceKeyError.unreadable }
        let body = Data(data.dropFirst())
        return try RecoverySeal.open(box, device: device) { ephemeral in
            kind == 1 ? try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: body)
                .sharedSecretFromKeyAgreement(with: ephemeral)
                : try P256.KeyAgreement.PrivateKey(rawRepresentation: body).sharedSecretFromKeyAgreement(with: ephemeral)
        }
    }

    var exists: Bool { SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess }

    func remove() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceKeyError.keychain(status) }
    }

    /// The item's bytes (a kind byte, then the key), or nil when it holds none.
    fileprivate func data() throws -> Data? {
        #if DEBUG
        if fault?.refusesRead() == true { throw DeviceKeyError.keychain(errSecInteractionNotAllowed) }
        #endif
        return try DeviceKeyItem.data(base)
    }

    /// The item holds `data` in the place of what it held, or nothing when `data` is nil.
    fileprivate func put(_ data: Data?) throws {
        try DeviceKeyItem.delete(base)
        guard let data else { return }
        #if DEBUG
        if fault?.refusesAdd() == true { throw DeviceKeyError.keychain(errSecNotAvailable) }
        #endif
        try DeviceKeyItem.add(base, data)
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// **The phone's copy of the recovery code** (DevOps plan V12): on this phone alone, while it is unlocked, never in a
/// backup and never synced to another device. Nothing shows it.
struct RecoveryCodeCopy: Sendable {
    private let service = "com.pieras.fleet.mobile.recovery-code"
    private let account: String

    init(account: String = "recovery-code") { self.account = account }

    var held: Bool { SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess }

    func keep(_ code: Data) throws {
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = code
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
    }

    func remove() {
        SecItemDelete(base as CFDictionary)
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
