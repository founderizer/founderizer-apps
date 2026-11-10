import CryptoKit
import FleetCore
import Foundation
import LocalAuthentication
import Security

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
        // `SecItemCopyMatching` blocks its thread for as long as the Face ID sheet is up, which can be as long as
        // the owner takes. Swift's cooperative pool holds about one thread per core, so doing this inside an async
        // function parks one of them; a few at once starve the pool and nothing else of the app runs — not the read
        // loop, not even the Unlock that would end it. So the blocking call goes on a thread of its own.
        try await withCheckedThrowingContinuation { continuation in
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
        try keepForPress(key)
    }

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
        var item = press
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
    }

    /// Forgets the key, both copies. The owner's phone then reads nothing until it enrolls again, and the hub keeps
    /// its own record until the owner removes the device there.
    func remove() throws {
        for query in [base, press] {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceKeyError.keychain(status) }
        }
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
        case .notProven(let status): "The key stays locked: this phone did not prove that you are here (\(status))."
        case .unreadable: "The saved key cannot be read."
        case .keychain(let status): "The keychain refused the key (\(status))."
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

    init(account: String = "signing-key") { self.account = account }

    /// A new key in place of any earlier one, and its public half (standard base64 of `04 || X || Y`).
    func make() throws -> String {
        let made: (data: Data, publicKey: String)
        if SecureEnclave.isAvailable {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            made = (Data([1]) + key.dataRepresentation, key.publicKey.x963Representation.base64EncodedString())
        } else {
            let key = P256.Signing.PrivateKey()
            made = (Data([0]) + key.rawRepresentation, key.publicKey.x963Representation.base64EncodedString())
        }
        try remove()
        var item = base
        item[kSecValueData as String] = made.data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
        return made.publicKey
    }

    /// The DER signature (standard base64) of the statement's UTF-8 bytes, or nil when this phone has no signing key.
    func sign(_ statement: String) throws -> String? {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let kind = data.first else {
            throw DeviceKeyError.keychain(status)
        }
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
    func approval(for need: OwnerNeed, choice: Int) -> (statement: String, signature: String)? {
        guard choice == 0, let call = need.door_call, let fleet = need.door_fleet else { return nil }
        let statement = OwnerStatement.doorCall(fleet: fleet, need: need.id, call: call)
        guard let signature = try? sign(statement) else { return nil }
        return (statement, signature)
    }

    func remove() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceKeyError.keychain(status) }
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// **This phone's own recovery key** (owner feature `recovery_copy`, UI-API 1.95, DevOps plan V12): a second P-256 key in
/// the Secure Enclave, a key agreement key, apart from the signing key. The phone sends its public half at enrollment,
/// bound by an HMAC to the same one-time value of the Mac's QR, and the Mac seals the recovery code to it
/// (`RecoverySeal`). Only this phone's chip opens that box; the simulator has no Secure Enclave and gets a software key.
struct DeviceRecoveryKey: Sendable {
    private let service = "com.pieras.fleet.mobile.recovery-key"
    private let account: String

    init(account: String = "recovery-key") { self.account = account }

    /// A new key in place of any earlier one, and its public half (standard base64 of `04 || X || Y`).
    func make() throws -> String {
        let made: (data: Data, publicKey: String)
        if SecureEnclave.isAvailable {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            made = (Data([1]) + key.dataRepresentation, key.publicKey.x963Representation.base64EncodedString())
        } else {
            let key = P256.KeyAgreement.PrivateKey()
            made = (Data([0]) + key.rawRepresentation, key.publicKey.x963Representation.base64EncodedString())
        }
        try remove()
        var item = base
        item[kSecValueData as String] = made.data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
        return made.publicKey
    }

    /// The code that a box of the Mac's holds, opened with this key, or nil when this phone has no recovery key.
    func open(_ box: String, device: String) throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let kind = data.first else {
            throw DeviceKeyError.keychain(status)
        }
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
