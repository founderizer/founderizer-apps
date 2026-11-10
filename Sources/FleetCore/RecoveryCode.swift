import CryptoKit
import Foundation
import Security

/// **The owner's recovery code** for the fleet's central vault: 26 symbols of Crockford's base32, 130 random bits.
/// The central vault seals its backup to the age key this code derives, so a backup opens with the code and with
/// nothing that the hub or a server holds. The app makes it by itself and keeps it in this Mac's login keychain only
/// (`RecoveryKeychain`), where a later restore reads it.
///
/// The key is HKDF-SHA-256 of the code in its normal form (salt "founderizer recovery v1", info "age X25519", 32
/// bytes), taken as an X25519 key, which is all an age identity is: `recipient` is its `age1…` public key, which the
/// owner's key signs for the vault, and `identity` its `AGE-SECRET-KEY-1…` form, for a restore tool that opens the
/// backup with `age`. It is not Codable, and it prints as nothing, so no log, report or crash record can carry it by
/// accident.
public struct RecoveryCode: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Crockford's alphabet: the digits and the letters without I, L, O and U, so no two read as one another.
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 26

    /// The code in its normal form: 26 symbols of the alphabet, upper case, no "-".
    public let normalized: String

    /// A code as the owner types it back, in any of the ways he may read it off his paper: nil when it is not one.
    public init?(_ text: String) {
        let code = Self.normalized(text)
        guard code.count == Self.length, code.allSatisfy(Self.alphabet.contains) else { return nil }
        normalized = code
    }

    private init(symbols: [Character]) { normalized = String(symbols) }

    /// A new code from the system's random source. Each symbol takes the low five bits of one random byte, and 256
    /// is a multiple of 32, so every symbol is equally likely.
    public static func make(random: (Int) throws -> Data = AgeSeal.secureRandom) throws -> RecoveryCode {
        let bytes = try random(length)
        guard bytes.count == length else { throw AgeSeal.Failure.random }
        return RecoveryCode(symbols: bytes.map { alphabet[Int($0 & 31)] })
    }

    /// Upper case, without "-" and white space, with I and L read as 1 and O as 0, as Crockford's decoding reads them.
    public static func normalized(_ text: String) -> String {
        String(text.uppercased().compactMap { symbol -> Character? in
            switch symbol {
            case "-": return nil
            case _ where symbol.isWhitespace: return nil
            case "I", "L": return "1"
            case "O": return "0"
            default: return symbol
            }
        })
    }

    /// The code as the card shows it: groups of four, joined by "-".
    public var grouped: String {
        stride(from: 0, to: normalized.count, by: 4).map { String(normalized.dropFirst($0).prefix(4)) }.joined(separator: "-")
    }

    /// The 32 bytes of the X25519 private key.
    var privateKey: Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(normalized.utf8)),
                                         salt: Data("founderizer recovery v1".utf8), info: Data("age X25519".utf8),
                                         outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The `age1…` key the central vault seals its backup to.
    public var recipient: String {
        // Any 32 bytes are an X25519 key: the clamping is part of the function, in CryptoKit as in age.
        let key = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        return AgeSeal.bech32("age", key.publicKey.rawRepresentation)
    }

    /// The `AGE-SECRET-KEY-1…` identity that opens what was sealed to `recipient`, for a restore tool.
    public var identity: String { AgeSeal.bech32("AGE-SECRET-KEY-", privateKey).uppercased() }

    public var description: String { "RecoveryCode(not shown)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// **Where the recovery code is kept**: in this Mac's login keychain only, one item for each fleet (service
/// `com.founderizer.recovery-code`, account the fleet's id), the way the owner key is kept. The app shows, copies,
/// logs and sends the code nowhere: the central vault gets its public key, signed, and a restore reads it from here.
public enum RecoveryKeychain {
    public static let item = FleetKeychainItem(service: "com.founderizer.recovery-code", label: "recovery code")

    /// The code this Mac keeps for the fleet, or nil.
    public static func code(fleet: String) -> RecoveryCode? {
        item.read(fleet: fleet).flatMap { String(data: $0, encoding: .utf8) }.flatMap(RecoveryCode.init)
    }

    /// The code this Mac keeps for the fleet, made and kept now when it keeps none. It is read back before it is
    /// returned, because a recovery key whose code is not kept would seal every backup to a key nobody has.
    public static func kept(fleet: String) throws -> RecoveryCode {
        if let code = code(fleet: fleet) { return code }
        let code = try RecoveryCode.make()
        try item.keep(Data(code.normalized.utf8), fleet: fleet)
        guard Self.code(fleet: fleet) == code else { throw FleetKeychainItem.Failure(label: item.label, status: errSecItemNotFound) }
        return code
    }
}
