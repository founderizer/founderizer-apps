#if os(macOS)
import Foundation
import os
import Testing
@testable import FleetCore

/// **How this Mac's records of its servers reach the hub, signed** (F17's SP1, `ServerMade.kept`,
/// `ServerMade.pinnedFleet`, `ServerMade.sweep` and `ServerMade.Pace`). Each test has its own hub address (the servers
/// of this run's builds are kept by hub, for the whole process), its own settings and files, and its own stand-in for
/// the hub.
struct ServerMadeKeptTests {
    private let fleet = "0123456789abcdef", otherFleet = "fedcba9876543210"

    private func hub(_ n: Int) -> URL { URL(string: "http://100.64.7.\(n):8765/")! }

    private func build(_ name: String, id: String?, hub: URL?, provider: CloudProvider = .hetzner,
                       use: CloudServerUse = .agent, at seconds: Double = 0) -> BuildRecord {
        var record = BuildRecord(provider: provider, use: use, hub: hub?.absoluteString, name: name, launch: "now",
                                 at: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
        if let id { record.made(id: id) }
        return record
    }

    private func listed(_ id: String, _ name: String) -> CloudExisting {
        CloudExisting(id: id, name: name, ipv4: "203.0.113.5", type: "cx23", memoryMB: 4096, system: "ubuntu",
                      version: "24.04", place: "Nuremberg", running: true, project: nil, madeFor: nil)
    }

    private func fields(_ name: String, _ id: String, _ provider: CloudProvider = .hetzner) throws -> ServerMade.Fields {
        try #require(ServerMade.Fields(machine: name, provider: provider, id: id, use: .agent))
    }

    private func files(_ builds: [BuildRecord], unswept: [BuildRecord]? = nil,
                       made: [String: String] = [:]) -> ServerMade.Files {
        ServerMade.Files(builds: builds, unswept: unswept ?? builds, made: made)
    }

    /// The hub's records as a stand-in keeps them: it keeps every statement that reaches it, also a second one of the
    /// same server, so that a test sees each send.
    private actor FakeHub {
        let fleet: String
        private(set) var db = "db-1"
        private(set) var records: [ServerMade.Record] = []
        private(set) var swept: Set<String> = []
        private(set) var listings = 0
        /// What reached the hub, in order: each server's id, and "swept".
        private(set) var calls: [String] = []
        /// The answer to a server's statement, by its id, in place of a record: a refusal or an error.
        var refuses: [String: any Error & Sendable] = [:]
        /// The next statement reaches the hub, and its answer is lost.
        var lose = false
        init(fleet: String) { self.fleet = fleet }

        func listing() -> ServerMade.Listing {
            listings += 1
            return ServerMade.Listing(db: db, fleet: fleet, records: records, swept: swept.sorted())
        }

        func keep(_ signed: ServerMade.Signed) throws -> ServerMade.Receipt {
            let id = ServerMade.fields(of: signed.statement, fleet: fleet)?.id ?? "?"
            calls.append(id)
            if let error = refuses[id] { throw error }
            let by = ServerMade.by(signed.key) ?? ""
            records.append(ServerMade.Record(statement: signed.statement, signature: signed.signature, key: signed.key,
                                             by: by, received: Double(calls.count)))
            if lose { lose = false; throw URLError(.networkConnectionLost) }
            return ServerMade.Receipt(ok: true, request_id: "r", kept: true, by: by)
        }

        func sweep(_ by: String) { calls.append("swept"); swept.insert(by) }
        func say(_ by: String) { swept.insert(by) }
        func loseNext() { lose = true }
        func refuse(_ id: String, _ error: (any Error & Sendable)?) { refuses[id] = error }
        /// An older copy of the hub came back.
        func restore() { records = []; swept = [] }
        /// The hub takes its word back.
        func unsay() { swept = [] }
        /// The hub starts a new generation of its records.
        func renew() { db = "db-2" }
        func forgetCalls() { calls = [] }

        /// The servers of the records that `key` signed for the fleet.
        func servers(by key: String) -> [String] {
            ServerMade.counted(records, fleet: fleet, anchors: [key]).map(\.server).sorted()
        }
    }

    /// One Mac of a test: its pin of the fleet's vault, its owner key, its records and its signed statements.
    private final class Mac {
        let hub: URL, fleet: String
        let defaults: TestDefaults
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("server-made-\(UUID().uuidString)")
        let builds: BuildRecords
        let statements: ServerMade.Statements
        var key: any OwnerKey = SoftwareOwnerKey()
        var lists: (listed: [CloudProvider: [CloudExisting]], waits: Bool) = ([:], false)
        var named: String?, clock: String?, hubMachine: String?
        /// The fleets that the sweep asked this Mac's owner key for.
        private(set) var asked: [String] = []

        init(_ hub: URL, fleet: String) {
            self.hub = hub; self.fleet = fleet
            defaults = TestDefaults("server-made-kept-tests")
            builds = BuildRecords(folder: folder.appendingPathComponent("builds"), launch: "now")
            statements = ServerMade.Statements(folder: folder.appendingPathComponent("server-made"))
            named = fleet
            hubMachine = "fleet-hub"
            CentralVaultPins.pin("age1example", hub: hub, fleet: fleet, in: defaults)
        }
        deinit { try? FileManager.default.removeItem(at: folder) }

        /// `reading`: whether the round reads the files (`Pace.files`); `start`: the start of the app.
        func sweep(_ fake: FakeHub, reading: ServerMade.FileRead = .read,
                   start: String = "start-1") async -> ServerMade.Outcome {
            let hub = hub, defaults = defaults, builds = builds, lists = lists, key = key
            return await ServerMade.sweep(ServerMade.Sweep(
                hub: hub, named: named, hubMachine: hubMachine, clock: clock, fileRead: reading, start: start,
                key: { fleet in self.asked.append(fleet); return key },
                listing: { await fake.listing() }, send: { try await fake.keep($0) }, swept: { await fake.sweep($0) },
                files: {
                    ServerMade.Files(builds: builds.all(), unswept: builds.unswept(),
                                     made: MadeServers.unswept(hub: hub, in: defaults))
                },
                lists: { lists },
                move: { old in
                    builds.sweep(old.builds)
                    MadeServers.sweep(old.entries, hub: hub, in: defaults)
                }, statements: statements, defaults: defaults))
        }

        func unsweptIDs() -> [String] { builds.unswept().compactMap(\.serverID).sorted() }
        func kept() -> [String] { statements.all(fleet: fleet, key: key.publicKey).map(\.made.id).sorted() }
    }

    /// A key whose chip refuses to sign.
    private struct RefusingKey: OwnerKey {
        let publicKey = SoftwareOwnerKey().publicKey
        func sign(_ statement: String) throws -> String { throw CocoaError(.featureUnsupported) }
    }

    private static func refusal(_ status: Int, code: String? = nil) -> HubError {
        .refusal(HubRefusal(status: status, hubWords: "no", code: code))
    }

    // MARK: - What a Mac signs

    /// **A server of another hub is never signed for this one**: only a build of this hub with the provider's id is
    /// this fleet's, and a server of this run's builds goes to the hub that it goes to now. A bug here: a Mac that
    /// served two fleets gives fleet B a signed proof of fleet A's server.
    @Test func aServerOfAnotherHubIsNeverSignedForThisOne() throws {
        let mine = hub(1), other = hub(2)
        let builds = [build("worker-1", id: "1001", hub: mine), build("worker-2", id: "1002", hub: other),
                      build("worker-3", id: "1003", hub: nil), build("worker-4", id: nil, hub: mine),
                      build("hub-1", id: "1005", hub: mine, use: .hub)]
        // worker-2's id is a build of the other hub: its entry here proves nothing, also with a list that holds it.
        let kept = ServerMade.kept(hub: mine, files: files(builds, made: ["worker-2": "1002"]),
                                   listed: [.hetzner: [listed("1002", "worker-2")]], waits: false)
        #expect(kept.servers.map(\.server) == ["hetzner|1001", "hetzner|1005"])
        #expect(kept.servers.map(\.use) == [.agent, .hub])
        #expect(kept.settled == ServerMade.Old(entries: ["worker-2": "1002"]))
        let server = try fields("worker-6", "abc-6", .vultr)
        ServerMade.Fresh.add(server, hub: other)
        #expect(ServerMade.Fresh.take(hub: mine).isEmpty)
        // A first run's second try takes the server of the first try: it is no more the first try's hub's.
        ServerMade.Fresh.add(server, hub: mine)
        #expect(ServerMade.Fresh.take(hub: other).isEmpty)
        #expect(ServerMade.Fresh.take(hub: mine).map(\.server) == ["vultr|abc-6"])
    }

    /// **One record for each id, as its build says**: an entry of `MadeServers` is signed by the build that names its
    /// id when that build has no hub yet (a first run's server, the hub's own among them), else only at the one
    /// provider whose list holds it, and never the hub's own machine; while a list did not come for a fault of the
    /// moment, or while the hub names no machine of its own, such an entry waits, and a provider whose token is refused
    /// has no list. Bugs here: the hub's own server is signed as a server for agents (also past the kept builds, at a
    /// hub that names no machine); a record names a provider where another business's server has the same id and name;
    /// or one list that a network fault held back settles each entry of every provider for good.
    @Test func eachIdIsSignedOnceAsItsBuildSaysOrAtTheOneProviderThatHoldsIt() {
        let mine = hub(3)
        let made = ["fleet-hub": "9001", "worker-5": "777", "worker-7": "1007", "worker-8": ""]
        let both: [CloudProvider: [CloudExisting]] = [
            .hetzner: [listed("9001", "fleet-hub"), listed("777", "worker-5"), listed("1007", "worker-7")],
            .vultr: [listed("777", "worker-5")]]
        let firstRun = build("fleet-hub", id: "9001", hub: nil, provider: .digitalOcean, use: .hub)
        let kept = ServerMade.kept(hub: mine, files: files([firstRun], made: made), hubMachine: "fleet-hub",
                                   listed: both, waits: false)
        #expect(kept.servers.map(\.server) == ["digitalocean|9001", "hetzner|1007"])
        #expect(kept.servers.map(\.use) == [.hub, .agent])
        #expect(kept.settled == ServerMade.Old(entries: ["worker-5": "777"]) && !kept.open)
        // A list that did not come for a fault of the moment says nothing of any entry: the id can be there too.
        let partly = ServerMade.kept(hub: mine, files: files([firstRun], made: made), hubMachine: "fleet-hub",
                                     listed: both, waits: true)
        #expect(partly.servers.map(\.server) == ["digitalocean|9001"])
        #expect(partly.settled == ServerMade.Old() && partly.open)
        // Hetzner refuses its token: it has no list, and the other lists decide alone.
        let vultr = ServerMade.kept(hub: mine, files: files([firstRun], made: made), hubMachine: "fleet-hub",
                                    listed: [.vultr: [listed("777", "worker-5")]], waits: false)
        #expect(vultr.servers.map(\.server) == ["digitalocean|9001", "vultr|777"])
        #expect(vultr.settled == ServerMade.Old(entries: ["worker-7": "1007"]) && !vultr.open)
        #expect(!ServerMade.listWaits(CloudError.tokenNotAccepted(.hetzner)) && !ServerMade.listWaits(CloudError.noToken(.vultr)))
        #expect(ServerMade.listWaits(CloudError.unreachable(.hetzner)) && ServerMade.listWaits(CloudError.rateLimited(.hetzner))
                && ServerMade.listWaits(CloudError.refused(.hetzner, "server error")) && ServerMade.listWaits(URLError(.timedOut)))
        // The hub names no machine of its own: an entry that only a list proves can be the hub's own server, and waits.
        let unnamed = ServerMade.kept(hub: mine, files: files([firstRun], made: made), listed: both, waits: false)
        #expect(unnamed.servers.map(\.server) == ["digitalocean|9001"] && unnamed.settled == ServerMade.Old() && unnamed.open)
        // Its build is past the kept ones, and the hub names its own machine: it is no server for agents.
        let alone = ServerMade.kept(hub: mine, files: files([], made: ["fleet-hub": "9001"]), hubMachine: "Fleet-hub",
                                    listed: both, waits: false)
        #expect(alone.servers.isEmpty)
        // A name that the hub refuses is no record, also one that only ends in a line end.
        #expect(ServerMade.Fields(machine: "worker-1\n", provider: .hetzner, id: "1", use: .agent) == nil)
    }

    /// **A fleet that only the hub names is no fleet to sign or count for**: only the one fleet whose central vault
    /// this Mac pinned at this hub's address, and the sweep asks for no other fleet's key. A bug here: a hub that is
    /// broken into names another fleet of this Mac, or one of two that were at this address, and that key signs this
    /// hub's servers.
    @Test func onlyTheFleetThatThisMacPinnedForTheHubCounts() async throws {
        let mine = hub(7), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: otherFleet)
        CentralVaultPins.pin("age1example", hub: hub(8), fleet: otherFleet, in: mac.defaults)
        #expect(ServerMade.pinnedFleet(hub: mine, named: fleet, in: mac.defaults) == fleet)
        #expect(ServerMade.pinnedFleet(hub: mine, named: nil, in: mac.defaults) == nil)
        let server = try fields("worker-1", "7001")
        ServerMade.Fresh.add(server, hub: mine)
        mac.named = otherFleet
        #expect(await mac.sweep(fake).done == false)
        #expect(mac.asked.isEmpty && ServerMade.Fresh.holds(hub: mine))
        #expect(await fake.listings == 0)
        // The pinned fleet's key, and records of another fleet in the hub's answer: nothing reaches that hub.
        mac.named = fleet
        let outcome = await mac.sweep(fake)
        #expect(mac.asked == [fleet] && !outcome.done && outcome.sent == 0)
        #expect(await fake.calls.isEmpty)
        // Two pins at one address: the hub would choose the key.
        CentralVaultPins.pin("age1example", hub: mine, fleet: otherFleet, in: mac.defaults)
        #expect(ServerMade.pinnedFleet(hub: mine, named: fleet, in: mac.defaults) == nil)
        #expect(ServerMade.pinnedFleet(hub: mine, named: otherFleet, in: mac.defaults) == nil)
    }

    // MARK: - The old records get their kept name

    /// **A record gets its kept name once the hub kept its statement and answered, and no earlier**, and the hub hears
    /// `swept` after the last one. A bug here: a hub that is away when a Mac sends takes the mark for the record, and
    /// the server has no record at the hub for good; or the hub hears `swept` while it lacks a record.
    @Test func aRecordGetsItsKeptNameOnceTheHubKeptItsStatement() async throws {
        let mine = hub(4), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        // The newest first.
        mac.builds.write(build("worker-1", id: "3001", hub: mine, at: 10))
        mac.builds.write(build("worker-2", id: "3002", hub: mine))
        MadeServers.note("worker-2", id: "3002", hub: mine, in: mac.defaults)
        // Another provider's server with an id of this Mac's build: its entry is no statement's, and gets no mark.
        MadeServers.note("web-7", id: "3001", hub: mine, in: mac.defaults)
        await fake.refuse("3002", URLError(.networkConnectionLost))
        let first = await mac.sweep(fake)
        #expect(first.signed == 2 && first.sent == 1 && !first.done && first.waits != nil)
        #expect(mac.unsweptIDs() == ["3002"])
        #expect(await fake.swept.isEmpty)
        await fake.refuse("3002", nil)
        let second = await mac.sweep(fake)
        #expect(second.done && second.signed == 0)
        #expect(mac.unsweptIDs().isEmpty && MadeServers.unswept(hub: mine, in: mac.defaults) == ["web-7": "3001"])
        #expect(MadeServers.kept(hub: mine, in: mac.defaults) == ["worker-2": "3002", "web-7": "3001"])
        #expect(await fake.calls.last == "swept")
        #expect(await fake.servers(by: mac.key.publicKey) == ["hetzner|3001", "hetzner|3002"])
    }

    /// **A send whose answer was lost makes no second record**: each round reads the hub first. A bug here: each lost
    /// answer adds a record.
    @Test func aLostAnswerMakesNoSecondRecord() async throws {
        let mine = hub(14), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        mac.builds.write(build("worker-1", id: "3000", hub: mine))
        await fake.loseNext()
        #expect(await mac.sweep(fake).done == false)
        #expect(await mac.sweep(fake).done)
        #expect(await fake.calls == ["3000", "swept"])
        #expect(await fake.records.count == 1)
        #expect(mac.unsweptIDs().isEmpty)
    }

    /// **A sweep needs both: a record with its old name, and a hub that does not say that this key moved them.** A
    /// program that writes a record of another business's server is stopped by the hub's word; a hub that is broken
    /// into and takes its word back finds no record with its old name. A bug here: one of the two alone makes this Mac
    /// sign a server as its own. A server of this run's builds is signed in each case.
    @Test func aSweepNeedsTheOldNameAndTheHubsWord() async throws {
        let mine = hub(5), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        mac.builds.write(build("worker-1", id: "5001", hub: mine))
        #expect(await mac.sweep(fake) == ServerMade.Outcome(signed: 1, sent: 1, done: true))
        // The hub's word is gone, and each record has its kept name.
        await fake.unsay()
        #expect(await mac.sweep(fake) == ServerMade.Outcome(done: true))
        #expect(await fake.servers(by: mac.key.publicKey) == ["hetzner|5001"])
        // A program wrote a record, and the hub says `swept` (the round before told it again).
        mac.builds.write(build("web-1", id: "5002", hub: mine))
        MadeServers.note("web-2", id: "5004", hub: mine, in: mac.defaults)
        let fresh = try fields("worker-3", "5003")
        ServerMade.Fresh.add(fresh, hub: mine)
        #expect(await mac.sweep(fake) == ServerMade.Outcome(signed: 1, sent: 1, done: true))
        #expect(await fake.servers(by: mac.key.publicKey) == ["hetzner|5001", "hetzner|5003"])
        #expect(mac.kept() == ["5001", "5003"] && mac.unsweptIDs() == ["5002"])
    }

    /// **A new owner key signs no record with a mark beside it** (the lane's limit 6), also at a hub that has none of
    /// its records: the records that the old key's statements moved stay that key's. A bug here: the sweep reads every
    /// record in place of those with no mark, and the new key signs again each server that the old one swept.
    @Test func aNewOwnerKeySignsNoRecordWithAMarkBesideIt() async throws {
        let mine = hub(10), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        mac.builds.write(build("worker-1", id: "1001", hub: mine))
        MadeServers.note("worker-2", id: "1002", hub: mine, in: mac.defaults)
        mac.lists = ([.hetzner: [listed("1002", "worker-2")]], false)
        #expect(await mac.sweep(fake) == ServerMade.Outcome(signed: 2, sent: 2, done: true))
        mac.key = SoftwareOwnerKey()
        #expect(await mac.sweep(fake) == ServerMade.Outcome(done: true))
        let signed = await fake.servers(by: mac.key.publicKey)
        #expect(signed.isEmpty && mac.kept().isEmpty)
    }

    /// **A hub that was restored from an older copy gets each statement again, and hears `swept` only after them**, and
    /// its `swept` with none of this key's records is not believed. A bug here: the restore loses the records for good,
    /// or a hub with none of them keeps this Mac from sending them.
    @Test func aRestoredHubGetsEachStatementAgainAndItsWordAloneIsNotBelieved() async throws {
        let mine = hub(15), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        mac.builds.write(build("worker-1", id: "1501", hub: mine))
        mac.builds.write(build("worker-2", id: "1502", hub: mine))
        #expect(await mac.sweep(fake).done)
        await fake.restore()
        await fake.forgetCalls()
        #expect(await mac.sweep(fake, reading: .closed) == ServerMade.Outcome(sent: 2, done: true))
        #expect(await fake.calls.count == 3)
        #expect(await fake.calls.last == "swept")
        #expect(await fake.servers(by: mac.key.publicKey) == ["hetzner|1501", "hetzner|1502"])
        // A hub that has the word and no record: the old records of this Mac are signed all the same.
        let other = hub(16), second = Mac(other, fleet: fleet), word = FakeHub(fleet: fleet)
        second.builds.write(build("worker-1", id: "1601", hub: other))
        let by = try #require(ServerMade.by(second.key.publicKey))
        await word.say(by)
        #expect(await second.sweep(word) == ServerMade.Outcome(signed: 1, sent: 1, done: true))
    }

    /// **A Mac with no record tells the hub nothing**, and a hub that keeps none of its records hears no `swept`. A bug
    /// here: a hub that was restored with none of them is told that all are there.
    @Test func noSweptWhileTheHubKeepsNoRecordOfThisKey() async throws {
        let mine = hub(17), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        #expect(await mac.sweep(fake) == ServerMade.Outcome(done: true))
        mac.builds.write(build("worker-1", id: "1701", hub: mine))
        await fake.refuse("1701", Self.refusal(409))
        #expect(await mac.sweep(fake) == ServerMade.Outcome(signed: 1, refused: 1, done: true))
        #expect(await fake.calls == ["1701"])
    }

    /// **A statement that the hub refuses stops no other**; one that it refuses for good is not sent again in that start
    /// of the app to that hub generation, and is at the next start (once) and to the next generation; one that it has no
    /// room for is tried at the next round. The hub hears `swept` once each is kept or settled. Bugs here: one junk
    /// statement keeps every later record from the hub for ever, or a hub fault that answered 400 once, and that a
    /// release fixed, loses the record until a restore.
    @Test func aRefusedStatementStopsNoOther() async throws {
        let mine = hub(18), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        for id in ["1801", "1802", "1803"] { mac.builds.write(build("worker-\(id)", id: id, hub: mine)) }
        await fake.refuse("1801", Self.refusal(400))
        await fake.refuse("1802", Self.refusal(409))
        #expect(await mac.sweep(fake) == ServerMade.Outcome(signed: 3, sent: 1, refused: 2, done: true))
        #expect(await fake.calls.last == "swept")
        #expect(mac.unsweptIDs().isEmpty && mac.kept() == ["1801", "1802", "1803"])
        await fake.forgetCalls()
        await fake.refuse("1801", nil)
        await fake.refuse("1802", nil)
        #expect(await mac.sweep(fake) == ServerMade.Outcome(sent: 1, done: true))
        #expect(await fake.calls == ["1802"])
        // The next start of the app sends it again, once.
        await fake.refuse("1801", Self.refusal(400))
        await fake.forgetCalls()
        #expect(await mac.sweep(fake, start: "start-2") == ServerMade.Outcome(refused: 1, done: true))
        #expect(await mac.sweep(fake, start: "start-2") == ServerMade.Outcome(done: true))
        #expect(await fake.calls == ["1801"])
        // And so does the next generation of the hub.
        await fake.refuse("1801", nil)
        await fake.forgetCalls()
        await fake.renew()
        #expect(await mac.sweep(fake, start: "start-2") == ServerMade.Outcome(sent: 1, done: true))
        #expect(await fake.calls == ["1801"])
        // A refusal that says nothing of the statement waits: the hub changed its generation, or it refuses this Mac.
        for error in [Self.refusal(409, code: "hub_changed_sending"), Self.refusal(403), Self.refusal(503)] {
            #expect(ServerMade.refusal(error) == nil)
        }
    }

    /// **A provider's list that did not come for a fault of the moment leaves its entry open, and the hub hears no
    /// `swept`**: the builds are signed, the entry waits for a later round, which signs it when the list comes, and only
    /// then the files close. A bug here: a network fault at the first read loses the hub's record of an old server for
    /// good, or the hub hears `swept` while an entry waits, and the entry is never read again.
    @Test func aListThatDidNotComeLeavesItsEntryOpenUntilItComes() async throws {
        let mine = hub(6), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        mac.builds.write(build("worker-1", id: "6001", hub: mine))
        MadeServers.note("worker-9", id: "6009", hub: mine, in: mac.defaults)
        MadeServers.note("worker-8", id: "6008", hub: mine, in: mac.defaults)          // no list holds it: settled
        mac.lists = ([.hetzner: [listed("6009", "worker-9")]], true)
        let first = await mac.sweep(fake)
        #expect(first.signed == 1 && first.sent == 1 && !first.done && first.waits != nil)
        #expect(mac.unsweptIDs().isEmpty
                && MadeServers.unswept(hub: mine, in: mac.defaults) == ["worker-9": "6009", "worker-8": "6008"])
        #expect(await fake.swept.isEmpty)
        mac.lists.waits = false
        #expect(await mac.sweep(fake) == ServerMade.Outcome(signed: 1, sent: 1, done: true))
        let swept = await fake.swept
        #expect(MadeServers.unswept(hub: mine, in: mac.defaults).isEmpty && !swept.isEmpty)
        mac.builds.write(build("web-1", id: "6666", hub: mine))
        #expect(await mac.sweep(fake) == ServerMade.Outcome(done: true))
        #expect(await fake.servers(by: mac.key.publicKey) == ["hetzner|6001", "hetzner|6009"])
    }

    // MARK: - What this Mac signed

    /// **The file of the signed statements is no proof**: a read takes only a `server-made` of that fleet that that very
    /// key signed, and a statement of an old owner key hides no server from a new one. A bug here: a program's junk
    /// entry names a server, and that server is never signed; or the hub gets a statement that this Mac did not sign.
    @Test func theKeptStatementsAreUntrustedInput() async throws {
        let mine = hub(19), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        let server = try fields("worker-1", "1901"), stranger = SoftwareOwnerKey()
        let forged = try ServerMade.Signed.sign(server, fleet: fleet, key: stranger)
        let elsewhere = try ServerMade.Signed.sign(server, fleet: otherFleet, key: mac.key)
        let junk = [ServerMade.Signed(statement: forged.statement, signature: forged.signature, key: mac.key.publicKey),
                    forged, elsewhere, ServerMade.Signed(statement: "{}", signature: "x", key: mac.key.publicKey)]
        try mac.statements.keep(junk.map { ServerMade.Statement(signed: $0, made: server) }, fleet: fleet,
                                key: mac.key.publicKey)
        #expect(mac.kept().isEmpty)
        mac.builds.write(build("worker-1", id: "1901", hub: mine))
        #expect(await mac.sweep(fake) == ServerMade.Outcome(signed: 1, sent: 1, done: true))
        #expect(await fake.servers(by: mac.key.publicKey) == ["hetzner|1901"])
        // What this build does not read stays as it is (a later build's statement), and a file that is no list is
        // moved aside, not written over: the heal of a restored hub needs each statement.
        let by = try #require(ServerMade.by(mac.key.publicKey)), later = "{\"provider\":\"example-later\"}"
        let file = mac.folder.appendingPathComponent("server-made/\(fleet)-\(by).json")
        let entries = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [Any])
        let entry: [String: Any] = ["statement": later, "signature": "x", "key": by]
        try JSONSerialization.data(withJSONObject: entries + [entry as Any]).write(to: file)
        ServerMade.Fresh.add(try fields("worker-2", "1902"), hub: mine)
        #expect(await mac.sweep(fake) == ServerMade.Outcome(signed: 1, sent: 1, done: true))
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        #expect(after.contains { $0["statement"] as? String == later } && mac.kept() == ["1901", "1902"])
        try Data("not a list".utf8).write(to: file)
        ServerMade.Fresh.add(try fields("worker-3", "1903"), hub: mine)
        #expect(await mac.sweep(fake).signed == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(names.contains { $0.hasPrefix("\(fleet)-\(by).json.unread-") } && mac.kept() == ["1903"])

        // A new owner key, with a statement of the old one that the hub never kept.
        let next = hub(20), second = Mac(next, fleet: fleet), away = FakeHub(fleet: fleet)
        second.builds.write(build("worker-1", id: "2001", hub: next))
        await away.refuse("2001", URLError(.cannotConnectToHost))
        #expect(await second.sweep(away).signed == 1)
        second.key = SoftwareOwnerKey()
        await away.refuse("2001", nil)
        #expect(await second.sweep(away) == ServerMade.Outcome(signed: 1, sent: 1, done: true))
        #expect(await away.servers(by: second.key.publicKey) == ["hetzner|2001"])
    }

    /// **A server of this run that a round could not sign waits for the next one**, and one that it signed is kept at
    /// once, with no hub. A bug here: a chip that refuses once, a clock that is off, or a hub that is away until the app
    /// quits, loses the server's record for good.
    @Test func aServerOfThisRunIsSignedWithNoHubAndWaitsWhenItCannotBe() async throws {
        let mine = hub(9), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        mac.builds.write(build("web-5", id: "9005", hub: mine))     // a round whose files were given up signs none
        let made = try fields("worker-4", "9004")
        ServerMade.Fresh.add(made, hub: mine)
        mac.clock = "the clock is off"
        #expect(await mac.sweep(fake, reading: .givenUp).signed == 0)
        mac.clock = nil
        let good = mac.key
        mac.key = RefusingKey()
        #expect(await mac.sweep(fake, reading: .givenUp).signed == 0)
        #expect(ServerMade.Fresh.holds(hub: mine))
        mac.key = good
        await fake.refuse("9004", URLError(.cannotConnectToHost))
        #expect(await mac.sweep(fake, reading: .givenUp).signed == 1)
        #expect(!ServerMade.Fresh.holds(hub: mine) && mac.kept() == ["9004"])
        await fake.refuse("9004", nil)
        #expect(await mac.sweep(fake, reading: .givenUp) == ServerMade.Outcome(sent: 1, done: true))
        #expect(await fake.servers(by: mac.key.publicKey) == ["hetzner|9004"])
        let swept = await fake.swept
        #expect(swept.isEmpty && mac.unsweptIDs() == ["9005"])
    }

    /// **A round that did not read the files tells the hub no `swept`**: after `VaultTries.most` rounds that waited in
    /// one start, a round for a server of this run signs and sends that server alone, the files stay given up, and the
    /// next start reads them and signs the old records. A bug here: that round says `swept`, or closes the files, and
    /// from then on the old records never reach the hub (a first run whose vault comes an hour after the hub names its
    /// fleet: the hub's own server, which only the files hold, gets no record).
    @Test func aRoundThatDidNotReadTheFilesSaysNoSwept() async throws {
        let mine = hub(11), mac = Mac(mine, fleet: fleet), fake = FakeHub(fleet: fleet)
        mac.builds.write(build("fleet-hub", id: "1100", hub: mine, use: .hub))
        var pace = ServerMade.Pace()
        let name = "db-1|\(fleet)", start = Date(timeIntervalSince1970: 1_800_000_000)
        mac.clock = "the clock is off"
        for round in 0..<VaultTries.most {
            let reading = pace.files(name)
            let outcome = await mac.sweep(fake, reading: reading)
            pace.ended(name, done: outcome.done, files: reading, freshLeft: false,
                       at: start.addingTimeInterval(Double(round) * 600))
        }
        #expect(pace.files(name) == .givenUp && !pace.runs(name, fresh: false))
        mac.clock = nil
        ServerMade.Fresh.add(try fields("worker-1", "1101"), hub: mine)
        #expect(pace.runs(name, fresh: true))
        let reading = pace.files(name), outcome = await mac.sweep(fake, reading: reading)
        #expect(outcome == ServerMade.Outcome(signed: 1, sent: 1, done: true))
        pace.ended(name, done: outcome.done, files: reading, freshLeft: false, at: start.addingTimeInterval(4000))
        #expect(pace.files(name) == .givenUp && mac.unsweptIDs() == ["1100"])
        #expect(await fake.swept.isEmpty)
        // The next start of the app reads the files.
        let next = ServerMade.Pace().files(name)
        #expect(next == .read)
        #expect(await mac.sweep(fake, reading: next) == ServerMade.Outcome(signed: 1, sent: 1, done: true))
        #expect(mac.unsweptIDs().isEmpty)
        #expect(await fake.calls.last == "swept")
        #expect(await fake.servers(by: mac.key.publicKey) == ["hetzner|1100", "hetzner|1101"])
    }

    /// **"Start again" leaves nothing of a fleet here**: what waits to be signed and what was signed go, of every key,
    /// and another hub's stay. A bug here: the names and ids of a forgotten fleet's servers stay on this Mac, or a later
    /// fleet at that address gets them.
    @Test func aForgottenFleetLeavesNothingHere() throws {
        let mine = hub(21), other = hub(22), mac = Mac(mine, fleet: fleet)
        CentralVaultPins.pin("age1example", hub: other, fleet: otherFleet, in: mac.defaults)
        let server = try fields("worker-1", "2101")
        for (key, of) in [(mac.key, fleet), (SoftwareOwnerKey(), fleet), (mac.key, otherFleet)] as [(any OwnerKey, String)] {
            let signed = try ServerMade.Signed.sign(server, fleet: of, key: key)
            try mac.statements.keep([ServerMade.Statement(signed: signed, made: server)], fleet: of, key: key.publicKey)
        }
        ServerMade.Fresh.add(server, hub: mine)
        ServerMade.forget(hub: mine, in: mac.defaults, statements: mac.statements)
        #expect(!ServerMade.Fresh.holds(hub: mine))
        let left = try FileManager.default.contentsOfDirectory(atPath: mac.folder.appendingPathComponent("server-made").path)
        #expect(left.count == 1 && left[0].hasPrefix("\(otherFleet)-"))
    }

    // MARK: - When a round runs

    /// **The sweep ends**: after a round that did all that it had, no look runs another one in this start, but for a
    /// server that this run makes (with the files closed) and for another generation of the hub. A round that waits is
    /// tried again after ten minutes, at most `VaultTries.most` times, and a server that could not be signed asks no
    /// keychain each minute. A bug here: each Mac reads the hub each minute, or each ten minutes, for ever.
    @Test func theSweepEndsAfterItsWork() {
        var pace = ServerMade.Pace()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        #expect(pace.due(at(0), fresh: false) && pace.runs("db1|a", fresh: false) && pace.files("db1|a") == .read)
        pace.look(at: at(0))
        pace.ended("db1|a", done: false, files: .read, freshLeft: false, at: at(0))
        #expect(!pace.due(at(59), fresh: true) && !pace.due(at(599), fresh: false) && pace.due(at(600), fresh: false))
        #expect(pace.due(at(60), fresh: true))              // a server that this run made meanwhile
        pace.ended("db1|a", done: false, files: .read, freshLeft: true, at: at(600))
        #expect(!pace.due(at(1199), fresh: true) && pace.due(at(1200), fresh: true))
        pace.look(at: at(1200))
        pace.ended("db1|a", done: true, files: .read, freshLeft: false, at: at(1200))
        #expect(pace.due(at(1260), fresh: false) && !pace.runs("db1|a", fresh: false))
        #expect(pace.runs("db1|a", fresh: true) && pace.files("db1|a") == .closed)
        #expect(pace.runs("db2|a", fresh: false) && pace.files("db2|a") == .read)
        // Rounds that wait, one after the other: after VaultTries.most of them, none more in this start.
        for round in 0..<VaultTries.most {
            #expect(pace.runs("db2|a", fresh: false), "\(round)")
            pace.ended("db2|a", done: false, files: .read, freshLeft: false, at: at(2000 + Double(round) * 600))
        }
        #expect(!pace.runs("db2|a", fresh: false) && pace.files("db2|a") == .givenUp && pace.runs("db2|a", fresh: true))
    }
}
#endif
