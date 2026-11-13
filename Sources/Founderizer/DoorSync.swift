import FleetCore
import Foundation
import Observation
import os

/// **The door's access file, kept by this Mac by itself** (owner feature `server_access`, DevOps plan C5 and D8).
///
/// The owner, 2 November 2026: "Yes, by business". Each business's DevOps agent holds every server of its business at
/// Fix, and nothing about it is on a page. The store's poll ticks this model, and about every five minutes it reads this
/// Mac's own Tailscale: the door is the one device with the door's tag, a server's business is its business tag, and a
/// business's DevOps agent is the one agent alone on the box with that business's operator tag (`DoorAccess`). When
/// those devices or their tags changed, or an hour went by, it reads the door's file over this Mac's own SSH, each
/// server's own parts and each operator box's agents, writes the file again through the door's root command when it
/// differs, and records each holding with the hub (`POST /ui/servers/grant`). Who operates never comes from the hub: the
/// tags are the owner's policy, and the Operator is the one agent's OS user on its box, so a hub bug names no Operator.
///
/// The owner, 6 November 2026 (DevOps D24): "Door, through the app". With owner feature `door_setup` the round also
/// keeps the rest of the door with no step of his (plan 13): it writes the door's entry in the fleet's configuration
/// when the hub has another address than this Mac's Tailscale (`POST /ui/door`), gives a door with no follow timer the
/// hub's release once, and writes the credentials that key cards asked for the door with the agents that use them
/// (`GET /ui/door`). An Operator's entry then takes the hub's name for the agent that its box shows (`HubDoor.name`).
///
/// What it could not do goes to the log and waits for the next round; no page shows it.
@MainActor @Observable
final class DoorSyncModel {
    private let hub: URL
    private(set) var working = false
    /// What the last round could not do, one line each, for the log.
    private(set) var problems: [String] = []
    private var lastRead: Date?
    private var lastRound: (key: String, at: Date)?
    /// The door said that it has its follow timer: it takes each release by itself, and this asks no more.
    private var followReady = false
    /// The door's code takes an entry for an agent that only gets its GitHub tokens (plan 13, item 4).
    private var tokensOnly = false
    /// The servers that did not answer this Mac's SSH or run a release that the door's install does not cover, with
    /// when: each is passed over for an hour (N8 (b)).
    private var skipped: [String: Date] = [:]
    private static let log = Logger(subsystem: "com.founderizer.app", category: "door")

    init(hub: URL) { self.hub = hub }

    /// Called from the store's poll on every page: Tailscale about every five minutes, the rest only on a change.
    func tick(store: FleetStore, now: Date = Date()) {
        guard !working, store.hub == hub, store.isFresh, store.state?.db != nil,
              store.state?.ui_features?.contains(ServerGrantCommand.feature) == true else { return }
        guard lastRead.map({ now.timeIntervalSince($0) >= 300 }) ?? true else { return }
        lastRead = now
        working = true
        Task {
            await round(store, now: now)
            working = false
        }
    }

    /// One round: read, decide, write, record. Each failure is one line in `problems`, and the round stops there.
    private func round(_ store: FleetStore, now: Date) async {
        guard let database = store.state?.db else { return }
        var said: [String] = []
        defer {
            problems = said
            for line in said { Self.log.notice("\(line, privacy: .public)") }
        }
        guard let devices = await Self.tailnet(), let door = DoorAccess.door(in: devices), let doorAddress = door.address else {
            return      // no door on this Mac's private network yet: nothing to keep
        }
        // owner feature door_setup (plan 13, items 1 and 3): the hub's entry follows the door that this Mac's Tailscale
        // shows, and the hub's view of the door's keys decides the round as the devices do
        let setup = store.state?.ui_features?.contains(DoorSetupClient.feature) == true
        var hubDoor: DoorAccess.HubDoor?
        if setup {
            do {
                let view = try await DoorSetupClient().view(hub: hub, database: database)
                hubDoor = view
                if view.door?.address != doorAddress {
                    do {
                        try await DoorSetupClient().save(hub: hub, database: database, client: store.installation,
                                                         address: doorAddress, port: view.door?.port ?? DoorAccess.doorPort)
                    } catch {
                        said.append("The hub did not take the door's address: \(Self.words(error))")
                    }
                }
            } catch {
                said.append("The hub's view of the door could not be read: \(Self.words(error))")
                return
            }
        }
        let key = Self.fingerprint(devices, database: database) + (hubDoor.map { "\n" + $0.digest } ?? "")
        if let last = lastRound, last.key == key, now.timeIntervalSince(last.at) < 3600 { return }

        let read = await ssh(door, address: doorAddress, DoorAccess.readProgram)
        guard let current = read.flatMap({ DoorAccess.file($0.output) }) else {
            said.append("The door's access file could not be read over SSH.")
            return
        }
        // plan 13, item 2: a door installed before its follow timer takes the hub's release once over this SSH; that
        // release's own update writes the timer, so a later round finds it, and the door then follows by itself
        if setup, !followReady, let entry = current["hub"] as? [String: Any], let hubAddress = entry["address"] as? String,
           let program = DoorAccess.followProgram(hub: hubAddress, port: entry["port"] as? Int ?? 8765) {
            if let answer = await ssh(door, address: doorAddress, program) {
                if answer.output.contains("follow=enabled") {
                    followReady = true
                } else {
                    said.append("The door took the hub's release once: \(answer.output.suffix(200))")
                }
            } else {
                said.append("The door did not take the hub's release, or SSH did not answer.")
            }
        }
        var facts = DoorAccess.Facts(devices: devices, hub: hubDoor)
        let byName = Dictionary(devices.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for name in DoorAccess.servers(access: current, devices: devices).keys.sorted() {
            guard let device = byName[name], let address = device.address else { continue }
            let answer = await ssh(device, address: address, DoorAccess.hostProgram)
            if let answer, let reading = DoorAccess.HostReading(output: answer.output) {
                facts.hosts[name] = reading
            } else if answer != nil {           // no second sshd runs there: its install stopped, or it was taken away
                facts.bare.insert(name)
                said.append("\(name) gave no key of its second sshd: its parts are not in place.")
            } else {
                said.append("\(name) gave no key of its second sshd: its parts are not in place, or SSH did not answer.")
            }
        }
        for (business, box) in DoorAccess.operatorBoxes(devices: devices).sorted(by: { $0.key < $1.key }) {
            guard let box, let address = box.address else { facts.operators[business] = .some(nil); continue }
            // A box that did not answer leaves its business as the file has it, until it does.
            guard let answer = await ssh(box, address: address, DoorAccess.boxProgram) else {
                said.append("The operator box \(box.name) did not answer over SSH.")
                continue
            }
            let agent = DoorAccess.operatorAgent(users: DoorAccess.boxUsers(output: answer.output))
            facts.operators[business] = .some(agent.map { DoorAccess.Operator(agent: $0, address: address) })
            if agent == nil { said.append("\(box.name) holds no one agent's OS user alone: it operates nothing.") }
        }

        // owner feature door_calls: the door checks the owner's signed yes against this Mac's owner key and the fleet
        if store.state?.ui_features?.contains(DoorCallSigning.feature) == true,
           let fleet = try? await VaultClient().reading(hub: hub, database: database)?.fleetID,
           let owner = OwnerKeychain.key(fleet: fleet) {
            facts.owner = DoorAccess.OwnerPin(key: owner.publicKey, fleet: fleet)
        }
        // plan 13, item 4: the agents' GitHub grants, and the move of the hub's App key, wait for door code that takes
        // an entry for an agent that only gets its tokens
        if setup, !tokensOnly, let probe = await ssh(door, address: doorAddress, DoorAccess.tokensProbe),
           probe.output.contains("tokens=yes") {
            tokensOnly = true
        }
        facts.tokensOnly = tokensOnly
        // plan 13, items 3 and 4: the hub seals a key for the door only to the key pinned under door, so the door's own
        // is pinned first (6 November 2026: none was, and no key of the door's ever reached it)
        if setup, let view = hubDoor {
            await pinDoor(store, view: view, door: door, doorAddress: doorAddress, database: database, said: &said)
        }
        var base = current
        if setup, tokensOnly, let view = hubDoor,
           let moved = await moveGitHub(store, view: view, current: current, devices: devices, door: door,
                                        doorAddress: doorAddress, database: database, said: &said) {
            base = moved
        }
        // new-projects plan N8 (b): the door's parts on one more server, the canary first (API 1.100). While a server
        // is between its install and its check, the next round runs in full, so each step follows in a round.
        var placing = false
        if setup, let view = hubDoor {
            placing = await placeParts(store, view: view, current: current, facts: facts, devices: devices, door: door,
                                       doorAddress: doorAddress, database: database, said: &said)
        }
        let plan = DoorAccess.plan(current: base, facts: facts)
        if plan.file != DoorAccess.canonical(current) {
            guard let written = await ssh(door, address: doorAddress, DoorAccess.writeProgram, stdin: plan.file), written.ok else {
                said.append("The door refused the new access file, or SSH did not answer. Nothing was recorded.")
                return
            }
        }
        var recorded = Self.recorded(hub: hub, database: database)
        for change in DoorAccess.changes(wanted: plan.holdings, recorded: recorded) {
            do {
                try await ServerGrantClient().grant(hub: hub, database: database, client: store.installation, agent: change.agent,
                                                    server: change.server, level: change.level)
                recorded[change.agent, default: [:]][change.server] = change.level
                if recorded[change.agent]?.isEmpty == true { recorded[change.agent] = nil }
            } catch {
                said.append("The hub did not record \(change.server) for \(change.agent): \(Self.words(error))")
            }
        }
        Self.keep(recorded, hub: hub, database: database)
        if said.isEmpty && !placing { lastRound = (key, now) }
    }

    /// The door's parts on a business's servers, one step a round (`DoorHosts.next`): the door's check of a server
    /// that got them (test 1, as code), or the install of the next one, the canary first and the others after the
    /// manager's `door_rollout`. A failure stops it at that server until a new build of the app or a new release of the
    /// door, with no clock, and the hub hears of each outcome. A server that does not answer, or runs a release that the
    /// install does not cover, is passed over for an hour; the canary is waited for.
    /// True while a server is between its install and its check, so that the next round runs in full.
    @discardableResult
    private func placeParts(_ store: FleetStore, view: DoorAccess.HubDoor, current: [String: Any], facts: DoorAccess.Facts,
                            devices: [DoorAccess.Device], door: DoorAccess.Device, doorAddress: String, database: String,
                            said: inout [String]) async -> Bool {
        guard let rollout = view.rollout,
              let fleet = try? await HubClient().servers(hub: hub, database: database).servers.map(\.name) else { return false }
        var state = DoorHosts.State.read(hub: hub, database: database)
        defer { state.save(hub: hub, database: database) }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        func revision() async -> String {
            await ssh(door, address: doorAddress, DoorHosts.revisionProgram)?.output
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
        }
        func report(_ host: String, _ outcome: String, _ words: String) async {
            do {
                try await DoorSetupClient().hostReport(hub: hub, database: database, client: store.installation, host: host,
                                                       state: outcome, said: words)
            } catch {
                said.append("The hub did not take the word about \(host): \(Self.words(error))")
            }
        }
        if let stop = state.stop {
            let running = await revision()
            guard stop.app != build || stop.door != running else {
                said.append("The door's parts go on no further server: \(stop.host): \(stop.reason)")
                return false
            }
            state.stop = nil            // a new build of the app or release of the door: that server is tried again
            state.hosts[stop.host] = nil
        }
        let now = Date()
        skipped = skipped.filter { now.timeIntervalSince($0.value) < 3600 }
        let order = DoorHosts.order(access: current, devices: devices, fleet: Set(fleet), heldOut: view.heldOut)
        // a host with no second sshd running leaves the door's file this round, so a canary whose install stopped
        // stays the canary (7 November 2026: the next host became one, because the stopped install had made its key)
        let inFile = Set((current["hosts"] as? [String: Any] ?? [:]).keys).subtracting(facts.bare)
        switch DoorHosts.next(order: order, state: state, inFile: inFile, answered: Set(facts.hosts.keys), rollout: rollout,
                              skipped: Set(skipped.keys)) {
        case .wait:
            return state.hosts.values.contains("installed")
        case .probe(let host):
            guard let program = DoorHosts.probeProgram(host: host),
                  let answer = await ssh(door, address: doorAddress, program, always: true),
                  let result = DoorHosts.probe(answer.output, host: host) else {
                said.append("The door's check of \(host) gave no answer.")
                return false
            }
            if result.passed {
                state.hosts[host] = "passed"
                Self.log.notice("\(host, privacy: .public) has the door's parts, and the door's check of it passed.")
                await report(host, "passed", "")
            } else {
                let reason = "the door's check failed: " + result.failed.joined(separator: ", ")
                state.stop = .init(host: host, reason: reason, app: build, door: await revision())
                await report(host, "failed", reason)
            }
            return true
        case .install(let host):
            guard let device = devices.first(where: { $0.name == host }), let address = device.address else { return false }
            guard let read = await ssh(device, address: address, DoorHosts.releaseProgram),
                  let release = DoorHosts.release(read.output) else {
                skipped[host] = now
                said.append("\(host) did not answer this Mac's SSH as root: it gets the door's parts when it does.")
                return false
            }
            guard DoorHosts.covered.contains(release) else {
                skipped[host] = now
                said.append("\(host) runs \(release), a release that the door's install does not cover.")
                return false
            }
            guard let given = await ssh(door, address: doorAddress, DoorHosts.bundleProgram),
                  let bundle = DoorHosts.Bundle(output: given.output) else {
                said.append("The door gave no bundle of its parts for \(host).")
                return false
            }
            let mode = (DoorAccess.servers(access: current, devices: devices)[host]?.count ?? 0) > 1 ? "rule-only" : "fix"
            guard let program = DoorHosts.installProgram(mode: mode, doorKey: bundle.doorKey) else { return false }
            let answer = await ssh(device, address: address, program, stdin: Data(bundle.tar.utf8))
            if let answer, answer.ok, answer.output.contains("host-key: ssh-ed25519 ") {
                state.hosts[host] = "installed"
                Self.log.notice("\(host, privacy: .public) has the door's parts now; the door checks it next.")
                await report(host, "installed", "")
            } else {
                let last = answer?.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "SSH did not answer"
                let reason = "the install stopped: \(last.prefix(300))"
                state.stop = .init(host: host, reason: reason, app: build, door: bundle.revision)
                await report(host, "failed", reason)
            }
            return true
        }
    }

    /// The door's own vault key, read over this Mac's SSH to the door that its Tailscale shows, pinned in the central
    /// vault under the name door with the owner's signed statement, as a fleet machine's key is pinned
    /// (`CentralVaultSection.trust`), when the hub reads the central vault and it holds another key there or none.
    private func pinDoor(_ store: FleetStore, view: DoorAccess.HubDoor, door: DoorAccess.Device, doorAddress: String,
                         database: String, said: inout [String]) async {
        guard view.vault_read == true else { return }
        guard let answer = await ssh(door, address: doorAddress, DoorAccess.recipientProgram),
              let recipient = DoorAccess.recipient(answer.output) else {
            said.append("The door's vault key could not be read over SSH.")
            return
        }
        guard view.needsPin(of: recipient) else { return }
        do {
            guard let fleet = try await VaultClient().reading(hub: hub, database: database)?.fleetID,
                  let key = OwnerKeychain.key(fleet: fleet) else {
                throw DoorKeys.Stop("Founderizer has no current status of the central vault, or no owner key for this fleet.")
            }
            let statement = OwnerStatement.pin(fleet: fleet, machine: DoorAccess.holder, recipient: recipient)
            _ = try await VaultClient().pin(hub: hub, database: database, client: store.installation, statement: statement,
                                            signature: key.sign(statement))
            Self.log.notice("The door's vault key is pinned in the central vault, so the door gets the keys it holds.")
        } catch {
            said.append("The door's vault key was not pinned: \(Self.words(error))")
        }
    }

    /// Plan 13, item 4 (the coordinator, 6 November 2026: move the key that the hub holds, with no new key and no file
    /// choice): the hub's own GitHub App key goes to the door, and then the hub gets every GitHub token from the door.
    /// One step a round. First the key: read over this Mac's own SSH to the hub machine, proved with GitHub, given to
    /// the door as the GitHub App rows' Save gives one (`DoorKeys.put`, with the owner's grant that this Mac signs), and
    /// named in the door's file for each account that the App is installed on. The key is in memory for this call only.
    /// Then, once the door holds its sealed copy, the hub's two secrets, which the door makes and the hub keeps only
    /// when the door mints for every owner: the hub then removes its own copy. Gives the door's file with the key in it,
    /// when this round put the key there. A round that failed after the hub step tries again under the same reference
    /// (`DoorKeyReference`) until the door's file names the App, so a failed round leaves no second catalog entry.
    private func moveGitHub(_ store: FleetStore, view: DoorAccess.HubDoor, current: [String: Any], devices: [DoorAccess.Device],
                            door: DoorAccess.Device, doorAddress: String, database: String,
                            said: inout [String]) async -> [String: Any]? {
        guard let app = view.github_app, view.linked != true else { return nil }
        let held = DoorAccess.gitHubApps(current).filter { $0.appID == app.app_id }
        guard let first = held.first else {
            guard let host = hub.host, app.path.range(of: "^/[A-Za-z0-9._/-]{1,200}$", options: .regularExpression) != nil else {
                return nil
            }
            let device = devices.first { $0.address == host } ?? DoorAccess.Device(name: "hub", address: host, tags: [])
            guard let read = await ssh(device, address: host, "cat -- '\(app.path)'") else {
                said.append("The hub's GitHub App key could not be read over SSH.")
                return nil
            }
            let parts = read.output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "app_id=\(app.app_id)" else {
                said.append("The hub's GitHub App file is not the one that the hub names.")
                return nil
            }
            let pem = String(parts[1])
            do {
                let found = try await GitHubAppKey.app(appID: app.app_id, pem: pem)
                let owners = try await GitHubAppKey.installations(appID: app.app_id, pem: pem)
                let login = try await DoorKeys.put(GitHubAppKey.vaultValue(pem),
                                                   variable: GitHubAppKey.variable(owner: found.owner.login), store: store,
                                                   reference: DoorKeyReference.take(hub: hub, database: database,
                                                                                    app: app.app_id))
                var file = current
                for owner in owners.isEmpty ? [found.owner.login] : owners {
                    file = DoorAccess.withGitHubApp(file, owner: owner, login: login, appID: app.app_id)
                }
                return file
            } catch {
                said.append("The hub's GitHub App key did not go to the door: \(Self.words(error))")
                return nil
            }
        }
        DoorKeyReference.done(hub: hub, database: database, app: app.app_id)
        guard let program = DoorAccess.heldProgram(login: first.login),
              let answer = await ssh(door, address: doorAddress, program), answer.output.contains("held=yes") else {
            said.append("The door does not hold the GitHub App key yet: the hub links after it does.")
            return nil
        }
        guard let made = await ssh(door, address: doorAddress, DoorAccess.hubSecretsProgram),
              let object = try? JSONSerialization.jsonObject(with: Data(made.output.utf8)) as? [String: Any],
              let token = object["token"] as? String, let record = object["record"] as? String else {
            said.append("The door did not make the hub's two secrets.")
            return nil
        }
        do {
            try await DoorSetupClient().link(hub: hub, database: database, client: store.installation, token: token, record: record)
            Self.log.notice("The hub gets every GitHub token from the door now, and it holds no App key of its own.")
        } catch {
            said.append("The hub did not take the door's two secrets: \(Self.words(error))")
        }
        return nil
    }

    /// The owner saved a GitHub App's key, which the door now holds: the door's file names it for that owner.
    func addGitHubApp(owner: String, login: String, appID: String) async -> String? {
        guard let devices = await Self.tailnet(), let door = DoorAccess.door(in: devices), let address = door.address else {
            return String(l10n: "This Mac's Tailscale shows no door.")
        }
        guard let read = await ssh(door, address: address, DoorAccess.readProgram), let current = DoorAccess.file(read.output) else {
            return String(l10n: "The door's access file could not be read over SSH.")
        }
        let file = DoorAccess.canonical(DoorAccess.withGitHubApp(current, owner: owner, login: login, appID: appID))
        guard let written = await ssh(door, address: address, DoorAccess.writeProgram, stdin: file), written.ok else {
            return String(l10n: "The door did not take its new access file.")
        }
        lastRound = nil
        return nil
    }

    /// The door's device on this Mac's own Tailscale, or nil.
    static func door() async -> DoorAccess.Device? {
        guard let devices = await tailnet() else { return nil }
        return DoorAccess.door(in: devices)
    }

    /// This Mac's own Tailscale: every device, or nil when it does not answer.
    private static func tailnet() async -> [DoorAccess.Device]? {
        guard let status = await MacNetwork.status() else { return nil }
        let devices = DoorAccess.devices(status: status)
        return devices.isEmpty ? nil : devices
    }

    /// One program as root on a device, over this Mac's own SSH, at the address that this Mac's Tailscale gives it.
    /// A connection that the app keeps for that machine gives its user, port and key; else root with the key files of
    /// the owner's `~/.ssh/config` and one key of the app's kept root connections (`DoorAccess.LoginKeys`). A host key this Mac does not know stops it
    /// (StrictHostKeyChecking=yes). A device that refused the login gets no try for an hour, or until its line in the
    /// fingerprint changes (`DoorAccess.Refusals`). nil when SSH did not answer.
    private func ssh(_ device: DoorAccess.Device, address: String, _ program: String, stdin: Data? = nil,
                     always: Bool = false) async -> LocalShell.Answer? {
        let kept = InstallTargets.target(machine: device.name, hub: hub)
        // a device with no kept connection: one key that this Mac already uses for root, besides ~/.ssh/config's
        let extra = kept == nil ? DoorAccess.LoginKeys.read(hub: hub).key(for: device, candidates: InstallTargets.rootKeys(hub: hub))
            : nil
        guard !DoorAccess.Refusals.read(hub: hub).waits(device, now: Date()),
              let arguments = DoorAccess.sshArguments(kept: kept, address: address, program: program, key: extra),
              let answer = try? await LocalShell.run("/usr/bin/ssh", arguments, stdin: stdin, timeout: 120) else { return nil }
        let refused = DoorAccess.loginRefused(status: answer.status, output: answer.output)
        if refused, let extra {
            var keys = DoorAccess.LoginKeys.read(hub: hub)
            keys.refused(device, key: extra)
            keys.save(hub: hub)
        }
        var refusals = DoorAccess.Refusals.read(hub: hub)     // read again: another call may have noted one meanwhile
        if refused || refusals.at[DoorAccess.line(device)] != nil {
            refusals.note(device, refused: refused, now: Date())
            refusals.save(hub: hub)
        }
        if refused {
            Self.log.notice("\(device.name, privacy: .public) refused this Mac's SSH login: no try for an hour, or until it changes.")
        }
        return answer.ok || stdin != nil || always ? answer : nil
    }

    /// What decides whether a round must read the servers again: the devices of the private network with their
    /// addresses and tags, which give the servers and the operator boxes.
    private static func fingerprint(_ devices: [DoorAccess.Device], database: String) -> String {
        ([database] + devices.map(DoorAccess.line)).joined(separator: "\n")
    }

    // MARK: what the hub recorded

    private static func name(_ hub: URL, _ database: String) -> String { "doorHoldings|\(hub.absoluteString)|\(database)" }

    static func recorded(hub: URL, database: String, in defaults: UserDefaults = .standard) -> [String: [String: String]] {
        defaults.dictionary(forKey: name(hub, database)) as? [String: [String: String]] ?? [:]
    }

    static func keep(_ holdings: [String: [String: String]], hub: URL, database: String, in defaults: UserDefaults = .standard) {
        defaults.set(holdings, forKey: name(hub, database))
    }

    private static func words(_ error: Error) -> String {
        HubError.said(error) ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
