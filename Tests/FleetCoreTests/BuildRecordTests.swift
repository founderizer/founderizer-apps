#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// **The kept record of a server that this Mac asked a provider for** (`BuildRecord`, `BuildRecords`): what it says of
/// a server that was made and never joined, also after the app's end, what a failed call left at the provider, and
/// how a later install's end closes it. Each test has a scratch folder of its own and removes it.
struct BuildRecordTests {
    private final class Scratch {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("build-records-\(UUID().uuidString)")
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    private let hub = "http://100.64.0.7:8765/"
    private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    private func build(_ name: String = "worker-2", use: CloudServerUse = .agent, hub: String? = "http://100.64.0.7:8765/",
                       provider: CloudProvider = .hetzner, launch: String = "now", at seconds: Double = 0) -> BuildRecord {
        BuildRecord(provider: provider, use: use, hub: hub, name: name, launch: launch, at: time(seconds))
    }

    /// A build whose server was made and that stopped while this Mac waited for it.
    private func stopped(_ name: String = "worker-2", id: String = "4711", hub: String? = "http://100.64.0.7:8765/",
                         launch: String = "now", at seconds: Double = 0) -> BuildRecord {
        var record = build(name, hub: hub, launch: launch, at: seconds)
        record.made(id: id, at: time(seconds + 8))
        record.end(at: time(seconds + 308))
        return record
    }

    /// The names that a reader for another program gives out are lower-case words with underscores, and none repeats.
    @Test func theFixedNamesAreSnakeCase() {
        #expect(BuildRecord.Stage.allCases.map(\.rawValue) == ["making", "joining"])
        #expect(BuildRecord.Outcome.allCases.map(\.rawValue) == ["running", "joined", "stopped", "cancelled", "interrupted"])
        #expect(BuildRecord.AtProvider.allCases.map(\.rawValue) == ["not_known", "nothing", "left_behind", "server"])
        for name in CloudProvider.allCases.map(\.rawValue) + [CloudServerUse.hub.rawValue, CloudServerUse.agent.rawValue] {
            #expect(name.range(of: "^[a-z]+(_[a-z]+)*$", options: .regularExpression) != nil, "\(name)")
        }
    }

    /// While the call for the server runs, what it left is not known; a build that the app's end cut off there can
    /// have left a server.
    @Test func whileTheProviderIsAskedNothingIsKnown() {
        let record = build()
        #expect(record.stage == .making && record.outcome == .running && record.atProvider == .notKnown)
        #expect(!record.isMade && !record.isUnjoined)
        let cut = record.cutOff()
        #expect(cut.outcome == .interrupted && cut.isUnjoined && !cut.isMade && cut.lastChange == time(0))
    }

    /// What a call that failed left at the provider: nothing when the call was not sent, when the provider refused,
    /// and when the app deleted what was made; something when the app could not delete it; not known when the provider
    /// did not answer, or for an error of another kind.
    @Test func aFailedCallSaysWhatItLeft() {
        typealias At = BuildRecord.AtProvider
        for error in [CloudError.notAServerName, .notAPublicKey, .notAnAuthKey, .noToken(.hetzner), .notAToken(.hetzner),
                      .tokenNotAccepted(.vultr), .readOnlyToken(.akamai), .rateLimited(.hetzner),
                      .refused(.digitalOcean, "the name is in use"), .noRoom(.hetzner), .notReady(.digitalOcean)] {
            #expect(At.after(error) == .nothing, "\(error)")
        }
        #expect(At.after(CloudError.leftBehind(.digitalOcean, reason: "It did not come up.", left: ["the server worker-2"]))
            == .leftBehind)
        #expect(At.after(CloudError.unreachable(.hetzner)) == .notKnown)
        #expect(At.after(CloudError.notUnderstood(.hetzner)) == .notKnown)
        #expect(At.after(URLError(.timedOut)) == .notKnown)
        // The page ended the build while the app waited for the new server: the call deleted what it made.
        #expect(At.after(CancellationError()) == .nothing)
    }

    /// Back while the provider is asked: the call deleted what it made, so the build is cancelled and no server stands
    /// at the provider; when it could not delete it, the server is left there.
    @Test func aBuildThatItsPageEndedWhileTheProviderWasAskedLeavesNothing() {
        var record = build()
        record.callEnded(with: CancellationError())
        record.end(cancelled: true, at: time(4))
        #expect(record.outcome == .cancelled && record.atProvider == .nothing && !record.isUnjoined)
        var left = build()
        left.callEnded(with: CloudError.leftBehind(.hetzner, reason: "cancelled", left: ["the server worker-2"]))
        left.end(cancelled: true, at: time(4))
        #expect(left.outcome == .cancelled && left.atProvider == .leftBehind && left.isUnjoined)
    }

    /// A try whose call left nothing is no server at the provider; one that left something, or whose answer is not
    /// known, is one that can stand there.
    @Test func onlyABuildThatDidNotLeaveNothingIsAnUnjoinedServer() {
        var refused = build()
        refused.callEnded(with: CloudError.refused(.hetzner, "the name is in use"))
        refused.end(at: time(3))
        #expect(refused.outcome == .stopped && refused.atProvider == .nothing && !refused.isUnjoined && !refused.isMade)

        var left = build()
        left.callEnded(with: CloudError.leftBehind(.digitalOcean, reason: "It did not come up.", left: ["the server worker-2"]))
        left.end(at: time(3))
        #expect(left.atProvider == .leftBehind && left.isUnjoined && !left.isMade && left.stage == .making)

        var silent = build()
        silent.callEnded(with: CloudError.unreachable(.hetzner))
        silent.end(at: time(3))
        #expect(silent.atProvider == .notKnown && silent.isUnjoined && silent.ended == time(3) && silent.lastChange == time(3))
    }

    /// **A new server never takes the name of an earlier build's server that can still join**: one that did not join,
    /// left something at its provider or does not know yet, and began less than its key's hour and five minutes ago.
    @Test func aNameStaysTakenWhileItsServerCanStillJoin() {
        let running = build("worker-2")                     // its call has no answer yet
        let waiting = stopped("worker-3")                   // made, and stopped while this Mac waited for it
        var joined = build("worker-4")
        joined.made(id: "9", at: time(8))
        joined.joined(at: time(90))
        var refused = build("worker-5")
        refused.callEnded(with: CloudError.refused(.hetzner, "the name is in use"))
        refused.end(at: time(3))
        let old = stopped("worker-6", at: -4000)
        #expect(BuildRecord.namesInUse([running, waiting, joined, refused, old], at: time(600)) == ["worker-2", "worker-3"])
        #expect(BuildRecord.namesInUse([waiting], at: time(3899)) == ["worker-3"])
        #expect(BuildRecord.namesInUse([waiting], at: time(3900)).isEmpty)
    }

    /// The provider answered with the server: it exists for sure, and a stop while this Mac waits for it is the server
    /// that was made and never joined. An error after that says nothing of what the provider has.
    @Test func aServerThatWasMadeAndNeverJoined() {
        var record = build()
        record.made(id: "4711", at: time(8))
        #expect(record.stage == .joining && record.isMade && record.serverID == "4711" && record.outcome == .running)
        #expect(record.atProvider == .server && record.lastChange == time(8))
        record.callEnded(with: CloudError.refused(.hetzner, "too late"))
        #expect(record.atProvider == .server)
        record.end(at: time(308))
        #expect(record.outcome == .stopped && record.isUnjoined && record.isMade && record.ended == time(308))
        // The private network's own list had it, and this Mac did not see it.
        var hidden = build()
        hidden.made(id: "4712", at: time(8))
        hidden.end(onNetwork: true, at: time(308))
        #expect(hidden.isUnjoined && hidden.onNetwork)
    }

    /// A build that joined is no unjoined server, and its end stays: a later end changes nothing, and neither does a
    /// second answer of the provider.
    @Test func aBuildThatJoinedKeepsItsEnd() {
        var record = build()
        record.made(id: "4711", at: time(8))
        record.joined(at: time(40))
        record.end(cancelled: true, at: time(50))
        record.made(id: "9999", at: time(60))
        record.joined(at: time(70))
        #expect(record.outcome == .joined && !record.isUnjoined && record.ended == time(40) && record.serverID == "4711")
    }

    /// The page ended a build that ran: it is cancelled, and the server can still stand at the provider.
    @Test func aBuildThatItsPageEndedIsStillAnUnjoinedServer() {
        var record = build()
        record.made(id: "4711", at: time(8))
        record.end(cancelled: true, at: time(20))
        #expect(record.outcome == .cancelled && record.isUnjoined && record.isMade)
    }

    /// The record's file has these fields and no other: no token, no key, no address of the server, no price.
    @Test func theRecordHasItsFieldsAndNoOther() throws {
        var record = build()
        record.made(id: "4711", at: time(8))
        record.end(onNetwork: true, at: time(308))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["id", "launch", "provider", "use", "hub", "name", "serverID", "stage",
                                                      "atProvider", "onNetwork", "began", "madeAt", "ended", "outcome"])
        #expect(object?["provider"] as? String == "hetzner" && object?["use"] as? String == "agent")
        #expect(object?["atProvider"] as? String == "server")
    }

    /// **What "Start again" reads in a record**: the server's type and price as the provider said them, and, for a
    /// first run's server, the address that its hub will have, which the record gets when the server is on the private
    /// network. A record that has its hub keeps it, and a record of an earlier build, with none of these, is read.
    @Test func aRecordKeepsTheTypeThePriceAndAFirstRunsHub() throws {
        var first = build("worker-1", use: .hub, hub: nil)
        first.made(id: "4711", type: "cx23", monthlyPrice: Decimal(string: "5.49"), currency: "EUR", at: time(8))
        #expect(first.type == "cx23" && first.monthlyPrice == Decimal(string: "5.49") && first.currency == "EUR")
        first.joined(at: time(60), hub: hub)
        #expect(first.hub == hub && first.outcome == .joined)
        let read = try JSONDecoder().decode(BuildRecord.self, from: JSONEncoder().encode(first))
        #expect(read == first)
        // A server made for a hub keeps that hub, whatever its join names; an empty address is none.
        var agent = build("worker-2")
        agent.made(id: "4712", at: time(8))
        agent.joined(at: time(60), hub: "http://100.64.1.7:8765/")
        #expect(agent.hub == hub)
        var none = build("worker-3", hub: nil)
        none.made(id: "4713", at: time(8))
        none.joined(at: time(60), hub: "")
        #expect(none.hub == nil)
        // A record of an earlier build has no type and no price.
        var old = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        for key in ["type", "monthlyPrice", "currency"] { old[key] = nil }
        let earlier = try JSONDecoder().decode(BuildRecord.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(earlier.type == nil && earlier.monthlyPrice == nil && earlier.serverID == "4711")
    }

    /// **The records of one hub go when the app forgets that fleet** (`remove(where:)`): their files too, so another
    /// start of the app does not read them again. The records of another hub and of a first run stay.
    @Test func theRecordsOfOneHubAreRemovedWithTheirFiles() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = BuildRecords(folder: scratch.folder, launch: "now")
        let mine = stopped("worker-2", id: "4711"), theirs = stopped("worker-2", id: "4712", hub: "http://100.64.1.7:8765/")
        let firstRun = stopped("worker-1", id: "4713", hub: nil)
        for record in [mine, theirs, firstRun] { records.write(record) }
        let before = records.changes
        records.remove { $0.hub == hub }
        #expect(Set(records.all().map(\.id)) == [theirs.id, firstRun.id])
        #expect(records.changes == before + 1)
        #expect(Set(BuildRecords(folder: scratch.folder, launch: "next").all().map(\.id)) == [theirs.id, firstRun.id])
        // Nothing to remove changes nothing.
        records.remove { $0.hub == hub }
        #expect(records.changes == before + 1)
    }

    /// The servers that never joined are found by their hub after another start of the app, and a first run's ones by
    /// "no hub". A build that the app's end cut off reads as interrupted, which is unjoined too, and never as running.
    /// A try that left nothing is in no such list.
    @Test func theUnjoinedServersOfAHubOutliveTheApp() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let first = BuildRecords(folder: scratch.folder, launch: "first")
        let stopped = stopped("worker-2", launch: "first", at: 0)
        var joined = build("worker-3", launch: "first", at: 400)
        joined.made(id: "4712", at: time(408))
        joined.joined(at: time(430))
        var cut = build("worker-4", launch: "first", at: 500)
        cut.made(id: "4713", at: time(508))
        var firstRun = build("hub-1", use: .hub, hub: nil, provider: .vultr, launch: "first", at: 600)
        firstRun.callEnded(with: CloudError.unreachable(.vultr))
        firstRun.end(at: time(603))
        var other = build("worker-9", hub: "http://100.64.0.9:8765/", launch: "first", at: 700)
        other.end(at: time(701))
        var refused = build("worker-5", launch: "first", at: 800)
        refused.callEnded(with: CloudError.noRoom(.hetzner))
        refused.end(at: time(801))
        for record in [stopped, joined, cut, firstRun, other, refused] { first.write(record) }
        // In its own start of the app the build that waits still runs.
        #expect(first.unjoined(hub: hub).map(\.name) == ["worker-2"])

        let later = BuildRecords(folder: scratch.folder, launch: "second")
        #expect(later.unjoined(hub: hub).map(\.name) == ["worker-4", "worker-2"])
        #expect(later.unjoined(hub: hub).map(\.outcome) == [.interrupted, .stopped])
        #expect(later.unjoined(hub: hub).first?.lastChange == time(508))
        #expect(later.unjoined(hub: nil).map(\.name) == ["hub-1"])
        #expect(later.unjoined(hub: nil).first?.isMade == false && later.unjoined(hub: nil).first?.atProvider == .notKnown)
        #expect(later.newest(hub: hub)?.name == "worker-5")
        #expect(later.newest(hub: nil)?.provider == .vultr)
        #expect(later.all().count == 6)
    }

    /// An install's end for a server of that name in that hub closes the newest build of the name when it did not end
    /// in a join, and no other: not the same name in another hub, not a first run's.
    @Test func aLaterInstallClosesTheNewestBuildOfThatName() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = BuildRecords(folder: scratch.folder, launch: "now")
        let old = stopped("worker-2", id: "4711", at: 0)
        let new = stopped("worker-2", id: "4720", at: 1000)
        let elsewhere = stopped("worker-2", id: "4730", hub: "http://100.64.0.9:8765/", at: 2000)
        let firstRun = stopped("worker-2", id: "4740", hub: nil, at: 3000)
        for record in [old, new, elsewhere, firstRun] { records.write(record) }

        records.noteJoined(name: "Worker-2", hub: hub, at: time(5000))
        let mine = records.all().filter { $0.hub == hub }
        #expect(mine.map(\.outcome) == [.joined, .stopped])
        #expect(mine.first?.serverID == "4720" && mine.first?.ended == time(5000))
        #expect(records.unjoined(hub: hub).map(\.serverID) == ["4711"])
        #expect(records.unjoined(hub: "http://100.64.0.9:8765/").count == 1)
        #expect(records.unjoined(hub: nil).count == 1)
        // A name that no build has changes nothing.
        let before = records.changes
        records.noteJoined(name: "worker-7", hub: hub, at: time(6000))
        #expect(records.changes == before)
    }

    /// **A new try takes the name of a server that never came to the network.** When the new one joins, its install's
    /// end must not close the record of the old one, which still stands at the provider: only the newest build of the
    /// name is looked at, and that one joined already.
    @Test func theInstallOfANewServerNeverClosesAnOlderOneOfItsName() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = BuildRecords(folder: scratch.folder, launch: "now")
        let old = stopped("worker-2", id: "4711", at: 0)
        var new = build("worker-2", at: 1000)
        new.made(id: "4720", at: time(1008))
        new.joined(at: time(1040))
        records.write(old)
        records.write(new)
        let before = records.changes
        records.noteJoined(name: "worker-2", hub: hub, at: time(2000))
        #expect(records.changes == before)
        #expect(records.unjoined(hub: hub).map(\.serverID) == ["4711"])
        // A build of the name that still runs is not closed by an install either.
        var running = build("worker-2", at: 3000)
        running.made(id: "4750", at: time(3008))
        records.write(running)
        records.noteJoined(name: "worker-2", hub: hub, at: time(3100))
        #expect(records.newest(hub: hub)?.outcome == .running)
    }

    /// **A try that left nothing is no server.** The provider refused the name of a new try because the server of the
    /// try before it has it; that server then comes to the fleet, and its install's end closes ITS record, not the
    /// record of the try that made nothing.
    @Test func anInstallPassesOverATryThatLeftNothing() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = BuildRecords(folder: scratch.folder, launch: "now")
        let made = stopped("worker-2", id: "4711", at: 0)
        var refused = build("worker-2", at: 1000)
        refused.callEnded(with: CloudError.refused(.hetzner, "the name is in use"))
        refused.end(at: time(1001))
        records.write(made)
        records.write(refused)
        #expect(records.unjoined(hub: hub).map(\.serverID) == ["4711"])
        records.noteJoined(name: "worker-2", hub: hub, at: time(2000))
        let both = records.all().filter { $0.name == "worker-2" }
        #expect(both.map(\.outcome) == [.stopped, .joined])
        #expect(both.map(\.atProvider) == [.nothing, .server])
        #expect(records.unjoined(hub: hub).isEmpty)
    }

    /// A build that was cut off and that an install then proved is joined, and stays so in every later start: its
    /// server is at the provider, whatever was known before.
    @Test func aCutOffBuildThatAnInstallProvedIsJoined() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let cut = build("worker-4", launch: "first", at: 0)
        BuildRecords(folder: scratch.folder, launch: "first").write(cut)
        let second = BuildRecords(folder: scratch.folder, launch: "second")
        #expect(second.unjoined(hub: hub).map(\.atProvider) == [.notKnown])
        second.noteJoined(name: "worker-4", hub: hub, at: time(900))
        let third = BuildRecords(folder: scratch.folder, launch: "third")
        #expect(third.all().map(\.outcome) == [.joined] && third.all().map(\.atProvider) == [.server])
        #expect(third.unjoined(hub: hub).isEmpty)
    }

    /// **"Use this server" proves its server by the provider's id** (the lane "Unfinished setup", 15 November 2026): a
    /// first run's server that stopped before this Mac saw it on the private network has no hub, so the name of a later
    /// install finds no record, and the id closes it, with the hub that the install proved. The same id at another
    /// provider, a build that still runs, an id that no build has, and a record that joined that hub already change
    /// nothing.
    @Test func anInstallOnAServerOfTheListClosesItsBuildByItsId() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = BuildRecords(folder: scratch.folder, launch: "now")
        let firstRun = stopped("worker-3", id: "4750", hub: nil, at: 0)
        var elsewhere = build("worker-3", hub: nil, provider: .vultr, at: 100)
        elsewhere.made(id: "4750", at: time(108))
        elsewhere.end(at: time(408))
        var running = build("worker-5", hub: nil, at: 200)
        running.made(id: "4760", at: time(208))
        for record in [firstRun, elsewhere, running] { records.write(record) }

        records.noteJoined(name: "worker-3", hub: hub, at: time(900))
        #expect(records.unjoined(hub: nil).count == 2)

        records.noteJoined(serverID: "4750", provider: .hetzner, hub: hub, at: time(1000))
        let closed = records.all().first { $0.id == firstRun.id }
        #expect(closed?.outcome == .joined && closed?.hub == hub && closed?.ended == time(1000))
        #expect(records.unjoined(hub: hub).isEmpty)
        #expect(records.all().first { $0.id == elsewhere.id }?.outcome == .stopped)

        let before = records.changes
        records.noteJoined(serverID: "4760", provider: .hetzner, hub: hub, at: time(1100))
        records.noteJoined(serverID: "4799", provider: .hetzner, hub: hub, at: time(1100))
        records.noteJoined(serverID: "4750", provider: .hetzner, hub: hub, at: time(1200))
        records.noteJoined(serverID: "", provider: .hetzner, hub: hub, at: time(1200))
        #expect(records.changes == before)
        #expect(records.all().first { $0.id == running.id }?.outcome == .running)
    }

    /// A server that joined one fleet and that the install of another fleet took ("Use this server" in a new first run)
    /// is that fleet's now: the record's hub moves with the install's proof, and the record keeps its end.
    @Test func aServerThatAnotherFleetTookIsThatFleetsNow() {
        let scratch = Scratch()
        defer { scratch.remove() }
        let records = BuildRecords(folder: scratch.folder, launch: "now")
        var joined = build("worker-6", at: 0)
        joined.made(id: "4770", at: time(8))
        joined.joined(at: time(90))
        records.write(joined)
        let other = "http://100.64.0.9:8765/"
        records.noteJoined(serverID: "4770", provider: .hetzner, hub: other, at: time(5000))
        let moved = records.all().first
        #expect(moved?.hub == other && moved?.outcome == .joined && moved?.ended == time(90))
        #expect(records.unjoined(hub: hub).isEmpty && records.unjoined(hub: other).isEmpty)
    }

    /// The two kinds of record have their own folders and their own signs of change: a build's file in the folder of
    /// the installs is no install, and a write of a build posts the builds' sign only.
    @Test func aBuildAndAnInstallAreNeverReadAsEachOther() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let build = stopped()
        BuildRecords(folder: scratch.folder, launch: "now").write(build)
        #expect(InstallRecords(folder: scratch.folder, launch: "now").all().isEmpty)
        let install = InstallRecord(kind: .join, hub: hub, host: "203.0.113.9", launch: "now", at: time(0))
        let both = InstallRecords(folder: scratch.folder, launch: "now")
        both.write(install)
        #expect(both.all() == [install])
        #expect(BuildRecords(folder: scratch.folder, launch: "now").all() == [build])

        #expect(BuildRecords.changed != InstallRecords.changed)
        // Each store posts its own kind's sign, with itself: other tests' stores post theirs at the same time.
        final class Count: @unchecked Sendable { var builds = 0, installs = 0 }
        let count = Count()
        let center = NotificationCenter.default
        let records = BuildRecords(folder: scratch.folder.appendingPathComponent("more"), launch: "now")
        let one = center.addObserver(forName: BuildRecords.changed, object: records, queue: nil) { _ in count.builds += 1 }
        let two = center.addObserver(forName: InstallRecords.changed, object: records, queue: nil) { _ in count.installs += 1 }
        defer { center.removeObserver(one); center.removeObserver(two) }
        records.write(self.build("worker-8"))
        #expect(count.builds == 1 && count.installs == 0)
    }
}
#endif
