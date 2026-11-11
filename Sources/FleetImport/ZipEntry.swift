import Foundation

/// The bytes of a file that the import reads, at an offset: a whole file in memory, or an open file that is read in
/// parts, so that a large export with attachments is never read whole.
protocol ExportBytes {
    var size: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
}

extension Data: ExportBytes {
    var size: UInt64 { UInt64(count) }
    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset <= UInt64(self.count), UInt64(count) <= UInt64(self.count) - offset else { throw ZipEntry.Failure.damaged }
        let start = startIndex + Int(offset)
        return subdata(in: start ..< start + count)
    }
}

/// One member of a zip file (a 1Password `.1pux` export is one), read with no program and no file of its own: the
/// central directory names it, its local header says where its data starts, and its data is stored or deflated. A zip
/// that is encrypted, split, or in the ZIP64 form is refused.
enum ZipEntry {
    enum Failure: Error, Equatable { case damaged, missing, tooLarge }

    static func read(_ name: String, from file: some ExportBytes, limit: Int) throws -> Data {
        let size = file.size
        guard size >= 22 else { throw Failure.damaged }
        let tail = Int(min(size, 65_557))
        let end = try file.read(at: size - UInt64(tail), count: tail)
        guard let eocd = (0 ... tail - 22).reversed().first(where: { end.u32($0) == 0x0605_4b50 }) else { throw Failure.damaged }
        let entries = Int(end.u16(eocd + 10)), directorySize = Int(end.u32(eocd + 12)), directoryOffset = UInt64(end.u32(eocd + 16))
        guard end.u16(eocd + 4) == 0, end.u16(eocd + 6) == 0, entries != 0xFFFF, directoryOffset != 0xFFFF_FFFF,
              directorySize <= 16_777_216, directoryOffset + UInt64(directorySize) <= size else { throw Failure.damaged }
        let directory = try file.read(at: directoryOffset, count: directorySize)
        var at = 0
        for _ in 0 ..< entries {
            guard at + 46 <= directory.count, directory.u32(at) == 0x0201_4b50 else { throw Failure.damaged }
            let flags = directory.u16(at + 8), method = directory.u16(at + 10), crc = directory.u32(at + 16)
            let packed = Int(directory.u32(at + 20)), unpacked = Int(directory.u32(at + 24))
            let nameLength = Int(directory.u16(at + 28)), extra = Int(directory.u16(at + 30)), comment = Int(directory.u16(at + 32))
            let local = UInt64(directory.u32(at + 42))
            guard at + 46 + nameLength <= directory.count else { throw Failure.damaged }
            let entryName = String(decoding: directory[(directory.startIndex + at + 46) ..< (directory.startIndex + at + 46 + nameLength)],
                                   as: UTF8.self)
            at += 46 + nameLength + extra + comment
            guard entryName == name else { continue }
            guard flags & 0x1 == 0, packed != 0xFFFF_FFFF, unpacked != 0xFFFF_FFFF, [0, 8].contains(method) else { throw Failure.damaged }
            guard unpacked <= limit, packed <= limit else { throw Failure.tooLarge }
            let header = try file.read(at: local, count: 30)
            guard header.u32(0) == 0x0403_4b50 else { throw Failure.damaged }
            let start = local + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
            guard start + UInt64(packed) <= size else { throw Failure.damaged }
            let stored = try file.read(at: start, count: packed)
            let data: Data
            if method == 0 {
                data = stored
            } else if unpacked == 0 {
                data = Data()
            } else {
                guard let inflated = try? (stored as NSData).decompressed(using: .zlib) as Data else { throw Failure.damaged }
                data = inflated
            }
            guard data.count == unpacked, CRC32.of(data) == crc else { throw Failure.damaged }
            return data
        }
        throw Failure.missing
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { n in
        (0 ..< 8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }
    static func of(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}

extension Data {
    func u16(_ at: Int) -> UInt16 { UInt16(self[startIndex + at]) | UInt16(self[startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
}
