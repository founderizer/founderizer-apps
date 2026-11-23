import Foundation
import Testing
@testable import FleetCore

/// The connection to each server for the steps that this Mac runs by itself as root there (`ServerRecords`: the owner's
/// access line and the join's hardening). The fleet of these tests has the shape of the one that showed the fault on
/// 15 November 2026: the hub's own server `hub-1` runs no agent, so the list of machines does not name it, and the hub
/// has its connection on record; `worker-1` runs an agent; `worker-7` joined and runs none. A row of the list of servers
/// has no `access` unless a test gives it one: that is a hub from before owner API 1.173.
struct ServerRecordsTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private struct NoAnswer: Error {}

    /// One row of `GET /ui/servers`. `access`: the JSON of the row's `access` (owner API 1.173), nil for a row without
    /// the key.
    private static func server(_ name: String, hub: Bool = false, address: String? = nil,
                               access: String? = nil) throws -> ServerEntry {
        var entry: [String: Any] = ["name": name, "hub": hub, "joined": !hub, "agents": [], "available": !hub, "why": []]
        if !hub { entry["kind"] = "linux" }
        if let address { entry["address"] = address }
        if let access {
            entry["access"] = try JSONSerialization.jsonObject(with: Data(access.utf8), options: .fragmentsAllowed)
        }
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    private static let rootRow = #"{"ssh": {"user": "root", "port": 22}}"#
    private static let noRecordRow = #"{"ssh": null}"#

    /// The list of machines as `GET /ui/machines` gives it: one entry for each agent, with its server's record.
    private static func machines(_ entries: [(machine: String, address: String, ssh: String)]) throws -> [MachineStatus] {
        let rows = entries.map { entry in
            #"""
            {"agent":"agent-\#(entry.machine)","machine":"\#(entry.machine)","role":"worker","address":"\#(entry.address)",
             "access":{"ssh":\#(entry.ssh),"screen_sharing":null},"update":{},"runtime":{},"security":{},"os":{"name":"Ubuntu"}}
            """#
        }
        let json = #"{"db":"db","machines":[\#(rows.joined(separator: ","))]}"#
        return try JSONDecoder().decode(MachineList.self, from: Data(json.utf8)).machines
    }

    /// The hub's record of its own server, as `GET /ui/vault` gives it.
    private static func own(_ ssh: String = #"{"user": "root", "port": 22}"#, machine: String = "hub-1",
                            address: String = #""100.64.0.2""#) throws -> VaultHub {
        try JSONDecoder().decode(VaultHub.self,
                                 from: Data(#"{"machine": "\#(machine)", "address": \#(address), "ssh": \#(ssh)}"#.utf8))
    }

    private static let rootSSH = #"{"user":"root","port":22,"available":true}"#

    /// The list with `worker-1` alone: no agent runs on the hub's server, and none on `worker-7`.
    private static func workerOnly() throws -> [MachineStatus] {
        try machines([("worker-1", "100.64.0.9", rootSSH)])
    }

    /// One round's records, with the count of each read. `list`: nil is a list that did not answer.
    private static func records(_ list: [MachineStatus]?, own: Result<VaultHub?, NoAnswer>)
        -> (records: ServerRecords, listReads: Calls, ownReads: Calls) {
        let listReads = Calls(), ownReads = Calls()
        let records = ServerRecords(machines: { listReads.add(); return list },
                                    own: { ownReads.add(); return try own.get() })
        return (records, listReads, ownReads)
    }

    /// What one try for one server comes to: the connection, or why there is none.
    private static func connection(_ records: ServerRecords, to server: ServerEntry,
                                   kept: InstallTarget? = nil) async -> Result<InstallTarget, ServerRecords.Unreached> {
        do {
            return .success(try await records.connection(to: server, kept: kept))
        } catch let error as ServerRecords.Unreached {
            return .failure(error)
        } catch {
            Issue.record("an error that is not ServerRecords.Unreached: \(error)")
            return .failure(.noConnection)
        }
    }

    // MARK: the hub's own server

    /// The fault of 15 November 2026: the list of machines does not name a hub's server with no agent, and this Mac
    /// keeps no install connection to it. The hub's own record of that server is its connection.
    @Test func theHubsOwnServerWithNoAgentIsReachedByTheHubsOwnRecord() async throws {
        let hub = try Self.server("hub-1", hub: true, address: "100.64.0.2")
        let asRoot = Self.records(try Self.workerOnly(), own: .success(try Self.own()))
        #expect(await Self.connection(asRoot.records, to: hub) == .success(InstallTarget(host: "100.64.0.2")))
        #expect(asRoot.listReads.value == 1 && asRoot.ownReads.value == 1)
        // The record's own port. A record's user that is not root is no connection of a root step (M1 of the validation
        // of 23 November 2026), and a connection that this Mac keeps with such a user is as it was.
        let asFleet = Self.records(try Self.workerOnly(), own: .success(try Self.own(#"{"user": "fleet", "port": 2222}"#)))
        #expect(await Self.connection(asFleet.records, to: hub) == .failure(.noConnection))
        let atPort = Self.records(try Self.workerOnly(), own: .success(try Self.own(#"{"user": "root", "port": 2222}"#)))
        #expect(await Self.connection(atPort.records, to: hub) == .success(InstallTarget(host: "100.64.0.2", port: 2222)))
        #expect(await Self.connection(asFleet.records, to: hub, kept: InstallTarget(host: "100.64.0.2", user: "fleet"))
                == .success(InstallTarget(host: "100.64.0.2", user: "fleet", becomeRoot: true)))
        // A fleet with no agent at all has an empty list, and a list that did not answer says nothing: the hub's own
        // page still gives the record.
        for list in [[], nil] as [[MachineStatus]?] {
            let round = Self.records(list, own: .success(try Self.own()))
            #expect(await Self.connection(round.records, to: hub) == .success(InstallTarget(host: "100.64.0.2")))
        }
    }

    /// The same server with an agent on it: the list names it, its entry is the fleet's record, and the hub's own page
    /// is not read (`OwnerKeyPlan.record`).
    @Test func aHubsServerThatTheListNamesHasItsRecordThere() async throws {
        let hub = try Self.server("hub-1", hub: true, address: "100.64.0.2")
        let list = try Self.machines([("hub-1", "100.64.0.2", #"{"user":"root","port":2200,"available":true}"#),
                                      ("worker-1", "100.64.0.9", Self.rootSSH)])
        let round = Self.records(list, own: .success(try Self.own()))
        #expect(await Self.connection(round.records, to: hub) == .success(InstallTarget(host: "100.64.0.2", port: 2200)))
        #expect(round.ownReads.value == 0)
        // An entry of the list that is no whole connection is the fleet's record too: none.
        let notWhole = Self.records(try Self.machines([("hub-1", "100.64.0.2", "null")]), own: .success(try Self.own()))
        #expect(await Self.connection(notWhole.records, to: hub) == .failure(.noConnection))
        #expect(notWhole.ownReads.value == 0)
    }

    /// Nothing runs where no connection is known, and the reason says whether another try can find one: a record that
    /// is known and is none, or a page that did not answer.
    @Test func withNoRecordOfTheHubsServerNothingRunsThere() async throws {
        let hub = try Self.server("hub-1", hub: true, address: "100.64.0.2")
        // Both pages answered: a hub that names no server of its own, one that names another, a record with no SSH
        // part, and parts that are no connection.
        for own in [nil, try Self.own(machine: "hub-2"), try Self.own("null"), try Self.own(#"{"user": null, "port": 22}"#),
                    try Self.own(#"{"user": "root", "port": 0}"#), try Self.own(#"{"user": "root -oProxyCommand=x", "port": 22}"#),
                    try Self.own(address: "null")] as [VaultHub?] {
            let round = Self.records(try Self.workerOnly(), own: .success(own))
            #expect(await Self.connection(round.records, to: hub) == .failure(.noConnection))
        }
        // An address that `ssh` cannot take as a host is no connection, although the record has every part.
        let badHost = Self.records(try Self.workerOnly(), own: .success(try Self.own(address: #""-oProxyCommand=x""#)))
        #expect(await Self.connection(badHost.records, to: hub) == .failure(.noConnection))
        // A page that did not answer says nothing.
        let noOwn = Self.records(try Self.workerOnly(), own: .failure(NoAnswer()))
        #expect(await Self.connection(noOwn.records, to: hub) == .failure(.recordNotRead))
        let noList = Self.records(nil, own: .success(nil))
        #expect(await Self.connection(noList.records, to: hub) == .failure(.recordNotRead))
        let neither = Self.records(nil, own: .failure(NoAnswer()))
        #expect(await Self.connection(neither.records, to: hub) == .failure(.recordNotRead))
    }

    // MARK: every other server

    /// A server that an agent runs on, as before: its entry in the list of machines.
    @Test func aServerWithAnAgentIsReachedByTheListsRecord() async throws {
        let worker = try Self.server("worker-1", address: "100.64.0.9")
        let round = Self.records(try Self.workerOnly(), own: .success(try Self.own()))
        #expect(await Self.connection(round.records, to: worker) == .success(InstallTarget(host: "100.64.0.9")))
        #expect(round.ownReads.value == 0)
    }

    /// The hub's own page names the hub's own server and no other. So for another server the list alone decides, and
    /// that page is never read: not when the list does not name the server, not when the list did not answer, and
    /// not when that page would name this server.
    @Test func theHubsOwnPageIsNeverReadForAnotherServer() async throws {
        let joined = try Self.server("worker-7", address: "100.64.0.7")
        let unnamed = Self.records(try Self.workerOnly(), own: .success(try Self.own()))
        #expect(await Self.connection(unnamed.records, to: joined) == .failure(.noConnection))
        #expect(unnamed.ownReads.value == 0)
        let noList = Self.records(nil, own: .success(try Self.own()))
        #expect(await Self.connection(noList.records, to: joined) == .failure(.recordNotRead))
        #expect(noList.ownReads.value == 0)
        let sameName = Self.records(try Self.workerOnly(), own: .success(try Self.own(machine: "worker-7", address: #""100.64.0.7""#)))
        #expect(await Self.connection(sameName.records, to: joined) == .failure(.noConnection))
        #expect(sameName.ownReads.value == 0)
        #expect(await unnamed.records.record(of: "worker-7", isHub: false) == .none)
        #expect(await noList.records.record(of: "worker-7", isHub: false) == .unknown)
    }

    // MARK: the server's own row (owner API 1.173)

    /// The second hole of 15 November 2026: a server that joined and runs no agent is in no list of machines, and the
    /// hub's own page names another server. Its own row of the list of servers has the fleet's record of it.
    @Test func aJoinedServerWithNoAgentIsReachedByItsRowsRecord() async throws {
        let joined = try Self.server("worker-7", address: "100.64.0.7", access: Self.rootRow)
        let round = Self.records(try Self.workerOnly(), own: .success(try Self.own()))
        #expect(await Self.connection(round.records, to: joined) == .success(InstallTarget(host: "100.64.0.7")))
        #expect(round.listReads.value == 1 && round.ownReads.value == 0)
        // The record's own port.
        let atPort = try Self.server("worker-7", address: "100.64.0.7", access: #"{"ssh": {"user": "root", "port": 2222}}"#)
        #expect(await Self.connection(round.records, to: atPort) == .success(InstallTarget(host: "100.64.0.7", port: 2222)))
        // The row came with the list of servers, so it is a page that answered: a list of machines that did not
        // answer, and one that is empty, change nothing.
        for list in [[], nil] as [[MachineStatus]?] {
            let other = Self.records(list, own: .failure(NoAnswer()))
            #expect(await Self.connection(other.records, to: joined) == .success(InstallTarget(host: "100.64.0.7")))
            #expect(other.ownReads.value == 0)
        }
    }

    /// A row whose `ssh` is null names the server with no record: the fleet's record is none, and known to be none
    /// also when the list of machines did not answer.
    @Test func aRowWithNoRecordIsNoConnection() async throws {
        let joined = try Self.server("worker-7", address: "100.64.0.7", access: Self.noRecordRow)
        #expect(joined.reach == MachineReach(address: "100.64.0.7"))
        // The word that the record is none needs no address.
        #expect(try Self.server("worker-7", access: Self.noRecordRow).reach == MachineReach(address: nil))
        for list in [try Self.workerOnly(), nil] as [[MachineStatus]?] {
            let round = Self.records(list, own: .success(try Self.own()))
            #expect(await Self.connection(round.records, to: joined) == .failure(.noConnection))
            #expect(await round.records.record(of: "worker-7", isHub: false, row: joined.reach) == OwnerKeyPlan.Record.none)
            #expect(round.ownReads.value == 0)
        }
    }

    /// A row's value that this app cannot use as a connection says nothing, as a row without the key: it is no word
    /// that the fleet has no record. The hub masks a text that holds a registered login in this page too, and the
    /// hub's own page is not masked: so for the hub's own server that page still decides, as before the row had a
    /// record, and for another server the result is that of a hub from before.
    @Test func aRowsValueThatIsNoConnectionSaysNothing() async throws {
        let unusable = ["{}", #"{"ssh": {}}"#, #"{"ssh": {"user": null, "port": 22}}"#, #"{"ssh": {"user": "root"}}"#,
                        #"{"ssh": {"user": "root", "port": 0}}"#, #"{"ssh": {"user": "root", "port": 70000}}"#,
                        #"{"ssh": {"user": "root -oProxyCommand=x", "port": 22}}"#,
                        #"{"ssh": {"user": "[Registered login removed]", "port": 22}}"#,
                        #"{"ssh": {"user": 5, "port": 22}}"#, #"{"ssh": {"user": "root", "port": "22"}}"#,
                        #"{"ssh": "root"}"#, #""root""#, "7", "[]"]
        for access in unusable {
            let joined = try Self.server("worker-7", address: "100.64.0.7", access: access)
            #expect(joined.reach == nil, "\(access)")
            let answered = Self.records(try Self.workerOnly(), own: .success(try Self.own()))
            #expect(await Self.connection(answered.records, to: joined) == .failure(.noConnection), "\(access)")
            let silent = Self.records(nil, own: .success(try Self.own()))
            #expect(await Self.connection(silent.records, to: joined) == .failure(.recordNotRead), "\(access)")
            // The hub's own server: its own page, which is not masked, gives the record.
            let hub = try Self.server("hub-1", hub: true, address: "100.64.0.2", access: access)
            let round = Self.records(try Self.workerOnly(), own: .success(try Self.own(#"{"user": "root", "port": 2201}"#)))
            #expect(await Self.connection(round.records, to: hub)
                    == .success(InstallTarget(host: "100.64.0.2", port: 2201)), "\(access)")
            #expect(round.ownReads.value == 1)
        }
        // A row with a whole record and no address, or with an address that `ssh` cannot take as a host, says nothing
        // either: no connection for another server, and the hub's own page for the hub's own server.
        let noAddress = try Self.server("worker-7", access: Self.rootRow)
        let badHost = try Self.server("worker-7", address: "-oProxyCommand=x", access: Self.rootRow)
        #expect(noAddress.reach == nil && badHost.reach == nil)
        let round = Self.records(try Self.workerOnly(), own: .success(try Self.own()))
        #expect(await Self.connection(round.records, to: noAddress) == .failure(.noConnection))
        #expect(await Self.connection(round.records, to: badHost) == .failure(.noConnection))
        let hubBadHost = try Self.server("hub-1", hub: true, address: "[Registered login removed]", access: Self.rootRow)
        #expect(await Self.connection(round.records, to: hubBadHost) == .success(InstallTarget(host: "100.64.0.2")))
        #expect(round.ownReads.value == 1)
        // A key that this app does not know beside the two that it reads changes nothing.
        #expect(try Self.server("worker-7", address: "100.64.0.7", access: #"{"ssh": {"user": "root", "port": 22, "more": 1}, "later": true}"#).reach
                == MachineReach(address: "100.64.0.7", user: "root", port: 22))
    }

    /// The order of the three pages, in the rule itself: the list, then the row, then the hub's own page, and each
    /// page that names the server decides, whole or not.
    @Test func theRuleTakesTheFirstPageThatNamesTheServer() throws {
        let listed = MachineReach(address: "100.64.0.2", user: "fleet", port: 2200)
        let row = MachineReach(address: "100.64.0.2", user: "admin", port: 2201)
        let own = try Self.own(#"{"user": "root", "port": 22}"#)
        let none = MachineReach(address: "100.64.0.2")
        func rule(_ listed: MachineReach?, _ row: MachineReach?, _ own: VaultHub?, read: Bool = true) -> OwnerKeyPlan.Record {
            OwnerKeyPlan.record(server: "hub-1", listed: listed, listRead: read, row: row, own: own, ownRead: read)
        }
        #expect(rule(listed, row, own) == .reach(listed))
        #expect(rule(nil, row, own) == .reach(row))
        #expect(rule(nil, nil, own) == .reach(own.reach))
        #expect(rule(none, row, own) == OwnerKeyPlan.Record.none)
        #expect(rule(nil, none, own) == OwnerKeyPlan.Record.none)
        #expect(rule(nil, nil, nil) == OwnerKeyPlan.Record.none)
        // The row came with the list of servers: it decides also when the two other pages did not answer.
        #expect(rule(nil, row, nil, read: false) == .reach(row))
        #expect(rule(nil, none, nil, read: false) == OwnerKeyPlan.Record.none)
        #expect(rule(nil, nil, nil, read: false) == .unknown)
        #expect(OwnerKeyPlan.named(server: "hub-1", listed: listed, row: row, own: own) == listed)
        #expect(OwnerKeyPlan.named(server: "hub-1", listed: nil, row: row, own: own) == row)
        #expect(OwnerKeyPlan.named(server: "hub-1", listed: nil, row: nil, own: own) == own.reach)
        #expect(OwnerKeyPlan.named(server: "hub-2", listed: nil, row: nil, own: own) == nil)
    }

    /// The list of machines comes first, as before: a server that it names has its record there, whole or not, and
    /// its row can say nothing else.
    @Test func theListOfMachinesDecidesBeforeTheRow() async throws {
        let list = try Self.machines([("worker-7", "100.64.0.7", #"{"user":"root","port":2200,"available":true}"#)])
        let joined = try Self.server("worker-7", address: "100.64.0.7", access: Self.rootRow)
        let round = Self.records(list, own: .success(try Self.own()))
        #expect(await Self.connection(round.records, to: joined) == .success(InstallTarget(host: "100.64.0.7", port: 2200)))
        let notWhole = Self.records(try Self.machines([("worker-7", "100.64.0.7", "null")]), own: .success(try Self.own()))
        #expect(await Self.connection(notWhole.records, to: joined) == .failure(.noConnection))
    }

    /// The hub's own server with its record on its row: the hub's own page is not read, for a whole record and for a
    /// record that is none. With a row that says nothing (a hub from before), that page decides as before.
    @Test func theHubsOwnPageIsNotReadForAServerThatItsRowNames() async throws {
        let onRow = try Self.server("hub-1", hub: true, address: "100.64.0.2", access: #"{"ssh": {"user": "root", "port": 2201}}"#)
        let round = Self.records(try Self.workerOnly(), own: .success(try Self.own()))
        #expect(await Self.connection(round.records, to: onRow) == .success(InstallTarget(host: "100.64.0.2", port: 2201)))
        let none = try Self.server("hub-1", hub: true, address: "100.64.0.2", access: Self.noRecordRow)
        #expect(await Self.connection(round.records, to: none) == .failure(.noConnection))
        #expect(round.ownReads.value == 0)
        let before = try Self.server("hub-1", hub: true, address: "100.64.0.2")
        #expect(await Self.connection(round.records, to: before) == .success(InstallTarget(host: "100.64.0.2")))
        #expect(round.ownReads.value == 1)
    }

    /// What a row says of the fleet's record: nothing without the key (a hub from before owner API 1.173), which is
    /// another answer than a record that is none. A value that cannot be read loses its facts and never the list.
    @Test func aRowWithoutTheKeySaysNothingAndABadValueLosesNoList() throws {
        #expect(try Self.server("worker-7", address: "100.64.0.7").reach == nil)
        #expect(try Self.server("worker-7", address: "100.64.0.7", access: "null").reach == nil)
        #expect(try Self.server("worker-7", address: "100.64.0.7", access: Self.rootRow).reach
                == MachineReach(address: "100.64.0.7", user: "root", port: 22))
        #expect(try Self.server("worker-7", address: "100.64.0.7", access: Self.noRecordRow).reach
                == MachineReach(address: "100.64.0.7"))
        // The whole list as the hub sends it, with a row of each kind.
        let json = #"""
        {"db": "db", "time": 1, "desired_revision": null, "join": null, "servers": [
          {"name": "hub-1", "hub": true, "joined": false, "agents": [], "available": false, "why": [],
           "address": "100.64.0.2", "access": {"ssh": {"user": "root", "port": 22}}},
          {"name": "worker-7", "hub": false, "joined": true, "agents": [], "available": true, "why": [],
           "address": "100.64.0.7", "user": "fleet", "access": {"ssh": {"user": "root", "port": 2222}}},
          {"name": "mini", "hub": false, "joined": true, "agents": [], "available": true, "why": [],
           "address": "100.64.0.3", "user": "dana", "access": {"ssh": null}},
          {"name": "odd", "hub": false, "joined": true, "agents": [], "available": true, "why": [], "access": 7},
          {"name": "before", "hub": false, "joined": true, "agents": [], "available": true, "why": []}]}
        """#
        let list = try JSONDecoder().decode(ServerList.self, from: Data(json.utf8))
        try list.validate(database: "db")
        #expect(list.servers.map { $0.reach?.onRecord?.user } == ["root", "root", nil, nil, nil])
        #expect(list.servers.map { $0.reach?.onRecord?.port } == [22, 2222, nil, nil, nil])
        #expect(list.servers.map { $0.reach != nil } == [true, true, true, false, false])
        // The row's own `user` is the OS user of the server's service, which is not the user of the connection.
        #expect(list.servers[1].user == "fleet" && list.servers[1].reach?.user == "root")
    }

    // MARK: a page that the owner opens

    /// The record for a page, out of what the app holds: the same pages in the same order, whole or not, and nil
    /// when no page names the server.
    @Test func aPageTakesTheRecordFromThePagesThatTheAppHolds() throws {
        let own = try Self.own(#"{"user": "admin", "port": 22}"#)
        let list = try Self.workerOnly()
        // The hub's own server with no agent and a hub from before: the vault's page that the app keeps.
        let hubBefore = try Self.server("hub-1", hub: true, address: "100.64.0.2")
        #expect(ServerRecords.held(of: hubBefore, machines: list, own: own) == own.reach)
        #expect(ServerRecords.held(of: hubBefore, machines: list, own: nil) == nil)
        let anotherHub = try Self.own(machine: "hub-2")
        #expect(ServerRecords.held(of: hubBefore, machines: list, own: anotherHub) == nil)
        // Its row, where the hub sends one: the vault's page is not asked.
        let asked = Calls()
        func kept(_ page: VaultHub? = nil) -> VaultHub? { asked.add(); return page ?? own }
        let hubNow = try Self.server("hub-1", hub: true, address: "100.64.0.2", access: Self.rootRow)
        #expect(ServerRecords.held(of: hubNow, machines: list, own: kept()) == MachineReach(address: "100.64.0.2", user: "root", port: 22))
        // A server that joined and runs no agent: its row, and nothing from a hub before. The vault's page is the
        // hub's own server's, so it is not asked for another server, also when it would name this one.
        let joined = try Self.server("worker-7", address: "100.64.0.7", access: Self.rootRow)
        #expect(ServerRecords.held(of: joined, machines: list, own: kept()) == MachineReach(address: "100.64.0.7", user: "root", port: 22))
        let joinedBefore = try Self.server("worker-7", address: "100.64.0.7")
        #expect(ServerRecords.held(of: joinedBefore, machines: list, own: kept()) == nil)
        let sameName = try Self.own(machine: "worker-7", address: #""100.64.0.7""#)
        #expect(ServerRecords.held(of: joinedBefore, machines: list, own: kept(sameName)) == nil)
        // A row with no record names the server: a record that is none, and not nil.
        let noRecord = try Self.server("worker-7", address: "100.64.0.7", access: Self.noRecordRow)
        #expect(ServerRecords.held(of: noRecord, machines: list, own: kept()) == MachineReach(address: "100.64.0.7"))
        // A server that the list of machines names: its entry there, before its row, and the vault's page is not asked.
        let worker = try Self.server("worker-1", hub: true, address: "100.64.0.9", access: #"{"ssh": {"user": "fleet", "port": 2200}}"#)
        #expect(ServerRecords.held(of: worker, machines: list, own: kept()) == MachineReach(address: "100.64.0.9", user: "root", port: 22))
        // The same for a hub's server that the list names and whose row says nothing: the list's entry.
        let listedHub = try Self.server("worker-1", hub: true, address: "100.64.0.9")
        #expect(ServerRecords.held(of: listedHub, machines: list, own: kept()) == MachineReach(address: "100.64.0.9", user: "root", port: 22))
        #expect(asked.value == 0)
        #expect(ServerRecords.held(of: hubBefore, machines: list, own: kept()) == own.reach)
        #expect(asked.value == 1)
    }

    // MARK: one round

    /// A connection that this Mac keeps from an install needs no page: for the hub's server and for any other.
    @Test func aKeptConnectionReadsNoPage() async throws {
        let round = Self.records(try Self.workerOnly(), own: .success(try Self.own()))
        let kept = InstallTarget(host: "100.64.0.2", user: "admin", port: 2200, identityFile: "/Users/me/.ssh/id_ed25519")
        var asRoot = kept
        asRoot.becomeRoot = true
        for server in [try Self.server("hub-1", hub: true, address: "100.64.0.2"), try Self.server("worker-7", address: "100.64.0.2")] {
            #expect(await Self.connection(round.records, to: server, kept: kept) == .success(asRoot))
        }
        #expect(round.listReads.value == 0 && round.ownReads.value == 0)
    }

    /// The list of machines is read once in a round, at the first server that needs it. A read that did not answer is
    /// made again for the next server, and the hub's own page is read for the hub's server alone.
    @Test func theListOfMachinesIsReadOnceInARound() async throws {
        let hub = try Self.server("hub-1", hub: true, address: "100.64.0.2")
        let worker = try Self.server("worker-1", address: "100.64.0.9"), joined = try Self.server("worker-7", address: "100.64.0.7")
        let round = Self.records(try Self.workerOnly(), own: .success(try Self.own()))
        #expect(await Self.connection(round.records, to: worker) == .success(InstallTarget(host: "100.64.0.9")))
        #expect(await Self.connection(round.records, to: hub) == .success(InstallTarget(host: "100.64.0.2")))
        #expect(await Self.connection(round.records, to: joined) == .failure(.noConnection))
        #expect(round.listReads.value == 1 && round.ownReads.value == 1)

        let silent = Self.records(nil, own: .success(try Self.own()))
        #expect(await Self.connection(silent.records, to: worker) == .failure(.recordNotRead))
        #expect(await Self.connection(silent.records, to: joined) == .failure(.recordNotRead))
        #expect(silent.listReads.value == 2 && silent.ownReads.value == 0)
    }

    // MARK: the connection itself

    /// How this Mac reaches a server as root, from a kept connection or from the fleet's record. **A record's user that
    /// is not root is no connection of a root step** (M1 of the validation of 23 November 2026). Bug: a root step takes
    /// the record's `fleet` through `sudo -n`, in a session that that user's own `authorized_keys` controls with a
    /// forced command, so the hub's own user decides what the vault's root read prints, and the Mac pins it. The key
    /// registration, which reads as the proof file's owner, takes that user (`rootOnly` false).
    @Test func theConnectionBecomesRootWhereItsUserIsNotRoot() throws {
        let server = try Self.server("worker-1", address: "100.64.0.9")
        // A kept connection wins over the record, keeps its own user, port and key, and goes to the private address
        // that the fleet reports when the kept one is a public address.
        let record = MachineReach(address: "100.64.0.9", user: "fleet", port: 22)
        let keptRoot = InstallTarget(host: "203.0.113.7", identityFile: "/Users/me/.ssh/id_ed25519")
        #expect(ServerRecords.target(server, kept: keptRoot, record: record)
                == InstallTarget(host: "100.64.0.9", identityFile: "/Users/me/.ssh/id_ed25519"))
        #expect(ServerRecords.target(server, kept: InstallTarget(host: "100.64.0.9", user: "admin"), record: nil)
                == InstallTarget(host: "100.64.0.9", user: "admin", becomeRoot: true))
        // With none kept, the record: root as root, and another user for no root step.
        #expect(ServerRecords.target(server, kept: nil, record: MachineReach(address: "100.64.0.9", user: "root", port: 22))
                == InstallTarget(host: "100.64.0.9"))
        #expect(ServerRecords.target(server, kept: nil, record: record) == nil)
        #expect(ServerRecords.target(server, kept: nil, record: record, rootOnly: false)
                == InstallTarget(host: "100.64.0.9", user: "fleet", becomeRoot: true))
        // No record, or one that is no whole connection: none.
        #expect(ServerRecords.target(server, kept: nil, record: nil) == nil)
        #expect(ServerRecords.target(server, kept: nil, record: MachineReach(address: "100.64.0.9", user: "root")) == nil)
        #expect(ServerRecords.target(server, kept: nil, record: MachineReach(address: "100.64.0.9")) == nil)
    }
}
