@testable import FleetCore
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
     "Peer": {"a": {"DNSName": "hub-box.tail1234.ts.net.", "TailscaleIPs": ["100.80.1.2"], "OS": "linux"},
              "b": {"DNSName": "web-box.tail1234.ts.net.", "TailscaleIPs": ["100.80.1.3"], "OS": "linux"}}}
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
    /// that calls a Mac Linux takes the guard away; the seed opens an SSH session before it asks the guard. The key
    /// swap's step (`keySwapStep`) and the gate's step (`keySwapGate`) on the hub's own row take `hubTarget` too (the
    /// Vault area's read of the gate piece, 23 November 2026, MUST 1): bug, the hub's record and a first label alone
    /// choose the machine where the owner's root session runs `configure`. The TCP step and `rootRun` take `hubTarget`
    /// too (the Door area's read of 25 November 2026: bug, where the node check fails they send the owner's keys to the
    /// hub's named address), and the trust step of the hub's own server with no kept connection takes
    /// `hubTarget` first, also with a record of root: bugs, those steps stop with the owner's step ("add this Mac's key
    /// …, then select Try again") and the owner's Try again runs no route, so the words are false; the trust step of a hub whose
    /// root holds only this Mac's key offers the owner's keys, and root refuses it (the tester's case).
    @Test func eachRootReadOfTheCentralVaultTakesHubTarget() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer/CentralVaultSection.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        for name in ["installed", "keySwapCentral", "keySwapGate"] {
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
        // the key swap's step: the hub's own row by `hubTarget`, each joined server by its own connection
        let step = try #require(source.range(of: "private func keySwapStep("), "keySwapStep is gone")
        let stepEnd = try #require(source.range(of: "\n    }\n", range: step.upperBound..<source.endIndex))
        #expect(source[step.lowerBound..<stepEnd.lowerBound].contains(
            "if row.hub {\n                target = try await hubTarget(row.name, database: database, record: reading?.hub?.reach)"))
        // and the round runs the gate's step after a keys step that reached the hub's own row (R3-S5)
        let round = try #require(source.range(of: "private func keySwapRound("), "keySwapRound is gone")
        let roundEnd = try #require(source.range(of: "\n    }\n", range: round.upperBound..<source.endIndex))
        #expect(source[round.lowerBound..<roundEnd.lowerBound].contains(
            "if step.gate, keys != nil { await keySwapGate(row, database: database) }"))
        // the trust step takes its connection and its Mac rule from `trustTarget` (R2-M1, R2-S3)
        let trust = try #require(source.range(of: "private func trust("), "trust is gone")
        let end = try #require(source.range(of: "\n    }\n", range: trust.upperBound..<source.endIndex))
        let body = source[trust.lowerBound..<end.lowerBound]
        #expect(body.contains("try await trustTarget(name, kind: kind, database: database)") && !body.contains("self.target("))
        let pre = try #require(body.range(of: "if let own = reading?.hub, own.machine == name, routes(name) {"),
                               "the trust step of the hub's own server takes the route first, a record of root too")
        #expect(body.contains("do { _ = try await hubTarget(name, database: database, record: own.reach) } catch let stop as RouteStop {"))
        // each press of the owner's ends the route's hold (`pressed`)
        for press in ["    func retry(_ store: FleetStore)", "    func retry(server machine: String,", "    func retryKeySwap(server",
                      "    func takeOver(", "    func rootRun("] {
            let start = try #require(source.range(of: press), "\(press) is gone")
            let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
            #expect(source[start.lowerBound..<end.lowerBound].contains("pressed()"), "\(press)")
        }
        #expect(pre.lowerBound < (body.range(of: "try await trustTarget(")?.lowerBound ?? body.startIndex))
        for name in ["keepTCPWindow", "rootRun"] {
            let start = try #require(source.range(of: "func \(name)("), "\(name) is gone")
            let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
            let body = source[start.lowerBound..<end.lowerBound]
            #expect(body.contains("hubTarget(machine, database: database, record: reading?.hub?.reach)")
                    && !body.contains("self.target("), "\(name)")
        }
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

    /// What the root route's stand-ins were asked: each `ssh`, and each read of the owner access key.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [[String]] = []
        private var reads = 0
        var ssh: [[String]] { lock.withLock { made } }
        var keyReads: Int { lock.withLock { reads } }
        /// Notes one `ssh`, and gives how many came before it.
        func note(_ arguments: [String]) -> Int { lock.withLock { made.append(arguments); return made.count - 1 } }
        func read() { lock.withLock { reads += 1 } }
    }

    private static let rootAnswer = LocalShell.Answer(status: 0, output: "founderizer-root=0\nfounderizer-app-key-in-place\n")
    private static let refusedAnswer = LocalShell.Answer(status: 255, output: "root@100.80.1.2: Permission denied (publickey).\r\n")

    /// The hub's root route with stand-ins (`RootRoute`): `ssh` answers `answers` in their order (the last one again),
    /// the owner access key is `key`, this Mac's own key file is a stand-in in `folder`, and the ledger of app mode and
    /// the key's folder are the test's own, in `folder` too.
    private static func route(_ calls: Calls, _ answers: [LocalShell.Answer], key: OwnerAccessKey? = nil,
                              folder: URL, run: ShellRunner? = nil, known: [String] = []) -> RootRoute {
        let appKey = folder.appendingPathComponent("founderizer_ed25519").path
        try? "stand-in\n".write(toFile: appKey, atomically: true, encoding: .utf8)
        return RootRoute(appKey: appKey, appLine: { "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample founderizer@mac" },
                         ownerAccess: { _ in calls.read(); return key },
                         run: run ?? { _, arguments, _, _ in answers[min(calls.note(arguments), answers.count - 1)] },
                         ledger: SSHKeyLedger(folder: folder.appendingPathComponent("ssh")), folder: folder,
                         known: { known.contains($0) })
    }

    /// A stand-in `ssh` whose `known_hosts` holds the hub's key under `known` alone: root answers where the call reads
    /// the key under that name (its `HostKeyAlias`, else its host), and `ssh` refuses an unknown host key elsewhere.
    private static func knownHosts(_ calls: Calls, _ known: String) -> ShellRunner {
        { _, arguments, _, _ in
            _ = calls.note(arguments)
            let alias = arguments.first { $0.hasPrefix("HostKeyAlias=") }.map { String($0.dropFirst("HostKeyAlias=".count)) }
            let host = arguments.first { $0.hasPrefix("root@") }.map { String($0.dropFirst("root@".count)) }
            return (alias ?? host) == known ? Self.rootAnswer
                : LocalShell.Answer(status: 255, output: "No ED25519 host key is known for \(alias ?? host ?? "").\r\nHost key verification failed.\r\n")
        }
    }

    private static func folder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("root-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The words of the stop that `body` threw, or nil when it threw none.
    private static func stop(_ body: () async throws -> InstallTarget) async -> String? {
        do { _ = try await body(); return nil } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    /// **The root route runs only for the hub's own machine, and only where this Mac's Tailscale names its address and
    /// this Mac's hub address as one node and gives that node's system as Linux** (`CentralVaultModel.hubTarget`,
    /// `rootRoute`): before that no SSH session opens, no owner access key is read, and nothing is kept. A hub on a Mac
    /// keeps its root record as before, and its record of another user stops with the words of no record. Bugs: the
    /// update round runs at the address of the hub's record alone, and pins the key that the root there prints as the
    /// central vault's; the route probes root on a server that is not the hub, and offers it the fleet's owner access
    /// key; a record of `fleet` (`hub.sh` records the hub's own user) is taken as it is, whose own `authorized_keys` can
    /// hold a forced command that prints the hub's key in root's place (M1 of the validation of 23 November 2026); on a
    /// hub on a Mac the route logs in as root, which macOS refuses, every 10 minutes, and its words name /root.
    @Test func theCentralVaultsStepsTakeOnlyTheHubsMachine() async throws {
        _ = try await ViewHost.onMainLoop { 0 }          // the test's defaults, before anything reads them
        let status = Self.status, folder = try Self.folder(), calls = Calls(), hub = Self.hub()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try #require(OwnerAccessKey(seed: Data(repeating: 7, count: 32)))
        let route = Self.route(calls, [Self.rootAnswer], key: key, folder: folder)
        let model = await CentralVaultModel(hub: hub)
        for user in ["root", "fleet"] {
            #expect(await Self.stop { try await model.hubTarget("web-box", database: "view-test", record: MachineReach(
                address: "100.80.1.3", user: user, port: 22), status: { status }, route: route) } != nil)
        }
        let elsewhere = #"{"BackendState": "Running", "Peer": {"b": {"DNSName": "web-box.tail1234.ts.net.", "TailscaleIPs": ["100.80.1.3"]}}}"#
        #expect(await Self.stop { try await model.hubTarget("hub-box", database: "view-test", record: MachineReach(
            address: "100.80.1.2", user: "fleet", port: 22), status: { elsewhere }, route: route) } != nil)
        // a hub on a Mac: no route
        let mac = status.replacingOccurrences(of: #""TailscaleIPs": ["100.80.1.2"], "OS": "linux""#,
                                              with: #""TailscaleIPs": ["100.80.1.2"], "OS": "macOS""#)
        #expect(await Self.stop { try await model.hubTarget("hub-box", database: "view-test", record: MachineReach(
            address: "100.80.1.2", user: "owner-example", port: 22), status: { mac }, route: route) }
                == "The fleet has no SSH connection to hub-box on record. Record one on its page in Servers.")
        #expect(try await model.hubTarget("hub-box", database: "view-test", record: MachineReach(
            address: "100.80.1.2", user: "root", port: 22), status: { mac }, route: route) == InstallTarget(host: "100.80.1.2"))
        #expect(calls.ssh.isEmpty && calls.keyReads == 0)
        let kept = await MainActor.run { ["web-box", "hub-box"].map { InstallTargets.target(machine: $0, hub: hub) } }
        #expect(kept == [nil, nil])
    }

    /// **A root record of the hub's machine, with no connection that this Mac keeps, gets this Mac's own key from the
    /// route, at the node's own address, and the connection is kept when root answers** (the tester's report of 25
    /// November 2026: root held the app's key, and the record's connection offered only the keys of the owner's agent and
    /// configuration, so root refused each try of the install). The install after it runs in app mode with that key,
    /// and a kept connection comes first after it. Bugs: the route runs only for a record of another user, so a root
    /// record offers only the owner's keys and root refuses this Mac (the tester's fault); the route connects to the
    /// record's first label, which `ssh` looks up through DNS; the route keeps nothing, so each step of each round
    /// probes again; the route runs again over a kept connection.
    @Test func aRootRecordOfTheHubOffersThisMacsKeyAndKeepsTheConnection() async throws {
        _ = try await ViewHost.onMainLoop { 0 }
        let status = Self.status, folder = try Self.folder(), calls = Calls(), hub = Self.hub()
        defer { try? FileManager.default.removeItem(at: folder) }
        let route = Self.route(calls, [Self.rootAnswer], folder: folder)
        let model = await CentralVaultModel(hub: hub)
        let record = MachineReach(address: "hub-box", user: "root", port: 22)
        let target = try await model.hubTarget("hub-box", database: "view-test", record: record, status: { status }, route: route)
        let root = InstallTarget(host: "100.80.1.2", user: "root", port: 22, identityFile: route.appKey)
        #expect(target == root && calls.ssh.count == 1 && calls.keyReads == 0)
        let probe = try #require(calls.ssh.first)
        #expect(probe.contains("root@100.80.1.2") && probe.contains(route.appKey) && probe.contains("StrictHostKeyChecking=yes"))
        #expect(await MainActor.run { InstallTargets.target(machine: "hub-box", hub: hub) } == root)
        // the install's own run: app mode with this Mac's key alone, as the ledger now says (`SSHCall.key`, with the
        // route's key file, which is the stand-in here and `AppSSHKey.path()` in the app)
        #expect(SSHCall.key(for: target, ledger: route.ledger, appKey: route.appKey) == .file(route.appKey))
        // the kept connection comes first: no second probe
        #expect(try await model.hubTarget("hub-box", database: "view-test", record: record, status: { status },
                                          route: route) == root)
        #expect(calls.ssh.count == 1)
    }

    /// **A record of the hub's own user is no dead end any more: the route tries root at its address and port, and the
    /// fleet's owner access key after root refused this Mac's own key, and keeps the connection once this Mac's own key
    /// got in after it** (`rootRoute`; the Setup area's read of a hub that moved: `hub.sh` writes no key, and only the
    /// owner access key may be in root's file). Bugs: the record of `fleet` stops each root step for ever; the route
    /// ignores the record's port; it keeps a connection that names the owner access key's file, which is gone after the
    /// call, or one that root refuses.
    @Test func aFleetRecordOfTheHubTriesRootAtItsAddressAndPort() async throws {
        _ = try await ViewHost.onMainLoop { 0 }
        let status = Self.status, folder = try Self.folder(), calls = Calls(), hub = Self.hub()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try #require(OwnerAccessKey(seed: Data(repeating: 7, count: 32)))
        let route = Self.route(calls, [Self.refusedAnswer, Self.rootAnswer, Self.rootAnswer], key: key, folder: folder)
        let model = await CentralVaultModel(hub: hub)
        let target = try await model.hubTarget("hub-box", database: "view-test", record: MachineReach(
            address: "100.80.1.2", user: "fleet", port: 2222), status: { status }, route: route)
        let root = InstallTarget(host: "100.80.1.2", user: "root", port: 2222, identityFile: route.appKey)
        #expect(target == root && calls.ssh.count == 3 && calls.keyReads == 1)
        #expect(calls.ssh.allSatisfy { $0.contains("root@100.80.1.2") && $0.contains("2222") && $0.contains("HostKeyAlias=100.80.1.2") })
        #expect(await MainActor.run { InstallTargets.target(machine: "hub-box", hub: hub) } == root)
        #expect(route.ledger.confined(SSHKeyLedger.Account(address: "100.80.1.2", user: "root", port: 2222)))
    }

    /// **Where the route does not reach root for a record of root, the step goes on with the owner's own keys, as before
    /// the route, and keeps nothing** (`rootRoute`; the Door area's read of 25 November 2026, MUST 2). Bugs: a hub whose
    /// root takes only the owner's agent key, which worked before the route, stops each root step at the route's
    /// refusal; a hub whose host key this Mac knows only under the record's name stops at the route's host key.
    @Test func aRootRecordGoesOnWithTheOwnersKeysWhereRootRefusesThisMacs() async throws {
        _ = try await ViewHost.onMainLoop { 0 }
        let status = Self.status, folder = try Self.folder(), calls = Calls(), hub = Self.hub()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try #require(OwnerAccessKey(seed: Data(repeating: 7, count: 32)))
        let route = Self.route(calls, [Self.refusedAnswer], key: key, folder: folder)
        let model = await CentralVaultModel(hub: hub)
        let record = MachineReach(address: "100.80.1.2", user: "root", port: 22)
        for _ in 0..<2 {
            #expect(try await model.hubTarget("hub-box", database: "view-test", record: record, status: { status },
                                              route: route) == InstallTarget(host: "100.80.1.2"))
        }
        #expect(calls.ssh.count == 2, "the second step within the wait opens no session of the route")
        let unknown = Calls(), other = await CentralVaultModel(hub: hub)
        let hostKey = LocalShell.Answer(status: 255, output: "Host key verification failed.\r\n")
        #expect(try await other.hubTarget("hub-box", database: "view-test", record: record, status: { status },
                                          route: Self.route(unknown, [hostKey], key: key, folder: folder))
                == InstallTarget(host: "100.80.1.2"))
        #expect(unknown.ssh.count == 1 && unknown.keyReads == 0)
        #expect(await MainActor.run { InstallTargets.target(machine: "hub-box", hub: hub) } == nil)
    }

    /// **Where root refuses the keys of a record of another user, or this Mac does not know the host key, nothing is
    /// kept, the step stops with the owner's own step, the other steps of the round open no SSH session, and a press of
    /// the owner's tries again at once** (`rootRoute`, `rootRouteStops`, `pressed`). Bugs: the stop says "Record one on
    /// its page in Servers", a page that has no field for the hub's own server (the owner's fault of 23 and 25 November
    /// 2026); a connection is kept after a refusal; each root step of a round logs in again, and the server's fail2ban
    /// shuts this Mac out; Try again shows the old words for 10 minutes and tries nothing; the owner access key goes to
    /// a host whose key this Mac does not know, and the words give no command to meet that key.
    @Test func whenRootRefusesNothingIsKeptAndTheWordsSayTheStep() async throws {
        _ = try await ViewHost.onMainLoop { 0 }
        let status = Self.status, folder = try Self.folder(), hub = Self.hub()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try #require(OwnerAccessKey(seed: Data(repeating: 7, count: 32)))
        let record = MachineReach(address: "100.80.1.2", user: "fleet", port: 22)
        let refused = Calls()
        let route = Self.route(refused, [Self.refusedAnswer], key: key, folder: folder)
        let model = await CentralVaultModel(hub: hub)
        let step = HubRootRoute.refused("hub-box", target: InstallTarget(host: "100.80.1.2"))
        for _ in 0..<2 {
            #expect(await Self.stop { try await model.hubTarget("hub-box", database: "view-test", record: record,
                                                                status: { status }, route: route) } == step)
        }
        #expect(refused.ssh.count == 2 && refused.keyReads == 1, "the second step within the wait opens no session")
        await model.pressed()
        #expect(await Self.stop { try await model.hubTarget("hub-box", database: "view-test", record: record,
                                                            status: { status }, route: route) } == step)
        #expect(refused.ssh.count == 4, "a press of the owner's tries again at once")
        let unknown = Calls(), other = await CentralVaultModel(hub: Self.hub())
        let hostKey = LocalShell.Answer(status: 255, output: "No ED25519 host key is known for 100.80.1.2.\r\nHost key verification failed.\r\n")
        let words = await Self.stop { try await other.hubTarget("hub-box", database: "view-test", record: record,
                                                                status: { status },
                                                                route: Self.route(unknown, [hostKey], key: key, folder: folder)) }
        #expect(words?.contains("run ssh root@100.80.1.2 once") == true)
        #expect(unknown.ssh.count == 1 && unknown.keyReads == 0)
        #expect(await MainActor.run { InstallTargets.target(machine: "hub-box", hub: hub) } == nil)
    }

    /// **The route connects to the node's own address and reads the host key where this Mac's `known_hosts` has it for
    /// that node: the address's line, else the line of the node's whole name in this Mac's own Tailscale**
    /// (`HubRootRoute.hostKeyName`, `InstallTarget.hostKeyName`; the Vault area's read of 1f5e0c113 and the Door area's):
    /// a key that the owner's `ssh` met under the MagicDNS name opens the route and the install after it, and a key met
    /// under the node's address does too, also where the record is a name. Bugs: a Mac that knows the key only under the
    /// node's address (an earlier install, or the route's own `ssh root@<address>`) stops where the record is a name; the route reads the key under the node's address alone, which the
    /// owner's `known_hosts` does not hold, so the tester's hub falls back to the owner's keys and "Permission denied"
    /// again; the kept connection forgets the name, so the install right after the route stops at the host key.
    @Test func theRouteReadsTheHostKeyWhereThisMacKnowsIt() async throws {
        _ = try await ViewHost.onMainLoop { 0 }
        let status = Self.status, folder = try Self.folder(), name = "hub-box.tail1234.ts.net"
        defer { try? FileManager.default.removeItem(at: folder) }
        let cases: [(record: String, line: String, alias: String?)] = [("hub-box", name, name), (name, "100.80.1.2", nil),
                                                                       ("100.80.1.2", "100.80.1.2", nil)]
        for (record, line, alias) in cases {
            let calls = Calls(), hub = Self.hub()
            let route = Self.route(calls, [], folder: folder, run: Self.knownHosts(calls, line), known: [line])
            let model = await CentralVaultModel(hub: hub)
            let target = try await model.hubTarget("hub-box", database: "view-test", record: MachineReach(
                address: record, user: "root", port: 22), status: { status }, route: route)
            let root = InstallTarget(host: "100.80.1.2", user: "root", port: 22, identityFile: route.appKey, hostKeyName: alias)
            #expect(target == root && calls.ssh.count == 1, "\(line)")
            #expect(await MainActor.run { InstallTargets.target(machine: "hub-box", hub: hub) } == root, "\(line)")
            // the install's own `ssh` reads the same line
            let install = CentralVaultRemote.arguments(target: target, program: "true", ledger: route.ledger)
            #expect(try await Self.knownHosts(Calls(), line)("/usr/bin/ssh", install, nil, 60) == Self.rootAnswer, "\(line)")
        }
    }

    /// **A first label is never the name under which the route reads the host key, and where this Mac knows neither the
    /// node's address nor its whole name the words give `ssh root@<the node's address>`** (`HubRootRoute.hostKeyName`;
    /// the Door area's read of 25 November 2026). Bug: the route reads the key of the record's string, a short label
    /// whose line in `known_hosts` can belong to another machine, and keeps root's connection on that word.
    @Test func aFirstLabelIsNeverTheHostKeyName() async throws {
        _ = try await ViewHost.onMainLoop { 0 }
        let status = Self.status, folder = try Self.folder(), hub = Self.hub(), calls = Calls()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = await CentralVaultModel(hub: hub)
        let words = await Self.stop { try await model.hubTarget("hub-box", database: "view-test", record: MachineReach(
            address: "hub-box", user: "fleet", port: 22), status: { status },
            route: Self.route(calls, [], folder: folder, run: Self.knownHosts(calls, "hub-box"), known: ["hub-box"])) }
        #expect(words?.contains("run ssh root@100.80.1.2 once") == true && calls.ssh.count == 1)
        #expect(calls.ssh.first?.contains("HostKeyAlias=hub-box") == false)
        #expect(await MainActor.run { InstallTargets.target(machine: "hub-box", hub: hub) } == nil)
    }

    /// **The install has a way to the hub's machine with the record's address alone** (`CentralVaultModel.hubOnRecord`),
    /// where the root route tries root. Bug: a hub whose record names an address and no user plans no install, so the
    /// route never runs for it.
    @Test func theInstallHasAWayWithTheRecordsAddressAlone() {
        func own(_ address: String?, _ user: String?) -> VaultHub {
            VaultHub(machine: "hub-box", address: address, ssh: user.map { VaultHub.SSH(user: $0, port: 22) })
        }
        #expect(CentralVaultModel.hubOnRecord(own("100.80.1.2", nil), kept: false))
        #expect(CentralVaultModel.hubOnRecord(own("100.80.1.2", "fleet"), kept: false))
        #expect(CentralVaultModel.hubOnRecord(own(nil, nil), kept: true))
        #expect(!CentralVaultModel.hubOnRecord(own(nil, "root"), kept: false))
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
        // a record of root of a server that is not the hub offers the owner's own keys, as before the hub's root route:
        // owner mode, with no key file alone (the Vault area's review of 25 November 2026: bug, each root record offers
        // this Mac's own key alone, and a server whose root holds only the owner's personal key refuses each step)
        let owners = CentralVaultRemote.arguments(target: linux.target, program: "true", ledger: SSHKeyLedger())
        #expect(linux.target.identityFile == nil && !owners.contains("-i") && !owners.contains("IdentitiesOnly=yes")
                && !owners.starts(with: ["-F", "/dev/null"]))
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
