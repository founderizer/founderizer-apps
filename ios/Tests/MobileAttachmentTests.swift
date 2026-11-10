import CoreGraphics
import FleetCore
import Foundation
import ImageIO
import Testing
@testable import FleetMobile

/// The files that the owner sends with a message (owner feature `attachments`). The fixture proves that the phone
/// sends and shows them; these checks prove the rules that must hold before anything travels: what the app takes,
/// what it makes of a picture, what it names a file, and that nothing is shown whose bytes are not the bytes the hub
/// named.
@Suite("The files of a message")
struct MobileAttachmentTests {

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 64)

    private func file(_ changes: [String: Any?] = [:]) throws -> MessageAttachment {
        var fields: [String: Any] = ["id": 7, "name": "mockup.png", "mime": "image/png", "size": 412,
                                     "sha256": String(repeating: "a", count: 64), "created": 1000.0]
        for (key, value) in changes {
            if let value { fields[key] = value } else { fields.removeValue(forKey: key) }
        }
        return try JSONDecoder().decode(MessageAttachment.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    /// A picture of one colour, as the camera and the library give them, in the type that the test needs.
    private func picture(_ type: String, width: Int = 1200, height: Int = 900) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let made = NSMutableData()
        let out = CGImageDestinationCreateWithData(made, type as CFString, 1, nil)!
        CGImageDestinationAddImage(out, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(out))
        return made as Data
    }

    @Test("Only the types the hub takes are offered, by their own extension")
    func types() throws {
        #expect(MessageAttachment.mime(forName: "shot.PNG") == "image/png")
        #expect(MessageAttachment.mime(forName: "a.jpeg") == "image/jpeg")
        #expect(MessageAttachment.mime(forName: "notes.md") == "text/markdown")
        #expect(MessageAttachment.mime(forName: "rows.csv") == "text/csv")
        #expect(MessageAttachment.mime(forName: "run.sh") == nil)
        #expect(MessageAttachment.mime(forName: "photo.heic") == nil)
        #expect(MessageAttachment.types.count == 10)
        #expect(MessageAttachment.perMessage == 4)
        #expect(MessageAttachment.sizeLimit == 25 * 1024 * 1024)
    }

    @Test("A name travels as the hub keeps it: no path, no strange letter, the right end")
    func names() {
        #expect(MessageAttachment.safeName("mockup.png", mime: "image/png") == "mockup.png")
        #expect(MessageAttachment.safeName("../../etc/passwd", mime: "text/plain") == "__.._etc_passwd.txt")
        #expect(MessageAttachment.safeName("", mime: "application/pdf") == "file.pdf")
        #expect(MessageAttachment.safeName("note", mime: "text/plain") == "note.txt")
        #expect(MessageAttachment.safeName("Trip to Köln.pdf", mime: "application/pdf") == "Trip to K_ln.pdf")
        #expect(MessageAttachment.safeName(String(repeating: "x", count: 200), mime: "image/png").count <= 84)
    }

    @Test("A PNG goes as it is; another picture becomes a JPEG that is small enough to send")
    func pictures() throws {
        let kept = try MessageAttachment.imageForSending(try picture("public.png"))
        #expect(kept.mime == "image/png")
        let made = try MessageAttachment.imageForSending(try picture("public.tiff", width: 4000, height: 3000))
        #expect(made.mime == "image/jpeg")
        #expect(made.data.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(made.data.count < 25 * 1024 * 1024)
        let source = CGImageSourceCreateWithData(made.data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as! Int == 2048)
        #expect(throws: (any Error).self) { try MessageAttachment.imageForSending(Data()) }
        #expect(throws: (any Error).self) { try MessageAttachment.imageForSending(Data("not a picture".utf8)) }
    }

    @Test("A thumbnail is drawn for a picture and for nothing else")
    func thumbnails() throws {
        #expect(MessageAttachment.thumbnail(try picture("public.png"), maxPixels: 64)?.width == 64)
        #expect(MessageAttachment.thumbnail(Data("plain words".utf8)) == nil)
    }

    @Test("Nothing is shown whose bytes are not the bytes the hub named")
    func bytes() throws {
        let item = try file(["size": png.count, "sha256": MessageAttachment.digest(png)])
        try item.validate()
        #expect(item.matches(png))
        #expect(!item.matches(png + Data([0])))
        #expect(!(try file(["size": png.count, "sha256": String(repeating: "b", count: 64)]).matches(png)))
    }

    @Test("A file that the hub describes in another way is refused")
    func metadata() throws {
        #expect(throws: (any Error).self) { try file(["id": 0]).validate() }
        #expect(throws: (any Error).self) { try file(["mime": "application/x-sh"]).validate() }
        #expect(throws: (any Error).self) { try file(["size": 0]).validate() }
        #expect(throws: (any Error).self) { try file(["size": 26 * 1024 * 1024]).validate() }
        #expect(throws: (any Error).self) { try file(["sha256": "ABCD"]).validate() }
        #expect(throws: (any Error).self) { try file(["sha256": String(repeating: "A", count: 64)]).validate() }
        #expect(throws: (any Error).self) { try file(["created": 0.0]).validate() }
    }

    @Test("A message carries the numbers of its files, and a request keeps them across a launch")
    func request() throws {
        let hub = try #require(try? MobileClient.address("http://127.0.0.1:8765"))
        let sending = PendingRequest(hub: hub, database: "gen-1", client: "founderizer-ios/1/x", recipient: "studio",
                                     attachments: [3, 4], text: "Look at this.")
        let body = try JSONSerialization.jsonObject(with: sending.body()) as! [String: Any]
        #expect(body["attachments"] as! [Int] == [3, 4])
        #expect(body["text"] as! String == "Look at this.")
        let again = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(sending))
        #expect(again.attachments == [3, 4])
        // A request that an older version of the app saved carries no files and is still read.
        var older = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sending)) as! [String: Any]
        older.removeValue(forKey: "attachments")
        let old = try JSONDecoder().decode(PendingRequest.self,
                                           from: JSONSerialization.data(withJSONObject: older))
        #expect(old.attachments.isEmpty)
        #expect(try JSONSerialization.jsonObject(with: old.body()) as! [String: Any] as? [String: AnyHashable] != nil)
        #expect(!(try JSONSerialization.jsonObject(with: old.body()) as! [String: Any]).keys.contains("attachments"))
    }

    @Test("A receipt confirms a message only when it names the same files")
    func receipt() throws {
        let hub = try #require(try? MobileClient.address("http://127.0.0.1:8765"))
        let sending = PendingRequest(hub: hub, database: "gen-1", client: "c", recipient: "studio",
                                     attachments: [3], text: "Look.")
        func receipt(_ files: [Int]?) throws -> SendReceipt {
            var fields: [String: Any] = ["ok": true, "request_id": sending.requestID.uuidString.lowercased(),
                                         "event_id": 9, "created": 1.0, "replayed": false, "client": "c",
                                         "recipient": "studio"]
            if let files { fields["attachments"] = files }
            return try JSONDecoder().decode(SendReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        #expect(try receipt([3]).matches(sending))
        #expect(try !receipt([3, 4]).matches(sending))
        #expect(try !receipt([]).matches(sending))
        // A hub without the feature says nothing about files, so a message that carries one is never confirmed by it.
        #expect(try !receipt(nil).matches(sending))
    }

    @Test("The chat page reads the files of a message, and takes none when the hub names none")
    func chatItems() throws {
        func item(_ files: Any?) throws -> MobileChatItem {
            var fields: [String: Any] = ["kind": "message", "ts": 10.0, "id": "r-1", "text": "Look.",
                                         "client": "founderizer-ios/1/x"]
            if let files { fields["attachments"] = files }
            return try JSONDecoder().decode(MobileChatItem.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let carried = try item([["id": 3, "name": "a.png", "mime": "image/png", "size": 10,
                                 "sha256": String(repeating: "a", count: 64), "created": 1.0]])
        #expect(carried.attachments.map(\.id) == [3])
        #expect(carried.attachments[0].isImage)
        #expect(try item(nil).attachments.isEmpty)
        #expect(try item([]).attachments.isEmpty)
    }

    @Test("The size of a file is said in the owner's words")
    func sizes() throws {
        #expect(try file(["size": 900]).sizeWords == "900 B")
        #expect(try file(["size": 412 * 1024]).sizeWords == "412 KB")
        // The number as the phone writes numbers (fix round 2, B13): "3.5 MB" in English, "3,5 MB" where a comma is the
        // decimal mark.
        #expect(try file(["size": 3 * 1024 * 1024 + 512 * 1024]).sizeWords ==
                3.5.formatted(.number.precision(.fractionLength(1))) + " MB")
        #expect(try file(["mime": "application/pdf", "name": "a.pdf"]).symbol == "doc.richtext")
        #expect(try file(["mime": "application/zip", "name": "a.zip"]).symbol == "doc.zipper")
        #expect(try file().symbol == "photo")
    }
}
