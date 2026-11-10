import FleetVaultIPC
import Foundation
import Security
import Testing
@testable import FleetVaultCore

/// The writer's service over a real XPC connection in this process (an anonymous listener: no launchd job, no signed
/// build). The stand-in for Bitwarden makes no real item, and the values are synthetic.
private final class Bitwarden: VaultItems, @unchecked Sendable {
    var made: [String: (name: String, value: String, note: String)] = [:]
    func organization(ofProject project: String) throws -> String { "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }
    func items(named name: String, project: String, organization: String) throws -> [String] { made.filter { $0.value.name == name }.map(\.key) }
    func notes(of ids: [String]) throws -> [String: String] { Dictionary(uniqueKeysWithValues: ids.compactMap { id in made[id].map { (id, $0.note) } }) }
    func create(name: String, value: String, note: String, project: String, organization: String) -> VaultCreateOutcome {
        let id = UUID().uuidString.lowercased()
        made[id] = (name, value, note)
        return .created(id)
    }
    func secret(id: String) throws -> VaultSecret {
        guard let item = made[id] else { throw VaultFailure.provider }
        return try VaultSecret(data: Data(item.value.utf8))
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<VaultWriterReply?, Never>?
    init(_ continuation: CheckedContinuation<VaultWriterReply?, Never>) { self.continuation = continuation }
    func resume(_ reply: VaultWriterReply?) {
        let waiting = lock.withLock { () -> CheckedContinuation<VaultWriterReply?, Never>? in defer { continuation = nil }; return continuation }
        waiting?.resume(returning: reply)
    }
}

/// One call over the connection. nil: the connection gave no answer (it was refused or it ended).
private func call(_ connection: NSXPCConnection,
                  _ body: @escaping (FleetVaultWriterProtocol, @escaping (Data) -> Void) -> Void) async -> VaultWriterReply? {
    await withCheckedContinuation { continuation in
        let once = Once(continuation)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in once.resume(nil) }) as? FleetVaultWriterProtocol else {
            once.resume(nil); return
        }
        body(proxy) { once.resume(VaultWriterReply.decode($0)) }
    }
}

@Suite(.serialized) struct VaultWriterServiceTests {
    private let canary = "synthetic-CANARY-71c4"
    private let id = "0c0c0c0c-1111-4222-8333-444444444444"
    /// A requirement that names the code of this test process, as the designated requirement of an ad-hoc signed
    /// Fleet app names that app: by its code hash.
    private var thisProcess: String? {
        var me: SecCode?, fixed: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &fixed) == errSecSuccess, let fixed,
              SecCodeCopySigningInformation(fixed, [], &information) == errSecSuccess,
              let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
    }

    private func service(client: String?, ready: Bool = true) throws -> (VaultWriterService, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-writer-service-" + UUID().uuidString)
        let items = Bitwarden()
        let writer = try VaultWriter(journal: folder.appendingPathComponent("writes.json"), clock: { 1_000 },
                                     session: { (items, "11111111-2222-3333-4444-555555555555") })
        return (VaultWriterService(writer: writer, clientRequirement: { client }, isSetUp: { ready }), folder)
    }

    private func connection(to service: VaultWriterService) -> (NSXPCConnection, NSXPCListener) {
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: FleetVaultWriterProtocol.self)
        connection.resume()
        return (connection, listener)
    }

    @Test func theTrustedClientAddsALoginAndGetsNoValueBack() async throws {
        let me: String = try #require(thisProcess)
        let (service, folder) = try service(client: me)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (connection, listener) = connection(to: service)
        defer { connection.invalidate(); listener.invalidate() }
        let empty = try #require(await call(connection) { $0.state(reply: $1) })
        #expect(empty.ok && empty.ready == true && empty.records == [])
        let value = try JSONSerialization.data(withJSONObject: ["username": "owner@example.test", "password": canary, "url": "https://shop.example.test"])
        let request = try VaultAddRequest.data(requestID: id, label: "Shop admin", hub: "http://localhost:8765/", db: "test-generation", value: value)
        let added = try #require(await call(connection) { $0.add(request: request, reply: $1) })
        let record = try #require(added.record)
        #expect(added.ok && record.state == .created && record.title == "Shop admin" && record.db == "test-generation")
        // A second connection reaches the same writer: the same UUID gets the same record and no second item.
        let (second, secondListener) = self.connection(to: service)
        defer { second.invalidate(); secondListener.invalidate() }
        #expect(await call(second) { $0.add(request: request, reply: $1) }?.record == record)
        #expect(await call(second) { $0.state(reply: $1) }?.records == [record])
        let salts = try JSONSerialization.data(withJSONObject: ["password": String(repeating: "1", count: 32), "totp": String(repeating: "2", count: 32)])
        let prints = try #require(await call(connection) { $0.fingerprints(requestID: self.id, salts: salts, reply: $1) })
        #expect(prints.ok && prints.login == record.login && prints.fingerprints?.map(\.kind) == ["password"] && prints.fingerprints?.first?.len == canary.count)
        let closed = try #require(await call(connection) { $0.close(requestID: self.id, registered: true, reply: $1) })
        #expect(closed.record?.state == .registered)
        for reply in [empty, added, prints, closed] { #expect(!String(decoding: reply.data(), as: UTF8.self).contains(canary)) }
        // A request that is not the one typed message gets a fixed text and makes nothing.
        let bad = try #require(await call(connection) { $0.add(request: Data("{}".utf8), reply: $1) })
        #expect(!bad.ok && bad.record == nil && bad.error == VaultWriteRefusal.request.rawValue)
        let unknown = try #require(await call(connection) { $0.check(requestID: "0d0d0d0d-1111-4222-8333-444444444444", reply: $1) })
        #expect(!unknown.ok && unknown.error == VaultWriteRefusal.request.rawValue)
    }

    @Test func aClientThatIsNotTheConfiguredAppGetsNoAnswer() async throws {
        // The requirement of another program, and no requirement at all (the configured app cannot be read).
        let other = try #require(VaultWriterService.requirement(ofCodeAt: "/bin/ls"))
        #expect(other.contains("com.apple.ls") && VaultWriterService.requirement(ofCodeAt: "/nonexistent/Founderizer.app") == nil)
        for client in [other, nil] {
            let (service, folder) = try service(client: client)
            defer { try? FileManager.default.removeItem(at: folder) }
            let (connection, listener) = connection(to: service)
            defer { connection.invalidate(); listener.invalidate() }
            #expect(await call(connection) { $0.state(reply: $1) } == nil)
        }
    }

    @Test func theSetupStateAndTheOwnerConfigurationAreRead() async throws {
        let me: String = try #require(thisProcess)
        let (service, folder) = try service(client: me, ready: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (connection, listener) = connection(to: service)
        defer { connection.invalidate(); listener.invalidate() }
        #expect(await call(connection) { $0.state(reply: $1) }?.ready == false)
        func configuration(_ fields: [String: Any]) throws -> VaultWriterConfiguration {
            try VaultWriterConfiguration(data: JSONSerialization.data(withJSONObject: fields))
        }
        let good: [String: Any] = ["role": "owner", "region": "eu", "fleet_app": "/Applications/Founderizer.app", "owner_uid": Int(getuid())]
        #expect(try configuration(good) == configuration(good) && configuration(good).fleetApp == "/Applications/Founderizer.app")
        for (key, value) in [("role", "worker" as Any), ("region", "moon" as Any), ("fleet_app", "Founderizer.app" as Any), ("fleet_app", "/tmp/tool" as Any),
                             ("owner_uid", Int(getuid()) + 1 as Any), ("owner_uid", "501" as Any)] {
            var changed = good; changed[key] = value
            #expect(throws: VaultFailure.configuration) { _ = try configuration(changed) }
        }
        var extra = good; extra["agent"] = "studio"
        #expect(throws: VaultFailure.configuration) { _ = try configuration(extra) }
        // A worker's configuration is no writer configuration, and a writer's is no worker's.
        let worker: [String: Any] = ["agent": "studio", "hub": "http://100.96.10.20:8765", "region": "eu", "worker_uid": Int(getuid()),
                                     "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"]
        #expect(throws: VaultFailure.configuration) { _ = try configuration(worker) }
        #expect(throws: VaultFailure.configuration) { _ = try VaultConfiguration(data: JSONSerialization.data(withJSONObject: good)) }
        _ = try VaultConfiguration(data: JSONSerialization.data(withJSONObject: worker))
    }
}
