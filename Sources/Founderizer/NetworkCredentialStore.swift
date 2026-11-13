import FleetCore
import Foundation
import Security

/// Where the Tailscale credential lives: **this Mac's own keychain, and nowhere else.**
///
/// It never goes to the hub, it is never written to a file of the app's, it stands in no argument, and the install
/// puts it in its redaction list so it cannot reach a line the app shows or keeps. Tailscale lets a client secret
/// be used as an auth key on its own, so it is as dangerous as a key and is kept like one.
///
/// A generic password of this app, not synchronized to iCloud and readable only after this Mac has been unlocked
/// once. Like the owner key (`FleetKeychainItem`), only the app as its Developer ID signed it touches the item: a
/// copy signed ad hoc would cost the owner his login password at every build.
enum NetworkCredentialStore {
    private static let service = "com.founderizer.app.private-network"
    private static let account = "tailscale-oauth-client"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The credential this Mac holds, or nil.
    static func read() -> NetworkCredential? {
        guard FleetKeychainItem.developerIDSigned else { return nil }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return NetworkCredential(stored: data)
    }

    /// Whether a credential is held, without reading the secret, so a screen can say so without touching it.
    static var isHeld: Bool {
        guard FleetKeychainItem.developerIDSigned else { return false }
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    /// Keeps the credential, replacing whatever was there.
    static func save(_ credential: NetworkCredential) throws {
        guard FleetKeychainItem.developerIDSigned else { throw NetworkStoreError.keychain(errSecInteractionNotAllowed) }
        let data = try credential.stored()
        let values: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                     kSecAttrSynchronizable as String: false,
                                     kSecAttrLabel as String: "Founderizer · your private network"]
        var add = query
        add.merge(values) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || (status == errSecDuplicateItem
            && SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecSuccess) else {
            throw NetworkStoreError.keychain(status)
        }
    }

    /// Ends it on this Mac. Tailscale's own copy is ended in Tailscale, which the screen offers beside this.
    static func forget() throws {
        guard FleetKeychainItem.developerIDSigned else { throw NetworkStoreError.keychain(errSecInteractionNotAllowed) }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NetworkStoreError.keychain(status) }
    }
}

enum NetworkStoreError: LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            String(l10n: "This Mac's keychain refused (\(Int(status))). Nothing was kept.")
        }
    }
}
