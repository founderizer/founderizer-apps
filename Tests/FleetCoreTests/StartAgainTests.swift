#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// **"Start again"** (`StartAgain`): which servers this Mac may delete, which device of the private network one build
/// made, the rows and the words of the pages, the order of a run and where it stops, and which kept values of a hub the
/// app clears. Nothing here reaches a provider, a private network or the app's own settings: each test has its own
/// records, its own stand-in for the calls and its own scratch settings.
struct StartAgainTests {
    private let hub = URL(string: "http://100.64.0.1:8765/")!
    /// A hub whose address only starts the same.
    private let other = URL(string: "http://100.64.0.10:8765/")!

    private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    /// A build whose server the provider made, eight seconds after the build began.
    private func build(_ name: String, id: String?, use: CloudServerUse = .agent, hub: String? = "http://100.64.0.1:8765/",
                       provider: CloudProvider = .hetzner, at seconds: Double = 0, price: Decimal? = nil) -> BuildRecord {
        var record = BuildRecord(provider: provider, use: use, hub: hub, name: name, launch: "now", at: time(seconds))
        if let id { record.made(id: id, type: "cx23", monthlyPrice: price, currency: price == nil ? nil : "EUR", at: time(seconds + 8)) }
        return record
    }

    private func listed(_ id: String, _ name: String, type: String = "cx23", madeFor: String? = nil) -> CloudExisting {
        CloudExisting(id: id, name: name, ipv4: "203.0.113.5", type: type, memoryMB: 4096, system: "ubuntu", version: "24.04",
                      place: "Nuremberg", running: true, project: nil, madeFor: madeFor)
    }

    private func device(_ id: String, _ hostname: String, created seconds: Double?, tags: [String] = ["tag:founderizer"],
                        authorized: Bool = true, external: Bool = false, address: String = "100.64.0.9",
                        connected: Bool = false) -> FleetDevice {
        FleetDevice(id: id, hostname: hostname, name: "\(hostname).example.ts.net", addresses: [address], tags: tags,
                    created: seconds.map(time), authorized: authorized, external: external, connected: connected)
    }

    // MARK: - The proof

    @Test func aBuildRecordWithThisHubAndTheProvidersIdIsTheProof() {
        let hubBuild = build("worker-1", id: "101", use: .hub, price: Decimal(string: "5.49"))
        let agentBuild = build("worker-2", id: "102", at: 600)
        let proven = StartAgain.proven(hub: hub, made: [:], builds: [agentBuild, hubBuild],
                                       listed: [.hetzner: [listed("102", "worker-2"), listed("101", "worker-1"), listed("999", "web-1")]])
        // The hub's own server first; each by the provider's id and at the record's own provider.
        #expect(proven.servers.map(\.serverID) == ["101", "102"])
        #expect(proven.servers.map(\.provider) == [.hetzner, .hetzner])
        #expect(proven.servers.map(\.use) == [.hub, .agent])
        #expect(proven.servers[0].type == "cx23" && proven.servers[0].monthlyPrice == Decimal(string: "5.49"))
        #expect(proven.servers[0].build == hubBuild)
        #expect(proven.gone.isEmpty)
        // A server of the account that no record names is never in it, whatever its label says.
        #expect(!proven.servers.contains { $0.serverID == "999" })
    }

    @Test func nothingElseIsAProof() {
        let list: [CloudProvider: [CloudExisting]] = [.hetzner: [
            listed("201", "worker-1", madeFor: "hub"), listed("202", "worker-2", madeFor: "agent"), listed("203", "worker-3")]]
        // A provider's label names no fleet: a server with the label and no record stays.
        #expect(StartAgain.proven(hub: hub, made: [:], builds: [], listed: list).servers.isEmpty)
        // A first run's record with no hub, a record of another hub, and a record with no id of the provider.
        let builds = [build("worker-1", id: "201", hub: nil), build("worker-2", id: "202", hub: other.absoluteString),
                      build("worker-3", id: nil)]
        #expect(StartAgain.proven(hub: hub, made: [:], builds: builds, listed: list).servers.isEmpty)
        // A name alone: an entry of the made servers with no id, and one whose id is another server's.
        #expect(StartAgain.proven(hub: hub, made: ["worker-1": "", "worker-2": "777"], builds: [], listed: list).servers.isEmpty)
        // An id whose server has another name now is not the server that was kept.
        #expect(StartAgain.proven(hub: hub, made: ["worker-9": "201"], builds: [], listed: list).servers.isEmpty)
        // An id that is no id of a provider never reaches a path.
        #expect(StartAgain.proven(hub: hub, made: ["worker-1": "201/../202"], builds: [build("worker-2", id: "20 2")], listed: list)
            .servers.isEmpty)
    }

    @Test func aMadeServerIsProvenOnlyByItsIdAndItsNameInOneProvidersList() {
        let made = ["worker-2": "302"]
        let one = StartAgain.proven(hub: hub, made: made, builds: [], listed: [
            .hetzner: [listed("301", "worker-1")], .digitalOcean: [listed("302", "Worker-2", type: "s-1vcpu-2gb")]])
        #expect(one.servers.map(\.id) == ["digitalocean|302"])
        // It was made for agents, and it has no build: its device stays.
        #expect(one.servers.first?.use == .agent && one.servers.first?.build == nil)
        #expect(one.servers.first?.type == "s-1vcpu-2gb" && one.servers.first?.monthlyPrice == nil)
        // The entry names no provider: two lists that both have such a server prove nothing.
        let two = StartAgain.proven(hub: hub, made: made, builds: [], listed: [
            .hetzner: [listed("302", "worker-2")], .digitalOcean: [listed("302", "worker-2")]])
        #expect(two.servers.isEmpty)
        // A provider whose list was not read proves nothing for it.
        #expect(StartAgain.proven(hub: hub, made: made, builds: [], listed: [:]).servers.isEmpty)
        // The same server in both records is one server, and the build's record names its provider.
        let both = StartAgain.proven(hub: hub, made: made, builds: [build("worker-2", id: "302", provider: .digitalOcean)],
                                     listed: [.hetzner: [listed("302", "worker-2")], .digitalOcean: [listed("302", "worker-2")]])
        #expect(both.servers.map(\.id) == ["digitalocean|302"])
    }

    @Test func aServerThatTheProviderNoLongerHasIsGoneAndAFailedReadLeavesTheRecordsRow() {
        let first = build("worker-1", id: "101", use: .hub, price: Decimal(string: "5.49")), second = build("worker-2", id: "102", at: 600)
        // The list was read and has only one of the two: the other is gone, and nothing is deleted for it.
        let read = StartAgain.proven(hub: hub, made: [:], builds: [first, second], listed: [.hetzner: [listed("102", "worker-2")]])
        #expect(read.servers.map(\.serverID) == ["102"] && read.gone == [first])
        #expect(read.builds == [second, first])
        // The list was not read: the rows are the records' own, with no type and no price.
        let failed = StartAgain.proven(hub: hub, made: ["worker-3": "103"], builds: [first, second], listed: [:])
        #expect(failed.servers.map(\.serverID) == ["101", "102"] && failed.gone.isEmpty)
        #expect(failed.servers.allSatisfy { $0.type == nil && $0.monthlyPrice == nil && $0.currency == nil })
    }

    /// **A list is one token's list.** A token of another project or account does not have this fleet's servers, so a
    /// server that the list lacks is gone only when the machine that its build made does not run.
    @Test func aServerWhoseMachineStillRunsIsNotGoneWhateverTheListSays() {
        let first = build("worker-1", id: "101", use: .hub, price: Decimal(string: "5.49")), second = build("worker-2", id: "102", at: 600)
        let devices = [device("n1", "worker-1", created: 60, connected: true), device("n2", "worker-2", created: 660, address: "100.64.0.11")]
        func proven(online: Set<String> = []) -> StartAgain.Proven {
            StartAgain.proven(hub: hub, made: [:], builds: [first, second], listed: [.hetzner: []]) {
                StartAgain.isAlive($0, devices: devices, online: online)
            }
        }
        // Tailscale says that worker-1's machine holds its connection: it stays a row, with no type and no price, so
        // that its step asks the provider. worker-2's machine does not run: it is gone.
        let one = proven()
        #expect(one.servers.map(\.serverID) == ["101"] && one.gone == [second])
        #expect(one.servers.allSatisfy { $0.type == nil && $0.monthlyPrice == nil })
        // This Mac's own Tailscale shows worker-2's address online: it runs too.
        #expect(proven(online: ["100.64.0.11"]).servers.map(\.serverID) == ["101", "102"])
        // With no word of the machines, the list decides, as before.
        #expect(StartAgain.proven(hub: hub, made: [:], builds: [first, second], listed: [.hetzner: []]).gone == [first, second])
        // Only the build's own device counts: a machine of that name from another time says nothing.
        #expect(!StartAgain.isAlive(first, devices: [device("n9", "worker-1", created: 86_400, connected: true)], online: []))
        #expect(!StartAgain.isAlive(first, devices: [device("n1", "worker-1", created: 60)], online: ["100.64.0.2"]))
        let status = "{\"Self\":{\"TailscaleIPs\":[\"100.64.0.2\"]},\"Peer\":{\"a\":{\"Online\":true,\"TailscaleIPs\":[\"100.64.0.9\",\"fd7a:115c:a1e0::9\"]},"
            + "\"b\":{\"Online\":false,\"TailscaleIPs\":[\"100.64.0.11\"]}}}"
        #expect(StartAgain.onlineAddresses(in: status) == ["100.64.0.9", "fd7a:115c:a1e0::9"])
        #expect(StartAgain.onlineAddresses(in: nil).isEmpty)
    }

    // MARK: - The device of one build

    @Test func aDeviceIsABuildsOwnOnlyByItsNameItsTagAndTheBuildsTimes() {
        let record = build("worker-2", id: "102")     // began at 0, made at 8
        func found(_ devices: FleetDevice..., thisMac: Set<String> = [], name: String? = nil) -> String? {
            StartAgain.device(of: record, in: devices, thisMac: thisMac, thisMacName: name)?.id
        }
        #expect(found(device("n1", "worker-2", created: 60)) == "n1")
        #expect(found(device("n1", "Worker-2", created: 60)) == "n1")
        // Five minutes before the build's start, and the key's hour and five minutes after the provider's answer.
        #expect(found(device("n1", "worker-2", created: -300)) == "n1")
        #expect(found(device("n1", "worker-2", created: -301)) == nil)
        #expect(found(device("n1", "worker-2", created: 8 + 3900)) == "n1")     // as long as its key lives
        #expect(found(device("n1", "worker-2", created: 8 + 3901)) == nil)
        // Another name, no tag of the fleet, not authorized, another tailnet's, no time.
        #expect(found(device("n1", "worker-20", created: 60)) == nil)
        #expect(found(device("n1", "worker-2", created: 60, tags: ["tag:server"])) == nil)
        #expect(found(device("n1", "worker-2", created: 60, authorized: false)) == nil)
        #expect(found(device("n1", "worker-2", created: 60, external: true)) == nil)
        #expect(found(device("n1", "worker-2", created: nil)) == nil)
        // Two devices that both fit prove nothing; a later build's device of the same name is outside the times.
        #expect(found(device("n1", "worker-2", created: 60), device("n2", "worker-2", created: 90)) == nil)
        #expect(found(device("n1", "worker-2", created: 60), device("n2", "worker-2", created: 7200)) == "n1")
        // Never this Mac: not by one of its addresses, and not by its name.
        #expect(found(device("n1", "worker-2", created: 60, address: "100.64.0.2"), thisMac: ["100.64.0.2"]) == nil)
        #expect(found(device("n1", "worker-2", created: 60), name: "Worker-2") == nil)
        // A record with no answer of the provider has no server, and no device; one with no answer's time counts
        // from its start.
        #expect(StartAgain.device(of: build("worker-2", id: nil), in: [device("n1", "worker-2", created: 60)]) == nil)
        var early = build("worker-2", id: "102")
        early.madeAt = nil
        #expect(StartAgain.device(of: early, in: [device("n1", "worker-2", created: 3900)])?.id == "n1")
        #expect(StartAgain.device(of: early, in: [device("n1", "worker-2", created: 3901)]) == nil)
    }

    /// A build of another hub, or a first run's with no hub, can have made the machine: a device that fits its times
    /// too is not provably this build's, when this build's own server never came up.
    @Test func aDeviceThatFitsAnotherBuildOfThatNameProvesNothing() {
        let record = build("worker-2", id: "102")                                         // began at 0
        let later = build("worker-2", id: "902", hub: other.absoluteString, at: 600)      // another hub's, ten minutes later
        let firstRun = build("worker-2", id: nil, hub: nil, at: 900)                      // a first run's, with no answer
        let its = device("n2", "worker-2", created: 660)
        #expect(StartAgain.device(of: record, in: [its])?.id == "n2")
        #expect(StartAgain.device(of: record, in: [its], rivals: [later]) == nil)
        #expect(StartAgain.device(of: record, in: [its], rivals: [firstRun]) == nil)
        // A device from before the other build's times is this build's; a build of another name is no rival, and
        // the record itself is none.
        #expect(StartAgain.device(of: record, in: [device("n1", "worker-2", created: 60)], rivals: [later, firstRun])?.id == "n1")
        #expect(StartAgain.device(of: record, in: [its], rivals: [build("worker-3", id: "903", hub: nil, at: 600), record])?.id == "n2")
        // A try that left nothing at its provider made no machine: it is no rival, and it does not keep this build's
        // own machine in the network.
        var refused = build("worker-2", id: nil, hub: nil, at: 900)
        refused.callEnded(with: CloudError.refused(.hetzner, "limit reached"))
        #expect(refused.atProvider == .nothing && StartAgain.rivals(hub: hub, builds: [refused]).isEmpty)
        let afterARefusal = StartAgain.proven(hub: hub, made: [:], builds: [refused, record], listed: [.hetzner: [listed("102", "worker-2")]])
        #expect(afterARefusal.rivals.isEmpty && StartAgain.Plan(hub: hub, proven: afterARefusal, devices: [its]).machines == ["worker-2"])
        // The proof gives the rivals: every record that is not this hub's own and that can have made a machine.
        let proven = StartAgain.proven(hub: hub, made: [:], builds: [record, later, firstRun], listed: [.hetzner: [listed("102", "worker-2")]])
        #expect(proven.rivals == [later, firstRun] && StartAgain.rivals(hub: hub, builds: [record, later, firstRun]) == [later, firstRun])
        #expect(StartAgain.Plan(hub: hub, proven: proven, devices: [its]).machines.isEmpty)
    }

    @Test func thisMacsOwnAddressesComeFromItsOwnStatus() {
        let status = "{\"Self\":{\"TailscaleIPs\":[\"100.64.0.2\",\"fd7a:115c:a1e0::2\"]},\"Peer\":{\"k\":{\"TailscaleIPs\":[\"100.64.0.9\"]}}}"
        #expect(StartAgain.ownAddresses(in: status) == ["100.64.0.2", "fd7a:115c:a1e0::2"])
        #expect(StartAgain.ownAddresses(in: nil).isEmpty && StartAgain.ownAddresses(in: "no json").isEmpty)
    }

    // MARK: - The rows and the words

    private func twoServers() -> StartAgain.Proven {
        StartAgain.proven(hub: hub, made: [:], builds: [build("worker-1", id: "101", use: .hub, price: Decimal(string: "5.49")),
                                                         build("worker-2", id: "102", at: 600, price: Decimal(string: "5.49"))],
                          listed: [.hetzner: [listed("101", "worker-1"), listed("102", "worker-2")]])
    }

    @Test func thePageNamesEachThingThatGoesAndWhere() {
        let devices = [device("n1", "worker-1", created: 60), device("n2", "worker-2", created: 660), device("n3", "laptop", created: 60)]
        let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: devices)
        let price = StartAgain.Words.monthly(Decimal(string: "5.49")!, "EUR")
        #expect(plan.sections.map(\.title) == ["Deleted at Hetzner", "Removed from your Tailscale network", "Removed from the Founderizer app"])
        #expect(plan.sections[0].rows.map(\.title) == ["worker-1", "worker-2", "Their 2 firewalls and Founderizer's SSH key"])
        #expect(plan.sections[0].rows.map(\.detail) == ["Your fleet's server · CX23 · \(price)", "The manager's server · CX23 · \(price)",
                                                         "Founderizer made them for these servers."])
        #expect(plan.sections[0].rows.map(\.symbol) == ["server.rack", "server.rack", "shield"])
        #expect(plan.sections[1].rows.map(\.title) == ["The machines worker-1 and worker-2"])
        #expect(plan.sections[1].rows.map(\.detail) == ["This Mac and your other devices stay in the network."])
        #expect(plan.sections[2].rows.map(\.title) == ["What the app keeps of this fleet"])
        #expect(plan.sections[2].rows.map(\.detail) == ["Its address, its keys and its copies. Nothing else on this Mac changes."])
        #expect(plan.steps.map(\.title) == [
            "Delete worker-1 at Hetzner", "Delete worker-2 at Hetzner", "Delete their firewalls and SSH key at Hetzner",
            "Remove both machines from Tailscale", "Clear what the app keeps of this fleet"])
        #expect(plan.steps.allSatisfy { $0.state == .waiting })
    }

    @Test func aSectionWithNoRowDoesNotShowAndTheAppsAlwaysDoes() {
        // A fleet of an older build: no record proves a server, so the page has the app's part alone.
        let old = StartAgain.Plan(hub: hub, proven: StartAgain.Proven(), devices: [device("n1", "worker-1", created: 60)])
        #expect(old.sections.map(\.id) == ["app"])
        #expect(old.steps.map(\.title) == ["Clear what the app keeps of this fleet"])
        // The private network has no device of these builds any more: no row for it, and no step.
        let none = StartAgain.Plan(hub: hub, proven: twoServers(), devices: [])
        #expect(none.sections.map(\.id) == ["hetzner", "app"])
        #expect(!none.steps.contains { if case .machines = $0.kind { true } else { false } })
        // The read of the private network failed: the row names the machines of the records.
        let failed = StartAgain.Plan(hub: hub, proven: twoServers(), devices: nil)
        #expect(failed.machines == ["worker-1", "worker-2"])
        // A server that the provider no longer has leaves its machine in the row, and nothing at the provider.
        let gone = StartAgain.proven(hub: hub, made: [:], builds: [build("worker-1", id: "101", use: .hub)], listed: [.hetzner: []])
        let rest = StartAgain.Plan(hub: hub, proven: gone, devices: [device("n1", "worker-1", created: 60)])
        #expect(rest.sections.map(\.id) == ["tailscale", "app"])
        #expect(rest.sections[0].rows.map(\.title) == ["The machine worker-1"])
        #expect(rest.steps.map(\.title) == ["Remove the machine from Tailscale", "Clear what the app keeps of this fleet"])
    }

    @Test func theWordsFollowTheCountAndTheProvider() {
        typealias Words = StartAgain.Words
        #expect(Words.firewalls(1, at: .hetzner) == "Its firewall and Founderizer's SSH key")
        #expect(Words.firewalls(3, at: .vultr) == "Their 3 firewalls and Founderizer's SSH key")
        #expect(Words.madeFor(1, at: .digitalOcean) == "Founderizer made them for this server.")
        #expect(Words.madeFor(2, at: .digitalOcean) == "Founderizer made them for these servers.")
        // Akamai keeps no SSH key of its own, so its rows name none.
        #expect(Words.firewalls(1, at: .akamai) == "Its firewall" && Words.firewalls(2, at: .akamai) == "Their 2 firewalls")
        #expect(Words.madeFor(1, at: .akamai) == "Founderizer made it for this server.")
        #expect(Words.machines(["worker-1"]) == "The machine worker-1")
        #expect(Words.machines(["worker-1", "worker-2", "worker-3"]) == "The machines worker-1, worker-2 and worker-3")
        let one = StartAgain.Server(provider: .akamai, serverID: "5", name: "worker-4", use: .agent, type: "g6-standard-1")
        #expect(Words.detail(of: one) == "The manager's server · g6-standard-1")
        #expect(Words.detail(of: StartAgain.Server(provider: .hetzner, serverID: "5", name: "worker-1", use: .hub)) == "Your fleet's server")
        #expect(Words.title(of: .firewalls(.hetzner, servers: [one])) == "Delete its firewall and SSH key at Hetzner")
        #expect(Words.title(of: .firewalls(.akamai, servers: [one])) == "Delete its firewall at Akamai")
        #expect(Words.title(of: .firewalls(.akamai, servers: [one, one])) == "Delete their firewalls at Akamai")
        #expect(Words.title(of: .machines(1)) == "Remove the machine from Tailscale")
        #expect(Words.title(of: .machines(3)) == "Remove the 3 machines from Tailscale")
        #expect(StartAgain.Step.State.allCases.map(Words.word) == ["Waiting", "Now", "Done", "Failed"])
        #expect(StartAgain.Step.State.allCases.map { StartAgain.Step(id: 0, kind: .app, state: $0).symbol }
            == ["circle.dashed", "circle.dotted", "checkmark.circle.fill", "xmark.circle.fill"])
        // A token that the provider does not take is one short sentence; any other stop is the app's own sentence.
        #expect(Words.says(CloudError.tokenNotAccepted(.hetzner)) == "Hetzner refused the token.")
        #expect(Words.says(CloudError.readOnlyToken(.vultr)) == "Vultr refused the token.")
        #expect(Words.says(CloudError.unreachable(.hetzner)) == CloudError.unreachable(.hetzner).errorDescription)
        #expect(Words.says(FleetKeyError.fleetKeyEnded) == FleetKeyError.fleetKeyEnded.errorDescription)
        #expect(Words.says(CancellationError(), at: .hetzner) == CloudError.unreachable(.hetzner).errorDescription)
        // A provider's own words often end with no stop: another sentence can follow them all the same.
        #expect(Words.sentence("Hetzner refused: not found") == "Hetzner refused: not found.")
        #expect(Words.sentence("Hetzner refused the token.") == "Hetzner refused the token." && Words.sentence(" Why? ") == "Why?")
    }

    // MARK: - The run

    /// The calls of a run, as a test wants them: what each was asked for, and which one fails.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String] = []
        var fails: [String: Error] = [:]
        var devices: [FleetDevice] = []
        var thisMac: Set<String> = []
        var online: Set<String> = []
        /// The servers that the provider does not have for the token, by id, with its words.
        var notThere: [String: String] = [:]
        /// The call that ends the run's own task when it is made, as a page that closes does.
        var endsAt: String?
        /// The servers whose deletion a provider took from this app before, by provider and id.
        var before: Set<String> = []
        /// The servers whose deletion the provider takes before the call ends as `fails` says, by id (Hetzner's
        /// action that ends with an error, or a wait that is cut off).
        var takes: Set<String> = []
        var told: [[StartAgain.Step.State]] = []

        var all: [String] { lock.withLock { made } }
        private func note(_ call: String) throws {
            try lock.withLock { made.append(call); if let error = fails[call] { throw error } }
            if call == endsAt { withUnsafeCurrentTask { $0?.cancel() } }
        }

        var work: StartAgain.Work {
            StartAgain.Work(
                deleteServer: { [self] server, accepted in
                    if takes.contains(server.serverID) { accepted() }
                    try note("server \(server.provider.rawValue) \(server.serverID)")
                    if let words = notThere[server.serverID] { return .notThere(.refused(.hetzner, words)) }
                    accepted()
                    return .deleted
                },
                deleteFirewalls: { [self] provider, name, deleted in
                    try note("firewalls \(provider.rawValue) \(name) \(deleted.sorted().joined(separator: ","))")
                },
                deleteKey: { [self] in try note("key \($0.rawValue)") },
                devices: { [self] in try note("devices"); return devices },
                deleteDevice: { [self] in try note("device \($0)") },
                thisMac: { [self] in (thisMac, nil) },
                online: { [self] in online },
                noteDeleted: { [self] provider, id in lock.withLock { _ = before.insert("\(provider.rawValue)|\(id)") } },
                forgetDeleted: { [self] provider, id in lock.withLock { _ = before.remove("\(provider.rawValue)|\(id)") } },
                deletedBefore: { [self] provider, id in lock.withLock { before.contains("\(provider.rawValue)|\(id)") } },
                clearApp: { [self] in try? note("app hubServerDeleted=\($0)") })
        }

        func tell(_ steps: [StartAgain.Step]) { lock.withLock { told.append(steps.map(\.state)) } }
    }

    @Test func aRunGoesOneStepAtATimeInThePagesOrder() async {
        let calls = Calls()
        calls.devices = [device("n1", "worker-1", created: 60), device("n2", "worker-2", created: 660), device("n3", "laptop", created: 60)]
        let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: calls.devices)
        let steps = await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work) { calls.tell($0) }
        #expect(calls.all == [
            "server hetzner 101", "server hetzner 102", "firewalls hetzner worker-1 101,102", "firewalls hetzner worker-2 101,102",
            "key hetzner", "devices", "device n1", "device n2", "app hubServerDeleted=true"])
        #expect(steps.allSatisfy { $0.state == .done && $0.says == nil && $0.failedTitle == nil })
        // One step is "now" at a time, and every step before it is done.
        for states in calls.told {
            #expect(states.filter { $0 == .now }.count <= 1)
            if let now = states.firstIndex(of: .now) { #expect(states[..<now].allSatisfy { $0 == .done }) }
        }
        #expect(calls.told.last == Array(repeating: .done, count: 5))
    }

    @Test func aStepThatFailsStopsTheRunAndTryAgainGoesOnThere() async {
        let calls = Calls()
        calls.devices = [device("n1", "worker-1", created: 60), device("n2", "worker-2", created: 660)]
        calls.fails["server hetzner 102"] = CloudError.tokenNotAccepted(.hetzner)
        let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: calls.devices)
        let stopped = await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work)
        // Nothing after the failed step ran: no firewall, no key, no device, and never the app's own step.
        #expect(calls.all == ["server hetzner 101", "server hetzner 102"])
        #expect(stopped.map(\.state) == [.done, .failed, .waiting, .waiting, .waiting])
        #expect(stopped[1].failedTitle == "worker-2 is not deleted")
        #expect(stopped[1].says == "Hetzner refused the token. The server is still there and still costs money.")
        // "Try again" goes on at the step that failed, and asks for nothing that is done.
        calls.fails = [:]
        let done = await StartAgain.run(stopped, builds: plan.builds, work: calls.work)
        #expect(calls.all.dropFirst(2) == [
            "server hetzner 102", "firewalls hetzner worker-1 101,102", "firewalls hetzner worker-2 101,102", "key hetzner",
            "devices", "device n1", "device n2", "app hubServerDeleted=true"])
        #expect(done.allSatisfy { $0.state == .done && $0.says == nil && $0.failedTitle == nil })
    }

    @Test func eachOtherStepThatFailsHasItsOwnTitleAndLeavesTheAppsPart() async {
        func stop(_ call: String, _ error: Error) async -> (step: StartAgain.Step?, calls: [String]) {
            let calls = Calls()
            calls.devices = [device("n1", "worker-1", created: 60), device("n2", "worker-2", created: 660)]
            calls.fails[call] = error
            let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: calls.devices)
            let steps = await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work)
            return (steps.first { $0.state == .failed }, calls.all)
        }
        let inUse = CloudError.refused(.hetzner, "firewall still applied")
        let firewalls = await stop("firewalls hetzner worker-1 101,102", inUse)
        #expect(firewalls.step?.failedTitle == "The firewalls are not deleted")
        #expect(firewalls.step?.says == "Hetzner refused: firewall still applied")
        // The other server's firewall and the key are asked all the same: one firewall that another server holds does
        // not keep them at the provider. The step fails, and nothing after it runs.
        #expect(firewalls.calls.suffix(3) == ["firewalls hetzner worker-1 101,102", "firewalls hetzner worker-2 101,102", "key hetzner"])
        let key = await stop("key hetzner", CloudError.unreachable(.hetzner))
        #expect(key.step?.failedTitle == "The SSH key is not deleted")
        #expect(key.step?.says == CloudError.unreachable(.hetzner).errorDescription)
        let list = await stop("devices", FleetKeyError.fleetKeyEnded)
        #expect(list.step?.failedTitle == "worker-1 is not removed" && list.step?.says == FleetKeyError.fleetKeyEnded.errorDescription)
        let machine = await stop("device n2", FleetKeyError.unreachable)
        #expect(machine.step?.failedTitle == "worker-2 is not removed")
        #expect(machine.calls.suffix(3) == ["devices", "device n1", "device n2"])
        for stopped in [firewalls, key, list, machine] { #expect(!stopped.calls.contains { $0.hasPrefix("app") }) }
    }

    @Test func aRunRemovesOnlyTheDevicesOfItsBuildsAndNeverThisMac() async {
        let calls = Calls()
        // A device of the same name from another time, a device with no tag, the hub's own name on this Mac's address.
        calls.devices = [device("n1", "worker-1", created: 60, address: "100.64.0.2"), device("n2", "worker-2", created: 86_400),
                         device("n3", "worker-2", created: 660, tags: []), device("n4", "worker-3", created: 60)]
        calls.thisMac = ["100.64.0.2"]
        let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: nil)
        _ = await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work)
        #expect(!calls.all.contains { $0.hasPrefix("device ") })
        #expect(calls.all.last == "app hubServerDeleted=true")
    }

    /// **A 404 is not a deletion while the server's machine runs.** With a token of another project or account the
    /// provider has no server of that id, and the run would end with the servers still there, off the private network
    /// and still paid for, and with this Mac's key for a live hub gone.
    @Test func aServerThatTheProviderDoesNotHaveAndThatStillRunsIsNotDeleted() async {
        let calls = Calls()
        calls.devices = [device("n1", "worker-1", created: 60, connected: true), device("n2", "worker-2", created: 660, address: "100.64.0.11")]
        calls.notThere = ["101": "server with ID '101' not found", "102": "server with ID '102' not found"]
        let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: calls.devices)
        let stopped = await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work)
        // The first server's machine holds its connection: the step fails with the provider's own answer, as one
        // sentence, and nothing after it runs.
        #expect(calls.all == ["server hetzner 101", "devices"])
        #expect(stopped.map(\.state) == [.failed, .waiting, .waiting, .waiting, .waiting])
        #expect(stopped[0].failedTitle == "worker-1 is not deleted")
        #expect(stopped[0].says == "Hetzner refused: server with ID '101' not found. The server is still there and still costs money.")
        // A machine that this Mac's own Tailscale shows online is one that runs too.
        let second = Calls()
        second.devices = [device("n2", "worker-2", created: 660, address: "100.64.0.11")]
        second.online = ["100.64.0.11"]
        second.notThere = ["102": "not found"]
        let later = await StartAgain.run(plan.steps, builds: plan.builds, work: second.work)
        #expect(later.map(\.state) == [.done, .failed, .waiting, .waiting, .waiting] && later[1].failedTitle == "worker-2 is not deleted")
        // A server that the provider does not have and whose machine does not run is deleted already: the run goes on.
        let gone = Calls()
        gone.devices = [device("n1", "worker-1", created: 60), device("n2", "worker-2", created: 660, address: "100.64.0.11")]
        gone.notThere = ["101": "not found", "102": "not found"]
        let done = await StartAgain.run(plan.steps, builds: plan.builds, work: gone.work)
        #expect(done.allSatisfy { $0.state == .done && !$0.deleted })
        // **This run deleted nothing at the provider**: no firewall and no key is asked for, and this Mac's key for
        // the hub stays. The machines of the servers that are gone go.
        #expect(gone.all == ["server hetzner 101", "devices", "server hetzner 102", "devices", "devices", "device n1", "device n2",
                             "app hubServerDeleted=false"])
        // A read of the private network that fails at that moment says nothing of the machine: the 404 stands, and
        // the machines' own step then stops the run before the app's part.
        let blind = Calls()
        blind.notThere = ["101": "not found", "102": "not found"]
        blind.fails["devices"] = FleetKeyError.unreachable
        let stuck = await StartAgain.run(plan.steps, builds: plan.builds, work: blind.work)
        #expect(stuck.map(\.state) == [.done, .done, .done, .failed, .waiting] && stuck[3].failedTitle == "worker-1 is not removed")
        #expect(!blind.all.contains { $0.hasPrefix("app") || $0.hasPrefix("device ") || $0.hasPrefix("key") })
    }

    /// **The machines' step removes no machine that runs, unless the provider took its server's deletion.** A server
    /// that a list did not have (the read of the private network had failed, or the machine came back) is there while
    /// its machine runs: the run stops with its name, and the app's part does not run.
    @Test func aMachineThatRunsIsNotRemovedUnlessTheProviderTookItsServersDeletion() async {
        // The list had no server of this hub: both are "gone", and the page names their machines.
        let gone = StartAgain.proven(hub: hub, made: [:], builds: [build("worker-1", id: "101", use: .hub), build("worker-2", id: "102", at: 600)],
                                     listed: [.hetzner: []])
        let plan = StartAgain.Plan(hub: hub, proven: gone, devices: nil)
        #expect(plan.steps.map(\.title) == ["Remove both machines from Tailscale", "Clear what the app keeps of this fleet"])
        let calls = Calls()
        calls.devices = [device("n1", "worker-1", created: 60), device("n2", "worker-2", created: 660, address: "100.64.0.11", connected: true)]
        let stopped = await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work)
        // worker-1's machine is off: it goes. worker-2's machine holds its connection: its server is there.
        #expect(calls.all == ["devices", "device n1"])
        #expect(stopped.map(\.state) == [.failed, .waiting])
        #expect(stopped[0].failedTitle == "worker-2 is not deleted" && stopped[0].says == "The server is still there and still costs money.")
        // The same for a machine that this Mac's own Tailscale shows online.
        let seen = Calls()
        seen.devices = [device("n2", "worker-2", created: 660, address: "100.64.0.11")]
        seen.online = ["100.64.0.11"]
        let again = await StartAgain.run(plan.steps, builds: plan.builds, work: seen.work)
        #expect(again[0].failedTitle == "worker-2 is not deleted" && !seen.all.contains { $0.hasPrefix("device ") || $0.hasPrefix("app") })
        // A server whose deletion a provider took from this app before is gone: Tailscale shows its machine
        // connected a while longer, and the machine goes.
        let echo = Calls()
        echo.devices = calls.devices
        echo.before = ["hetzner|102"]
        let done = await StartAgain.run(plan.steps, builds: plan.builds, work: echo.work)
        #expect(done.allSatisfy { $0.state == .done } && echo.all == ["devices", "device n1", "device n2", "app hubServerDeleted=false"])
        // And in the run that deleted the server itself, its machine goes while Tailscale still shows it connected.
        let own = Calls()
        own.devices = [device("n1", "worker-1", created: 60, connected: true), device("n2", "worker-2", created: 660, address: "100.64.0.11", connected: true)]
        let whole = StartAgain.Plan(hub: hub, proven: twoServers(), devices: own.devices)
        let ended = await StartAgain.run(whole.steps, builds: whole.builds, work: own.work)
        #expect(ended.allSatisfy { $0.state == .done } && own.all.suffix(3) == ["device n1", "device n2", "app hubServerDeleted=true"])
        // A 404 for a server that this app deleted before is no server of another project: its step is done.
        let late = Calls()
        late.devices = own.devices
        late.notThere = ["101": "not found"]
        late.before = ["hetzner|101"]
        let passed = await StartAgain.run(whole.steps, builds: whole.builds, work: late.work)
        #expect(passed.allSatisfy { $0.state == .done } && passed[0].deleted == false && passed[1].deleted)
        // Only the second server's deletion was this run's: only its firewall and the key are asked for.
        #expect(late.all.filter { $0.hasPrefix("firewalls") || $0.hasPrefix("key") } == ["firewalls hetzner worker-2 102", "key hetzner"])
        #expect(late.all.last == "app hubServerDeleted=false")
    }

    /// **A deletion that the provider took, and then said did not go, is no deletion that this app made.** The
    /// sequence: Hetzner takes the DELETE and its action ends with an error, so the server is there; the token is
    /// then another project's; "Try again". The 404 must not read as the server's deletion, and its machine, which
    /// runs, must stay in the private network.
    @Test func aDeletionThatTheProviderTookAndThenRefusedIsNotOneThatThisAppMade() async {
        let devices = [device("n1", "worker-1", created: 60, connected: true), device("n2", "worker-2", created: 660, address: "100.64.0.11")]
        let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: devices)
        // 1. The provider takes the deletion of worker-1, and then says that it did not go.
        let calls = Calls()
        calls.devices = devices
        calls.takes = ["101"]
        calls.fails["server hetzner 101"] = CloudError.refused(.hetzner, "the server is locked")
        let stopped = await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work)
        #expect(stopped[0].state == .failed && !stopped[0].deleted)
        #expect(stopped[0].says == "Hetzner refused: the server is locked. The server is still there and still costs money.")
        // It was noted at the moment the provider took it, and the note is gone again.
        #expect(calls.before.isEmpty)
        // 2. The token is another project's now: the provider has no such server. "Try again": the machine runs, so
        //    the step fails, and nothing of the server is removed.
        calls.fails = [:]
        calls.takes = []
        calls.notThere = ["101": "server with ID '101' not found"]
        let again = await StartAgain.run(stopped, builds: plan.builds, work: calls.work)
        #expect(again[0].state == .failed && again[0].failedTitle == "worker-1 is not deleted")
        #expect(again[0].says == "Hetzner refused: server with ID '101' not found. The server is still there and still costs money.")
        #expect(!calls.all.contains { $0.hasPrefix("device ") || $0.hasPrefix("app") })
        // 3. The page opens again, and the list of that other project has no server of this hub: the machines' step
        //    finds worker-1's machine running, and stops before it removes one and before the app's part.
        let lacks = StartAgain.proven(hub: hub, made: [:], builds: plan.servers.compactMap(\.build), listed: [.hetzner: []])
        let reopened = StartAgain.Plan(hub: hub, proven: lacks, devices: nil)
        let stuck = await StartAgain.run(reopened.steps, builds: reopened.builds, work: calls.work)
        #expect(stuck[0].state == .failed && stuck[0].failedTitle == "worker-1 is not deleted")
        #expect(!calls.all.contains { $0.hasPrefix("device ") || $0.hasPrefix("app") })

        // A wait that the page's close cut off, and a call that got no answer, say nothing of the server: the note of
        // the deletion that the provider took stays, and its machine then goes as the machine of a deleted server.
        for silent in [CancellationError() as Error, CloudError.unreachable(.hetzner)] {
            let cut = Calls()
            cut.devices = devices
            cut.takes = ["101"]
            cut.fails["server hetzner 101"] = silent
            _ = await StartAgain.run(plan.steps, builds: plan.builds, work: cut.work)
            #expect(cut.before == ["hetzner|101"], "\(silent)")
            cut.fails = [:]
            cut.takes = []
            cut.notThere = ["101": "not found"]
            let done = await StartAgain.run(plan.steps, builds: plan.builds, work: cut.work)
            #expect(done.allSatisfy { $0.state == .done } && cut.all.contains("device n1"), "\(silent)")
        }
        // An error of a call that the provider did not take leaves an earlier note as it is.
        let earlier = Calls()
        earlier.before = ["hetzner|101"]
        earlier.fails["server hetzner 101"] = CloudError.tokenNotAccepted(.hetzner)
        _ = await StartAgain.run(plan.steps, builds: plan.builds, work: earlier.work)
        #expect(earlier.before == ["hetzner|101"])
        // Which errors are the provider's own.
        #expect(StartAgain.isProvidersOwn(CloudError.refused(.hetzner, "x")) && StartAgain.isProvidersOwn(CloudError.notUnderstood(.hetzner)))
        #expect(!StartAgain.isProvidersOwn(CloudError.unreachable(.hetzner)) && !StartAgain.isProvidersOwn(CancellationError()))
    }

    /// The page names the machines that go. A device that the page did not name is never removed, also when it fits
    /// the rule by the time of the run (two devices fitted at the read, and one of them went meanwhile).
    @Test func aRunRemovesNoDeviceThatThePageDidNotName() async {
        let calls = Calls()
        let read = [device("n1", "worker-1", created: 60), device("n2", "worker-2", created: 660), device("n3", "worker-2", created: 700)]
        let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: read)
        #expect(plan.machines == ["worker-1"] && plan.builds.map(\.name) == ["worker-1"])
        #expect(plan.steps.map(\.title).contains("Remove the machine from Tailscale"))
        calls.devices = [read[0], read[1]]
        _ = await StartAgain.run(plan.steps, builds: plan.builds, rivals: plan.rivals, work: calls.work)
        #expect(calls.all.filter { $0.hasPrefix("device ") } == ["device n1"])
    }

    /// A page that closes in the middle of a run ends the run's task: the step that runs ends, and no further step
    /// starts, least of all the app's own.
    @Test func aRunWhoseTaskEndsInAStepStartsNoFurtherStep() async {
        for end in ["server hetzner 101", "key hetzner", "device n2"] {
            let calls = Calls()
            calls.devices = [device("n1", "worker-1", created: 60), device("n2", "worker-2", created: 660)]
            calls.endsAt = end
            let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: calls.devices)
            let steps = await Task { await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work) }.value
            #expect(calls.all.last == end, "\(end): \(calls.all)")
            #expect(!calls.all.contains { $0.hasPrefix("app") }, "\(end)")
            #expect(steps.last?.state == .waiting && !steps.contains { $0.state == .now }, "\(end)")
        }
    }

    /// The page can close in the moment in which a step is said to run (`tell`): that step is then not asked for.
    /// For the app's own step this is the difference between a fleet that stays and a fleet that is forgotten.
    @Test func aRunWhoseTaskEndsWhileAStepIsSaidDoesNotAskForThatStep() async {
        for last in [0, 4] {
            let calls = Calls()
            calls.devices = [device("n1", "worker-1", created: 60), device("n2", "worker-2", created: 660)]
            let plan = StartAgain.Plan(hub: hub, proven: twoServers(), devices: calls.devices)
            let steps = await Task {
                await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work) { steps in
                    if steps[last].state == .now { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }.value
            #expect(steps[last].state == .waiting && !steps.contains { $0.state == .now }, "step \(last)")
            #expect(!calls.all.contains { $0.hasPrefix("app") }, "step \(last)")
            #expect(calls.all.isEmpty == (last == 0), "step \(last): \(calls.all)")
        }
    }

    @Test func thisMacsKeyForTheHubGoesOnlyWhenTheRunDeletedTheHubsOwnServer() async {
        // Only an agent's server is proven: the hub stays alive.
        let agents = StartAgain.proven(hub: hub, made: ["worker-3": "103"], builds: [build("worker-2", id: "102")],
                                       listed: [.hetzner: [listed("102", "worker-2"), listed("103", "worker-3")]])
        let calls = Calls()
        let plan = StartAgain.Plan(hub: hub, proven: agents, devices: [])
        _ = await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work)
        #expect(calls.all == ["server hetzner 102", "server hetzner 103", "firewalls hetzner worker-2 102,103",
                              "firewalls hetzner worker-3 102,103", "key hetzner", "app hubServerDeleted=false"])
        // No server at all (a fleet of an older build): the app's part alone, and the hub's key stays.
        let none = Calls()
        let empty = StartAgain.Plan(hub: hub, proven: StartAgain.Proven(), devices: [])
        _ = await StartAgain.run(empty.steps, builds: [], work: none.work)
        #expect(none.all == ["app hubServerDeleted=false"])
    }

    @Test func akamaiHasNoKeyToDeleteAndARunThatWasEndedStartsNoStep() async {
        let linode = StartAgain.proven(hub: hub, made: [:], builds: [build("worker-1", id: "101", use: .hub, provider: .akamai)],
                                       listed: [.akamai: [listed("101", "worker-1", type: "g6-standard-1")]])
        let calls = Calls()
        let plan = StartAgain.Plan(hub: hub, proven: linode, devices: [])
        _ = await StartAgain.run(plan.steps, builds: plan.builds, work: calls.work)
        #expect(calls.all == ["server akamai 101", "firewalls akamai worker-1 101", "app hubServerDeleted=true"])
        // The page closed: the task of the run is ended, and nothing is asked for.
        let ended = Calls()
        let task = Task { () -> [StartAgain.Step] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await StartAgain.run(plan.steps, builds: plan.builds, work: ended.work)
        }
        let steps = await task.value
        #expect(ended.all.isEmpty && steps.allSatisfy { $0.state == .waiting })
    }

    // MARK: - A first run's server, and the hub that it becomes

    /// **The address under which a first run's server is kept is the address that its claim then gives the app.** The
    /// build knows the server's address on the private network; the claim's step gives the same address, and both
    /// write the hub's address through one form (`hubText`). So the record of the first run's own server names the
    /// hub that the app then has, and the proof finds it.
    @Test func aFirstRunsServerIsKeptUnderTheAddressThatItsClaimGives() throws {
        let server = "100.64.0.9"
        // What the claim's step gives the app (`MachineInstallModel.claimedAddress`, which reads the step's lines with
        // `claimedHub`), as the store then keeps it (`FleetStore.connect`, `HubClient.address`).
        let lines = ["==> the hub is up", "fleet-claim: this hub answers at 100.64.0.9, port 8765", "public address 203.0.113.5"]
        let text = try #require(StartAgain.claimedHub(in: lines))
        let claimed = try HubClient.address(text)
        #expect(text == "http://100.64.0.9:8765" && claimed.absoluteString == "http://100.64.0.9:8765/")
        // Lines with no address of the private network give none; a public address is never the hub's.
        #expect(StartAgain.claimedHub(in: ["public address 203.0.113.5", "no address"]) == nil)
        // What the build keeps the server under, before any hub exists.
        let future = try #require(StartAgain.hubAddress(onNetwork: server))
        #expect(future == claimed)
        // A claim line that the owner pastes gives the same hub.
        #expect(try ClaimCode.hubAddress(in: server).map(HubClient.address) == claimed)
        // So the first run's records are this hub's own, and nothing of another server's.
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        MadeServers.note("worker-1", id: "101", hub: future, in: defaults)
        var record = BuildRecord(provider: .hetzner, use: .hub, hub: nil, name: "worker-1", launch: "now", at: time(0))
        record.made(id: "101", type: "cx23", at: time(8))
        record.joined(at: time(60), hub: future.absoluteString)
        let proven = StartAgain.proven(hub: claimed, made: MadeServers.kept(hub: claimed, in: defaults), builds: [record],
                                       listed: [.hetzner: [listed("101", "worker-1"), listed("102", "worker-2")]])
        #expect(proven.servers.map(\.serverID) == ["101"] && proven.servers.first?.use == .hub)
        // What is no address of the private network names no hub.
        #expect(StartAgain.hubAddress(onNetwork: "203.0.113.5") == nil && StartAgain.hubAddress(onNetwork: "worker-1") == nil)
        // The fleet's own VPS is in the made servers now, and it is never a server for agents to use again: Add
        // server's list knows it by its build's record, also at a provider with no label.
        let agent = build("worker-2", id: "102"), elsewhere = build("worker-1", id: "901", use: .hub, hub: other.absoluteString)
        #expect(MadeServers.hubsOwn(hub: claimed, builds: [record, agent, elsewhere]) == ["101"])
    }

    @Test func thisMacsKeyForAHubGoesWithTheKeyThatWaits() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("start-again-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = OwnerMacKey.folder(home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["100.64.0.1_8765", "100.64.0.1_8765.pending", "100.64.0.10_8765"] {
            try Data("a-key-of-a-test".utf8).write(to: folder.appendingPathComponent(name))
        }
        StartAgain.forgetMacKey(hub: hub, home: home, lookup: { _ in nil })
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["100.64.0.10_8765"])
        // A hub that is called by a name that no longer answers has no file that this can find.
        StartAgain.forgetMacKey(hub: URL(string: "http://hub-1.example.ts.net:8765/")!, home: home, lookup: { _ in nil })
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["100.64.0.10_8765"])
    }

    // MARK: - When the link shows

    @Test func theLinkShowsOnlyForAManagerThatWaitsForItsFirstServer() {
        func offers(gives: Bool = true, runs: Bool = false, asks: Bool = false, others: Int = 0, used: Int = 0) -> Bool {
            StartAgain.offers(givesManagerItsServer: gives, runs: runs, asksHub: asks, otherAgents: others, serversWithAnAgent: used)
        }
        #expect(offers())
        #expect(!offers(gives: false) && !offers(runs: true) && !offers(asks: true) && !offers(others: 1) && !offers(used: 1))
    }

    // MARK: - What the app keeps of one hub

    private func scratch() -> (defaults: UserDefaults, name: String) {
        let name = "start-again-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Every value that the app keeps by a hub's address, written for this hub and for one whose address only starts
    /// the same, with the values that are never cleared.
    private func fill(_ defaults: UserDefaults) {
        let mine = hub.absoluteString, theirs = other.absoluteString
        defaults.set(mine, forKey: "hubAddress")
        defaults.set([mine, theirs], forKey: "hubsAnswered")
        MadeServers.note("worker-2", id: "102", hub: hub, in: defaults)
        MadeServers.note("worker-2", id: "902", hub: other, in: defaults)
        InstallEnds.note("worker-2", address: "100.64.0.9", hub: hub, in: defaults)
        InstallEnds.note("worker-2", address: "100.64.0.99", hub: other, in: defaults)
        for key in ["unplacedAgents", "addingAgents"] { defaults.set(["\(mine)|db1|manager", "\(theirs)|db9|manager"], forKey: key) }
        for key in ["serversJoinedFor", "hubTCPDone", "centralVaultPins"] {
            defaults.set(["\(mine)|db1|manager": "worker-2", "\(theirs)|db9|manager": "worker-9"], forKey: key)
        }
        for key in ["ownerAccessInPlace", "serverHardening", "serverMemoryLimit", ServerLibraries.keptKey,
                    ServerRestart.keptKey] {
            defaults.set(["\(mine) worker-2 100.64.0.9": "aa", "\(theirs) worker-9 100.64.0.99": "bb"], forKey: key)
        }
        for key in ["pinnedAgents", "fleetIdsByHub", "lastPages"] { defaults.set([mine: "one", theirs: "two"], forKey: key) }
        for key in ["machineChecklists", "machineInstallTargets"] {
            let table = ["\(mine)|worker-2": ["host": "100.64.0.9", "readAt": 784_123_456.5],
                         "\(theirs)|worker-9": ["host": "100.64.0.99", "readAt": 784_123_457.25, "port": 22]]
            defaults.set(try! JSONSerialization.data(withJSONObject: table), forKey: key)
        }
        let targets = ["100.64.0.1_8765": ["host": "100.64.0.1"], "100.64.0.10_8765": ["host": "100.64.0.10"]]
        defaults.set(try! JSONSerialization.data(withJSONObject: targets), forKey: "ownerKeyHubServer")
        defaults.set(["context": "\(mine)\ndb1", "seen": ["manager": 3]], forKey: "chatRepliesSeen")
        ConnectGate.keep(.on, for: hub, in: defaults)
        ConnectGate.keep(.off, for: other, in: defaults)
        for hub in [mine, theirs] {
            defaults.set(["worker-2": "key"], forKey: "doorLoginKeys|\(hub)")
            defaults.set(["worker-2": Date()], forKey: "doorRefusals|\(hub)")
            defaults.set(Data("{}".utf8), forKey: "doorHosts|\(hub)|db1")
            defaults.set(["worker-2": ["app": "held"]], forKey: "doorHoldings|\(hub)|db1")
            defaults.set("bws://00000000-0000-4000-8000-000000000001", forKey: "doorKeyReference|\(hub)|db1|example-app")
        }
        // Never cleared: the app's own settings, the backup's, the first run's, and the installation id.
        for key in StartAgainTests.never { defaults.set("kept", forKey: key) }
    }

    private static let never = ["installationID", "copyAutomatic", "copyEvery", "copyFolder", "copyKeptAt", "tailscale.policy.place",
                                "firstRunManagerName", "firstRunServersStep", "viewZoom", "sidebarWidth", "reportEmail",
                                "notifyNeedsYou", "managerDraft", "signedGrantClock"]

    private func json(_ key: String, _ defaults: UserDefaults) -> [String: Any] {
        defaults.data(forKey: key).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    @Test func onlyThisHubsKeptValuesAreClearedAndNeverTheOthers() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        fill(defaults)
        let mine = hub.absoluteString, theirs = other.absoluteString
        StartAgain.forgetKept(hub: hub, hubServerDeleted: true, in: defaults)

        #expect(defaults.string(forKey: "hubAddress") == nil)
        #expect(defaults.stringArray(forKey: "hubsAnswered") == [theirs])
        #expect(MadeServers.kept(hub: hub, in: defaults).isEmpty && MadeServers.kept(hub: other, in: defaults) == ["worker-2": "902"])
        #expect(InstallEnds.ended(hub: hub, in: defaults).isEmpty && InstallEnds.ended(hub: other, in: defaults) == ["worker-2": "100.64.0.99"])
        for key in ["unplacedAgents", "addingAgents"] { #expect(defaults.stringArray(forKey: key) == ["\(theirs)|db9|manager"], "\(key)") }
        for key in ["serversJoinedFor", "hubTCPDone", "centralVaultPins"] {
            #expect(defaults.dictionary(forKey: key) as? [String: String] == ["\(theirs)|db9|manager": "worker-9"], "\(key)")
        }
        for key in ["ownerAccessInPlace", "serverHardening", "serverMemoryLimit", ServerLibraries.keptKey,
                    ServerRestart.keptKey] {
            #expect(defaults.dictionary(forKey: key) as? [String: String] == ["\(theirs) worker-9 100.64.0.99": "bb"], "\(key)")
        }
        for key in ["pinnedAgents", "fleetIdsByHub", "lastPages"] { #expect(defaults.dictionary(forKey: key) as? [String: String] == [theirs: "two"], "\(key)") }
        for key in ["machineChecklists", "machineInstallTargets"] {
            // The other hub's entry is whole, with its numbers as they were.
            let kept = json(key, defaults)
            #expect(Array(kept.keys) == ["\(theirs)|worker-9"], "\(key)")
            let entry = kept["\(theirs)|worker-9"] as? [String: Any]
            #expect(entry?["host"] as? String == "100.64.0.99" && entry?["readAt"] as? Double == 784_123_457.25 && entry?["port"] as? Int == 22, "\(key)")
        }
        #expect(Array(json("ownerKeyHubServer", defaults).keys) == ["100.64.0.10_8765"])
        #expect(defaults.dictionary(forKey: "chatRepliesSeen") == nil)
        #expect(ConnectGate.kept(hub, in: defaults) == nil && ConnectGate.kept(other, in: defaults) == .off)
        for start in ["doorLoginKeys|", "doorRefusals|"] {
            #expect(defaults.object(forKey: "\(start)\(mine)") == nil && defaults.object(forKey: "\(start)\(theirs)") != nil, "\(start)")
        }
        for (start, end) in [("doorHosts|", "|db1"), ("doorHoldings|", "|db1"), ("doorKeyReference|", "|db1|example-app")] {
            #expect(defaults.object(forKey: "\(start)\(mine)\(end)") == nil, "\(start)")
            #expect(defaults.object(forKey: "\(start)\(theirs)\(end)") != nil, "\(start)")
        }
        for key in Self.never { #expect(defaults.string(forKey: key) == "kept", "\(key)") }
    }

    @Test func aHubThatStaysAliveKeepsWhatALaterConnectNeeds() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        fill(defaults)
        let mine = hub.absoluteString
        StartAgain.forgetKept(hub: hub, hubServerDeleted: false, in: defaults)
        // The vault's pins, the fleet id that this Mac made, the target of this Mac's key and the App keys' references.
        #expect((defaults.dictionary(forKey: "centralVaultPins") as? [String: String])?["\(mine)|db1|manager"] == "worker-2")
        #expect((defaults.dictionary(forKey: "fleetIdsByHub") as? [String: String])?[mine] == "one")
        #expect(json("ownerKeyHubServer", defaults).keys.sorted() == ["100.64.0.10_8765", "100.64.0.1_8765"])
        #expect(defaults.string(forKey: "doorKeyReference|\(mine)|db1|example-app") != nil)
        // All else of the hub goes as in every run.
        #expect(defaults.string(forKey: "hubAddress") == nil && MadeServers.kept(hub: hub, in: defaults).isEmpty)
        #expect((defaults.dictionary(forKey: "pinnedAgents") as? [String: String])?[mine] == nil)
        #expect((defaults.dictionary(forKey: "lastPages") as? [String: String])?[mine] == nil)
        #expect(defaults.object(forKey: "doorHosts|\(mine)|db1") == nil)
    }

    @Test func aKeptAddressOfAnotherHubStays() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(other.absoluteString, forKey: "hubAddress")
        defaults.set(["context": "\(other.absoluteString)\ndb9", "seen": ["manager": 1]], forKey: "chatRepliesSeen")
        StartAgain.forgetKept(hub: hub, hubServerDeleted: true, in: defaults)
        #expect(defaults.string(forKey: "hubAddress") == other.absoluteString)
        #expect(defaults.dictionary(forKey: "chatRepliesSeen") != nil)
    }

    /// The bug that this catches: Forget this fleet leaves the blocks of a hub's older tasks or rows (owner API 1.254,
    /// 1.258) on the disk, where a later connect to another fleet of the same address would read them.
    @Test func theKeptReadingsOfAHubAreItsFourFilesAndItsBlocksOfOlderTasksAndRows() {
        let folder = URL(fileURLWithPath: "/tmp/example/Founderizer")
        #expect(StartAgain.readingFiles(of: hub, in: folder).map(\.lastPathComponent) == [
            "state-100.64.0.1-8765.json", "health-100.64.0.1-8765.json", "releases-100.64.0.1-8765.json", "app-update-100.64.0.1-8765.json",
            "older-100.64.0.1-8765", "rows-needs-100.64.0.1-8765", "rows-reports-100.64.0.1-8765",
            "rows-messages-100.64.0.1-8765"])
        #expect(Set(StartAgain.readingFiles(of: hub, in: folder)).isDisjoint(with: StartAgain.readingFiles(of: other, in: folder)))
    }

    // MARK: - A hub that a run left alive

    @Test func aHubThatARunLeftIsPassedOverUntilTheOwnerConnectsToIt() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!StartAgain.LeftHubs.holds(hub, in: defaults))
        StartAgain.LeftHubs.note(URL(string: "http://Hub-1.example.ts.net:8765/")!, also: [hub], in: defaults)
        // The first run asks each device at its address with no last slash: the same hub.
        #expect(StartAgain.LeftHubs.holds(URL(string: "http://100.64.0.1:8765")!, in: defaults))
        #expect(StartAgain.LeftHubs.holds(URL(string: "http://hub-1.example.ts.net:8765")!, in: defaults))
        #expect(!StartAgain.LeftHubs.holds(other, in: defaults))
        #expect(!StartAgain.LeftHubs.holds(URL(string: "http://100.64.0.1:8766")!, in: defaults))
        StartAgain.LeftHubs.forget(hub, in: defaults)
        #expect(!StartAgain.LeftHubs.holds(hub, in: defaults))
        #expect(StartAgain.LeftHubs.holds(URL(string: "http://hub-1.example.ts.net:8765/")!, in: defaults))
    }

    /// The first run's search asks each device at its address. A hub that was kept by a name of the private network
    /// is passed over by the device that has that name: its name in Tailscale, its own host name, or its whole name.
    @Test func aLeftHubIsPassedOverAtEachAddressThatItAnswersAt() {
        let status = """
        {"Self":{"DNSName":"laptop.example.ts.net.","TailscaleIPs":["100.64.0.2"]},
         "Peer":{"a":{"DNSName":"hub-1.example.ts.net.","HostName":"worker-1","Online":true,"TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"]},
                 "b":{"DNSName":"worker-2.example.ts.net.","HostName":"worker-2","Online":true,"TailscaleIPs":["100.64.0.10"]},
                 "c":{"DNSName":"worker-3.example.ts.net.","HostName":"worker-3","Online":false,"TailscaleIPs":["100.64.0.11"]}}}
        """
        let devices = FleetOnTailscale.devices(in: status), names = StartAgain.LeftHubs.dnsNames(in: status)
        #expect(names["100.64.0.1"] == "hub-1.example.ts.net" && names["100.64.0.10"] == "worker-2.example.ts.net")
        func passed(_ kept: String...) -> Set<String> {
            let (defaults, name) = scratch()
            defer { defaults.removePersistentDomain(forName: name) }
            for address in kept { StartAgain.LeftHubs.note(URL(string: address)!, in: defaults) }
            return StartAgain.LeftHubs.addresses(among: devices, dnsNames: names, in: defaults)
        }
        #expect(passed().isEmpty)
        #expect(passed("http://100.64.0.1:8765/") == ["100.64.0.1"])
        // By its whole name, by its name in Tailscale, and by the name that the machine gave itself.
        #expect(passed("http://Hub-1.example.ts.net:8765/") == ["100.64.0.1"])
        #expect(passed("http://hub-1:8765/") == ["100.64.0.1"])
        #expect(passed("http://worker-1:8765/") == ["100.64.0.1"])
        #expect(passed("http://worker-2.example.ts.net:8765/", "http://100.64.0.11:8765/") == ["100.64.0.10", "100.64.0.11"])
        // Another port is another program, and a name that only starts the same is another machine.
        #expect(passed("http://100.64.0.1:9000/").isEmpty && passed("http://worker-20:8765/").isEmpty)
    }
}
#endif
