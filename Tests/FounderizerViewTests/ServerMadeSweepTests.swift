import CryptoKit
import FleetCore
import Foundation
import Testing
@testable import Founderizer

/// **The servers that this Mac made, to the hub, in the app** (F17's SP1, `ServerMadeModel`): the four calls reach their
/// routes with their fields, the sweep of the poll ends after its work, a fleet that this Mac did not pin gets nothing,
/// and "Start again" forgets it all. Each reads what the app sent to a stand-in hub (`LoopbackHub`).
@Suite(.serialized, .timeLimit(.minutes(2))) struct ServerMadeSweepTests {
    private static let fleet = "0123456789abcdef", otherFleet = "fedcba9876543210"

    private static func state(_ db: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": db, "time": Int(Date().timeIntervalSince1970),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
            "reports": [], "ui_features": [ServerMade.feature]] as [String: Any])
    }

    /// The hub's records in the stand-in: it answers the routes as the hub does, and keeps the bodies that it got.
    private final class HubRecords: @unchecked Sendable {
        private let lock = NSLock()
        private let db: String
        private var records: [[String: Any]] = [], swept: [String] = []
        init(db: String) { self.db = db }

        func answer(_ request: LoopbackHub.Request) -> Data? {
            let body = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any] ?? [:]
            let id = body["request_id"] as? String ?? ""
            return lock.withLock { () -> Data? in
                let answer: [String: Any]
                switch (request.method, request.path) {
                case ("GET", "/ui/servers/made"):
                    answer = ["db": db, "fleet": ServerMadeSweepTests.fleet, "records": records, "swept": swept]
                case ("POST", "/ui/servers/made"):
                    let key = body["key"] as? String ?? "", by = ServerMade.by(key) ?? ""
                    records.append(["statement": body["statement"] ?? "", "signature": body["signature"] ?? "", "key": key,
                                    "by": by, "received": 1.0])
                    answer = ["ok": true, "request_id": id, "kept": true, "by": by]
                case ("POST", "/ui/servers/made/swept"):
                    let by = body["by"] as? String ?? ""
                    swept.append(by)
                    answer = ["ok": true, "request_id": id, "kept": true, "by": by]
                case ("POST", "/ui/servers/worker-1/install-ended"):
                    answer = ["ok": true, "request_id": id, "server": "worker-1", "address": body["address"] ?? ""]
                default:
                    return nil
                }
                return try? JSONSerialization.data(withJSONObject: answer)
            }
        }
    }

    /// The routes of the hub's records in the stand-in, each answered by `kept` (LoopbackHub's one way: one table of
    /// answers by route); a request that it does not answer gets a 404.
    private static func serve(_ hub: LoopbackHub, _ kept: HubRecords) {
        for (method, path) in [("GET", "/ui/servers/made"), ("POST", "/ui/servers/made"), ("POST", "/ui/servers/made/swept"),
                               ("POST", "/ui/servers/worker-1/install-ended")] {
            hub.answer(method, path) { request in
                kept.answer(request).map { (status: 200, body: $0) } ?? (status: 404, body: Data("{}".utf8))
            }
        }
    }

    /// How often a test's owner key was asked for, and for which fleets.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var fleets: [String] = []
        func note(_ fleet: String) { lock.withLock { fleets.append(fleet) } }
        var all: [String] { lock.withLock { fleets } }
    }

    @MainActor private final class Box<Value> { var value: Result<Value, any Error>? }

    /// The fleet that the vault's reading names, which a test changes.
    @MainActor private final class Named { var fleet: String? }

    /// The answer of an async call, inside a body of the main loop.
    @MainActor private static func answer<Value: Sendable>(_ call: @escaping @Sendable () async throws -> Value) throws -> Value {
        let box = Box<Value>()
        Task {
            do { box.value = .success(try await call()) } catch { box.value = .failure(error) }
        }
        ViewHost.turn(10) { box.value != nil }
        guard let value = box.value else { throw ViewHost.Missing(description: "the call did not end") }
        return try value.get()
    }

    /// A store of the app that reads `hub`, after the hub's first answer, with this Mac's pin of the fleet's vault.
    @MainActor private static func store(on hub: LoopbackHub, _ state: Data) throws -> FleetStore {
        _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.canWrite }
        CentralVaultPins.pin("age1example", hub: store.hub, fleet: fleet)
        return store
    }

    private static func paths(_ hub: LoopbackHub) -> [String] {
        hub.requests.filter { $0.path.hasPrefix("/ui/servers") }.map { "\($0.method) \($0.path)" }
    }

    /// The four calls of a client, each to its route, with its fields, and the answer that each takes. A bug here: a
    /// wrong path or a wrong field, and no record of any Mac ever reaches a hub.
    @Test func theFourCallsReachTheirRoutes() async throws {
        struct Seen: Sendable {
            let records: Int, swept: [String], paths: [String], bodies: [[String]], refused: Bool
        }
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> Seen in
            let db = "made-\(UUID().uuidString)", hub = try LoopbackHub(state: Self.state(db))
            defer { hub.stop() }
            let kept = HubRecords(db: db)
            Self.serve(hub, kept)
            let store = try Self.store(on: hub, Self.state(db)), address = store.hub
            let server = try #require(ServerMade.Fields(machine: "worker-1", provider: .hetzner, id: "1001", use: .agent))
            let signed = try ServerMade.Signed.sign(server, fleet: Self.fleet, key: SoftwareOwnerKey())
            let by = try #require(ServerMade.by(signed.key))
            let receipt = try Self.answer {
                try await HubClient().keepMadeServer(hub: address, database: db, client: "test", signed: signed)
            }
            try Self.answer { try await HubClient().keepMadeSwept(hub: address, database: db, client: "test", by: by) }
            try Self.answer {
                try await HubClient().keepInstallEnded(hub: address, database: db, client: "test", server: "worker-1",
                                                       address: "100.64.0.11")
            }
            let listing = try Self.answer { try await HubClient().madeServers(hub: address, database: db) }
            // Another generation's answer, and a name that would lead to another path, are no answers.
            let refused = (try? Self.answer { try await HubClient().madeServers(hub: address, database: "other") }) == nil
                && (try? Self.answer {
                    try await HubClient().keepInstallEnded(hub: address, database: db, client: "test",
                                                           server: "worker-1/remove", address: "100.64.0.11")
                }) == nil
            let posts = hub.requests.filter { $0.method == "POST" && $0.path.hasPrefix("/ui/servers") }
            let counted = ServerMade.counted(listing.records, fleet: Self.fleet, anchors: [signed.key])
            return Seen(records: receipt.kept && counted == [server] ? 1 : 0, swept: listing.swept == [by] ? ["by"] : [],
                        paths: Self.paths(hub), bodies: posts.map { post in
                            let body = (try? JSONSerialization.jsonObject(with: Data(post.body.utf8))) as? [String: Any]
                            return (body ?? [:]).keys.sorted()
                        }, refused: refused)
        }
        #expect(seen.records == 1 && seen.swept == ["by"] && seen.refused)
        #expect(Array(seen.paths.prefix(4)) == ["POST /ui/servers/made", "POST /ui/servers/made/swept",
                                                "POST /ui/servers/worker-1/install-ended", "GET /ui/servers/made"])
        #expect(seen.bodies == [["db", "key", "request_id", "signature", "statement"], ["by", "db", "request_id"],
                                ["address", "db", "request_id"]])
    }

    /// **The sweep of the poll ends after its work**: one listing in the start that moves the records, none after it,
    /// one in the next start and none after that; and a fleet that this Mac did not pin at the hub's address asks for
    /// no key and reads nothing. Bugs here: each Mac reads the hub each minute for ever; or a hub that is broken into
    /// names another fleet of this Mac, and its key signs.
    @Test func theSweepOfThePollEndsAndGoesToThePinnedFleetOnly() async throws {
        struct Seen: Sendable {
            let other: [String], asked: [String], first: [String], later: [String], next: [String], unswept: Bool, kept: Bool
        }
        let (seen, _) = try await ViewHost.onMainLoop(limit: 100) { () -> Seen in
            let db = "made-\(UUID().uuidString)", hub = try LoopbackHub(state: Self.state(db))
            defer { hub.stop() }
            let kept = HubRecords(db: db)
            Self.serve(hub, kept)
            let store = try Self.store(on: hub, Self.state(db)), address = store.hub.absoluteString
            var build = BuildRecord(provider: .hetzner, use: .agent, hub: address, name: "worker-1")
            build.made(id: "1001")
            BuildRecords.shared.write(build)
            defer { BuildRecords.shared.remove { $0.hub == address } }
            let raw = P256.Signing.PrivateKey().rawRepresentation, asked = Asked()
            @MainActor func model(_ fleet: String) -> ServerMadeModel {
                ServerMadeModel(hub: store.hub, key: { name in
                    asked.note(name)
                    return (try? P256.Signing.PrivateKey(rawRepresentation: raw)).map { SoftwareOwnerKey($0) }
                }, said: { _ in ServerMadeModel.Said(fleet: fleet) })
            }
            @MainActor func run(_ model: ServerMadeModel, at seconds: TimeInterval) {
                model.tick(store: store, now: Date(timeIntervalSinceNow: seconds))
                ViewHost.turn(10) { !model.working }
            }
            run(model(Self.otherFleet), at: 0)
            let other = Self.paths(hub), askedThen = asked.all
            let one = model(Self.fleet)
            run(one, at: 0)
            let first = Self.paths(hub)
            for minute in 1...30 { run(one, at: Double(minute) * 61) }
            let later = Self.paths(hub)
            let two = model(Self.fleet)
            for minute in 0...30 { run(two, at: Double(minute) * 61) }
            return Seen(other: other, asked: askedThen, first: first, later: later, next: Self.paths(hub),
                        unswept: BuildRecords.shared.unswept().contains { $0.id == build.id },
                        kept: BuildRecords.shared.all().contains { $0.id == build.id })
        }
        #expect(seen.other.isEmpty && seen.asked.isEmpty)
        #expect(seen.first == ["GET /ui/servers/made", "POST /ui/servers/made", "POST /ui/servers/made/swept"])
        #expect(seen.later == seen.first)
        #expect(seen.next == seen.first + ["GET /ui/servers/made"])
        #expect(seen.kept && !seen.unswept)
    }

    /// **The first look waits for the vault's reading, not ten minutes**: while the reading names no fleet (the first
    /// polls of a start), the sweep makes no look, and it looks at the first poll that has one. A bug here: each start
    /// sweeps only after ten minutes, and a start that is shorter never moves this Mac's records.
    @Test func theFirstLookWaitsForTheVaultsReadingNotTenMinutes() async throws {
        struct Seen: Sendable { let before: [String], after: [String] }
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> Seen in
            let db = "made-\(UUID().uuidString)", hub = try LoopbackHub(state: Self.state(db))
            defer { hub.stop() }
            let kept = HubRecords(db: db)
            Self.serve(hub, kept)
            let store = try Self.store(on: hub, Self.state(db)), named = Named()
            let model = ServerMadeModel(hub: store.hub, key: { _ in SoftwareOwnerKey() },
                                        said: { _ in ServerMadeModel.Said(fleet: named.fleet) })
            model.tick(store: store, now: Date())
            ViewHost.turn(10) { !model.working }
            let before = Self.paths(hub)
            named.fleet = Self.fleet
            model.tick(store: store, now: Date(timeIntervalSinceNow: 1))
            ViewHost.turn(10) { !model.working }
            return Seen(before: before, after: Self.paths(hub))
        }
        #expect(seen.before.isEmpty && seen.after.first == "GET /ui/servers/made")
    }

    /// **"Start again" leaves nothing of it**: the fleet's model runs no more, what waits to be signed is gone, and so
    /// is what was signed. A bug here: the store's model writes the forgotten fleet's records again.
    @Test func startAgainForgetsTheFleetsRecords() async throws {
        struct Seen: Sendable { let before: Int, after: Int, stopped: Bool, fresh: Bool }
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> Seen in
            let db = "made-\(UUID().uuidString)", hub = try LoopbackHub(state: Self.state(db))
            defer { hub.stop() }
            let store = try Self.store(on: hub, Self.state(db)), address = store.hub, key = SoftwareOwnerKey()
            let model = store.madeModel()
            let server = try #require(ServerMade.Fields(machine: "worker-1", provider: .hetzner, id: "1001", use: .agent))
            let signed = try ServerMade.Signed.sign(server, fleet: Self.fleet, key: key)
            try ServerMade.Statements.app.keep([ServerMade.Statement(signed: signed, made: server)], fleet: Self.fleet,
                                               key: key.publicKey)
            ServerMade.Fresh.add(server, hub: address)
            let before = ServerMade.Statements.app.all(fleet: Self.fleet, key: key.publicKey).count
            store.forgetFleet(address, hubServerDeleted: false)
            return Seen(before: before, after: ServerMade.Statements.app.all(fleet: Self.fleet, key: key.publicKey).count,
                        stopped: model.stopped, fresh: ServerMade.Fresh.holds(hub: address))
        }
        #expect(seen.before == 1 && seen.after == 0 && seen.stopped && !seen.fresh)
    }
}
