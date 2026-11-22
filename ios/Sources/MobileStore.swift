import CoreGraphics
import FleetCore
import Foundation
import Observation
import UIKit
import UserNotifications

/// The three items of the bottom bar.
enum MobileTab: String, Hashable, CaseIterable { case chats, needs, tasks }

/// Where this phone's own key for the hub stands now.
enum KeyState: Equatable {
    /// This phone has no key. It sends no bearer token, which is right from the owner's own Mac address.
    case none
    /// A key is in the keychain and is not unlocked yet.
    case locked
    /// The key is in memory for as long as the app is in front.
    case ready
    /// The keychain did not give the key, in its own words.
    case failed(String)
}

/// The one state of Fleet Mobile: where the owner is, what the hub last said, this phone's key, and the request that
/// waits for its receipt.
///
/// It reads the phone's own routes (UI-API.md, "The owner's phone"): `GET /ui/mobile` for the heads of the whole
/// fleet with an `ETag`, and one page at a time for a conversation and for a task. It reads only while the app is in
/// front, every 10 seconds with a chat or a task open and every 30 seconds otherwise, so an unchanged fleet costs six
/// empty answers in a quiet minute. On a hub with the change signal (`live_changes`, UI-API.md 1.47) it also waits on
/// `GET /ui/wait` while it is in front, and reads the moment the hub says that something changed.
///
/// It writes as the Mac app writes, with the same four rules (MOBILE-APP.md 5.4 and 10): the request goes into the
/// Outbox **before** the send and keeps its number across launches; one request waits at a time; a refusal that is
/// not definitive keeps the request for Retry; and a 422 takes the refused text off the phone at once.
@MainActor @Observable
final class MobileStore {

    // MARK: Where the owner is

    var tab: MobileTab = .chats
    /// The Chats stack: an agent's chat and its own page over it, or Settings and Add this phone under it.
    var chatRoute: [ChatsRoute] = []
    /// The Tasks stack: the task whose page is open.
    var taskRoute: [Int] = []
    /// The chat on screen: the last page of the Chats stack, when that page is a chat.
    var openChat: String? {
        if case .chat(let name) = chatRoute.last { return name }
        return nil
    }
    /// The task whose page is on screen: the last page of the Chats stack, when a row of a chat opened a task
    /// (`ChatsRoute.task`), else the Tasks stack's.
    var openTask: Int? {
        if tab == .chats, case .task(let id) = chatRoute.last { return id }
        return taskRoute.last
    }
    /// A chat or a task is open, so the app reads more often.
    var detailIsOpen: Bool { openChat != nil || openTask != nil }
    /// Seconds between two reads. A waiting request reads often too, so its receipt shows soon.
    var readSeconds: Int { detailIsOpen || pending != nil ? 10 : Self.restingSeconds }
    /// The cadence of a tab with nothing waiting: the slowest one.
    static let restingSeconds = 30

    // MARK: What the hub said

    private(set) var snapshot: MobileSnapshot? {
        // Each agent's role, for every line of the app that names an agent (`AgentNames`), as on the Mac.
        didSet {
            AgentNames.shared.read((snapshot?.agents ?? []).map { ($0.name, $0.title) })
            // The heads that carry an ask as FleetCore's tasks, once for each reading: a chat reads them at every
            // frame (`asks(in:)`). A reading with no ask costs nothing.
            readAskTasks()
        }
    }
    /// **The ended heads of what he asked for in a chat** (`GET /ui/mobile/ended`), read while a chat is open, and again
    /// only when their mark changes: what he asked for in a chat stays there when its work ends, and the main read holds
    /// the last 20 that ended. Only the heads that carry an ask are kept, with the names of their asks. A hub with
    /// `ended_asks` (1.258) gives the heads of one chat's asks from a time on: the phone reads them for the chat that is
    /// open, from the oldest line that it holds of it, and keeps them by chat, so the read grows with what the phone
    /// holds and not with the fleet's history (on the first fleet, on 20 November 2026, every head was 840 KB, of which
    /// the phone kept 90 KB). A hub before that gives every head, kept under "".
    struct EndedAsks: Sendable {
        let mark: String
        /// The time from which the read covers the chat's messages; nil for a read of every head.
        let from: Double?
        let heads: [MobileTaskHead]
        let names: [String: String]
    }
    @ObservationIgnored private var endedAsks: [String: EndedAsks] = [:]
    private var endedHeads: [MobileTaskHead] { endedAsks.keys.sorted().flatMap { endedAsks[$0]!.heads } }
    private var endedNames: [String: String] {
        endedAsks.values.reduce(into: [:]) { names, read in names.merge(read.names) { first, _ in first } }
    }
    /// When a read of the ended heads last failed: the next one waits a minute.
    @ObservationIgnored private var endedFailed: Date?

    /// The tasks of the asks, from the open heads, the recent ones and every ended one that the phone read.
    private func readAskTasks() {
        let open = (snapshot?.tasks ?? []) + (snapshot?.recent ?? [])
        var seen = Set<Int>()
        let heads = (open + endedHeads).filter { seen.insert($0.id).inserted }
        askIDs = Set(heads.compactMap { $0.ask?.lowercased() }.filter { !$0.isEmpty })
        askTasks = askIDs.isEmpty ? [] : heads.filter { ($0.ask ?? "").isEmpty == false }.compactMap(\.fleetTask)
        askRowsKept = [:]
    }

    /// Reads the ended heads while a chat is open, on a hub that names asks, when their mark moved since the last read
    /// of them: only a chat draws them. **It is never the reading's fault**: a read that fails says nothing, keeps what
    /// the phone had, and is tried again a minute later, so a slow or large answer never makes the hub look away.
    private func readEnded(hub requested: URL, database: String) async {
        guard let chat = openChat, features.contains("asks"), features.contains("mobile_ended"),
              let mark = snapshot?.ended_mark, endedFailed.map({ Date().timeIntervalSince($0) > 60 }) ?? true
        else { return }
        let scoped = features.contains("ended_asks")
        guard let read = Self.endedRead(endedAsks, chat: chat, lines: chatItems[chat], mark: mark, scoped: scoped)
        else { return }
        let (place, from) = read
        do {
            let page = try await client.ended(at: requested, key: key, database: database, chat: scoped ? chat : nil,
                                              from: from ?? 0)
            guard requested == hub, snapshot?.db == database else { return }
            if scoped { endedAsks[""] = nil }           // the read of every head of a hub before its update
            endedAsks[place] = EndedAsks(mark: page.mark, from: from,
                                         heads: page.tasks.filter { ($0.ask ?? "").isEmpty == false }, names: page.asked ?? [:])
            endedFailed = nil
            readAskTasks()
        } catch {
            endedFailed = Date()
        }
    }

    /// **Which read of the ended heads the open chat needs**, or nil for none. A hub with `ended_asks` (`scoped`): the
    /// heads of that chat's asks from the oldest line that the phone holds of it, read again when their mark moved or
    /// when the chat holds an older line than the read covered; with no line of the chat yet, none, because no row
    /// stands under a line. A hub before it: every head, once for each mark, under "".
    static func endedRead(_ held: [String: EndedAsks], chat: String, lines: [MobileChatItem]?, mark: String,
                          scoped: Bool) -> (place: String, from: Double?)? {
        let from = scoped ? lines?.map(\.ts).min() : nil
        if scoped && from == nil { return nil }
        let place = scoped ? chat : ""
        if let read = held[place], read.mark == mark, (read.from ?? -.infinity) <= (from ?? -.infinity) { return nil }
        return (place, from)
    }

    /// The open and the recent task heads as FleetCore's tasks, when one of them carries an ask, else none.
    @ObservationIgnored private var askTasks: [FleetTask] = []
    /// The asks that those heads name, by request_id in lower case.
    @ObservationIgnored private var askIDs: Set<String> = []
    /// Each chat's rows of its asks, with what they were made of: a chat draws again at each key that he types.
    @ObservationIgnored private var askRowsKept: [String: (made: String, rows: [String: [ChatAskRow]])] = [:]

    /// **Whether a message of these lines began an ask that the reading names**, or corrects one: a chat with none
    /// reads nothing more for its rows.
    func asksHere(_ lines: [MobileChatItem]) -> Bool {
        guard !askIDs.isEmpty else { return false }
        return lines.contains { line in
            line.kind == .message && (askIDs.contains(line.key.lowercased())
                                      || line.replaces.map { askIDs.contains($0.lowercased()) } == true)
        }
    }

    /// The rows of a chat's asks, made again only when the reading or what they are made of changes (`made`).
    func askRows(_ agent: String, made: String, make: () -> [String: [ChatAskRow]]) -> [String: [ChatAskRow]] {
        if let kept = askRowsKept[agent], kept.made == made { return kept.rows }
        let rows = make()
        askRowsKept[agent] = (made, rows)
        return rows
    }
    /// The tag of the body that `snapshot` came from. The next read sends it, and an unchanged fleet answers 304.
    @ObservationIgnored private var etag: String?
    /// When that body arrived, so that the ages on screen keep moving while the hub answers 304.
    @ObservationIgnored private var snapshotAt: Date?
    /// The hub's feature names, which say what the owner may write. They come with the compact read.
    private(set) var features: Set<String> = []
    private(set) var lastRead: Date?
    /// Why the last read failed, in the hub's words or the system's; nil after a read that worked.
    private(set) var readError: String?
    /// The hub itself refused the read, so reading again changes nothing until something else does. Then its own
    /// reason is what the owner needs: "unavailable" would be wrong, because the hub answered.
    private(set) var readWasRefused = false
    /// The hub's `auth` reason when it refused this device, so that Settings can offer the right next step.
    private(set) var authProblem: String?
    private(set) var refreshing = false
    /// **The first read of this launch is on its way and younger than a second.** Until it answers, the pages show
    /// the fleet this phone kept from its last launch as it was, or nothing of it when none was kept — no empty list,
    /// no line about the hub — so the fleet comes in one frame. The phone said "Reading the hub…" in orange over "No
    /// agents read" for 163 ms at every cold start.
    private(set) var firstReadWaits = true
    /// The time of the last read attempt. Every "how long ago" counts from it, so the words change when the app reads.
    private(set) var clock = Date()
    /// **A request of a read has taken more than its hold, and no read has answered since** (D-1 rule 2; fix round 3d,
    /// as the Mac's `readHeld`): the reading it reads again is old from then on, and looks old until a read answers.
    /// After a return, a read that took longer than its first second left the old reading looking current until it
    /// answered: up to its 10-second limit on a hub that holds it. It outlives a read that failed: the old look never
    /// goes before an answer.
    private(set) var readHeld = false
    /// How long the slowest request of the last read that answered took, and of the read on its way (`readHold`).
    @ObservationIgnored private var lastRequestTook: Duration = .zero
    @ObservationIgnored private var slowestRequest: Duration = .zero

    /// One agent's conversation, oldest first, and the cursor of its last page.
    private(set) var chatItems: [String: [MobileChatItem]] = [:]
    /// **The agent's words that came into its chat while he had it open**, by agent, with when they came: they fade in
    /// from then, as the Mac's reply does (fix round 2, item 75; fix round 3d). The items a chat opened with, and its
    /// first read, draw at once.
    private(set) var arrivals: [String: [String: Date]] = [:]
    /// The chat he left: what came while it was open is drawn at once the next time.
    func settleArrivals(of agent: String) { arrivals[agent] = nil }
    @ObservationIgnored private var chatCursor: [String: Double] = [:]
    /// The hub generation of the chats that this phone kept from its last launch, until a read names the generation.
    @ObservationIgnored private var keptDatabase: String?
    /// Where the chats are kept between launches (`keepChats`).
    private let chatsFile: URL
    /// Where the last compact read is kept between launches (`keepSnapshot`).
    private let snapshotFile: URL
    /// The newest line of each chat that a read in the background already took, so that one change is one read.
    @ObservationIgnored private var chatsReadAt: [String: Double] = [:]
    @ObservationIgnored private var chatsReading: Task<Void, Never>?
    /// One task with its notes, and the number of the last note that the phone has.
    private(set) var taskPages: [Int: MobileTaskPage] = [:]
    @ObservationIgnored private var taskCursor: [Int: Int] = [:]

    // MARK: This device

    var addressText: String
    private(set) var hub: URL
    private(set) var addressError: String?
    /// **The sample fleet is open** (`SampleFleet.swift`): the pages read it in place of a hub, until the owner leaves
    /// it or adds this phone. It lasts one launch: at its next start, a phone with no hub offers it again.
    private(set) var sample = false
    /// **This phone has no hub yet** (the owner's yes of 11 November 2026 to its picture): no address was ever set, and
    /// the sample is not open. It reads nothing and says nothing about a hub, and Chats says how to add one.
    var hasNoHub: Bool { !sample && hub == Self.noHub }
    /// **This phone is in no fleet**: it has no hub, or only the sample open, which a phone with no hub opens and which
    /// saves no address (`connect` saves the first one).
    private var inNoFleet: Bool { hasNoHub || (sample && Self.savedHub() == Self.noHub) }
    /// The built-in address, which names no hub (`HubClient.defaultAddress`).
    private static let noHub = try! MobileClient.address(defaultAddress)
    /// The client label of every write of this installation, as the plan asks (MOBILE-APP.md 6.3).
    let installation: String
    /// The keychain holder of this phone's own key. A check gives a holder of its own (`DeviceKey(account:)`), so that
    /// it never touches the key of an enrolled phone.
    let deviceKey: DeviceKey
    private(set) var keyState: KeyState = .locked
    /// The key while the app is in front. The keychain gives it once, behind the owner's presence; it is dropped when
    /// the app leaves the front and it is written nowhere else.
    @ObservationIgnored private var key: String?
    /// This phone as the hub names it, from `GET /ui/owner/devices`.
    private(set) var device: MobileDevice?

    // MARK: What the owner writes

    /// The request that waits for its receipt. It is read at each start, so a request that a force quit interrupted is
    /// never lost and never sent twice.
    private(set) var pending: PendingRequest?
    /// A message that the hub confirmed and that its chat has not read back yet. Its bubble stays until the message
    /// itself takes its place, in one frame: it went from the screen at the receipt and came back with the next read,
    /// one or two round trips later.
    private(set) var delivered: PendingRequest?
    /// **His answers in words that the hub confirmed and that their chat has not read back yet** (the owner, 14
    /// November 2026: "When I reply to a card, the conversation should follow!"): each is his message in the chat of
    /// the agent that asked, so its bubble stays from the send until that chat's read brings the message itself. A
    /// list of their own, beside `delivered`: one slot for both let a message that he sent next take an answer's
    /// bubble away, and an answer a message's (the review of that day).
    private(set) var deliveredAnswers: [PendingRequest] = []
    /// The request numbers of the answers in words that the hub took from this phone, until the hub or its generation
    /// changes: the chat knows by them that an answer's words are his own and not a pressed option's, also when they
    /// are an option's own words and the reading still has the request open (`ChatPage.entries`).
    private(set) var writtenAnswers: Set<String> = []
    /// Why the Outbox cannot be used. While it is set, nothing is sent: a request that cannot be saved could be sent
    /// twice.
    private(set) var storageError: String?
    /// The system's own words for that failure. VoiceOver reads them as the line's value; the line says in plain words
    /// what failed and what stays safe, and never carries the system's text.
    private(set) var storageErrorDetail: String?
    private(set) var sending = false
    /// What the owner must know about the last send, or nil after one that the hub confirmed.
    private(set) var sendError: String?
    /// How often the hub refused registered login text (422). A view that holds text of its own watches it.
    private(set) var secretRefusals = 0
    /// One draft for each agent, by its name, and one for each open item of Needs you, by its number. Both are kept
    /// across a force quit. The keys are the Mac app's, because `Outbox.rejectSecret` removes exactly these on a 422;
    /// this app has its own `UserDefaults`, so the two apps never share a draft.
    private(set) var drafts: [String: String]
    private(set) var answers: [String: String]
    /// The message of this phone that the owner corrects now, and the text of the correction. The correction is not a
    /// draft: it stands for one message, so it ends with the send or with Cancel.
    private(set) var correcting: MobileChatItem?
    var correctionText = ""
    /// The hub takes 1 to 16,000 characters in a message or an answer. A message that carries a file may have none.
    static let textLimit = 16_000
    /// Owner feature `attachments`: the files that the owner picked for each chat and each open item, by the key of
    /// that composer. They are kept across a force quit, as the drafts are; the bytes of one that is not on the hub
    /// yet wait beside the Outbox, so a crash in the middle loses nothing and sends nothing twice.
    private(set) var staged: [String: [StagedFile]] = [:]
    /// **The generation that the chats' drafts and the staged files belong to** (`readSnapshot`; the hub's `db`, random for
    /// each database), kept with them as "composersPlace": a file's number, and an item's, name another one in another
    /// generation. The hub's address is not part of it: the same generation at another form of the address (a new code
    /// link, a restore to a new server that keeps the database, the address typed another way) is the same fleet.
    @ObservationIgnored private var composersPlace: String?
    /// The chats' drafts that look like a key, which stand in memory only (`keepChatDrafts`), as they were when he
    /// opened the sample fleet: its end loads the drafts from the disk, and gives these back too.
    @ObservationIgnored private var keyDraftsBeforeSample: [String: String] = [:]
    /// The uploads that run now, by their own number.
    private(set) var uploading: Set<UUID> = []
    /// The bytes of the files that the pages show, by attachment number, newest last. A page reads them through
    /// `heldBytes(of:)`: a number can name another file.
    private var fileData: [Int: Data] = [:]
    /// The SHA-256 that the read of each file of `fileData` checked.
    @ObservationIgnored private var fileSums: [Int: String] = [:]
    private var fileOrder: [Int] = []
    /// A file as the reads and the marks name it: its number and its SHA-256, because the hub can give a number
    /// again after its file went, while this phone still shows a message that carried the file before.
    private struct FileKey: Hashable {
        let id: Int
        let sha256: String
        init(_ file: MessageAttachment) { id = file.id; sha256 = file.sha256 }
    }
    private var fileReads: Set<FileKey> = []
    /// One more at each new hub or hub generation (`forgetGeneration`): a read that one overtook keeps nothing, and a
    /// picture's tile that SwiftUI kept reads its file again.
    private(set) var filesGeneration = 0
    /// The pictures of the chats, drawn once from their bytes, by attachment number, each with the SHA-256 of its
    /// file: a chat draws them in its first frame, and its body never decodes an image.
    private var pictures: [Int: (sha256: String, image: CGImage)] = [:]
    @ObservationIgnored private var pictureOrder: [Int] = []
    /// The pictures that the background reads (`readPictures`) still have to bring, and the ones that did not come.
    @ObservationIgnored private var picturesWaiting: [MessageAttachment] = []
    @ObservationIgnored private var picturesFailed: Set<FileKey> = []
    /// The pictures whose bytes did not come, which their tile says, with its ↻ (D-7).
    private var notLoaded: Set<FileKey> = []
    /// This picture's bytes did not come: its tile says so, with its ↻.
    func didNotLoad(_ file: MessageAttachment) -> Bool { notLoaded.contains(FileKey(file)) }
    @ObservationIgnored private var picturesReading: Task<Void, Never>?
    @ObservationIgnored private var stagedThumbs: [UUID: CGImage] = [:]
    /// What went wrong with a file that the owner picked or opened, in plain words; nil when nothing did.
    private(set) var fileError: String?
    /// The system's own words for it, when it gave some, as the line's value for VoiceOver.
    private(set) var fileErrorDetail: String?
    /// The words of a file that did not go or did not open, and the system's words for VoiceOver; nil clears them.
    func fileFailed(_ words: String?, detail: String? = nil) {
        fileError = words
        fileErrorDetail = detail
    }
    /// The system's own words for an enrollment that failed on this phone, as the problem line's value for VoiceOver.
    private(set) var enrollDetail: String?

    /// The one client of every read and write. It answers the sample fleet's address itself (`SampleHub`), and only
    /// that address, so a request to the sample never leaves the phone, also when it was on its way at Leave.
    private let client = MobileClient(answering: SampleHub.host, with: SampleHub.self)
    private let outbox: Outbox
    /// Where the bytes of a file that is not on the hub yet wait, beside the Outbox.
    private let stagedDirectory: URL
    private var reading: Task<Void, Never>?
    /// The reads: one that is asked for while one is on its way runs once more, and none is dropped.
    private let reads = RunAgain()
    /// When the last read ended, on a clock that only goes forward. The read on the clock counts from it.
    @ObservationIgnored private var lastReadUptime: TimeInterval?
    /// One keychain read at a time. Asking twice puts two prompts on the screen and the owner answers neither.
    @ObservationIgnored private var unlocking = false
    private(set) var isForeground = false
    /// The time of the newest reply that the owner has seen from each agent, for one hub and one hub generation.
    private var seenReplies: [String: Double] = [:]
    @ObservationIgnored private var seenContext = ""

    init(deviceKey: DeviceKey = DeviceKey()) {
        self.deviceKey = deviceKey
        let address = UserDefaults.standard.string(forKey: "hubAddress") ?? MobileStore.defaultAddress
        // A phone with no hub shows an empty field with its example: the built-in address names no hub.
        addressText = UserDefaults.standard.string(forKey: "hubAddress") ?? ""
        hub = (try? MobileClient.address(address)) ?? (try! MobileClient.address(MobileStore.defaultAddress))
        installation = Self.installationLabel()
        if let seen = UserDefaults.standard.dictionary(forKey: "mobileRepliesSeen"), let context = seen["context"] as? String,
           let replies = seen["seen"] as? [String: Double] {
            seenContext = context; seenReplies = replies
        }
        drafts = UserDefaults.standard.dictionary(forKey: "agentDrafts") as? [String: String] ?? [:]
        answers = UserDefaults.standard.dictionary(forKey: "answerDrafts") as? [String: String] ?? [:]
        if let kept = UserDefaults.standard.data(forKey: "stagedFiles"),
           let files = try? JSONDecoder().decode([String: [StagedFile]].self, from: kept) {
            staged = files
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        outbox = Outbox(file: support.appendingPathComponent("FleetMobile/pending.json"))
        stagedDirectory = support.appendingPathComponent("FleetMobile/staged")
        chatsFile = support.appendingPathComponent("FleetMobile/chats.json")
        snapshotFile = support.appendingPathComponent("FleetMobile/snapshot.json")
        // The fleet as the last launch read it, so the first frame is the Chats list and not an empty page.
        if let kept = Self.keptSnapshot(snapshotFile, hub: hub) {
            snapshot = kept.snapshot
            etag = kept.etag
            snapshotAt = kept.at
            features = Set(kept.snapshot.ui_features ?? [])
            keptDatabase = kept.snapshot.db
        }
        if let kept = Self.keptChats(chatsFile, hub: hub), keptDatabase == nil || kept.db == keptDatabase {
            chatItems = kept.chats
            keptDatabase = kept.db
        }
        do { pending = try outbox.load() }
        catch {
            storageError = String(l10n: "Cannot read the saved request. Sending is blocked.")
            storageErrorDetail = error.localizedDescription
        }
        // A refused write of the sample fleet, which a launch that ended in the sample left: the sample is not kept.
        if let left = pending, left.hub == SampleHub.address, (try? outbox.clear(matching: left.requestID)) != nil {
            pending = nil
        }
        keyState = deviceKey.has ? .locked : .none
        // (chat drafts that an earlier build kept with words that look like a key leave the disk now)
        if drafts.values.contains(where: { KeyInText.contains($0) }) { Self.writeChatDrafts(drafts) }
        composersPlace = UserDefaults.standard.string(forKey: "composersPlace")
        shareRoster()
    }

    /// What the share extension last got from this app (`SharedPlace`), so that an unchanged roster is not written
    /// again at every read.
    @ObservationIgnored private var sharedRoster: SharedRoster?

    /// **Gives the share extension the hub, this installation's label and the agents** as this app reads them now:
    /// at the launch, after each read that brought a new body, and when the owner chose another hub. A roster that did
    /// not change is not written again, and the app that hosts the unit tests writes none. **The sample fleet gives it
    /// nothing**: a share never goes to an agent of the sample.
    private func shareRoster() {
        guard !Self.hostsTests, !sample else { return }
        let roster = SharedRoster(hub: hub, installation: installation, snapshot: snapshot, features: features)
        guard roster != sharedRoster else { return }
        if SharedPlace.keep(roster) { sharedRoster = roster }
    }

    /// The hub inside the owner's tailnet, as the Mac app knows it.
    static let defaultAddress = HubClient.defaultAddress

    /// The client label of this installation, made once and kept. A press on a notification sends it too, from a
    /// launch that may have no store (`PushNotifications.swift`), so it is made here and not inside the store.
    nonisolated static func installationLabel() -> String {
        let installationID = UserDefaults.standard.string(forKey: "installationID") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(installationID, forKey: "installationID")
        return "founderizer-ios/1/\(installationID)"
    }

    /// The hub that the owner chose, or the default one. A press on a notification answers there too.
    nonisolated static func savedHub() -> URL {
        let address = UserDefaults.standard.string(forKey: "hubAddress") ?? HubClient.defaultAddress
        return (try? MobileClient.address(address)) ?? (try! MobileClient.address(HubClient.defaultAddress))
    }

    // MARK: This phone's key

    /// Takes the key out of the keychain, behind the owner's presence, for as long as the app is in front. A phone
    /// with no key sends no token, which is what the owner's own Mac address needs.
    /// The read itself is the authority: a question that only asks whether an item is there answers differently on
    /// different iOS versions, and a phone that holds a key must never conclude from one that it holds none.
    func unlock() async {
        guard key == nil, !unlocking else { return }
        unlocking = true
        defer { unlocking = false }
        do {
            key = try await deviceKey.key(reason: String(l10n: "Founderizer uses this phone's own key to reach the hub."))
            keyState = key == nil ? .none : .ready
            // A phone that enrolled before the pings has no copy for a press on a notification yet.
            if let key { try? deviceKey.keepForPress(key) }
        } catch {
            key = nil
            keyState = .failed(error.localizedDescription)
        }
    }

    /// The keychain's own words for a key that did not open, as a value for VoiceOver, or nil.
    var keyDetail: String? {
        if case .failed(let reason) = keyState { return reason }
        return nil
    }

    /// A read of the hub can answer now: none failed, and nothing that only the owner can give (his key in hand, a new
    /// code) stands before it. A page shows its loading line only then: during an outage nothing is on its way, and
    /// the line over the page says why.
    var readCanCome: Bool { readError == nil && !keyIsHeldBack && authProblem == nil }

    /// This phone holds a key that is not in hand, so a read now would go without it and the hub would refuse it.
    /// Reading anyway would blame the hub for something only the owner's presence can give.
    var keyIsHeldBack: Bool {
        // A phone with no hub, or in the sample fleet, has no hub to reach with a key (a key outlives a reinstall).
        guard !hasNoHub, !sample else { return false }
        return switch keyState {
        case .locked, .failed: true
        case .none, .ready: false
        }
    }

    /// What the owner must know about the key, or nil while it is in hand or not wanted.
    var keyWords: String? {
        guard !hasNoHub, !sample else { return nil }
        return switch keyState {
        case .none, .ready: nil
        case .locked: String(l10n: "This phone's key is locked. Unlock it in Settings to read the hub.")
        // The keychain's own words go to VoiceOver (`keyDetail`), not on the screen.
        case .failed: String(l10n: "This phone's key did not open. Unlock it in Settings to read the hub.")
        }
    }

    /// The hub refused this phone, so the owner must enroll it again. The Settings page offers the step.
    var needsEnrollment: Bool {
        ["device_not_enrolled", "device_key_required", "device_key_mismatch"].contains(authProblem ?? "")
    }

    /// Takes the one-time code that the owner read in the Mac app and keeps the key that the hub gives for it. The
    /// hub gives that key once: if this phone cannot keep it, the code is spent and the owner makes a new one.
    /// Gives nil when the phone is enrolled, else what went wrong in the owner's words. With `read` false, the hub is
    /// not read after it: the Mac's code link reads when its join has ended (`openLink`).
    func enroll(code: String, bind: String? = nil, read: Bool = true) async -> String? {
        enrollDetail = nil
        guard MobileClient.normalizedCode(code) != nil else {
            return String(l10n: "A code is eight characters, as the Mac app shows it (XXXX-XXXX).")
        }
        do {
            // owner feature door_calls: the QR's one-time value binds a new signing key of this phone, which the Mac
            // then certifies. A typed code has none, and this phone's yes to a door call then stays unsigned.
            let signing = bind.flatMap { bind -> (key: String, binding: String)? in
                guard let key = try? DeviceSigningKey().make(),
                      let binding = DeviceBinding.binding(bind: bind, key: key) else { return nil }
                return (key, binding)
            }
            // owner feature recovery_copy (UI-API 1.95): a second key of this phone's, bound to the same value, that
            // the Mac seals the recovery code to. A copy of an earlier enrollment goes, as its key does.
            let recovery = signing == nil ? nil : bind.flatMap { bind -> (key: String, binding: String)? in
                RecoveryCodeCopy().remove()
                guard let key = try? DeviceRecoveryKey().make(),
                      let binding = DeviceBinding.binding(bind: bind, key: key) else { return nil }
                return (key, binding)
            }
            recoveryTaken = false
            let enrollment = try await client.enroll(at: hub, code: code, signing: signing, recovery: recovery)
            do { try deviceKey.save(enrollment.key) }
            catch {
                enrollDetail = error.localizedDescription
                return String(l10n: "This phone could not keep its key. Make a new code.")
            }
            key = enrollment.key
            keyState = .ready
            authProblem = nil
            readError = nil
            if read { await refresh() }
            return nil
        } catch let error as MobileError {
            return MobileError.enrollWords(error)
        } catch {
            enrollDetail = error.localizedDescription
            return String(l10n: "The hub did not take the code.")
        }
    }

    // MARK: The Mac's picture of a code

    /// A code that a link brought and that did not go, with what went wrong: Add this phone shows it in its field.
    /// `otherHub`: the link names another hub, which this phone, holding a key, does not follow.
    private(set) var linkedCode: (code: String, problem: String, otherHub: Bool)?

    /// **The Mac's code link is joining this phone to its hub, so nothing reads the hub until the enrolment has
    /// answered** (`openLink`). A read before it goes with no key, and the hub refuses it: a recording on an iPhone 18
    /// Pro (11 November 2026) showed "The hub wants this phone's key and the phone sent none" over Chats for the
    /// quarter second of the enrolment. The first read goes after it, with the key that it gave.
    @ObservationIgnored private var joining = false

    /// The Mac draws a code as the link `fleet://enroll?hub=…&code=…` (`OwnerDevices.enrollPayload`), and the
    /// phone's camera opens it here: the phone joins its fleet with nothing typed, and Chats opens. It did not open
    /// anything: the app registered no address of its own, and the eight characters were typed by hand.
    ///
    /// A phone that holds a key keeps its hub: a link to another hub would take the phone there and its key with it.
    /// That link opens Add this phone with its code and the reason, as a refusal of the hub does.
    ///
    /// **A phone in no fleet has no hub to keep** (F7, piece A1): a key that it holds is one that an earlier install
    /// left, because iOS keeps a keychain item when the app is deleted and the hub's address goes with the app. That
    /// key goes, with its signing key, as Forget the key takes them (`forgetKey`), and the phone joins as a new phone.
    /// After a reinstall every link was "another hub", and the phone could join no fleet at all. A key with no hub
    /// reaches nothing, so nothing is lost, and the old key never reaches the link's hub: it is gone before anything
    /// goes there, and the enrolment carries no key.
    func openLink(_ url: URL) async {
        guard let query = Self.enrollItems(url) else { return }
        let code = query.first { $0.name == "code" }?.value ?? ""
        let bind = query.first { $0.name == "bind" }?.value
        // No read of the hub until the enrolment has answered (`joining`): the move to the hub reads nothing.
        joining = true
        defer { joining = false }
        if let text = query.first(where: { $0.name == "hub" })?.value, let address = try? MobileClient.address(text),
           address != hub {
            if deviceKey.has {
                guard inNoFleet else {
                    showEnrollment(code, problem: String(l10n: "This code is for another hub. Forget this phone's key in Settings first."),
                                   otherHub: true)
                    return
                }
                // The key stays when the keychain refuses to let it go: the phone then follows no link, and the
                // field says why, as Forget the key in Settings does.
                if let failed = forgetKey() {
                    enrollDetail = failed.detail
                    showEnrollment(code, problem: failed.words, otherHub: true)
                    return
                }
            }
            addressText = text
            await connect()
        }
        let problem = await enroll(code: code, bind: bind, read: false)
        // The enrolment answered: the first read goes now, with the key that it gave, or after a refused code with
        // none, as it went before the enrolment.
        joining = false
        await refresh()
        if let problem {
            showEnrollment(code, problem: problem)
        } else {
            chatRoute = []
            tab = .chats
        }
    }

    /// **The two forms of the Mac's code link** (the owner's choice of 13 November 2026: one picture that opens this app
    /// on a phone that has it, and the App Store on a phone that does not). `fleet://enroll?hub=…&code=…` is the form
    /// of every Mac until then, and stays. `https://platform.founderizer.com/enroll#hub=…&code=…` is the new one: the
    /// phone's camera opens it here through the app's associated domain, and on a phone without the app in Safari,
    /// where the platform's `/enroll` sends it to the App Store. Its values ride in the fragment, which a browser never
    /// sends, so a phone without the app gives the website no code and no hub address. founderizer.com is the marketing
    /// site (the owner, 21 November 2026): the Macs make that form of the link until most phones have this build, so
    /// it opens here too until founderizer.com's /enroll goes, and the build after that takes it out. nil for any other
    /// link.
    nonisolated static func enrollItems(_ url: URL) -> [URLQueryItem]? {
        let scheme = url.scheme?.lowercased(), host = url.host()?.lowercased()
        if scheme == "fleet", host == "enroll" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        }
        guard scheme == "https", host == "platform.founderizer.com" || host == "founderizer.com",
              url.path() == "/enroll",
              let fragment = url.fragment(percentEncoded: true), !fragment.isEmpty else { return nil }
        // The fragment carries what the query carries in the first form; `URLComponents(string:)` refuses a bad
        // one with nil, where its `percentEncodedQuery` setter would stop the app.
        return URLComponents(string: "fleet://enroll?" + fragment)?.queryItems
    }

    private func showEnrollment(_ code: String, problem: String, otherHub: Bool = false) {
        linkedCode = (code, problem, otherHub)
        tab = .chats
        chatRoute = [.settings, .enroll]
    }

    /// Add this phone takes the code that a link brought, once.
    func takeLinkedCode() -> (code: String, problem: String, otherHub: Bool)? {
        defer { linkedCode = nil }
        return linkedCode
    }

    /// Takes this phone's key off the phone. The hub keeps its own record until the owner removes the device in the
    /// Mac app, so enrolling again needs a new code.
    /// Gives nil when the key is gone, else the plain words and the keychain's own words for VoiceOver.
    func forgetKey() -> (words: String, detail: String)? {
        do {
            try deviceKey.remove()
            try? DeviceSigningKey().remove()
            key = nil
            keyState = .none
            device = nil
            Self.setIconCount(0)
            return nil
        } catch { return (String(l10n: "Cannot take the key off this phone."), error.localizedDescription) }
    }

    // MARK: The read loop

    /// The app came to the front, or left it. It reads nothing in the background: a ping will bring it forward
    /// (MOBILE-APP.md 9). The key is taken once when it comes forward and dropped when it leaves.
    func setForeground(_ value: Bool) {
        // **His answers that wait with Undo go when the app leaves the front** (`releaseHeldAnswers`): it may end there,
        // and an answer that only waited in memory would be lost. Also in the app that hosts the unit tests, which
        // reads no hub for it.
        if !value { releaseHeldAnswers() }
        // **The app that hosts the unit tests reads no hub** (fix round 2): it starts with no hub address of a check's
        // own, and the built-in one is the owner's real hub, which no test may reach.
        guard !Self.hostsTests else { return }
        guard value != isForeground else { return }
        isForeground = value
        if value {
            // a key that the leave kept for the sends of his held answers goes now: each return asks for him again
            if keyKeptForSends { lockKey() }
            endLeaveTime()
            guard reading == nil else { return }
            // **A return to the front holds the old reading's marks for its read's first second, as the launch does**
            // (fix round 2, item 86; D-1 rule 2): back after more than 45 s the marks went grey and Settings said
            // "Last read" for the whole read, which answers in a moment. A reading whose read failed is not held: its
            // line stays.
            if Self.holdsOnReturn(hasReading: snapshot != nil, readFailed: readError != nil) { firstReadWaits = true }
            if firstReadWaits {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.firstReadWaits = false
                }
            }
            reading = Task { [weak self] in
                // No Face ID for a phone with no hub, or in the sample fleet: there is no hub to reach with the key.
                if self?.hasNoHub == false, self?.sample == false { await self?.unlock() }
                await self?.refresh()
                while !Task.isCancelled {
                    // The read on the clock counts from the last read, whoever ran it: a read that a change of the
                    // hub asked for takes the place of this one instead of adding one.
                    let wait = self?.untilRead ?? 30
                    do { try await Task.sleep(for: .seconds(max(wait, 0.1))) } catch { return }
                    if self?.untilRead == 0 { await self?.refresh() }
                }
            }
        } else {
            reading?.cancel()
            reading = nil
            chatsReading?.cancel()
            chatsReading = nil
            picturesReading?.cancel()
            picturesReading = nil
            stopWatching()
            lockKeyAtTheLeave()
        }
    }

    /// The key leaves memory, and the keychain must give it again: no write goes until it does (`canWrite`).
    func lockKey() {
        keyKeptForSends = false
        key = nil
        if keyState == .ready { keyState = .locked }
    }

    /// The key stays in memory past the leave only for the answers that wait to go (`lockKeyAtTheLeave`).
    @ObservationIgnored private var keyKeptForSends = false

    /// **The key goes as the app leaves the front, once each answer that waits to go has started with it**
    /// (`releaseHeldAnswers`, `wait`): a send reads the key in the turn that its wait ends (`transmit`), so the key
    /// stays only until no answer waits that can go in this leave (the store writes, or a send is on its way), not
    /// until the sends end. **iOS's time in the background lasts until the last of those sends has its answer**
    /// (`beginBackgroundTask`; the review of 21 November 2026): an app that iOS stops before the receipt finds its
    /// send failed at the return, and the request stays in the Outbox. Where iOS gives no time, the key goes at once,
    /// and **the first answer that waits is saved in the Outbox, not sent** (`keepFirstUnsent`); where the time ends,
    /// the key goes too. What still waits goes after the return and Face ID. The read that ends a send reads nothing
    /// meanwhile (`readOnce`).
    func lockKeyAtTheLeave() {
        guard !waitingPresses.isEmpty else { return lockKey() }
        endLeaveTime()
        if !backgroundTimeRefused {
            leaveTime = UIApplication.shared.beginBackgroundTask(withName: "Founderizer answer") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.isForeground, self.keyKeptForSends { self.lockKey() }
                    self.endLeaveTime()
                }
            }
        }
        guard leaveTime != .invalid else {
            keepFirstUnsent()
            return lockKey()
        }
        keyKeptForSends = true
        Task { [weak self] in
            while let self, self.keyKeptForSends, !self.waitingPresses.isEmpty, self.sending || self.canWrite {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let self, !self.isForeground, self.keyKeptForSends { self.lockKey() }
            while let self, self.leaveTime != .invalid, self.sending {
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.endLeaveTime()
        }
    }

    /// iOS's time in the background for the answers of a leave (`lockKeyAtTheLeave`), or `.invalid`.
    @ObservationIgnored private var leaveTime = UIBackgroundTaskIdentifier.invalid
    /// The app holds iOS's time in the background for the answers of a leave.
    var holdsBackgroundTime: Bool { leaveTime != .invalid }
    /// iOS gives no time in the background: a check sets it, as iOS does when it has none to give.
    @ObservationIgnored var backgroundTimeRefused = false

    private func endLeaveTime() {
        guard leaveTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(leaveTime)
        leaveTime = .invalid
    }

    /// **With no time in the background, the first answer that waits goes into the Outbox and is not sent** (the
    /// review of 21 November 2026): an end of the app there does not lose it, and at the return its card says "Not
    /// sent" with Try again, as a request that the app found in the Outbox at its start. The Outbox keeps one request
    /// at a time, so the answers behind it wait in memory, as a press that waits for the hub does on the Mac
    /// (`AnswerWaits`): an end of the app loses them, and their requests stay open on the hub for his answer.
    private func keepFirstUnsent() {
        guard canWrite, let first = waitingPresses.keys.sorted().first, let press = waitingPresses[first],
              stillMeant(press, for: first) else { return }
        waitingPresses[first] = nil
        pressWaits.removeValue(forKey: first)?.cancel()
        _ = saved(needID: first, press)
    }

    /// This process runs the unit tests (Xcode's test host): it reads nothing from any hub.
    nonisolated static var hostsTests: Bool { MobileClient.hostsTests }

    /// Whether a return to the front holds the marks of the reading it has for the first second of its read: a reading
    /// that is there and whose last read did not fail.
    static func holdsOnReturn(hasReading: Bool, readFailed: Bool) -> Bool { hasReading && !readFailed }

    /// **How long a request of a read may take before the reading it reads again is old** (D-1 rule 2): a second, **or
    /// twice the slowest request of the last read on a hub whose reads take longer** (fix round 3d, as the Mac's
    /// 71f8236), so that a hub that answers every request in 1.6 s does not turn the reading old in every read.
    static func readHold(after slowest: Duration) -> Duration { max(.seconds(1), slowest * 2) }

    /// One request of a read, with its hold: past `readHold`, the reading is old until a read answers (`readHeld`).
    private func holding<T>(_ requested: URL, _ request: () async throws -> T) async rethrows -> T {
        let began = ContinuousClock.now
        let hold = Task { [weak self, wait = Self.readHold(after: lastRequestTook)] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, self.hub == requested else { return }
            self.readHeld = true
        }
        defer { hold.cancel() }
        let value = try await request()
        slowestRequest = max(slowestRequest, ContinuousClock.now - began)
        return value
    }

    /// **A first reading that comes just after the loading line showed waits until the line has stood half a
    /// second** (the Mac's `settle`; fix round 2, items 84 and 104): shown at one second, the line stays until one and a
    /// half. A reading that comes inside the first second, when no line showed, goes at once.
    static func settle(since start: ContinuousClock.Instant) async {
        // **From the frame the line's words first drew** (fix round 3, item 43, as the Mac's item 14): counted from the
        // read's start, a line that drew a few frames after its second stood 496 ms.
        guard ContinuousClock.now - start > .seconds(1) else { return }
        var until = start + .milliseconds(1500)
        while true {
            if let shown = LoadingLine.shownAt, shown >= start { until = max(until, shown + .milliseconds(500)) }
            guard ContinuousClock.now < until else { return }
            do { try await Task.sleep(until: until, clock: .continuous) } catch { return }
        }
    }

    /// When a page that had nothing to draw began to wait for its first reading: the fleet's, a chat's, a task's.
    @ObservationIgnored private var fleetSince: ContinuousClock.Instant?
    @ObservationIgnored private var chatSince: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var taskSince: [Int: ContinuousClock.Instant] = [:]

    /// A chat or a task opened with nothing of it read: its loading line's second counts from now.
    func beginWait(chat agent: String) { if chatItems[agent] == nil, chatSince[agent] == nil { chatSince[agent] = .now } }
    func beginWait(task id: Int) { if taskPages[id] == nil, taskSince[id] == nil { taskSince[id] = .now } }

    /// How long the read on the clock waits now.
    private var untilRead: TimeInterval {
        LiveChanges.untilRead(after: lastReadUptime, now: ProcessInfo.processInfo.systemUptime,
                              every: TimeInterval(readSeconds))
    }

    /// One pass of the loop: the heads of the fleet, then the page that is open, then the receipt of a request that
    /// waits. Each part is small, and an unchanged fleet answers 304 with no body at all. **A call while a pass is on
    /// its way is never dropped**: that pass runs once more when it ends, and the call comes back after that one, so
    /// what the owner just did, or what the hub just said changed, is in what the phone holds.
    func refresh() async {
        await reads.run { [self] in await readOnce() }
    }

    private func readOnce() async {
        defer { lastReadUptime = ProcessInfo.processInfo.systemUptime; firstReadWaits = false }
        // A phone with no hub reads nothing: no hub can answer the built-in address, and no line may say one did not.
        guard !hasNoHub else { return }
        // The Mac's code link is joining this phone: its first read goes with the key that the enrolment gives.
        guard !joining else { return }
        // Nothing reads in the background, also while the key stays for the sends of his held answers.
        guard !keyKeptForSends else { return }
        if snapshot == nil, fleetSince == nil { fleetSince = .now }
        refreshing = true
        guard !keyIsHeldBack else { refreshing = false; clock = Date(); return }
        let requested = hub
        defer { refreshing = false; clock = Date() }
        readsBegun += 1
        let run = readsBegun
        // Each request of this read has its hold (`holding`); the slowest one sets the next read's.
        slowestRequest = .zero
        do {
            // **The page he opened reads first** (fix round 3, items 44 and 46): on a slow hub its read waited behind
            // the fleet's read and the other chats' (Remy's chat filled at +3.5 s on a 1.6-s hub). With a generation
            // read before, it goes now; the fleet's read follows, and the page reads again only if that changed.
            let early = snapshot?.db
            if let early {
                if let agent = openChat {
                    try await holding(requested) { try await readChat(agent, hub: requested, database: early) }
                }
                if let task = openTask {
                    try await holding(requested) { try await readTask(task, hub: requested, database: early) }
                }
            }
            try await holding(requested) { try await readSnapshot(requested) }
            guard requested == hub, let database = snapshot?.db else { return }
            showCountOnIcon()
            follow()
            if early != database {
                if let agent = openChat {
                    try await holding(requested) { try await readChat(agent, hub: requested, database: database) }
                }
                if let task = openTask {
                    try await holding(requested) { try await readTask(task, hub: requested, database: database) }
                }
            }
            readChangedChats(hub: requested, database: database)
            try await holding(requested) { try await confirmPending(hub: requested, database: database) }
            await readEnded(hub: requested, database: database)
            lastRead = Date()
            decideTaken(before: run)
            // The read answered: the reading is current again, and the next read's hold follows this one's time.
            lastRequestTook = slowestRequest
            if readHeld { readHeld = false }
            readError = nil
            readWasRefused = false
            authProblem = nil
            replayTakenTalk()
            replayTakenPause()
            await preparePush()
        } catch is CancellationError {
            return
        } catch {
            guard requested == hub else { return }
            // A generation change makes everything that the phone holds stale. Drop it and read the new one at once:
            // the clock's next read was up to 30 seconds away, with nothing on the pages until then.
            if case MobileError.refusal(let refusal, _) = error, refusal.status == 409 {
                forgetGeneration()
                Task { await self.refresh() }
                return
            }
            readError = error.localizedDescription
            readWasRefused = (error as? MobileError)?.isDefinitive == true
            authProblem = (error as? MobileError)?.auth
            // The hub took this phone off, or its key is not taken: nothing of that hub is this phone's to count.
            if authProblem != nil { Self.setIconCount(0) }
        }
    }

    private func readSnapshot(_ requested: URL) async throws {
        let answer: (snapshot: MobileSnapshot, etag: String?, body: Data)?
        // The first read of a launch names no generation: the one kept from the last launch may be gone, and the hub
        // answers a read of a gone one with a refusal, where a read of none gets the new one at once. Its tag still
        // goes, so an unchanged fleet answers 304 and what was kept is current.
        let database = lastRead == nil ? nil : snapshot?.db
        do { answer = try await client.snapshot(at: requested, key: key, database: database, etag: etag) }
        catch MobileError.refusal(let refusal, _) where refusal.status == 404 { throw MobileError.noPhoneRoutes }
        guard let answer else {
            // 304: the fleet did not change, so what the phone holds is current.
            lastRead = Date()
            readError = nil
            readWasRefused = false
            authProblem = nil
            return
        }
        guard requested == hub else { return }
        // The pages' loading line, when it showed, stands half a second (item 84).
        if snapshot == nil, let since = fleetSince { await Self.settle(since: since) }
        fleetSince = nil
        guard requested == hub else { return }
        // The chats kept from the last launch belong to the generation they were read in.
        if (snapshot?.db ?? keptDatabase) != answer.snapshot.db { forgetGeneration(keepSnapshot: true) }
        snapshot = answer.snapshot
        // The words about a key request that is no longer open go: nothing shows them again. So do the words of his
        // message under a card that closed.
        let open = Set(answer.snapshot.needs.map(\.id))
        if clarifyDrafts.keys.contains(where: { !open.contains($0) }) { clarifyDrafts = clarifyDrafts.filter { open.contains($0.key) } }
        // **A request of another hub or generation leaves at the first read of this one** (F10, A2): it can never go
        // (it goes only to its own, `canRetry`), Settings offered no control for it, and every later write of the
        // phone waited behind it, also after a start of the app. Its words go back to no field: an agent of that name
        // on another hub is another agent. Not in the sample fleet, whose reading is no hub's.
        // (An Outbox that cannot clear it keeps it, as before, and the next read tries again.)
        if !sample, let other = pending, !sending, other.hub != hub || other.database != answer.snapshot.db,
           (try? outbox.clear(matching: other.requestID)) != nil {
            pending = nil
            sendError = nil
        }
        // A refused answer, or a refused message under a card, whose item is no longer open leaves: no card shows its
        // line and its Discard any more (F10, A1). **Also in the read that the refused send makes as it ends**, while
        // `sending` still holds: no other send carries a request then. Later reads of an unchanged fleet answer 304
        // and come not here, so the request stood in Settings as "Refused" until the next write.
        if let refused = pending, refused.refusal != nil, let item = refused.needID ?? refused.talkNeed,
           refused.hub == hub, refused.database == answer.snapshot.db, !open.contains(item) {
            clear(refused: refused)
        }
        // The receipt's talk of a card goes once the reading has as many lines, or the card is no longer open: an item
        // that another took the place of keeps no talk, which went to the new one (review B of 20 November 2026).
        if !talkTaken.isEmpty {
            let read = Dictionary(answer.snapshot.needs.map { ($0.id, $0) }) { first, _ in first }
            let still = talkTaken.filter { id, taken in read[id].map { ($0.talk ?? []).count < taken.count } ?? false }
            if still.count != talkTaken.count { talkTaken = still }
        }
        // **The chats' drafts and the files that he picked belong to their generation** (`composersPlace`): at the first
        // read of another one they go, from memory and from the disk, or the files of an old item 7 stood in the new
        // item 7's box and went with a Send, with the attachment numbers of the old generation. Not by
        // `forgetGeneration`, which also runs when he leaves the sample fleet, whose end gives him back what he had
        // before; not in the sample, whose reading is no hub's. A first read with no record keeps them.
        let place = answer.snapshot.db
        if !sample, composersPlace != place {
            if composersPlace != nil { forgetComposers() }
            composersPlace = place
            UserDefaults.standard.set(place, forKey: "composersPlace")
        }
        keptDatabase = answer.snapshot.db
        snapshotAt = Date()
        etag = answer.etag
        keepSnapshot(answer.body, etag: answer.etag)
        let names = Set(answer.snapshot.ui_features ?? [])
        if features != names { features = names }
        shareRoster()
        markRepliesSeen()
    }

    /// One agent's conversation: the last page when the phone has not read it in this launch, and the items after its
    /// cursor otherwise. A chat kept from the last launch is read from its last page too: when that page begins after
    /// the newest item kept, the messages between are not on this phone, so what was kept goes and the page stands
    /// alone, rather than a conversation with a hole in it.
    private func readChat(_ agent: String, hub requested: URL, database: String) async throws {
        let since = chatCursor[agent]
        let page = try await client.chat(at: requested, key: key, database: database, agent: agent, since: since)
        guard requested == hub, snapshot?.db == database else { return }
        // A chat that opened with nothing read shows its loading line after a second; when it showed, it stands half a
        // second (item 104).
        if chatItems[agent] == nil, let start = chatSince[agent] { await Self.settle(since: start) }
        chatSince[agent] = nil
        guard requested == hub, snapshot?.db == database else { return }
        var held = chatItems[agent] ?? []
        if since == nil, let first = page.items.first, let newest = held.last, first.ts > newest.ts { held = [] }
        let merged = Self.merge(held, page.items)
        var items = merged.items
        let fresh = merged.fresh
        // The agent's words that come into the chat he has open, after it was drawn, fade in.
        if agent == openChat, !items.isEmpty {
            let now = Date()
            for id in fresh.filter({ $0.kind == .report }).map(\.id) where arrivals[agent]?[id] == nil {
                arrivals[agent, default: [:]][id] = now
            }
        }
        items += fresh
        let read = items.sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
        chatCursor[agent] = max(page.cursor, chatCursor[agent] ?? 0)
        if let sent = delivered, (sent.recipient ?? "manager") == agent, Self.holds(sent, in: read) { delivered = nil }
        // An answer names no agent: its message is known by its request number alone.
        deliveredAnswers.removeAll { Self.holds($0, in: read) }
        guard chatItems[agent] != read else { return }
        chatItems[agent] = read
        keepChats()
        readPictures()
    }

    /// **What a chat's read brings, merged into what the phone holds** (review A2): an item it holds takes the hub's
    /// version — the words of a message he corrected where it stands, its read time — and a new one comes after it.
    /// The read kept the first version of every item, so a message corrected in place kept its old words, also after a
    /// relaunch.
    static func merge(_ held: [MobileChatItem], _ page: [MobileChatItem]) -> (items: [MobileChatItem], fresh: [MobileChatItem]) {
        let latest = Dictionary(page.map { ($0.id, $0) }) { _, last in last }
        let items = held.map { latest[$0.id] ?? $0 }
        let known = Set(items.map(\.id))
        return (items, page.filter { !known.contains($0.id) })
    }

    /// **A correction that changes his message where it stands** (owner feature `edit_in_place`), by the Mac's own
    /// question (`HubState.editsInPlace`): his message that the agent has not read and that no reply names. The hub asks
    /// again inside its write, and a read of the same moment wins: then the correction goes under it after all.
    static func editsInPlace(_ original: String, in items: [MobileChatItem]) -> Bool {
        guard let message = items.last(where: { $0.kind == .message && $0.answer_to == nil
            && $0.key.caseInsensitiveCompare(original) == .orderedSame }), message.read_at == nil else { return false }
        return !items.contains { $0.kind == .report && $0.in_reply_to?.caseInsensitiveCompare(original) == .orderedSame }
    }

    /// The items with the words of one message changed where it stands.
    static func edit(_ items: [MobileChatItem], message original: String, to text: String) -> [MobileChatItem] {
        items.map { item in
            guard item.kind == .message, item.key.caseInsensitiveCompare(original) == .orderedSame else { return item }
            var edited = item
            edited.text = text
            return edited
        }
    }

    /// The hub holds this request: its own message, or — a correction that changed its message where it stands, which
    /// leaves no message of its own — that message with the correction's words. The original's id then, else nil.
    static func held(_ request: PendingRequest, in items: [MobileChatItem]) -> (held: Bool, inPlace: String?) {
        if items.contains(where: { $0.kind == .message
            && $0.key.caseInsensitiveCompare(request.requestID.uuidString) == .orderedSame }) { return (true, nil) }
        guard let original = request.replacesRequestID, items.contains(where: { $0.kind == .message
            && $0.key.caseInsensitiveCompare(original) == .orderedSame && $0.text == request.text }) else { return (false, nil) }
        return (true, original)
    }

    /// The chats whose newest line changed since this phone read them, read in the background one after another, so
    /// that a chat opens drawn with its messages, at the newest one, and not as an empty page that fills a moment
    /// later. The open chat is the loop's own read. A read that fails ends the pass: the next read of the fleet tries
    /// again.
    private func readChangedChats(hub requested: URL, database: String) {
        readPictures()
        guard chatsReading == nil else { return }
        let changed: [(name: String, ts: Double)] = agents.compactMap { agent in
            guard let last = agent.last, agent.name != openChat, chatsReadAt[agent.name] != last.ts,
                  last.ts > (chatItems[agent.name]?.last?.ts ?? 0) else { return nil }
            return (agent.name, last.ts)
        }
        guard !changed.isEmpty else { return }
        chatsReading = Task { [weak self] in
            // Who stopped a reader (a new generation, the move to the back) let it go already, and may have started
            // the next one: a stopped reader's end does not let that one go.
            defer { if !Task.isCancelled { self?.chatsReading = nil } }
            for chat in changed {
                guard let store = self, !Task.isCancelled, store.hub == requested, store.snapshot?.db == database
                else { return }
                do { try await store.readChat(chat.name, hub: requested, database: database) } catch { return }
                store.chatsReadAt[chat.name] = chat.ts
            }
        }
    }

    // MARK: The fleet and the chats kept between launches

    /// The last compact read as the hub sent it, with its tag and when it came, for one hub.
    private struct KeptSnapshot: Codable {
        let hub: String
        let etag: String?
        let at: Double
        let body: Data
    }

    /// The compact read that the last launch kept for this hub, or nil.
    private static func keptSnapshot(_ file: URL, hub: URL) -> (snapshot: MobileSnapshot, etag: String?, at: Date)? {
        guard let data = try? Data(contentsOf: file),
              let kept = try? JSONDecoder().decode(KeptSnapshot.self, from: data), kept.hub == hub.absoluteString,
              let snapshot = try? MobileSnapshot.decode(kept.body)
        else { return nil }
        return (snapshot, kept.etag, Date(timeIntervalSince1970: kept.at))
    }

    /// Writes each new compact read to this phone, so the next launch draws the fleet in its first frame. A copy of
    /// what the hub said: nothing is sent from it, and its first read replaces it. The sample fleet is not kept.
    private func keepSnapshot(_ body: Data, etag: String?) {
        guard !sample else { return }
        let kept = KeptSnapshot(hub: hub.absoluteString, etag: etag, at: Date().timeIntervalSince1970, body: body)
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: snapshotFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: snapshotFile, options: [.atomic, .completeFileProtection])
    }

    /// The chats as this phone holds them, for one hub and one hub generation.
    private struct KeptChats: Decodable {
        let hub: String
        let db: String
        let chats: [String: [MobileChatItem]]
    }

    /// The chats that the last launch kept for this hub, or nil.
    private static func keptChats(_ file: URL, hub: URL) -> KeptChats? {
        guard let data = try? Data(contentsOf: file),
              let kept = try? JSONDecoder().decode(KeptChats.self, from: data), kept.hub == hub.absoluteString
        else { return nil }
        return kept
    }

    /// Writes the chats to this phone, the newest 40 items of each, in the hub's own words, so the next launch opens
    /// a chat drawn with them and a chat stays drawn while the hub is away. It is a copy of what the hub said, and
    /// nothing is sent from it: the first read of a launch replaces it. The sample fleet is not kept.
    private func keepChats() {
        guard !sample, let database = snapshot?.db ?? keptDatabase else { return }
        let chats = chatItems.mapValues { $0.suffix(40).map(\.wire) }
        guard let data = try? JSONSerialization.data(withJSONObject: ["hub": hub.absoluteString, "db": database,
                                                                      "chats": chats]) else { return }
        try? FileManager.default.createDirectory(at: chatsFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: chatsFile, options: [.atomic, .completeFileProtection])
    }

    /// One task: the task itself every time, and the notes after the cursor.
    private func readTask(_ id: Int, hub requested: URL, database: String) async throws {
        let page = try await client.task(at: requested, key: key, database: database, id: id,
                                         since: taskCursor[id] ?? 0)
        guard requested == hub, snapshot?.db == database else { return }
        // The task page's loading line, when it showed, stands half a second (item 84).
        if taskPages[id] == nil, let start = taskSince[id] { await Self.settle(since: start) }
        taskSince[id] = nil
        guard requested == hub, snapshot?.db == database else { return }
        var notes = taskPages[id]?.notes ?? []
        let known = Set(notes.map(\.id))
        notes += page.notes.filter { !known.contains($0.id) }
        taskPages[id] = MobileTaskPage(db: page.db, task: page.task, notes: notes.sorted { $0.id < $1.id },
                                       holds: page.holds, outcomes: page.outcomes, cursor: page.cursor)
        taskCursor[id] = max(page.cursor, taskCursor[id] ?? 0)
    }

    /// A send whose answer never arrived may still have reached the hub. The hub's own event is the proof, so the
    /// phone looks for the request's number in that chat before it does anything else (RULES.md 9). An answer to a
    /// Needs-you item is confirmed by its own receipt or by Retry, which replays the same number, **or by a read that no
    /// longer lists its item as open** (`confirmAnswer`).
    private func confirmPending(hub requested: URL, database: String) async throws {
        // (his message under a card is no message of a chat: its own receipt or Try again confirms it)
        guard let request = pending, request.refusal == nil, request.hub == requested,
              request.database == database, request.command == nil, !sending else { return }
        if let needID = request.needID {
            return await confirmAnswer(request, to: needID, hub: requested, database: database)
        }
        let agent = request.recipient ?? "manager"
        let page = try await client.chat(at: requested, key: key, database: database, agent: agent, since: nil)
        let found = Self.held(request, in: page.items)
        guard requested == hub, pending?.requestID == request.requestID, found.held else { return }
        do { try finish(request, editedInPlace: found.inPlace) }
        catch {
            storageError = String(l10n: "Cannot clear the confirmed request. Sending is blocked.")
            storageErrorDetail = error.localizedDescription
        }
    }

    /// **An answer that waits unsent, whose item the reading no longer lists as open** (the owner, 22 November 2026:
    /// "cards on the phone are left with Sending... and never complete"): the hub took it and its receipt was lost, or
    /// another hand answered the item (the Mac, the owner tools, a notification's button, the manager), or the item
    /// went. The newest page of the chat of the agent that raised it tells which: the request's own number there is the
    /// hub's write of this answer, and it ends as its receipt would have ended it (`finish`); else the request leaves,
    /// and nothing of it goes. The phone confirmed only a chat message so, and every later write waited behind such an
    /// answer until his Try again, which met the hub's "already answered" and then waited for a Discard. An item that
    /// is still open keeps its "Not sent" with Try again. An answer of his older than the chat's page or than the
    /// reading's 50 answered items leaves as one that another hand gave: the hub has the item answered all the same.
    /// A chat that does not read leaves the request for the next read, and the read itself counts as one that worked.
    private func confirmAnswer(_ request: PendingRequest, to needID: Int, hub requested: URL, database: String) async {
        guard let reading = snapshot, reading.db == database, !reading.needs.contains(where: { $0.id == needID })
        else { return }
        var found = false
        if let answered = reading.answered_needs?.first(where: { $0.id == needID }) {
            guard let page = try? await client.chat(at: requested, key: key, database: database, agent: answered.by,
                                                    since: nil) else { return }
            found = Self.held(request, in: page.items).held
        }
        guard requested == hub, pending?.requestID == request.requestID, !sending else { return }
        if found {
            do { try finish(request) }
            catch {
                storageError = String(l10n: "Cannot clear the confirmed request. Sending is blocked.")
                storageErrorDetail = error.localizedDescription
            }
        } else if (try? outbox.clear(matching: request.requestID)) != nil {
            // (an Outbox that cannot clear it keeps it, as before, and the next read tries again)
            pending = nil
            sendError = nil
        }
    }

    /// Everything that belonged to one hub generation goes: its pages, its cursors and its tag. The waiting request
    /// stays, because it names its own hub and generation and Settings says so, until the first read of the new one
    /// (`readSnapshot`).
    private func forgetGeneration(keepSnapshot: Bool = false) {
        clarifyDrafts = [:]         // the words about a key request belong to the request of that generation
        talkTaken = [:]             // and the talk under a card, which a new generation numbers anew
        talkReceipts = [:]
        // The ended heads belong to the generation they were read in.
        endedAsks = [:]
        endedFailed = nil
        if !keepSnapshot { snapshot = nil; snapshotAt = nil }
        stopWatching()
        etag = nil
        features = []
        chatItems = [:]
        chatCursor = [:]
        chatsReading?.cancel()
        chatsReading = nil
        chatsReadAt = [:]
        delivered = nil
        deliveredAnswers = []
        writtenAnswers = []
        answersTaken = [:]
        takenAtRead = [:]
        picturesReading?.cancel()
        picturesReading = nil
        picturesWaiting = []
        picturesFailed = []
        notLoaded = []
        // A new generation numbers its files from the start again: what this phone holds of the old one goes, and a
        // read on its way keeps nothing (`load`).
        filesGeneration += 1
        pictures = [:]
        pictureOrder = []
        fileData = [:]
        fileSums = [:]
        fileOrder = []
        fileReads = []
        keptDatabase = nil
        try? FileManager.default.removeItem(at: chatsFile)
        taskPages = [:]
        taskCursor = [:]
        cancelCorrection()
    }

    /// The owner typed another hub address. A new address drops the old state at once: nothing of one hub shows under
    /// another.
    func connect() async {
        do {
            let next = try MobileClient.address(addressText)
            // The sample fleet's address is no hub: this app answers it itself.
            guard next.host?.lowercased() != SampleHub.host else { throw MobileError.invalidAddress }
            addressError = nil
            // A hub of his own ends the sample fleet: the camera's link of a code comes here too.
            if sample { endSample() }
            if next != hub {
                UserDefaults.standard.set(next.absoluteString, forKey: "hubAddress")
                use(next)
            }
            await refresh()
        } catch { addressError = error.localizedDescription }
    }

    /// The phone moves to another hub, or to or from the sample fleet: nothing of one shows under another.
    private func use(_ next: URL) {
        hub = next
        Self.setIconCount(0)        // the next read of that hub sets its own count (showCountOnIcon)
        forgetGeneration()
        shareRoster()
        device = nil
        lastRead = nil
        readError = nil
        readWasRefused = false
        readHeld = false
        lastRequestTook = .zero
        authProblem = nil
        chatRoute = []
        taskRoute = []
    }

    // MARK: The sample fleet

    /// Opens the sample fleet (`SampleFleet.swift`) from a phone with no hub: the pages read it from now on, from its
    /// first frame, and every time in it counts back from this moment.
    func startSample() {
        guard !sample else { return }
        SampleHub.begin()
        keyDraftsBeforeSample = drafts.filter { KeyInText.contains($0.value) }
        sample = true
        use(SampleHub.address)
        tab = .chats
        Task { await refresh() }
    }

    /// Leaves the sample fleet: what it held goes, and the phone is as it was before it, with no hub.
    func leaveSample() {
        guard sample else { return }
        endSample()
        use(Self.savedHub())
        tab = .chats
        Task { await refresh() }
    }

    /// Takes the sample off this phone: a write of it that waits or that was refused, and the drafts written in it,
    /// which were never kept (`setDraft`), so the drafts of before it come back, those that look like a key too
    /// (`keyDraftsBeforeSample`).
    private func endSample() {
        sample = false
        if let left = pending, left.hub == SampleHub.address, (try? outbox.clear(matching: left.requestID)) != nil {
            pending = nil
        }
        sendError = nil
        fileFailed(nil)
        drafts = (UserDefaults.standard.dictionary(forKey: "agentDrafts") as? [String: String] ?? [:])
            .merging(keyDraftsBeforeSample) { _, kept in kept }
        keyDraftsBeforeSample = [:]
        answers = UserDefaults.standard.dictionary(forKey: "answerDrafts") as? [String: String] ?? [:]
        let seen = UserDefaults.standard.dictionary(forKey: "mobileRepliesSeen")
        seenContext = seen?["context"] as? String ?? ""
        seenReplies = seen?["seen"] as? [String: Double] ?? [:]
    }

    /// Reads this phone as the hub names it. Settings asks for it; no page needs it to work.
    func readDevice() async {
        guard let database = snapshot?.db else { return }
        let requested = hub
        do {
            let list = try await client.devices(at: requested, key: key, database: database)
            guard requested == hub else { return }
            device = list.thisDevice
        } catch { device = nil }
    }

    // MARK: Live changes (owner feature `live_changes`)

    /// The wait on `GET /ui/wait`, for one hub address and one generation, while the app is in front.
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var watched: Watched?
    @ObservationIgnored private var watches = 0
    private struct Watched: Equatable { let hub: URL; let database: String; let id: Int }
    /// At most one read that a change asks for in two seconds; the one held for later, while it waits.
    @ObservationIgnored private var cap = WakeCap()
    @ObservationIgnored private var heldWake: Task<Void, Never>?

    /// Starts the wait while the app is in front and the hub's compact read carries its token, and stops it when
    /// either goes away. A hub without it is read on the clock alone, as before.
    private func follow() {
        let token = isForeground && features.contains(LiveChanges.feature) ? LiveToken(snapshot?.token) : nil
        if let watched, watched.hub == hub, watched.database == snapshot?.db, token != nil { return }
        guard watched != nil || token != nil else { return }
        stopWatching()
        guard let token, let database = snapshot?.db else { return }
        watches += 1
        let watching = Watched(hub: hub, database: database, id: watches)
        watched = watching
        watcher = Task { [weak self] in await self?.watchChanges(watching, from: token) }
    }

    private func stopWatching() {
        watcher?.cancel(); watcher = nil; watched = nil
        heldWake?.cancel(); heldWake = nil
        cap.reset()
    }

    /// One wait after another, each from the newest token, and a read for each change. **Nothing of it is ever on
    /// the screen**: a wait that failed sets no error and no state, and the next one waits 1 to 30 seconds. A changed
    /// generation ends it, because only a read learns the new one, and that read starts the next wait.
    private func watchChanges(_ watching: Watched, from token: LiveToken) async {
        var watch = LiveWatch(from: token)
        let changes = LiveChangesClient()
        while !Task.isCancelled, watched == watching {
            do {
                let started = ProcessInfo.processInfo.systemUptime
                let answer = try await changes.wait(hub: watching.hub, database: watching.database,
                                                    since: watch.since, key: key)
                guard !Task.isCancelled, watched == watching else { return }
                switch answer {
                case .token(let next):
                    switch watch.answered(next, took: ProcessInfo.processInfo.systemUptime - started,
                                          jitter: .random(in: 0...1)) {
                    case .wake: woke()
                    case .wait: break
                    case .pause(let delay): do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    }
                case .generationChanged:
                    watcher = nil; watched = nil
                    woke()
                    return
                }
            } catch {
                guard !Task.isCancelled, watched == watching else { return }
                do { try await Task.sleep(for: .seconds(watch.failed(jitter: .random(in: 0...1)))) } catch { return }
            }
        }
    }

    /// The hub said that something changed. **At most one read goes out in two seconds for it**: the changes inside
    /// them fold into one read at their end.
    private func woke() {
        let now = ProcessInfo.processInfo.systemUptime
        switch cap.wake(at: now) {
        case .now: Task { await refresh() }
        case .at(let time):
            heldWake = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, time - now)))
                guard !Task.isCancelled, let self else { return }
                self.heldWake = nil
                self.cap.fired(at: ProcessInfo.processInfo.systemUptime)
                await self.refresh()
            }
        case .folded: break
        }
    }

    // MARK: Pings (owner feature push)

    /// This hub sends pings to its enrolled phones (UI-API.md, "Pings to the owner's phone").
    var supportsPush: Bool { features.contains("push") }
    /// The token that Apple gave this phone, and what the hub last took from it: the hub, its generation, this
    /// device and the token. The phone gives it once at each start, and again when one of them changes.
    @ObservationIgnored private var pushToken: String?
    @ObservationIgnored private var pushGiven: String?
    @ObservationIgnored private var pushAsked = false

    /// Apple gave this phone its token (`PushDelegate`).
    func pushTokenArrived(_ token: String) {
        pushToken = token
        Task { await givePushToken() }
    }

    /// After a read that worked, so on an enrolled phone: a phone without its key reads nothing at all, and only the
    /// owner's own Mac address, where the simulator runs, reads without one. The question to the owner goes on its own
    /// task, so the read loop never waits for his answer, and the token goes to the hub only for a device.
    private func preparePush() async {
        await takeRecoveryCopy()
        guard supportsPush else { return }
        if !pushAsked {
            pushAsked = true
            Task { await PushRegistration.ask() }
        }
        await givePushToken()
    }

    /// The phone's copy of the recovery code (owner feature `recovery_copy`, DevOps plan V12): after a read that worked,
    /// once, when this phone has a recovery key and keeps no copy yet. It opens the box that the Mac sealed to that key,
    /// keeps the code on this phone alone, and tells the hub, which then deletes the box. Nothing shows.
    @ObservationIgnored private var recoveryTaken = false
    /// One look for the box a minute at most: reads come every few seconds while the app is open.
    @ObservationIgnored private var recoveryLooked: TimeInterval = 0

    private func takeRecoveryCopy() async {
        guard features.contains("recovery_copy"), !recoveryTaken, let key, let database = snapshot?.db,
              ProcessInfo.processInfo.systemUptime - recoveryLooked >= 60,
              DeviceRecoveryKey().exists, !RecoveryCodeCopy().held else { return }
        recoveryLooked = ProcessInfo.processInfo.systemUptime
        if device == nil { await readDevice() }
        guard let name = device?.device else { return }
        do {
            guard let box = try await client.recoveryBox(device: name, hub: hub, key: key, database: database),
                  let code = try DeviceRecoveryKey().open(box, device: name) else { return }
            try RecoveryCodeCopy().keep(code)
            try await client.recoveryHeld(device: name, hub: hub, key: key, database: database, label: installation)
            recoveryTaken = true
        } catch {
            // No box yet, no answer, or a box this key does not open: the next read tries again.
        }
    }

    private func givePushToken() async {
        guard supportsPush, let token = pushToken, let key, let database = snapshot?.db else { return }
        if device == nil { await readDevice() }
        guard let name = device?.device else { return }
        // A hub that seals what a ping says gets this phone's own key with the token (UI-API.md 1.76).
        let seal = features.contains("sealed_push") ? SealKey().current() : nil
        let given = [hub.absoluteString, database, name, token, seal == nil ? "" : "sealed"].joined(separator: "|")
        guard pushGiven != given else { return }
        do {
            try await client.givePushToken(token, environment: PushRegistration.environment, seal: seal, device: name,
                                           hub: hub, key: key, database: database, label: installation)
            pushGiven = given
        } catch let error as MobileError where error.isDefinitive {
            pushGiven = given           // the hub said no: asking again at every read changes nothing
        } catch {
            // No answer: the next read tries again. The app works without pings.
        }
    }

    // MARK: Is what shows current?

    /// The state on screen is current: the last read worked, it is not older than the slowest read cadence plus the
    /// client's own timeout, and no read on its way has taken longer than its hold (`readHeld`). Without it, every page
    /// says so and no value reads as current.
    var isFresh: Bool { answersWrites && !readHeld }

    /// The hub answered the last read, and not longer ago than the slowest read cadence plus the client's own timeout.
    /// **A read that is slow leaves a write as it was** (fix round 3d, as the Mac's): the old look is the reading's,
    /// and a write has its own answer, so a slow read hides no button.
    var answersWrites: Bool {
        guard snapshot != nil, readError == nil, let lastRead else { return false }
        // Against the slowest cadence: a read that fails says so by itself (`readError`), and a chat or a task reads at
        // once when it opens. Against the open page's own cadence, a chat or a task opened 25 to 45 seconds after a
        // tab's read was "unavailable" in its first frame, before its own read had even started.
        return max(clock, Date()).timeIntervalSince(lastRead) < Double(Self.restingSeconds) + 15
    }

    /// What shows may be drawn as current: a current read, or — for the first second of a launch or a return, while
    /// its first read is on its way — the reading this phone holds. Its old-reading marks wait that second, as the
    /// Mac's do: the kept fleet is almost always still true, and marks that came for the 100 to 300 ms of a read and
    /// went were a flash at every start. After the second, an old reading says that it is old.
    var showsCurrent: Bool {
        // **The second's end draws the pages again** (D-1 rule 2; fix round 3d): both halves are read, so a page tracks
        // the hold. A page last drawn with a current reading had read `isFresh` alone, and after a return the old
        // reading stood unmarked until its read answered.
        let holds = firstReadWaits && snapshot != nil && readError == nil
        return isFresh || holds
    }

    /// A read is on its way to a reading that is there, and no read failed: the reading is being read again (D-1 rule
    /// 2), so what it holds stays in its place until the read answers.
    var readsAgain: Bool { refreshing && snapshot != nil && readError == nil }

    /// The hub's own clock now, as well as this phone can tell: the time of the last body plus the time since it
    /// came. A 304 brings no time, so the ages on screen still move while the fleet is unchanged.
    var hubNow: Double {
        guard let snapshot else { return Date().timeIntervalSince1970 }
        guard let snapshotAt else { return snapshot.time }
        return snapshot.time + max(0, max(clock, Date()).timeIntervalSince(snapshotAt))
    }

    /// What the owner must know about the connection, or nil while the read is current.
    var unavailableWords: String? {
        // A phone with no hub has no connection to speak of.
        guard !hasNoHub, !firstReadWaits else { return nil }
        // The key comes first: when this phone holds one that is not in hand, that is the whole reason, and the
        // hub's own refusal would send the owner to make a new code for something a Face ID prompt gives back. **Also
        // while the reading is current** (the review of 21 November 2026): every write waits for the key
        // (`canWrite`), and after a Face ID that he cancelled both Sends stood gray with no reason for 45 seconds. Not
        // while the Face ID sheet is up.
        if let words = keyWords, !isFresh || !unlocking { return words }
        guard !isFresh else { return nil }
        if let auth = authProblem { return MobileError.authWords(auth) }
        // The hub answered and said no: its own reason, not "unavailable".
        if readWasRefused, let readError { return readError }
        // Only a read that failed says so, in the Mac's words. The age of the last read is not a failure: a page
        // opened half a minute after a read said "Hub unavailable. Last read just now." over a hub that answered
        // every read within milliseconds, and its read was already on its way.
        if readError != nil { return MobileError.noAnswer.localizedDescription }
        // A read on its way is not a problem: a page with nothing read shows its loading line in its first slot.
        return nil
    }

    /// The line over the page sends him to Settings: this phone's key or its enrollment stands in the way, and only he
    /// can put that right, there. Any other failure is a read to try again.
    var outageNeedsSettings: Bool { keyWords != nil || authProblem != nil }

    /// Settings, from any page: the line over the page's way on when the key or the enrollment is the cause.
    func openSettings() {
        tab = .chats
        chatRoute = [.settings]
    }

    /// Nothing of this hub was ever read and its read is on its way: the pages show the one loading line. When no
    /// read can come, the line over the page is the one thing that says so (D-2).
    var readsTheHub: Bool { snapshot == nil && readCanCome && !hasNoHub }

    // MARK: The lists of the pages

    var agents: [MobileAgent] { snapshot?.agents ?? [] }
    var openNeeds: [OwnerNeed] { (snapshot?.needs ?? []).sorted { ($0.raised, $0.id) > ($1.raised, $1.id) } }
    /// The newest answered items, for the folded cards of the chats (fix round 2, item 103) and the line of a row on
    /// Chats (`ChatsPage.waitingRequest`), with none that a new item replaced (`answered(_:holding:)`).
    var answeredNeeds: [OwnerNeed] { Self.answered(snapshot, holding: pending?.needID) }
    /// **No card for a request that a new item replaced** (owner API 1.274, `replaced_by`; FleetCore's `drawn`, as the
    /// Mac's chat draws its requests; the owner, 20 November 2026, of a chat where a folded card said "Replaced by
    /// manager with a new item: …" over the card of the new item with the same title): the hub answers such an item
    /// with its own words, so a chat leaves it out before it places its cards in time, and the new item's card stands
    /// there alone. The one whose answer of his is on its way or was refused (`held`, the outbox's request) keeps its
    /// card until that answer is cleared. An open item never has the field, because the hub sets it with its own
    /// answer: Needs you and its count, which draw the open items, have none to leave out.
    nonisolated static func answered(_ read: MobileSnapshot?, holding held: Int?) -> [OwnerNeed] {
        (read?.answered_needs ?? []).drawn(holding: held)
    }
    /// The open tasks, newest activity first.
    var openTasks: [MobileTaskHead] { sorted(snapshot?.tasks ?? []) }
    /// The last tasks that ended, newest first.
    var endedTasks: [MobileTaskHead] { sorted(snapshot?.recent ?? []) }
    /// The holds that still hold a task, and the outcomes that the owner must record: not those that the task's agent
    /// checks first, while the task runs or waits for its next session (`TaskOutcome.waitsOnOwner`).
    var openHolds: [TaskHold] { snapshot?.holds ?? [] }
    var openOutcomes: [TaskOutcome] {
        (snapshot?.outcomes ?? []).filter { outcome in
            let row = head(outcome.task)
            return outcome.waitsOnOwner(holds: openHolds, taskEnded: row?.isTerminal, shellOff: shellOff(row?.owner))
        }
    }
    /// Whether the agent `name`'s sessions record no outcome (`TaskOutcome.shellOff`), with a `can` that the hub did not
    /// send read as `[]`, as `askReading` reads it.
    func shellOff(_ name: String?) -> Bool {
        guard let name, let agent = agent(name) else { return false }
        return TaskOutcome.shellOff(role: agent.role, can: agent.can ?? [])
    }
    /// **The Needs you tab's count is the Mac's Needs you row's** (the owner's yes of 28 October 2026 to D-4: "the same
    /// count as the iPhone tab"): the open requests, and each task that only he can move, once, as
    /// `HubState.ownerTasks` counts them. The page lists both, so the count is what it opens (fix round 1).
    /// The number on the app's icon is this count too (`showCountOnIcon`), and the hub's twin of the rule is
    /// `owner_count` in hub.py, which puts it in each ping.
    var needsYouCount: Int { openNeeds.count + ownerTasks.count }

    /// **The number on the Home Screen icon is the tab's count** (the owner's yes of 12 November 2026, "Yes, all
    /// four", point 1), and no number when nothing needs him. After each read of the hub that worked, also one that
    /// found the fleet unchanged; the hub's pings carry the same number while the app is closed. The sample fleet puts
    /// no number there. A phone that did not allow badges shows nothing, and the call does nothing.
    func showCountOnIcon() {
        Self.setIconCount(sample ? 0 : needsYouCount)
    }

    static func setIconCount(_ count: Int) {
        guard !hostsTests else { return }
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }

    /// A task that only the owner can move, as the Mac's Needs you page lists it.
    struct OwnerTask: Identifiable {
        let id: Int
        let title: String
        let owner: String?
        /// What waits, in the Mac's words, and its mark.
        let words: String
        let symbol: String
    }

    /// **The tasks that only he can move**, the newest first: an action whose outcome nobody knows ("Outcome not known:
    /// check it") and a stop the helper did not confirm ("Stop not confirmed"), each once.
    var ownerTasks: [OwnerTask] {
        let unconfirmed = openHolds.filter { $0.state == "not_confirmed" }
        let ids = Set(openOutcomes.map(\.task) + unconfirmed.map(\.task))
        return ids.sorted(by: >).map { id in
            let head = head(id)
            if let outcome = openOutcomes.first(where: { $0.task == id }) {
                return OwnerTask(id: id, title: head?.title ?? outcome.title, owner: head?.owner,
                                 words: String(l10n: "Outcome not known: check it"), symbol: "questionmark.circle")
            }
            return OwnerTask(id: id, title: head?.title ?? String(l10n: "Task"), owner: head?.owner,
                             words: String(l10n: "Stop not confirmed"), symbol: "exclamationmark.circle")
        }
    }

    private func sorted(_ tasks: [MobileTaskHead]) -> [MobileTaskHead] {
        tasks.sorted { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) }
    }

    /// One task's head, from the open tasks or the ones that ended.
    func head(_ id: Int) -> MobileTaskHead? {
        snapshot?.tasks.first { $0.id == id } ?? snapshot?.recent.first { $0.id == id }
    }
    func taskPage(_ id: Int) -> MobileTaskPage? { taskPages[id] }
    func agent(_ name: String) -> MobileAgent? { snapshot?.agents.first { $0.name == name } }
    /// The conversation with one agent, oldest last, as far as the phone has read it.
    func items(for agent: String) -> [MobileChatItem] { chatItems[agent] ?? [] }

    /// The name of each thing that he asked for that the reading's heads name, by his message's request_id.
    var askNames: [String: String] { endedNames.merging(snapshot?.asked ?? [:]) { _, current in current } }

    /// **What he asked for in the chat of `entries`** (owner feature asks; the owner, 16 November 2026: "this tasks
    /// should also show inside the conversation!!", and "the Mac and the iPhone"): FleetCore's asks (`HubState.asks`)
    /// of the tasks that the phone holds — the open ones, the 20 that ended last and every ended one that it read
    /// (`readEnded`) — whose message stands in these entries, read with the requests, holds, outcomes and usage limits
    /// of the reading, as the Mac reads them. nil while none is held.
    func askReading(in entries: [ChatEntry]) -> HubState? {
        guard let snapshot, !askTasks.isEmpty else { return nil }
        var here = Set<String>()
        var messages: [OwnerMessage] = []
        for entry in entries {
            if case .message(let message) = entry {
                here.insert(message.request_id.lowercased())
                messages.append(message)
            }
        }
        // A correction stands for the message that it replaced (`ChatAskPlaces`).
        for message in messages { if let replaced = message.replaces_request_id { here.insert(replaced.lowercased()) } }
        guard askTasks.contains(where: { $0.ask.map { here.contains($0.lowercased()) } == true }) else { return nil }
        let agents = snapshot.agents.map {
            FleetAgent(phoneName: $0.name, role: $0.role, runtime: $0.runtime, limit: $0.limit, can: $0.can ?? [])
        }
        return HubState(phoneTime: snapshot.time, db: snapshot.db, agents: agents, tasks: askTasks,
                        needs: snapshot.needs + (snapshot.answered_needs ?? []), messages: messages,
                        holds: snapshot.holds, outcomes: snapshot.outcomes)
    }

    /// **What came of his answer to `need`, in the place of its check** (owner feature `need_marks`; the owner's "Yes,
    /// as drawn" of 21 November 2026): FleetCore's own rule (`OwnerNeed.answeredMark`), as the Mac's folded card reads
    /// it, from the reading that the phone holds (`markReading`). Before the first reading: the check.
    func answeredMark(of need: OwnerNeed) -> AnsweredMark {
        need.answeredMark(in: snapshot.map { Self.markReading($0, ended: endedHeads, of: need) })
    }

    /// **The task that a press of an answered card's mark opens** (his "Both (Recommended)", "Yes, open task" and "Gray
    /// pause, as the row" of 21 November 2026; the Mac's `NeedRequestCard.markOpensTask`): the task that his answer let
    /// go on, where the card draws that task's work mark, the orange mark of a task that needs him, or the gray mark of
    /// his pause. Each of them comes only from a task that the reading holds. The check and the red mark open nothing,
    /// and neither does the work of a team plan, which no task holds.
    nonisolated static func taskOpened(by mark: AnsweredMark?, of need: OwnerNeed) -> Int? {
        guard let task = need.task, let mark else { return nil }
        switch mark {
        case .working(_, let agent?, _): return agent.isEmpty ? nil : task
        case .attention, .paused: return task
        case .working, .done, .failed: return nil
        }
    }

    /// **Pause at the end of an answered card's line while its task works** (his "Both (Recommended)"; the Mac's
    /// `NeedRequestCard.pausable`): the task, where what came of his answer is that task's work, the hub takes a task's
    /// controls, the task has no hold that is not released, and no Pause of it is on its way or taken with no read
    /// since. **His Pause of the task that waits unsent stands on the card, whatever its mark is now**, and its press
    /// sends that one again (`pause(task:)`): every later write of the phone waits behind it, and only Settings showed
    /// it (the review of 21 November 2026). nil otherwise.
    func pausable(_ need: OwnerNeed) -> Int? {
        guard features.contains(Self.taskControls), let snapshot, let task = need.task, !need.isOpen else { return nil }
        // his Pause of this task that goes, that did not go, or that the hub refused: it is on its way, or its own line
        // under the card stands for it (`pauseState`)
        if let pending, case .control(let paused, .pause)? = pending.command, paused == task, pending.hub == hub,
           pending.database == snapshot.db {
            return nil
        }
        guard pauseState(of: task) == nil, case .working(_, let agent?, _) = answeredMark(of: need), !agent.isEmpty,
              let head = (snapshot.tasks + snapshot.recent + endedHeads).first(where: { $0.id == task }), !head.isTerminal,
              !snapshot.holds.contains(where: { $0.task == task && $0.state != "released" }),
              !pausesTaken.contains(task) else { return nil }
        return task
    }

    /// `ui_features` of a hub that takes a task's Pause, Stop and Resume (`POST /ui/tasks/<id>/control`).
    static let taskControls = "task_controls"

    /// His Pause of `task` can go now.
    func canPause(_ task: Int) -> Bool { canWrite && features.contains(Self.taskControls) }

    /// **What came of his Pause of a task, when it did not go**: it waits unsent ("Not sent", and its Try again sends
    /// the same request), or the hub refused it (its words; it left the Outbox by itself). nil otherwise.
    enum PauseState: Equatable { case notSent, refused(String) }

    /// The hub's refusal of his Pause of a task, by task, on its hub and generation, until his Discard.
    private struct PauseRefusal { let hub: URL, database: String, words: String }
    private var pauseRefusals: [Int: PauseRefusal] = [:]

    /// **His Pause of `task` that did not go, as its card's line says it** (the review of 21 November 2026): a Pause
    /// that waits unsent and goes nowhere by itself, and one that the hub refused, which ended by itself with no words.
    func pauseState(of task: Int) -> PauseState? {
        if let pending, case .control(let paused, .pause)? = pending.command, paused == task, pending.hub == hub,
           pending.database == snapshot?.db, pending.refusal == nil, !sending {
            return .notSent
        }
        if let refused = pauseRefusals[task], refused.hub == hub, refused.database == snapshot?.db {
            return .refused(refused.words)
        }
        return nil
    }

    /// Discard of a refused Pause's line: the card offers its Pause again where its task works.
    func discardPauseRefusal(_ task: Int) { pauseRefusals[task] = nil }

    /// **The tasks whose Pause the hub took**, until the read that the send makes after its receipt: the card's Pause
    /// does not come back for that read's round trip, before the reading has the hold.
    private(set) var pausesTaken: Set<Int> = []

    /// **The task's Pause, from an answered card**, as the task's panel on the Mac sends it: one owner command, `POST
    /// /ui/tasks/<id>/control`, which the hub takes from this phone's own key (UI-API.md, "What a device may use"). It is
    /// saved and sent as every write is, through the Outbox and once: a Pause of it that waits unsent goes again with
    /// its own number (`retry`), never as a second one.
    func pause(task: Int) async {
        if let pending, case .control(let paused, .pause)? = pending.command, paused == task, pending.refusal == nil,
           pending.hub == hub, pending.database == snapshot?.db {
            return await retry()
        }
        guard canWrite, let snapshot, features.contains(Self.taskControls), clearRefused() else { return }
        pauseRefusals[task] = nil
        let request = PendingRequest(hub: hub, database: snapshot.db, client: installation,
                                     command: .control(task: task, action: .pause), text: "")
        do {
            try outbox.save(request)
            pending = request
        } catch {
            storageError = String(l10n: "Cannot save this request. Nothing was sent.")
            storageErrorDetail = error.localizedDescription
            return
        }
        await transmit(request)
    }

    /// **A Pause whose receipt was lost, while the reading has its task's hold**: the hub took it, so the same request
    /// goes again, once, and the hub answers with its first result (`command_run`), which confirms it. **Only then**: a
    /// Pause that the hub never took waits for his Try again under its card (`pauseState`), also after a start of the
    /// app, as every request that the app keeps does (the review of 21 November 2026: a Pause pressed with the hub away
    /// went by itself the next day). **Never without this phone's key**: then it stays for a later read, as his message
    /// under a card does (`replayTakenTalk`).
    private func replayTakenPause() {
        guard let request = pending, case .control(let task, .pause)? = request.command, request.refusal == nil,
              request.hub == hub, request.database == snapshot?.db, pauseReplayed != request.requestID,
              snapshot?.holds.contains(where: { $0.task == task && $0.state != "released" }) == true
        else { return }
        pauseReplayed = request.requestID
        Task { [weak self] in
            while self?.sending == true { try? await Task.sleep(for: .milliseconds(50)) }
            guard let self, self.pending?.requestID == request.requestID else { return }
            guard !self.keyIsHeldBack else { self.pauseReplayed = nil; return }
            await self.retry()
        }
    }
    @ObservationIgnored private var pauseReplayed: UUID?

    /// **The reading of an answered card's mark, made of the parts that the phone holds**: the hub's features, the task
    /// that his answer lets go on — from the open heads, the 20 that ended last and every ended one that the phone read
    /// — and the holds, the outcomes and the agents' usage limits and Tools boxes, which that task's mark reads, as on
    /// the Mac. A task that none of them holds is none, and the rule then says that the agent has his answer.
    nonisolated static func markReading(_ snapshot: MobileSnapshot, ended: [MobileTaskHead],
                                        of need: OwnerNeed) -> HubState {
        let head = need.task.flatMap { id in (snapshot.tasks + snapshot.recent + ended).first { $0.id == id } }
        let agents = snapshot.agents.map {
            FleetAgent(phoneName: $0.name, role: $0.role, runtime: $0.runtime, limit: $0.limit, can: $0.can ?? [])
        }
        return HubState(phoneTime: snapshot.time, db: snapshot.db, agents: agents,
                        tasks: head?.fleetTask.map { [$0] } ?? [], needs: [need], messages: [],
                        holds: snapshot.holds, outcomes: snapshot.outcomes, features: snapshot.ui_features)
    }
    /// This chat was read at least once on this hub generation: before that, it is not empty, it is not read yet.
    func hasRead(chat agent: String) -> Bool { chatItems[agent] != nil }

    /// **Whether an agent works on his newest chat message now**, as the "Thinking" of its chat says it: its mark then
    /// moves and the line of its row on Chats moves, as for a task in work (`MobileAgent.mobileState`). Not while its
    /// usage limit holds it or its server does not answer, and not from a reading that is not current.
    ///
    /// **The hub says since when each chat waits** (owner feature `chat_waits`, hub 1.142; the owner, 13 November
    /// 2026: "Yes, fix it"), so every row of Chats knows it, also for a message that he wrote on his Mac. With a hub
    /// from before that, only a conversation that this phone has read up to its newest line says it: the compact read
    /// gives a conversation's last line and not what it answers, so the rule reads the chat's own items
    /// (`ChatPage.pending`), and a line that came since (a reply) is not in them.
    func thinks(_ name: String) -> Bool {
        guard showsCurrent, let entry = agent(name), let snapshot else { return false }
        return Self.thinks(entry, items: items(for: name), time: snapshot.time, hubSays: features.contains("chat_waits"),
                           answers: ChatPage.answersWait(entry, features: features))
    }

    /// `answers`: the chat's line waits on his answer to a request too (`ChatPage.answersWait`).
    static func thinks(_ entry: MobileAgent, items: [MobileChatItem], time: Double, hubSays: Bool,
                       answers: Bool = false) -> Bool {
        // nor while his message does not arrive, which the hub says of a server that answers (`chat_undelivered`)
        guard entry.active != false, entry.limit == nil, entry.helperIsRecent(serverTime: time),
              entry.chat_undelivered != true else { return false }
        if hubSays {
            guard let sent = entry.waits_since else { return false }
            return !ChatWaiting.turnIsOver(sent: sent, turnEndedAfter: entry.turn_ended_after)
        }
        guard let last = entry.last, let newest = items.map(\.ts).max(), newest >= last.ts - 0.001 else { return false }
        return ChatPage.pending(in: items, turnEndedAfter: entry.turn_ended_after, answers: answers) == .waiting
    }

    /// A reply came in this agent's chat after the owner last had that chat open.
    func hasNewReply(from name: String) -> Bool {
        guard let last = agent(name)?.last, last.isFromAgent else { return false }
        return last.ts > (seenReplies[name] ?? 0)
    }

    /// The open chat's replies are seen. A new hub or hub generation takes the replies that it has as seen, so that
    /// only later replies are new.
    func markRepliesSeen() {
        guard let snapshot else { return }
        let context = "\(hub.absoluteString)\n\(snapshot.db)"
        var seen = seenContext == context ? seenReplies : [:]
        if seenContext != context {
            for agent in snapshot.agents where agent.last?.isFromAgent == true { seen[agent.name] = agent.last?.ts }
        }
        if let open = openChat, let last = agent(open)?.last, last.isFromAgent { seen[open] = last.ts }
        guard seen != seenReplies || seenContext != context else { return }
        seenContext = context
        seenReplies = seen
        // What he saw in the sample fleet is not kept: it ends with the sample (`endSample`).
        guard !sample else { return }
        UserDefaults.standard.set(["context": context, "seen": seen], forKey: "mobileRepliesSeen")
    }

    // MARK: Can the owner write now?

    var supportsDirectChat: Bool { features.contains("direct_chat") }
    /// This hub takes files with a message (owner feature `attachments`).
    var supportsAttachments: Bool { features.contains("attachments") }
    /// This hub takes Word, Excel and PowerPoint files from the owner too (owner feature `office_files`, UI-API.md 1.251).
    var supportsOfficeFiles: Bool { features.contains("office_files") }
    /// **This hub takes his words about a key request from a phone** (owner feature `secret_clarify_phone`, API 1.252;
    /// the owner's "Yes, build it" of 20 November 2026 to the picture of the phone's card): the card of a request for a
    /// key or a login draws its link Needs clarification only then. A hub before it refuses those words from a phone.
    var supportsClarify: Bool { features.contains("secret_clarify_phone") }
    /// **This hub takes his message under a card** (Needs clarification on every card, owner feature `need_clarify`,
    /// API 1.272; the owner's "Keep Your answer too" of 20 November 2026 to the picture of the card): a card shows its
    /// talk with the agent, and the link Needs clarification stands under his answer where the hub says that the card
    /// takes a message (`OwnerNeed.clarifies`). The phone's key card has its own Needs clarification
    /// (`supportsClarify`), whose words answer the request.
    var supportsTalk: Bool { features.contains(FleetCore.NeedClarify.feature) }
    var supportsCorrections: Bool { features.contains("corrections") }
    /// **His correction on its way changes his message where it stands** (owner feature `edit_in_place`; review A2):
    /// the hub will change that message itself, so its bubble shows the new words, and no second bubble comes. Only
    /// while it waits for its receipt: a confirmed one is in the chat itself.
    func editsInPlace(_ request: PendingRequest) -> String? {
        guard features.contains("edit_in_place"), request.needID == nil, pending?.requestID == request.requestID,
              let original = request.replacesRequestID, !request.text.isEmpty,
              Self.editsInPlace(original, in: items(for: request.recipient ?? "manager")) else { return nil }
        return original
    }

    /// This hub takes a message to this agent: the route is there and the agent is active.
    func canChat(with name: String) -> Bool { snapshot?.canChat(with: name, features: features) ?? false }

    /// Why this chat takes no message, in the owner's words, or nil when it takes one. The connection line says it
    /// when nothing was read.
    func chatUnavailableWords(_ name: String) -> String? { snapshot?.chatUnavailableWords(name, features: features) }

    /// A write may go: the hub answered the last read (`answersWrites`), nothing else waits for its receipt, the
    /// Outbox can be used, and **this phone's key is in hand** (`keyIsHeldBack`). One request at a time, as on the Mac.
    /// A write with no key is refused for good (`device_key_required`), and the phone then asks to be enrolled again:
    /// a press that waited went so at its next look after the move to the back locked the key, or at the return before
    /// Face ID ended (the review of 21 November 2026). It waits for the key now.
    /// **A request that the hub refused for good holds no write** (the owner, 22 November 2026: "cards on the phone are
    /// left with Sending... and never complete"): it leaves the Outbox when the next write is saved (`clearRefused`), as
    /// the Mac's save never waits behind a request in its request line. Every later answer of the phone waited behind
    /// it, its card said "Sending…" with no end, and only a Discard in Settings moved it.
    var canWrite: Bool {
        answersWrites && !sending && (pending == nil || pending?.refusal != nil) && storageError == nil && !keyIsHeldBack
    }

    /// This item's own request, of this hub and generation, waits in the Outbox and no send carries it: an error
    /// stopped its send, or the app started with it. Its item says "Not sent", and only his Try again moves it. **Not a
    /// refused one**: it holds nothing (`canWrite`), and a new press on its item is a new answer, which takes its place.
    func waitsUnsent(for need: Int) -> Bool {
        guard let pending, pending.refusal == nil, !sending else { return false }
        // his message under the card is its own request too (Needs clarification): a press behind it waited with no
        // end, and the card said "Sending…" in place of its "Not sent"
        return (pending.needID == need || pending.talkNeed == need) && pending.hub == hub
            && pending.database == snapshot?.db
    }

    /// **His words about a key request that wait in the Outbox**, of this hub and generation, with no refusal: the
    /// card's field shows them and takes no change, because Try again sends those words and no others. The words that
    /// stand in the field are kept in memory only (`clarifyDrafts`), so after a start of the app the kept request is
    /// the one place that has them, and a field that showed the link alone let him write other words that never went.
    /// **His message under any other card waits there the same way** (`talk(needID:words:)`), while it goes too.
    func clarifyKept(for need: Int) -> String? {
        guard let pending, (pending.clarifies && pending.needID == need) || pending.talkNeed == need,
              pending.refusal == nil, pending.hub == hub, pending.database == snapshot?.db else { return nil }
        return pending.text
    }

    /// The waiting request may be sent again, with its own number. A refused one may not: its refusal is definitive.
    var canRetry: Bool {
        guard let pending else { return false }
        return answersWrites && !sending && storageError == nil && pending.refusal == nil && !keyIsHeldBack &&
            pending.hub == hub && pending.database == snapshot?.db
    }

    // MARK: The drafts

    func draft(for name: String) -> String { drafts[name] ?? "" }
    /// A draft is kept across a force quit, except one written in the sample fleet, which ends with the sample, and one
    /// whose words look like a key (`keepChatDrafts`).
    func setDraft(_ text: String, for name: String) {
        guard drafts[name] ?? "" != text else { return }
        if text.isEmpty { drafts[name] = nil } else { drafts[name] = text }
        keepChatDrafts()
    }

    /// **The chats' drafts are kept across a start of the app, but words that look like a key are not** (`KeyInText`):
    /// they stay in memory only, as the words of Needs clarification do (`clarifyDrafts`), because a key pasted into
    /// the chat's box must not stay on the phone's disk while it waits there. A force quit loses such a draft, the
    /// price of no key on the disk. The sample's drafts are never kept.
    private func keepChatDrafts() {
        guard !sample else { return }
        Self.writeChatDrafts(drafts)
    }

    private static func writeChatDrafts(_ drafts: [String: String]) {
        UserDefaults.standard.set(drafts.filter { !KeyInText.contains($0.value) }, forKey: "agentDrafts")
    }

    /// **The words about a key request that stand in its field, in memory only.** They are the field's own words: the
    /// card on Needs you and the card in the agent's chat read and write the same ones, and the store empties them, so
    /// no view keeps a copy that a refusal for registered login text would leave on the screen. The drafts of an answer
    /// are kept across a restart (`answers`, in the app's settings file); these are never written to a file, because a
    /// key that he pasted into that field by mistake must not stay on the phone's disk. They go when they are sent,
    /// when the hub refuses registered login text, with the generation, and at each read for a request that is no
    /// longer open (`readSnapshot`).
    private(set) var clarifyDrafts: [Int: String] = [:]
    func clarifyDraft(for need: Int) -> String { clarifyDrafts[need] ?? "" }
    func setClarifyDraft(_ text: String, for need: Int) {
        let kept = text.isEmpty ? nil : text
        if clarifyDrafts[need] != kept { clarifyDrafts[need] = kept }
    }

    /// **Needs clarification**: his words about a request for a key or a login go to the agent that asked, saved and
    /// sent as an answer is (`write`). The hub closes the request with them. Words that look like a key never go, and
    /// never reach the saved request: the card holds them back first and says why, and this refuses them too, as it
    /// refuses words over the hub's most.
    func clarify(needID: Int, words: String) async {
        guard let need = snapshot?.needs.first(where: { $0.id == needID }), need.asksForSecret, supportsClarify,
              !KeyInText.contains(words), NeedSecret.length(words.trimmingCharacters(in: .whitespacesAndNewlines)) <= NeedSecret.clarifyMost
        else { return }
        await write(words, needID: needID, recipient: need.by, clarifies: true)
    }

    // MARK: His message under a card (Needs clarification on every card)

    /// **The talk of each card as the hub's receipt of his last message gave it**, by item, until a reading has as
    /// many lines: his message stands in the card from the frame the hub took it, where it went from the field at the
    /// receipt and came back one read later.
    private(set) var talkTaken: [Int: [NeedMessage]] = [:]
    /// **How many of his messages under each card the hub took on this phone**, by item: a card's field goes back to
    /// its link at each one. It only grows while the generation lasts, so a read that drops `talkTaken` closes no
    /// field that he opened again since.
    private(set) var talkReceipts: [Int: Int] = [:]
    /// The message under a card that a read sent again because its card's talk had it (`replayTakenTalk`): once.
    @ObservationIgnored private var talkReplayed: UUID?
    /// How many of his lines with a message's words its card showed when he sent it, by request: only a reading with
    /// more of them has it (`replayTakenTalk`). A start of the app forgets it, and then only his Try again sends it.
    @ObservationIgnored private var talkLinesAtSend: [UUID: Int] = [:]

    /// His lines with these words in the talk of the card `need`, as the reading has it.
    private func ownLines(_ words: String, under need: Int) -> Int {
        let item = ((snapshot?.needs ?? []) + (snapshot?.answered_needs ?? [])).first { $0.id == need }
        return (item?.talk ?? []).filter { $0.fromOwner && $0.text == words }.count
    }

    /// **His message under a card whose receipt never came, while the card's talk has it already** (review A of 20
    /// November 2026): the hub took it and its answer was lost, so the card showed his message in its talk, the same
    /// words in the field and "Not sent" under it, and every write of the phone waited behind it. The hub's talk names
    /// no request, so the read cannot finish it as it finishes a chat's message by its number (`confirmPending`):
    /// the same request goes again, once, as his Try again would send it, and the hub answers with its first result
    /// (`command_run`), which confirms it. Only a talk with more of his lines with those words than it had at his
    /// send has it: an older message of his with the same words is no sign (review A, round 2), and after a start of
    /// the app, which forgets that number, only his Try again sends it. The read that a failed send makes at its end
    /// is the first to see it, so the request goes once that send has ended.
    private func replayTakenTalk() {
        guard let request = pending, let needID = request.talkNeed, request.refusal == nil,
              request.hub == hub, request.database == snapshot?.db, talkReplayed != request.requestID,
              let before = talkLinesAtSend[request.requestID], ownLines(request.text, under: needID) > before
        else { return }
        talkReplayed = request.requestID
        Task { [weak self] in
            while self?.sending == true { try? await Task.sleep(for: .milliseconds(50)) }
            guard let self, self.pending?.requestID == request.requestID else { return }
            // never without this phone's key, which the move to the back locks (review B, round 2): the hub would
            // refuse the phone itself, for good; a read after the key comes back sends it
            guard !self.keyIsHeldBack else { self.talkReplayed = nil; return }
            await self.retry()
        }
    }

    /// The request is his message under the card `need` of this hub and generation: a request kept from another one
    /// names another item by that number (review B of 20 November 2026).
    func talks(_ request: PendingRequest, under need: Int) -> Bool {
        request.talkNeed == need && request.hub == hub && request.database == snapshot?.db
    }

    /// **The talk under a card, as the card shows it** (`OwnerNeed.shownTalk`): his messages and the agent's replies,
    /// oldest first, open or answered, on a hub that names the feature; the receipt's while the reading does not have
    /// his last message yet (`talkTaken`).
    func talk(of need: OwnerNeed) -> [NeedMessage] {
        let read = need.shownTalk(features: Array(features))
        guard supportsTalk, let taken = talkTaken[need.id], taken.count > read.count else { return read }
        return taken
    }

    /// **His message under a card** (Needs clarification, owner feature `need_clarify`; the owner, 20 November 2026: "a
    /// button link, that then shows the extra text input", and "Keep Your answer too"): it goes to the agent of the
    /// card, and the item stays open for his answer. It is saved and sent as every write is, through the Outbox and
    /// once, on its own route (`OwnerCommand.needTalk`), so a failure sends the same request again and never a second
    /// one. Its words are the field's (`clarifyDrafts`, in memory only). Words that look like a key never go, and never
    /// reach the saved request: the card holds them back first and says why, and this refuses them too, as it refuses
    /// words over the hub's most and a card that takes no message (`OwnerNeed.clarifies`).
    func talk(needID: Int, words: String) async {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canWrite, let snapshot, answersTaken[needID] == nil,
              let need = snapshot.needs.first(where: { $0.id == needID }), need.clarifies(features: Array(features)),
              !text.isEmpty, !KeyInText.contains(text), NeedSecret.length(text) <= NeedTalk.most, clearRefused()
        else { return }
        let request = PendingRequest(hub: hub, database: snapshot.db, client: installation,
                                     command: .needTalk(need: needID), text: text)
        // (of the talk that the card shows: a reading behind the last receipt has fewer of them; review A, round 3)
        talkLinesAtSend = [request.requestID: talk(of: need).filter { $0.fromOwner && $0.text == text }.count]
        do {
            try outbox.save(request)
            pending = request
        } catch {
            storageError = String(l10n: "Cannot save this request. Nothing was sent.")
            storageErrorDetail = error.localizedDescription
            return
        }
        await transmit(request)
    }

    func answerDraft(for need: Int) -> String { answers[String(need)] ?? "" }
    func setAnswerDraft(_ text: String, for need: Int) {
        let key = String(need)
        guard answers[key] ?? "" != text else { return }
        if text.isEmpty { answers[key] = nil } else { answers[key] = text }
        if !sample { UserDefaults.standard.set(answers, forKey: "answerDrafts") }
    }

    // MARK: The files that the owner picked

    /// One file that the owner picked for one composer. Its own number is the number of its upload, so a repeat is
    /// one file on the hub and never a second one.
    struct StagedFile: Codable, Identifiable, Equatable, Sendable {
        let requestID: UUID
        let name: String
        let mime: String
        let size: Int
        /// What the hub called it, once the upload worked. Until then the bytes wait on this phone.
        var attachmentID: Int?
        /// Why the last upload did not work, in the hub's words.
        var failure: String?
        var id: UUID { requestID }
        var isOnHub: Bool { attachmentID != nil }
    }

    /// The composer of one chat, or of one open item of Needs you.
    static func stageKey(agent: String) -> String { "agent:\(agent)" }
    static func stageKey(need: Int) -> String { "need:\(need)" }

    func stagedFiles(for composer: String) -> [StagedFile] { staged[composer] ?? [] }
    /// The numbers that a message from this composer carries, in the order the owner picked them.
    func readyFiles(for composer: String) -> [Int] { stagedFiles(for: composer).compactMap(\.attachmentID) }
    /// A file of this composer is still on its way, or did not go.
    func filesAreWaiting(for composer: String) -> Bool { stagedFiles(for: composer).contains { !$0.isOnHub } }

    /// The owner picked a file. The bytes are written beside the Outbox **before** anything is sent, then the file
    /// goes up with its own number; the message that carries it names only that number.
    func stage(_ data: Data, name: String, mime: String, for composer: String) async {
        guard storageError == nil else { return }
        // The sample fleet takes no file, as it takes no write: the hub's refusal, at once, where a file's words go.
        guard !sample else {
            fileFailed(MobileError.refusal(HubRefusal(status: 409, hubWords: SampleHub.refusal), auth: nil).notSentWords)
            return
        }
        guard stagedFiles(for: composer).count < MessageAttachment.perMessage else {
            fileFailed(String(l10n: "A message carries at most \(MessageAttachment.perMessage) files."))
            return
        }
        guard MessageAttachment.sendable(mime, office: supportsOfficeFiles) else {
            fileFailed(MessageAttachment.typeWords(office: supportsOfficeFiles))
            return
        }
        guard !data.isEmpty, data.count <= MessageAttachment.sizeLimit else {
            fileFailed(AttachmentError.tooLarge.errorDescription)
            return
        }
        let file = StagedFile(requestID: UUID(), name: MessageAttachment.safeName(name, mime: mime), mime: mime,
                              size: data.count)
        do { try write(data, of: file) }
        catch {
            fileFailed(String(l10n: "Cannot keep this file on the phone. Nothing was sent."), detail: error.localizedDescription)
            return
        }
        fileFailed(nil)
        staged[composer, default: []].append(file)
        keepStaged()
        await upload(file, for: composer)
    }

    /// Sends one staged file up, with its own number. A file that is already on the hub never goes again.
    func upload(_ file: StagedFile, for composer: String) async {
        guard snapshot != nil, !file.isOnHub, !uploading.contains(file.requestID) else { return }
        guard let data = try? Data(contentsOf: stagedURL(file)) else {
            change(file, in: composer) { $0.failure = String(l10n: "The bytes of this file are gone from the phone. Pick it again.") }
            return
        }
        uploading.insert(file.requestID)
        defer { uploading.remove(file.requestID) }
        change(file, in: composer) { $0.failure = nil }
        // **It waits for this phone's key**, as every write does (`canWrite`; the review of 21 November 2026): an upload
        // with none is refused for good, and the file's row said "Add this phone again with a new code". It goes once
        // the key is in hand, while the file is still in its composer.
        let requested = hub
        while keyIsHeldBack {
            try? await Task.sleep(for: .milliseconds(250))
            guard hub == requested, stagedFiles(for: composer).contains(where: { $0.requestID == file.requestID }) else { return }
        }
        guard let snapshot else { return }
        do {
            let sent = try await client.upload(data, name: file.name, mime: file.mime, requestID: file.requestID,
                                               client: installation, hub: hub, key: key, database: snapshot.db)
            change(file, in: composer) { $0.attachmentID = sent.id; $0.failure = nil }
        } catch {
            if let error = error as? MobileError { authProblem = error.auth }
            change(file, in: composer) {
                $0.failure = (error as? LocalizedError)?.errorDescription ?? String(l10n: "The file did not go up.")
            }
        }
    }

    /// The owner takes a file out of a composer. Its bytes leave the phone; a file that is already on the hub stays
    /// there until the hub itself drops it, but no message of this phone names it.
    func removeStaged(_ file: StagedFile, for composer: String) {
        guard !uploading.contains(file.requestID) else { return }
        try? FileManager.default.removeItem(at: stagedURL(file))
        staged[composer] = stagedFiles(for: composer).filter { $0.requestID != file.requestID }
        if staged[composer]?.isEmpty == true { staged[composer] = nil }
        keepStaged()
    }

    /// Every file of this composer, after the hub took the message that carried them.
    /// The files that the hub took leave the composer; one that the owner picked while the message was on its way
    /// stays for the next message.
    private func clearStaged(_ composer: String, sent: [Int]) {
        guard !sent.isEmpty else { return }
        for file in stagedFiles(for: composer) where file.attachmentID.map(sent.contains) == true {
            try? FileManager.default.removeItem(at: stagedURL(file))
        }
        staged[composer] = stagedFiles(for: composer).filter { file in
            file.attachmentID.map { !sent.contains($0) } ?? true
        }
        if staged[composer]?.isEmpty == true { staged[composer] = nil }
        keepStaged()
    }

    private func change(_ file: StagedFile, in composer: String, _ edit: (inout StagedFile) -> Void) {
        guard var list = staged[composer],
              let at = list.firstIndex(where: { $0.requestID == file.requestID }) else { return }
        edit(&list[at])
        staged[composer] = list
        keepStaged()
    }

    /// The chats' drafts and every staged file, with its bytes, leave this phone: they were of another generation
    /// (`readSnapshot`). An upload on its way then finds no file to change.
    private func forgetComposers() {
        if !drafts.isEmpty {
            drafts = [:]
            keepChatDrafts()
        }
        guard !staged.isEmpty else { return }
        for file in staged.values.joined() { try? FileManager.default.removeItem(at: stagedURL(file)) }
        staged = [:]
        stagedThumbs = [:]
        keepStaged()
    }

    private func keepStaged() {
        guard let data = try? JSONEncoder().encode(staged) else { return }
        UserDefaults.standard.set(data, forKey: "stagedFiles")
    }

    /// Which composer holds this file, for a view that has the file alone.
    func composerOf(_ file: StagedFile) -> String? {
        staged.first { $0.value.contains(where: { $0.requestID == file.requestID }) }?.key
    }

    /// A small picture of a staged file, drawn once and kept while the file waits.
    func stagedThumbnail(_ file: StagedFile) -> CGImage? {
        if let made = stagedThumbs[file.requestID] { return made }
        guard file.mime.hasPrefix("image/"), let data = try? Data(contentsOf: stagedURL(file)),
              let made = MessageAttachment.thumbnail(data, maxPixels: 160) else { return nil }
        stagedThumbs[file.requestID] = made
        return made
    }

    private func stagedURL(_ file: StagedFile) -> URL {
        stagedDirectory.appendingPathComponent(file.requestID.uuidString.lowercased())
    }

    private func write(_ data: Data, of file: StagedFile) throws {
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: stagedURL(file), options: [.atomic, .completeFileProtection])
    }

    // MARK: The files that the hub holds

    /// The bytes held for this file, for a page that shows them: only bytes whose read checked this file's size and
    /// SHA-256. A number can name another file: the hub can give a number again after its file went.
    func heldBytes(of file: MessageAttachment) -> Data? {
        guard let data = fileData[file.id], data.count == file.size, fileSums[file.id] == file.sha256 else { return nil }
        return data
    }

    /// The bytes of one file of a message, for the page that shows it. Nothing is kept before its size and its
    /// SHA-256 match what the hub said.
    /// `quietly`: a read in the background, which says nothing when it fails; the page's own read says it.
    func load(_ file: MessageAttachment, quietly: Bool = false) async {
        if let data = heldBytes(of: file) {
            if file.isImage, picture(of: file) == nil { keepPicture(data, of: file) }
            return
        }
        // Bytes held under this number for another file do not stop this file's read: its bytes take their place.
        let read = FileKey(file)
        guard let snapshot, !fileReads.contains(read) else { return }
        let generation = filesGeneration
        fileReads.insert(read)
        // The end of a read that a new generation overtook does not take away the mark of that generation's read.
        defer { if generation == filesGeneration { fileReads.remove(read) } }
        do {
            let data = try await client.attachment(file, hub: hub, key: key, database: snapshot.db)
            // A read that a new hub or generation overtook keeps nothing: its number names another file now.
            guard generation == filesGeneration else { return }
            fileData[file.id] = data
            fileSums[file.id] = file.sha256
            fileOrder.removeAll { $0 == file.id }
            fileOrder.append(file.id)
            while fileOrder.count > 12, let oldest = fileOrder.first {
                fileData[oldest] = nil
                fileSums[oldest] = nil
                fileOrder.removeFirst()
            }
            if file.isImage { keepPicture(data, of: file) }
            notLoaded.remove(read)
        } catch {
            // Nor does it mark anything: its failure was the hub's or the generation's of before. A read that its page
            // stopped (the owner left the chat) or the app's move to the back stopped did not fail.
            guard generation == filesGeneration, !Task.isCancelled else { return }
            // The hub has a new generation that this phone does not know yet: the fleet's read learns it, and
            // empties the files (`forgetGeneration`), and the pictures' tiles read their files again then.
            if case MobileError.refusal(let refusal, _) = error, refusal.status == 409 {
                Task { await self.refresh() }
                return
            }
            // A picture that did not come says so on its own tile, with the ↻ that reads it again; the line under
            // the composer is for a file that is not a picture.
            // Each mark names this file, so a file that took its number after it is not marked with it.
            if file.isImage { notLoaded.insert(read) }
            if quietly { picturesFailed.insert(read); return }
            if let error = error as? MobileError { authProblem = error.auth }
            if !file.isImage { fileFailed((error as? LocalizedError)?.errorDescription ?? String(l10n: "This file did not come.")) }
        }
    }

    /// A read of this file runs now (`load`): a second `load` returns at once, before its bytes are here.
    func reads(_ file: MessageAttachment) -> Bool { fileReads.contains(FileKey(file)) }

    /// The owner pressed ↻ on a picture that did not come: its tile reads it again at once.
    func readAgain(_ file: MessageAttachment) async {
        notLoaded.remove(FileKey(file))
        picturesFailed.remove(FileKey(file))
        await load(file)
    }

    /// The picture of an image file, once its bytes came: only one drawn from the bytes of this file.
    func picture(of file: MessageAttachment) -> CGImage? {
        guard let held = pictures[file.id], held.sha256 == file.sha256 else { return nil }
        return held.image
    }

    /// At most 60 pictures stay drawn, the newest last.
    private func keepPicture(_ data: Data, of file: MessageAttachment) {
        guard let picture = MessageAttachment.thumbnail(data, maxPixels: 640) else { return }
        let id = file.id
        pictures[id] = (file.sha256, picture)
        pictureOrder.removeAll { $0 == id }
        pictureOrder.append(id)
        while pictureOrder.count > 60, let oldest = pictureOrder.first {
            pictures[oldest] = nil
            pictureOrder.removeFirst()
        }
    }

    /// The pictures of the newest 20 messages of each chat, read in the background one after another, so that a chat
    /// opens with its pictures drawn in their slots and nothing arrives under the owner's eyes.
    private func readPictures() {
        guard pictures.count < 60 else { return }
        let queued = Set(picturesWaiting.map(FileKey.init))
        let missing = chatItems.values.flatMap { $0.suffix(20).flatMap(\.attachments) }.filter {
            $0.isImage && picture(of: $0) == nil && !queued.contains(FileKey($0)) && !picturesFailed.contains(FileKey($0))
        }
        picturesWaiting += missing
        guard picturesReading == nil, !picturesWaiting.isEmpty else { return }
        picturesReading = Task { [weak self] in
            // Who stopped a reader (a new generation, the move to the back) let it go already, and may have started
            // the next one: a stopped reader's end does not let that one go.
            defer { if !Task.isCancelled { self?.picturesReading = nil } }
            while let store = self, !Task.isCancelled, !store.picturesWaiting.isEmpty {
                let file = store.picturesWaiting.removeFirst()
                await store.load(file, quietly: true)
            }
        }
    }

    // MARK: The writes

    /// **Words of a chat's Send that look like a key, which wait for his choice** (`KeyInText`): the chat, the message
    /// that a correction replaces (nil for a message), and the words, exactly as the box held them. His Keep it gives
    /// it back to the send of that chat and that mode, and then those words go.
    struct ChatKeyHold: Equatable, Sendable {
        let agent: String
        let replaces: String?
        let words: String
    }

    /// A message to one agent. The manager's chat is where the owner writes a goal, as on the Mac.
    ///
    /// **Words that look like a key wait for his choice** (`KeyInText`), as on the Mac (the owner, 22 November 2026:
    /// "Keep it, as on the Mac"): a key typed or pasted into the chat would go out as words, into the agent's
    /// conversation and the hub's records, but a normal link can look like one too. The send reads the box's words
    /// once and decides on them before anything is saved (`sendChat`), and it gives back the hold that the composer
    /// shows, or nil. `kept` is his Keep it of a hold: those exact words of this chat go, once.
    @discardableResult func send(to name: String, keeping kept: ChatKeyHold? = nil) async -> ChatKeyHold? {
        let hold = ChatKeyHold(agent: name, replaces: nil, words: draft(for: name))
        return await sendChat(hold, kept: kept) {
            save(hold.words, recipient: name, files: readyFiles(for: Self.stageKey(agent: name)))
        }
    }

    /// **The one decision of a chat's Send** (`send(to:keeping:)`, `sendCorrection(in:keeping:)`), on the words that it
    /// would send (`hold`): words that look like a key wait, with nothing saved and the words in the box, unless his
    /// Keep it names this hold. A Keep it of other words (he changed the box since, or it is the other mode's) sends
    /// nothing, and a key in these words waits again. No later read of the box, which a send empties and he can
    /// change while another write is on its way, decides it again. Kept words that nothing can save now still wait.
    private func sendChat(_ hold: ChatKeyHold, kept: ChatKeyHold?, saving: () -> PendingRequest?) async -> ChatKeyHold? {
        let looksLikeKey = KeyInText.contains(hold.words)
        if let kept, kept != hold { return looksLikeKey ? hold : nil }
        if kept == nil, looksLikeKey { return hold }
        guard let request = saving() else { return kept }
        await transmit(request)
        return nil
    }

    /// One answer to one open item of Needs you. It goes to the agent that raised the item. **Words that look like a
    /// key never go** (`KeyInText`), as his message under a card does not: the answer's box holds them back first.
    func send(needID: Int) async {
        guard let need = snapshot?.needs.first(where: { $0.id == needID }), !KeyInText.contains(answerDraft(for: needID))
        else { return }
        await write(answerDraft(for: needID), needID: needID, recipient: need.by,
                    files: readyFiles(for: Self.stageKey(need: needID)))
    }

    /// **The presses on an item's answers that wait until the hub can take them**, by item: the newest press of an
    /// item wins (fix round 2, item 51).
    private(set) var waitingPresses: [Int: WaitingPress] = [:]

    /// A press that waits: one of the item's own options, by its index, or the words that its agent recommends (owner
    /// feature `need_recommended`), which go as his answer in words, with the files of his answer that were up when he
    /// pressed: a file that he adds while the press waits stops it. Or Send on the options that he ticked, on a card
    /// of pictures whose options combine (`NeedPictures`).
    enum WaitingPress: Equatable, Sendable {
        case option(Int)
        case words(String, files: [Int])
        case ticked([Int])
    }

    /// **The answers that the hub took, by item, until the item folds away** (polish pass: the receipt's jump): from
    /// the receipt to the read that folds the item, it keeps its look — his words in its field and "Sending…" under
    /// it, where that line showed — so nothing in it moves before its fold. "Sending…" and its room went at the
    /// receipt, one read before the fold. An item that the read after the receipt still lists as open does not fold,
    /// and it leaves this list then; a folded item draws none of it.
    private(set) var answersTaken: [Int: TakenAnswer] = [:]

    /// An answer that the hub took, with the records of the files it carried: the files leave the composer at the
    /// receipt, and their row under the field draws these until the item folds (polish pass). That row went at the
    /// receipt, one read before the fold.
    struct TakenAnswer: Sendable {
        let request: PendingRequest
        let files: [StagedFile]
    }
    @ObservationIgnored private var pressWaits: [Int: Task<Void, Never>] = [:]
    /// The field's words before the agent's words of a press that waits for the hub (`HeldAnswer.draft`), which its
    /// Undo gives back.
    @ObservationIgnored private var waitingDrafts: [Int: String] = [:]

    /// **A press on one of an item's options is never refused for a moment**, and its rows are never drawn grey (fix
    /// round 2, item 51): it goes at once when the hub can take a write; otherwise it waits — for this launch's first
    /// answer, for the hub to answer again, for the write before it — and goes then, while its item says "Sending…".
    /// Nothing goes on a reading the hub has not confirmed: the press goes only through `send`, which asks `canWrite`,
    /// and only while the item is still open on the same hub and generation; else it is dropped, and nothing went.
    /// **One exception: a press on an item whose own request waits unsent is dropped** (`waitsUnsent`), at the press
    /// or when that request's send stops. The item says "Not sent" with Try again, and only that moves its request: the
    /// press waited behind it with no end, and the item said "Sending…" in place of that line (two reviews of 20
    /// November 2026). A press on any other item waits as before, also behind a request that waits unsent: it goes
    /// when he sends that one again, or when a read finds that the hub has it. **A refused request holds no press**
    /// (`canWrite`): the press goes, and that request leaves the Outbox first.
    func press(needID: Int, choice: Int) {
        press(needID: needID, .option(choice))
    }

    /// **Send on the options that he ticked**, on a card of pictures whose options combine (`NeedPictures`; owner
    /// feature `need_pictures`): it waits and goes as a press on one option does, and the hub joins their words.
    func press(needID: Int, choices: [Int]) {
        press(needID: needID, .ticked(choices))
    }

    /// **A press on the words that an item's agent recommends** (owner feature `need_recommended`: the phone's row of
    /// them on an item with no options): his answer in those words, as if he had typed them. The words go into the
    /// item's field at once and then as his words go (`send(needID:)`), with the files that are up, and they wait as a
    /// press on an option waits, with its drop behind the item's own unsent request. While a file of the answer still
    /// uploads they only stand in the field, and his Send sends them with it; a file that starts, or other words in
    /// the field, while the press waits, drop the press.
    func press(needID: Int, words: String) {
        // behind this item's own answer that waits unsent a press changes nothing, as a press on an option does: only
        // his Try again moves that answer, and the words in the field are his to send with it
        guard canWrite || !waitsUnsent(for: needID) else {
            waitingPresses[needID] = nil
            return
        }
        setAnswerDraft(words, for: needID)
        guard !filesAreWaiting(for: Self.stageKey(need: needID)) else {
            // the newest press wins: an older press of this item that still waits goes with it
            waitingPresses[needID] = nil
            return
        }
        press(needID: needID, .words(words, files: readyFiles(for: Self.stageKey(need: needID))))
    }

    private func press(needID: Int, _ press: WaitingPress) {
        guard canWrite else {
            guard !waitsUnsent(for: needID) else {
                // the newest press wins: an older press of this item that still waits goes with it
                waitingPresses[needID] = nil
                return
            }
            wait(needID: needID, press)
            return
        }
        waitingPresses[needID] = nil
        Task { await send(needID: needID, press) }
    }

    /// **The press waits until the store can write, and goes then** (`canWrite`: the hub answered, nothing else is on
    /// its way, and this phone's key is in hand), while its item is open on the hub and generation of the press and it
    /// still means what he pressed. Presses that wait go one after the other: each one's request is in the Outbox in
    /// the turn that its wait ends, before the next one looks.
    private func wait(needID: Int, _ press: WaitingPress) {
        waitingPresses[needID] = press
        waitingDrafts[needID] = nil
        guard pressWaits[needID] == nil else { return }
        let hub = hub, database = snapshot?.db
        pressWaits[needID] = Task { [weak self] in
            while let store = self, !Task.isCancelled {
                guard store.hub == hub, store.snapshot?.db == database, store.storageError == nil,
                      !store.waitsUnsent(for: needID),
                      store.openNeeds.contains(where: { $0.id == needID }), let press = store.waitingPresses[needID],
                      store.stillMeant(press, for: needID)
                else { break }
                if store.canWrite {
                    store.waitingPresses[needID] = nil
                    store.waitingDrafts[needID] = nil
                    store.pressWaits[needID] = nil
                    await store.send(needID: needID, press)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.waitingPresses[needID] = nil
            self?.waitingDrafts[needID] = nil
            self?.pressWaits[needID] = nil
        }
    }

    // MARK: His answer waits 5 seconds, with Undo

    /// **His answer waits 5 seconds on its card, with Undo, before it goes** (the owner, 21 November 2026: "Sometimes I
    /// can make a mistake replying to a card... we need a way to be able to UNDO very easily", his "Yes, 5 seconds
    /// (Recommended)" and his "Yes, Undo there too"; the Mac's `AnswerHolds`). Each answer that a card sends waits here
    /// first, whole: an option, the words that its agent recommends, the ticked options, and his words with their
    /// files. Nothing of it reaches the Outbox or the hub meanwhile, and then it goes on the path that it took before
    /// (`press(needID:_:)`), with its wait for the hub and its refusals. **One for each request, in the store**, so the
    /// card in a chat and on Needs you show the same Undo. A ping's buttons answer at once: they have no card. The key
    /// card keeps its form, and a message under a card (Needs clarification) is no answer. **The app's leave of the front
    /// sends what waits at once** (`releaseHeldAnswers`): his answer is not lost by an act that is not Undo.
    struct HeldAnswer: Sendable {
        let hub: URL
        let database: String
        let press: WaitingPress
        /// The words of his field before the agent's words took their place (`hold(needID:words:)`), which Undo puts
        /// back; nil where the field holds his own words, which stay.
        let draft: String?
        let mark: UUID

        /// What the card shows meanwhile, as an answer on its way shows.
        var shown: GivenAnswer { GivenAnswer(press) }
    }

    /// How long an answer waits: 5 seconds (his "Yes, 5 seconds"). A check shortens it.
    @ObservationIgnored var answerWait: Duration = .seconds(5)
    private(set) var heldAnswers: [Int: HeldAnswer] = [:]
    @ObservationIgnored private var holdWaits: [Int: Task<Void, Never>] = [:]
    /// The options to tick again on a card whose answer he took back, until its pictures took them (`restoredTicks`).
    @ObservationIgnored private var ticksBack: [Int: [Int]] = [:]

    /// **A press on one of the card's options waits 5 seconds, with Undo**, and then goes as a press went before.
    func hold(needID: Int, choice: Int) {
        guard openNeeds.first(where: { $0.id == needID })?.choices.indices.contains(choice) == true else { return }
        hold(needID, .option(choice))
    }

    /// **Send on the options that he ticked waits 5 seconds, with Undo**, which ticks them again.
    func hold(needID: Int, choices: [Int]) {
        let ticked = Array(Set(choices)).sorted()
        guard let need = openNeeds.first(where: { $0.id == needID }), need.combines, !ticked.isEmpty,
              ticked.allSatisfy(need.choices.indices.contains) else { return }
        hold(needID, .ticked(ticked))
    }

    /// **A press on the words that the agent recommends waits 5 seconds, with Undo**: they stand in his field at once,
    /// as `press(needID:words:)` puts them there, and Undo gives the field back the words that it held before. While a
    /// file of the answer still goes up they only stand in the field, as before, and nothing waits.
    func hold(needID: Int, words: String) {
        guard !waitsUnsent(for: needID) else { return press(needID: needID, words: words) }
        let before = answerDraft(for: needID)
        setAnswerDraft(words, for: needID)
        let composer = Self.stageKey(need: needID)
        guard !filesAreWaiting(for: composer) else { waitingPresses[needID] = nil; return }
        hold(needID, .words(words, files: readyFiles(for: composer)), draft: before)
    }

    /// **Send under his words waits 5 seconds, with Undo**: his words and his files stay in the field, and go then as
    /// his Send sent them (`send(needID:)`), unless he changed them. **Words that look like a key are no answer**
    /// (`KeyInText`): no wait starts and nothing is saved, decided here, at his press, as the answer's box decides.
    func holdSend(needID: Int) {
        let composer = Self.stageKey(need: needID)
        let words = answerDraft(for: needID), files = readyFiles(for: composer)
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filesAreWaiting(for: composer), trimmed.count <= Self.textLimit, !trimmed.isEmpty || !files.isEmpty,
              !KeyInText.contains(trimmed)
        else { return }
        hold(needID, .words(words, files: files))
    }

    /// His press waits `answerWait`, and then goes (`releaseHeld`). Behind this item's own answer that waits unsent it
    /// changes nothing, as a press does. A second press on the same request while one waits takes its place: the card
    /// stands folded meanwhile, so none can come from it.
    private func hold(_ needID: Int, _ press: WaitingPress, draft: String? = nil) {
        guard let database = snapshot?.db, openNeeds.contains(where: { $0.id == needID }) else { return }
        guard !waitsUnsent(for: needID) else { waitingPresses[needID] = nil; return }
        holdWaits[needID]?.cancel()
        let mark = UUID()
        heldAnswers[needID] = HeldAnswer(hub: hub, database: database, press: press, draft: draft, mark: mark)
        let wait = answerWait
        holdWaits[needID] = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, self.heldAnswers[needID]?.mark == mark else { return }
            self.releaseHeld(needID)
        }
    }

    /// The answer that waits with Undo on `need`, on the hub and generation that the store reads and while the request
    /// is open there; nil where none does.
    func heldAnswer(to need: Int) -> HeldAnswer? { current(heldAnswers[need], need) }

    private func current(_ held: HeldAnswer?, _ need: Int) -> HeldAnswer? {
        guard let held, held.hub == hub, held.database == snapshot?.db,
              openNeeds.contains(where: { $0.id == need }) else { return nil }
        return held
    }

    /// **Undo**: the answer goes nowhere, and the card opens as it was: the field's words that the agent's words took
    /// the place of, and the options that he had ticked (`restoredTicks`). His own words and his files stayed in the
    /// field. **While nothing left the phone**: during its wait with Undo, and while it waits for the hub or for this
    /// phone's key after that (`waitingPresses`), whose wait ends at its next look. Once its request is saved it does
    /// nothing: the answer went.
    func undo(needID: Int) {
        guard let held = heldAnswer(to: needID) else {
            guard let press = waitingPresses.removeValue(forKey: needID) else { return }
            if let draft = waitingDrafts.removeValue(forKey: needID) { setAnswerDraft(draft, for: needID) }
            if case .ticked(let indexes) = press { ticksBack[needID] = indexes }
            return
        }
        holdWaits.removeValue(forKey: needID)?.cancel()
        heldAnswers[needID] = nil
        if let draft = held.draft { setAnswerDraft(draft, for: needID) }
        if case .ticked(let indexes) = held.press { ticksBack[needID] = indexes }
    }

    /// The options that a card ticks again as it comes, once: those of an answer that he took back.
    func restoredTicks(of need: Int) -> [Int] { ticksBack.removeValue(forKey: need) ?? [] }

    /// **The answer that waits on this request goes now**, once: on the hub and generation of his press, while the
    /// request is open there, what he pressed still means it (`stillMeant`), and the request's own answer does not wait
    /// unsent (its card says "Not sent", as for a press). **It goes as a press that waits goes** (`wait`), never by a
    /// send of its own: answers that several holds let go in one moment (the leave of the front) each go in turn, and
    /// one that cannot go now waits for the hub and for this phone's key, with "Sending…" under its folded card. A send
    /// of its own saw the store free for each of them, and the second one found the first in the Outbox and ended with
    /// nothing sent and no sign (the review of 21 November 2026).
    func releaseHeld(_ needID: Int) {
        holdWaits.removeValue(forKey: needID)?.cancel()
        guard let held = heldAnswers.removeValue(forKey: needID), current(held, needID) != nil,
              stillMeant(held.press, for: needID), !waitsUnsent(for: needID) else { return }
        wait(needID: needID, held.press)
        // the field's words of before, which Undo gives back while the press waits
        if waitingPresses[needID] == held.press, let draft = held.draft { waitingDrafts[needID] = draft }
    }

    /// Every answer that waits goes now: when the app leaves the front, and before it can end there.
    func releaseHeldAnswers() {
        for need in Array(heldAnswers.keys).sorted() { releaseHeld(need) }
    }

    /// A press on the agent's words still means them while the field holds those words and the answer has the files
    /// that it had at the press, all of them up; a press on an option always does.
    private func stillMeant(_ press: WaitingPress, for needID: Int) -> Bool {
        guard case .words(let words, let files) = press else { return true }
        let composer = Self.stageKey(need: needID)
        return answerDraft(for: needID) == words && !filesAreWaiting(for: composer) && readyFiles(for: composer) == files
    }

    private func send(needID: Int, _ press: WaitingPress) async {
        guard let request = saved(needID: needID, press) else { return }
        await transmit(request)
    }

    /// **The request of a press, saved in the Outbox and not sent yet** (`save`), or nil where nothing can go: an
    /// option with its words and a door call's signed yes, his words in the field with the files that are up, or the
    /// options that he ticked.
    private func saved(needID: Int, _ press: WaitingPress) -> PendingRequest? {
        guard let need = snapshot?.needs.first(where: { $0.id == needID }) else { return nil }
        switch press {
        case .option(let choice):
            guard need.choices.indices.contains(choice) else { return nil }
            return save(need.choices[choice], needID: needID, recipient: need.by, choice: choice,
                        approval: DeviceSigningKey().approval(for: need, choice: choice))
        case .words(let words, _):
            // (words that look like a key never go: the press of them was no answer, `holdSend`)
            guard !KeyInText.contains(words) else { return nil }
            return save(answerDraft(for: needID), needID: needID, recipient: need.by,
                        files: readyFiles(for: Self.stageKey(need: needID)))
        case .ticked(let choices):
            let ticked = Array(Set(choices)).sorted()
            guard need.combines, !ticked.isEmpty, ticked.allSatisfy(need.choices.indices.contains) else { return nil }
            return save(ticked.map { need.choices[$0] }.joined(separator: "; "), needID: needID, recipient: need.by,
                        choices: ticked)
        }
    }

    /// One answer to one open item by one of the options its agent offered (owner feature `need_options`): the hub
    /// writes that option's own words as the answer, as a press on the ping's button does. It goes as every write
    /// goes, through the Outbox and once.
    func send(needID: Int, choice: Int) async { await send(needID: needID, .option(choice)) }

    /// One answer by the options that he ticked, on an item whose options combine (`OwnerNeed.combines`), as the Mac
    /// sends it: their indexes, each once, and their words joined with "; ", which the hub writes as the answer.
    func send(needID: Int, choices: [Int]) async { await send(needID: needID, .ticked(choices)) }

    /// The last message that this phone sent in this chat: the one message that the phone offers to correct
    /// (MOBILE-APP.md 10). The hub refuses a correction of another client's message or of another chat. An answer to a
    /// request is not one, as on the Mac: its card shows it, and it is no bubble to press (item 103).
    func correctable(in name: String) -> MobileChatItem? {
        guard supportsCorrections, canChat(with: name) else { return nil }
        return items(for: name).last { $0.kind == .message && $0.answer_to == nil && $0.client == installation }
    }

    func canCorrect(_ item: MobileChatItem, in name: String) -> Bool { correctable(in: name)?.key == item.key }

    func beginCorrection(_ item: MobileChatItem, in name: String) {
        guard canCorrect(item, in: name) else { return }
        correcting = item
        correctionText = item.text
    }

    func cancelCorrection() {
        correcting = nil
        correctionText = ""
    }

    /// Sends the correction of the message that the owner opened. The original message and the work that followed it
    /// stay in the history: the hub keeps both events. Words that look like a key wait for his choice, as in a message
    /// (`send(to:keeping:)`): decided once, on the words that it would send. A correction has its own hold: the Keep
    /// it of a message, or of another correction, sends nothing here.
    @discardableResult func sendCorrection(in name: String, keeping kept: ChatKeyHold? = nil) async -> ChatKeyHold? {
        guard let item = correcting, canCorrect(item, in: name) else { return nil }
        let hold = ChatKeyHold(agent: name, replaces: item.key, words: correctionText)
        return await sendChat(hold, kept: kept) { save(hold.words, recipient: name, replaces: item.key) }
    }

    /// Saves the request, then sends it. The order is the rule: the Outbox holds the number and the text before the
    /// hub hears anything, so a crash, a timeout or a force quit can never make a second message. The app makes no
    /// new number for a request that already exists (MOBILE-APP.md 5.4 and 10).
    private func write(_ value: String, needID: Int? = nil, recipient: String, replaces: String? = nil,
                       files: [Int] = [], choice: Int? = nil, choices: [Int]? = nil,
                       approval: (statement: String, signature: String)? = nil, clarifies: Bool = false) async {
        guard let request = save(value, needID: needID, recipient: recipient, replaces: replaces, files: files,
                                 choice: choice, choices: choices, approval: approval, clarifies: clarifies)
        else { return }
        await transmit(request)
    }

    /// **The request, saved in the Outbox, before any send** (`write`): its number and its words are on the phone
    /// first. nil where nothing can go now, or the Outbox cannot keep it.
    private func save(_ value: String, needID: Int? = nil, recipient: String, replaces: String? = nil,
                      files: [Int] = [], choice: Int? = nil, choices: [Int]? = nil,
                      approval: (statement: String, signature: String)? = nil, clarifies: Bool = false) -> PendingRequest? {
        guard canWrite, let snapshot else { return nil }
        guard needID != nil || canChat(with: recipient) else { return nil }
        guard files.isEmpty || supportsAttachments else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A message carries text, or files, or both. Without a file it must carry text, as the hub asks.
        guard !text.isEmpty || !files.isEmpty, text.count <= Self.textLimit else { return nil }
        if let needID, !openNeeds.contains(where: { $0.id == needID }) { return nil }
        guard clearRefused() else { return nil }
        let request = PendingRequest(hub: hub, database: snapshot.db, client: installation, needID: needID,
                                     choice: choice, choices: choices,
                                     recipient: needID == nil && supportsDirectChat ? recipient : nil,
                                     replacesRequestID: replaces, attachments: files, approval: approval,
                                     clarifies: clarifies, text: text)
        if let needID { answersTaken[needID] = nil; takenAtRead[needID] = nil }
        do {
            try outbox.save(request)
            pending = request
        } catch {
            storageError = String(l10n: "Cannot save this request. Nothing was sent.")
            storageErrorDetail = error.localizedDescription
            return nil
        }
        // The bubble is the message now: its words leave the field in the frame the bubble comes in. They stood in
        // both while the message went. A message that is refused gives them back when the owner discards it.
        if needID == nil {
            if replaces == nil { setDraft("", for: recipient) } else { correctionText = "" }
        }
        return request
    }

    /// Sends the waiting request again, with its own number. The hub answers the first event once more: one message,
    /// not two.
    func retry() async {
        guard canRetry, let pending else { return }
        await transmit(pending)
    }

    /// Takes a refused request off the phone. Only a refusal that the hub called definitive leaves this way; nothing
    /// that may have arrived is dropped.
    func discardRefused() {
        guard !sending, let pending, pending.refusal != nil else { return }
        clear(refused: pending)
    }

    /// The steps of a Discard: the refused request leaves the Outbox, and a message's words go back to their field.
    private func clear(refused request: PendingRequest) {
        do {
            try outbox.clear(matching: request.requestID)
            pending = nil
            sendError = nil
            giveBack(request)
        } catch {
            storageError = String(l10n: "Cannot clear the refused request. Sending is blocked.")
            storageErrorDetail = error.localizedDescription
        }
    }

    /// **A refused request leaves before the next write is saved** (`canWrite`): by the steps of his Discard, so a
    /// message's words go back to its field when the field holds none. Each door that saves a request asks it first
    /// (`save`, `pause(task:)`, `talk(needID:words:)`), because the Outbox keeps one request and refuses a second while
    /// one is in its file. False when the Outbox could not clear it: then nothing is saved, and the line says why.
    private func clearRefused() -> Bool {
        guard let pending, pending.refusal != nil else { return true }
        discardRefused()
        return self.pending == nil
    }

    /// A message that never went gives its words back to the field they came from, unless the owner has written
    /// there since. A 422 has already taken the words off the phone, so nothing comes back from one.
    private func giveBack(_ request: PendingRequest) {
        // His message under a card goes back to that card's field, never to a chat's: while the card is open on this
        // hub and generation, and the field holds no words of his since (after a start of the app it holds none, and
        // the words were gone with the Discard; review A of 20 November 2026).
        if let needID = request.talkNeed {
            // (only to a card that still takes a message, whose field shows them: review A, round 2)
            if !request.text.isEmpty, request.hub == hub, request.database == snapshot?.db,
               openNeeds.first(where: { $0.id == needID })?.clarifies(features: Array(features)) == true,
               clarifyDraft(for: needID).isEmpty {
                setClarifyDraft(request.text, for: needID)
            }
            return
        }
        guard request.needID == nil, request.command == nil, !request.text.isEmpty else { return }
        if let replaced = request.replacesRequestID {
            if correcting?.key == replaced, correctionText.isEmpty { correctionText = request.text }
        } else {
            let name = request.recipient ?? "manager"
            if draft(for: name).isEmpty { setDraft(request.text, for: name) }
        }
    }

    private func transmit(_ request: PendingRequest) async {
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            if request.command != nil {
                // his message under a card: a command, whose receipt carries the card's talk
                let receipt = try await client.command(request, key: key)
                try finish(request, talk: receipt.talk)
            } else {
                let receipt = try await client.send(request, key: key)
                try finish(request, editedInPlace: receipt.edited == true
                    ? receipt.message_request_id ?? request.replacesRequestID : nil)
            }
        } catch {
            // A read in between may have found the hub's own event for this request already.
            guard pending?.requestID == request.requestID else { return }
            if case MobileError.refusal(let refusal, _) = error, refusal.status == 422 {
                // The hub does not say which words are a login. Every draft of this phone goes, with the request.
                secretRefusals += 1
                drafts = [:]
                answers = [:]
                clarifyDrafts = [:]
                UserDefaults.standard.set(drafts, forKey: "agentDrafts")
                UserDefaults.standard.set(answers, forKey: "answerDrafts")
                cancelCorrection()
                do { pending = try outbox.rejectSecret(matching: request.requestID, drafts: .standard) }
                catch { storageError = String(l10n: "Cannot remove the refused text from this phone. Sending is blocked.") }
                sendError = String(l10n: "The hub refused registered login text. The text and the drafts are gone from this phone.")
            } else if let error = error as? MobileError, error.isDefinitive, case .control? = request.command {
                // **A refused Pause ends by itself** (the review of 21 November 2026): the hub changed nothing (a task
                // that ended between two reads, one that a hold holds already), its card shows the task as the next
                // read has it, and nothing waits for a Discard that only Settings offered while every later write of
                // the phone waited behind it
                do {
                    try outbox.clear(matching: request.requestID)
                    pending = nil
                } catch {
                    storageError = String(l10n: "Cannot clear the refused request. Sending is blocked.")
                    storageErrorDetail = error.localizedDescription
                }
                authProblem = error.auth
                // its card says why, in the phone's words of a refused write, until his Discard (`pauseState`)
                if case .control(let task, _)? = request.command {
                    var refused = request
                    refused.refuse(because: error)
                    pauseRefusals[task] = PauseRefusal(hub: request.hub, database: request.database,
                                                       words: refused.notSentLine ?? error.notSentWords)
                }
            } else if let error = error as? MobileError, error.isDefinitive {
                var refused = request
                // What the hub refused is kept as its fields, and the words are made when the owner reads them, in the
                // language of that day (`PendingRequest.notSentLine`).
                refused.refuse(because: error)
                do { try outbox.save(refused); pending = refused }
                catch { storageError = String(l10n: "Cannot save the refusal. The request is kept as it was.") }
                sendError = error.notSentWords
                authProblem = error.auth
            } else {
                // One failure, one way on (T-35): the row's Try again. The number it keeps is why a second press
                // is safe, so that is what the words say, and the number itself stays off the screen.
                sendError = String(l10n: "Your hub did not confirm it. Sending it again does not send it twice.")
            }
        }
        // (the read after a receipt decides whether the item folds: `decideTaken`)
        await refresh()
        // the read after a Pause's receipt has its hold, or the next one has
        if case .control(let task, _)? = request.command { pausesTaken.remove(task) }
    }

    /// **The answer that the hub took stays taken until a read that began after its receipt worked** (the owner, 22
    /// November 2026: "cards on the phone are left with Sending... and never complete"): that read decides, and a read
    /// that failed, or that did not run (the app is not in front, this phone's key is not in hand), leaves it to the
    /// next one. Its item is no longer open: it folds away as answered. It is still open: it does not fold, and its
    /// answer is not on its way. The read that the send makes after its receipt decided alone, also when it failed or
    /// did not run, so the card that he answered stood open again with no sign, and a second press met the hub's
    /// "already answered".
    private func decideTaken(before run: Int) {
        for (need, at) in takenAtRead where at < run {
            takenAtRead[need] = nil
            if openNeeds.contains(where: { $0.id == need }) { answersTaken[need] = nil }
        }
    }
    /// The reads that began, and for each answer that the hub took the count at its receipt, until a read that began
    /// after it worked (`decideTaken`).
    @ObservationIgnored private var readsBegun = 0
    @ObservationIgnored private var takenAtRead: [Int: Int] = [:]

    /// The hub confirmed this request: it leaves the Outbox, and its draft or its correction ends. `editedInPlace`: the
    /// hub changed that message itself and wrote no message of its own (review A2), so its words change where it
    /// stands, in the chat the phone keeps, and no bubble waits at the end for a message that never comes.
    private func finish(_ request: PendingRequest, editedInPlace original: String? = nil,
                        talk: [NeedMessage]? = nil) throws {
        try outbox.clear(matching: request.requestID)
        // **A task's Pause** (`pause(task:)`): no message and no answer. Its card's Pause stays away until the read
        // after it, which has the hold.
        if case .control(let task, _)? = request.command {
            if request.hub == hub, request.database == snapshot?.db { pausesTaken.insert(task) }
            pending = nil
            sendError = nil
            return
        }
        if let needID = request.talkNeed {
            // **His message under a card**: it leaves its field, which goes back to its link (`talkReceipts`), and it
            // stands in the card's talk from the receipt (`talkTaken`). It is no answer and no message of a chat: the
            // card stays open, and no bubble waits for it anywhere. (A receipt that came after he moved to another hub
            // or generation changes none of its cards: their numbers are others' items.)
            if request.hub == hub, request.database == snapshot?.db {
                if clarifyDraft(for: needID).trimmingCharacters(in: .whitespacesAndNewlines) == request.text {
                    clarifyDrafts[needID] = nil
                }
                // (a late Try again gets the hub's first result, whose talk can be shorter than the reading's)
                let read = ((snapshot?.needs ?? []) + (snapshot?.answered_needs ?? [])).first { $0.id == needID }?.talk
                if let talk, talk.count > (read ?? []).count { talkTaken[needID] = talk }
                talkReceipts[needID, default: 0] += 1
            }
            pending = nil
            sendError = nil
            return
        }
        if let replaced = request.replacesRequestID {
            if correcting?.key == replaced { cancelCorrection() }
        } else if let needID = request.needID {
            if answerDraft(for: needID).trimmingCharacters(in: .whitespacesAndNewlines) == request.text {
                setAnswerDraft("", for: needID)
            }
            if request.clarifies { clarifyDrafts[needID] = nil }
            let sentFiles = stagedFiles(for: Self.stageKey(need: needID)).filter {
                $0.attachmentID.map(request.attachments.contains) == true
            }
            clearStaged(Self.stageKey(need: needID), sent: request.attachments)
            answersTaken[needID] = TakenAnswer(request: request, files: sentFiles)
            takenAtRead[needID] = readsBegun
            // **What he wrote to a request is his message in the chat of the agent that asked** (`deliveredAnswers`):
            // its bubble stands from the send until that chat's read brings the message itself, as a message's does.
            // An option that he pressed is no message: its card shows it.
            if request.answersInWords {
                writtenAnswers.insert(request.requestID.uuidString.lowercased())
                if !request.text.isEmpty, !chatItems.values.contains(where: { Self.holds(request, in: $0) }),
                   !deliveredAnswers.contains(where: { $0.requestID == request.requestID }) {
                    deliveredAnswers.append(request)
                }
            }
        } else {
            let name = request.recipient ?? "manager"
            if draft(for: name).trimmingCharacters(in: .whitespacesAndNewlines) == request.text { setDraft("", for: name) }
            clearStaged(Self.stageKey(agent: name), sent: request.attachments)
        }
        let name = request.recipient ?? "manager"
        if let original, request.needID == nil {
            if let held = chatItems[name] {
                chatItems[name] = Self.edit(held, message: original, to: request.text)
                keepChats()
            }
        } else if request.needID == nil, !Self.holds(request, in: items(for: name)) {
            // A message whose chat already holds it (the read that confirmed it brought it) needs no bubble of its own.
            delivered = request
        }
        pending = nil
        sendError = nil
    }

    /// The hub's own event of this request is in these items: a message is known by its request number.
    private static func holds(_ request: PendingRequest, in items: [MobileChatItem]) -> Bool {
        items.contains { $0.kind == .message && $0.key.caseInsensitiveCompare(request.requestID.uuidString) == .orderedSame }
    }

    /// What the waiting request is, for Settings and for the chat.
    var pendingSummary: String {
        guard let pending else { return "" }
        if let need = pending.needID { return String(l10n: "Answer to item \(need)") }
        // a task's Pause from an answered card: the command's own name, "Pause the task"
        if let command = pending.command, case .control = command { return command.label }
        // his message under a card goes to the agent that raised it, which only a reading of its own hub and
        // generation names: another one's item of that number is another card
        if let need = pending.talkNeed {
            let by = pending.hub == hub && pending.database == snapshot?.db
                ? snapshot?.needs.first { $0.id == need }?.by : nil
            return String(l10n: "Message to \(agentName(by ?? "manager"))")
        }
        let name = agentName(pending.recipient ?? "manager")
        return pending.replacesRequestID == nil ? String(l10n: "Message to \(name)") : String(l10n: "Correction to \(name)")
    }
}
