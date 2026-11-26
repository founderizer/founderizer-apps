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

    /// The key this Mac keeps for the fleet, made and kept now **only when the keychain says that none is there**
    /// (`FleetKeychainItem.held`): a read that fails now throws and keeps the key, because a new one would no longer
    /// match the key in the fleet's copies (the Door area's read of 24 November 2026; the sweep calls this each round).
    /// It is read back before it is returned, because a key that is not kept would be a line on the servers that no
    /// copy can use.
    public static func kept(fleet: String) throws -> OwnerAccessKey {
        let read = item.lookup(fleet: fleet)
        switch item.held(read, decode: { OwnerAccessKey(seed: $0) }) {
        case .value(let key): return key
        case .notNow(let failure): throw failure
        case .none: try item.mayMake(read)
        }
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

/// **A hub's copy that passed the form check** (`OwnerAccess.checkHubForm`): its file, and what the file was when it
/// passed (its device, file number, size and time of change), which the key's step reads again. Only the check makes one.
public struct HubCopy: Sendable {
    public let file: URL
    let identity: [Int]?

    /// What a file is now, or nil when it cannot be read: a link is read as itself, never followed.
    static func identity(of file: URL) -> [Int]? {
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return [Int(info.st_dev), Int(info.st_ino), Int(info.st_size), Int(info.st_mtimespec.tv_sec),
                Int(info.st_mtimespec.tv_nsec), Int(info.st_ctimespec.tv_sec), Int(info.st_ctimespec.tv_nsec)]
    }
}

/// **The access key in a copy of the fleet.** The hub writes a copy and never sees this key, so this Mac puts it in:
/// one more member of the zip, which the hub's restore does not read (it reads the members that the copy's own
/// manifest lists, and this one is not among them).
public enum OwnerAccess {
    /// The member's name in the zip.
    public static let member = "owner-access.key"

    /// The names that a copy's manifest lists under `files`, and nothing else of it: none when it has no such object.
    static func listedFiles(_ copy: URL) throws -> [String] {
        let manifest: Data
        do {
            manifest = try ZipArchive.member(FleetManifest.manifestMember, in: copy, limit: 1 << 20)
        } catch {
            throw RestoreError.notACopy
        }
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] else {
            throw RestoreError.notACopy
        }
        return ((object["files"] as? [String: Any]) ?? [:]).keys.map { $0 }
    }

    /// Puts the fleet's access key into this copy, when the copy has none. The fleet is the one that the copy's own
    /// manifest names. `key` gives the key of a fleet; the app's is the keychain's, which makes one when it keeps none.
    public static func add(to copy: URL, key: (String) throws -> OwnerAccessKey = OwnerAccessKeychain.kept) throws {
        let fleet = try self.fleet(of: copy)
        try ZipArchive.add(Data(try key(fleet).privateFile.utf8), named: member, to: copy)
    }

    /// **The fleet of a copy, and nothing else of its manifest** (the audit's finding 1, 24 November 2026): the key's
    /// step read the manifest with the restore's own check (`ChosenCopy.read`: format 1, a fixed list of members, its
    /// limits), and the hub releases before the app. So a hub that added a member to the manifest would have made every
    /// older Mac keep its copies with no key and no word, until the last copy with the key went. Only `fleet_id` is read
    /// here, from `fleet.json` (at most 1 MiB), and it must be a fleet's id: 1 to 64 lowercase hex characters.
    static func fleet(of copy: URL) throws -> String {
        struct Fleet: Decodable { let fleet_id: String }
        let fleet: String
        do {
            let manifest = try ZipArchive.member(FleetManifest.manifestMember, in: copy, limit: 1 << 20)
            fleet = try JSONDecoder().decode(Fleet.self, from: manifest).fleet_id
        } catch {
            throw RestoreError.notACopy
        }
        guard !fleet.isEmpty, fleet.count <= 64, fleet.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw RestoreError.notACopy
        }
        return fleet
    }

    /// **The copy with the fleet's access key in it**, as a second file beside the copy, mode 600, in the folder that
    /// this app made for the copy; nil when the key did not go in, and the copy is then as it was. The key goes into the
    /// second file and never into the copy itself, so a write that stops halfway costs no copy. A key member that the
    /// hub's copy carries already is not this fleet's key: it stays out (`ZipArchive.copy`), so no hub puts a key of its
    /// own into the copies that the owner keeps for the way back. The second file counts only once the key that it
    /// reads is the fleet's own.
    public static func withKey(_ copy: HubCopy, key: (String) throws -> OwnerAccessKey = OwnerAccessKeychain.kept) -> URL? {
        (try? keyed(copy, key: key))?.file
    }

    /// `withKey` of a file that no form check passed: this module's tests only.
    static func withKey(_ copy: URL, key: (String) throws -> OwnerAccessKey = OwnerAccessKeychain.kept) -> URL? {
        keyed(copy, key: key).file
    }

    /// **The key's step of a hub's copy that passed the form check** (`checkHubForm`, the validator's S1 of 26 November
    /// 2026): only that check makes a `HubCopy`, so no caller keys a copy that skipped it, and the caller's fallback (the
    /// hub's own file when the key could not go in) is a file that passed it. It throws when the file is no longer the one
    /// that passed (another file in its place, or changed since), and the caller keeps nothing then.
    public static func keyed(_ copy: HubCopy, key: (String) throws -> OwnerAccessKey = OwnerAccessKeychain.kept)
        throws -> (file: URL?, cause: String?) {
        guard HubCopy.identity(of: copy.file) == copy.identity else {
            throw FleetCopyError.cannotKeep(RestoreError.notACopy.errorDescription ?? "")
        }
        return keyed(copy.file, key: key)
    }

    /// `withKey`, with why the key did not go in when it did not (the validator's S3 of 25 November 2026): the system's
    /// or this app's own words of the failure, which Report a problem carries (`FleetCopyKeeper.keyCause`). A failure of
    /// the keychain names its item and status, and one of the copy names what the zip did not allow; neither holds the
    /// key.
    static func keyed(_ copy: URL, key: (String) throws -> OwnerAccessKey = OwnerAccessKeychain.kept)
        -> (file: URL?, cause: String?) {
        let made = copy.deletingLastPathComponent().appendingPathComponent("with-key-" + copy.lastPathComponent)
        try? FileManager.default.removeItem(at: made)
        do {
            // The hub's copy as it is, as a clone that takes no time, when it carries no member of the key's name (the
            // usual case); else written new without them (`ZipArchive.copy`).
            if try ZipArchive.names(in: copy).contains(where: isKey) {
                try ZipArchive.copy(copy, to: made, without: isKey)
            } else {
                try FileManager.default.copyItem(at: copy, to: made)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: made.path)
            }
            // A manifest that lists a member of the key's name is a hub's, never this app's: such a copy keeps no key
            // (the Door area's read of 25 November 2026). Only the names of its files are read, so a hub that adds
            // members of its own to the manifest still has its copies kept (fleet(of:)).
            guard try !listedFiles(made).contains(where: isKey) else { throw RestoreError.notACopy }
            let wanted = try key(try fleet(of: made))
            guard try ZipArchive.add(Data(wanted.privateFile.utf8), named: member, to: made),
                  self.key(in: made)?.key == wanted else { throw ZipArchive.Trouble.damaged }
            return (made, nil)
        } catch {
            try? FileManager.default.removeItem(at: made)
            let said = (error as? LocalizedError)?.errorDescription
            return (nil, String(l10n: "The access key did not go into the copy:") + " "
                         + (said ?? "\(type(of: error)).\(error)"))
        }
    }

    /// Whether this file is a zip that lists the access key's member: read from its central directory, so no key is
    /// read into memory (retention's question, `FleetCopyKeeper.carriesKey`). `withKey` checked the key when it wrote it.
    public static func carries(_ copy: URL) -> Bool {
        (try? ZipArchive.names(in: copy))?.contains(member) == true
    }

    /// Whether a member's name is the key's: the copy's own top level (a name whose other parts are only "." or empty,
    /// split at / and \\), in any case, read to its first NUL as unzip and ditto write it. That is the member that the
    /// way back reads (`unzip -p <copy>.zip owner-access.key`, `key(in:)`); a file of that name in a folder, such as an
    /// agent's skill file under config/skills, is another file, and stops no copy (the Door area's read of
    /// 25 November 2026).
    public static func isKey(_ name: String) -> Bool {
        // By Unicode scalars, not by characters: a mark or a Prepend scalar next to a / would join it into one
        // character, and a split by characters would not see that /.
        var parts: [String] = []
        var part = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "\0" { break }
            if scalar == "/" || scalar == "\\" {
                parts.append(String(part))
                part = String.UnicodeScalarView()
            } else {
                part.append(scalar)
            }
        }
        parts.append(String(part))
        // The whole name resolved as ditto (Finder's Archive Utility) resolves it: "" and "." go, ".." takes the part
        // before it and stops at the top. The key is a name whose first part left is the key's, folded as this Mac's
        // disk folds names ("owner-acceß.key", the long s): the file itself, or a folder of that name, which would
        // keep a full extraction from writing the key's file.
        // A drive letter first ("C:", "C:\\") goes too, as bsdtar takes it away.
        if let drive = parts.first?.unicodeScalars, drive.count >= 2,
           CharacterSet.letters.contains(drive[drive.startIndex]), drive[drive.index(after: drive.startIndex)] == ":" {
            parts[0] = String(String.UnicodeScalarView(drive.dropFirst(2)))
        }
        var left: [String] = []
        for part in parts where !part.isEmpty && part != "." {
            if part == ".." { _ = left.popLast() } else { left.append(part) }
        }
        guard let first = left.first else { return false }
        return first.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == member
    }

    /// **The copy as it goes to a hub: without the fleet's access key**, which is root on every server of the fleet and
    /// which no hub ever holds. nil when the copy carries no member of that name, and it goes as it is. Else a new file,
    /// mode 600, in a new folder of this app's own, mode 700, which the caller removes: the copy without those members
    /// (`ZipArchive.copy`, which only reads the copy). It counts only when it holds every other member and no key
    /// member, when one key member ended where the directory starts (where `add` writes the key: a hub that crafted
    /// its copy for a Mac whose `withKey` took any key could hide that entry behind one of its own and cover its bytes
    /// with another member's extra field — the Door area's read of 25 November 2026), and when the file holds neither
    /// the key members' bytes nor this fleet's own key (`known`, this Mac's keychain), anywhere. Else nothing goes: a
    /// `RestoreError`, `notACopy` for a file that is not a copy this app reads or wrote (a key member inside one would
    /// go with it), `cannotRead` for a file it could not read or write, such as a full disk.
    public static func withoutKey(_ copy: URL,
                                  known: (String) -> OwnerAccessKey? = { OwnerAccessKeychain.key(fleet: $0) }) throws -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("founderizer-restore-" + UUID().uuidString)
        do {
            let names = try ZipArchive.names(in: copy)
            let keys = names.filter(isKey)
            guard !keys.isEmpty else { return nil }
            let fleetKey = (try? fleet(of: copy)).flatMap { known($0) }
            let secrets = try keys.map { try ZipArchive.member($0, in: copy, limit: 64 << 10) }.filter { !$0.isEmpty }
                + (fleetKey.map { [Data($0.privateFile.utf8)] } ?? [])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let made = folder.appendingPathComponent("copy.zip")
            let (gone, atDirectory) = try ZipArchive.copy(copy, to: made, without: isKey)
            guard gone == keys, atDirectory, try ZipArchive.names(in: made) == names.filter({ !isKey($0) }),
                  try !holds(made, any: secrets) else { throw ZipArchive.Trouble.damaged }
            return made
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if let error = error as? RestoreError { throw error }
            if error is ZipArchive.Trouble { throw RestoreError.notACopy }
            throw RestoreError.cannotRead(error.localizedDescription)
        }
    }

    /// **A hub's copy that the owner may keep** (`CopyKeeper`, `HealthView`, before the key's step `keyed`): it must be in
    /// the one form that a hub writes (`HubCopyForm`, the owner tools' check), else it throws, and the caller keeps and
    /// confirms nothing. A hub that hides a member in a gap, after the last one, inside a member after its deflate
    /// stream ends, or behind a second directory could else make a reader of the kept copy (ditto, unzip) write its own
    /// key as owner-access.key, the owner's way back (the validator's read of 25 November 2026). A copy in that form
    /// holds no member of the key's name and nothing hidden, so `keyed`'s file, or the hub's own file when the key could
    /// not go in, is safe to keep. It inflates the whole copy: call it off the main actor.
    @discardableResult
    public static func checkHubForm(_ copy: URL) throws -> HubCopy {
        let before = HubCopy.identity(of: copy)
        guard before != nil, HubCopyForm.fault(copy.path) == nil, HubCopy.identity(of: copy) == before else {
            throw FleetCopyError.cannotKeep(RestoreError.notACopy.errorDescription ?? "")
        }
        return HubCopy(file: copy, identity: before)
    }

    /// Whether the file holds any of these byte strings anywhere, read a mebibyte at a time.
    static func holds(_ file: URL, any needles: [Data]) throws -> Bool {
        guard let longest = needles.map(\.count).max(), longest > 0 else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var carry = Data()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            let window = carry + chunk
            if needles.contains(where: { window.range(of: $0) != nil }) { return true }
            carry = Data(window.suffix(longest - 1))
        }
        return false
    }

    /// What `install`'s program prints once the key's line is in the file.
    public static let inPlace = "founderizer-owner-access-in-place"
    /// Where root keeps the keys that it logs in with, on every system that the installers take.
    public static let rootKeys = "/root/.ssh/authorized_keys"

    /// **The program that puts the key's public half on one Linux server of the fleet**, for root there: its line goes
    /// into root's `authorized_keys`, once, after a file that may not end with a new line, and nothing else in the file
    /// changes. It prints `inPlace` when the line is there, also when it was there before.
    public static func install(_ key: OwnerAccessKey, file: String = rootKeys) -> String {
        install(line: key.publicLine, file: file)
    }

    /// The same program for any one line of `authorized_keys` (the hub's root route puts the line of this Mac's own
    /// key there with it, `HubRootRoute`), which prints `mark` when the line is there.
    public static func install(line: String, file: String = rootKeys, mark: String = inPlace) -> String {
        let line = InstallPlan.quote(line), file = InstallPlan.quote(file)
        return "f=\(file); umask 077; mkdir -p \"$(dirname \"$f\")\"; touch \"$f\"; "
            + "grep -qxF \(line) \"$f\" || { [ -z \"$(tail -c1 \"$f\")\" ] || echo >> \"$f\"; "
            + "printf '%s\\n' \(line) >> \"$f\"; }; grep -qxF \(line) \"$f\" && echo \(mark)"
    }

    /// Whether the program's output says that the line is in place.
    public static func isInPlace(_ output: String, mark: String = inPlace) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == mark }
    }

    /// The access key that a copy carries, with the id of its fleet; nil when it carries none, or none that is a key. Of
    /// the manifest only the fleet is read (`fleet(of:)`), as the key's step reads it.
    public static func key(in copy: URL) -> (fleet: String, key: OwnerAccessKey)? {
        guard let fleet = try? fleet(of: copy),
              let found = try? ZipArchive.member(member, in: copy, limit: 4096),
              let text = String(data: found, encoding: .utf8), let key = OwnerAccessKey(privateFile: text) else { return nil }
        return (fleet, key)
    }
}
