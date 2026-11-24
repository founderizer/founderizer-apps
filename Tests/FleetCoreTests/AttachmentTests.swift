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

    /// CHAT-APPS.md 8.1: a chat app's file of any type comes, and the apps open and save it with its own extension;
    /// only the four picture types whose first bytes the hub checks are drawn from their bytes, so no decoder of the
    /// app's own process reads a stranger's TIFF, DNG or HEIC bytes.
    @Test func aChatAppsFileOfAnyTypeOpensAndOnlyCheckedPicturesAreDrawn() throws {
        for (mime, name, drawn) in [("video/mp4", "clip.mp4", false), ("image/heic", "IMG_0001.heic", false),
                                    ("image/tiff", "scan.tiff", false), ("application/octet-stream", ".env", false),
                                    ("image/png", "shot.png", true), ("image/jpeg", "photo.jpg", true)] {
            let file = try self.file(["mime": mime, "name": name])
            try file.validate()
            #expect(file.isImage == drawn, "\(mime)")
        }
        #expect(MessageAttachment.safeName("clip.mp4", mime: "video/mp4") == "clip.mp4")
        #expect(MessageAttachment.safeName("", mime: "video/mp4") == "file")
        for bad in ["text/plain\r\nX-A: 1", "Image/PNG", "text/", "/png", "a/b/c", ""] {
            #expect(throws: AttachmentError.self) { try self.file(["mime": bad, "name": "x"]).validate() }
        }
    }

    /// CHAT-APPS.md 20: an agent's message can carry a spreadsheet, a Word file or a presentation, and the apps read
    /// and open them. The owner sends them himself only to a hub with `office_files` (UI-API.md 1.251; his "Yes, fix
    /// both" of 20 November 2026): a hub before it answers 415, so the plus, a drop and Cmd+V refuse them there with
    /// the words of what that hub takes.
    @Test func anOfficeFileGoesOnlyToAHubThatTakesIt() throws {
        let sheet = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        let slides = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        let word = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        for (mime, symbol) in [(sheet, "tablecells"), (slides, "rectangle.on.rectangle"), (word, "doc.text")] {
            let file = try self.file(["mime": mime, "name": "Prices.xlsx"])
            try file.validate()
            #expect(file.symbol == symbol)
            #expect(!file.isImage)
            #expect(!MessageAttachment.sendable(mime, office: false) && MessageAttachment.sendable(mime, office: true))
            #expect(!MessageAttachment.opensWithoutShell(mime) && GuidanceFiles.any.takes(mime))
        }
        #expect(MessageAttachment.mime(forName: "Prices.xlsx") == nil)
        #expect(MessageAttachment.mime(forName: "Prices.XLSX", office: true) == sheet)
        #expect(MessageAttachment.mime(forName: "Plan.docx", office: true) == word)
        #expect(MessageAttachment.mime(forName: "Deck.pptx", office: true) == slides)
        #expect(MessageAttachment.mime(forName: "a.heic", office: true) == nil)
        #expect(MessageAttachment.safeName("Contract v2", mime: word) == "Contract v2.docx")    // the hub's own name
        #expect(MessageAttachment.typeWords(office: true).contains("Word"))
        #expect(!MessageAttachment.typeWords(office: false).contains("Word"))
        #expect(!MessageAttachment.sendable("application/x-msdownload", office: true))
        // a chat app's file of any type opens (CHAT-APPS.md 8.1), while the owner's own send still refuses it
        try self.file(["mime": "application/x-msdownload"]).validate()
    }

    /// A report and a conversation line carry the files of the agent's words; a hub from before them sends none.
    @Test func aReportAndAConversationLineCarryTheAgentsFiles() throws {
        let file: [String: Any] = ["id": 41, "name": "Invoice October.pdf", "mime": "application/pdf", "size": 182,
                                   "sha256": String(repeating: "b", count: 64), "created": 1000.0, "kept": NSNull()]
        let report: [String: Any] = ["id": 3, "agent": "studio", "text": "Here is the invoice.", "about": "",
                                     "created": 1000.0, "in_reply_to": NSNull(), "delivery": NSNull(),
                                     "pushed": true, "attachments": [file]]
        let decoded = try JSONDecoder().decode(ManagerReport.self, from: JSONSerialization.data(withJSONObject: report))
        #expect(decoded.attachments?.map(\.id) == [41])
        var older = report
        older.removeValue(forKey: "attachments")
        #expect(try JSONDecoder().decode(ManagerReport.self, from: JSONSerialization.data(withJSONObject: older))
            .attachments == nil)
        let line: [String: Any] = ["id": "CM-7", "who": "agent", "text": "Here is the list.", "created": 1000.0,
                                   "read_at": NSNull(), "in_reply_to": "CM-6", "need": NSNull(), "delivery": NSNull(),
                                   "attachments": [file]]
        let item = try JSONDecoder().decode(ConversationItem.self, from: JSONSerialization.data(withJSONObject: line))
        #expect(item.attachments?.first?.name == "Invoice October.pdf")
    }

    @Test func aNameTravelsAsTheHubKeepsIt() {
        #expect(MessageAttachment.safeName("mockup.png", mime: "image/png") == "mockup.png")
        #expect(MessageAttachment.safeName("../../etc/passwd", mime: "text/plain") == "__.._etc_passwd.txt")
        #expect(MessageAttachment.safeName("Trip to Köln.pdf", mime: "application/pdf") == "Trip to K_ln.pdf")
        #expect(MessageAttachment.safeName("  ", mime: "text/csv") == "file.csv")
        #expect(MessageAttachment.safeName("rows", mime: "text/csv") == "rows.csv")
    }

    /// The save icon of an agent's file writes into Downloads: a file that the owner has there already stays as it
    /// was, and a name from the hub never reaches outside the folder.
    @Test func aSavedFileNeverReplacesAFileOrLeavesItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try MessageAttachment.save(Data("one".utf8), named: "Report.pdf", in: folder)
        let second = try MessageAttachment.save(Data("two".utf8), named: "Report.pdf", in: folder)
        #expect(first.lastPathComponent == "Report.pdf")
        #expect(second.lastPathComponent == "Report 2.pdf")
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
        _ = try MessageAttachment.save(Data("a".utf8), named: "notes", in: folder)
        #expect(try MessageAttachment.save(Data("b".utf8), named: "notes", in: folder).lastPathComponent == "notes 2")
        for name in ["../../escape", "a/\u{301}../../escape"] {
            let place = try MessageAttachment.save(Data("x".utf8), named: name, in: folder)
            #expect(place.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
            #expect(!place.lastPathComponent.unicodeScalars.contains("/"))
        }
        #expect(MessageAttachment.diskName("../../escape") == "_.._.._escape")
        #expect(MessageAttachment.diskName("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(MessageAttachment.diskName(".hidden.pdf") == "_.hidden.pdf")
        #expect(MessageAttachment.diskName(".\u{301}x.pdf") == "_.\u{301}x.pdf")
        #expect(MessageAttachment.diskName(" ") == "file")
    }

    @Test func nothingIsShownWhoseBytesAreNotTheBytesTheHubNamed() throws {
        let bytes = Data("a picture, say".utf8)
        let item = try file(["size": bytes.count, "sha256": MessageAttachment.digest(bytes)])
        try item.validate()
        #expect(item.matches(bytes))
        #expect(!item.matches(bytes + Data([0])))
        #expect(throws: (any Error).self) { try self.file(["mime": "Application/X-SH"]).validate() }   // no type token
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
        // For a session with no shell, a picture that the hub would not give in a tool's answer is made small enough
        // (`shownPictureSide`, `shownPictureBytes`); one that fits goes as it is.
        let wide = try picture("public.png", width: MessageAttachment.shownPictureSide + 1, height: 10)
        #expect(try MessageAttachment.imageForSending(wide).mime == "image/png")
        let shown = try MessageAttachment.imageForSending(wide, shown: true)
        #expect(shown.mime == "image/jpeg" && shown.data.count <= MessageAttachment.shownPictureBytes)
        #expect(try MessageAttachment.imageForSending(try picture("public.png"), shown: true).mime == "image/png")
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
        // **A skill that he gives goes as `{"give": <its ZIP's number>}` alone** (owner feature `message_skills`), never
        // also in `attachments`, where the agent would get it as a file too; the hub refuses an entry with a second key,
        // and skills on an answer. A record that a version before it saved has none, and sends no field.
        let giving = PendingRequest(hub: hub, database: "gen-1", client: "c", recipient: "studio", attachments: [3],
                                    skills: [.give(41)], text: "")
        let given = try JSONSerialization.jsonObject(with: giving.body()) as! [String: Any]
        #expect(given["skills"] as? [[String: Int]] == [["give": 41]] && given["attachments"] as? [Int] == [3])
        #expect(giving.givenFiles == [41])
        #expect(!(try JSONSerialization.jsonObject(with: plain.body()) as! [String: Any]).keys.contains("skills"))
        #expect(PendingRequest(hub: hub, database: "gen-1", client: "c", needID: 7, skills: [.give(41)], text: "Yes")
            .skills == nil)
        #expect(try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(giving)).skills == [.give(41)])
        #expect(old.skills == nil)
        // A guidance carries its files beside its words (owner API 1.223): a body without them was a file dropped in
        // silence. No other command carries a file.
        let guidance = PendingRequest(hub: hub, database: "gen-1", client: "c", command: .steer(task: 8, attempt: 2),
                                      attachments: [3, 4], text: "Use this screenshot.")
        let steer = try JSONSerialization.jsonObject(with: guidance.body()) as! [String: Any]
        #expect(steer["attachments"] as? [Int] == [3, 4])
        #expect(steer["text"] as? String == "Use this screenshot." && steer["expected_attempt"] as? Int == 2)
        let other = PendingRequest(hub: hub, database: "gen-1", client: "c",
                                   command: .triggerState(id: 2, revision: 1, action: .pause), attachments: [3], text: "")
        #expect(throws: (any Error).self) { try other.body() }
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
        // The hub's replay lists the files by number, whatever their order in the request.
        let two = PendingRequest(hub: hub, database: "gen-1", client: "c", recipient: "studio",
                                 attachments: [4, 3], text: "Look.")
        let replayed = try JSONDecoder().decode(SendReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "ok": true, "request_id": two.requestID.uuidString.lowercased(), "event_id": 9, "created": 1.0,
            "replayed": true, "client": "c", "recipient": "studio", "attachments": [3, 4]]))
        #expect(replayed.matches(two))
        #expect(try !receipt([3, 4]).matches(sending))
        #expect(try !receipt(nil).matches(sending))     // a hub without the feature never confirms a file
        // A guidance's receipt, the same: its steer must hold the files that were sent (owner API 1.223).
        let guidance = PendingRequest(hub: hub, database: "gen-1", client: "c", command: .steer(task: 8, attempt: 2),
                                      attachments: [3], text: "Look.")
        func steer(_ files: [Int]?) throws -> TaskSteer {
            var fields: [String: Any] = ["id": 9, "task": 8, "attempt": 2, "text": "Look.", "created": 100.0,
                                         "request_id": guidance.requestID.uuidString.lowercased(), "client": "c"]
            if let files { fields["attachments"] = files.map { ["id": $0, "name": "mockup.png", "mime": "image/png",
                "size": 412, "sha256": String(repeating: "a", count: 64), "created": 1000.0] as [String: Any] } }
            return try JSONDecoder().decode(TaskSteer.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        #expect(try steer([3]).matches(guidance))
        #expect(try !steer([]).matches(guidance))
        #expect(try !steer(nil).matches(guidance))      // a hub before 1.223 dropped the file
        #expect(try !steer([3, 4]).matches(guidance))
        // A steer's file of a type that this app does not know (a later hub's) is checked where it opens, as a
        // message's is: the state that carries it is still read, so one file never stops the whole app.
        let later: [String: Any] = ["id": 9, "task": 8, "attempt": 2, "text": "Look.", "created": 100.0,
                                    "request_id": guidance.requestID.uuidString.lowercased(), "client": "c",
                                    "attachments": [["id": 3, "name": "photo.heic", "mime": "image/heic", "size": 412,
                                                     "sha256": String(repeating: "a", count: 64), "created": 1000.0]]]
        let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "gen-1", "time": 110.0, "agents": [], "tasks": [], "notes": [], "needs": [],
            "permissions": [], "messages": [], "reports": [], "steers": [later]]))
        #expect(state.steers?.first?.attachments?.first?.mime == "image/heic")
    }

    /// **The plus of a guidance shows only where the file reaches its task alone** (the owner's "Yes, build it" of 19
    /// November 2026 to the pictures): not on a hub that does not say it takes a steer's files (an older one dropped
    /// them in silence), not on a task that a person's conversation drives (that person could get what the file says),
    /// and for a worker or a lead whose Shell box is off only what its session opens: pictures and texts, or texts
    /// alone where its AI program shows no picture. Fails when the box takes a file that the hub drops, that a person
    /// reads, or that the agent cannot open, or when it limits the manager, whose session always has a shell.
    @Test func aGuidanceTakesFilesOnlyWhereItsOwnTaskAloneReadsThem() throws {
        func state(_ features: [String], conversation: Bool?, shell: Bool = true, role: String = "worker",
                   runtime: String = "claude") throws -> HubState {
            var task: [String: Any] = ["id": 8, "title": "Fix the form", "details": "", "done_when": "Fixed.",
                                       "needs": "none", "goal": "", "owner": "nova", "requester": "manager",
                                       "state": "working", "created": 1.0, "attempt": 1, "restarts": 0,
                                       "nudge_level": 0, "stop_sent": 0]
            if let conversation { task["from_conversation"] = conversation }
            let agent: [String: Any] = ["name": "nova", "role": role, "runtime": runtime, "can": shell ? ["shell"] : []]
            return try HubState.decode(JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": "gen-1", "time": 10.0, "agents": [agent], "tasks": [task], "notes": [],
                "needs": [], "permissions": [], "messages": [], "reports": [], "ui_features": features]))
        }
        let both = ["attachments", "steer_files"]
        let open = try state(both, conversation: false)
        #expect(open.tasks[0].guidanceTakesFiles(in: open) && open.tasks[0].guidanceFiles(in: open) == .any)
        for refused in [try state(["attachments"], conversation: false), try state(["steer_files"], conversation: false),
                        try state(both, conversation: true), try state(both, conversation: nil)] {
            #expect(!refused.tasks[0].guidanceTakesFiles(in: refused))
        }
        let closed = try state(both, conversation: false, shell: false)
        #expect(closed.tasks[0].guidanceTakesFiles(in: closed) && closed.tasks[0].guidanceFiles(in: closed) == .shown)
        let lead = try state(both, conversation: false, shell: false, role: "lead", runtime: "codex")
        #expect(lead.tasks[0].guidanceFiles(in: lead) == .shown)
        let grok = try state(both, conversation: false, shell: false, runtime: "grok")
        #expect(grok.tasks[0].guidanceFiles(in: grok) == .texts)
        let manager = try state(both, conversation: false, shell: false, role: "manager")
        #expect(manager.tasks[0].guidanceFiles(in: manager) == .any)
        let pictures = ["image/png", "image/jpeg"], texts = ["text/plain", "text/markdown", "text/csv", "application/json"]
        let neither = ["application/pdf", "application/zip", "image/heic", "text/html"]
        #expect((pictures + texts).allSatisfy(GuidanceFiles.shown.takes) && !neither.contains(where: GuidanceFiles.shown.takes))
        #expect(texts.allSatisfy(GuidanceFiles.texts.takes) && !(pictures + neither).contains(where: GuidanceFiles.texts.takes))
        #expect(["application/pdf", "application/zip"].allSatisfy(GuidanceFiles.any.takes))
    }
}
