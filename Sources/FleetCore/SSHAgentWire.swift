import CryptoKit
import Foundation

/// **The SSH wire of a P-256 key** (release-keys-secure-enclave.md, section 6 and its appendix; app-ssh-key-build-spec.md,
/// "Agent"): the public blob and the public line of a key, the signature blob from r and s, the answer of an agent to
/// one message, and the encoders of a string and of a number of 32 bits that all of them use.
///
/// One file for two programs. The app compiles it in `FleetCore`. `founderizer-sign` compiles a copy of it beside its
/// own `main.swift`, in the Swift 5 mode of that build (autopublish.py `signer_build`). So this file imports Foundation
/// and CryptoKit only, and no other part of the app. A change of it reaches the signer only at the signer's next
/// `--install-signer`, so a change for the app cannot stop a release.
///
/// The key type is the plain `ecdsa-sha2-nistp256` (RFC 5656). A key of this Mac's Secure Enclave and a key in memory
/// sign in the same way, so the agent takes a function that signs and never a private key: the private half of a key
/// of the Secure Enclave never leaves the chip.
///
/// The agent gives the list of its keys (message 11), with its one key. It signs (message 13) only the data of a
/// public-key login (RFC 4252, section 7) with its key, as the one user that it allows. Each other message gets
/// failure (5): it never adds, removes or locks a key. A message over 256 KiB closes the connection, as in OpenSSH's
/// own agent. Which process may ask is not this file's rule: the program that holds the socket answers only the child
/// that it started.
public enum SSHAgentWire {
    /// The type of each key here (RFC 5656).
    public static let keyType = "ecdsa-sha2-nistp256"
    /// The name of the key's curve in its public blob.
    static let curve = "nistp256"

    // MARK: the encoders

    /// A number of 32 bits, high byte first.
    public static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    /// A string: its length as a number of 32 bits, then its bytes.
    public static func string(_ bytes: Data) -> Data {
        uint32(UInt32(bytes.count)) + bytes
    }

    /// A string of the UTF-8 bytes of `text`.
    public static func string(_ text: String) -> Data {
        string(Data(text.utf8))
    }

    /// An mpint (RFC 4251, section 5) of a number that is not negative, given as its bytes, high byte first: a string
    /// with no first zero bytes, and one zero byte before a first byte of 0x80 or more, so that the number does not
    /// read as a negative one. Zero is the empty string.
    public static func mpint(_ magnitude: Data) -> Data {
        var bytes = Array(magnitude.drop(while: { $0 == 0 }))
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return string(Data(bytes))
    }

    // MARK: the reader

    /// The fields of a blob, read one after the other. A read that the rest of the blob does not hold gives nil and
    /// reads nothing.
    public struct Reader: Sendable {
        private let bytes: [UInt8]
        private var at = 0

        public init(_ data: Data) {
            bytes = Array(data)
        }

        /// True when each byte of the blob was read.
        public var atEnd: Bool { at == bytes.count }

        public mutating func byte() -> UInt8? {
            guard at < bytes.count else { return nil }
            at += 1
            return bytes[at - 1]
        }

        public mutating func uint32() -> UInt32? {
            guard bytes.count - at >= 4 else { return nil }
            let value = bytes[at ..< at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            at += 4
            return value
        }

        public mutating func string() -> Data? {
            guard bytes.count - at >= 4 else { return nil }
            let length = Int(bytes[at ..< at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard bytes.count - at - 4 >= length else { return nil }
            at += 4 + length
            return Data(bytes[at - length ..< at])
        }
    }

    // MARK: the public key

    /// The public blob of a key: string `ecdsa-sha2-nistp256`, string `nistp256`, string Q (65 bytes: 04, X, Y).
    public static func publicBlob(_ key: P256.Signing.PublicKey) -> Data {
        string(keyType) + string(curve) + string(key.x963Representation)
    }

    /// The public line of a key, as a public file and `authorized_keys` hold it: `ecdsa-sha2-nistp256 <base64 of the
    /// public blob> <comment>`, with no comment when `comment` is empty.
    public static func publicLine(_ key: P256.Signing.PublicKey, comment: String) -> String {
        ([keyType, publicBlob(key).base64EncodedString()] + (comment.isEmpty ? [] : [comment])).joined(separator: " ")
    }

    /// The key of a public blob, or nil when the blob is not the public blob of a P-256 key, as publicBlob writes it.
    public static func publicKey(blob: Data) -> P256.Signing.PublicKey? {
        var reader = Reader(blob)
        guard reader.string() == Data(keyType.utf8), reader.string() == Data(curve.utf8), let point = reader.string(),
              reader.atEnd, point.count == 65, point.first == 4 else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: point)
    }

    /// The key of a public line (`ecdsa-sha2-nistp256 <base64 of the public blob>`, with any comment after it), or nil
    /// when the line is no public line of a P-256 key: a line of another key type or a private key gives nil. The
    /// words are split at each white space, so the line break at the end of a line with no comment is no part of the
    /// base64.
    public static func publicKey(line: String) -> P256.Signing.PublicKey? {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words[0] == keyType, let blob = Data(base64Encoded: String(words[1])) else { return nil }
        return publicKey(blob: blob)
    }

    // MARK: the signature

    /// The signature blob of a signature, from its two numbers r and s, each given as its bytes, high byte first:
    /// string `ecdsa-sha2-nistp256`, then a string of mpint r and mpint s (RFC 5656, section 3.1.2).
    public static func signatureBlob(r: Data, s: Data) -> Data {
        string(keyType) + string(mpint(r) + mpint(s))
    }

    /// The signature blob of a signature that CryptoKit made: its raw form is r and then s, 32 bytes each.
    public static func signatureBlob(_ signature: P256.Signing.ECDSASignature) -> Data {
        let raw = signature.rawRepresentation
        return signatureBlob(r: raw.prefix(32), s: raw.suffix(32))
    }

    // MARK: the agent

    /// The types of message that the agent reads and writes (draft-miller-ssh-agent, section 6.1).
    enum Kind: UInt8 {
        case failure = 5        // SSH_AGENT_FAILURE
        case listKeys = 11      // SSH_AGENTC_REQUEST_IDENTITIES
        case keyList = 12       // SSH_AGENT_IDENTITIES_ANSWER
        case sign = 13          // SSH_AGENTC_SIGN_REQUEST
        case signature = 14     // SSH_AGENT_SIGN_RESPONSE
    }

    /// The longest message that the agent reads, in bytes after its length: 256 KiB, as OpenSSH's own AGENT_MAX_LEN.
    public static let largest = 256 * 1024

    /// The answer of failure (5), with its length: the answer to each message that the agent does not answer
    /// otherwise.
    public static let failure = string(Data([Kind.failure.rawValue]))

    /// What a connection does with the bytes that it read and did not use yet.
    public enum Next: Equatable, Sendable {
        /// The next message is not all there yet: read more.
        case partial
        /// A whole message: its type byte and its contents, and the count of bytes that it takes at the start of the
        /// bytes, its length included.
        case message(Data, size: Int)
        /// The next message is longer than `largest`: close the connection, and read none of it.
        case tooLong
    }

    /// The first message of `bytes`, the bytes that a connection read and did not use yet.
    public static func next(_ bytes: Data) -> Next {
        var reader = Reader(bytes.prefix(4))
        guard let given = reader.uint32() else { return .partial }
        let length = Int(given)
        guard length <= largest else { return .tooLong }
        guard bytes.count >= 4 + length else { return .partial }
        return .message(Data(bytes.dropFirst(4).prefix(length)), size: 4 + length)
    }

    /// The answer to one message (its type byte and its contents, as `next` gives it), with its length. To message
    /// 11: the list with the one key `key` and its comment. To message 13: the signature of the data, made by `sign`,
    /// when the message asks for a signature with this key of the data of a login of `user` (`isLoginRequest`), and
    /// the signature is good for `key`. Failure to each other message, and when `sign` throws.
    public static func answer(to message: Data, key: P256.Signing.PublicKey, comment: String, user: String,
                              sign: (Data) throws -> P256.Signing.ECDSASignature) -> Data {
        var reader = Reader(message)
        let blob = publicBlob(key)
        switch reader.byte().flatMap(Kind.init(rawValue:)) {
        case .listKeys? where reader.atEnd:
            return string(Data([Kind.keyList.rawValue]) + uint32(1) + string(blob) + string(comment))
        case .sign?:
            guard reader.string() == blob, let data = reader.string(), reader.uint32() != nil, reader.atEnd,
                  isLoginRequest(data, blob: blob, user: user), let signature = try? sign(data),
                  key.isValidSignature(signature, for: data) else { return failure }
            return string(Data([Kind.signature.rawValue]) + string(signatureBlob(signature)))
        default:
            return failure
        }
    }

    /// True when `data` is the data that ssh signs to log in with the key of the public blob `blob` as `user`, and
    /// nothing more (RFC 4252, section 7; OpenSSH's PROTOCOL, `publickey-hostbound-v00@openssh.com`): string the
    /// session id (not empty), byte 50, string the user, string `ssh-connection`, string `publickey` or
    /// `publickey-hostbound-v00@openssh.com`, a byte 1, string `ecdsa-sha2-nistp256`, string the public blob, and for
    /// the second method a string of the server's host key. So the signed bytes of a commit, a login as another user
    /// and a login with another key are no login request.
    public static func isLoginRequest(_ data: Data, blob: Data, user: String) -> Bool {
        var reader = Reader(data)
        guard !user.isEmpty, reader.string()?.isEmpty == false, reader.byte() == 50,
              reader.string() == Data(user.utf8), reader.string() == Data("ssh-connection".utf8),
              let method = reader.string(), reader.byte() == 1, reader.string() == Data(keyType.utf8),
              reader.string() == blob else { return false }
        if method == Data("publickey-hostbound-v00@openssh.com".utf8) {
            guard reader.string()?.isEmpty == false else { return false }
        } else if method != Data("publickey".utf8) {
            return false
        }
        return reader.atEnd
    }
}
