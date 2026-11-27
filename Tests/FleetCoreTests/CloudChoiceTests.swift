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
        // The hub needs about 2 GB too: a server of 1 GB is no choice for it.
        #expect(server(memory: 960).unfit(for: .hub, fleet: []) == "960 MB: too small")
        #expect(server(memory: 2048).unfit(for: .hub, fleet: []) == nil, "the hub needs about 2 GB")
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
        let defaults = TestDefaults("cloud-choice")
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

    /// **An entry with a mark beside it stays an entry of every read** (`sweep`, F17's SP1): it stays in the list that
    /// an older build of the app reads, and a new server of that name is a new entry, with no mark. A bug here: after a
    /// move back to an older build, "Start again" and "Use this server" lose a server that is still paid for; or the
    /// record of a new server never reaches the hub because an older one had its name.
    @Test func aServerWithAMarkStaysAServerOfEveryRead() throws {
        let defaults = TestDefaults("cloud-choice")
        let one = try #require(URL(string: "http://100.64.0.1:8765")), other = try #require(URL(string: "http://100.64.0.2:8765"))
        MadeServers.note("worker-2", id: "1", hub: one, in: defaults)
        MadeServers.note("worker-3", id: "2", hub: one, in: defaults)
        MadeServers.note("worker-2", id: "1", hub: other, in: defaults)
        MadeServers.sweep(["worker-2": "1", "worker-3": "9"], hub: one, in: defaults)
        #expect(MadeServers.unswept(hub: one, in: defaults) == ["worker-3": "2"])
        #expect(MadeServers.kept(hub: one, in: defaults) == ["worker-2": "1", "worker-3": "2"])
        // The list that an older build reads holds each entry as before.
        #expect(Set(defaults.stringArray(forKey: "serversMadeFor") ?? []) == ["\(one.absoluteString)|worker-2|1",
                                                                              "\(one.absoluteString)|worker-3|2",
                                                                              "\(other.absoluteString)|worker-2|1"])
        #expect(MadeServers.unswept(hub: other, in: defaults) == ["worker-2": "1"])
        MadeServers.note("worker-2", id: "7", hub: one, in: defaults)
        #expect(MadeServers.kept(hub: one, in: defaults) == ["worker-2": "7", "worker-3": "2"])
        #expect(MadeServers.unswept(hub: one, in: defaults) == ["worker-2": "7", "worker-3": "2"])
        MadeServers.sweep(["worker-2": "7"], hub: one, in: defaults)
        MadeServers.forget(hub: one, in: defaults)
        #expect(MadeServers.kept(hub: one, in: defaults).isEmpty && MadeServers.kept(hub: other, in: defaults) == ["worker-2": "1"])
    }

    /// **An install was seen to end by this Mac, or by another client of the fleet (the hub's mark), each only at the
    /// server's address now** (F17's SP1). A bug here: a new server of a removed one's name gets an agent with no
    /// install, or a server that another Mac installed is installed again.
    @Test func anInstallWasSeenToEndOnlyAtTheServersAddressNow() throws {
        func entry(_ name: String, _ address: String?, _ mark: String?) throws -> ServerEntry {
            let row: [String: Any] = ["name": name, "address": address as Any? ?? NSNull(), "hub": false, "joined": true,
                                      "agents": [], "available": true, "why": [], "install_ended": mark as Any? ?? NSNull()]
            return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: row))
        }
        let servers = try [entry("worker-1", "100.64.0.11", nil), entry("worker-2", "100.64.0.12", "100.64.0.12"),
                           entry("worker-3", "100.64.0.13", "100.64.0.99"), entry("worker-4", nil, nil)]
        #expect(InstallEnds.finished(servers, ended: ["worker-1": "100.64.0.11", "worker-3": "100.64.0.9"])
                == ["worker-1", "worker-2"])
    }

    /// **Each place of the app that decides on this Mac's ended installs takes the hub's mark too**, wherever the rule
    /// stands (F17's SP1): a place that compares them with a server's address has the mark in the same condition, and
    /// the app's pages decide at such a place or by `InstallEnds.finished`. A bug here: the rule moves to another file,
    /// or two changes of it are merged, the hub's mark is gone, and a server that another Mac installed is installed
    /// again with no test that says so.
    @Test func eachPlaceThatDecidesOnEndedInstallsTakesTheHubsMarkToo() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var places = 0, without: [String] = [], pagesDecide = false
        for folder in ["Sources/Founderizer", "Sources/FleetCore"] {
            let files = try #require(FileManager.default.enumerator(at: app.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                var decides = folder == "Sources/Founderizer" && code.contains("InstallEnds.finished(")
                for match in code.matches(of: #/ended\[[^\]]*\]\s*==\s*\$0\.address/#) {
                    let open = code[..<match.range.lowerBound].lastIndex(of: "{") ?? code.startIndex
                    let close = code[match.range.upperBound...].firstIndex(of: "}") ?? code.endIndex
                    places += 1
                    if !code[open..<close].contains("install_ended == $0.address") { without.append(file.lastPathComponent) }
                    if folder == "Sources/Founderizer" { decides = true }
                }
                pagesDecide = pagesDecide || decides
            }
        }
        #expect(places > 0 && pagesDecide)
        #expect(without.isEmpty, "add the hub's mark to the condition, or call InstallEnds.finished, in: \(without)")
    }

    @Test func theFleetsOwnVPSIsNeverTakenAsAServerForAgents() throws {
        let hub = try entry("hub", hub: true, why: ["hub_machine"])
        #expect(again(server("worker-3", madeFor: "hub"), [hub], devices: [device("worker-3")], made: ["worker-3"]) == nil)
    }

    @Test func thisMacKeepsTheInstallsThatItSawEnd() throws {
        let defaults = TestDefaults("install-ends")
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

    // MARK: the hub's server that this Mac made, in a first run's list (`hubAgain`)

    /// A record of this Mac's build of the hub's server `worker-1`, which its provider calls by the id "1": made, and
    /// seen on this Mac's network at `joined`. With none, the build stopped before that, and `onNetwork` says whether
    /// the private network's own list had the server then.
    private func hubBuild(_ name: String = "worker-1", id: String? = "1", provider: CloudProvider = .hetzner,
                          use: CloudServerUse = .hub, joined: String? = "100.64.0.9", onNetwork: Bool = false,
                          began: Date = Date(timeIntervalSince1970: 1_763_300_000)) -> BuildRecord {
        var record = BuildRecord(provider: provider, use: use, hub: nil, name: name, at: began)
        if let id { record.made(id: id, at: began.addingTimeInterval(20)) }
        if let joined {
            record.joined(at: began.addingTimeInterval(80), hub: "http://\(joined):8765")
        } else {
            record.end(onNetwork: onNetwork, at: began.addingTimeInterval(320))
        }
        return record
    }

    /// The hub's install on a server of a first run's list, with one device of its name at the join's address unless
    /// the test names others.
    private func hubAgain(_ server: CloudExisting, _ builds: [BuildRecord], devices: [FleetOnTailscale.Device]? = nil,
                          provider: CloudProvider = .hetzner, except: Set<String> = []) -> CloudReuse? {
        server.hubAgain(at: provider, builds: builds, devices: devices ?? [device("worker-1", address: "100.64.0.9")],
                        except: except)
    }

    /// **The owner's report of 14 November 2026, for the fleet's own VPS**: the hub's server was made, its install
    /// stopped, and the first run's list showed it grey beside "New server". This Mac's own record of the build proves
    /// the server, and the install runs again at its address on the private network.
    @Test func theHubsServerThatThisMacMadeTakesItsInstallAgain() {
        let made = server("worker-1", madeFor: "hub")
        // Its row keeps its words: the first run knows no fleet, so nothing more can be said of it.
        #expect(made.unfit(for: .hub, fleet: []) == "Used by Founderizer")
        #expect(hubAgain(made, [hubBuild()]) == .install(address: "100.64.0.9"))
        // Tailscale gave the device another name, and the device keeps the name that it gave itself.
        #expect(hubAgain(made, [hubBuild()], devices: [device("worker-1-1", address: "100.64.0.9", host: "worker-1")])
                == .install(address: "100.64.0.9"))
        // The record names the server by its id: a new name at the provider, and capitals in the record, change nothing.
        #expect(hubAgain(server("renamed", madeFor: "hub"), [hubBuild("Worker-1")]) == .install(address: "100.64.0.9"))
        // The newest record of the server is the one that counts.
        let older = hubBuild(joined: "100.64.0.12", began: Date(timeIntervalSince1970: 1_763_200_000))
        #expect(hubAgain(made, [older, hubBuild()]) == .install(address: "100.64.0.9"))
        #expect(hubAgain(made, [hubBuild(), older]) == .install(address: "100.64.0.9"))
    }

    /// **Each proof is needed.** The provider's label names no Mac and no fleet: without this Mac's own record of the
    /// build, by the provider's id, the row stays as it is.
    @Test func aHubsServerStaysGreyWhereAProofIsMissing() {
        let made = server("worker-1", madeFor: "hub")
        // No record; a record of another provider's server with that id; of a server for agents; of another server.
        #expect(hubAgain(made, []) == nil)
        #expect(hubAgain(made, [hubBuild(provider: .digitalOcean)]) == nil)
        #expect(hubAgain(made, [hubBuild()], provider: .digitalOcean) == nil)
        #expect(hubAgain(made, [hubBuild(use: .agent)]) == nil)
        #expect(hubAgain(made, [hubBuild(id: "2")]) == nil)
        #expect(hubAgain(made, [hubBuild(id: nil, joined: nil)]) == nil)
        // The provider says that it is off.
        #expect(hubAgain(server("worker-1", running: false, madeFor: "hub"), [hubBuild()]) == nil)
        // No device of its name, an offline one, and one at another address than the join's: no address to install at.
        #expect(hubAgain(made, [hubBuild()], devices: []) == nil)
        #expect(hubAgain(made, [hubBuild()], devices: [device("worker-1", address: "100.64.0.9", online: false)]) == nil)
        #expect(hubAgain(made, [hubBuild()], devices: [device("worker-1", address: "100.64.0.12")]) == nil)
        #expect(hubAgain(made, [hubBuild()], devices: [device("worker-2", address: "100.64.0.9")]) == nil)
        // A record with no name is no proof by a name: a device that gave Tailscale no name of its own has none either.
        #expect(hubAgain(made, [hubBuild("")], devices: [device("worker-2", address: "100.64.0.9")]) == nil)
        // The record keeps the join's address: a hub that it knows by a name gives no device.
        #expect(hubAgain(made, [hubBuild(joined: "worker-1.example.ts.net")]) == nil)
        // The hub that the app is connected to, a hub that "Start again" left alive, and a hub that refuses this Mac.
        #expect(hubAgain(made, [hubBuild()], except: ["100.64.0.9"]) == nil)
        #expect(hubAgain(made, [hubBuild()], except: ["100.64.0.12"]) == .install(address: "100.64.0.9"))
    }

    /// **A build that stopped before this Mac saw the server on its network has only its name**, and a later try can
    /// take the same name: a new server gets a name that no device has. So it counts only when the private network's
    /// own list had its server at the build's end (a rule of the network kept it from this Mac), one device alone
    /// carries the name now, and no other build of this Mac has that name.
    @Test func aHubsServerThatThisMacNeverSawJoinIsTakenOnlyByANameThatIsItsAlone() {
        let made = server("worker-1", madeFor: "hub"), kept = hubBuild(joined: nil, onNetwork: true)
        let seen = [device("worker-1", address: "100.64.0.7")], later = Date(timeIntervalSince1970: 1_763_301_000)
        #expect(kept.hub == nil && kept.outcome == .stopped && kept.onNetwork)
        #expect(hubAgain(made, [kept], devices: seen) == .install(address: "100.64.0.7"))
        #expect(hubAgain(made, [kept], devices: [device("worker-1-1", address: "100.64.0.7", host: "worker-1")])
                == .install(address: "100.64.0.7"))
        // The network's own list never had the server: a device of that name proves nothing.
        #expect(hubAgain(made, [hubBuild(joined: nil)], devices: seen) == nil)
        // No device, two devices that carry the name, and an address that no install goes to.
        #expect(hubAgain(made, [kept], devices: []) == nil)
        #expect(hubAgain(made, [kept], devices: seen + [device("worker-1-1", address: "100.64.0.12", host: "worker-1")]) == nil)
        #expect(hubAgain(made, [kept], devices: seen, except: ["100.64.0.7"]) == nil)
        // The next try took the same name: the one device of the name is that try's server, which its own row offers,
        // and never this one's.
        let next = hubBuild(id: "2", joined: "100.64.0.7", began: later)
        #expect(hubAgain(made, [kept, next], devices: seen) == nil)
        #expect(hubAgain(CloudExisting(id: "2", name: "worker-1", ipv4: "203.0.113.21", type: "cx23", memoryMB: 4096,
                                       system: "ubuntu", version: "24.04", place: "Nuremberg", running: true,
                                       project: nil, madeFor: "hub"), [kept, next], devices: seen)
                == .install(address: "100.64.0.7"))
        // Another build of that name counts whatever it was for and whatever it left: at another provider, for agents,
        // and a try that its provider refused, whose own fault answer can have made the server all the same.
        var refused = BuildRecord(provider: .hetzner, use: .hub, hub: nil, name: "worker-1", at: later)
        refused.callEnded(with: CancellationError())
        refused.end()
        #expect(refused.atProvider == .nothing)
        for other in [hubBuild(id: "3", provider: .digitalOcean, joined: nil, began: later),
                      hubBuild(id: "3", use: .agent, joined: nil, began: later), refused] {
            #expect(hubAgain(made, [kept, other], devices: seen) == nil, "\(other.provider) \(other.use) \(other.atProvider)")
        }
    }

    /// **The first run's list uses the rule** (the Mac app's own target has no tests, so its source is read, as
    /// `InstallStartTests` reads it, with each run of spaces and line ends as one space). Each line here is a way in
    /// which a later edit of that page could bring the second paid server back with nothing that fails to compile:
    /// the list gets the servers that can be taken again (the argument has a default of none); its press asks the
    /// rule before its check of the row, which a server that the app made never passes; that install goes to the
    /// address on the private network; and "Make the server" goes to the page's task, which reads the network
    /// before it makes a server (`makeHub`, `makeServer`). **With no reading, the press makes nothing** (the owner's
    /// yes of 18 November 2026): only an answer that says what the network is now is a reading, so a Tailscale that
    /// is stopped or signed out is none. A server is made at two places only: at once on a list with no such record,
    /// whatever the list's choice was before, and at the end, after the return of a press whose list has a row
    /// chosen, after the refusal, and after the line of a server of an earlier try that cannot be taken (the owner's
    /// yes of the same day: that press rented a second server while the first still cost money).
    @Test func theFirstRunsListOffersTheHubsServerThatThisMacMade() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: app.appendingPathComponent("Sources/Founderizer/FirstRunView.swift"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(source.contains("CloudChoice(cloud: cloud, job: .hub, fleet: [], reuse:"))
        #expect(source.contains("reuseWords: Self.madeForHub, makeNew: makeHub, use: useExisting)"))
        let press = try #require(source.range(of: "private func useExisting(_ server: CloudExisting) {"))
        let next = try #require(source.range(of: "private func startInstall(", range: press.upperBound..<source.endIndex))
        let body = source[press.upperBound..<next.lowerBound]
        let rule = try #require(body.range(of: "= hubAgain(server)"))
        let check = try #require(body.range(of: "server.unfit(for: .hub"))
        #expect(rule.lowerBound < check.lowerBound)
        #expect(body.contains(#"startInstall(InstallTarget(host: onNetwork, user: "root", port: 22, identityFile: AppSSHKey.path()))"#))
        // "Make the server": the press is counted, the page's task takes it, and that task reads before it makes.
        #expect(source.contains("makeAsked += 1") && source.contains("await makeServer()"))
        let make = try #require(source.range(of: "private func makeServer() async {"))
        let rest = source[make.upperBound...]
        let task = rest[..<(rest.range(of: " private func ")?.lowerBound ?? rest.endIndex)]
        let atOnce = try #require(task.range(of: "guard made else { return cloud.makeNew { work.hubBuilt = true; startInstall($0) } }"))
        let reads = try #require(task.range(of: "let live = await readNetwork()", range: atOnce.upperBound..<task.endIndex))
        let chooses = try #require(task.range(of: "cloud.chosen = first.id", range: reads.upperBound..<task.endIndex))
        let chosen = try #require(task.range(of: "if cloud.chosen != nil {", range: chooses.upperBound..<task.endIndex))
        let refuses = try #require(task.range(of: "guard live else { return cloud.stop(Self.offNetwork) }",
                                              range: chosen.upperBound..<task.endIndex))
        #expect(task[chosen.upperBound..<refuses.lowerBound].hasSuffix("return } "))
        // A server of an earlier try that cannot be taken: the press asks the rule (`EarlierServerLines`) with the
        // line that it found over itself, read before the press takes its own lines away, and says the rule's line in
        // place of the server. The page gives the rule each such server with whether its row can be taken, and the
        // owner's next choice and a reading take away only what the rule says.
        let says = try #require(task.range(of: "if let line = earlierLines.says(over: said) { return cloud.stop(line) }",
                                           range: refuses.upperBound..<task.endIndex))
        #expect(task.range(of: "cloud.makeNew { work.hubBuilt = true; startInstall($0) }",
                           range: says.upperBound..<task.endIndex) != nil)
        let said = try #require(task.range(of: "let said = cloud.failure"))
        #expect(said.upperBound < (task.range(of: "cloud.stop(nil)")?.lowerBound ?? task.startIndex))
        // The press after that line rents a server, and the press after one that chose a row starts an install: the
        // second click of a double click and the repeats of a held key are no press, on either.
        #expect(source.contains("if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat, "
                                + "ProcessInfo.processInfo.systemUptime - event.timestamp < NSEvent.doubleClickInterval { return true } "
                                + "return SecondClick.isNow }"))
        #expect(source.contains("private func makeHub() { if !asksNetwork, !pressRepeats { makeAsked += 1 } }"))
        #expect(body.hasPrefix(" guard !pressRepeats else { return } "))
        #expect(source.contains("EarlierServerLines(made.map { (Self.stillCosts($0.name, at: provider), hubAgain($0) != nil) })"))
        #expect(source.contains("|| earlierLines.has(cloud.failure) { cloud.stop(nil) }"))
        #expect(source.contains("|| earlierLines.stale(cloud.failure) { cloud.stop(nil) }"))
        #expect(task.components(separatedBy: "cloud.makeNew").count == 3)
        // Only a reading of this press chooses a row, and the press that chose one says so over the press.
        #expect(task.contains("if live, cloud.chosen == nil, !suggestedHub, let first = "))
        #expect(task[chosen.upperBound..<refuses.lowerBound].contains("cloud.stop(Self.tookRow)"))
        #expect(source.contains("let devices = FleetOnTailscale.live(in: answer), !Task.isCancelled else { return false }"))
    }

    /// **A press on "Make the server" says that a server of an earlier try still costs money before a press rents a
    /// new one** (the owner's yes of 18 November 2026, "A: say it at the press"). The line is of the first such server
    /// whose row cannot be taken. Only a press over that same line makes the server: with no line, with a line that
    /// went and with another line over it, the press says the line, and the press after it makes the server. A
    /// reading of the network takes the line away only when a press would say it no more.
    @Test func thePressSaysThatAnEarlierServerStillCostsMoneyBeforeItRentsANewOne() {
        let lines = EarlierServerLines([("a costs", true), ("b costs", false), ("c costs", false)])
        #expect(lines.now == "b costs" && lines.lines == ["a costs", "b costs", "c costs"])
        #expect(lines.says(over: nil) == "b costs")
        #expect(lines.says(over: "b costs") == nil)
        #expect(lines.says(over: "c costs") == "b costs" && lines.says(over: "The provider's own line.") == "b costs")
        // Each such server's row can be taken, or the list has none: the press makes the server at once.
        #expect(EarlierServerLines([("a costs", true)]).says(over: nil) == nil)
        #expect(EarlierServerLines([]).says(over: nil) == nil && EarlierServerLines([]).lines.isEmpty)
        #expect(lines.has("c costs") && !lines.has("The provider's own line.") && !lines.has(nil))
        #expect(!lines.stale("b costs") && lines.stale("a costs") && lines.stale("c costs"))
        #expect(!lines.stale("The provider's own line.") && !lines.stale(nil))
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

    /// **The line under a server on the first run's page "Your fleet"**, as the build page's picture has it: Hetzner's
    /// type and the price; another provider's memory in place of the type. No place and no disk. **Its capsule and the
    /// rows of its list** (slice 2b, the owner's picture of 17 November 2026): the provider before that line, and a row
    /// with the cores ("own" for a dedicated type), the memory and the city, the price apart.
    @Test func theLineUnderAServerOfTheFleetIsItsTypeAndItsPrice() {
        let offer = CloudOffer(provider: .hetzner, type: "cx23", location: "nbg1", cores: 2, memoryGB: 4, diskGB: 40,
                               monthlyPrice: Decimal(string: "5.49")!, currency: "EUR")
        #expect(offer.brief == "CX23 · \(offer.monthly)")
        let ocean = CloudOffer(provider: .digitalOcean, type: "s-1vcpu-2gb", location: "fra1", cores: 1, memoryGB: 2,
                               diskGB: 50, monthlyPrice: 12, currency: "USD")
        #expect(ocean.brief == "2 GB · \(ocean.monthly)")
        let bare = CloudOffer(provider: .vultr, type: "vc2-1c-1gb", location: "fra", cores: nil, memoryGB: nil,
                              diskGB: nil, monthlyPrice: 5, currency: "USD")
        #expect(bare.brief == bare.monthly)
        #expect(offer.pick == "Hetzner · \(offer.brief)" && offer.choice == "CX23 · 2 cores · 4 GB · Nuremberg")
        #expect(offer.monthly == "\(offer.amount) a month")
        #expect(ocean.pick == "DigitalOcean · \(ocean.brief)" && ocean.choice == "1 core · 2 GB · Frankfurt")
        let own = CloudOffer(provider: .hetzner, type: "ccx13", location: "hel1", cores: 2, memoryGB: 8, diskGB: 80,
                             monthlyPrice: Decimal(string: "36.99")!, currency: "EUR", dedicated: true)
        #expect(own.choice == "CCX13 · 2 own cores · 8 GB · Helsinki")
        // One row of the list is Hetzner's type, and another provider's size, whatever its kind (`kind`, which keeps the
        // owner's choice through a read after "taken").
        let amd = CloudOffer(provider: .digitalOcean, type: "s-1vcpu-2gb-amd", location: "ams3", cores: 1, memoryGB: 2,
                             diskGB: 50, monthlyPrice: 14, currency: "USD")
        #expect(offer.kind == "cx23" && own.kind == "ccx13" && amd.kind == ocean.kind && amd.kind != own.kind)
    }
}
#endif
