import FleetCore
import Foundation
import CoreGraphics
import ImageIO
import Observation
import UniformTypeIdentifiers

/// **The share sheet's one state** (the owner's request of 11 November 2026: "when I am sharing a link, a post, an
/// image etc from any app, I can share it to Founderizer. Then, like in whatsapp, I choose which agent to share it to,
/// and also append a text message and send it").
///
/// It lists the agents that the app left for it (`SharedPlace`), so the list stands in the first frame with no read and
/// no Face ID. What was shared waits in the chosen agent's composer: a link or a text in the field, where the
/// owner writes his own line under it, and a picture or a file in the composer's row, as "+" stages one in a chat.
///
/// It sends as the chat sends: this phone's key from the keychain behind Face ID (only when the owner presses Send),
/// the hub's generation from `GET /ui/mobile`, each file up with its own number, then the message with its own
/// number. A send that the hub did not confirm keeps its numbers, so Send again never makes a second message; the sheet
/// closes when the hub confirms it.
@MainActor @Observable
final class ShareModel {

    /// The agent the owner chose, as the navigation stack holds it.
    var path: [String] = []
    /// The agents that take a message, by name, in the hub's order.
    private(set) var agents: [String] = []
    /// Every agent of the read, in the hub's order: the marks take their looks from it (`MarkTeam`).
    private(set) var team: [String] = []
    /// The app left no agents for this hub and the sheet reads the hub itself.
    private(set) var readingHub = false
    /// Why the sheet has no agents to offer, in the app's own words.
    private(set) var listProblem: String?

    /// The words of the message: what was shared as words, and the owner's own line under it.
    var text = ""
    /// The files that go with the message, at most four, in the order they were shared.
    private(set) var files: [ShareFile] = []
    /// The shared items are still being read.
    private(set) var taking = true

    private(set) var sending = false
    /// What the composer's one line says, or nil: a refusal or a send that the hub did not confirm, else a file that
    /// stayed out of what was shared.
    var note: (words: String, isWarning: Bool)? { sendNote ?? takeNote }
    private var sendNote: (words: String, isWarning: Bool)?
    private var takeNote: (words: String, isWarning: Bool)?

    /// The message that went to `pendingAgent` and that the hub has not confirmed: Send sends it again, with its own
    /// number. Its words and its files stand still meanwhile.
    private(set) var pending: PendingRequest?
    @ObservationIgnored private var pendingAgent: String?
    /// The hub generation that the files' numbers belong to.
    @ObservationIgnored private var filesDatabase: String?

    /// The hub that the app reads, or the built-in one before the app ever said.
    let hub: URL
    /// The app's own client label, so that the chat shows this message as this phone's; a share before the app ever
    /// ran gets one of its own.
    let installation: String
    private let client = MobileClient()
    /// This phone's key, once Face ID gave it for this sheet; dropped with the sheet.
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var keyTaken = false
    @ObservationIgnored private let finish: @MainActor () -> Void
    @ObservationIgnored private let leave: @MainActor () -> Void

    init(finish: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
        self.finish = finish
        leave = cancel
        let roster = SharedPlace.roster()
        hub = roster?.hubURL ?? (try! MobileClient.address(HubClient.defaultAddress))
        installation = roster?.installation ?? "founderizer-ios/1/\(UUID().uuidString.lowercased())"
        if let roster, !roster.team.isEmpty {
            show(roster.team.map { ($0.name, $0.title, $0.takesMessage) })
        }
    }

    /// The owner closed the sheet: nothing goes.
    func cancel() { leave() }

    // MARK: The agents

    /// The agents in the hub's order, each with its role and whether it takes a message.
    private func show(_ members: [(name: String, title: String?, takesMessage: Bool)]) {
        // Each agent's role, for every line that names an agent, as the app reads it.
        AgentNames.shared.read(members.map { ($0.name, $0.title) })
        team = members.map(\.name)
        agents = members.filter(\.takesMessage).map(\.name)
        listProblem = agents.isEmpty ? "No agents yet" : nil
    }

    /// The app left no agents (it has not read its hub since this build): the sheet reads the hub itself, with this
    /// phone's key when it holds one.
    func readAgentsIfNeeded() async {
        guard team.isEmpty, !readingHub else { return }
        readingHub = true
        defer { readingHub = false }
        do {
            let key = try await phoneKey()
            guard let read = try await client.snapshot(at: hub, key: key, database: nil, etag: nil) else {
                throw MobileError.invalidResponse
            }
            let snapshot = read.snapshot, features = Set(snapshot.ui_features ?? [])
            show(snapshot.agents.map { ($0.name, $0.title, snapshot.canChat(with: $0.name, features: features)) })
        } catch {
            listProblem = Self.words(error)
        }
    }

    /// A tap on an agent opens its composer, once: a second tap while it slides in opens no second page.
    func choose(_ agent: String) {
        guard path.isEmpty else { return }
        path = [agent]
    }

    /// The composer of one agent opened. A message that went to another agent and that the hub never confirmed stays
    /// that agent's: this agent gets a new message, with numbers of its own.
    func open(_ agent: String) {
        guard pendingAgent != agent else { return }
        pending = nil
        pendingAgent = nil
        sendNote = nil
    }

    // MARK: What was shared

    /// Reads what the app the owner shares from gave: links and words go into the field, pictures and files into the
    /// composer's row. The share sheet offers Founderizer only for what the hub takes (the activation rule in
    /// `Info.plist`), so a refusal here is a file that did not open or one more than a message carries.
    func take(_ items: [NSExtensionItem]) async {
        defer { taking = false }
        var words: [String] = []
        var refusal: String?
        for item in items {
            if let content = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty {
                words.append(content)
            }
            for provider in item.attachments ?? [] {
                do {
                    switch try await SharedItem.read(provider) {
                    case .words(let shared): words.append(shared)
                    case .file(let file):
                        guard files.count < MessageAttachment.perMessage else {
                            file.forget()
                            refusal = "A message carries at most \(MessageAttachment.perMessage) files."
                            continue
                        }
                        files.append(file)
                    case nil: break
                    }
                } catch {
                    refusal = refusal ?? ((error as? LocalizedError)?.errorDescription ?? "A file did not open.")
                }
            }
        }
        let shared = SharedItem.joined(words)
        // The owner writes his own line under what he shared, so the field ends with a new line for it; words that he
        // typed while the items were read stay under it.
        if !shared.isEmpty { text = shared + "\n" + text }
        if let refusal { takeNote = (refusal, true) }
    }

    func remove(_ file: ShareFile) {
        guard pending == nil, !sending else { return }
        file.forget()
        files.removeAll { $0.id == file.id }
        if takeNote?.words.hasPrefix("A message carries") == true { takeNote = nil }
    }

    // MARK: Sending

    /// The text as it goes: without the empty line at its end.
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A message carries words, or files, or both, and at most the hub's limit of words.
    var canSend: Bool {
        !taking && !sending && (!trimmed.isEmpty || !files.isEmpty) && trimmed.count <= Self.textLimit
    }

    /// The hub takes 1 to 16,000 characters in a message, as the app's composer counts them.
    static let textLimit = 16_000

    /// Sends the message to one agent and closes the sheet when the hub confirms it.
    func send(to agent: String) async {
        guard canSend else { return }
        open(agent)
        sending = true
        sendNote = nil
        defer { sending = false }
        var messageWent = false
        do {
            let key = try await phoneKey()
            guard let read = try await client.snapshot(at: hub, key: key, database: nil, etag: nil) else {
                throw MobileError.invalidResponse
            }
            let snapshot = read.snapshot, features = Set(snapshot.ui_features ?? [])
            if let words = snapshot.chatUnavailableWords(agent, features: features) {
                sendNote = (words, true)
                return
            }
            if !files.isEmpty, !features.contains("attachments") {
                sendNote = ("This hub needs an update before it takes files.", true)
                return
            }
            // A hub installed again since the files went up numbers everything from the start: nothing of the old
            // generation goes with a message of the new one.
            if filesDatabase != snapshot.db {
                for index in files.indices { files[index].attachmentID = nil }
                filesDatabase = snapshot.db
            }
            if pending?.database != snapshot.db { pending = nil }
            if pending == nil {
                for index in files.indices where files[index].attachmentID == nil {
                    let file = files[index]
                    let sent = try await client.upload(try file.bytes(), name: file.name, mime: file.mime,
                                                       requestID: file.id, client: installation, hub: hub, key: key,
                                                       database: snapshot.db)
                    files[index].attachmentID = sent.id
                }
                pending = PendingRequest(hub: hub, database: snapshot.db, client: installation,
                                         recipient: features.contains("direct_chat") ? agent : nil,
                                         attachments: files.compactMap(\.attachmentID), text: trimmed)
                pendingAgent = agent
            }
            guard let request = pending else { return }
            messageWent = true
            _ = try await client.send(request, key: key)
            pending = nil
            pendingAgent = nil
            for file in files { file.forget() }
            finish()
        } catch {
            if case MobileError.refusal(422, _, _) = error {
                // The hub does not say which words are a login: the words go from this phone, as the app's do.
                pending = nil
                text = ""
                sendNote = ("The hub refused registered login text. The text is gone from this phone.", true)
            } else if let error = error as? MobileError, error.isDefinitive {
                pending = nil
                sendNote = (error.notSentWords, true)
            } else if messageWent {
                // One failure, one way on: Send again keeps the number, so it never sends twice.
                sendNote = ("Your hub did not confirm it. Sending it again does not send it twice.", true)
            } else {
                sendNote = (Self.words(error), true)
            }
        }
    }

    /// This phone's key, behind Face ID, once for this sheet; nil on a phone that holds none (the owner's own Mac
    /// address, as the simulator reads it, needs none).
    private func phoneKey() async throws -> String? {
        if keyTaken { return key }
        let holder = DeviceKey()
        if holder.has { key = try await holder.key(reason: "Founderizer uses this phone's own key to reach the hub.") }
        keyTaken = true
        return key
    }

    /// An error in the app's own words.
    static func words(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Your hub did not answer. Check that its server is on."
    }
}

/// One file that the owner shared: its bytes wait in this sheet's own folder until they go up, with their own number.
struct ShareFile: Identifiable, Sendable {
    /// The number of its upload, so a send again is one file on the hub and never a second one.
    let id: UUID
    let name: String
    let mime: String
    let size: Int
    /// A small picture of it, for the composer's row.
    let thumbnail: CGImage?
    /// Where its bytes wait.
    let place: URL
    /// What the hub called it, once it went up.
    var attachmentID: Int?

    func bytes() throws -> Data { try Data(contentsOf: place, options: [.mappedIfSafe]) }

    func forget() { try? FileManager.default.removeItem(at: place) }

    var isPicture: Bool { mime.hasPrefix("image/") }
}

/// What one shared item is, read from its provider. A provider is not safe to send across threads, so it stays on the
/// main actor: each read starts there and its handler gives back only plain values (words, bytes).
@MainActor
enum SharedItem {
    case words(String)
    case file(ShareFile)

    /// The types that the hub takes as files, as the share sheet names them, each with the type the hub knows it by.
    /// A picture goes as the app's "+" sends one (`imageForSending`): a PNG as it is, every other picture as a JPEG of
    /// a size that travels well.
    static let fileTypes: [(type: UTType, mime: String)] = [
        (.pdf, "application/pdf"), (.zip, "application/zip"), (.commaSeparatedText, "text/csv"),
        (.json, "application/json"), (UTType("net.daringfireball.markdown") ?? .plainText, "text/markdown"),
    ]

    /// Reads one provider. A link to a web page and words become words; a picture and a file of a type the hub takes
    /// become a file; anything else is nil, and the share sheet never offers Founderizer for it.
    static func read(_ provider: NSItemProvider) async throws -> SharedItem? {
        for (type, mime) in fileTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            return .file(try await file(provider, type: type, mime: mime))
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return .file(try await picture(provider))
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           case .link(let link)? = try await loaded(provider, .url) {
            return .words(link)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            // A text that an app shares is words; a text file from Files is a file.
            switch try await loaded(provider, .plainText) {
            case .words(let words)?: return .words(words)
            case .link(let link)?: return .words(link)
            case .fileURL?: return .file(try await file(provider, type: .plainText, mime: "text/plain"))
            case nil: break
            }
        }
        return nil
    }

    /// The words that were shared, each once: an app that shares a post's text and its link gives the link twice.
    static func joined(_ words: [String]) -> String {
        var kept: [String] = []
        for word in words.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !word.isEmpty {
            if kept.contains(where: { $0.contains(word) }) { continue }
            kept.removeAll { word.contains($0) }
            kept.append(word)
        }
        return kept.joined(separator: "\n")
    }

    /// What `loadItem` gave, as a value that may cross threads.
    private enum Loaded: Sendable { case link(String), words(String), fileURL }

    private static func loaded(_ provider: NSItemProvider, _ type: UTType) async throws -> Loaded? {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Loaded?, Error>) in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error { return done.resume(throwing: error) }
                switch item {
                case let url as URL: done.resume(returning: url.isFileURL ? .fileURL : .link(url.absoluteString))
                case let words as String: done.resume(returning: .words(words))
                case let data as Data:
                    if type == .url, let url = URL(dataRepresentation: data, relativeTo: nil), url.scheme != nil {
                        done.resume(returning: url.isFileURL ? .fileURL : .link(url.absoluteString))
                    } else {
                        done.resume(returning: String(data: data, encoding: .utf8).map { .words($0) })
                    }
                default: done.resume(returning: nil)
                }
            }
        }
    }

    private static func picture(_ provider: NSItemProvider) async throws -> ShareFile {
        let stem = provider.suggestedName.map { ($0 as NSString).deletingPathExtension }
        let data = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, Error>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data { done.resume(returning: data) } else { done.resume(throwing: error ?? AttachmentError.bytes) }
            }
        }
        return try await prepared(picture: data, stem: stem)
    }

    /// A picture made ready off the main thread: a photo of an iPhone is HEIC and large, and it becomes a JPEG.
    nonisolated private static func prepared(picture data: Data, stem: String?) async throws -> ShareFile {
        let picture = try MessageAttachment.imageForSending(data)
        let ext = picture.mime == "image/png" ? "png" : "jpg"
        let name = (stem?.isEmpty == false ? stem! : "photo") + "." + ext
        return try keep(picture.data, name: name, mime: picture.mime)
    }

    private static func file(_ provider: NSItemProvider, type: UTType, mime: String) async throws -> ShareFile {
        let suggested = provider.suggestedName
        // The provider's file is gone when its handler returns, so its bytes are read inside it.
        let (data, fileName) = try await withCheckedThrowingContinuation {
            (done: CheckedContinuation<(Data, String), Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url, let data = try? Data(contentsOf: url) else {
                    return done.resume(throwing: error ?? AttachmentError.bytes)
                }
                done.resume(returning: (data, url.lastPathComponent))
            }
        }
        return try await kept(data, name: suggested ?? fileName, mime: mime)
    }

    nonisolated private static func kept(_ data: Data, name: String, mime: String) async throws -> ShareFile {
        try keep(data, name: name, mime: mime)
    }

    /// Writes the bytes into this sheet's own folder and gives the file that waits there.
    nonisolated private static func keep(_ data: Data, name: String, mime: String) throws -> ShareFile {
        guard !data.isEmpty, data.count <= MessageAttachment.sizeLimit else { throw AttachmentError.tooLarge }
        let id = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let place = folder.appendingPathComponent(id.uuidString.lowercased())
        try data.write(to: place, options: [.atomic, .completeFileProtection])
        let thumbnail = mime.hasPrefix("image/") ? MessageAttachment.thumbnail(data, maxPixels: 160) : nil
        return ShareFile(id: id, name: MessageAttachment.safeName(name, mime: mime), mime: mime, size: data.count,
                         thumbnail: thumbnail, place: place)
    }
}
