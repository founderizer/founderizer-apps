import FleetCore
import Foundation
import Security

/// **A Mac's screen password for the take-over card** (the owner's "Yes, build it" of 21 November 2026 to
/// `superbot-ideas/09-take-over-modal-design.md`, section 3.3): the password of the account that a Mac agent's screen
/// signs in with, which the card asks for the first time and keeps for the next. Screen Sharing kept it in its own
/// Keychain item before; the card keeps it in one of this app's.
///
/// A generic password of this app for each machine (its account and address), not synchronized to iCloud, readable
/// only after this Mac has been unlocked once. Like the other items of the app (`NetworkCredentialStore`), only the app
/// as its Developer ID signed it touches the item; a build signed ad hoc keeps nothing, and the card asks each time.
/// It is kept only after a sign-in that it opened, and dropped when a screen refuses it.
enum TakeOverPasswords {
    private static let service = "com.founderizer.app.take-over-screen"

    private static func query(_ way: ScreenSharingConnection) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(way.user)@\(way.address)"]
    }

    static func read(_ way: ScreenSharingConnection) -> String? {
        guard FleetKeychainItem.developerIDSigned else { return nil }
        var request = query(way)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess, let data = value as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for way: ScreenSharingConnection) {
        guard FleetKeychainItem.developerIDSigned, let data = password.data(using: .utf8) else { return }
        let values: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                     kSecAttrSynchronizable as String: false,
                                     kSecAttrLabel as String: "Founderizer · take over \(way.user)"]
        var add = query(way)
        add.merge(values) { _, new in new }
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(query(way) as CFDictionary, values as CFDictionary)
        }
    }

    static func forget(_ way: ScreenSharingConnection) {
        guard FleetKeychainItem.developerIDSigned else { return }
        SecItemDelete(query(way) as CFDictionary)
    }
}
