import Darwin
import FleetVaultIPC
import Foundation
import Security

/// The configuration of Fleet Vault on the owner's Mac. That Mac has no worker: Fleet Vault there only writes the
/// logins that the owner adds in Fleet. The installer writes it into the same root-owned file as a worker's
/// configuration, and the two forms never mix: a file is one or the other.
public struct VaultWriterConfiguration: Equatable, Sendable {
    /// A Bitwarden project's region, or nil when this writer saves into the fleet's own store on this Mac.
    public let region: String?
    /// The Founderizer app that may use the writer.
    public let fleetApp: String

    public var backend: VaultBackend { region == nil ? .store : .bitwarden }

    public init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["region", "store"].contains(where: { Set(object.keys) == ["role", $0, "fleet_app", "owner_uid"] }),
              object["role"] as? String == "owner",
              object["region"] == nil || ["eu", "us"].contains(object["region"] as? String ?? ""),
              object["store"] == nil || object["store"] as? String == VaultBackend.fleetStore,
              let app = object["fleet_app"] as? String, app.hasPrefix("/"), app.hasSuffix(".app"), !app.contains("\0"), app.utf8.count <= 1024,
              let uid = VaultRequest.integer(object["owner_uid"]), uid > 0, uid == Int(getuid()) else { throw VaultFailure.configuration }
        region = object["region"] as? String; fleetApp = app
    }

    public static func load() throws -> Self { try Self(data: VaultBroker.protectedConfiguration()) }
}

/// The writer's one-time setup: the Bitwarden access token that can write, and the ID of the project that gets the
/// new items. Both stay in Fleet Vault's Keychain group. Fleet gets neither. A writer that saves into the fleet's
/// own store needs no setup at all: it makes its store key and an empty store itself, as a Linux machine's
/// `store-init` is part of installing the machine.
public enum VaultWriterSetup {
    /// No agent name can start with "_", so these items never meet a worker's items.
    static let account = "_writer"

    public static var isDone: Bool { isDone(backend: .bitwarden) }

    public static func isDone(backend: VaultBackend) -> Bool {
        let keychain = VaultKeychain(agent: account)
        if backend == .store { return (try? VaultLocalStore(keychain: keychain)) != nil }
        return ((try? keychain.readIfPresent("token")) ?? nil) != nil && ((try? keychain.readIfPresent("project")) ?? nil) != nil
    }

    /// Signs in with the token and reads the project, then keeps the two. Bitwarden shows the write permission only at
    /// a write, so the first save proves it. Called only after owner authentication in Fleet Vault's own window.
    public static func save(token: String, project: String, region: String, bundle: Bundle = .main) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines), project = project.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: project) != nil else { throw VaultFailure.provider }
        let sdk = try VaultBitwarden(libraryURL: library(bundle), region: region)
        try sdk.authenticate(token: Data(token.utf8))
        _ = try sdk.organization(ofProject: project)
        let keychain = VaultKeychain(agent: account)
        try keychain.save(Data(project.utf8), item: "project")
        try keychain.save(token: token)
    }

    private static func library(_ bundle: Bundle) -> URL { bundle.bundleURL.appendingPathComponent("Contents/Frameworks/libbitwarden_c.dylib") }

    /// What one step of the writer saves into: the fleet's own store on this Mac, or a sign-in with the kept
    /// Bitwarden token and its project.
    static func session(configuration: VaultWriterConfiguration, bundle: Bundle) -> @Sendable () throws -> (items: any VaultItems, project: String) {
        let library = library(bundle), helpers = bundle.bundleURL.appendingPathComponent("Contents/Helpers")
        guard let region = configuration.region else {
            return {
                guard let store = try? VaultLocalStore(keychain: VaultKeychain(agent: account), programs: helpers) else {
                    throw VaultWriteRefusal.setup
                }
                return (store, VaultLocalStore.place)
            }
        }
        return {
            let keychain = VaultKeychain(agent: account)
            guard let token = (try? keychain.readIfPresent("token")) ?? nil, let stored = (try? keychain.readIfPresent("project")) ?? nil,
                  let project = String(data: stored, encoding: .utf8) else { throw VaultWriteRefusal.setup }
            let sdk = try VaultBitwarden(libraryURL: library, region: region)
            try sdk.authenticate(token: token)
            return (sdk, project)
        }
    }
}

/// The writer's Mach service. Every connection uses the same `VaultWriter`, so the calls of all connections run one
/// at a time. A connection is accepted only from this user and only from code that satisfies the designated
/// requirement of the Fleet app at the configured path, read again for each connection (the check of the setup
/// service). The requirement is read from that path, so this binds a client to the code at that path and not to a
/// team, whatever signs it — the Developer ID of a release build does not change that: a process that
/// can replace that app, which the same user and an administrator can do, passes it. Such a process gets no token and
/// no value from the writer; it could add items and read salted fingerprints of the items in the journal.
public final class VaultWriterService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let writer: VaultWriter
    private let clientRequirement: @Sendable () -> String?
    private let isSetUp: @Sendable () -> Bool
    private let backend: VaultBackend

    /// `clientRequirement`: the code-signing requirement of the one client, read for each connection; nil refuses.
    /// `backend`: which store this writer saves into, so a refusal is said in that store's own words.
    init(writer: VaultWriter, clientRequirement: @escaping @Sendable () -> String?, isSetUp: @escaping @Sendable () -> Bool,
         backend: VaultBackend = .bitwarden) {
        self.writer = writer; self.clientRequirement = clientRequirement; self.isSetUp = isSetUp; self.backend = backend
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(), let requirement = clientRequirement() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: FleetVaultWriterProtocol.self)
        connection.exportedObject = Endpoint(writer: writer, isSetUp: isSetUp, backend: backend)
        connection.resume()
        return true
    }

    /// The designated requirement of the code at a path, as text.
    static func requirement(ofCodeAt path: String) -> String? {
        var code: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// Runs the writer for its Mach service; launchd starts it on demand. A second writer process cannot use the
    /// journal: launchd gives the service to one job, and the journal's lock refuses another process.
    public static func run() -> Never {
        do {
            try VaultBroker.verifySignature()
            let configuration = try VaultWriterConfiguration.load()
            let journal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Fleet Vault/writes.json")
            let writer = try VaultWriter(journal: journal, session: VaultWriterSetup.session(configuration: configuration, bundle: .main))
            let app = configuration.fleetApp, backend = configuration.backend
            let service = VaultWriterService(writer: writer, clientRequirement: { requirement(ofCodeAt: app) },
                                             isSetUp: { VaultWriterSetup.isDone(backend: backend) }, backend: backend)
            let listener = NSXPCListener(machServiceName: VaultWriterID.service)
            listener.delegate = service
            listener.resume()
            withExtendedLifetime((service, listener)) { dispatchMain() }
        } catch { exit(78) }
    }

    // XPC reply blocks are called from the writer's task.
    private struct Reply: @unchecked Sendable {
        let call: (Data) -> Void
        let backend: VaultBackend
        func send(_ reply: VaultWriterReply) { call(reply.data()) }
        func refuse(_ error: Error) {
            send(VaultWriterReply(ok: false, error: (error as? VaultWriteRefusal)?.said(by: backend) ?? VaultWriteRefusal.request.rawValue))
        }
    }

    private final class Endpoint: NSObject, FleetVaultWriterProtocol, @unchecked Sendable {
        private let writer: VaultWriter
        private let isSetUp: @Sendable () -> Bool
        private let backend: VaultBackend
        init(writer: VaultWriter, isSetUp: @escaping @Sendable () -> Bool, backend: VaultBackend) {
            self.writer = writer; self.isSetUp = isSetUp; self.backend = backend
        }

        func state(reply: @escaping (Data) -> Void) {
            let reply = Reply(call: reply, backend: backend)
            Task { reply.send(VaultWriterReply(ready: isSetUp(), records: await writer.pending())) }
        }

        func add(request: Data, reply: @escaping (Data) -> Void) {
            let reply = Reply(call: reply, backend: backend)
            guard let message = VaultAddRequest.read(request) else { reply.refuse(VaultWriteRefusal.request); return }
            Task {
                do {
                    reply.send(VaultWriterReply(record: try await writer.add(requestID: message.requestID, label: message.label, hub: message.hub,
                                                                             db: message.db, value: message.value)))
                } catch { reply.refuse(error) }
            }
        }

        func check(requestID: String, reply: @escaping (Data) -> Void) {
            let reply = Reply(call: reply, backend: backend)
            Task { do { reply.send(VaultWriterReply(record: try await writer.check(requestID: requestID))) } catch { reply.refuse(error) } }
        }

        func fingerprints(requestID: String, salts: Data, reply: @escaping (Data) -> Void) {
            let reply = Reply(call: reply, backend: backend)
            guard salts.count <= 4096, let given = try? JSONSerialization.jsonObject(with: salts) as? [String: String] else {
                reply.refuse(VaultWriteRefusal.request); return
            }
            Task {
                do {
                    let made = try await writer.fingerprints(requestID: requestID, salts: given)
                    reply.send(VaultWriterReply(login: made.login, fingerprints: made.items))
                } catch { reply.refuse(error) }
            }
        }

        func close(requestID: String, registered: Bool, reply: @escaping (Data) -> Void) {
            let reply = Reply(call: reply, backend: backend)
            Task {
                do { reply.send(VaultWriterReply(record: try await writer.close(requestID: requestID, registered: registered))) } catch { reply.refuse(error) }
            }
        }
    }
}
