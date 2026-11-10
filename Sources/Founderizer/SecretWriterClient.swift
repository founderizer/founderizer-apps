import FleetVaultIPC
import Foundation

/// Fleet's connection to the writer of Add secret: the signed Fleet Vault of this Mac. Fleet sends a message only to
/// code that satisfies Fleet Vault's signing requirement, and the writer accepts only this app. The write token never
/// comes to Fleet: the answers hold records without secrets, and salted fingerprints.
final class SecretWriterClient: @unchecked Sendable {
    /// The one client of the app: the Secrets page starts the writer with it, and Add secret then uses the same connection.
    static let shared = SecretWriterClient()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    deinit { connection?.invalidate() }

    /// One call. nil: the writer gave no answer. Fleet Vault is not installed for this user, it is not the signed
    /// Fleet Vault, it refused this app, or the connection ended before the answer.
    func call(_ body: @escaping @Sendable (FleetVaultWriterProtocol, @escaping (Data) -> Void) -> Void) async -> VaultWriterReply? {
        let connection = current()
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            guard let writer = connection.remoteObjectProxyWithErrorHandler({ _ in answer.give(nil) }) as? FleetVaultWriterProtocol else {
                answer.give(nil); return
            }
            body(writer) { answer.give(VaultWriterReply.decode($0)) }
        }
    }

    private func current() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let made = NSXPCConnection(machServiceName: VaultWriterID.service, options: [])
            made.remoteObjectInterface = NSXPCInterface(with: FleetVaultWriterProtocol.self)
            made.setCodeSigningRequirement(VaultWriterID.requirement)
            made.invalidationHandler = { [weak self, weak made] in
                self?.lock.withLock { if self?.connection === made { self?.connection = nil } }
            }
            made.resume()
            connection = made
            return made
        }
    }

    /// XPC calls the reply or the error handler; this gives the first of them and no second answer.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<VaultWriterReply?, Never>?
        init(_ continuation: CheckedContinuation<VaultWriterReply?, Never>) { self.continuation = continuation }
        func give(_ reply: VaultWriterReply?) {
            let waiting = lock.withLock { () -> CheckedContinuation<VaultWriterReply?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: reply)
        }
    }
}
