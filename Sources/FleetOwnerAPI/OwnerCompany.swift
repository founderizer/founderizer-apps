import CoreGraphics
import Foundation
import ImageIO
import zlib

/// **The company's logo, as the hub keeps it** (Founderizer for Teams; owner API 1.349, decisions D87, D88, D90 and
/// D115): a PNG of 64 x 64 pixels in at most 12,288 bytes, which a member's app shows over the company's agents from a
/// later release. One rule makes it, for the tool `save_company` of this program and for the rows of the app's
/// Settings, the same as `owner_mcp.py`'s (`company_logo`, which reads the picture with macOS's sips):
/// - A whole PNG of that size goes as it is, with its colour profile, which the hub keeps (D115), unless the caller
///   asks for `remake`: whole by a walk of its chunks (`asIs`). Any other PNG of that size is drawn again.
/// - A PDF, a PostScript file and a text that starts with `<` (an SVG) are no picture (`notAPictureHere`): ImageIO
///   reads none of them, and sips reads a PDF and an SVG, so both programs refuse them before they read them.
/// - A picture of more than `pixelsMost` pixels is refused before it is decoded.
/// - Any other picture is fitted whole into the square (`fittedSize`), centred, on a clear ground (a small one is
///   scaled up, and none is cut), turned as its EXIF says, in sRGB, with the chunks IHDR, sRGB, IDAT and IEND alone (no
///   profile, text, EXIF or time: this file writes the PNG, not ImageIO, which adds them), and takes fewer colour bits,
///   step by step, until it fits. The deflate and the checksums are the system's libz, at level 9 as Python's zlib, so
///   the same pixels give the same bytes in both programs; the pixels are scaled by CoreGraphics here and by sips
///   there, and can differ.
/// `owner_mcp.py`'s table carries the numbers and the words of a refusal (`COMPANY_LOGO`), which the tests hold to
/// these.
public enum CompanyLogo {
    /// Pixels of each side of the logo (`teams_company.PNG_SIDE`).
    public static let side = 64
    /// Bytes of the logo's PNG at most (`teams_company.PNG_MOST`).
    public static let most = 12_288
    /// Pixels of a picture at most, read before it is decoded (`owner_mcp.py` LOGO_PIXELS_MOST): a few MB of PNG can
    /// take gigabytes to decode.
    public static let pixelsMost = 100_000_000
    /// Bytes of a picture file that is read at most, as an attachment's (`owner_mcp.py` ATTACH_MAX).
    public static let fileMost = 25 * 1024 * 1024

    /// Why no logo came from a picture.
    public enum Failure: Error, Sendable, Equatable {
        /// The system cannot read the bytes as a picture: a text, a key, a document, a kind that it does not know.
        case notAPicture
        /// A picture of more than `pixelsMost` pixels, refused before it is decoded.
        case tooManyPixels
        /// The PNG of 64 x 64 is larger than `most` bytes also at one colour bit a sample: a very busy picture.
        case tooLarge
        /// A file of more than `fileMost` bytes, refused before it is read (`png(from: URL)` only).
        case fileTooLarge(Int)
        /// The file could not be read (`png(from: URL)` only), in the system's words.
        case unreadable(String)
    }

    /// The logo's PNG from a picture's bytes, for a view that has them (a drop, the pasteboard). `remake`: draw the
    /// picture again also when it is a PNG of 64 x 64 already, so that the logo is always sRGB with no profile (the
    /// owner's Mac writes it so, decision D115); the tool `save_company` sends such a PNG as it is.
    public static func png(from data: Data, remake: Bool = false) throws -> Data {
        try made(from: data, remake: remake).png
    }

    /// The logo's PNG from a picture file, for a view that has its URL (the file panel of "Choose…"), with `remake` as
    /// `png(from: Data, remake:)` takes it. A file of more than `fileMost` bytes is refused before it is read: the
    /// file itself, also when the URL is a link to it (a link's own size is a few bytes).
    public static func png(from url: URL, remake: Bool = false) throws -> Data {
        let file = url.resolvingSymlinksInPath()
        let data: Data
        do {
            if let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > fileMost {
                throw Failure.fileTooLarge(size)
            }
            data = try Data(contentsOf: file, options: .mappedIfSafe)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        return try png(from: data, remake: remake)
    }

    /// A logo and the words of what was done to the picture, which the tool gives back.
    struct Made: Sendable {
        let png: Data
        let said: String
    }

    // The words of `save_company`, as `owner_mcp.py` writes them. They name no path of this Mac.
    static let nothing = "Give name, logo_file or both: a field left out stays as it is, so nothing was sent."
    static let logoFile = "logo_file must be the path of a picture file on this Mac, or null to remove the logo."
    static let notAFile = "logo_file is not a file on this Mac."
    static let notAPictureWords = "logo_file is not a picture that this Mac can read: give a PNG, a JPEG or another "
        + "picture file. Nothing was sent."
    static let tooManyPixelsWords = "logo_file is a picture of more than 100 million pixels, too large to read here: "
        + "give a smaller picture. Nothing was sent."
    static let tooLargeWords = "logo_file does not fit in 12,288 bytes as a PNG of 64 x 64 px, also with the fewest "
        + "colours: give a simpler picture. Nothing was sent."
    static let asIsWords = "The picture went as it was: a PNG of 64 x 64 px."
    static let madeWords = "The picture went as a PNG of 64 x 64 px"
    static let fittedWords = "fitted whole on a clear ground"
    static let fewerWords = "with fewer colours"

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let critical = ["IHDR", "PLTE", "IDAT", "IEND"]

    /// `owner_mcp.py`'s `logo_as_is`: **a whole PNG of 64 x 64 in at most `most` bytes, which the hub takes as it is**:
    /// the signature, IHDR first with that size, each chunk whole with its CRC, no critical chunk but those of
    /// `critical`, not both sRGB and iCCP, and IEND last with no byte after it. Any other file is drawn again.
    static func asIs(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        let head = signature + [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, UInt8(side), 0, 0, 0, UInt8(side)]
        guard bytes.count <= most, bytes.count >= 24, Array(bytes[0..<24]) == head else { return false }
        var at = signature.count, kinds: [String] = []
        while at < bytes.count, kinds.last != "IEND" {
            guard at + 12 <= bytes.count else { return false }
            let length = bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) }
            let end = at + 12 + length
            let kind = bytes[(at + 4)..<(at + 8)]
            guard end <= bytes.count, kind.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) })
            else { return false }
            let said = bytes[(end - 4)..<end].reduce(UInt32(0), { $0 << 8 | UInt32($1) })
            guard checksum(Array(bytes[(at + 4)..<(end - 4)])) == said else { return false }
            kinds.append(String(decoding: kind, as: UTF8.self))
            at = end
        }
        return at == bytes.count && kinds.last == "IEND" && !(kinds.contains("sRGB") && kinds.contains("iCCP"))
            && kinds.allSatisfy { $0.first?.isUppercase != true || critical.contains($0) }
    }

    /// `owner_mcp.py`'s `not_a_picture_here`: a PDF (`%PDF-` in its first 1,024 bytes), a PostScript or EPS file
    /// (`%!`), or a text that starts with `<` after white space or a UTF-8 BOM (an SVG, an XML or HTML file).
    static func notAPictureHere(_ data: Data) -> Bool {
        let first = [UInt8](data.prefix(1024))
        let pdf = Array("%PDF-".utf8)
        if first.count >= pdf.count,
           (0...(first.count - pdf.count)).contains(where: { Array(first[$0..<($0 + pdf.count)]) == pdf }) {
            return true
        }
        if first.starts(with: Array("%!".utf8)) { return true }
        var text = first[...]
        if text.starts(with: [0xEF, 0xBB, 0xBF]) { text = text.dropFirst(3) }
        return text.drop { [0x20, 0x09, 0x0D, 0x0A].contains($0) }.first == UInt8(ascii: "<")
    }

    /// `owner_mcp.py`'s `fitted_size`: **the frame of a picture in the square**, the longer side `side`, the shorter in
    /// proportion, rounded half up in whole numbers, and at least 1 pixel.
    static func fittedSize(_ width: Int, _ height: Int) -> (width: Int, height: Int) {
        let long = max(width, height), short = min(width, height)
        let fitted = max(1, (2 * short * side + long) / (2 * long))
        return width >= height ? (side, fitted) : (fitted, side)
    }

    /// The logo of these bytes: as they are for a whole PNG that is the logo already (unless `remake`), else drawn by
    /// the one rule. Nothing of bytes that the system cannot read as a picture goes anywhere: `Failure.notAPicture`.
    static func made(from data: Data, remake: Bool = false) throws -> Made {
        if !remake, asIs(data) { return Made(png: data, said: asIsWords) }
        if notAPictureHere(data) { throw Failure.notAPicture }
        let reading = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, reading),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw Failure.notAPicture }
        // Before any decode: the properties come from the file's header.
        if width.multipliedReportingOverflow(by: height).overflow || width * height > pixelsMost {
            throw Failure.tooManyPixels
        }
        // The frame of the picture as it is shown: an EXIF orientation of 5 to 8 turns it a quarter.
        let turned = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        let fitted = turned ? fittedSize(height, width) : fittedSize(width, height)
        // turned as its EXIF says, and never larger than the square (a small one is scaled up when drawn)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), side)] as CFDictionary),
              image.width > 0, image.height > 0,
              let canvas = draw(image, fitted.width, fitted.height)
        else { throw Failure.notAPicture }
        for bits in stride(from: 8, through: 1, by: -1) {
            let png = try pngOf(fewerBits(canvas, bits))
            if png.count <= most {
                var said = [madeWords]
                if fitted.width != fitted.height { said.append(fittedWords) }
                if bits < 8 { said.append(fewerWords) }
                return Made(png: png, said: said.joined(separator: ", ") + ".")
            }
        }
        throw Failure.tooLarge
    }

    /// The picture drawn `width` x `height` on a clear square of `side`, centred (left and top rounded down), in sRGB:
    /// its RGBA samples from the top row, not premultiplied, as a PNG holds them.
    static func draw(_ image: CGImage, _ width: Int, _ height: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        let left = (side - width) / 2, top = (side - height) / 2
        context.draw(image, in: CGRect(x: left, y: side - top - height, width: width, height: height))
        guard let memory = context.data else { return nil }
        var pixels = [UInt8](UnsafeRawBufferPointer(start: memory, count: side * side * 4))
        for at in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[at + 3])
            for sample in at..<(at + 3) {
                pixels[sample] = alpha == 0 ? 0 : UInt8(min(255, (Int(pixels[sample]) * 255 + alpha / 2) / alpha))
            }
        }
        return pixels
    }

    /// `owner_mcp.py`'s `fewer_bits`: each sample at 2^bits levels from 0 to 255, 0 and 255 among them (8 bits: as it
    /// is), and each pixel that is then wholly clear made clear black, so that no colour stays hidden in it.
    static func fewerBits(_ canvas: [UInt8], _ bits: Int) -> [UInt8] {
        let top = (1 << bits) - 1
        let table = (0..<256).map { UInt8((($0 * top + 127) / 255 * 255 + top / 2) / top) }
        var out = canvas.map { table[Int($0)] }
        for alpha in stride(from: 3, to: out.count, by: 4) where out[alpha] == 0 {
            out[alpha - 3] = 0
            out[alpha - 2] = 0
            out[alpha - 1] = 0
        }
        return out
    }

    /// `owner_mcp.py`'s `png_of`: a PNG of `side` x `side` RGBA pixels of 8 bits in sRGB, with IHDR, sRGB (perceptual),
    /// one IDAT and IEND and no other chunk. Each row takes the filter whose bytes, read as signed, have the least sum
    /// of sizes, the first one on a tie.
    static func pngOf(_ rgba: [UInt8]) throws -> Data {
        let stride = side * 4
        var raw: [UInt8] = []
        raw.reserveCapacity(side * (stride + 1))
        var prior = [UInt8](repeating: 0, count: stride)
        for y in 0..<side {
            let row = Array(rgba[(y * stride)..<((y + 1) * stride)])
            var made = [[UInt8]](repeating: [UInt8](repeating: 0, count: stride), count: 5)
            for i in 0..<stride {
                let a = i >= 4 ? Int(row[i - 4]) : 0, b = Int(prior[i]), c = i >= 4 ? Int(prior[i - 4]) : 0
                let r = Int(row[i])
                made[0][i] = row[i]
                made[1][i] = UInt8((r - a) & 255)
                made[2][i] = UInt8((r - b) & 255)
                made[3][i] = UInt8((r - (a + b) / 2) & 255)
                made[4][i] = UInt8((r - paeth(a, b, c)) & 255)
            }
            var kind = 0, least = Int.max
            for (number, bytes) in made.enumerated() {
                let sum = bytes.reduce(0) { $0 + ($1 < 128 ? Int($1) : 256 - Int($1)) }
                if sum < least { (kind, least) = (number, sum) }
            }
            raw.append(UInt8(kind))
            raw.append(contentsOf: made[kind])
            prior = row
        }
        var size = compressBound(uLong(raw.count))
        var idat = [UInt8](repeating: 0, count: Int(size))
        guard compress2(&idat, &size, raw, uLong(raw.count), 9) == Z_OK else { throw Failure.notAPicture }
        var png = Data(signature)
        png.append(chunk("IHDR", bigEndian(UInt32(side)) + bigEndian(UInt32(side)) + [8, 6, 0, 0, 0]))
        png.append(chunk("sRGB", [0]))
        png.append(chunk("IDAT", Array(idat[0..<Int(size)])))
        png.append(chunk("IEND", []))
        return png
    }

    /// The Paeth predictor of PNG's filter 4.
    static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
    }

    static func chunk(_ kind: String, _ body: [UInt8]) -> Data {
        let named = Array(kind.utf8) + body
        return Data(bigEndian(UInt32(body.count)) + named + bigEndian(checksum(named)))
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 255), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]
    }

    /// The CRC-32 of a chunk's name and data, by the system's libz.
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        UInt32(crc32(0, bytes, uInt(bytes.count)))
    }
}

extension OwnerTools {
    /// `save_company` (`owner_mcp.py`'s `save_company`): `POST /ui/company` with the name, the logo's PNG, or both; a
    /// field left out stays as it is, and null removes it. The answer: the hub's two values, and with a file, in
    /// words, what went.
    func saveCompany(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        guard args["name"] != nil || args["logo_file"] != nil else { throw OwnerRefusal(CompanyLogo.nothing) }
        var body: [String: JSONValue] = [:]
        var said: String?
        if let name = args["name"] { body["name"] = name }
        if let given = args["logo_file"] {
            if given.isNull {
                body["png"] = .null
            } else {
                let made = try companyLogo(given)
                body["png"] = .string(made.png.base64EncodedString())
                said = made.said
            }
        }
        let answer = try hub.command("/ui/company", body, "the company's name and logo", requestID: args["request_id"])
        var result: [String: JSONValue] = ["name": answer?["name"] ?? .null, "logo": answer?["logo"] ?? .null]
        if let said { result["picture"] = .string(said) }
        return .object(result)
    }

    /// `owner_mcp.py`'s `company_logo`: the file read here, and the logo made of it, before any byte leaves.
    func companyLogo(_ given: JSONValue) throws -> CompanyLogo.Made {
        guard case .string(let text) = given, !PyText.strip(text).isEmpty else {
            throw OwnerRefusal(CompanyLogo.logoFile)
        }
        let place = try localPlace(text)                // a NUL first, before "~" is expanded
        guard LocalFile.isFile(place) else { throw OwnerRefusal(CompanyLogo.notAFile) }
        let most = CompanyLogo.fileMost
        let tooLarge = { (size: Int) in
            OwnerRefusal("logo_file is \(size) bytes; a picture for the logo is at most \(most / (1024 * 1024)) MiB.")
        }
        let data: Data
        do {
            let size = try LocalFile.size(place)
            if size > most { throw tooLarge(size) }
            data = try LocalFile.read(place)
        } catch let failure as LocalFile.Failure {
            throw OwnerRefusal("logo_file could not be read on this Mac: \(failure.reason).")
        }
        if data.count > most { throw tooLarge(data.count) }
        do {
            return try CompanyLogo.made(from: data)
        } catch CompanyLogo.Failure.tooLarge {
            throw OwnerRefusal(CompanyLogo.tooLargeWords)
        } catch CompanyLogo.Failure.tooManyPixels {
            throw OwnerRefusal(CompanyLogo.tooManyPixelsWords)
        } catch is CompanyLogo.Failure {
            throw OwnerRefusal(CompanyLogo.notAPictureWords)
        }
    }
}
