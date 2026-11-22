import CommonCrypto
import CryptoKit
import Foundation
import Security

// The crypto of Bitwarden Secrets Manager that a machine account's client needs, in plain Swift with CryptoKit and
// CommonCrypto: no library comes back into a build (the owner's option A of 11 November 2026, 2ebc37e0a). Read from
// the SDK's own source (bitwarden/sdk-internal, 22 November 2026): `bitwarden-core/src/auth/access_token.rs`,
// `bitwarden-crypto/src/keys/shareable_key.rs`, `bitwarden-crypto/src/enc_string/symmetric.rs` and
// `hazmat/symmetric_encryption/aes256_cbc_hmac_sha256_ae.rs`, `bitwarden-core/src/auth/login/access_token.rs`.

/// **The 64-byte key of Bitwarden's type 2 encryption**: AES-256-CBC with the first 32 bytes, HMAC-SHA256 with the
/// last 32. It prints nothing of its bytes.
struct CompositeKey: Sendable, CustomStringConvertible, CustomReflectable {
    let enc: SymmetricKey
    let mac: SymmetricKey

    init?(_ bytes: Data) {
        guard bytes.count == 64 else { return nil }
        enc = SymmetricKey(data: bytes.prefix(32))
        mac = SymmetricKey(data: bytes.suffix(32))
    }

    /// The 64 bytes, for a test's comparison with the SDK's own vectors.
    var bytes: Data { enc.withUnsafeBytes { Data($0) } + mac.withUnsafeBytes { Data($0) } }

    var description: String { "CompositeKey(…)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// **`derive_shareable_key`**: HMAC-SHA256 with the key `bitwarden-<name>` over the 16-byte secret, then
/// HKDF-Expand with SHA-256 and `info` to 64 bytes, `enc_key || mac_key`.
enum ShareableKey {
    static func derive(_ secret: Data, name: String, info: String?) -> CompositeKey? {
        guard secret.count == 16 else { return nil }
        let prk = HMAC<SHA256>.authenticationCode(for: secret, using: SymmetricKey(data: Data("bitwarden-\(name)".utf8)))
        let key = HKDF<SHA256>.expand(pseudoRandomKey: SymmetricKey(data: Data(prk)), info: Data((info ?? "").utf8),
                                      outputByteCount: 64)
        return CompositeKey(key.withUnsafeBytes { Data($0) })
    }
}

/// **A machine account's access token**: `0.<access token id>.<client secret>:<16 bytes of key, base64>`. Its key is
/// `derive_shareable_key(key, "accesstoken", "sm-access-token")`, which opens the sign-in's `encrypted_payload`. It
/// prints nothing but its id.
struct BitwardenAccessToken: Sendable, CustomStringConvertible, CustomReflectable {
    /// The access token's id, the `client_id` of the sign-in, in lower case.
    let id: String
    let clientSecret: String
    let key: CompositeKey

    init?(_ text: String) {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let parts = token[..<colon].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "0", let id = UUID(uuidString: String(parts[1])),
              parts[1].count == 36 else { return nil }
        let secret = String(parts[2])
        guard !secret.isEmpty, secret.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              let raw = Self.base64(String(token[token.index(after: colon)...])), raw.count == 16,
              let key = ShareableKey.derive(raw, name: "accesstoken", info: "sm-access-token") else { return nil }
        self.id = id.uuidString.lowercased()
        self.clientSecret = secret
        self.key = key
    }

    /// Standard base64, with or without its padding: the SDK makes it padded and takes it without.
    static func base64(_ text: String) -> Data? {
        guard !text.isEmpty, text.range(of: "\\A[A-Za-z0-9+/]+={0,2}\\z", options: .regularExpression) != nil else { return nil }
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return Data(base64Encoded: bare + String(repeating: "=", count: (4 - bare.count % 4) % 4))
    }

    var description: String { "BitwardenAccessToken(\(id))" }
    var customMirror: Mirror { Mirror(self, children: ["id": id]) }
}

/// **Bitwarden's encrypted string of type 2** (`Aes256Cbc_HmacSha256_B64`): `2.<iv>|<data>|<mac>` in standard base64,
/// AES-256-CBC with PKCS#7 padding, and an HMAC-SHA256 over the IV and the data, which is checked before anything is
/// decrypted. The organization key of a machine account is such a key, so the names, values and notes of its items are
/// such strings.
enum EncString {
    enum Failure: Error, Equatable { case format, integrity, crypto }

    static func seal(_ plain: Data, key: CompositeKey, iv given: Data? = nil) throws -> String {
        let iv = try given ?? random(16)
        guard iv.count == 16 else { throw Failure.format }
        let data = try aes(CCOperation(kCCEncrypt), plain, key: key, iv: iv)
        let mac = HMAC<SHA256>.authenticationCode(for: iv + data, using: key.mac)
        return "2." + [iv, data, Data(mac)].map { $0.base64EncodedString() }.joined(separator: "|")
    }

    static func seal(_ text: String, key: CompositeKey) throws -> String { try seal(Data(text.utf8), key: key) }

    static func open(_ text: String, key: CompositeKey) throws -> Data {
        guard text.hasPrefix("2.") else { throw Failure.format }
        let parts = text.dropFirst(2).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let iv = Data(base64Encoded: String(parts[0])), let data = Data(base64Encoded: String(parts[1])),
              let mac = Data(base64Encoded: String(parts[2])), iv.count == 16, mac.count == 32, !data.isEmpty,
              data.count % 16 == 0 else { throw Failure.format }
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: iv + data, using: key.mac) else {
            throw Failure.integrity
        }
        return try aes(CCOperation(kCCDecrypt), data, key: key, iv: iv)
    }

    /// The text of an encrypted string, or nil when it does not open with `key` or is no UTF-8.
    static func openText(_ text: String, key: CompositeKey) -> String? {
        (try? open(text, key: key)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func aes(_ operation: CCOperation, _ input: Data, key: CompositeKey, iv: Data) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = out.count
        var moved = 0
        let status = key.enc.withUnsafeBytes { secret in
            out.withUnsafeMutableBytes { output in
                input.withUnsafeBytes { source in
                    iv.withUnsafeBytes { vector in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                secret.baseAddress, secret.count, vector.baseAddress, source.baseAddress, source.count,
                                output.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.crypto }
        return out.prefix(moved)
    }

    private static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.crypto }
        return bytes
    }
}

/// **What the sign-in gives a machine account**: the organization of its JWT (the claim `organization`, which the
/// SDK reads and Bitwarden's identity writes), and the organization key in its `encrypted_payload`, the JSON
/// `{"encryptionKey": <base64 of 64 bytes>}` encrypted with the access token's key.
enum SignInParts {
    /// The claim `organization` of a JWT, in lower case, or nil. The signature is not checked: the JWT came from
    /// Bitwarden's identity over TLS, and only Bitwarden's API checks it.
    static func organization(ofJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let organization = claims["organization"] as? String else { return nil }
        return organization
    }

    /// The organization key of the payload, or nil when it does not open with the token's key or is not 64 bytes.
    static func organizationKey(payload: String, token: BitwardenAccessToken) -> CompositeKey? {
        guard let plain = try? EncString.open(payload, key: token.key),
              let object = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              let text = object["encryptionKey"] as? String, let bytes = Data(base64Encoded: text) else { return nil }
        return CompositeKey(bytes)
    }
}
