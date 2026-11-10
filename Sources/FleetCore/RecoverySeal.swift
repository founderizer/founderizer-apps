import CryptoKit
import Foundation

/// **The recovery code's copy for one phone** (DevOps plan V12, owner feature `recovery_copy`, UI-API 1.95; the
/// coordinator, 6 November 2026: "a second Secure Enclave key on the phone, the Mac seals the code to it, the hub carries
/// only the sealed box and then deletes it, and the phone keeps the code on this device only").
///
/// A newer phone sends a second key of its own with its enrollment, a key agreement key of its Secure Enclave, bound to
/// the same one-time value of the Mac's QR as its signing key (`DeviceBinding`). Once that binding matched a QR of this
/// Mac, the Mac seals the code to that key: an ephemeral P-256 key agreement, HKDF-SHA256 over its shared secret, and
/// AES-GCM. The hub carries the box and cannot open it, and only that phone's chip opens it. Nothing shows on either
/// screen.
public enum RecoverySeal {
    public enum Failure: Error, Equatable, Sendable { case key, box }

    static let info = "founderizer recovery copy v1"

    /// The box for this phone, in standard base64: the ephemeral public point (`04 || X || Y`, 65 bytes), then AES-GCM's
    /// nonce, the sealed code and its tag. The device's name is bound into the key and the tag.
    public static func seal(_ code: Data, to key: String, device: String) throws -> String {
        guard let point = Data(base64Encoded: key), point.count == 65, point.first == 0x04,
              let theirs = try? P256.KeyAgreement.PublicKey(x963Representation: point) else { throw Failure.key }
        let mine = P256.KeyAgreement.PrivateKey()
        let ephemeral = mine.publicKey.x963Representation
        let symmetric = derive(try mine.sharedSecretFromKeyAgreement(with: theirs), ephemeral: ephemeral, device: device)
        guard let combined = try AES.GCM.seal(code, using: symmetric, authenticating: bound(device)).combined else {
            throw Failure.box
        }
        return (ephemeral + combined).base64EncodedString()
    }

    /// The code from its box, with the phone's own key agreement: its Secure Enclave key on the phone, a software key in
    /// the simulator and in tests.
    public static func open(_ box: String, device: String,
                            agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> Data {
        guard let raw = Data(base64Encoded: box), raw.count > 65 + 12 + 16,
              let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: raw.prefix(65)),
              let sealed = try? AES.GCM.SealedBox(combined: raw.dropFirst(65)) else { throw Failure.box }
        let symmetric = derive(try agree(ephemeral), ephemeral: Data(raw.prefix(65)), device: device)
        guard let code = try? AES.GCM.open(sealed, using: symmetric, authenticating: bound(device)) else {
            throw Failure.box
        }
        return code
    }

    static func bound(_ device: String) -> Data { Data((info + "|" + device).utf8) }

    static func derive(_ shared: SharedSecret, ephemeral: Data, device: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral, sharedInfo: bound(device), outputByteCount: 32)
    }
}
