import Compression
import Foundation

/// **A skill that the owner gives an agent** (owner feature `message_skills`; the owner's "Yes, as drawn" of 22
/// November 2026 to the given skill: the Mac's chat box takes a skill's folder, and its ZIP with the plus, and the chip
/// of a skill shows a bolt and the skill's name; `~/dev/founderizer-plans/slash-list-and-skills-build-design-2026-11-22.md`
/// 3). A skill is a folder with its `SKILL.md` at the top; it travels as one ZIP, which goes up as a file
/// (`POST /ui/attachments`) and is then given with the message (`MessageSkill.give`). **The hub's checks are the
/// rule** (paths, links, sizes, logins, the front matter): its words come back when it refuses a gift. This type only
/// says whether a folder or a ZIP is meant as a skill, and what its name is, so that the box can show it as one.
public enum SkillPackage {
    /// The owner feature of a skill in a message (owner API, `ui_features`): until the hub lists it, a ZIP is a file and
    /// a folder is a type that the hub does not take, as before.
    public static let feature = "message_skills"
    /// The most entries of a skill's ZIP, as the hub counts them (`SKILL_GIFT_ENTRIES`).
    public static let mostEntries = 5_000
    /// A skill's main file, in this letter case, at the top of its folder.
    public static let mainFile = "SKILL.md"
    /// A skill's name, as the hub's `lifecycle.SKILL_NAME` has it.
    nonisolated(unsafe) private static let nameShape = /[a-z0-9][a-z0-9-]{0,63}/

    // MARK: A ZIP

    /// **A ZIP is a skill when its `SKILL.md` stands at its root, or under its one top folder**, as the hub's own reader
    /// places it (`skill_gift_read`). Only the central directory's names are read, never a file's bytes: the end record,
    /// then at most `mostEntries` entries. An entry of a folder, `__MACOSX/` (a Mac's ZIP), `__pycache__/` and every path
    /// with a part that starts with a dot are left out before the top folder is found, as the hub leaves them out; a
    /// link stays a name, so the hub's words about it reach him. False for anything that this cannot read: a damaged
    /// ZIP, ZIP64, more entries than a skill holds.
    public static func isSkill(_ data: Data) -> Bool { main(in: data) != nil }

    /// **The name that a skill's ZIP shows in the box**: the `name:` of its `SKILL.md`'s front matter, when this can
    /// read it (stored or deflated, and its front matter in the file's first 64 KiB), else the name of its one top
    /// folder, else the ZIP's own name without `.zip`. nil for a ZIP that is no skill (`isSkill`).
    public static func name(inZip data: Data, fileName: String) -> String? {
        guard let found = main(in: data) else { return nil }
        if let text = text(of: found.entry, in: data), let name = name(frontMatter: text) { return name }
        if let top = found.top { return top }
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }

    /// **The `name:` of a `SKILL.md`'s front matter**, in the forms that the hub reads (`skill_gift_front`): a line
    /// `---`, then `name:` at the start of a line before the next `---`, plain, in double quotes as JSON writes a string,
    /// or in single quotes. nil when it has none, or when it is no skill's name (1 to 64 characters of a-z, 0-9 and -,
    /// a letter or a digit first): the hub then refuses the gift with its own words.
    public static func name(frontMatter text: String) -> String? {
        // by "\n" alone, as the hub splits them: a Character of Swift holds "\r\n" as one
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        guard let line = lines[1..<end].first(where: { $0.hasPrefix("name:") }) else { return nil }
        let value = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
        let name: String?
        if value.hasPrefix("\"") {
            name = try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        } else if value.hasPrefix("'") {
            name = value.count >= 2 && value.hasSuffix("'")
                ? String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") : nil
        } else {
            name = value
        }
        guard let name, name.wholeMatch(of: nameShape) != nil else { return nil }
        return name
    }

    // MARK: A folder

    /// **A folder is a skill when its `SKILL.md`, in this letter case, is a plain file at its top.** A Mac's disk takes
    /// `skill.md` for `SKILL.md`, so the names of the folder are read as it keeps them. A link to a folder is the folder.
    public static func isSkillFolder(_ folder: URL) -> Bool {
        let folder = folder.resolvingSymlinksInPath()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path), names.contains(mainFile)
        else { return false }
        let main = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(mainFile).path)
        return main?[.type] as? FileAttributeType == .typeRegular
    }

    /// The name that a skill's folder shows in the box: its `SKILL.md`'s `name:`, else the folder's own name.
    public static func name(ofFolder folder: URL) -> String {
        let folder = folder.resolvingSymlinksInPath()
        // its first bytes only: the front matter stands at its top
        let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(mainFile))
        defer { try? handle?.close() }
        if let start = try? handle?.read(upToCount: frontMatterBytes),
           let name = name(frontMatter: String(decoding: start, as: UTF8.self)) {
            return name
        }
        return folder.lastPathComponent
    }

    /// Why a skill's folder did not become a ZIP.
    public enum FolderRefusal: Error, Equatable {
        /// Its plain files hold more than the bytes given, or more entries than a skill holds.
        case tooLarge
        /// The Mac did not read it, or did not make its ZIP.
        case unreadable
    }

    /// **One ZIP of a skill's folder, with the folder's own name as its top folder** (the hub takes that folder off).
    /// The Mac's own ZIP of a folder (`NSFileCoordinator`, `.forUploading`; measured on macOS 26: one entry for each
    /// file under `<folder>/`, no entry for a folder) is made of a copy that holds only the folder's plain files and
    /// folders: **no hidden name, no `__pycache__`, no `__MACOSX` and no link**. The hub leaves the first three out of a
    /// skill, so they would travel to its file store for nothing (a `.git` folder, a `.env` file); and the Mac's ZIP
    /// refuses a folder that holds a link ("couldn't be opened because there is no such file", also for a link whose
    /// file is there). `atMost`: the most bytes of the plain files, past which nothing is copied.
    public static func zip(folder: URL, atMost: Int) throws -> Data {
        let source = folder.resolvingSymlinksInPath()
        let place = FileManager.default.temporaryDirectory
            .appendingPathComponent("founderizer-skill-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: place) }
        let copy = place.appendingPathComponent(source.lastPathComponent)
        var bytes = 0, entries = 0
        do { try copyPlain(source, to: copy, bytes: &bytes, entries: &entries, atMost: atMost) }
        catch let refusal as FolderRefusal { throw refusal }
        catch { throw FolderRefusal.unreadable }
        var failure: NSError?
        var zipped: Data?
        NSFileCoordinator().coordinate(readingItemAt: copy, options: .forUploading, error: &failure) { zip in
            // the Mac removes its ZIP when this block ends
            zipped = KeptFile.bytes(of: zip, atMost: 2 * MessageAttachment.sizeLimit)     // the box then says it is too large
        }
        guard failure == nil, let zipped, !zipped.isEmpty else { throw FolderRefusal.unreadable }
        return zipped
    }

    /// A name that a skill's ZIP leaves out, as the hub does: a hidden name, `__MACOSX`, `__pycache__`.
    static func leftOut(_ part: some StringProtocol) -> Bool {
        part.hasPrefix(".") || part == "__MACOSX" || part == "__pycache__"
    }

    private static func copyPlain(_ from: URL, to: URL, bytes: inout Int, entries: inout Int, atMost: Int) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: to, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        for item in try manager.contentsOfDirectory(at: from, includingPropertiesForKeys: keys, options: []) {
            let name = item.lastPathComponent
            guard !leftOut(name) else { continue }
            let kind = try item.resourceValues(forKeys: Set(keys))
            guard kind.isSymbolicLink != true else { continue }
            entries += 1
            guard entries <= mostEntries else { throw FolderRefusal.tooLarge }
            if kind.isDirectory == true {
                try copyPlain(item, to: to.appendingPathComponent(name), bytes: &bytes, entries: &entries, atMost: atMost)
            } else if kind.isRegularFile == true {
                bytes += kind.fileSize ?? 0
                guard bytes <= atMost else { throw FolderRefusal.tooLarge }
                try manager.copyItem(at: item, to: to.appendingPathComponent(name))
            }
        }
    }

    // MARK: The central directory

    /// The bytes of a `SKILL.md` that are read for its front matter.
    static let frontMatterBytes = 65_536

    /// One entry of a ZIP's central directory: what the reading of its main file needs.
    struct Entry {
        let flags: Int
        let method: Int
        let packed: Int
        let size: Int
        /// Where its local header stands in the bytes (the directory's own offset, moved by bytes before the ZIP).
        let header: Int
    }

    /// The entry of the skill's `SKILL.md`, and the name of the top folder that it stands under (nil at the root), or
    /// nil for a ZIP that is no skill.
    static func main(in data: Data) -> (entry: Entry, top: String?)? {
        data.withUnsafeBytes { bytes -> (entry: Entry, top: String?)? in
            guard let names = directory(bytes) else { return nil }
            // the names that the hub keeps, each in its parts with no empty and no "." part
            var kept: [(parts: [ArraySlice<UInt8>], entry: Entry)] = []
            for (name, entry, mode) in names {
                // a name ends at its first zero byte, as Python's zipfile cuts it
                let raw = name.prefix { $0 != 0 }
                if raw.last == UInt8(ascii: "/") || mode & 0o170000 == 0o040000 { continue }      // a folder
                let parts = raw.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
                    .filter { $0 != [UInt8(ascii: ".")] }
                guard !parts.isEmpty else { continue }
                if parts.contains(where: { leftOut(String(decoding: $0, as: UTF8.self)) }) { continue }
                kept.append((parts, entry))
            }
            guard let first = kept.first?.parts.first else { return nil }
            let under = kept.allSatisfy { $0.parts.count > 1 && $0.parts[0] == first }
            let main = Array(mainFile.utf8)
            guard let found = kept.first(where: { Array($0.parts.dropFirst(under ? 1 : 0)) == [main[...]] }) else {
                return nil
            }
            return (found.entry, under ? String(decoding: first, as: UTF8.self) : nil)
        }
    }

    /// The names of a ZIP's entries, in the order of its central directory, or nil where this cannot read it.
    static func names(in data: Data) -> [String]? {
        data.withUnsafeBytes { directory($0)?.map { String(decoding: $0.name, as: UTF8.self) } }
    }

    /// Every entry of the central directory: its name's bytes, what its reading needs, and its Unix mode (0 where the
    /// ZIP keeps none). nil for a ZIP that this cannot read, or that has more than `mostEntries` entries.
    private static func directory(_ bytes: UnsafeRawBufferPointer) -> [(name: [UInt8], entry: Entry, mode: Int)]? {
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        let count = bytes.count
        guard count >= 22 else { return nil }
        // the end record: its signature nearest the end, within the longest comment that a ZIP can have
        var end = count - 22
        let first = max(0, count - 22 - 65_535)
        while end >= first, !(bytes[end] == 0x50 && bytes[end + 1] == 0x4B && bytes[end + 2] == 5 && bytes[end + 3] == 6) {
            end -= 1
        }
        guard end >= first else { return nil }
        let total = u16(end + 10), length = u32(end + 12), offset = u32(end + 16)
        // ZIP64 keeps its numbers elsewhere; a skill is far from needing it
        guard total != 0xFFFF, length != 0xFFFF_FFFF, offset != 0xFFFF_FFFF, total <= mostEntries else { return nil }
        // the directory stands right before the end record; bytes before the ZIP move every offset by as many
        let start = end - length, before = start - offset
        guard start >= 0, before >= 0 else { return nil }
        var entries: [(name: [UInt8], entry: Entry, mode: Int)] = []
        var at = start
        while at < end {
            guard at + 46 <= end, u32(at) == 0x0201_4B50 else { return nil }
            let named = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32)
            guard at + 46 + named + extra + comment <= end else { return nil }
            entries.append((Array(bytes[(at + 46)..<(at + 46 + named)]),
                            Entry(flags: u16(at + 8), method: u16(at + 10), packed: u32(at + 20), size: u32(at + 24),
                                  header: u32(at + 42) + before),
                            (u32(at + 38) >> 16) & 0xFFFF))
            guard entries.count <= mostEntries else { return nil }
            at += 46 + named + extra + comment
        }
        return entries
    }

    /// The first `frontMatterBytes` of an entry's file, as text: stored or deflated, not encrypted, from its local
    /// header. nil where this cannot read it.
    private static func text(of entry: Entry, in data: Data) -> String? {
        let bytes: Data? = data.withUnsafeBytes { bytes in
            func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
            let at = entry.header
            guard entry.flags & 1 == 0, at >= 0, at + 30 <= bytes.count,
                  bytes[at] == 0x50, bytes[at + 1] == 0x4B, bytes[at + 2] == 3, bytes[at + 3] == 4 else { return nil }
            let start = at + 30 + u16(at + 26) + u16(at + 28)
            guard entry.packed >= 0, start + entry.packed <= bytes.count else { return nil }
            return Data(bytes[start..<(start + entry.packed)])
        }
        guard let bytes else { return nil }
        switch entry.method {
        case 0: return String(decoding: bytes.prefix(frontMatterBytes), as: UTF8.self)
        case 8: return inflated(bytes).map { String(decoding: $0, as: UTF8.self) }
        default: return nil
        }
    }

    /// The first `frontMatterBytes` of raw DEFLATE (the `zlib` algorithm of Apple's Compression), never more: a small
    /// packed file can unpack to a very large one.
    private static func inflated(_ packed: Data) -> Data? {
        // the packed bytes in the pieces that the filter asks for, then nil at their end
        var at = packed.startIndex
        guard let filter = try? InputFilter<Data>(.decompress, using: .zlib, bufferCapacity: 65_536, readingFrom: { wanted in
            guard at < packed.endIndex else { return nil }
            let end = packed.index(at, offsetBy: min(wanted, packed.endIndex - at))
            defer { at = end }
            return Data(packed[at..<end])
        }) else { return nil }
        var out = Data()
        do {
            while out.count < frontMatterBytes, let more = try filter.readData(ofLength: frontMatterBytes - out.count),
                  !more.isEmpty {
                out.append(more)
            }
        } catch { return nil }
        return out
    }
}

/// **One skill of a message of his** (owner feature `message_skills`, `skills` of `POST /ui/messages`): a skill of the
/// agent's that he asks it to use, by its name, or a skill that he gives it with this message, by the number of its ZIP
/// on the hub. The request sends one key of each entry (`fields`); the hub's stored entry of a gift adds the skill's
/// name, which the badge of his message shows.
public enum MessageSkill: Codable, Hashable, Sendable {
    case use(String)
    /// The number of the ZIP (`POST /ui/attachments`), which the message does not also carry in `attachments`, and the
    /// skill's name as the hub stored it (nil in a request).
    case give(Int, name: String? = nil)

    /// The entry as the request sends it: exactly one key, as the hub asks.
    public var fields: [String: Any] {
        switch self {
        case .use(let name): ["use": name]
        case .give(let id, _): ["give": id]
        }
    }

    /// The number of a gift's ZIP, or nil for a skill to use.
    public var given: Int? {
        if case .give(let id, _) = self { return id }
        return nil
    }

    private enum Keys: String, CodingKey { case use, give, name }

    public init(from decoder: Decoder) throws {
        let entry = try decoder.container(keyedBy: Keys.self)
        if let id = try? entry.decode(Int.self, forKey: .give) {
            self = .give(id, name: try? entry.decodeIfPresent(String.self, forKey: .name))
        } else {
            self = .use(try entry.decode(String.self, forKey: .use))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var entry = encoder.container(keyedBy: Keys.self)
        switch self {
        case .use(let name): try entry.encode(name, forKey: .use)
        case .give(let id, let name):
            try entry.encode(id, forKey: .give)
            try entry.encodeIfPresent(name, forKey: .name)
        }
    }
}

/// **The skills of one message of his, as the hub gives them** (`messages[].skills`). Never strict: an entry of another
/// shape is none, a value that is no list is an empty list, and the message and the rest of the reading stay.
public struct MessageSkills: Decodable, Equatable, Sendable {
    public let entries: [MessageSkill]

    public init(_ entries: [MessageSkill]) { self.entries = entries }

    public init(from decoder: Decoder) throws {
        entries = ((try? decoder.singleValueContainer().decode([Entry].self)) ?? []).compactMap(\.skill)
    }

    /// The names of the skills that he gave with it, in his order: the badge of each stands over his words.
    public var given: [String] {
        entries.compactMap { entry in
            guard case .give(_, let name?) = entry, !name.isEmpty else { return nil }
            return name
        }
    }

    private struct Entry: Decodable {
        let skill: MessageSkill?
        init(from decoder: Decoder) throws { skill = try? MessageSkill(from: decoder) }
    }
}
