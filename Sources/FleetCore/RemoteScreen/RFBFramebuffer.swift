import Compression
import Foundation

/// **The agent's screen as the take-over card holds it**: 4 bytes a pixel in the order blue, green, red, unused, which
/// is the pixel format that the session asks every server for (`RFBSession.pixelFormat`) and a Core Graphics image reads
/// as 32-bit little-endian with the first byte skipped.
public struct RFBFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: Data
}

/// What a server's rectangle can be: this file decodes these four encodings, and the session asks for no other one
/// (besides the screen's new size).
enum RFBEncoding {
    static let raw: Int32 = 0
    static let copyRect: Int32 = 1
    static let hextile: Int32 = 5
    static let zrle: Int32 = 16
    static let desktopSize: Int32 = -223
}

enum RFBDecodeError: Error, Equatable {
    case outside
    case badData(String)
}

/// The pixels, and the decoders that write a rectangle into them. A class, because the session's actor holds it and
/// Hextile's decoder reads the server's bytes while it writes.
final class RFBFramebuffer {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: [UInt8]
    /// ZRLE's one zlib stream, which runs from the first ZRLE rectangle to the session's end (RFC 6143 7.7.6).
    private var inflater: RFBInflater?

    /// The largest screen that a server can name: a 6K display is 6016 by 3384.
    static let largest = 8192

    static func fits(width: Int, height: Int) -> Bool {
        (1...largest).contains(width) && (1...largest).contains(height)
    }

    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    var frame: RFBFrame { RFBFrame(width: width, height: height, pixels: Data(pixels)) }

    /// A new size of the screen (the server's DesktopSize): black pixels; ZRLE's stream goes on.
    func resize(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    func contains(x: Int, y: Int, width w: Int, height h: Int) -> Bool {
        x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height
    }

    /// Raw: `w·h` pixels of 4 bytes, row by row.
    func raw(x: Int, y: Int, width w: Int, height h: Int, bytes: [UInt8]) throws {
        guard contains(x: x, y: y, width: w, height: h) else { throw RFBDecodeError.outside }
        guard bytes.count == w * h * 4 else { throw RFBDecodeError.badData("raw size") }
        for row in 0..<h {
            let from = row * w * 4, to = ((y + row) * width + x) * 4
            pixels.replaceSubrange(to..<(to + w * 4), with: bytes[from..<(from + w * 4)])
        }
    }

    /// CopyRect: the pixels of a rectangle of the screen to another place of it.
    func copy(x: Int, y: Int, width w: Int, height h: Int, fromX: Int, fromY: Int) throws {
        guard contains(x: x, y: y, width: w, height: h), contains(x: fromX, y: fromY, width: w, height: h) else {
            throw RFBDecodeError.outside
        }
        // only the source rectangle is copied first, so a source that overlaps its place is read before it is written
        var source = [UInt8]()
        source.reserveCapacity(w * h * 4)
        for row in 0..<h {
            let from = ((fromY + row) * width + fromX) * 4
            source.append(contentsOf: pixels[from..<(from + w * 4)])
        }
        for row in 0..<h {
            let to = ((y + row) * width + x) * 4
            pixels.replaceSubrange(to..<(to + w * 4), with: source[(row * w * 4)..<((row + 1) * w * 4)])
        }
    }

    /// One colour over a rectangle that is inside the screen.
    func fill(x: Int, y: Int, width w: Int, height h: Int, pixel: [UInt8]) {
        for row in y..<(y + h) {
            var at = (row * width + x) * 4
            for _ in 0..<w {
                pixels[at] = pixel[0]; pixels[at + 1] = pixel[1]; pixels[at + 2] = pixel[2]; pixels[at + 3] = pixel[3]
                at += 4
            }
        }
    }

    /// ZRLE (RFC 6143 7.7.6): the rectangle's bytes of the session's zlib stream, in tiles of 64 by 64. A pixel is
    /// 3 bytes in it (CPIXEL: the session's 32-bit format of depth 24, its low 3 bytes).
    func zrle(x: Int, y: Int, width w: Int, height h: Int, compressed: [UInt8]) throws {
        guard contains(x: x, y: y, width: w, height: h) else { throw RFBDecodeError.outside }
        if inflater == nil { inflater = try RFBInflater() }
        guard let inflater else { throw RFBDecodeError.badData("zlib") }
        // a hard limit with room: a tile's palette form can be a little larger than its raw form
        let tiles = ((w + 63) / 64) * ((h + 63) / 64)
        var data = RFBBytes(try inflater.inflate(compressed, atMost: w * h * 4 + 64 * tiles + 1024))
        for tileY in stride(from: y, to: y + h, by: 64) {
            for tileX in stride(from: x, to: x + w, by: 64) {
                let tw = min(64, x + w - tileX), th = min(64, y + h - tileY)
                try zrleTile(x: tileX, y: tileY, width: tw, height: th, data: &data)
            }
        }
    }

    private func zrleTile(x: Int, y: Int, width w: Int, height h: Int, data: inout RFBBytes) throws {
        let kind = Int(try data.take(1)[0])
        func cpixel() throws -> [UInt8] { let c = try data.take(3); return [c[0], c[1], c[2], 255] }
        func put(_ index: Int, _ pixel: [UInt8]) {
            let at = ((y + index / w) * width + x + index % w) * 4
            pixels[at] = pixel[0]; pixels[at + 1] = pixel[1]; pixels[at + 2] = pixel[2]; pixels[at + 3] = pixel[3]
        }
        func runLength() throws -> Int {
            var length = 1
            while true {
                let byte = Int(try data.take(1)[0])
                length += byte
                if byte != 255 { return length }
            }
        }
        switch kind {
        case 0:
            for index in 0..<(w * h) { put(index, try cpixel()) }
        case 1:
            fill(x: x, y: y, width: w, height: h, pixel: try cpixel())
        case 2...16:
            let palette = try (0..<kind).map { _ in try cpixel() }
            let bits = kind == 2 ? 1 : kind <= 4 ? 2 : 4
            let perByte = 8 / bits, mask = (1 << bits) - 1
            for row in 0..<h {
                let rowBytes = try data.take((w + perByte - 1) / perByte)
                for column in 0..<w {
                    let byte = Int(rowBytes[column / perByte])
                    let shift = 8 - bits * (column % perByte + 1)
                    let index = (byte >> shift) & mask
                    guard index < palette.count else { throw RFBDecodeError.badData("zrle palette index") }
                    put(row * w + column, palette[index])
                }
            }
        case 128:
            var index = 0
            while index < w * h {
                let pixel = try cpixel(), length = try runLength()
                guard index + length <= w * h else { throw RFBDecodeError.badData("zrle run") }
                for at in index..<(index + length) { put(at, pixel) }
                index += length
            }
        case 130...255:
            let palette = try (0..<(kind - 128)).map { _ in try cpixel() }
            var index = 0
            while index < w * h {
                let byte = Int(try data.take(1)[0])
                let entry = byte & 127
                guard entry < palette.count else { throw RFBDecodeError.badData("zrle palette index") }
                let length = byte & 128 != 0 ? try runLength() : 1
                guard index + length <= w * h else { throw RFBDecodeError.badData("zrle run") }
                for at in index..<(index + length) { put(at, palette[entry]) }
                index += length
            }
        default:
            throw RFBDecodeError.badData("zrle subencoding \(kind)")
        }
    }
}

/// Bytes read from the front.
struct RFBBytes {
    private let bytes: [UInt8]
    private var at = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// The next `count` bytes, indexed from 0.
    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, at + count <= bytes.count else { throw RFBDecodeError.badData("short") }
        defer { at += count }
        return Array(bytes[at..<(at + count)])
    }
}

/// **ZRLE's zlib stream**, which goes on from one rectangle to the next. Apple's Compression framework reads DEFLATE
/// without zlib's two-byte header, so the stream's first two bytes are checked and dropped. Each rectangle ends with a
/// flush of the server's, so all its bytes come out at once.
final class RFBInflater {
    private let stream: UnsafeMutablePointer<compression_stream>
    private var headerLeft = 2
    private var ended = false

    init() throws {
        stream = .allocate(capacity: 1)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            throw RFBDecodeError.badData("zlib")
        }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
    }

    /// The rectangle's bytes out of the stream; more than `atMost` is a fault of the server's (a small rectangle of
    /// zeros can inflate to gigabytes).
    func inflate(_ input: [UInt8], atMost: Int) throws -> [UInt8] {
        var input = input[...]
        if headerLeft > 0 {
            let header = input.prefix(headerLeft)
            // the first byte names DEFLATE (low 4 bits 8), and the pair is a multiple of 31 (RFC 1950)
            if headerLeft == 2, let first = header.first, first & 0x0F != 8 { throw RFBDecodeError.badData("zlib header") }
            headerLeft -= header.count
            input = input.dropFirst(header.count)
        }
        guard !ended else {
            if input.isEmpty { return [] }
            throw RFBDecodeError.badData("zlib ended")
        }
        var output: [UInt8] = []
        let chunk = 1 << 16
        var buffer = [UInt8](repeating: 0, count: chunk)
        try Array(input).withUnsafeBufferPointer { source in
            stream.pointee.src_ptr = source.baseAddress ?? UnsafePointer(bitPattern: 1)!
            stream.pointee.src_size = source.count
            repeat {
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { target in
                    stream.pointee.dst_ptr = target.baseAddress!
                    stream.pointee.dst_size = chunk
                    return compression_stream_process(stream, 0)
                }
                guard status != COMPRESSION_STATUS_ERROR else { throw RFBDecodeError.badData("zlib data") }
                output.append(contentsOf: buffer[0..<(chunk - stream.pointee.dst_size)])
                guard output.count <= atMost else { throw RFBDecodeError.badData("zlib size") }
                if status == COMPRESSION_STATUS_END { ended = true; break }
            } while stream.pointee.src_size > 0 || stream.pointee.dst_size == 0
        }
        return output
    }
}
