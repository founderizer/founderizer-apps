import CryptoKit
import Foundation
import Security
import UserNotifications

/// This phone's own key for what a ping says (`UI-API.md` version 1.76, feature `sealed_push`). Every hub sends its
/// pings through founderizer.com, so the hub seals the agent's name, the item's title and its options with this key,
/// and founderizer.com and Apple carry only "Needs you", the item's number and the sealed bytes. The app makes the key
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

    /// The ping that a notification carries, or nil: no sealed part, no key, or a part that this key does not open.
    static func open(_ info: [AnyHashable: Any], key: Data?) -> SealedPing? {
        guard let text = info["sealed"] as? String, let combined = Data(base64Encoded: text), let key, key.count == 32,
              let box = try? ChaChaPoly.SealedBox(combined: combined),
              let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: key)),
              let said = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let need = (said["need"] as? NSNumber)?.intValue, let db = said["db"] as? String,
              let title = said["title"] as? String, let body = said["body"] as? String
        else { return nil }
        let options = said["options"] as? [String]
        return SealedPing(need: need, db: db, title: title, body: body, options: options?.isEmpty == false ? options : nil)
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
            content.categoryIdentifier = "need"
        }
        content.userInfo = info
        return true
    }
}
