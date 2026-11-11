import FleetCore
import Foundation
import Security

/// **What the app leaves for its share extension** (`Share/`): the owner shares a link, a post or a picture from any
/// app to one agent, with a line of his own. The extension runs in a process of its own, with its own defaults and its
/// own folder, so the app leaves it what it needs to draw its first page and to send as this phone: the hub's address,
/// this installation's client label, and the agents of its last read, in the hub's order, each with its role and
/// whether the hub takes a message to it.
///
/// It is not secret, and it still lives in the keychain, in the group that the app already shares with its extensions
/// (the first group of `keychain-access-groups`, where an item goes that names no group). An App Group would have been
/// the usual place, but an App Group is a step on Apple's developer site that the build's own key cannot take
/// ("Authentication failed" from `xcodebuild -allowProvisioningUpdates` on 11 November 2026); the keychain group needs
/// nothing from the owner. This phone's key stays where it is, behind Face ID, and the extension asks for it there
/// (`DeviceKey`) only when the owner presses Send.
struct SharedRoster: Codable, Equatable, Sendable {
    /// The hub that the app reads.
    let hub: String
    /// The app's client label, so that what the extension sends is this phone's message in the chat, and the app can
    /// correct it.
    let installation: String
    /// Every agent of the app's last read, in the hub's order: the marks take their looks from that order.
    let team: [Member]

    struct Member: Codable, Equatable, Sendable {
        let name: String
        /// Its role (team.json `title`), which the share sheet shows as its name, as the app does.
        let title: String?
        /// The hub takes a message to it, by the chat's own rule (`MobileSnapshot.canChat`).
        let takesMessage: Bool
    }

    init(hub: URL, installation: String, snapshot: MobileSnapshot?, features: Set<String>) {
        self.hub = hub.absoluteString
        self.installation = installation
        team = (snapshot?.agents ?? []).map { agent in
            Member(name: agent.name, title: agent.title,
                   takesMessage: snapshot?.canChat(with: agent.name, features: features) ?? false)
        }
    }

    /// The hub's address as the client takes it, or nil when it is not one.
    var hubURL: URL? { try? MobileClient.address(hub) }
}

/// The keychain item that holds the roster. A check names an item of its own, so that a test run never changes the
/// roster of the app on the phone that runs it.
enum SharedPlace {
    private static let service = "com.pieras.fleet.mobile.share"

    private static func item(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// What the app left, or nil before it ever left anything.
    static func roster(account: String = "roster") -> SharedRoster? {
        var query = item(account)
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(SharedRoster.self, from: data)
    }

    /// Writes what the app reads now, in the place of what it left before. True when the keychain took it. It is
    /// readable while the phone is unlocked, on this phone alone, which is when a share sheet opens.
    @discardableResult
    static func keep(_ roster: SharedRoster, account: String = "roster") -> Bool {
        guard let data = try? JSONEncoder().encode(roster) else { return false }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(item(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = item(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Takes the roster away. Only a check uses it, for its own item.
    static func forget(account: String) { SecItemDelete(item(account) as CFDictionary) }
}
