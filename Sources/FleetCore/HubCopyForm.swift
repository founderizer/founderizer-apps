import Compression
import Foundation

/// **The one form of a hub's copy**, as the owner tools' `take_backup` checks it (FleetOwnerAPI's `CopyShape`, which is
/// `owner_mcp.py`'s `copy_fault`): a copy of the same code, because FleetOwnerAPI does not take FleetCore. The app's own
/// Save copy keeps a hub's copy only in this form (`OwnerAccess.checkHubForm`, before the key's step): every member is named by the directory, at its
/// place, one after the other from byte 0, deflated to its exact end, with nothing before, between or after, so no reader
/// of a copy (ditto, unzip, bsdtar, zipfile) finds a member that this check did not see, and none of them is the access
/// key (the validator's read of the restore branch, 25 November 2026). Change the two together.
///
/// **Names by what is unsafe, not by a list** (the validator's M1 of 26 November 2026): the hub releases before the app,
/// so a hub may write a member that this app does not know (as `vault/central.json` once was), and a list of names would
/// make every Mac of an older app refuse every copy until it updates. One rule in the three copies of this check
/// (`owner_mcp.py`'s `copy_fault`, FleetOwnerAPI's `CopyShape`, this one; the Setup and Door areas, 26 November 2026):
/// a name whose last part (split at "/" and "\", trailing dots dropped) is owner-access.key or owner-access.pub, in
/// any ASCII case and at any depth, is refused as the key's (lifecycle.COPY_KEY_NAMES: a hub writes no file of either name); a name that is not
/// plain is refused: empty, a byte outside visible ASCII, a backslash or a colon, a leading slash, or a part that is
/// empty, "." or "..". Any other name is kept, once.
enum HubCopyForm {
    /// `owner_mcp.py`'s ACCESS_MEMBER, and lifecycle.COPY_KEY_NAMES.
    static let accessMember = "owner-access.key"
    static let keyNames: Set<[UInt8]> = [Array("owner-access.key".utf8), Array("owner-access.pub".utf8)]
    static let entriesMost = 20_000
    static let directoryMost = 4 * 1024 * 1024
    static let unpackMost = 2048 * 1024 * 1024 + 2 * 1024 * 1024
    /// The last bytes of a member that go in one at a time (`inflatesWhole`).
    static let tailBytes = 64
    static let withKey = "The hub's copy holds a member named owner-access.key or owner-access.pub, which no hub writes: "
        + "only the Founderizer app puts the fleet's access key into a copy, its own. So nothing was kept, and the hub was "
        + "not told that the copy is kept."
    static let notHubs = "The hub's copy is not a copy in the form that a hub writes (one zip with fleet.json, RESTORE.md "
        + "and fleet.sqlite3, each member once and under a plain name), so nothing was kept, and the hub was not told that "
        + "the copy is kept."

    /// nil for a file in the one form of a hub's copy, else the words of the refusal.
    static func fault(_ path: String) -> String? {
        guard !path.unicodeScalars.contains("\u{0}") else { return notHubs }
        let handle = open(path, O_RDONLY | O_CLOEXEC)
        guard handle >= 0 else { return notHubs }
        defer { close(handle) }
        var info = stat()
        guard fstat(handle, &info) == 0 else { return notHubs }
        let size = Int(info.st_size)
        func read(_ offset: Int, _ count: Int) -> [UInt8]? {
            guard offset >= 0, count >= 0, count <= size, offset <= size - count else { return nil }
            var bytes = [UInt8](repeating: 0, count: count), done = 0
            while done < count {
                let got = bytes.withUnsafeMutableBytes { pread(handle, $0.baseAddress! + done, count - done, off_t(offset + done)) }
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { return nil }
                done += got
            }
            return bytes
        }
        func number(_ bytes: [UInt8], _ at: Int, _ width: Int) -> Int {
            (0..<width).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        guard size >= 22, let end = read(size - 22, 22) else { return notHubs }
        if size >= 42, let locator = read(size - 42, 4), locator == [0x50, 0x4b, 0x06, 0x07] { return notHubs }
        guard Array(end[0..<4]) == [0x50, 0x4b, 0x05, 0x06] else { return notHubs }
        let disk = number(end, 4, 2), first = number(end, 6, 2), here = number(end, 8, 2), count = number(end, 10, 2)
        let length = number(end, 12, 4), start = number(end, 16, 4), comment = number(end, 20, 2)
        guard disk == 0, first == 0, comment == 0, here == count, count <= entriesMost, length <= directoryMost,
              start + length == size - 22, let directory = read(start, length) else { return notHubs }
        var raws: [[UInt8]] = [], streams: [(at: Int, packed: Int, whole: Int, check: Int)] = [], at = 0, local = 0
        for _ in 0..<count {
            guard at + 46 <= length, Array(directory[at..<(at + 4)]) == [0x50, 0x4b, 0x01, 0x02] else { return notHubs }
            let flags = number(directory, at + 8, 2), method = number(directory, at + 10, 2)
            let check = number(directory, at + 16, 4), packed = number(directory, at + 20, 4)
            let whole = number(directory, at + 24, 4), nameSize = number(directory, at + 28, 2)
            let extra = number(directory, at + 30, 2), note = number(directory, at + 32, 2)
            let diskStart = number(directory, at + 34, 2), offset = number(directory, at + 42, 4)
            // its mode: zipfile writes rw------- and no kind of file (0o600 << 16); a link or a folder is no hub's
            let mode = number(directory, at + 38, 4), kind = (mode >> 16) & 0o170000
            guard flags & 9 == 0, extra == 0, note == 0, diskStart == 0, kind == 0 || kind == 0o100000,
                  mode & 0xFFFF == 0, offset == local, at + 46 + nameSize <= length else { return notHubs }
            let name = Array(directory[(at + 46)..<(at + 46 + nameSize)])
            // The local head: the same member, where the directory says, one after the other up to the directory.
            guard let head = read(offset, 30 + nameSize), Array(head[0..<4]) == [0x50, 0x4b, 0x03, 0x04], method == 8,
                  number(head, 6, 2) == flags, number(head, 8, 2) == method, number(head, 14, 4) == check,
                  number(head, 18, 4) == packed, number(head, 22, 4) == whole, number(head, 26, 2) == nameSize,
                  number(head, 28, 2) == 0, Array(head[30...]) == name
            else { return notHubs }
            raws.append(name)
            streams.append((offset + 30 + nameSize, packed, whole, check))
            at += 46 + nameSize
            local = offset + 30 + nameSize + packed
        }
        // what a restore unpacks, which bounds the inflating below too
        guard at == length, local == start, streams.reduce(0, { $0 + $1.whole }) <= unpackMost else { return notHubs }
        for raw in raws {
            var last = raw.split(omittingEmptySubsequences: false) { $0 == 0x2f || $0 == 0x5c }.last.map(Array.init) ?? raw
            // Windows drops a name's trailing dots when it writes the file, so "owner-access.key." lands as the key
            // (the Setup and Door areas, 26 November 2026)
            while last.last == 0x2e { last.removeLast() }
            if keyNames.contains(last.map({ (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 })) { return withKey }
        }
        let needed = Set(["fleet.json", "RESTORE.md", "fleet.sqlite3"].map { Array($0.utf8) })
        guard raws.allSatisfy(member), Set(raws).count == raws.count, needed.isSubset(of: Set(raws)) else { return notHubs }
        for stream in streams {
            guard inflatesWhole(handle, at: stream.at, packed: stream.packed, whole: stream.whole,
                                check: UInt32(stream.check)) else { return notHubs }
        }
        return nil
    }

    /// `owner_mcp.py`'s `inflates_whole`: whether the `packed` bytes at `at` are one deflate stream that ends with its
    /// last byte and gives `whole` bytes of this CRC-32, read in parts. A byte after the stream's end is room for a member
    /// that the directory does not name, which a reader of a stream to its end and then of the next member finds. Apple's
    /// decoder takes in the bytes after a stream's end that came in the same call as the end, and says nothing of them
    /// (measured on this Mac, 25 November 2026), so the last `tailBytes` go in one byte at a time: an end before the last
    /// byte is then an end with bytes left, and the parts before them go in whole. The decoder is called again while its
    /// last call made output (below), so its end comes at the stream's exact end and 64 bytes leave room: measured on
    /// 1,202 streams (zero runs of 16 and 64 MiB among them) with no wrong answer at 1, 8 or 64 bytes, and by Door's
    /// reader on 847 copies.
    static func inflatesWhole(_ handle: Int32, at: Int, packed: Int, whole: Int, check: UInt32) -> Bool {
        guard packed > 0 else { return false }          // no stream at all, as zlib finds no end in nothing
        let part = 1 << 20, tail = min(packed, tailBytes)
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { return false }
        defer { compression_stream_destroy(&stream) }
        var input = [UInt8](repeating: 0, count: part), output = [UInt8](repeating: 0, count: part)
        var read = 0, made = 0, crc: UInt32 = 0xFFFF_FFFF
        while true {
            let count = read < packed - tail ? min(part, packed - tail - read) : min(1, packed - read)
            var got = 0
            while got < count {
                let one = input.withUnsafeMutableBytes { pread(handle, $0.baseAddress! + got, count - got, off_t(at + read + got)) }
                if one < 0, errno == EINTR { continue }
                guard one > 0 else { return false }
                got += one
            }
            read += count
            let last = read == packed
            var status = COMPRESSION_STATUS_OK, left = 0, produced = 0
            input.withUnsafeBufferPointer { inBytes in
                stream.src_ptr = UnsafePointer(inBytes.baseAddress!)
                stream.src_size = count
                repeat {
                    output.withUnsafeMutableBufferPointer { outBytes in
                        stream.dst_ptr = outBytes.baseAddress!
                        stream.dst_size = part
                        status = compression_stream_process(&stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                        produced = part - stream.dst_size
                        made += produced
                        for byte in outBytes[0..<produced] { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
                    }
                // on while input is left or the last call made output: the decoder can say OK with its input used
                // up and output that it still holds (the Vault area's reader of 58ed16645: 16 MiB of zeros)
                } while status == COMPRESSION_STATUS_OK && made <= whole && (stream.src_size > 0 || produced > 0)
                left = stream.src_size
            }
            if status == COMPRESSION_STATUS_ERROR || made > whole { return false }
            if status == COMPRESSION_STATUS_END { return left == 0 && last && made == whole && ~crc == check }
            if last { return false }            // all of it read, and no end: a cut or broken stream
        }
    }

    /// The table of CRC-32 (the zip's check), one entry for each byte.
    static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
    }

    /// A plain name of a member: visible ASCII bytes with no backslash and no colon, no leading slash, and no part that
    /// is empty, "." or "..", so each reader of a copy writes it at the same place under the folder that it unpacks into.
    static func member(_ raw: [UInt8]) -> Bool {
        guard !raw.isEmpty, raw.first != 0x2f,
              raw.allSatisfy({ $0 > 0x20 && $0 < 0x7f && $0 != 0x5c && $0 != 0x3a }) else { return false }
        return raw.split(separator: 0x2f, omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && Array(part) != [0x2e] && Array(part) != [0x2e, 0x2e]
        }
    }
}
