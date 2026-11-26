import CoreGraphics
import Foundation
import ImageIO
import Testing
import zlib
@testable import FleetOwnerAPI

/// **The company's logo** (`CompanyLogo`, the tool `save_company`; Founderizer for Teams): one rule makes it from any
/// picture, for this program and for the app's Settings rows, and nothing of a file that is no picture leaves this Mac.
final class OwnerCompanyTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    /// A picture of `width` x `height`, each pixel `colour(x, y)` as RGBA from the top left, in sRGB.
    static func picture(_ width: Int, _ height: Int, _ colour: (Int, Int) -> [UInt8]) -> CGImage {
        let context = Self.context(width, height)
        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgba = colour(x, y), alpha = Int(rgba[3])
                for sample in 0..<3 { bytes[(y * width + x) * 4 + sample] = UInt8(Int(rgba[sample]) * alpha / 255) }
                bytes[(y * width + x) * 4 + 3] = rgba[3]
            }
        }
        return context.makeImage()!
    }

    /// A clear context of 8-bit RGBA in sRGB, its samples in that order from the top row.
    static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    }

    /// The picture as a file of the kind `type` ("public.png", "public.jpeg"), with an EXIF orientation when given.
    static func file(_ image: CGImage, _ type: String = "public.png", orientation: Int? = nil) -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)!
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// The RGBA samples of a PNG of 64 x 64 from the top left, as the system reads it, and its chunks' names.
    static func read(_ png: Data) throws -> (pixels: [UInt8], chunks: [String]) {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64 && image.height == 64)
        let context = Self.context(64, 64)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let pixels = [UInt8](UnsafeRawBufferPointer(start: context.data, count: 64 * 64 * 4))
        var chunks: [String] = [], at = 8
        let bytes = [UInt8](png)
        while at + 8 <= bytes.count {
            let length = bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) }
            chunks.append(String(decoding: bytes[(at + 4)..<(at + 8)], as: UTF8.self))
            at += 12 + length
        }
        return (pixels, chunks)
    }

    static func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
        Array(pixels[((y * 64 + x) * 4)..<((y * 64 + x) * 4 + 4)])
    }

    /// Each sample within 8 of the colour's: a resampler may move a sample a little.
    static func near(_ pixels: [UInt8], _ x: Int, _ y: Int, _ colour: [UInt8]) -> Bool {
        zip(pixel(pixels, x, y), colour).allSatisfy { abs(Int($0) - Int($1)) <= 8 }
    }

    static let red: [UInt8] = [255, 0, 0, 255], blue: [UInt8] = [0, 0, 255, 255], clear: [UInt8] = [0, 0, 0, 0]
    /// The chunks of each logo that the rule draws: sRGB, and no profile, text, EXIF or time (decision D115).
    static let madeChunks = ["IHDR", "sRGB", "IDAT", "IEND"]

    /// A wide and a tall picture are fitted whole and centred on a clear ground, with their ends kept; a tiny one is
    /// scaled up to the whole square; each result is a PNG of 64 x 64 with IHDR, sRGB, IDAT and IEND alone, within the
    /// hub's bytes. Bugs: the ends of a logo with words are cut, a coloured ground, a stretched logo, a small logo
    /// left small, a PNG with the picture's metadata (ImageIO writes a profile, an EXIF) or one that the hub refuses.
    @Test func eachPictureIsFittedWholeCentredOnAClearGround() throws {
        let wide = Self.picture(200, 50) { x, _ in x < 10 || x >= 190 ? Self.red : Self.blue }
        let made = try CompanyLogo.made(from: Self.file(wide))
        #expect(made.said == "The picture went as a PNG of 64 x 64 px, fitted whole on a clear ground.")
        var (pixels, chunks) = try Self.read(made.png)
        #expect(chunks == Self.madeChunks && made.png.count <= CompanyLogo.most)
        #expect(Self.pixel(pixels, 0, 0) == Self.clear && Self.pixel(pixels, 32, 23) == Self.clear)
        #expect(Self.near(pixels, 32, 24, Self.blue) && Self.near(pixels, 32, 39, Self.blue))
        #expect(Self.near(pixels, 0, 32, Self.red) && Self.near(pixels, 63, 32, Self.red))

        let tall = Self.picture(50, 200) { _, y in y < 10 || y >= 190 ? Self.red : Self.blue }
        (pixels, chunks) = try Self.read(try CompanyLogo.png(from: Self.file(tall)))
        #expect(chunks == Self.madeChunks)
        #expect(Self.pixel(pixels, 0, 0) == Self.clear && Self.pixel(pixels, 23, 32) == Self.clear)
        #expect(Self.near(pixels, 32, 0, Self.red) && Self.near(pixels, 32, 63, Self.red))
        #expect(Self.near(pixels, 24, 32, Self.blue) && Self.near(pixels, 39, 32, Self.blue))

        let tiny = try CompanyLogo.made(from: Self.file(Self.picture(16, 16) { _, _ in [0, 255, 0, 255] }))
        #expect(tiny.said == "The picture went as a PNG of 64 x 64 px.")
        (pixels, chunks) = try Self.read(tiny.png)
        #expect(chunks == Self.madeChunks)
        #expect(Self.near(pixels, 0, 0, [0, 255, 0, 255]) && Self.near(pixels, 63, 63, [0, 255, 0, 255]))
    }

    /// A picture of noise does not fit at 8 bits a sample: it takes fewer colour bits until it fits, and says so.
    /// Bug: a busy picture is refused, or goes larger than the hub takes.
    @Test func aBusyPictureTakesFewerColoursUntilItFits() throws {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let noise = Self.picture(200, 200) { _, _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return [UInt8(seed >> 56), UInt8(seed >> 48 & 255), UInt8(seed >> 40 & 255), UInt8(seed >> 32 & 255)]
        }
        let made = try CompanyLogo.made(from: Self.file(noise))
        #expect(made.said == "The picture went as a PNG of 64 x 64 px, with fewer colours.")
        #expect(made.png.count <= CompanyLogo.most)
        #expect(try Self.read(made.png).chunks == Self.madeChunks)
    }

    /// **A ready PNG of 64 x 64 goes as it is, with its colour profile** (the tool's route; the hub keeps the profile,
    /// decision D115), and with `remake`, as the app's Settings rows call it, it is drawn again: sRGB, with the chunks
    /// of `madeChunks` alone. Bugs: the owner's Mac sends a profile, with its name and text, to every member; the
    /// tool changes a ready logo that the person made with care.
    @Test func aReadyPNGGoesAsItIsAndRemakeTakesItsProfileOut() throws {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 48, height: 48))
        let ready = Self.file(context.makeImage()!)                   // ImageIO writes the P3 profile in an iCCP
        let readyChunks = try Self.read(ready).chunks
        #expect(readyChunks.contains("iCCP") && ready.count <= CompanyLogo.most)
        let sent = try CompanyLogo.png(from: ready)
        #expect(sent == ready)
        let remade = try CompanyLogo.made(from: ready, remake: true)
        #expect(remade.said == "The picture went as a PNG of 64 x 64 px.")
        let (pixels, chunks) = try Self.read(remade.png)
        #expect(chunks == Self.madeChunks)
        #expect(Self.pixel(pixels, 0, 0) == Self.clear && Self.pixel(pixels, 32, 32)[3] == 255)
        let place = home.appendingPathComponent("ready.png")
        try ready.write(to: place)
        let fromFile = try CompanyLogo.png(from: place, remake: true)
        #expect(fromFile == remade.png)
    }

    /// A photo whose EXIF turns it is drawn turned, as every viewer shows it. Bug: the logo of a phone's photo lies on
    /// its side.
    @Test func aJPEGIsTurnedAsItsEXIFSays() throws {
        let stored = Self.picture(200, 50) { x, _ in x < 20 ? Self.red : Self.blue }
        let jpeg = Self.file(stored, "public.jpeg", orientation: 6)        // shown turned a quarter to the right
        let made = try CompanyLogo.made(from: jpeg)
        #expect(made.said.hasSuffix("fitted whole on a clear ground."))
        let (pixels, chunks) = try Self.read(made.png)
        #expect(chunks == Self.madeChunks)                              // no EXIF of the photo
        #expect(Self.pixel(pixels, 0, 32) == Self.clear && Self.pixel(pixels, 63, 32) == Self.clear)
        let top = Self.pixel(pixels, 32, 1), bottom = Self.pixel(pixels, 32, 62)
        #expect(top[0] > 200 && top[2] < 60 && top[3] == 255)                // the stored left end is now at the top
        #expect(bottom[2] > 200 && bottom[0] < 60)
    }

    /// **Nothing of a file that is no picture leaves this Mac** (the area's security rule for both copies): a text, a
    /// private key, a file that only starts as a PNG, a PDF, a PostScript file and an SVG are refused before any
    /// request, and the hub gets nothing. Bug: `logo_file` names a wrong file (a contract) and its bytes, or a
    /// picture of its first page, go to the hub.
    @Test func aFileThatIsNoPictureNeverLeavesThisMac() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        let header = CompanyLogo.signature + [0, 0, 0, 13] + Array("IHDR".utf8)
            + [0, 0, 0, 32, 0, 0, 0, 32, 8, 6, 0, 0, 0]
        let files: [(String, Data)] = [
            ("plan.txt", Data("The launch plan: the price is still open.\n".utf8)),
            // a key file's shape, its marker in two parts so that no scanner takes this file for a key
            ("id_ed25519", Data(("-----BEGIN OPENSSH " + "PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n"
                                 + "-----END OPENSSH " + "PRIVATE KEY-----\n").utf8)),
            ("start.png", Data(header + Array("not the rest of a picture".utf8))),
            ("contract.pdf", Self.pdf()),
            ("page.eps", Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\n".utf8)),
            ("logo.svg", Data([0xEF, 0xBB, 0xBF] + Array("\n  <svg xmlns='http://www.w3.org/2000/svg'/>".utf8))),
        ]
        for (name, bytes) in files {
            let place = home.appendingPathComponent(name)
            try bytes.write(to: place)
            #expect(throws: CompanyLogo.Failure.notAPicture) { try CompanyLogo.png(from: bytes) }
            #expect(tools.refused("save_company", ["logo_file": .string(place.path)]) == CompanyLogo.notAPictureWords)
        }
        #expect(tools.refused("save_company", ["logo_file": .string(home.appendingPathComponent("none.png").path)])
                == CompanyLogo.notAFile)
        #expect(tools.refused("save_company") == CompanyLogo.nothing)
        #expect(hub.seen.isEmpty)
        #expect(throws: CompanyLogo.Failure.self) { try CompanyLogo.png(from: home.appendingPathComponent("none.png")) }
    }

    /// The tool sends the logo that the rule made, as standard base64 in `png`, with the name, and answers the hub's
    /// two values and what went. Bug: the file's own bytes go, or the answer names a path of this Mac.
    @Test func theToolSendsTheMadeLogoAndSaysWhatWent() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        hub.answer = { seen in
            seen.method == "POST" ? (200, .object(["ok": .bool(true), "name": .string("Example Labs"),
                                                   "logo": .string("0123456789abcdef")])) : nil
        }
        let tools = Fixture.tools(hub, home: home)
        let place = home.appendingPathComponent("wide logo.png")
        let source = Self.file(Self.picture(200, 50) { x, _ in x < 10 ? Self.red : Self.blue })
        try source.write(to: place)
        let answer = try tools.json("save_company", ["name": .string("Example Labs"), "logo_file": .string(place.path)])
        #expect(answer == .object(["name": .string("Example Labs"), "logo": .string("0123456789abcdef"),
                                   "picture": .string("The picture went as a PNG of 64 x 64 px, fitted whole on a "
                                                      + "clear ground.")]))
        let sent = try #require(hub.seen.last { $0.method == "POST" })
        #expect(sent.path == "/ui/company" && sent.body?["name"] == .string("Example Labs"))
        let text = try #require(sent.body?["png"]?.string)
        let png = try #require(Data(base64Encoded: text))
        let expected = try CompanyLogo.png(from: source)
        #expect(png == expected && png != source)
    }

    /// The numbers and the words of a refusal are the ones of `owner_mcp.py`'s table, which test_teams_company holds
    /// to the hub's own numbers. Bugs: the hub takes a smaller logo than the one that the app makes, and refuses every
    /// logo; the two copies say different words for the same file.
    @Test func theNumbersAndTheWordsAreTheTables() throws {
        let url = try #require(Bundle.module.url(forResource: "owner-tools", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let root = try #require(JSONValue.parse(try Data(contentsOf: url)))
        #expect(root["COMPANY_LOGO"] == .object([
            "side": .int(Int64(CompanyLogo.side)), "most": .int(Int64(CompanyLogo.most)),
            "pixels_most": .int(Int64(CompanyLogo.pixelsMost)), "not_a_picture": .string(CompanyLogo.notAPictureWords),
            "too_many_pixels": .string(CompanyLogo.tooManyPixelsWords), "too_large": .string(CompanyLogo.tooLargeWords),
            "older_hub": .string(OwnerHub.olderHub)]))
    }

    /// A PDF of one page, which ImageIO does not read as a picture and sips does.
    static func pdf() -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 40, height: 20)
        let context = CGContext(consumer: CGDataConsumer(data: out as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return out as Data
    }

    /// The pixels of `test_teams_company.pattern()`: clear in the first 8 columns, half clear in the next 8, and
    /// colours of x and y.
    static func pattern() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let alpha: UInt8 = x < 8 ? 0 : x < 16 ? 128 : 255
                guard alpha > 0 else { continue }
                let at = (y * 64 + x) * 4
                let colour = [UInt8((x * 4) % 256), UInt8((y * 4) % 256), UInt8(((x + y) * 2) % 256), alpha]
                out.replaceSubrange(at..<(at + 4), with: colour)
            }
        }
        return out
    }

    /// **The writer gives, for the same pixels, the bytes of Python's** (`Fixtures/company-logo.png`, which
    /// test_teams_company holds to `owner_mcp.png_of` and to the hub's own check of a PNG): the same filters, the same
    /// deflate at level 9 and the same checksums, by the system's libz. Bugs: a checksum of this writer is wrong and
    /// the hub refuses each logo of the app's Settings rows; the two copies send different bytes, so a different
    /// `logo`.
    @Test func theWriterGivesTheBytesOfPython() throws {
        let url = try #require(Bundle.module.url(forResource: "company-logo", withExtension: "png",
                                                 subdirectory: "Fixtures"))
        #expect(try CompanyLogo.pngOf(Self.pattern()) == Data(contentsOf: url))
    }

    /// The frame of a picture in the square: the numbers of `test_teams_company.FRAMES`, which `owner_mcp.py` gives.
    /// Bug: a frame a pixel off in one copy, or a thin picture refused in one copy and drawn in the other.
    @Test func theFramesAreTheNumbersOfPython() throws {
        let frames: [((Int, Int), (Int, Int))] = [((300, 200), (64, 43)), ((200, 300), (43, 64)), ((128, 1), (64, 1)),
                                                  ((1000, 10), (64, 1)), ((10, 1000), (1, 64)), ((99, 100), (63, 64)),
                                                  ((16, 16), (64, 64)), ((200, 50), (64, 16)), ((3, 2), (64, 43))]
        for ((width, height), (fittedWidth, fittedHeight)) in frames {
            let fitted = CompanyLogo.fittedSize(width, height)
            #expect(fitted.width == fittedWidth && fitted.height == fittedHeight, "\(width) x \(height)")
        }
        let line = Self.picture(128, 1) { _, _ in Self.red }
        let (pixels, _) = try Self.read(try CompanyLogo.png(from: Self.file(line)))
        #expect((0..<64).filter { Self.pixel(pixels, 32, $0)[3] > 0 } == [31])
    }

    /// A clear and a half clear part of a picture stay so: drawn again, the alpha of each pixel is the picture's.
    /// Bug: a logo with a transparent part is drawn on black, or its half clear edge goes opaque.
    @Test func aClearAndAHalfClearPartOfAPictureStaySo() throws {
        let context = Self.context(64, 64)
        let samples = context.data!.bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
        let pattern = Self.pattern()
        for at in 0..<(64 * 64) {                        // premultiplied, as the context holds them
            let alpha = Int(pattern[at * 4 + 3])
            for sample in 0..<3 { samples[at * 4 + sample] = UInt8(Int(pattern[at * 4 + sample]) * alpha / 255) }
            samples[at * 4 + 3] = pattern[at * 4 + 3]
        }
        let made = try CompanyLogo.made(from: Self.file(context.makeImage()!), remake: true)
        let (pixels, chunks) = try Self.read(made.png)
        #expect(chunks == Self.madeChunks)
        #expect(Self.pixel(pixels, 3, 30)[3] == 0 && Self.pixel(pixels, 40, 30)[3] == 255)
        #expect(abs(Int(Self.pixel(pixels, 12, 30)[3]) - 128) <= 2)
    }

    /// **A ready PNG goes as it is only when the hub takes it so**, by the cases of the Python copy's test
    /// (`test_only_a_whole_png_that_the_hub_takes_goes_as_it_is`): whole with a text chunk or a profile alone; not
    /// with a byte after its end, a wrong CRC, no IEND, both sRGB and iCCP, a critical chunk of nobody, more than
    /// 12,288 bytes or 32 px. Each of those is drawn again, never refused, but the one that ImageIO cannot draw. Bug:
    /// the hub refuses with a 400 a file that the tool sent as it is, about a file that is a PNG of 64 x 64.
    @Test func aReadyPNGThatTheHubWouldRefuseIsDrawnAgain() throws {
        let ready = [UInt8](try CompanyLogo.pngOf(Self.pattern()))         // IHDR, sRGB, IDAT, IEND
        let ihdr = Data(ready[8..<33]), srgb = Data(ready[33..<46])
        let idat = Data(ready[46..<(ready.count - 12)]), iend = Data(ready.suffix(12))
        let signature = Data(CompanyLogo.signature)
        let profileBody: [UInt8] = Array("P3".utf8) + [0, 0, 0x78, 0x9C, 0x03, 0, 0, 0, 0, 1]
        let profile = CompanyLogo.chunk("iCCP", profileBody)
        let text = CompanyLogo.chunk("tEXt", Array("Author\u{0}Example Labs".utf8))
        /// The PNG of these chunks, after the signature.
        func png(_ chunks: [Data]) -> Data { chunks.reduce(signature, +) }
        let whole: [Data] = [png([ihdr, idat, iend]), png([ihdr, text, idat, iend]), png([ihdr, profile, idat, iend]),
                             Data(ready)]
        for one in whole { #expect(CompanyLogo.asIs(one)) }
        let fillerBody: [UInt8] = Array("Comment\u{0}".utf8) + [UInt8](repeating: 0x78, count: 12_288)
        let large = png([ihdr, srgb, CompanyLogo.chunk("tEXt", fillerBody), idat, iend])
        let small = Self.file(Self.picture(32, 32) { _, _ in Self.red })
        var wrong = ready
        wrong[wrong.count - 1] ^= 1                                             // IEND's CRC
        let drawn: [Data] = [Data(ready + [0]), Data(wrong), Data(ready.dropLast(12)),
                             png([ihdr, srgb, profile, idat, iend]), large, small]
        for one in drawn {
            #expect(!CompanyLogo.asIs(one))
            let made = try CompanyLogo.made(from: one)
            #expect(made.said == "The picture went as a PNG of 64 x 64 px." && made.png.count <= CompanyLogo.most)
            #expect(try Self.read(made.png).chunks == Self.madeChunks)
        }
        #expect(!CompanyLogo.asIs(png([ihdr, CompanyLogo.chunk("ABCD", []), idat, iend])))
    }

    /// **A picture of more than 100 million pixels is refused before it is decoded**: a PNG of 10,001 x 10,000 of a
    /// few kB. Bug: a small file makes the app take gigabytes of memory.
    @Test func aPictureOfTooManyPixelsIsRefusedBeforeItIsDecoded() throws {
        let width = 10_001, height = 10_000
        let raw = [UInt8](repeating: 0, count: height * (1 + (width + 7) / 8))
        var size = compressBound(uLong(raw.count))
        var packed = [UInt8](repeating: 0, count: Int(size))
        #expect(compress2(&packed, &size, raw, uLong(raw.count), 9) == Z_OK)
        var huge = Data(CompanyLogo.signature)
        let size2 = CompanyLogo.bigEndian(UInt32(width)) + CompanyLogo.bigEndian(UInt32(height))
        huge.append(CompanyLogo.chunk("IHDR", size2 + [1, 0, 0, 0, 0]))
        huge.append(CompanyLogo.chunk("IDAT", Array(packed[0..<Int(size)])))
        huge.append(CompanyLogo.chunk("IEND", []))
        #expect(throws: CompanyLogo.Failure.tooManyPixels) { try CompanyLogo.png(from: huge) }
        let place = home.appendingPathComponent("huge.png")
        try huge.write(to: place)
        let hub = StandInHub(features: Fixture.everyFeature)
        #expect(Fixture.tools(hub, home: home).refused("save_company", ["logo_file": .string(place.path)])
                == CompanyLogo.tooManyPixelsWords)
        #expect(hub.seen.isEmpty)
    }

    /// The Settings rows' file that is larger than `fileMost` is refused before it is read, also through a link to it.
    /// Bug: a file of gigabytes that a person chose, or a link to one, is read whole into the app.
    @Test func aFileLargerThanTheLimitIsRefusedBeforeItIsRead() throws {
        let place = home.appendingPathComponent("large.tiff")
        FileManager.default.createFile(atPath: place.path, contents: nil)
        let handle = try FileHandle(forWritingTo: place)
        try handle.truncate(atOffset: UInt64(CompanyLogo.fileMost + 1))
        try handle.close()
        #expect(throws: CompanyLogo.Failure.fileTooLarge(CompanyLogo.fileMost + 1)) { try CompanyLogo.png(from: place) }
        // a link to it, whose own size is a few bytes, is measured as the file that it names
        let link = home.appendingPathComponent("link.tiff")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: place)
        #expect(throws: CompanyLogo.Failure.fileTooLarge(CompanyLogo.fileMost + 1)) { try CompanyLogo.png(from: link) }
    }
}
