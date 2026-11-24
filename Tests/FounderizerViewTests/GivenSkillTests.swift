import AppKit
import FleetCore
import Testing
import Vision
@testable import Founderizer

/// **A skill that he gives an agent, in the chat's box** (owner feature `message_skills`; the owner's "Yes, as drawn" of
/// 22 November 2026: the Mac's chat box takes a skill's folder, and its ZIP with the plus; the chip shows a bolt and
/// the skill's name; and of 21 November to the badge with the bolt in his message). The real store and chat, on a
/// stand-in hub that keeps what the app sends (`LoopbackHub`). Example names only.
@Suite(.serialized, .timeLimit(.minutes(3))) struct GivenSkillTests {
    private static let now = Int(Date().timeIntervalSince1970)
    /// The box of the chat with Marketing.
    @MainActor private static var box: String { FleetStore.stageKey(agent: "atlas") }

    private static func reading(features: [String], messages: [[String: Any]] = [],
                                db: String = "skills-\(UUID().uuidString)") throws -> Data {
        let agents: [[String: Any]] = [
            ["name": "manager", "role": "manager", "title": "Fleet Manager", "runtime": "claude", "can": [], "placed": true],
            ["name": "atlas", "role": "worker", "title": "Marketing", "runtime": "claude", "can": [], "placed": true]]
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": db, "time": now, "agents": agents, "tasks": [],
            "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": messages,
            "reports": [], "ui_features": ["direct_chat", "attachments"] + features] as [String: Any])
    }

    /// A store of the app that reads `hub`, after the hub's first answer: it can write. `kept`: the files that its box
    /// kept from an earlier launch, with their bytes; each goes up again before its send (`forgetFilesOfAnotherFleet`).
    @MainActor private static func store(on hub: LoopbackHub, _ state: Data,
                                         kept: [(file: FleetStore.StagedFile, bytes: Data)] = []) throws -> FleetStore {
        _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        if !kept.isEmpty {
            let place = AppFolders.support.appendingPathComponent("Founderizer/staged")
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            for (file, bytes) in kept {
                try bytes.write(to: place.appendingPathComponent(file.requestID.uuidString.lowercased()))
            }
            AppDefaults.store.set(try JSONEncoder().encode([box: kept.map(\.file)]), forKey: "stagedFiles")
        }
        let store = FleetStore()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.canWrite }
        store.destination = .agent("atlas")
        return store
    }

    /// Three folders and a ZIP in a test's own place: a skill's folder (its SKILL.md names it acme-web), a
    /// folder with no SKILL.md, and a ZIP of a skill whose front matter names it seo-radar-kit.
    private static func places() throws -> (root: URL, skill: URL, plain: URL, zip: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("given-skill-\(UUID().uuidString)")
        let skill = root.appendingPathComponent("acme-folder"), plain = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data("---\nname: acme-web\ndescription: Deploy the example web app.\n---\nSteps.\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("not a skill\n".utf8).write(to: plain.appendingPathComponent("notes.md"))
        let other = root.appendingPathComponent("radar")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("---\nname: seo-radar-kit\ndescription: Read the example site's search ranks.\n---\n".utf8)
            .write(to: other.appendingPathComponent("SKILL.md"))
        let zip = root.appendingPathComponent("radar.zip")
        try SkillPackage.zip(folder: other, atMost: 1_000_000).write(to: zip)
        return (root, skill, plain, zip)
    }

    /// Where the chat's column shows these words, read as a person reads them (Vision, English), within 20 s: right of
    /// the sidebar, which shows his newest words too, and left of the panel; with the width of the words found.
    @MainActor private static func place(of words: String, in window: NSWindow) throws -> CGRect? {
        guard let view = window.contentView else { return nil }
        let end = Date().addingTimeInterval(20)
        repeat {
            view.layoutSubtreeIfNeeded()
            view.display()
            if let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: picture)
                if let image = picture.cgImage {
                    let reading = VNRecognizeTextRequest()
                    reading.recognitionLevel = .accurate
                    reading.recognitionLanguages = ["en-US"]
                    reading.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: image).perform([reading])
                    let column = (FleetStyle.sidebarWidth + 20)...(view.bounds.width - FleetStyle.panelWidth - 20)
                    for line in reading.results ?? [] {
                        for text in line.topCandidates(3) {
                            guard let range = text.string.range(of: words),
                                  let box = try? text.boundingBox(for: range)?.boundingBox else { continue }
                            let found = CGRect(x: box.minX * view.bounds.width, y: box.minY * view.bounds.height,
                                               width: box.width * view.bounds.width, height: box.height * view.bounds.height)
                            if column.contains(found.midX) { return found }
                        }
                    }
                }
            }
            ViewHost.turn(0.3)
        } while Date() < end
        return nil
    }

    struct Staged: Sendable {
        var skill: String?, name: String?, isZip = false, plainWords: String?, needWords: String?, zipSkill: String?
        var chipShowsSkill = false, chipShowsZip = true, badgeShows = false, badgeOnTheLine = false, badgeBefore = false
        var offSkill: String??, offFolderWords: String?, offZipSkill: String??
    }

    /// The bug that this catches: a dropped skill's folder gets the words of a type that the hub does not take, or
    /// is staged as a ZIP with no skill in it; a folder with no SKILL.md, or a folder dropped on a request's answer box,
    /// is taken as a skill; the chip shows the ZIP's name in place of the skill's; a ZIP of a skill from the plus stays
    /// a file; his message that gave a skill with no words shows nothing in the chat; the badge of a skill that he gave
    /// with words stands over them, or over their first word, and not before them on their first line, as his picture
    /// drew it; and on a hub that does not list the feature, a folder is taken or a ZIP is staged as a skill.
    @Test func aSkillsFolderOrZipIsOneSkillInTheChatsBoxAndAnyOtherFolderIsAsBefore() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 150) { () -> Staged in
            var seen = Staged()
            let places = try Self.places()
            defer { try? FileManager.default.removeItem(at: places.root) }
            // his message of yesterday that gave a skill, with no words
            let gave: [String: Any] = ["request_id": UUID().uuidString.lowercased(), "recipient": "atlas", "kind": "message",
                                       "text": "", "event_id": 3, "created": Double(Self.now - 600), "client": "c",
                                       "skills": [["give": 7, "name": "seo-radar-kit", "commit": "abc"]]]
            let db = "skills-\(UUID().uuidString)"
            // and his message that gave a skill with his words: its badge on their first line, before them
            let gaveWithWords: [String: Any] = ["request_id": UUID().uuidString.lowercased(), "recipient": "atlas",
                                                "kind": "message", "text": "Launch with it today", "event_id": 4,
                                                "created": Double(Self.now - 500), "client": "c",
                                                "skills": [["give": 8, "name": "film-kit", "commit": "abd"]]]
            let state = try Self.reading(features: [SkillPackage.feature], messages: [gave, gaveWithWords], db: db)
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            let store = try Self.store(on: hub, state)
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            seen.badgeShows = try ViewHost.middle(of: "seo-radar-kit", in: window) != nil
            if let badge = try Self.place(of: "film-kit", in: window), let words = try Self.place(of: "Launch", in: window) {
                seen.badgeOnTheLine = abs(badge.midY - words.midY) < 5
                seen.badgeBefore = badge.maxX < words.minX
            }

            Task { await store.stage(contentsOf: places.skill, for: Self.box) }
            ViewHost.turn(20) { store.stagedFiles(for: Self.box).count == 1 }
            let file = store.stagedFiles(for: Self.box).first
            seen.skill = file?.skill
            seen.name = file?.name
            seen.isZip = file.flatMap { KeptFile.bytes(of: store.stagedURL($0), atMost: 1_000_000) }
                .map(SkillPackage.isSkill) ?? false
            seen.chipShowsSkill = try ViewHost.middle(of: "acme-web", in: window) != nil
            seen.chipShowsZip = try ViewHost.middle(of: "acme-folder.zip", in: window, seconds: 1) != nil

            Task { await store.stage(contentsOf: places.plain, for: Self.box) }
            ViewHost.turn(10) { store.fileError(for: Self.box) != nil }
            seen.plainWords = store.fileError(for: Self.box)
            let need = FleetStore.stageKey(need: 7)
            Task { await store.stage(contentsOf: places.skill, for: need) }
            ViewHost.turn(10) { store.fileError(for: need) != nil }
            seen.needWords = store.stagedFiles(for: need).isEmpty ? store.fileError(for: need) : "staged"
            Task { await store.stage(contentsOf: places.zip, for: Self.box) }
            ViewHost.turn(20) { store.stagedFiles(for: Self.box).count == 2 }
            seen.zipSkill = store.stagedFiles(for: Self.box).last?.skill
            ViewHost.turn(20) { store.uploading.isEmpty }
            for file in store.stagedFiles(for: Self.box) { store.removeStaged(file, for: Self.box) }

            // a hub that does not list the feature: a folder is a type that it does not take, and a ZIP is a file
            let off = try Self.reading(features: [], messages: [gave], db: db)
            hub.give(off)
            Task { await store.refresh() }
            ViewHost.turn(10) { store.state?.ui_features?.contains(SkillPackage.feature) == false }
            store.setFileError(nil, for: Self.box)
            Task { await store.stage(contentsOf: places.skill, for: Self.box) }
            ViewHost.turn(10) { store.fileError(for: Self.box) != nil || !store.stagedFiles(for: Self.box).isEmpty }
            seen.offFolderWords = store.stagedFiles(for: Self.box).isEmpty ? store.fileError(for: Self.box) : "staged"
            Task { await store.stage(contentsOf: places.zip, for: Self.box) }
            ViewHost.turn(20) { !store.stagedFiles(for: Self.box).isEmpty }
            seen.offZipSkill = store.stagedFiles(for: Self.box).first.map(\.skill)
            seen.offSkill = store.stagedFiles(for: Self.box).first.map { store.skillName(of: $0, in: Self.box) }
            return seen
        }
        #expect(seen.badgeShows)
        // his picture: the badge on the first line of his words, before them, and not over them
        #expect(seen.badgeOnTheLine && seen.badgeBefore)
        #expect(seen.skill == "acme-web" && seen.name == "acme-folder.zip" && seen.isZip)
        #expect(seen.chipShowsSkill && !seen.chipShowsZip)
        #expect(seen.plainWords == MessageAttachment.typeWords(office: false))
        #expect(seen.needWords == MessageAttachment.typeWords(office: false))
        #expect(seen.zipSkill == "seo-radar-kit")
        #expect(seen.offFolderWords == MessageAttachment.typeWords(office: false))
        #expect(seen.offZipSkill == .some(nil) && seen.offSkill == .some(nil))
        #expect(screen.stayedHis)
    }

    /// What one send gave the hub, and what the app kept after the hub's answer.
    struct Sent: Sendable {
        var skills: [[String: Int]]?, attachments: [Int]?, text: String?
        var draftKept = false, refused = false, chipFailed = false, sendWaits = false, stillStaged = false
        /// The sends of the message, and whether each had the same request id and body as the first.
        var sends = 0, sameEachTime = false
        /// The hub's receipt ended the request, and the box has neither the skill nor the words any more.
        var written = false, boxEmpty = false
    }

    /// The hub of each case: whether it lists the feature, and its answer to the message.
    enum Hub: String, Sendable, CaseIterable {
        case refusesTheGift, before, busy, landed
    }

    /// **The message gives the skill only to a hub that lists the feature**: `skills: [{"give": <its number>}]`, and
    /// the number is not also in `attachments`; on a hub before it, the same ZIP goes as a file, as before. **A gift that
    /// the hub refuses (a 422 with `refused_gift`) is refused as any message is**: his words stay in the box, the request
    /// waits for Discard with the hub's words, and the skill's chip says that it did not go. **A 409 of a gift (it can
    /// follow a commit that landed) sends the same request again**, with its id, its words and its skill, a counted
    /// number of times, and the skill stays in the box as it was; **after a 502, the same request again is the message
    /// that the hub writes**, and the box empties. The bug that this catches: a hub without the feature
    /// refuses a field that it does not know, and his message is not sent; the agent gets the skill twice, as a gift
    /// and as a file; a gift's refusal is read as login text in his words, which empties every draft of his; Send gives
    /// the refused skill again, and again; a retry on a 409 alone leaves a gift that landed before a 502 with no message;
    /// or a gift that landed is never written as his message, or goes as a file.
    @Test func theMessageGivesTheSkillOnlyToAHubThatListsTheFeature() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 120) { () -> [Hub: Sent] in
            var seen: [Hub: Sent] = [:]
            FleetStore.giftPause = .milliseconds(50)
            defer { FleetStore.giftPause = .seconds(2) }
            for kind in Hub.allCases {
                let state = try Self.reading(features: kind == .before ? [] : [SkillPackage.feature])
                let hub = try LoopbackHub(state: state)
                defer { hub.stop() }
                switch kind {
                case .refusesTheGift:
                    hub.answer("POST", "/ui/messages") { _ in (status: 422, body: Data(
                        #"{"error":"run.sh is a link. A skill holds plain files only.","refused_gift":41}"#.utf8)) }
                case .busy:
                    hub.answer("POST", "/ui/messages") { _ in (status: 409, body: Data(
                        #"{"error":"The skill acme-web of Marketing changed while the hub gave it. Give it again.","refused_gift":41}"#.utf8)) }
                case .before: break     // 404, as a hub answers a route that it does not have
                case .landed: break     // below: its receipt names the request's own id
                }
                // the skill's ZIP, kept from an earlier launch: it goes up again first, and the hub names it 41
                let bytes = Data("PK example skill bytes".utf8)
                let file = FleetStore.StagedFile(requestID: UUID(), name: "acme-folder.zip", mime: "application/zip",
                                                 size: bytes.count, attachmentID: 41, hubCreated: Double(Self.now),
                                                 skill: "acme-web")
                let uploaded = try JSONSerialization.data(withJSONObject: [
                    "id": 41, "name": "acme-folder.zip", "mime": "application/zip", "size": bytes.count,
                    "sha256": MessageAttachment.digest(bytes), "created": Double(Self.now)] as [String: Any])
                hub.answer("POST", "/ui/attachments") { _ in (status: 200, body: uploaded) }
                let store = try Self.store(on: hub, state, kept: [(file, bytes)])
                defer { try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer")) }
                if kind == .landed {
                    // a 502 after the gift's commit landed, then the message written with the same request again
                    let client = store.installation
                    hub.answer("POST", "/ui/messages") { [unowned hub] request in
                        guard hub.requests.filter({ $0.method == "POST" && $0.path == "/ui/messages" }).count > 1 else {
                            return (502, Data(#"{"error":"The hub wrote the skill acme-web of Marketing, but cannot read now whether it is yours. Give it again.","refused_gift":41}"#.utf8))
                        }
                        let sent = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]) ?? [:]
                        let receipt: [String: Any] = [
                            "ok": true, "request_id": sent["request_id"] ?? "", "event_id": 9, "created": Double(Self.now),
                            "read_at": NSNull(), "replayed": false, "client": client, "recipient": "atlas",
                            "replaces_request_id": NSNull(), "attachments": [],
                            "skills": [["give": 41, "name": "acme-web", "commit": "abc", "beside": 0]]]
                        return (200, (try? JSONSerialization.data(withJSONObject: receipt)) ?? Data())
                    }
                }
                store.setDraft("Use it for the launch", for: "atlas")
                Task { await store.send() }
                ViewHost.turn(10) { hub.requests.contains { $0.method == "POST" && $0.path == "/ui/messages" } }
                ViewHost.turn(10) { !store.sending && (store.pending?.refusal != nil || store.pending == nil) }
                let posts = hub.requests.filter { $0.method == "POST" && $0.path == "/ui/messages" }
                let body = posts.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.body.utf8)) as? [String: Any] }
                seen[kind] = Sent(skills: body?["skills"] as? [[String: Int]], attachments: body?["attachments"] as? [Int],
                                  text: body?["text"] as? String,
                                  draftKept: store.draft(for: "atlas") == "Use it for the launch",
                                  refused: store.pending?.refusal != nil,
                                  chipFailed: store.stagedFiles(for: Self.box).first?.failure != nil,
                                  sendWaits: store.filesAreWaiting(for: Self.box),
                                  stillStaged: store.stagedFiles(for: Self.box).first?.attachmentID == 41,
                                  sends: posts.count, sameEachTime: posts.allSatisfy { $0.body == posts.first?.body },
                                  written: store.pending == nil && store.sendError == nil,
                                  boxEmpty: store.stagedFiles(for: Self.box).isEmpty && store.draft(for: "atlas").isEmpty)
            }
            return seen
        }
        #expect(seen[.refusesTheGift]?.skills == [["give": 41]] && seen[.refusesTheGift]?.attachments == nil)
        #expect(seen[.refusesTheGift]?.text == "Use it for the launch")
        #expect(seen[.before]?.skills == nil && seen[.before]?.attachments == [41])
        // the gift's refusal: his words stay, the request waits for Discard, and the chip says that it did not go
        #expect(seen[.refusesTheGift]?.draftKept == true && seen[.refusesTheGift]?.refused == true)
        #expect(seen[.refusesTheGift]?.chipFailed == true && seen[.refusesTheGift]?.sendWaits == true)
        #expect(seen[.refusesTheGift]?.sends == 1)
        // a 409 of the gift: the same request again, as many times as the count, then refused; the skill stays as it was
        #expect(seen[.busy]?.sends == 3 && seen[.busy]?.sameEachTime == true)     // FleetStore.giftTries
        #expect(seen[.busy]?.skills == [["give": 41]] && seen[.busy]?.refused == true)
        #expect(seen[.busy]?.stillStaged == true && seen[.busy]?.chipFailed == false && seen[.busy]?.sendWaits == false)
        // a 502 after the commit landed: the same request again, once, and the hub's receipt ends it; the box is empty
        #expect(seen[.landed]?.sends == 2 && seen[.landed]?.sameEachTime == true && seen[.landed]?.skills == [["give": 41]])
        #expect(seen[.landed]?.written == true && seen[.landed]?.boxEmpty == true)
        #expect(screen.stayedHis)
    }
}
