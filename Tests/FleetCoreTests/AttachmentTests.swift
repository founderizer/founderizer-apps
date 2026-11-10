import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FleetCore

/// The files that the owner sends with a message (owner feature `attachments`). Both apps keep these rules before
/// anything travels, and neither shows bytes that are not the bytes the hub named.
@Suite struct AttachmentTests {

    private func file(_ changes: [String: Any?] = [:]) throws -> MessageAttachment {
        var fields: [String: Any] = ["id": 7, "name": "mockup.png", "mime": "image/png", "size": 412,
                                     "sha256": String(repeating: "a", count: 64), "created": 1000.0]
        for (key, value) in changes {
            if let value { fields[key] = value } else { fields.removeValue(forKey: key) }
        }
        return try JSONDecoder().decode(MessageAttachment.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func picture(_ type: String, width: Int = 600, height: Int = 400) throws -> Data {
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

    @Test func theAppTakesOnlyWhatTheHubTakes() throws {
        #expect(MessageAttachment.types.count == 10)
        #expect(MessageAttachment.sizeLimit == 25 * 1024 * 1024)
        #expect(MessageAttachment.perMessage == 4)
        #expect(MessageAttachment.mime(forName: "a.PNG") == "image/png")
        #expect(MessageAttachment.mime(forName: "a.jpeg") == "image/jpeg")
        #expect(MessageAttachment.mime(forName: "a.md") == "text/markdown")
        #expect(MessageAttachment.mime(forName: "a.heic") == nil)
        #expect(MessageAttachment.mime(forName: "a") == nil)
    }

    @Test func aNameTravelsAsTheHubKeepsIt() {
        #expect(MessageAttachment.safeName("mockup.png", mime: "image/png") == "mockup.png")
        #expect(MessageAttachment.safeName("../../etc/passwd", mime: "text/plain") == "__.._etc_passwd.txt")
        #expect(MessageAttachment.safeName("Trip to Köln.pdf", mime: "application/pdf") == "Trip to K_ln.pdf")
        #expect(MessageAttachment.safeName("  ", mime: "text/csv") == "file.csv")
        #expect(MessageAttachment.safeName("rows", mime: "text/csv") == "rows.csv")
    }

    @Test func nothingIsShownWhoseBytesAreNotTheBytesTheHubNamed() throws {
        let bytes = Data("a picture, say".utf8)
        let item = try file(["size": bytes.count, "sha256": MessageAttachment.digest(bytes)])
        try item.validate()
        #expect(item.matches(bytes))
        #expect(!item.matches(bytes + Data([0])))
        #expect(throws: (any Error).self) { try self.file(["mime": "application/x-sh"]).validate() }
        #expect(throws: (any Error).self) { try self.file(["size": 26 * 1024 * 1024]).validate() }
        #expect(throws: (any Error).self) { try self.file(["sha256": String(repeating: "A", count: 64)]).validate() }
    }

    @Test func aPictureIsMadeReadyToSend() throws {
        #expect(try MessageAttachment.imageForSending(try picture("public.png")).mime == "image/png")
        let made = try MessageAttachment.imageForSending(try picture("public.tiff", width: 3000, height: 2000),
                                                         maxPixels: 512)
        #expect(made.mime == "image/jpeg")
        let source = CGImageSourceCreateWithData(made.data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as! Int == 512)
        #expect(MessageAttachment.thumbnail(try picture("public.png"), maxPixels: 48)?.width == 48)
        #expect(MessageAttachment.thumbnail(Data("words".utf8)) == nil)
    }

    @Test func aRequestCarriesTheNumbersOfItsFiles() throws {
        let hub = try HubClient.address("http://127.0.0.1:8765")
        let sending = PendingRequest(hub: hub, database: "gen-1", client: "c", recipient: "studio",
                                     attachments: [3, 4], text: "Look at this.")
        let body = try JSONSerialization.jsonObject(with: sending.body()) as! [String: Any]
        #expect(body["attachments"] as! [Int] == [3, 4])
        let plain = PendingRequest(hub: hub, database: "gen-1", client: "c", recipient: "studio", text: "No files.")
        let yes = PendingRequest(hub: hub, database: "gen-1", client: "c", needID: 7, choice: 0,
                                 approval: (statement: "{\"v\":1}", signature: "c2ln"), text: "Yes, run it once")
        let signed = try JSONSerialization.jsonObject(with: yes.body()) as? [String: Any] ?? [:]
        #expect(signed["statement"] as? String == "{\"v\":1}" && signed["signature"] as? String == "c2ln")
        #expect(signed["choice"] as? Int == 0 && signed["answer"] == nil)
        let message = PendingRequest(hub: hub, database: "gen-1", client: "c", recipient: "studio",
                                     approval: (statement: "{}", signature: "c2ln"), text: "Hello")
        #expect((try JSONSerialization.jsonObject(with: message.body()) as? [String: Any])?["statement"] == nil)
        #expect(!(try JSONSerialization.jsonObject(with: plain.body()) as! [String: Any]).keys.contains("attachments"))
        // A record that an older version of an app saved carries no files and is still read.
        var older = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sending)) as! [String: Any]
        older.removeValue(forKey: "attachments")
        let old = try JSONDecoder().decode(PendingRequest.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(old.attachments.isEmpty)
    }

    @Test func theOutboxKeepsOneRequestWithItsOwnFiles() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = Outbox(file: directory.appendingPathComponent("pending.json"))
        let hub = try HubClient.address("http://127.0.0.1:8765")
        let request = PendingRequest(hub: hub, database: "gen-1", client: "c", recipient: "studio",
                                     attachments: [3], text: "Look.")
        try outbox.save(request)
        #expect(try outbox.load()?.attachments == [3])
        try outbox.save(request)                        // the same request again is the same record
        #expect(throws: (any Error).self) {
            try outbox.save(PendingRequest(hub: hub, database: "gen-1", client: "c", recipient: "studio",
                                           attachments: [3, 9], text: "Look."))
        }
    }

    // ---- keeping one of them past the ninety days (owner feature attachment_knowledge, UI-API.md 1.30 and 1.31)

    @Test func theAppReadsHowAFileIsKeptAndTellsTheTwoKindsApart() throws {
        // Not kept, which is every file until he says so -- and every file of a hub before the feature, whose
        // answers carry no `kept` at all.
        let plain = try file()
        #expect(!plain.isKept && plain.keptAs == nil)
        try plain.validate()
        // Kept alone: a picture, which could never become a knowledge file. `knowledge` is null, and that is the
        // whole of what tells it from the other kind.
        let alone = try file(["kept": ["at": 1_700_000.0, "knowledge": NSNull()]])
        #expect(alone.isKept && alone.keptAs == nil)
        try alone.validate()
        // Kept as knowledge: the words of a text file are in his own knowledge, and in his copy of the fleet.
        let words = try file(["mime": "text/markdown", "name": "tolerances.md",
                              "kept": ["at": 1_700_000.0, "knowledge": "knowledge/owner/mill-tolerances.md"]])
        #expect(words.isKept && words.keptAs == "knowledge/owner/mill-tolerances.md")
        try words.validate()
        #expect(throws: (any Error).self) { try self.file(["kept": ["at": 0.0]]).validate() }
        #expect(throws: (any Error).self) { try self.file(["kept": ["at": 1.0, "knowledge": ""]]).validate() }
    }

    @Test func onlyTheFourTextTypesCanBecomeAKnowledgeFile() throws {
        // The hub answers 415 for every other type, because knowledge is text that search_knowledge reads. So the
        // app offers the one press for exactly these four and the file itself for the rest.
        #expect(MessageAttachment.knowledgeTypes == ["text/plain", "text/markdown", "text/csv", "application/json"])
        for mime in MessageAttachment.knowledgeTypes {
            #expect(try file(["mime": mime]).canBecomeKnowledge, "\(mime) is one of the four")
        }
        for mime in ["image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf", "application/zip"] {
            #expect(try !file(["mime": mime]).canBecomeKnowledge, "\(mime) can only be kept as the file itself")
        }
        #expect(MessageAttachment.knowledgeTypes.isSubset(of: Set(MessageAttachment.types.keys)))
    }

    @Test func thePressSendsOneCommandAndTakesOnlyItsOwnReceipt() async throws {
        let item = try file()
        let kept = try OneAnswer(status: "200 OK") { message in
            let body = try! JSONSerialization.jsonObject(with: OneAnswer.body(of: message)) as! [String: Any]
            return #"{"ok":true,"request_id":"\#(body["request_id"] as! String)","client":"c","#
                + #""attachment":7,"kept":{"at":1700000.0,"knowledge":null},"going":false}"#
        }
        let receipt = try await HubClient().keep(item, true, client: "c",
                                                  hub: URL(string: "http://127.0.0.1:\(kept.port)")!, database: "db")
        let sent = String(decoding: kept.received, as: UTF8.self)
        #expect(sent.starts(with: "POST /ui/attachments/7/keep HTTP/1.1\r\n"))
        #expect(sent.contains("X-Fleet-Client: c"))
        #expect(receipt.kept?.knowledge == nil && receipt.going == false)
        let body = try JSONSerialization.jsonObject(with: OneAnswer.body(of: kept.received)) as! [String: Any]
        #expect(body["keep"] as? Bool == true)          // a boolean, which is the one thing the hub takes
        #expect(body["db"] as? String == "db")
        #expect(Set(body.keys) == ["request_id", "db", "keep"])
    }

    @Test func aReceiptThatDoesNotMatchThePressIsNoAnswer() async throws {
        // Each of these is the hub answering about something else, or about the other direction, which must never
        // turn into a mark on this file.
        let item = try file()
        for body in [#"{"ok":true,"request_id":"x","client":"c","attachment":7,"kept":null,"going":true}"#,
                     #"{"ok":true,"request_id":"R","client":"other","attachment":7,"kept":{"at":1.0},"going":false}"#,
                     #"{"ok":true,"request_id":"R","client":"c","attachment":9,"kept":{"at":1.0},"going":false}"#,
                     #"{"ok":true,"request_id":"R","client":"c","attachment":7,"kept":null,"going":true}"#] {
            let hub = try OneAnswer(status: "200 OK") { message in
                let sent = try! JSONSerialization.jsonObject(with: OneAnswer.body(of: message)) as! [String: Any]
                return body.replacingOccurrences(of: #""R""#, with: "\"\(sent["request_id"] as! String)\"")
            }
            await #expect(throws: (any Error).self) {
                try await HubClient().keep(item, true, client: "c",
                                           hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db")
            }
        }
    }

    @Test func theWordsOfATextFileGoAsTheKnowledgeShapeOfItsOwnRoute() async throws {
        let hub = try OneAnswer(status: "200 OK") { message in
            let body = try! JSONSerialization.jsonObject(with: OneAnswer.body(of: message)) as! [String: Any]
            return #"{"ok":true,"request_id":"\#(body["request_id"] as! String)","client":"c","#
                + #""path":"knowledge/owner/mill-tolerances.md","title":"Mill tolerances","#
                + #""commit":"\#(String(repeating: "a", count: 40))"}"#
        }
        let receipt = try await KnowledgeClient().add(attachment: 7, hub: URL(string: "http://127.0.0.1:\(hub.port)")!,
                                                      database: "db", client: "c")
        #expect(receipt.path == "knowledge/owner/mill-tolerances.md")
        let sent = String(decoding: hub.received, as: UTF8.self)
        #expect(sent.starts(with: "POST /ui/knowledge HTTP/1.1\r\n"))
        let body = try JSONSerialization.jsonObject(with: OneAnswer.body(of: hub.received)) as! [String: Any]
        #expect(body["attachment"] as? Int == 7)
        #expect(Set(body.keys) == ["request_id", "db", "attachment"])    // no title: the hub takes the file's own
    }

    @Test func aReceiptConfirmsOnlyTheSameFiles() throws {
        let hub = try HubClient.address("http://127.0.0.1:8765")
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
        #expect(try !receipt(nil).matches(sending))     // a hub without the feature never confirms a file
    }
}
