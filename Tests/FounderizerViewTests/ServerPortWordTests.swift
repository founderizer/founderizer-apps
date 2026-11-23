import FleetCore
import Foundation
import Testing
@testable import Founderizer

/// **The owner's word for a server's port, and the address checks of the root steps, in the app's own code** (the SSH
/// first-use fix of 22 November 2026, `InstallTarget.hostKeyOptions`): a port that he gave keeps a new host key once, a
/// port of the hub's record never does, and the steps that run by themselves as root run only at an address that this
/// Mac's own Tailscale names. FleetCore's tests hold the rule; these hold the places of the app that give it its input.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ServerPortWordTests {
    /// A hub address of this test alone (the app keeps its records by the hub's address), at the address of the hub's
    /// machine in `status`.
    private static func hub() -> URL { URL(string: "http://100.80.1.2:8765/\(UUID().uuidString)")! }

    /// This Mac's `tailscale status --json`: the hub's machine and one other server.
    private static let status = #"""
    {"BackendState": "Running",
     "Self": {"DNSName": "owner-mac.tail1234.ts.net.", "TailscaleIPs": ["100.70.0.1"]},
     "Peer": {"a": {"DNSName": "hub-box.tail1234.ts.net.", "TailscaleIPs": ["100.80.1.2"]},
              "b": {"DNSName": "web-box.tail1234.ts.net.", "TailscaleIPs": ["100.80.1.3"]}}}
    """#

    /// One row of the hub's list of servers, with the fleet's record of its SSH (owner API 1.173).
    private static func server(_ name: String, address: String, port: Int) throws -> ServerEntry {
        let row: [String: Any] = ["name": name, "hub": false, "joined": true, "agents": [], "available": true, "why": [],
                                  "kind": "linux", "address": address, "access": ["ssh": ["user": "root", "port": port]]]
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: row))
    }

    /// **A kept connection keeps the owner's word for its port, and one kept before the fix has none**
    /// (`InstallTargets`). Bugs: the kept record drops the word, so a port that he typed is read as the hub's at each
    /// later round, and his own server on 2222 is refused for ever; or a record from before the fix reads as his word,
    /// so a `[host]:port` line that a first use kept at the hub's port still opens every strict step.
    @Test func aKeptConnectionKeepsTheOwnersWordForItsPort() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> (kept: String?, old: String?, alias: Bool) in
            let hub = Self.hub()
            InstallTargets.remember(InstallTarget(host: "100.80.1.3", port: 2222, portGivenFor: "100.80.1.3"),
                                    machine: "web-box", hub: hub)
            let kept = InstallTargets.target(machine: "web-box", hub: hub)?.portGivenFor
            // the same record as a Mac kept it before 22 November 2026: no word at all
            let key = "machineInstallTargets", prefix = hub.absoluteString + "|"
            guard let data = AppDefaults.store.data(forKey: key),
                  var all = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                return (kept, "no record", false)
            }
            for name in all.keys where name.hasPrefix(prefix) { all[name]?.removeValue(forKey: "portGivenFor") }
            AppDefaults.store.set(try JSONSerialization.data(withJSONObject: all), forKey: key)
            let old = InstallTargets.target(machine: "web-box", hub: hub)
            return (kept, old?.portGivenFor, old?.hostKeyOptions(strict: true).contains("HostKeyAlias=100.80.1.3") == true)
        }
        #expect(seen.kept == "100.80.1.3")
        #expect(seen.old == nil && seen.alias)
    }

    /// **A server's page takes a port as the owner's only when he typed it** (`MachineChecksModel`): the record's port
    /// in fields that open by any way is the hub's, also when he enters it again unchanged, and another value that he
    /// types is his; Use a different connection opens the port's field empty, so that the hub's port is not there to
    /// enter again. Bugs: the record's port gets `accept-new` (the hole itself); the hub's 2222 entered again becomes
    /// his word, so the first key at the hub's own port is kept (the Setup area's read of round 2); a value that he
    /// typed sets no word; the fields that open again after the fleet's connection give a word of before to the
    /// record's port.
    @Test func aServersPageTakesAPortAsTheOwnersOnlyWhenHeTypedIt() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [String] in
            let model = MachineChecksModel(machine: "web-box", hub: Self.hub(), kind: .linuxWorker, linux: true)
            model.fleetSays(MachineReach(address: "100.80.1.3", user: "root", port: 2222))
            var seen = [model.target.portGivenFor ?? "none"]
            model.asksForTheMachine = true          // fields that hold the hub's 2222
            model.typed(port: "2222")
            seen.append(model.target.portGivenFor ?? "none")
            model.typed(port: "2200")
            seen.append(model.target.portGivenFor ?? "none")
            seen.append(model.target.hostKeyOptions(strict: false).joined(separator: " "))
            model.useTheFleetsConnection()
            seen.append(model.target.portGivenFor ?? "none")
            model.askForTheConnection()
            seen += [model.port, model.target.portGivenFor ?? "none"]
            return seen
        }
        #expect(seen == ["none", "none", "100.80.1.3", "-o StrictHostKeyChecking=accept-new", "none", "", "none"])
    }

    /// **The fleet's connection takes no word of his** (`MachineChecksModel.useTheFleetsConnection`): a kept connection
    /// whose port 2200 he gave, then the fleet's connection at the record's 2222 on the same address. Bug: the page
    /// keeps the word that he gave for 2200, so the hub's 2222 meets its first key with `accept-new`.
    @Test func theFleetsConnectionTakesNoWordOfHis() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [String] in
            let hub = Self.hub()
            InstallTargets.remember(InstallTarget(host: "100.80.1.3", port: 2200, portGivenFor: "100.80.1.3"),
                                    machine: "web-box", hub: hub)
            let model = MachineChecksModel(machine: "web-box", hub: hub, kind: .linuxWorker, linux: true)
            model.fleetSays(MachineReach(address: "100.80.1.3", user: "root", port: 2222))
            var seen = [String(model.target.port), model.target.portGivenFor ?? "none"]
            model.useTheFleetsConnection()
            seen += [String(model.target.port), model.target.portGivenFor ?? "none"]
            return seen
        }
        #expect(seen == ["2200", "100.80.1.3", "2222", "none"])
    }

    /// **The port's field opens empty at a port that he did not give, other than 22, and any port in it is his**
    /// (`MachineChecksModel.askForTheConnection`): a refused key there asks for the port that the server's SSH listens
    /// on, at a closer look, at an update, or at a vault step that this page never sees, and the empty field (its
    /// placeholder 22) holds no port of the hub's. A port of 22 stays in its field. Bugs: the field shows the hub's 2222
    /// again, so that his answer to the refusal is the hub's port; it empties only after this page's own stop, so the
    /// stop of an update or of a vault step leaves the hub's port there (the Setup area's read of round 3); an empty
    /// field is no port.
    @Test func thePortsFieldOpensEmptyAtAPortThatIsNotHisAndAnyPortInItIsHis() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [String] in
            let model = MachineChecksModel(machine: "web-box", hub: Self.hub(), kind: .linuxWorker, linux: true)
            model.fleetSays(MachineReach(address: "100.80.1.3", user: "root", port: 2222))
            model.askForTheConnection()
            var seen = [model.port, String(model.target.port), model.target.portGivenFor ?? "none"]
            model.typed(port: "2222")
            seen.append(model.target.portGivenFor ?? "none")
            let plain = MachineChecksModel(machine: "web-box", hub: Self.hub(), kind: .linuxWorker, linux: true)
            plain.fleetSays(MachineReach(address: "100.80.1.3", user: "root", port: 22))
            plain.askForTheConnection()
            seen.append(plain.port)
            return seen
        }
        #expect(seen == ["", "22", "none", "100.80.1.3", "22"])
    }

    /// The page of the server web-box at 100.80.1.3, connected, with the fleet's record at `port`.
    @MainActor private static func page(_ port: Int) -> MachineChecksModel {
        let model = MachineChecksModel(machine: "web-box", hub: Self.hub(), kind: .linuxWorker, linux: true)
        model.fleetSays(MachineReach(address: "100.80.1.3", user: "root", port: port))
        return model
    }

    /// **A connected server keeps its tick and offers no fields until a refused key asks for its port, and then offers
    /// the fields of another connection in a card** (`MachineStandingSection.offers`, `isWell`); the hub's own server is
    /// always connected. Bugs: a connected server shows no button after such a stop, so the stop's words lead to a page
    /// with no field (the Setup area's read of round 3); its tick hides the card that holds the button; a port of the
    /// hub's that works (an sshd on 2222 with the keys of port 22) loses its tick and keeps a card for good (round 4).
    @Test func aConnectedServerKeepsItsTickUntilARefusalAsksForThePort() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [Bool] in
            let connected = MachineConnection.connected(lastSeen: nil)
            let standing = ServerStanding.of(try Self.server("web-box", address: "100.80.1.3", port: 2222),
                                             connected: connected, now: 0)
            let record = Self.page(2222)
            let none = MachineStandingSection.offers(standing, model: record, connected: connected, portStep: false)
            let after = MachineStandingSection.offers(standing, model: record, connected: connected, portStep: true)
            return [standing.settled, MachineStandingSection.isWell(standing, model: record, portStep: false), none.fields,
                    after.fields, MachineStandingSection.isWell(standing, model: record, portStep: true)]
        }
        #expect(seen == [true, true, false, true, false])
    }

    /// **The stops that ask for the port** (`MachineChecksModel.portStepIsDue`): this page's own stop and its update's,
    /// in the words that name the server by its address, at a port that he did not give, other than 22. Bugs: the port
    /// alone asks (round 4's false alarm); the page's stop, or the update's, is not read; a server at port 22 asks for
    /// its port; another stop asks.
    @Test func thePagesStopsThatAskForThePort() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [Bool] in
            let words = InstallTarget.typeItsPort("100.80.1.3")
            let record = Self.page(2222)
            let quiet = record.portStepIsDue(vault: [])
            let other = record.portStepIsDue(vault: ["Founderizer could not read its vault key on web-box."])
            let page = Self.page(2222)
            page.problem(words)
            let update = Self.page(2222)
            update.updateFailure = words
            let plain = Self.page(22)
            plain.problem(words)
            return [quiet, other, page.portStepIsDue(vault: []), update.portStepIsDue(vault: []),
                    plain.portStepIsDue(vault: [])]
        }
        #expect(seen == [false, false, true, true, false])
    }

    /// **A vault step's stop asks for the port in the words that name the server by its name**
    /// (`MachineChecksModel.portStepIsDue`, `CentralVaultModel.stops(of:isHub:)`). Bug: only the page's form of the
    /// words, by the address, counts, so a vault step refused at the hub's 2222 leaves the page with its tick.
    @Test func aVaultStepNamesTheServerByItsName() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> Bool in
            Self.page(2222).portStepIsDue(vault: [InstallTarget.typeItsPort("web-box")])
        }
        #expect(seen)
    }

    /// **The vault's stops of one server, for its page** (`CentralVaultModel.stops(of:isHub:)`): the trust step's last
    /// try and the key swap step's last try of that server, and the install's and the update's only for the hub's own
    /// server. Bug: the page never learns of a vault step's refusal whose way out is the port on that page, so the
    /// central vault's update on a second Mac, for a hub whose SSH is on 2222, waits for ever with no field to give it.
    @Test func theVaultsStopsOfAServerReachItsPage() throws {
        let tries = { (says: String) in VaultTries.failed(after: nil, at: 0, reason: says) }
        let trust = ["web-box": tries("trust web-box"), "db-box": tries("trust db-box")]
        let swap = ["web-box": KeySwapPlan.record(stop: "swap web-box", after: nil, at: 0),
                    "db-box": KeySwapPlan.record(stop: "swap db-box", after: nil, at: 0)]
        let install = tries("install"), update = tries("update")
        #expect(CentralVaultModel.stops(of: "web-box", isHub: false, trust: trust, keySwap: swap, install: install,
                                        update: update) == ["trust web-box", KeySwapWords.notSwitchedOn("swap web-box")])
        #expect(CentralVaultModel.stops(of: "hub-box", isHub: true, trust: trust, keySwap: swap, install: install,
                                        update: update) == ["install", "update"])
        #expect(CentralVaultModel.stops(of: "hub-box", isHub: true, trust: [:], keySwap: [:], install: nil,
                                        update: update) == ["update"])
    }

    /// **A key swap step refused at the hub's port asks for the port on the server's page** (`CentralVaultModel.stops`,
    /// `MachineChecksModel.portStepIsDue`), with the key swap's real stop: its record keeps the words inside its own
    /// sentence ("The key swap is not switched on: …", `KeySwapWords.notSwitchedOn`). Bugs: a stop counts only when it
    /// equals the words, so this one never does, and the stop's words lead to a page that shows no button (the Setup
    /// area's read of round 5); the words of another server whose name begins with this one's count for it.
    @Test func aKeySwapRefusalAtTheHubsPortAsksForThePortOnThePage() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [Bool] in
            let refused = KeySwapPlan.record(stop: InstallTarget.typeItsPort("web-box"), after: nil, at: 0)
            let other = KeySwapPlan.record(stop: InstallTarget.typeItsPort("web-box-2"), after: nil, at: 0)
            func stops(_ records: [String: KeySwapRecord]) -> [String] {
                CentralVaultModel.stops(of: "web-box", isHub: false, trust: [:], keySwap: records, install: nil, update: nil)
            }
            let page = Self.page(2222)
            return [page.portStepIsDue(vault: stops(["web-box": refused])),
                    page.portStepIsDue(vault: stops(["web-box": other])),
                    page.portStepIsDue(vault: [InstallTarget.typeItsPort("web-box-2")])]
        }
        #expect(seen == [true, false, false])
    }

    /// **A connected server offers a closer look while he gives a connection in the open fields, and while a stop that
    /// asks for the port is on record** (`MachineStandingSection.offers`): the closer look is what checks and keeps the
    /// port that he typed, which the vault's next step then takes, and it is what clears a stop of this page's own,
    /// which stays until a new look also after the refusal went another way. Bugs: the open fields of a connected server
    /// have no button that uses them; a stale stop keeps the card and its fields until the app quits, with no look that
    /// can clear it (the Setup area's read of round 5); a connected server with no stop offers a look.
    @Test func aConnectedServerOffersACloserLookOfTheConnectionThatHeGives() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [Bool] in
            let connected = MachineConnection.connected(lastSeen: nil)
            let standing = ServerStanding.of(try Self.server("web-box", address: "100.80.1.3", port: 2222),
                                             connected: connected, now: 0)
            let model = Self.page(2222)
            let quiet = MachineStandingSection.offers(standing, model: model, connected: connected, portStep: false)
            let stopped = MachineStandingSection.offers(standing, model: model, connected: connected, portStep: true)
            model.askForTheConnection()
            let open = MachineStandingSection.offers(standing, model: model, connected: connected, portStep: false)
            return [quiet.look, stopped.fields, stopped.look, open.fields, open.look]
        }
        #expect(seen == [false, true, true, false, true])
    }

    /// **No line of how this Mac reaches a server at a port that he did not give, other than 22, and a line that names
    /// a port that he gave** (`MachineChecksModel.connectionWords`): beside the words that ask for the port that the
    /// server's SSH listens on, a line with the hub's port is the value to copy, and a line with no port says port 22.
    /// Bugs: the line says "on port 2222"; the line leaves the port out, which says port 22, where this Mac does not
    /// reach it (the Setup area's read of round 4); a port that he gave is not named.
    @Test func noLineOfTheConnectionAtAPortThatTheHubGave() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [Bool] in
            let record = MachineChecksModel(machine: "web-box", hub: Self.hub(), kind: .linuxWorker, linux: true)
            record.fleetSays(MachineReach(address: "100.80.1.3", user: "root", port: 2222))
            let hub = Self.hub()
            InstallTargets.remember(InstallTarget(host: "100.80.1.3", port: 2200, portGivenFor: "100.80.1.3"),
                                    machine: "web-box", hub: hub)
            let given = MachineChecksModel(machine: "web-box", hub: hub, kind: .linuxWorker, linux: true)
            return [record.connectionWords == nil, given.connectionWords?.contains("2200") == true]
        }
        #expect(seen == [true, true])
    }

    /// **The page of a server that the hub does not report as Linux keeps no first host key at all** (a Mac, or a new
    /// server of no kind and no reading), and a later report that says Linux reaches the page's kept model
    /// (`FleetStore.checksModel`). Bugs: a Mac's page, or the page of a new Mac with no agent, takes the Linux rule, so
    /// its first check keeps an agent's key at port 22; or the kept model never learns that the server is Linux, so a
    /// Linux server's first check can never keep its key.
    @Test func aPageOfAServerNotReportedAsLinuxKeepsNoFirstHostKey() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [Bool] in
            let store = ViewHost.store(try ViewHost.reading(needs: [], features: []))
            let name = "new-box-\(UUID().uuidString.prefix(8).lowercased())"
            let mac = MachineChecksModel(machine: name, hub: Self.hub(), kind: .macWorker, linux: false)
            let unknown = store.checksModel(machine: name, kind: .linuxWorker, linux: false)
            let first = [mac.target.macServer, unknown.target.macServer]
            let later = store.checksModel(machine: name, kind: .linuxWorker, linux: true)
            return first + [later === unknown, later.target.macServer]
        }
        #expect(seen == [true, true, true, false])
    }

    /// **The owner's access line and the hardening steps run only at an address that this Mac's own Tailscale names as
    /// that server** (`OwnerAccessModel.connection`). Bug: a record that names another machine's address puts the
    /// owner's line there as root, and the record of it, so the real server never gets it.
    @Test func theRootStepsOfAServerRunOnlyWhereThisMacsTailscaleNamesIt() async throws {
        _ = try await ViewHost.onMainLoop { 0 }          // the test's defaults, before anything reads them
        let hub = Self.hub(), status = Self.status
        let records = ServerRecords(machines: { [] }, own: { nil })
        let named = try Self.server("web-box", address: "100.80.1.3", port: 22)
        let target = try await OwnerAccessModel.connection(to: named, hub: hub, records: records,
                                                           device: { MacNetwork.device(of: $0, in: status) })
        #expect(target.host == "100.80.1.3")
        let elsewhere = try Self.server("web-box", address: "100.80.1.2", port: 22)
        await #expect(throws: (any Error).self) {
            try await OwnerAccessModel.connection(to: elsewhere, hub: hub, records: records,
                                                  device: { MacNetwork.device(of: $0, in: status) })
        }
    }

    /// **Each step that reads the central vault as root takes the hub's machine through `hubTarget`**: the install and
    /// the update (`installed`) and the key swap's read of its owner keys (`keySwapCentral`). Bug: one of them goes
    /// back to `self.target`, and its stop is gone, so the hub's record alone chooses the machine whose root prints
    /// the key that becomes the pin; the install loses the compare with the pin that this Mac holds
    /// (`CentralVaultPins.refusal`), so an update pins any key that it prints. No other test runs these steps, which
    /// need the owner's Keychain and a hub. The trust step and the first run's seed give the Mac server pin's guard the
    /// node's Tailscale OS from that same read (`MacVaultPin`, VAULT.md limit 10). Bug: the guard gets no OS, so a hub
    /// that calls a Mac Linux takes the guard away; the seed opens an SSH session before it asks the guard.
    @Test func eachRootReadOfTheCentralVaultTakesHubTarget() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer/CentralVaultSection.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        for name in ["installed", "keySwapCentral"] {
            let start = try #require(source.range(of: "private func \(name)("), "\(name) is gone")
            let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
            let body = source[start.lowerBound..<end.lowerBound]
            #expect(body.contains("try await hubTarget(") || body.contains("try? await hubTarget("), "\(name)")
            #expect(!body.contains("self.target("), "\(name)")
            // the install and the update move no pin that this Mac holds, and only Set up does (M2, R2-S3)
            if name == "installed" {
                #expect(body.contains("CentralVaultPins.refusal(") && body.contains("setUp: !own)"), "the pin's compare")
            }
        }
        // the trust step takes its connection and its Mac rule from `trustTarget` (R2-M1, R2-S3)
        let trust = try #require(source.range(of: "private func trust("), "trust is gone")
        let end = try #require(source.range(of: "\n    }\n", range: trust.upperBound..<source.endIndex))
        let body = source[trust.lowerBound..<end.lowerBound]
        #expect(body.contains("try await trustTarget(name, kind: kind, database: database)") && !body.contains("self.target("))
        #expect(body.contains("let (target, mac, os) = try await trustTarget(") &&
                body.contains("MacVaultPin(kind: kind, os: os, record:"), "the guard takes the trust step's OS")
        let seed = try #require(source.range(of: "private func seed("), "seed is gone")
        let seedEnd = try #require(source.range(of: "\n    }\n", range: seed.upperBound..<source.endIndex))
        let seedBody = source[seed.lowerBound..<seedEnd.lowerBound]
        let covered = try #require(seedBody.range(of: "MacVaultPin(kind: kind, os: peer.os, record: nil).covered"))
        let reach = try #require(seedBody.range(of: "try trustReach(name, kind: kind, peer: peer)"))
        let ssh = try #require(seedBody.range(of: "SSHRun.run("))
        #expect(covered.lowerBound < reach.lowerBound && reach.lowerBound < ssh.lowerBound && !seedBody.contains("self.target("),
                "the seed asks the guard before any SSH, and reads a Mac only by both words")
        // The guard's own calls (path E and MUST A of mac-server-pin-design.md): no SSH session before `mayRead`, only the
        // key that `signs` gives is signed, the record takes it before the signature leaves this Mac, the seed keeps only
        // what `MacVaultPin.seed` names, Try again (`added`) keeps the record, and only Remove server clears it.
        let mayRead = try #require(body.range(of: "guarded.mayRead(bound: reported)"), "the guard's read check is gone")
        let trustSSH = try #require(body.range(of: "SSHRun.run("))
        let noted = try #require(body.range(of: "MacVaultPins.note(.signed(signed)"), "the record's write is gone")
        let sent = try #require(body.range(of: "VaultClient().pin("))
        #expect(mayRead.lowerBound < trustSSH.lowerBound && noted.lowerBound < sent.lowerBound
                && body.contains("guarded.signs(found: found, bound: reported)") && body.contains("recipient: signed"),
                "the trust step signs only the guard's key, and the record takes it first")
        #expect(seedBody.contains("MacVaultPin.seed(record: MacVaultPins.records(") && seedBody.contains(".seeded(kept)"))
        let added = try #require(source.range(of: "    func added("), "added is gone")
        let addedEnd = try #require(source.range(of: "\n    }\n", range: added.upperBound..<source.endIndex))
        let addedBody = source[added.lowerBound..<addedEnd.lowerBound]
        #expect(addedBody.contains("MacVaultPins.note(.added") && !addedBody.contains("MacVaultPins.note(.removed"),
                "Try again keeps the record")
        let removed = try #require(source.range(of: "    func removed("), "removed is gone")
        let removedEnd = try #require(source.range(of: "\n    }\n", range: removed.upperBound..<source.endIndex))
        #expect(source[removed.lowerBound..<removedEnd.lowerBound].contains("MacVaultPins.note(.removed"))
        #expect(source.components(separatedBy: "MacVaultPins.note(.removed").count - 1 == 2
                && source.contains("for machine in marked.keys { MacVaultPins.note(.removed")
                && source.contains("for machine in joined { MacVaultPins.note(.added"),
                "only Remove server clears the record: in removed, and in the read for a press before the fleet was known")
    }

    /// **The central vault's install, update and owner-key read take only the hub's machine** (`CentralVaultModel.
    /// hubTarget`): this Mac's Tailscale names the connection's host and this Mac's hub address as one device, and the
    /// record's user is root. Bugs: the update round runs at the address of the hub's record alone, and pins the key
    /// that the root there prints as the central vault's; it runs as the record's `fleet` (`hub.sh` records the hub's
    /// own user), whose own `authorized_keys` can hold a forced command that prints the hub's key in root's place (M1
    /// of the validation of 23 November 2026).
    @Test func theCentralVaultsStepsTakeOnlyTheHubsMachine() async throws {
        _ = try await ViewHost.onMainLoop { 0 }          // the test's defaults, before anything reads them
        let status = Self.status
        let model = await CentralVaultModel(hub: Self.hub())
        let hubs = try await model.hubTarget("hub-box", database: "view-test", record: MachineReach(
            address: "100.80.1.2", user: "root", port: 22), status: { status })
        #expect(hubs.host == "100.80.1.2")
        await #expect(throws: (any Error).self) {
            try await model.hubTarget("web-box", database: "view-test", record: MachineReach(
                address: "100.80.1.3", user: "root", port: 22), status: { status })
        }
        await #expect(throws: (any Error).self) {
            try await model.hubTarget("hub-box", database: "view-test", record: MachineReach(
                address: "100.80.1.2", user: "fleet", port: 22), status: { status })
        }
    }

    /// **The trust step reads a server as a Mac only when the hub's list and this Mac's own Tailscale both say so**
    /// (`CentralVaultModel.trustTarget`; R2-M1 of the validation of 23 November 2026). Bugs: the hub's word "mac" alone
    /// lets the record's user in, so on a Linux server that the hub calls a Mac the step logs in as an agent's OS user,
    /// whose forced command prints the agent's key, and the Mac pins it; the step reads the `OS` of another node than
    /// the one that it names; a Mac by both words loses the read as the agents' user; the Mac server pin's guard gets no
    /// `OS`, so a Mac that the hub calls Linux gets no record at its first pin.
    @Test func theTrustStepReadsAServerAsAMacOnlyByBothWords() async throws {
        _ = try await ViewHost.onMainLoop { 0 }          // the test's defaults, before anything reads them
        let status = #"""
        {"BackendState": "Running",
         "Self": {"DNSName": "owner-mac.tail1234.ts.net.", "TailscaleIPs": ["100.70.0.1"], "OS": "macOS"},
         "Peer": {"a": {"DNSName": "web-box.tail1234.ts.net.", "TailscaleIPs": ["100.80.1.3"], "OS": "linux"},
                  "b": {"DNSName": "studio-1.tail1234.ts.net.", "TailscaleIPs": ["100.80.1.4"], "OS": "macOS"}}}
        """#
        let model = await CentralVaultModel(hub: Self.hub())
        await #expect(throws: (any Error).self) {
            try await model.trustTarget("web-box", kind: "mac", database: "view-test", record: MachineReach(
                address: "100.80.1.3", user: "fleet-writer", port: 22), status: { status })
        }
        let linux = try await model.trustTarget("web-box", kind: "mac", database: "view-test", record: MachineReach(
            address: "100.80.1.3", user: "root", port: 22), status: { status })
        let mac = try await model.trustTarget("studio-1", kind: "mac", database: "view-test", record: MachineReach(
            address: "100.80.1.4", user: "owner-example", port: 22), status: { status })
        #expect(!linux.mac && !linux.target.macServer)
        #expect(mac.mac && mac.target.macServer && !mac.target.becomeRoot && mac.target.user == "owner-example")
        // the Mac server pin's guard takes the node's own `OS` from this same read (`MacVaultPin`)
        #expect(linux.os == ["linux"] && mac.os == ["macOS"])
    }

    /// **A closer look keeps no connection with a user of the fleet's record that is not root**
    /// (`MachineChecksModel.keeps`; M1 of the validation of 23 November 2026), also when he enters it again unchanged;
    /// root, a user that he gave, and a connection kept before are kept. Bug: the page keeps the record's `fleet`, and
    /// every root step of this Mac then takes that kept connection as it is, in a session whose output that user's own
    /// `authorized_keys` decides.
    @Test func aCloserLookKeepsNoUserOfTheRecordThatIsNotRoot() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> [Bool] in
            @MainActor func page(_ user: String) -> MachineChecksModel {
                let model = MachineChecksModel(machine: "web-box", hub: Self.hub(), kind: .linuxWorker, linux: true)
                model.fleetSays(MachineReach(address: "100.80.1.3", user: user, port: 22))
                return model
            }
            let record = page("fleet"), root = page("root"), given = page("fleet")
            given.asksForTheMachine = true
            given.user = "admin"
            let hub = Self.hub()
            InstallTargets.remember(InstallTarget(host: "100.80.1.3", user: "fleet"), machine: "web-box", hub: hub)
            let kept = MachineChecksModel(machine: "web-box", hub: hub, kind: .linuxWorker, linux: true)
            kept.fleetSays(MachineReach(address: "100.80.1.3", user: "fleet", port: 22))
            return [record.keeps(record.target), root.keeps(root.target), given.keeps(given.target), kept.keeps(kept.target)]
        }
        #expect(seen == [false, true, true, true])
    }
}
