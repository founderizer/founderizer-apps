import CommonCrypto
import CryptoKit
import Foundation

/// The decryption of a Bitwarden export that its user locked with a password of the export's own ("password
/// protected"). It runs in this process only: the password and the values stay in memory, and nothing is written.
enum ExportCrypto {
    enum Failure: Error, Equatable { case format, password, parameters }

    /// The key of the password, as Bitwarden derives it: PBKDF2-SHA256 (kdfType 0) or Argon2id (kdfType 1, with the
    /// SHA-256 of the salt as Argon2's salt and the memory in MiB). The bounds are Bitwarden's own: PBKDF2 5,000 to 2,000,000
    /// iterations; Argon2id 2 to 10 iterations, 16 to 1,024 MiB and 1 to 16 lanes.
    static func passwordKey(password: String, salt: String, kdf: Int, iterations: Int, memory: Int?, parallelism: Int?) throws -> [UInt8] {
        let secret = Array(password.utf8), saltBytes = Array(salt.utf8)
        switch kdf {
        case 0:
            guard (5_000...2_000_000).contains(iterations) else { throw Failure.parameters }
            return try pbkdf2(secret, salt: saltBytes, iterations: iterations)
        case 1:
            guard let memory, let parallelism, (16...1024).contains(memory), (1...16).contains(parallelism),
                  (2...10).contains(iterations) else { throw Failure.parameters }
            let digest = Array(SHA256.hash(data: saltBytes))
            do {
                return try Argon2id.derive(password: secret, salt: digest, iterations: iterations, memory: memory * 1024,
                                           parallelism: parallelism)
            } catch { throw Failure.parameters }
        default:
            throw Failure.parameters
        }
    }

    static func pbkdf2(_ password: [UInt8], salt: [UInt8], iterations: Int, length: Int = 32) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { secret in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 secret.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                 &out, length)
        }
        guard status == kCCSuccess else { throw Failure.parameters }
        return out
    }

    /// The two keys of a 32-byte key: HKDF-Expand with SHA-256, the info "enc" and "mac", 32 bytes each.
    static func stretch(_ key: [UInt8]) -> (enc: [UInt8], mac: [UInt8]) {
        let prk = SymmetricKey(data: key)
        func expand(_ info: String) -> [UInt8] {
            HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data(info.utf8), outputByteCount: 32).withUnsafeBytes { Array($0) }
        }
        return (expand("enc"), expand("mac"))
    }

    /// One encrypted string of type 2, `2.<iv>|<data>|<mac>` in base64: AES-256-CBC with PKCS#7 padding, and an
    /// HMAC-SHA256 over the IV and the data, which is checked before anything is decrypted.
    static func open(_ text: String, enc: [UInt8], mac: [UInt8]) throws -> Data {
        guard text.hasPrefix("2.") else { throw Failure.format }
        let parts = text.dropFirst(2).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let iv = Data(base64Encoded: String(parts[0])), let body = Data(base64Encoded: String(parts[1])),
              let tag = Data(base64Encoded: String(parts[2])), iv.count == 16, tag.count == 32, !body.isEmpty,
              body.count % 16 == 0 else { throw Failure.format }
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: iv + body, using: SymmetricKey(data: mac)) else {
            throw Failure.password
        }
        var out = Data(count: body.count + 16)
        var moved = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { output in
            body.withUnsafeBytes { input in
                iv.withUnsafeBytes { vector in
                    enc.withUnsafeBytes { key in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, key.count, vector.baseAddress, input.baseAddress, input.count,
                                output.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.format }
        return out.prefix(moved)
    }
}
