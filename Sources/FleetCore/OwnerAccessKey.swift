import CryptoKit
import Foundation

/// **The owner's access key of one fleet**: the way back for an owner who lost the Mac that he runs his fleet from and
/// still has a copy of the fleet (the owner, 10 November 2026: "the idea of the restoration is that I have 'lost' a
/// laptop where I run the fleet from, but I had the backup, so sohuld be able to restore it", and his yes the same day
/// to a key in the copy).
///
/// It is one Ed25519 SSH key, made on the owner's Mac, once for a fleet:
///
///   - **Its public half is a line of root's `authorized_keys`** on each Linux server of the fleet, beside the line of
///     the app's own key (`AppSSHKey`).
///   - **Its private half is in this Mac's keychain** (`OwnerAccessKeychain`) **and in each copy of the fleet**
///     (`OwnerAccess.add`), as an OpenSSH private key file, so `ssh -i` takes the file as the copy carries it.
///
/// So a new Mac that has a copy can log in to the fleet's servers as root, and from there do what only root on those
/// servers may do: give the hub its new owner, and give each server the new Mac's own key. The servers take SSH over
/// the owner's private network only, so the key opens nothing for somebody who is not on that network.
///
/// **It is not the recovery code** (`RecoveryCode`). A copy also carries the central vault's store, sealed to the key
/// that the recovery code derives, and a copy that carried the code too would open every secret of the fleet by
/// itself, with no network at all. The code stays where it was: in the Mac's keychain, and on the owner's phone.
///
/// It is not Codable, and it prints as nothing, so no log, report or crash record can carry it by accident.
public struct OwnerAccessKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The comment of its `authorized_keys` line and of its key file, which says what the line is to somebody who reads
    /// a server's file.
    public static let comment = "founderizer-owner-access"
    static let kind = "ssh-ed25519"
    static let magic = Data("openssh-key-v1".utf8) + [0]

    /// The 32 bytes of the Ed25519 private key, which are all the key is.
    public let seed: Data
    let publicKey: Data

    /// The key of these 32 bytes, or nil when they are not a key.
    public init?(seed: Data) {
        guard seed.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        self.seed = Data(seed)
        publicKey = key.publicKey.rawRepresentation
    }

    /// A new key from the system's random source.
    public static func make(random: (Int) throws -> Data = AgeSeal.secureRandom) throws -> OwnerAccessKey {
        guard let key = OwnerAccessKey(seed: try random(32)) else { throw AgeSeal.Failure.random }
        return key
    }

    /// Its public half in SSH's own form: the key's kind and its 32 bytes, each with its length before it.
    var publicBlob: Data { Self.string(Data(Self.kind.utf8)) + Self.string(publicKey) }

    /// The line of `authorized_keys`: "ssh-ed25519 AAAA… founderizer-owner-access".
    public var publicLine: String { "\(Self.kind) \(publicBlob.base64EncodedString()) \(Self.comment)" }

    /// Its fingerprint as `ssh-keygen -l` prints it: "SHA256:" and the digest of the public half, in base64 with no
    /// padding. It names the key where the key itself must not be written.
    public var fingerprint: String {
        "SHA256:" + Data(SHA256.hash(data: publicBlob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// **The key as an OpenSSH private key file**, with no passphrase, which is what a copy carries: the same bytes for
    /// the same key, so a copy that gets the key twice gets one file.
    public var privateFile: String {
        // The two check numbers are equal, which is all that OpenSSH asks of them. They come from the public half, so
        // the file of a key never changes.
        let check = Data(SHA256.hash(data: Data("founderizer check".utf8) + publicKey).prefix(4))
        var secret = check + check + Self.string(Data(Self.kind.utf8)) + Self.string(publicKey)
            + Self.string(seed + publicKey) + Self.string(Data(Self.comment.utf8))
        var pad: UInt8 = 1
        while secret.count % 8 != 0 { secret.append(pad); pad += 1 }
        let none = Self.string(Data("none".utf8))
        let whole = Self.magic + none + none + Self.string(Data()) + Self.number(1) + Self.string(publicBlob) + Self.string(secret)
        let text = whole.base64EncodedString()
        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var at = text.startIndex
        while at < text.endIndex {
            let end = text.index(at, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(String(text[at..<end]))
            at = end
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The key that an OpenSSH private key file holds, when it is one Ed25519 key with no passphrase and its two
    /// halves belong together; else nil. The file comes out of a copy, which is a file like any other: nothing of it
    /// is trusted before its own public half is made again from its private half.
    public init?(privateFile text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3, lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----",
              let whole = Data(base64Encoded: lines.dropFirst().dropLast().joined()), whole.count <= 4096,
              whole.starts(with: Self.magic) else { return nil }
        var reader = Reader(whole.dropFirst(Self.magic.count))
        guard reader.string() == Data("none".utf8), reader.string() == Data("none".utf8), reader.string() == Data(),
              reader.number() == 1, let blob = reader.string(), let secret = reader.string(), reader.isAtEnd else { return nil }
        var inner = Reader(secret)
        guard let first = inner.number(), let second = inner.number(), first == second,
              inner.string() == Data(Self.kind.utf8), let publicKey = inner.string(), publicKey.count == 32,
              let both = inner.string(), both.count == 64, both.suffix(32) == publicKey, inner.string() != nil,
              let key = OwnerAccessKey(seed: Data(both.prefix(32))), key.publicKey == publicKey, key.publicBlob == blob
        else { return nil }
        self = key
    }

    public var description: String { "OwnerAccessKey" }
    public var debugDescription: String { "OwnerAccessKey" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// A number as SSH writes it: four bytes, the highest first.
    static func number(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    /// Bytes as SSH writes them: their count as a number, then the bytes.
    static func string(_ bytes: Data) -> Data { number(UInt32(bytes.count)) + bytes }

    /// Reads SSH's numbers and strings out of some bytes, and gives nil past their end.
    private struct Reader {
        private var rest: Data
        init(_ data: Data) { rest = Data(data) }
        var isAtEnd: Bool { rest.isEmpty }

        mutating func number() -> UInt32? {
            guard rest.count >= 4 else { return nil }
            let value = rest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            rest = Data(rest.dropFirst(4))
            return value
        }

        mutating func string() -> Data? {
            guard let count = number(), rest.count >= Int(count) else { return nil }
            let value = Data(rest.prefix(Int(count)))
            rest = Data(rest.dropFirst(Int(count)))
            return value
        }
    }
}

/// **Where the owner's access key is kept**: in this Mac's login keychain only, one item for each fleet (service
/// `com.founderizer.owner-access`, account the fleet's id), the way the owner key and the recovery code are kept. The
/// app shows and logs it nowhere; it goes into the copies of that fleet, and its public half to the fleet's servers.
public enum OwnerAccessKeychain {
    public static let item = FleetKeychainItem(service: "com.founderizer.owner-access", label: "owner access key")

    /// The key this Mac keeps for the fleet, or nil.
    public static func key(fleet: String) -> OwnerAccessKey? {
        item.read(fleet: fleet).flatMap { OwnerAccessKey(seed: $0) }
    }

    /// The key this Mac keeps for the fleet, made and kept now when it keeps none. It is read back before it is
    /// returned, because a key that is not kept would be a line on the servers that no copy can use.
    public static func kept(fleet: String) throws -> OwnerAccessKey {
        if let key = key(fleet: fleet) { return key }
        let key = try OwnerAccessKey.make()
        try keep(key, fleet: fleet)
        return key
    }

    /// Keeps this key for the fleet, in place of any earlier one: a new Mac keeps the key that it took from a copy.
    public static func keep(_ key: OwnerAccessKey, fleet: String) throws {
        try item.keep(key.seed, fleet: fleet)
        guard Self.key(fleet: fleet) == key else { throw FleetKeychainItem.Failure(label: item.label, status: errSecItemNotFound) }
    }
}

/// **The access key in a copy of the fleet.** The hub writes a copy and never sees this key, so this Mac puts it in:
/// one more member of the zip, which the hub's restore does not read (it reads the members that the copy's own
/// manifest lists, and this one is not among them).
public enum OwnerAccess {
    /// The member's name in the zip.
    public static let member = "owner-access.key"

    /// Puts the fleet's access key into this copy, when the copy has none. The fleet is the one that the copy's own
    /// manifest names. `key` gives the key of a fleet; the app's is the keychain's, which makes one when it keeps none.
    public static func add(to copy: URL, key: (String) throws -> OwnerAccessKey = OwnerAccessKeychain.kept) throws {
        let fleet = try ChosenCopy.read(copy).manifest.fleet_id
        try ZipArchive.add(Data(try key(fleet).privateFile.utf8), named: member, to: copy)
    }

    /// **The copy with the fleet's access key in it**, as a second file beside the copy, in the folder that this app made
    /// for the copy; nil when the key did not go in, and the copy is then as it was. The key goes into the second file
    /// and never into the copy itself, so a write that stops halfway costs no copy, and the second file counts only
    /// once it reads as a copy that carries the key.
    public static func withKey(_ copy: URL, key: (String) throws -> OwnerAccessKey = OwnerAccessKeychain.kept) -> URL? {
        let made = copy.deletingLastPathComponent().appendingPathComponent("with-key-" + copy.lastPathComponent)
        try? FileManager.default.removeItem(at: made)
        do {
            try FileManager.default.copyItem(at: copy, to: made)
            try add(to: made, key: key)
            guard self.key(in: made) != nil else { throw ZipArchive.Trouble.damaged }
            return made
        } catch {
            try? FileManager.default.removeItem(at: made)
            return nil
        }
    }

    /// What `install`'s program prints once the key's line is in the file.
    public static let inPlace = "founderizer-owner-access-in-place"
    /// Where root keeps the keys that it logs in with, on every system that the installers take.
    public static let rootKeys = "/root/.ssh/authorized_keys"

    /// **The program that puts the key's public half on one Linux server of the fleet**, for root there: its line goes
    /// into root's `authorized_keys`, once, after a file that may not end with a new line, and nothing else in the file
    /// changes. It prints `inPlace` when the line is there, also when it was there before.
    public static func install(_ key: OwnerAccessKey, file: String = rootKeys) -> String {
        let line = InstallPlan.quote(key.publicLine), file = InstallPlan.quote(file)
        return "f=\(file); umask 077; mkdir -p \"$(dirname \"$f\")\"; touch \"$f\"; "
            + "grep -qxF \(line) \"$f\" || { [ -z \"$(tail -c1 \"$f\")\" ] || echo >> \"$f\"; "
            + "printf '%s\\n' \(line) >> \"$f\"; }; grep -qxF \(line) \"$f\" && echo \(inPlace)"
    }

    /// Whether the program's output says that the line is in place.
    public static func isInPlace(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == inPlace }
    }

    /// The access key that a copy carries, with the id of its fleet; nil when it carries none, or none that is a key.
    public static func key(in copy: URL) -> (fleet: String, key: OwnerAccessKey)? {
        guard let chosen = try? ChosenCopy.read(copy),
              let found = try? ZipArchive.member(member, in: copy, limit: 4096),
              let text = String(data: found, encoding: .utf8), let key = OwnerAccessKey(privateFile: text) else { return nil }
        return (chosen.manifest.fleet_id, key)
    }
}
