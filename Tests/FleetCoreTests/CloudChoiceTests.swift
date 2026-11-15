#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// The words of the list in which the owner chooses a server he has at a provider, or a new one (the owner's yes of 5
/// November 2026): a short reason on each server that cannot be used, and what each row says.
struct CloudChoiceTests {
    private func server(_ name: String = "web-1", ipv4: String? = "203.0.113.20", type: String = "cx23",
                        memory: Int? = 4096, system: String? = "ubuntu", version: String? = "24.04", running: Bool = true,
                        project: String? = nil, madeFor: String? = nil) -> CloudExisting {
        CloudExisting(id: "1", name: name, ipv4: ipv4, type: type, memoryMB: memory, system: system, version: version,
                      place: "Nuremberg", running: running, project: project, madeFor: madeFor)
    }

    @Test func aServerThatCanTakeTheInstallHasNoReason() {
        #expect(server().unfit(for: .hub, fleet: []) == nil)
        #expect(server().unfit(for: .join, fleet: ["worker-1"]) == nil)
        // A server whose provider does not say its system is left to the check.
        #expect(server(system: nil, version: nil).unfit(for: .join, fleet: []) == nil)
    }

    @Test func eachServerThatCannotBeUsedSaysWhyInAFewWords() {
        #expect(server("Worker-1").unfit(for: .join, fleet: ["worker-1"]) == "In your fleet")
        #expect(server(madeFor: "hub").unfit(for: .join, fleet: []) == "Used by Founderizer")
        #expect(server(madeFor: "agent").unfit(for: .hub, fleet: []) == "Used by Founderizer")
        #expect(server(running: false).unfit(for: .hub, fleet: []) == "Off")
        #expect(server(ipv4: nil).unfit(for: .hub, fleet: []) == "No IPv4 address")
        #expect(server(memory: 1024).unfit(for: .join, fleet: []) == "1 GB: too small")
        #expect(server(memory: 1024).unfit(for: .hub, fleet: []) == nil, "the hub needs about 1 GB")
        #expect(server(memory: 512).unfit(for: .hub, fleet: []) == "512 MB: too small")
        // Both installers take Ubuntu 26.04 and Debian 13 (InstallPlan.joinTakes).
        #expect(server(version: "26.04").unfit(for: .hub, fleet: []) == nil)
        #expect(server(version: "26.04").unfit(for: .join, fleet: []) == nil)
        #expect(server(system: "debian", version: "13").unfit(for: .hub, fleet: []) == nil)
        #expect(server(system: "debian", version: "11").unfit(for: .join, fleet: []) == "Debian 11: not supported")
        #expect(server(system: "centos", version: "9").unfit(for: .hub, fleet: []) == "Centos 9: not supported")
    }

    // MARK: where a server that Founderizer made stands to this fleet (the owner's yes of 14 November 2026)

    /// The device of the fleet's own VPS, which its provider calls worker-1 and the hub calls `hub`.
    private var ownVPS: FleetOnTailscale.Device { device("worker-1", address: "100.64.0.9", host: "worker-1") }

    /// What a page knows of a fleet whose hub is at 100.64.0.9 and whose one server for agents is at 100.64.0.12, on a
    /// network that shows the fleet's own VPS and `others`.
    private func known(_ others: [FleetOnTailscale.Device] = [], own: Bool = true) throws -> FleetKnown? {
        FleetKnown(servers: [try entry("hub", address: "100.64.0.9", hub: true), try entry("worker-2", address: "100.64.0.12")],
                   hub: "100.64.0.9", devices: (own ? [ownVPS] : []) + others)
    }

    private let fleet: Set<String> = ["hub", "worker-2"]

    @Test func nothingIsKnownWithoutANetworkThatShowsTheFleet() throws {
        let servers = [try entry("hub", address: "100.64.0.9", hub: true)]
        // The network did not answer, or its list of devices is an old one (`FleetOnTailscale.live`).
        #expect(FleetKnown(servers: servers, hub: "100.64.0.9", devices: nil) == nil)
        // An answer with no device, and the network of another fleet: no device has an address of this fleet.
        #expect(FleetKnown(servers: servers, hub: "100.64.0.9", devices: []) == nil)
        #expect(FleetKnown(servers: servers, hub: "100.64.0.9", devices: [device("worker-3")]) == nil)
        // The address that the app reaches the hub at counts, also when the hub's list has none for it.
        let reached = try #require(FleetKnown(servers: [try entry("hub", address: nil, hub: true)], hub: "100.64.0.9",
                                              devices: [ownVPS]))
        #expect(reached.addresses == ["100.64.0.9"])
        // With nothing known, every server that Founderizer made keeps the old words: here a network that shows a
        // machine of its name and no device of this fleet.
        let stray = server("worker-3", madeFor: "agent")
        #expect(try stray.unfit(for: .join, fleet: fleet, known: known([device("worker-3")], own: false)) == "Used by Founderizer")
        #expect(stray.unfit(for: .join, fleet: fleet) == "Used by Founderizer")
        #expect(stray.unfit(for: .hub, fleet: []) == "Used by Founderizer")
    }

    @Test func theFleetsOwnVPSIsInTheFleetAndNeverNotInIt() throws {
        // The hub calls its machine `hub`, and its provider calls the server worker-1: the one link is the address
        // that the device of that name has on this Mac's network. By the device's name in Tailscale:
        let own = server("Worker-1", madeFor: "hub")
        #expect(try own.unfit(for: .join, fleet: fleet, known: known([device("worker-1", address: "100.64.0.9")], own: false))
                == "In your fleet")
        // And by the name that the device gave Tailscale, which called it worker-1-1 because an older device, now
        // offline, has the name.
        let second = [device("worker-1", online: false), device("worker-1-1", address: "100.64.0.9", host: "worker-1")]
        #expect(try own.unfit(for: .join, fleet: fleet, known: known(second, own: false)) == "In your fleet")
        // **A server with the label of a fleet's own VPS never says "Not in this fleet"**: a hub of another fleet that
        // runs on this network, and this fleet's own VPS under a name that nothing here links to it.
        let other = server("worker-5", madeFor: "hub")
        for devices in [[], [device("worker-5")], [device("worker-5", host: "worker-5")], [device("db", host: "worker-5")]] {
            #expect(try other.unfit(for: .join, fleet: fleet, known: known(devices)) == "Used by Founderizer")
        }
        // The hub runs on a server that was made for agents: its address says that it is the fleet's, also beside a
        // device of its name at another address.
        let byHand = server("worker-1", madeFor: "agent")
        #expect(try byHand.unfit(for: .join, fleet: fleet, known: known([device("worker-1")])) == "In your fleet")
    }

    @Test func aServerForAgentsSaysNotInThisFleetOnlyWhenTheNetworkShowsItOutsideTheFleet() throws {
        let stray = server("Worker-3", madeFor: "agent")
        // A machine of its name is online on this Mac's network, at an address that the hub does not have: by its
        // name in Tailscale, and by the name that it gave Tailscale.
        #expect(try stray.unfit(for: .join, fleet: fleet, known: known([device("worker-3")])) == "Not in this fleet")
        #expect(try stray.unfit(for: .join, fleet: fleet, known: known([device("worker-3-1", host: "worker-3")])) == "Not in this fleet")
        // **No proof, the old words.** An offline device of the name can be what a deleted server left behind.
        #expect(try stray.unfit(for: .join, fleet: fleet, known: known([device("worker-3", online: false)])) == "Used by Founderizer")
        // No device carries its name: it never came to this network, it is in another fleet's network, or its owner
        // gave it another name at the provider or on the machine (the hub then has it as `db`, at its address).
        #expect(try stray.unfit(for: .join, fleet: fleet, known: known()) == "Used by Founderizer")
        #expect(try stray.unfit(for: .join, fleet: ["hub", "db"], known: known([device("db", address: "100.64.0.12", host: "db")]))
                == "Used by Founderizer")
        // A device with no name of its own is not a device of a server with no name.
        #expect(try server("", madeFor: "agent").unfit(for: .join, fleet: fleet, known: known([device("worker-3")]))
                == "Used by Founderizer")
        // The fleet has it under the name that Tailscale gave it, at the address of its device.
        let second = [device("worker-3", online: false), device("worker-3-1", address: "100.64.0.12", host: "worker-3")]
        #expect(try stray.unfit(for: .join, fleet: ["hub", "worker-3-1"], known: known(second)) == "In your fleet")
        // **An address of the fleet comes before a machine of the name that runs outside it**: the fleet has the
        // server as `db` (a new name in Tailscale's own pages; the device keeps the name that it gave), it is offline
        // now, and another machine called worker-3 is online.
        let renamed = [device("worker-3"), device("db", address: "100.64.0.12", online: false, host: "worker-3")]
        #expect(try stray.unfit(for: .join, fleet: ["hub", "db"], known: known(renamed)) == "In your fleet")
        // The same fleet with no device that links the two: a name with Tailscale's number is enough for the old words.
        #expect(try stray.unfit(for: .join, fleet: ["hub", "worker-3-1"], known: known([device("worker-3")])) == "Used by Founderizer")
        // A name that only starts the same is another server.
        #expect(try stray.unfit(for: .join, fleet: ["hub", "worker-3-east", "worker-30", "worker-3-"], known: known([device("worker-3")]))
                == "Not in this fleet")
        // Its name in the hub's list comes first, as before.
        #expect(try stray.unfit(for: .join, fleet: ["worker-3"], known: known([device("worker-3")])) == "In your fleet")
        // A server that Founderizer did not make says nothing of the fleet: its row is the check's, as before.
        #expect(try server("worker-3").unfit(for: .join, fleet: fleet, known: known([device("worker-3")])) == nil)
    }

    // MARK: a server that the fleet holds already (the report of 14 November 2026)

    /// One server of the hub's own list (`GET /ui/servers`).
    private func entry(_ name: String, address: String? = "100.64.0.9", hub: Bool = false, joined: Bool = true,
                       agents: [String] = [], why: [String] = []) throws -> ServerEntry {
        try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: [
            "name": name, "kind": "linux", "address": address ?? NSNull(), "user": "fleet", "hub": hub, "joined": joined,
            "agents": agents, "available": why.isEmpty, "why": why, "job": NSNull()] as [String: Any]))
    }

    /// A device of this Mac's network; `host` is the name that it gave Tailscale itself, and none unless a test says.
    private func device(_ name: String, address: String = "100.64.0.7", online: Bool = true,
                        host: String = "") -> FleetOnTailscale.Device {
        .init(name: name, address: address, online: online, host: host)
    }

    /// What the fleet can do again with a server, with nothing kept on this Mac unless the test names it.
    private func again(_ server: CloudExisting, _ servers: [ServerEntry]?, devices: [FleetOnTailscale.Device] = [],
                       finished: Set<String> = [], made: Set<String> = [], placing: Bool = true,
                       job: InstallJob = .join) -> CloudReuse? {
        server.reuse(for: job, servers: servers, devices: devices, finished: finished, made: made, placing: placing)
    }

    @Test func aFleetServerWhoseInstallStoppedAfterTheJoinIsInstalledAgain() throws {
        let stopped = try entry("worker-2", why: ["no_reading"])
        // Still "In your fleet" in its row, and no longer a row that cannot be chosen.
        #expect(server("Worker-2", madeFor: "agent").unfit(for: .join, fleet: ["worker-2"]) == "In your fleet")
        for placing in [true, false] {
            #expect(again(server("Worker-2", madeFor: "agent"), [stopped], placing: placing) == .install(address: "100.64.0.9"))
        }
        // The hub's list has no address for it: this Mac's own network has.
        let noAddress = try entry("worker-2", address: nil, why: ["no_reading"])
        #expect(again(server("worker-2"), [noAddress], devices: [device("worker-2", online: false)])
                == .install(address: "100.64.0.7"))
        #expect(again(server("worker-2"), [noAddress]) == nil)
    }

    @Test func aFreeFleetServerIsInstalledAgainUnlessThisMacSawItsInstallEnd() throws {
        let free = try entry("worker-2")
        // The hub offers it from its first reading, right after the join and before the install's firewall and checks:
        // with no end that this Mac saw, the same install runs again, in an agent's setup and in Add server.
        for placing in [true, false] {
            #expect(again(server("worker-2"), [free], placing: placing) == .install(address: "100.64.0.9"))
        }
        // This Mac saw its install end: the agent that waits for a server takes it, with no install.
        #expect(again(server("Worker-2"), [free], finished: ["worker-2"]) == .place(server: "worker-2"))
        // Add server has no agent that waits: a server that is ready is in the fleet, and that is all.
        #expect(again(server("worker-2"), [free], finished: ["worker-2"], placing: false) == nil)
    }

    @Test func aFleetServerThatWorksOrThatTheHubCannotJudgeStaysGrey() throws {
        let made = server("worker-2", madeFor: "agent"), seen = [device("worker-2")]
        // It has an agent, it is the hub's own, it reported before and is offline now, or its job runs.
        #expect(again(made, [try entry("worker-2", agents: ["scout"], why: ["has_agent"])], devices: seen, made: ["worker-2"]) == nil)
        #expect(again(made, [try entry("worker-2", hub: true, why: ["hub_machine", "no_reading"])], devices: seen) == nil)
        #expect(again(made, [try entry("worker-2", why: ["offline"])], devices: seen) == nil)
        #expect(again(made, [try entry("worker-2", why: ["no_reading", "busy"])], devices: seen) == nil)
        #expect(again(made, [try entry("worker-2", why: ["busy"])], devices: seen, finished: ["worker-2"]) == nil)
        // It never joined with a join code: the hub would refuse the join of a server that it lists with no key.
        #expect(again(made, [try entry("worker-2", joined: false, why: ["no_service"])], devices: seen) == nil)
    }

    @Test func aServerThatNeverJoinedIsInstalledAgainOnlyWhenThisMacMadeItForThisHub() throws {
        let orphan = server("worker-3", madeFor: "agent"), hub = try entry("hub", hub: true, why: ["hub_machine"])
        #expect(orphan.unfit(for: .join, fleet: ["hub"]) == "Used by Founderizer")
        for placing in [true, false] {
            #expect(again(orphan, [hub], devices: [device("worker-3")], made: ["worker-3"], placing: placing)
                    == .install(address: "100.64.0.7"))
        }
        // **The provider's label names no fleet.** A working server of another fleet of the same account has the label,
        // is online on the same network and is not in this hub's list: an install there would take it out of its fleet.
        #expect(again(orphan, [hub], devices: [device("worker-3")]) == nil)
        // A provider that keeps no label (DigitalOcean) is covered by the same proof.
        #expect(again(server("worker-3"), [hub], devices: [device("worker-3")], made: ["worker-3"])
                == .install(address: "100.64.0.7"))
        // Not on this network, or offline there: nothing can install it.
        #expect(again(orphan, [hub], made: ["worker-3"]) == nil)
        #expect(again(orphan, [hub], devices: [device("worker-3", online: false)], made: ["worker-3"]) == nil)
        // The hub lists a server at that address under another name: it is in the fleet, and it works.
        let renamed = try entry("server-3", address: "100.64.0.7", agents: ["scout"], why: ["has_agent"])
        #expect(again(orphan, [hub, renamed], devices: [device("worker-3")], made: ["worker-3"]) == nil)
        // A server that is off.
        #expect(again(server("worker-3", running: false, madeFor: "agent"), [hub], devices: [device("worker-3")],
                      made: ["worker-3"]) == nil)
    }

    @Test func nothingIsTakenAgainWithoutTheHubsOwnListOrForTheFleetsOwnVPS() throws {
        let orphan = server("worker-3", madeFor: "agent")
        // The hub's list was not read: a working server of the fleet would look like one that never joined.
        #expect(again(orphan, nil, devices: [device("worker-3")], made: ["worker-3"]) == nil)
        #expect(again(orphan, [], devices: [device("worker-3")], made: ["worker-3"], placing: false, job: .hub) == nil)
    }

    @Test func thisMacKeepsTheServersThatItMadeByTheirHubAndByTheProvidersId() throws {
        let name = "cloud-choice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let one = try #require(URL(string: "http://100.64.0.1:8765")), other = try #require(URL(string: "http://100.64.0.2:8765"))
        #expect(MadeServers.kept(hub: one, in: defaults).isEmpty)
        // Before its provider answers, a server is kept by its name; then with the provider's id.
        MadeServers.note("Worker-2", hub: one, in: defaults)
        #expect(MadeServers.kept(hub: one, in: defaults) == ["worker-2": ""])
        MadeServers.note("worker-2", id: "1", hub: one, in: defaults)
        MadeServers.note("worker-5", id: "77", hub: other, in: defaults)
        #expect(MadeServers.kept(hub: one, in: defaults) == ["worker-2": "1"])
        #expect(MadeServers.kept(hub: other, in: defaults) == ["worker-5": "77"])
        // `server` has the id "1" at its provider.
        let kept = MadeServers.kept(hub: one, in: defaults)
        #expect(MadeServers.holds(server("worker-2"), in: kept))
        #expect(!MadeServers.holds(server("worker-5"), in: kept))
        // **A name comes back, an id does not**: the server that another fleet made later under the name of a deleted
        // one has another id.
        #expect(!MadeServers.holds(server("worker-2"), in: ["worker-2": "9"]))
        // A call that failed before the provider gave an id left the name alone: the name is the proof then.
        #expect(MadeServers.holds(server("worker-2"), in: ["worker-2": ""]))
    }

    @Test func theFleetsOwnVPSIsNeverTakenAsAServerForAgents() throws {
        let hub = try entry("hub", hub: true, why: ["hub_machine"])
        #expect(again(server("worker-3", madeFor: "hub"), [hub], devices: [device("worker-3")], made: ["worker-3"]) == nil)
    }

    @Test func thisMacKeepsTheInstallsThatItSawEnd() throws {
        let name = "install-ends-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let one = try #require(URL(string: "http://100.64.0.1:8765")), other = try #require(URL(string: "http://100.64.0.2:8765"))
        InstallEnds.note("Worker-2", address: "100.64.0.9", hub: one, in: defaults)
        InstallEnds.note("worker-2", address: "100.64.0.7", hub: other, in: defaults)
        #expect(InstallEnds.ended(hub: one, in: defaults) == ["worker-2": "100.64.0.9"])
        // A later install of a server of that name is the one that counts.
        InstallEnds.note("worker-2", address: "100.64.0.12", hub: one, in: defaults)
        #expect(InstallEnds.ended(hub: one, in: defaults) == ["worker-2": "100.64.0.12"])
        #expect(InstallEnds.ended(hub: other, in: defaults) == ["worker-2": "100.64.0.7"])
    }

    @Test func eachRowSaysWhatTheServerIs() {
        #expect(server().summary == "CX23 · 4 GB · Ubuntu 24.04")
        #expect(server(type: "s-1vcpu-2gb", memory: 2048, project: "Web").summary == "2 GB · Ubuntu 24.04 · Web")
        #expect(server(memory: 1536, system: nil, version: nil).summary == "CX23 · 1.5 GB")
    }

    @Test func theNewServerSaysWhatItIsWhereAndWhatItCosts() {
        let offer = CloudOffer(provider: .hetzner, type: "cx23", location: "nbg1", cores: 2, memoryGB: 4, diskGB: 40,
                               monthlyPrice: Decimal(string: "5.49")!, currency: "EUR")
        #expect(offer.size == "CX23 · 2 vCPU · 4 GB · 40 GB")
        #expect(offer.place == "Nuremberg, Germany")
        #expect(offer.monthly.hasSuffix(" a month") && offer.monthly.contains("5") && offer.monthly.contains("49"))
        #expect(offer.row == "CX23 · 4 GB · Nuremberg · \(offer.monthly)")
        let ocean = CloudOffer(provider: .digitalOcean, type: "s-1vcpu-2gb", location: "fra1", cores: 1, memoryGB: 2,
                               diskGB: 50, monthlyPrice: 12, currency: "USD")
        #expect(ocean.size == "1 vCPU · 2 GB · 50 GB")
        #expect(ocean.row == "2 GB · Frankfurt · \(ocean.monthly)")
    }
}
#endif
