import Foundation
import LocalAuthentication
import Security

/// The four Keychain calls of the vault's items, so a test can stand in for the Keychain. Only `errSecItemNotFound`
/// says that an item is not there. Each other answer is a failure of the Keychain, for example before the first unlock
/// after a restart, and the vault never takes it for "no item" (package 7).
protocol VaultKeychainBackend: Sendable {
    /// The file whose lock each process holds across a move of the keys (`VaultKeyMove`).
    var lockFile: URL { get }
    func read(service: String, account: String) -> (OSStatus, Data?)
    func add(service: String, account: String, data: Data) -> OSStatus
    func update(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

/// The data-protection Keychain, in Fleet Vault's own group, which macOS gives only to code with Fleet Vault's
/// signature. No legacy ACL and no approval dialog: the OS checks the provisioned access-group entitlement.
struct VaultSystemKeychain: VaultKeychainBackend {
    private let group = "6EBZ756H9Q.local.agent-fleet.vault"

    /// In the vault's own folder, beside its store file.
    var lockFile: URL { VaultLocalStore.file.deletingLastPathComponent().appendingPathComponent("keys.lock") }

    private func key(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecUseDataProtectionKeychain as String: true,
         kSecAttrAccessGroup as String: group, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(service: String, account: String) -> (OSStatus, Data?) {
        let context = LAContext(); context.interactionNotAllowed = true
        var query = key(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return (status, value as? Data)
    }

    private var values: [String: Any] {
        [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecAttrSynchronizable as String: false]
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var add = key(service, account)
        add.merge(values) { _, new in new }
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        var change = values
        change[kSecValueData as String] = data
        return SecItemUpdate(key(service, account) as CFDictionary, change as CFDictionary)
    }

    /// The query asks for no value, so nothing of the item is read. The vault's items have no access control of their
    /// own, so a delete shows no dialog.
    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(key(service, account) as CFDictionary)
    }
}

/// The Keychain items of one agent's vault: `<agent>.<item>` under the service of one key generation.
///
/// **The key generation (package 7, C23).** Each build of Fleet Vault has the same signature, so an agent of a Mac can
/// stop Fleet Vault and start an older build, which would open the same store and have none of the newer checks. So a
/// build reads and writes only the service of its own generation, and each older build reads only its own: the service
/// is a constant of each build's code, and no argument, variable or file of the user sets it. Generation 1 is the
/// service of builds 1 to 14. A release that adds a check which an older build must not undo raises the number, and
/// its first start moves the keys to its service (`VaultKeyMove`). Before the move is done, a build of this generation
/// reads and writes none of its items, so it never makes a key beside the real ones.
public final class VaultKeychain: @unchecked Sendable {
    /// The key generation of this build.
    public static let generation = 2

    /// The service of one generation: today's name for generation 1, and the name with its number for each later one.
    static func service(_ generation: Int) -> String {
        generation == 1 ? "local.agent-fleet.vault" : "local.agent-fleet.vault.\(generation)"
    }

    let agent: String
    let generationNumber: Int
    private let service: String
    let backend: any VaultKeychainBackend
    /// True for the items of this build's own generation, which wait for the move. The move itself, and the cleanup of
    /// the items of builds before this one, use the items of a generation as they are.
    private let guarded: Bool

    public convenience init(agent: String) {
        self.init(agent: agent, generation: Self.generation, backend: VaultSystemKeychain(), guarded: true)
    }

    init(agent: String, generation: Int, backend: any VaultKeychainBackend, guarded: Bool) {
        self.agent = agent; self.generationNumber = generation; self.backend = backend; self.guarded = guarded
        service = Self.service(generation)
    }

    /// An agent name has no `.`, so the account of one item is never the account of another item.
    private func account(_ item: String) -> String { "\(agent).\(item)" }

    private func ready() throws {
        if guarded { try VaultKeyMove.ensure(agent: agent, backend: backend, generation: generationNumber) }
    }

    func read(_ item: String) throws -> Data {
        guard let data = try readIfPresent(item) else { throw VaultFailure.keychain }
        return data
    }

    func readIfPresent(_ item: String) throws -> Data? {
        try ready()
        return try raw(item)
    }

    /// Saves one item, in its place when it is there.
    func save(_ data: Data, item: String) throws {
        try ready()
        try rawSave(data, item: item)
    }

    /// Saves a new item, and never in the place of one that is there: a new key never takes the place of a key.
    func create(_ data: Data, item: String) throws {
        try ready()
        guard backend.add(service: service, account: account(item), data: data) == errSecSuccess else { throw VaultFailure.keychain }
    }

    /// Deletes one item, and an item that is not there counts as deleted.
    func remove(_ item: String) throws {
        try ready()
        try rawRemove(item)
    }

    // MARK: the items as they are, for the move and for the cleanup of older items

    func raw(_ item: String) throws -> Data? {
        let (status, data) = backend.read(service: service, account: account(item))
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, !data.isEmpty else { throw VaultFailure.keychain }
        return data
    }

    func rawSave(_ data: Data, item: String) throws {
        let status = backend.add(service: service, account: account(item), data: data)
        guard status == errSecSuccess || (status == errSecDuplicateItem &&
            backend.update(service: service, account: account(item), data: data) == errSecSuccess) else {
            throw VaultFailure.keychain
        }
    }

    /// Adds an item, and never in the place of one that is there.
    func rawCreate(_ data: Data, item: String) throws {
        guard backend.add(service: service, account: account(item), data: data) == errSecSuccess else { throw VaultFailure.keychain }
    }

    func rawRemove(_ item: String) throws {
        let status = backend.delete(service: service, account: account(item))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultFailure.keychain }
    }
}
