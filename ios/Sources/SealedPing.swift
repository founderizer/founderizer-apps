import CryptoKit
import Foundation
import Security
import UserNotifications

/// This phone's own key for what a ping says (`UI-API.md` version 1.76, feature `sealed_push`). Every hub sends its
/// pings through the platform, so the hub seals the agent's name, the item's title and its options with this key,
/// and the platform and Apple carry only "Needs you", the item's number and the sealed bytes. The app makes the key
/// once and gives it to the hub with its push token; the notification service extension (`NeedSeal`) reads it to open
/// a ping. So it is kept in a keychain group that both share, and readable after the first unlock since the phone
/// started, because a ping arrives on a locked phone too. It opens pings and nothing else: it is no key to the hub.
struct SealKey: Sendable {
    /// The keychain group of the app and its extension: the team's prefix and a name of the app's own.
    static let group = "6EBZ756H9Q.com.founderizer.mobile.seal"
    private let service = "com.founderizer.mobile.seal"
    private let account: String

    /// A check names an item of its own, so that it never replaces the key of a phone that gets pings.
    init(account: String = "seal-key") {
        self.account = account
    }

    /// The key, made the first time that the app gives its push token. nil when the keychain refuses it.
    func current() -> Data? {
        if let key = read() { return key }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var item = base
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess: return key
        case errSecDuplicateItem: return read()
        default: return nil
        }
    }

    /// The key, or nil while this phone has made none.
    func read() -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let key = item as? Data,
              key.count == 32 else { return nil }
        return key
    }

    func remove() {
        SecItemDelete(base as CFDictionary)
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: Self.group]
    }
}

/// What a sealed ping says, once this phone's key has opened it: the item and the hub's generation, the agent that
/// asks (the banner's title), the item's title (its text) and its options when each fits a button. The hub seals it
/// with ChaCha20-Poly1305, and the bytes are CryptoKit's `SealedBox` combined: the nonce, the sealed text and the tag.
struct SealedPing: Equatable, Sendable {
    let need: Int
    let db: String
    let title: String
    let body: String
    let options: [String]?
    /// API 1.245: the indexes of the options that get no button, because only the Mac presses them (Full access on a
    /// door card); the other buttons keep their own index. Empty on every other ping.
    var noButton: [Int] = []

    /// The ping that a notification carries, or nil: no sealed part, no key, or a part that this key does not open.
    /// Only the owner's form (B9, `PingForm.owner`) is opened with this key: never a member ping, whatever its part holds.
    static func open(_ info: [AnyHashable: Any], key: Data?) -> SealedPing? {
        guard PingForm.of(info) == .owner, let text = info["sealed"] as? String, let combined = Data(base64Encoded: text), let key, key.count == 32,
              let box = try? ChaChaPoly.SealedBox(combined: combined),
              let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: key)),
              let said = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let need = (said["need"] as? NSNumber)?.intValue, let db = said["db"] as? String,
              let title = said["title"] as? String, let body = said["body"] as? String
        else { return nil }
        let options = said["options"] as? [String]
        return SealedPing(need: need, db: db, title: title, body: body, options: options?.isEmpty == false ? options : nil,
                          noButton: said["no_button"] as? [Int] ?? [])
    }

    /// Shows what the ping says on the notification that iOS is about to show (`NeedSeal`): the agent as the title,
    /// the item's title as the text, the item and the generation that a press answers, and the options with the
    /// category `need` (PushDelegate.needCategory, and NeedActions' Info.plist) when it has options. A part that does
    /// not open leaves the notification as it came. True when it opened.
    @discardableResult
    static func show(in content: UNMutableNotificationContent, key: Data?) -> Bool {
        guard let said = open(content.userInfo, key: key) else { return false }
        content.title = said.title
        content.body = said.body
        var info = content.userInfo
        info["sealed"] = nil
        info["need"] = said.need
        info["db"] = said.db
        if let options = said.options {
            info["options"] = options
            if !said.noButton.isEmpty { info["no_button"] = said.noButton }
            content.categoryIdentifier = "need"
        }
        content.userInfo = info
        return true
    }
}

// MARK: - B9: a ping to a member's phone (m5)
//
// The iPhone app of a company's people (b9-phone-members.md, section 5 and 10.10; the hub's side is
// `teams_links.member_ping`, the vectors `app/vectors/agent-sharing-vectors.json`, `member`). A member's phone holds one
// seal key for each link to a company, and that company's hub seals each ping to the phone with it. A ping of that kind
// says no word: the open part is the same for every member ping of every fleet, the phone draws its own words for it
// ("New reply in a shared chat", with no name: the owner's answer b9-q3), and nothing on it is pressed. A tap opens the
// chat that the part names, in the link whose key opened it, by the phone's own record of that link.

/// **The forms of a ping**, by its open part, as the vectors' rule (`member.forms`) tells them apart. The phone tries its
/// link keys on the member form only and the owner's key on the owner's form only, so no key reads the other kind.
enum PingForm: Equatable, Sendable {
    /// `{"aps":{"alert":{"loc-key":"shared-reply"},"mutable-content":1},"sealed":…}`, with no other key; `aps` may
    /// also have `"sound":"default"`, as the platform's member route sends it. Never a badge: no hub sets the number on
    /// a member's icon (b9-phone-members.md, 10.7).
    case member
    /// The owner's own hub (`hub.py` ping_payload): `need` and `db` beside `aps`.
    case owner
    /// Neither: nothing of it is opened.
    case other

    /// The member ping's `loc-key`: the hub's `teams_links.MEMBER_WORD`, a key of the app's own words.
    static let memberWord = "shared-reply"
    static let memberAps: Set<String> = ["alert", "mutable-content", "sound"]

    static func of(_ info: [AnyHashable: Any]) -> PingForm {
        let keys = Set(info.keys.compactMap { $0.base as? String })
        guard keys.count == info.count else { return .other }
        if keys.contains("need") && keys.contains("db") { return .owner }
        guard keys == ["aps", "sealed"], info["sealed"] is String, let aps = info["aps"] as? [String: Any],
              Set(aps.keys).isSubset(of: memberAps), (aps["mutable-content"] as? NSNumber)?.intValue == 1,
              aps["sound"] == nil || aps["sound"] as? String == "default",
              let alert = aps["alert"] as? [String: Any], alert.count == 1,
              alert["loc-key"] as? String == memberWord else { return .other }
        return .member
    }
}

/// One link's seal key (`LinkSealKeys`): the link is the phone's own id of it, never a value of the ping.
struct LinkSeal: Equatable, Sendable {
    let link: UUID
    let key: Data
}

/// **The seal key of each link** (b9-phone-members.md, section 5, point 1, and 10.10): 32 random bytes that the phone
/// makes for one link to one company and gives to that company's hub in the link's `device` request (`seal`, in b64u:
/// `wire`). Never the owner's key (`SealKey`) and never another link's: each link makes its own. They stand for now in
/// the seal group, under a service of their own, with the link's id in the account (5a's `SharedLink.id`, lowercased, as
/// the link's other keychain items name it), "after first unlock, this device only", never synced. The app opens a
/// member ping with them at the tap, on an unlocked phone; `NeedSeal` reads none of them. The app that makes the link
/// (m4) makes its key, and Leave and `ended` remove it. **For m4** (the coordinator's decision of 27 November 2026): when
/// m4 adds the app's own `.links` group, it moves these keys there, "when unlocked, this device only".
struct LinkSealKeys: Sendable {
    static let service = "com.founderizer.mobile.link-seal"
    private let service: String

    /// A check names a service of its own, so that it never takes or removes a key of a real link.
    init(service: String = LinkSealKeys.service) {
        self.service = service
    }

    /// The link's key, made the first time. nil when the keychain refuses it.
    func make(_ link: UUID) -> Data? {
        if let key = read(link) { return key }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var item = base(link)
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess: return key
        case errSecDuplicateItem: return read(link)
        default: return nil
        }
    }

    /// The link's key, or nil while it has none.
    func read(_ link: UUID) -> Data? {
        var query = base(link)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let key = item as? Data,
              key.count == 32 else { return nil }
        return key
    }

    func remove(_ link: UUID) {
        SecItemDelete(base(link) as CFDictionary)
    }

    /// Every link's key that this phone holds: what `MemberPing` tries on a member ping. An item whose account is not a
    /// link's id in its one form, or whose key is not 32 bytes, is none.
    func all() -> [LinkSeal] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccessGroup as String: SealKey.group,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let rows = found as? [[String: Any]] else { return [] }
        let links = rows.compactMap { row -> UUID? in
            guard let account = row[kSecAttrAccount as String] as? String, let link = UUID(uuidString: account),
                  Self.account(link) == account else { return nil }
            return link
        }
        return links.sorted { $0.uuidString < $1.uuidString }.compactMap { link in read(link).map { LinkSeal(link: link, key: $0) } }
    }

    /// The key as the `device` request gives it (`seal`): base64url with no padding, as the hub's `unb64u` reads it.
    static func wire(_ key: Data) -> String {
        key.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func account(_ link: UUID) -> String { link.uuidString.lowercased() }

    private func base(_ link: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account(link),
         kSecAttrAccessGroup as String: SealKey.group]
    }
}

/// **What the phone keeps of one link**, as far as a tap on a member ping needs it: the seam to the member's store
/// (m4, of 5a's `SharedLink`), which gives it for an active link only.
struct MemberLinkRecord: Equatable, Sendable {
    /// The link's heading: the company's name (`SharedLink.heading`).
    let company: String
    /// The agents of the link's `list`, one chat each.
    let chats: [String]
}

/// The phone's own record of its links (m4's store). nil for a link that it does not hold, or that is not active.
protocol MemberLinkRecords {
    func memberLink(_ link: UUID) -> MemberLinkRecord?
}

/// A tap on a member ping, as the tap found it: the ping that one link's key opened, or nil when none did. Its route
/// is found when the member's pages read it (`PushDelegate.takeMemberRoute`), because on a cold start the store and its
/// record come after the tap.
struct MemberTap: Equatable, Sendable {
    let ping: MemberPing?
}

/// Where a tap on a member ping goes.
enum MemberRoute: Equatable, Sendable {
    /// That chat of that link: the company and the chat by the phone's record, never by the part.
    case chat(link: UUID, company: String, agent: String)
    /// Chats: no key of a link opened the part, or the phone holds no record of that link or of that chat.
    case chats
}

/// **A member ping, once one link's key opened it** (`teams_links.member_ping`): the link whose key opened it, and the
/// chat that its part names. The part is `{"t":"news","agent","n"}`, padded with spaces; whatever else a hub puts in it
/// (a `need`, `options`, a title, a company or a link) is read by no one, so nothing on the notification is pressed and
/// no name comes from it.
struct MemberPing: Equatable, Sendable {
    let link: UUID
    /// The agent's id of the chat, or nil when the part names none in its form.
    let agent: String?

    /// The words of a member ping, in the phone's language: the table by `loc-key` (`PingForm.memberWord`). iOS draws
    /// them itself from the app's table; `NeedSeal` carries the same table and writes them only when iOS gave none.
    static var words: String {
        String(localized: "shared-reply", defaultValue: "New reply in a shared chat")
    }

    /// The ping, or nil: not the member form, no part that a key opens, or a part that the keys of two links open (the
    /// cipher commits to no key, so the link that a part names must be the one that only its key opens).
    static func open(_ info: [AnyHashable: Any], seals: [LinkSeal]) -> MemberPing? {
        guard PingForm.of(info) == .member, let text = info["sealed"] as? String,
              let combined = Data(base64Encoded: text), let box = try? ChaChaPoly.SealedBox(combined: combined)
        else { return nil }
        let opened = seals.compactMap { seal -> (UUID, Data)? in
            guard seal.key.count == 32, let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: seal.key))
            else { return nil }
            return (seal.link, plain)
        }
        guard opened.count == 1, let (link, padded) = opened.first else { return nil }
        let end = padded.lastIndex { $0 != 0x20 }.map { padded.index(after: $0) } ?? padded.startIndex  // the pad
        let said = try? JSONSerialization.jsonObject(with: Data(padded[padded.startIndex..<end])) as? [String: Any]
        let agent = said?["t"] as? String == "news" ? (said?["agent"] as? String).flatMap(chat) : nil
        return MemberPing(link: link, agent: agent)
    }

    /// An agent's id as the hub's `AGENT_TEXT` makes it: 1 to 64 printable ASCII characters.
    private static func chat(_ text: String) -> String? {
        (1...64).contains(text.utf8.count) && text.utf8.allSatisfy { (0x21...0x7e).contains($0) } ? text : nil
    }

    /// **Where a tap goes** (10.10, "Taps and names"): the chat of the link whose key opened the part (`ping`, nil when
    /// none did), by the phone's own record of that link as it is now, or Chats.
    static func route(_ ping: MemberPing?, records: (any MemberLinkRecords)?) -> MemberRoute {
        guard let ping, let agent = ping.agent, let record = records?.memberLink(ping.link), record.chats.contains(agent)
        else { return .chats }
        return .chat(link: ping.link, company: record.company, agent: agent)
    }

    /// The same for a ping as it came: nil for a ping that is not the member form, which is the owner's.
    static func route(_ info: [AnyHashable: Any], seals: [LinkSeal], records: (any MemberLinkRecords)?) -> MemberRoute? {
        guard PingForm.of(info) == .member else { return nil }
        return route(open(info, seals: seals), records: records)
    }

    /// **What `NeedSeal` shows for a member ping**: the approved words and nothing else, with no title, no category and
    /// so no button, and none of the owner's fields; the part stays, for the tap to open it. A ping of another form is
    /// left as it came. True for the member form.
    @discardableResult
    static func show(in content: UNMutableNotificationContent) -> Bool {
        guard PingForm.of(content.userInfo) == .member else { return false }
        content.title = ""
        content.subtitle = ""
        content.categoryIdentifier = ""
        if content.body.isEmpty || content.body == PingForm.memberWord { content.body = words }
        return true
    }
}

extension SealedPing {
    /// **What `NeedSeal` does with a ping, by its form** (`PingForm`): the owner's form opens with the owner's key, as
    /// before B9; the member form gets its own words and no button (`MemberPing.show`), and no key of the owner's touches
    /// it; any other form stays as it came. True when the owner's key opened it or it is a member ping.
    @discardableResult
    static func showByForm(in content: UNMutableNotificationContent, ownerKey: () -> Data?) -> Bool {
        switch PingForm.of(content.userInfo) {
        case .owner: show(in: content, key: ownerKey())
        case .member: MemberPing.show(in: content)
        case .other: false
        }
    }
}
