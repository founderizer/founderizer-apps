import CryptoKit
import Foundation
import Security

/// A value sealed for one machine's vault (owner feature `secret_deliveries`): an `age` file (age-encryption.org/v1)
/// for one X25519 recipient, in ASCII armor, which only the holder of that recipient's identity opens — the vault of
/// the machine whose key the owner pinned. The hub carries it and cannot open it; the app keeps no copy and no key.
///
/// It is age's own format, made with CryptoKit, so that the Mac app needs no program of its own for it: a random
/// file key, wrapped for the recipient with an ephemeral X25519 share (HKDF-SHA-256 and ChaCha20-Poly1305), the
/// header's HMAC, and the payload in ChaCha20-Poly1305 chunks of 64 KiB under a key of its own nonce. `vault.py` and
/// the Mac vault open it with the bundled `age`, and the tests hold a file that `age -d` opened.
public enum AgeSeal {
    public enum Failure: Error, Equatable { case recipient, random }

    static let head = "-----BEGIN AGE ENCRYPTED FILE-----"
    static let tail = "-----END AGE ENCRYPTED FILE-----"
    private static let chunk = 65_536
    /// The longest sealed copy the hub takes (`DEPOSIT_COPY_MAX`): over this, `POST /ui/secrets/deliver` refuses the
    /// whole delivery, so a value too long to seal is refused in the form instead, before it is typed away.
    public static let maxCopy = 16_384
    /// The header is one fixed size: the version line (22), "-> X25519 " and the ephemeral share (53), the wrapped
    /// file key with its line end (44), "---" (4), and the space, the header's HMAC and its line end (45).
    /// `sealedLengthIsTheLengthTheSealerWrites` holds this number to the sealer itself.
    private static let headerBytes = 168
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)

    /// `value` sealed to `recipient` (`age1…`), as an armored file with LF line ends. `random` gives the file key, the
    /// ephemeral key and the payload's nonce, in that order; only a test gives its own.
    public static func seal(_ value: Data, to recipient: String,
                            random: (Int) throws -> Data = secureRandom) throws -> String {
        guard let share = publicKey(of: recipient) else { throw Failure.recipient }
        let value = Data(value)         // indices from 0, also for a slice
        let fileKey = try random(16)
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: random(32))
        let mine = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: share))
        let secret = shared.withUnsafeBytes { Data($0) }
        // A low-order key gives an all-zero secret, which wraps the file key for nobody.
        guard secret.contains(where: { $0 != 0 }) else { throw Failure.recipient }
        let wrapKey = key(secret, salt: mine + share, info: "age-encryption.org/v1/X25519")
        let wrapped = try ChaChaPoly.seal(fileKey, using: wrapKey, nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        var header = "age-encryption.org/v1\n-> X25519 \(raw(mine))\n\(lines(raw(wrapped.ciphertext + wrapped.tag)))\n---"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(header.utf8), using: key(fileKey, salt: Data(), info: "header"))
        header += " \(raw(Data(mac)))\n"
        let nonce = try random(16)
        let payloadKey = key(fileKey, salt: nonce, info: "payload")
        var file = Data(header.utf8) + nonce
        var start = 0, counter: UInt64 = 0
        repeat {
            let end = min(start + chunk, value.count)
            // An 11-byte big-endian counter, then 1 for the last chunk. An empty value is one empty last chunk.
            var chunkNonce = Data(count: 12)
            withUnsafeBytes(of: counter.bigEndian) { chunkNonce.replaceSubrange(3..<11, with: $0) }
            chunkNonce[11] = end == value.count ? 1 : 0
            let sealed = try ChaChaPoly.seal(value.subdata(in: start..<end), using: payloadKey, nonce: ChaChaPoly.Nonce(data: chunkNonce))
            file += sealed.ciphertext + sealed.tag
            start = end; counter += 1
        } while start < value.count
        let text = file.base64EncodedString()
        var armored = head + "\n"
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 64, limitedBy: text.endIndex) ?? text.endIndex
            armored += text[index..<next] + "\n"
            index = next
        }
        return armored + tail + "\n"
    }

    /// True for an armored age file that this app made: the form the hub takes (`sealed_copy`), which also tells a
    /// sealed copy apart from a value at a glance. It does not open it.
    public static func isSealed(_ text: String) -> Bool {
        guard text.hasPrefix(head + "\n"), text.hasSuffix(tail + "\n") else { return false }
        let inside = text.dropFirst(head.count + 1).dropLast(tail.count + 1)
        let rows = inside.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        guard inside.hasSuffix("\n"), !rows.isEmpty, rows.dropLast().allSatisfy({ $0.count == 64 }), (rows.last?.count ?? 0) <= 64,
              let file = Data(base64Encoded: rows.joined()) else { return false }
        return file.starts(with: Data("age-encryption.org/v1\n-> X25519 ".utf8))
    }

    /// How many characters `seal` writes for a value of `count` bytes. Nothing in the file varies with the value but
    /// its own length: one fixed header, the payload's nonce, and one tag for each chunk, in base64 lines of 64.
    public static func sealedLength(of count: Int) -> Int {
        let chunks = max(1, (count + chunk - 1) / chunk)        // an empty value is one empty last chunk
        let text = (headerBytes + 16 + count + 16 * chunks + 2) / 3 * 4
        return head.count + 1 + text + (text + 63) / 64 + tail.count + 1
    }

    /// The longest value whose sealed copy is at most `limit` characters.
    public static func longestSealed(within limit: Int) -> Int {
        var low = 0, high = max(0, limit)                       // base64 alone is longer than the value
        while low < high {
            let mid = (low + high + 1) / 2
            if sealedLength(of: mid) <= limit { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The 32 bytes of an `age1…` recipient, or nil: Bech32 (BIP 173) in lower case, with the human-readable part
    /// "age", a valid checksum, and no padding bits that are set.
    public static func publicKey(of recipient: String) -> Data? {
        let bytes = Array(recipient.utf8)
        guard bytes.count == 62, recipient.hasPrefix("age1") else { return nil }
        var values: [UInt8] = []
        for byte in bytes.dropFirst(4) {
            guard let index = charset.firstIndex(of: byte) else { return nil }
            values.append(UInt8(index))
        }
        let hrp = Array("age".utf8)
        guard polymod(hrp.map { $0 >> 5 } + [0] + hrp.map { $0 & 31 } + values) == 1 else { return nil }
        var accumulator = 0, bits = 0, out: [UInt8] = []
        for value in values.dropLast(6) {
            accumulator = accumulator << 5 | Int(value)
            bits += 5
            while bits >= 8 {
                bits -= 8
                out.append(UInt8(accumulator >> bits & 0xff))
            }
            accumulator &= (1 << bits) - 1
        }
        guard bits < 5, accumulator == 0, out.count == 32 else { return nil }
        return Data(out)
    }

    /// Bech32 (BIP 173) of `data` under the human-readable part `hrp`, in lower case and with no length limit, as age
    /// writes its keys: "age" gives a recipient (`age1…`), which `publicKey(of:)` reads back, and "AGE-SECRET-KEY-",
    /// upper-cased by the caller, an identity (`AGE-SECRET-KEY-1…`). The checksum is over the lower-case part, as
    /// age computes it, so the upper-case identity is the one `age-keygen -y` reads.
    public static func bech32(_ hrp: String, _ data: Data) -> String {
        let prefix = Array(hrp.lowercased().utf8)
        var values: [UInt8] = [], accumulator = 0, bits = 0
        for byte in data {
            accumulator = accumulator << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                values.append(UInt8(accumulator >> bits & 31))
            }
            accumulator &= (1 << bits) - 1
        }
        if bits > 0 { values.append(UInt8(accumulator << (5 - bits) & 31)) }      // the last group, padded with zero bits
        let check = polymod(prefix.map { $0 >> 5 } + [0] + prefix.map { $0 & 31 } + values + [0, 0, 0, 0, 0, 0]) ^ 1
        let symbols = values + (0..<6).map { UInt8(check >> (5 * (5 - UInt32($0))) & 31) }
        return String(decoding: prefix, as: UTF8.self) + "1" + String(decoding: symbols.map { charset[Int($0)] }, as: UTF8.self)
    }

    public static func secureRandom(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure.random }
        return Data(bytes)
    }

    private static func key(_ material: Data, salt: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: salt, info: Data(info.utf8), outputByteCount: 32)
    }

    /// Base64 without padding, as age writes the header.
    private static func raw(_ data: Data) -> String {
        var text = data.base64EncodedString()
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    /// A stanza's body in lines of 64 columns. A body whose last line is full ends with an empty line.
    private static func lines(_ text: String) -> String {
        var rows: [Substring] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 64, limitedBy: text.endIndex) ?? text.endIndex
            rows.append(text[index..<next])
            index = next
        }
        if rows.last?.count ?? 64 == 64 { rows.append("") }
        return rows.joined(separator: "\n")
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var check: UInt32 = 1
        for value in values {
            let top = check >> 25
            check = (check & 0x1ffffff) << 5 ^ UInt32(value)
            for index in 0..<5 where top >> index & 1 == 1 { check ^= generator[index] }
        }
        return check
    }
}
