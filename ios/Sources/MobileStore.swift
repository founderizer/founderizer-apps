import CoreGraphics
import FleetCore
import Foundation
import Observation
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
    var openTask: Int? { taskRoute.last }
    /// A chat or a task is open, so the app reads more often.
    var detailIsOpen: Bool { openChat != nil || openTask != nil }
    /// Seconds between two reads. A waiting request reads often too, so its receipt shows soon.
    var readSeconds: Int { detailIsOpen || pending != nil ? 10 : Self.restingSeconds }
    /// The cadence of a tab with nothing waiting: the slowest one.
    static let restingSeconds = 30

    // MARK: What the hub said

    private(set) var snapshot: MobileSnapshot? {
        // Each agent's role, for every line of the app that names an agent (`AgentNames`), as on the Mac.
        didSet { AgentNames.shared.read((snapshot?.agents ?? []).map { ($0.name, $0.title) }) }
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
    /// The uploads that run now, by their own number.
    private(set) var uploading: Set<UUID> = []
    /// The bytes of the files that the pages show, by attachment number, newest last.
    private(set) var fileData: [Int: Data] = [:]
    private var fileOrder: [Int] = []
    private var fileReads: Set<Int> = []
    /// The pictures of the chats, drawn once from their bytes, by attachment number: a chat draws them in its first
    /// frame, and its body never decodes an image.
    private var pictures: [Int: CGImage] = [:]
    @ObservationIgnored private var pictureOrder: [Int] = []
    /// The pictures that the background reads (`readPictures`) still have to bring, and the ones that did not come.
    @ObservationIgnored private var picturesWaiting: [MessageAttachment] = []
    @ObservationIgnored private var picturesFailed: Set<Int> = []
    /// The pictures whose bytes did not come, which their tile says, with its ↻ (D-7).
    private(set) var notLoaded: Set<Int> = []
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
            storageError = "Cannot read the saved request. Sending is blocked."
            storageErrorDetail = error.localizedDescription
        }
        // A refused write of the sample fleet, which a launch that ended in the sample left: the sample is not kept.
        if let left = pending, left.hub == SampleHub.address, (try? outbox.clear(matching: left.requestID)) != nil {
            pending = nil
        }
        keyState = deviceKey.has ? .locked : .none
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
            key = try await deviceKey.key(reason: "Founderizer uses this phone's own key to reach the hub.")
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
        case .locked: "This phone's key is locked. Unlock it in Settings to read the hub."
        // The keychain's own words go to VoiceOver (`keyDetail`), not on the screen.
        case .failed: "This phone's key did not open. Unlock it in Settings to read the hub."
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
            return "A code is eight characters, as the Mac app shows it (XXXX-XXXX)."
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
                return "This phone could not keep its key. Make a new code."
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
            return "The hub did not take the code."
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
    func openLink(_ url: URL) async {
        guard let query = Self.enrollItems(url) else { return }
        let code = query.first { $0.name == "code" }?.value ?? ""
        let bind = query.first { $0.name == "bind" }?.value
        // No read of the hub until the enrolment has answered (`joining`): the move to the hub reads nothing.
        joining = true
        defer { joining = false }
        if let text = query.first(where: { $0.name == "hub" })?.value, let address = try? MobileClient.address(text),
           address != hub {
            guard !deviceKey.has else {
                showEnrollment(code, problem: "This code is for another hub. Forget this phone's key in Settings first.",
                               otherHub: true)
                return
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
    /// of every Mac until then, and stays. `https://founderizer.com/enroll#hub=…&code=…` is the new one: the phone's
    /// camera opens it here through the app's associated domain, and on a phone without the app in Safari, where the
    /// website's `/enroll` sends it to the App Store. Its values ride in the fragment, which a browser never sends, so
    /// a phone without the app gives the website no code and no hub address. nil for any other link.
    nonisolated static func enrollItems(_ url: URL) -> [URLQueryItem]? {
        let scheme = url.scheme?.lowercased(), host = url.host()?.lowercased()
        if scheme == "fleet", host == "enroll" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        }
        guard scheme == "https", host == "founderizer.com", url.path() == "/enroll",
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
        } catch { return ("Cannot take the key off this phone.", error.localizedDescription) }
    }

    // MARK: The read loop

    /// The app came to the front, or left it. It reads nothing in the background: a ping will bring it forward
    /// (MOBILE-APP.md 9). The key is taken once when it comes forward and dropped when it leaves.
    func setForeground(_ value: Bool) {
        // **The app that hosts the unit tests reads no hub** (fix round 2): it starts with no hub address of a check's
        // own, and the built-in one is the owner's real hub, which no test may reach.
        guard !Self.hostsTests else { return }
        guard value != isForeground else { return }
        isForeground = value
        if value {
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
            key = nil
            if keyState == .ready { keyState = .locked }
        }
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
        if snapshot == nil, fleetSince == nil { fleetSince = .now }
        refreshing = true
        guard !keyIsHeldBack else { refreshing = false; clock = Date(); return }
        let requested = hub
        defer { refreshing = false; clock = Date() }
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
            lastRead = Date()
            // The read answered: the reading is current again, and the next read's hold follows this one's time.
            lastRequestTook = slowestRequest
            if readHeld { readHeld = false }
            readError = nil
            readWasRefused = false
            authProblem = nil
            await preparePush()
        } catch is CancellationError {
            return
        } catch {
            guard requested == hub else { return }
            // A generation change makes everything that the phone holds stale. Drop it and read the new one at once:
            // the clock's next read was up to 30 seconds away, with nothing on the pages until then.
            if case MobileError.refusal(409, _, _) = error {
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
        catch MobileError.refusal(404, _, _) { throw MobileError.noPhoneRoutes }
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
            defer { self?.chatsReading = nil }
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
    /// Needs-you item is confirmed by its own receipt or by Retry, which replays the same number.
    private func confirmPending(hub requested: URL, database: String) async throws {
        guard let request = pending, request.refusal == nil, request.hub == requested,
              request.database == database, request.needID == nil, !sending else { return }
        let agent = request.recipient ?? "manager"
        let page = try await client.chat(at: requested, key: key, database: database, agent: agent, since: nil)
        let found = Self.held(request, in: page.items)
        guard requested == hub, pending?.requestID == request.requestID, found.held else { return }
        do { try finish(request, editedInPlace: found.inPlace) }
        catch {
            storageError = "Cannot clear the confirmed request. Sending is blocked."
            storageErrorDetail = error.localizedDescription
        }
    }

    /// Everything that belonged to one hub generation goes: its pages, its cursors and its tag. The waiting request
    /// stays, because it names its own hub and generation and Settings says so.
    private func forgetGeneration(keepSnapshot: Bool = false) {
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
        answersTaken = [:]
        picturesReading?.cancel()
        picturesReading = nil
        picturesWaiting = []
        picturesFailed = []
        notLoaded = []
        // A new generation numbers its files from the start again: what this phone holds of the old one goes.
        pictures = [:]
        pictureOrder = []
        fileData = [:]
        fileOrder = []
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
    /// which were never kept (`setDraft`), so the drafts of before it come back.
    private func endSample() {
        sample = false
        if let left = pending, left.hub == SampleHub.address, (try? outbox.clear(matching: left.requestID)) != nil {
            pending = nil
        }
        sendError = nil
        fileFailed(nil)
        drafts = UserDefaults.standard.dictionary(forKey: "agentDrafts") as? [String: String] ?? [:]
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
        guard !hasNoHub, !isFresh, !firstReadWaits else { return nil }
        // The key comes first: when this phone holds one that is not in hand, that is the whole reason, and the
        // hub's own refusal would send the owner to make a new code for something a Face ID prompt gives back.
        if let words = keyWords { return words }
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
    /// The newest answered items, for the folded cards of the chats (fix round 2, item 103).
    var answeredNeeds: [OwnerNeed] { snapshot?.answered_needs ?? [] }
    /// The open tasks, newest activity first.
    var openTasks: [MobileTaskHead] { sorted(snapshot?.tasks ?? []) }
    /// The last tasks that ended, newest first.
    var endedTasks: [MobileTaskHead] { sorted(snapshot?.recent ?? []) }
    /// The holds that still hold a task, and the outcomes that the owner must record.
    var openHolds: [TaskHold] { snapshot?.holds ?? [] }
    var openOutcomes: [TaskOutcome] { (snapshot?.outcomes ?? []).filter { $0.state == "unknown" } }
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
                                 words: "Outcome not known: check it", symbol: "questionmark.circle")
            }
            return OwnerTask(id: id, title: head?.title ?? "Task", owner: head?.owner,
                             words: "Stop not confirmed", symbol: "exclamationmark.circle")
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
        return Self.thinks(entry, items: items(for: name), time: snapshot.time, hubSays: features.contains("chat_waits"))
    }

    static func thinks(_ entry: MobileAgent, items: [MobileChatItem], time: Double, hubSays: Bool) -> Bool {
        // nor while his message does not arrive, which the hub says of a server that answers (`chat_undelivered`)
        guard entry.active != false, entry.limit == nil, entry.helperIsRecent(serverTime: time),
              entry.chat_undelivered != true else { return false }
        if hubSays {
            guard let sent = entry.waits_since else { return false }
            return !ChatWaiting.turnIsOver(sent: sent, turnEndedAfter: entry.turn_ended_after)
        }
        guard let last = entry.last, let newest = items.map(\.ts).max(), newest >= last.ts - 0.001 else { return false }
        return ChatPage.pending(in: items, turnEndedAfter: entry.turn_ended_after) == .waiting
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

    /// A write may go: the hub answered the last read (`answersWrites`), nothing else waits for its receipt, and the
    /// Outbox can be used. One request at a time, as on the Mac.
    var canWrite: Bool { answersWrites && !sending && pending == nil && storageError == nil }

    /// The waiting request may be sent again, with its own number. A refused one may not: its refusal is definitive.
    var canRetry: Bool {
        guard let pending else { return false }
        return answersWrites && !sending && storageError == nil && pending.refusal == nil &&
            pending.hub == hub && pending.database == snapshot?.db
    }

    // MARK: The drafts

    func draft(for name: String) -> String { drafts[name] ?? "" }
    /// A draft is kept across a force quit, except one written in the sample fleet, which ends with the sample.
    func setDraft(_ text: String, for name: String) {
        guard drafts[name] ?? "" != text else { return }
        if text.isEmpty { drafts[name] = nil } else { drafts[name] = text }
        if !sample { UserDefaults.standard.set(drafts, forKey: "agentDrafts") }
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
            fileFailed(MobileError.refusal(status: 409, auth: nil, message: SampleHub.refusal).notSentWords)
            return
        }
        guard stagedFiles(for: composer).count < MessageAttachment.perMessage else {
            fileFailed("A message carries at most \(MessageAttachment.perMessage) files.")
            return
        }
        guard MessageAttachment.types[mime] != nil else { fileFailed(AttachmentError.type.errorDescription); return }
        guard !data.isEmpty, data.count <= MessageAttachment.sizeLimit else {
            fileFailed(AttachmentError.tooLarge.errorDescription)
            return
        }
        let file = StagedFile(requestID: UUID(), name: MessageAttachment.safeName(name, mime: mime), mime: mime,
                              size: data.count)
        do { try write(data, of: file) }
        catch {
            fileFailed("Cannot keep this file on the phone. Nothing was sent.", detail: error.localizedDescription)
            return
        }
        fileFailed(nil)
        staged[composer, default: []].append(file)
        keepStaged()
        await upload(file, for: composer)
    }

    /// Sends one staged file up, with its own number. A file that is already on the hub never goes again.
    func upload(_ file: StagedFile, for composer: String) async {
        guard let snapshot, !file.isOnHub, !uploading.contains(file.requestID) else { return }
        guard let data = try? Data(contentsOf: stagedURL(file)) else {
            change(file, in: composer) { $0.failure = "The bytes of this file are gone from the phone. Pick it again." }
            return
        }
        uploading.insert(file.requestID)
        defer { uploading.remove(file.requestID) }
        change(file, in: composer) { $0.failure = nil }
        do {
            let sent = try await client.upload(data, name: file.name, mime: file.mime, requestID: file.requestID,
                                               client: installation, hub: hub, key: key, database: snapshot.db)
            change(file, in: composer) { $0.attachmentID = sent.id; $0.failure = nil }
        } catch {
            if let error = error as? MobileError { authProblem = error.auth }
            change(file, in: composer) {
                $0.failure = (error as? LocalizedError)?.errorDescription ?? "The file did not go up."
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

    /// The bytes of one file of a message, for the page that shows it. Nothing is kept before its size and its
    /// SHA-256 match what the hub said.
    /// `quietly`: a read in the background, which says nothing when it fails; the page's own read says it.
    func load(_ file: MessageAttachment, quietly: Bool = false) async {
        if let data = fileData[file.id] {
            if file.isImage, pictures[file.id] == nil { keepPicture(data, of: file.id) }
            return
        }
        guard let snapshot, !fileReads.contains(file.id) else { return }
        fileReads.insert(file.id)
        defer { fileReads.remove(file.id) }
        do {
            let data = try await client.attachment(file, hub: hub, key: key, database: snapshot.db)
            fileData[file.id] = data
            fileOrder.append(file.id)
            while fileOrder.count > 12, let oldest = fileOrder.first {
                fileData[oldest] = nil
                fileOrder.removeFirst()
            }
            if file.isImage { keepPicture(data, of: file.id) }
            notLoaded.remove(file.id)
        } catch {
            // A picture that did not come says so on its own tile, with the ↻ that reads it again; the line under
            // the composer is for a file that is not a picture.
            if file.isImage { notLoaded.insert(file.id) }
            if quietly { picturesFailed.insert(file.id); return }
            if let error = error as? MobileError { authProblem = error.auth }
            if !file.isImage { fileFailed((error as? LocalizedError)?.errorDescription ?? "This file did not come.") }
        }
    }

    /// The owner pressed ↻ on a picture that did not come: its tile reads it again at once.
    func readAgain(_ file: MessageAttachment) async {
        notLoaded.remove(file.id)
        picturesFailed.remove(file.id)
        await load(file)
    }

    /// The picture of an image file, once its bytes came.
    func picture(_ id: Int) -> CGImage? { pictures[id] }

    /// At most 60 pictures stay drawn, the newest last.
    private func keepPicture(_ data: Data, of id: Int) {
        guard let picture = MessageAttachment.thumbnail(data, maxPixels: 640) else { return }
        pictures[id] = picture
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
        let queued = Set(picturesWaiting.map(\.id))
        let missing = chatItems.values.flatMap { $0.suffix(20).flatMap(\.attachments) }.filter {
            $0.isImage && pictures[$0.id] == nil && !queued.contains($0.id) && !picturesFailed.contains($0.id)
        }
        picturesWaiting += missing
        guard picturesReading == nil, !picturesWaiting.isEmpty else { return }
        picturesReading = Task { [weak self] in
            defer { self?.picturesReading = nil }
            while let store = self, !Task.isCancelled, !store.picturesWaiting.isEmpty {
                let file = store.picturesWaiting.removeFirst()
                await store.load(file, quietly: true)
            }
        }
    }

    // MARK: The writes

    /// A message to one agent. The manager's chat is where the owner writes a goal, as on the Mac.
    func send(to name: String) async {
        await write(draft(for: name), recipient: name, files: readyFiles(for: Self.stageKey(agent: name)))
    }

    /// One answer to one open item of Needs you. It goes to the agent that raised the item.
    func send(needID: Int) async {
        guard let need = snapshot?.needs.first(where: { $0.id == needID }) else { return }
        await write(answerDraft(for: needID), needID: needID, recipient: need.by,
                    files: readyFiles(for: Self.stageKey(need: needID)))
    }

    /// **The presses on an item's own options that wait until the hub can take them**, by item: the newest press of an
    /// item wins (fix round 2, item 51).
    private(set) var waitingPresses: [Int: Int] = [:]

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

    /// **A press on one of an item's options is never refused for a moment**, and its rows are never drawn grey (fix
    /// round 2, item 51): it goes at once when the hub can take a write; otherwise it waits — for this launch's first
    /// answer, for the hub to answer again, for the write before it — and goes then, while its item says "Sending…".
    /// Nothing goes on a reading the hub has not confirmed: the press goes only through `send`, which asks `canWrite`,
    /// and only while the item is still open on the same hub and generation; else it is dropped, and nothing went.
    func press(needID: Int, choice: Int) {
        guard canWrite else {
            waitingPresses[needID] = choice
            guard pressWaits[needID] == nil else { return }
            let hub = hub, database = snapshot?.db
            pressWaits[needID] = Task { [weak self] in
                while let store = self, !Task.isCancelled {
                    guard store.hub == hub, store.snapshot?.db == database, store.storageError == nil,
                          store.openNeeds.contains(where: { $0.id == needID }), let choice = store.waitingPresses[needID]
                    else { break }
                    if store.canWrite {
                        store.waitingPresses[needID] = nil
                        store.pressWaits[needID] = nil
                        await store.send(needID: needID, choice: choice)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                self?.waitingPresses[needID] = nil
                self?.pressWaits[needID] = nil
            }
            return
        }
        waitingPresses[needID] = nil
        Task { await send(needID: needID, choice: choice) }
    }

    /// One answer to one open item by one of the options its agent offered (owner feature `need_options`): the hub
    /// writes that option's own words as the answer, as a press on the ping's button does. It goes as every write
    /// goes, through the Outbox and once.
    func send(needID: Int, choice: Int) async {
        guard let need = snapshot?.needs.first(where: { $0.id == needID }), need.choices.indices.contains(choice)
        else { return }
        await write(need.choices[choice], needID: needID, recipient: need.by, choice: choice,
                    approval: DeviceSigningKey().approval(for: need, choice: choice))
    }

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
    /// stay in the history: the hub keeps both events.
    func sendCorrection(in name: String) async {
        guard let item = correcting, canCorrect(item, in: name) else { return }
        await write(correctionText, recipient: name, replaces: item.key)
    }

    /// Saves the request, then sends it. The order is the rule: the Outbox holds the number and the text before the
    /// hub hears anything, so a crash, a timeout or a force quit can never make a second message. The app makes no
    /// new number for a request that already exists (MOBILE-APP.md 5.4 and 10).
    private func write(_ value: String, needID: Int? = nil, recipient: String, replaces: String? = nil,
                       files: [Int] = [], choice: Int? = nil,
                       approval: (statement: String, signature: String)? = nil) async {
        guard canWrite, let snapshot else { return }
        guard needID != nil || canChat(with: recipient) else { return }
        guard files.isEmpty || supportsAttachments else { return }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A message carries text, or files, or both. Without a file it must carry text, as the hub asks.
        guard !text.isEmpty || !files.isEmpty, text.count <= Self.textLimit else { return }
        if let needID, !openNeeds.contains(where: { $0.id == needID }) { return }
        let request = PendingRequest(hub: hub, database: snapshot.db, client: installation, needID: needID,
                                     choice: choice, recipient: needID == nil && supportsDirectChat ? recipient : nil,
                                     replacesRequestID: replaces, attachments: files, approval: approval, text: text)
        if let needID { answersTaken[needID] = nil }
        do {
            try outbox.save(request)
            pending = request
        } catch {
            storageError = "Cannot save this request. Nothing was sent."
            storageErrorDetail = error.localizedDescription
            return
        }
        // The bubble is the message now: its words leave the field in the frame the bubble comes in. They stood in
        // both while the message went. A message that is refused gives them back when the owner discards it.
        if needID == nil {
            if replaces == nil { setDraft("", for: recipient) } else { correctionText = "" }
        }
        await transmit(request)
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
        do {
            try outbox.clear(matching: pending.requestID)
            self.pending = nil
            sendError = nil
            giveBack(pending)
        } catch {
            storageError = "Cannot clear the refused request. Sending is blocked."
            storageErrorDetail = error.localizedDescription
        }
    }

    /// A message that never went gives its words back to the field they came from, unless the owner has written
    /// there since. A 422 has already taken the words off the phone, so nothing comes back from one.
    private func giveBack(_ request: PendingRequest) {
        guard request.needID == nil, !request.text.isEmpty else { return }
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
            let receipt = try await client.send(request, key: key)
            try finish(request, editedInPlace: receipt.edited == true
                ? receipt.message_request_id ?? request.replacesRequestID : nil)
        } catch {
            // A read in between may have found the hub's own event for this request already.
            guard pending?.requestID == request.requestID else { return }
            if case MobileError.refusal(422, _, _) = error {
                // The hub does not say which words are a login. Every draft of this phone goes, with the request.
                secretRefusals += 1
                drafts = [:]
                answers = [:]
                UserDefaults.standard.set(drafts, forKey: "agentDrafts")
                UserDefaults.standard.set(answers, forKey: "answerDrafts")
                cancelCorrection()
                do { pending = try outbox.rejectSecret(matching: request.requestID, drafts: .standard) }
                catch { storageError = "Cannot remove the refused text from this phone. Sending is blocked." }
                sendError = "The hub refused registered login text. The text and the drafts are gone from this phone."
            } else if let error = error as? MobileError, error.isDefinitive {
                var refused = request
                refused.refusal = error.notSentWords
                do { try outbox.save(refused); pending = refused }
                catch { storageError = "Cannot save the refusal. The request is kept as it was." }
                sendError = error.notSentWords
                authProblem = error.auth
            } else {
                // One failure, one way on (T-35): the row's Try again. The number it keeps is why a second press
                // is safe, so that is what the words say, and the number itself stays off the screen.
                sendError = "Your hub did not confirm it. Sending it again does not send it twice."
            }
        }
        await refresh()
        // The read after the receipt still lists the item as open: it does not fold, and its answer is not on its way.
        if let needID = request.needID, answersTaken[needID] != nil, openNeeds.contains(where: { $0.id == needID }) {
            answersTaken[needID] = nil
        }
    }

    /// The hub confirmed this request: it leaves the Outbox, and its draft or its correction ends. `editedInPlace`: the
    /// hub changed that message itself and wrote no message of its own (review A2), so its words change where it
    /// stands, in the chat the phone keeps, and no bubble waits at the end for a message that never comes.
    private func finish(_ request: PendingRequest, editedInPlace original: String? = nil) throws {
        try outbox.clear(matching: request.requestID)
        if let replaced = request.replacesRequestID {
            if correcting?.key == replaced { cancelCorrection() }
        } else if let needID = request.needID {
            if answerDraft(for: needID).trimmingCharacters(in: .whitespacesAndNewlines) == request.text {
                setAnswerDraft("", for: needID)
            }
            let sentFiles = stagedFiles(for: Self.stageKey(need: needID)).filter {
                $0.attachmentID.map(request.attachments.contains) == true
            }
            clearStaged(Self.stageKey(need: needID), sent: request.attachments)
            answersTaken[needID] = TakenAnswer(request: request, files: sentFiles)
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
        if let need = pending.needID { return "Answer to item \(need)" }
        let name = agentName(pending.recipient ?? "manager")
        return pending.replacesRequestID == nil ? "Message to \(name)" : "Correction to \(name)"
    }
}
