import CommonCrypto
import CryptoKit
import Foundation
import Security

/// **What the take-over card signs in with** to an agent's screen (the owner's "Yes, build it" of 21 November 2026 to
/// `superbot-ideas/09-take-over-modal-design.md`): nothing, a one-time password (a Linux agent's screen, which its
/// server makes at each press), or a Mac's account and password (that Mac's own screen sharing).
public enum RFBCredentials: Sendable, Equatable {
    case none
    case password(String)
    case account(user: String, password: String)
}

/// The security types of the protocol (RFC 6143 section 7.2, and Apple's 30).
enum RFBSecurity {
    static let none: UInt8 = 1
    static let vnc: UInt8 = 2
    static let apple: UInt8 = 30

    /// The type that these credentials sign in with, among the server's; nil when none fits. A Mac's account takes
    /// Apple's sign-in only: its password never goes into VNC's sign-in, whose key is the first 8 characters.
    static func choose(_ offered: [UInt8], for credentials: RFBCredentials) -> UInt8? {
        switch credentials {
        case .none: return offered.contains(none) ? none : nil
        case .password: return offered.contains(vnc) ? vnc : nil
        case .account: return offered.contains(apple) ? apple : nil
        }
    }
}

/// **VNC's own sign-in** (RFC 6143 section 7.2.2): the server's 16 bytes, encrypted with DES under the password's first
/// 8 bytes, each byte with its bits in reverse order, as every VNC server reads them.
enum RFBVNCSignIn {
    static func response(challenge: [UInt8], password: String) -> [UInt8]? {
        guard challenge.count == 16 else { return nil }
        var key = [UInt8](repeating: 0, count: 8)
        defer { RFBAppleSignIn.zero(&key) }
        for (index, byte) in Array(password.utf8.prefix(8)).enumerated() { key[index] = reversedBits(byte) }
        return crypt(algorithm: CCAlgorithm(kCCAlgorithmDES), key: key, data: challenge)
    }

    static func reversedBits(_ byte: UInt8) -> UInt8 {
        var input = byte, output: UInt8 = 0
        for _ in 0..<8 { output = (output << 1) | (input & 1); input >>= 1 }
        return output
    }
}

/// **A Mac's screen sign-in** (Apple's security type 30): Diffie-Hellman on the server's generator and prime, then the
/// account's name and password, each in 64 bytes that end with a zero and random bytes, encrypted with AES-128 in ECB
/// mode under the MD5 of the shared secret. The client sends the 128 encrypted bytes and then its public key.
enum RFBAppleSignIn {
    struct Offer {
        let generator: [UInt8]
        let prime: [UInt8]
        let serverKey: [UInt8]
    }

    /// Whether the server's offer can carry a secret: a prime of 512 to 4096 bits, a generator of 2 or more, and a
    /// server key in 2…p−2. With a prime of 1, or a server key of 0, 1 or p−1, the shared secret is known to anybody
    /// who reads the bytes, and with it the password (review of 21 November 2026).
    static func acceptable(_ offer: Offer) -> Bool {
        let size = offer.prime.count
        guard (64...512).contains(size), offer.serverKey.count == size, offer.generator.count == 2 else { return false }
        let prime = RFBNumber(bigEndian: offer.prime), key = RFBNumber(bigEndian: offer.serverKey)
        let two = RFBNumber(limbs: [2])
        return prime.bits >= 512 && !(RFBNumber(bigEndian: offer.generator) < two) && !(key < two)
            && key < prime.lessOne
    }

    /// The bytes that the client sends; nil for an offer that is not `acceptable`, or a name or a password of 64 bytes
    /// or more. `privateKey` and `filler` are for the tests: the session gives random bytes.
    static func response(to offer: Offer, user: String, password: String, privateKey: [UInt8]? = nil,
                         filler: [UInt8]? = nil) -> [UInt8]? {
        let size = offer.prime.count
        var name = Array(user.utf8), secret = Array(password.utf8)
        defer { zero(&name); zero(&secret) }
        guard acceptable(offer), name.count < 64, secret.count < 64 else { return nil }
        let prime = RFBNumber(bigEndian: offer.prime)
        var ownBytes = privateKey ?? random(size)
        var own = RFBNumber(bigEndian: ownBytes)
        defer { own.wipe(); zero(&ownBytes) }
        guard !own.isZero,
              let ownPublic = RFBNumber(bigEndian: offer.generator).power(own, modulus: prime)?.bigEndian(count: size),
              var shared = RFBNumber(bigEndian: offer.serverKey).power(own, modulus: prime)?.bigEndian(count: size)
        else { return nil }
        var plain = filler ?? random(128)
        defer { zero(&plain); zero(&shared) }
        guard plain.count == 128 else { return nil }
        plain.replaceSubrange(0..<name.count, with: name)
        plain[name.count] = 0
        plain.replaceSubrange(64..<(64 + secret.count), with: secret)
        plain[64 + secret.count] = 0
        var key = Array(Insecure.MD5.hash(data: shared))
        defer { zero(&key) }
        guard let encrypted = crypt(algorithm: CCAlgorithm(kCCAlgorithmAES128), key: key, data: plain) else { return nil }
        return encrypted + ownPublic
    }

    /// Writes zeros over a secret's bytes once it is used.
    static func zero(_ bytes: inout [UInt8]) {
        for index in bytes.indices { bytes[index] = 0 }
    }

    private static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return bytes
    }
}

/// One block cipher in ECB mode with no padding, for data of whole blocks.
private func crypt(algorithm: CCAlgorithm, key: [UInt8], data: [UInt8]) -> [UInt8]? {
    var out = [UInt8](repeating: 0, count: data.count + 16)
    var moved = 0
    let status = CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode), key, key.count, nil,
                         data, data.count, &out, out.count, &moved)
    guard status == kCCSuccess, moved == data.count else { return nil }
    return Array(out.prefix(moved))
}
