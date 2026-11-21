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
    /// The hub's `door_grant_waits` that the last round started with (`DoorAccess.roundDue`).
    private var grantActed: Double?
    /// The last round with no problem; `whole`: its plan held every agent's GitHub grants (`Plan.leftOut`, API 1.234).
    private var lastRound: (key: String, at: Date, whole: Bool)?
    /// The door said that it has its follow timer: it takes each release by itself, and this asks no more.
    private var followReady = false
    /// The door's code takes an entry for an agent that only gets its GitHub tokens (plan 13, item 4).
    private var tokensOnly = false
    /// The door's release installs a machine of the fleet (`install.sh --fleet`, API 1.210).
    private var fleetInstall = false
    /// The door's check takes `--first` (API 1.241, `DoorAccess.firstProbe`).
    private var probeFirst = false
    /// The servers that did not answer this Mac's SSH or run a release that the door's install does not cover, with
    /// when: each is passed over for an hour (N8 (b)).
    private var skipped: [String: Date] = [:]
    /// The mark of the newest view of the hub whose plan the door's file holds (API 1.234): a round of this app wrote
    /// the file from that view, or found it so, with every agent's grants. Each read of the hub's view says it, and
    /// only that word ends the hub's wait for a new grant, so a read that wrote nothing ends none.
    private var held: String?
    /// The writes of the door's file outside a round (`addGitHubApp`): a round during which one came vouches for no file.
    private var outsideWrites = 0
    private static let log = Logger(subsystem: "com.founderizer.app", category: "door")

    init(hub: URL) { self.hub = hub }

    /// Called from the store's poll on every page: Tailscale about every five minutes, the rest only on a change.
    func tick(store: FleetStore, now: Date = Date()) {
        guard !working, store.hub == hub, store.isFresh, store.state?.db != nil,
              store.state?.ui_features?.contains(ServerGrantCommand.feature) == true else { return }
        // About every five minutes, and once at once for each new grant that the door may not hold yet (roundDue)
        let waits = store.state?.door_grant_waits
        guard DoorAccess.roundDue(lastRead: lastRead, now: now, grantWaits: waits, acted: grantActed) else { return }
        lastRead = now
        if waits != nil { grantActed = waits }      // this round reads that grant: no second early round for it
        working = true
        Task {
            let before = held
            await round(store, now: now)
            // a round that changed what the door's file holds says so at once, with one more read of the hub's view: a
            // restart that waits for a new grant then starts at the end of this round, not at the next one's read. A
            // read that fails changes nothing: the next round's read says it.
            if let held, held != before, let database = store.state?.db {
                _ = try? await DoorSetupClient().view(hub: hub, database: database, held: held)
            }
            working = false
        }
    }

    /// One round: read, decide, write, record. Each failure is one line in `problems`, and the round stops there.
    private func round(_ store: FleetStore, now: Date) async {
        guard let database = store.state?.db else { return }
        let writes = outsideWrites
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
                let view = try await DoorSetupClient().view(hub: hub, database: database, held: held ?? "")
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
        if let last = lastRound, last.key == key, now.timeIntervalSince(last.at) < 3600 {
            // the door's file holds what the last full round wrote, since no write came after it (a write clears
            // lastRound), and this view gives the same grants (API 1.234)
            if last.whole, let mark = hubDoor?.mark { held = mark }
            return
        }

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
        // the fleet's own servers (API 1.210) are read as a business's servers are: each one's own parts
        let fleetServers = DoorAccess.fleetServers(access: current, devices: devices, hub: hubDoor)
        for name in DoorAccess.servers(access: current, devices: devices).keys.sorted() + fleetServers {
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

        facts.fleetHolder = await fleetHolder(hubDoor, devices: devices, operators: facts.operators, said: &said)
        // owner feature door_calls: the door checks the owner's signed yes against this Mac's owner key and the fleet
        if store.state?.ui_features?.contains(DoorCallSigning.feature) == true,
           let fleet = try? await VaultClient().reading(hub: hub, database: database)?.fleetID,
           let owner = OwnerKeychain.key(fleet: fleet) {
            facts.owner = DoorAccess.OwnerPin(key: owner.publicKey, fleet: fleet)
        }
        // plan 13, item 4: the agents' GitHub grants, and the move of the hub's App key, wait for door code that takes
        // an entry for an agent that only gets its tokens
        if setup, !tokensOnly {
            if let probe = await ssh(door, address: doorAddress, DoorAccess.tokensProbe) {
                tokensOnly = probe.output.contains("tokens=yes")
            } else {        // a problem, so the next round runs in full and asks again (API 1.234)
                said.append("The door did not say whether it takes an entry for an agent that only gets its tokens: SSH did not answer.")
            }
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
        // an agent that this round found for the fleet's own servers, and that the plan gave none of them: its entry
        // in the door's file holds more than the fleet's servers at another address (the log only, no page)
        if case .agent(let found) = facts.fleetHolder, !fleetServers.isEmpty,
           !fleetServers.contains(where: { plan.holdings[found.agent]?[$0] != nil }),
           fleetServers.contains(where: { facts.hosts[$0]?.fleet == true }) {
            Self.log.notice("\(found.agent, privacy: .public) holds none of the fleet's own servers: the door's file has it at another address with more than those servers, or at the hub's or the door's address.")
        }
        if plan.file != DoorAccess.canonical(current) {
            // the Save of a GitHub App's key wrote the door's file after this round read it: this plan would take that
            // App's entry away, so the next round, which runs in full, writes from the file as it is now
            guard outsideWrites == writes else {
                said.append("The door's access file changed during this round: the next round writes it.")
                return
            }
            // the door's file changes now, and a write whose answer is lost may have landed: nothing vouches for a file
            // until this write answers, and no early return until a round with no problem
            lastRound = nil
            held = nil
            guard let written = await ssh(door, address: doorAddress, DoorAccess.writeProgram, stdin: plan.file), written.ok else {
                said.append("The door refused the new access file, or SSH did not answer. Nothing was recorded.")
                return
            }
        }
        // the door's file holds what this view gives (API 1.234), unless the plan left an agent's grants out or the
        // Save of a GitHub App's key wrote the file while this round ran
        if outsideWrites == writes, plan.leftOut.isEmpty, let mark = hubDoor?.mark { held = mark }
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
        if said.isEmpty && !placing && outsideWrites == writes { lastRound = (key, now, plan.leftOut.isEmpty) }
    }

    /// **The agent that holds the fleet's own servers** (API 1.210; the owner, 17 November 2026): the hub's view and
    /// this round's Operators give a candidate (`DoorAccess.fleetCandidate`). One that is no Operator, the agent that
    /// the manager named or the manager itself, holds them only when the server at its address, a device of this Mac's
    /// own Tailscale, says that this one agent runs alone there, as an operator box says it. A server that did not
    /// answer leaves the holder as the door's file has it. Nothing of it shows on a page.
    private func fleetHolder(_ view: DoorAccess.HubDoor?, devices: [DoorAccess.Device],
                             operators: [String: DoorAccess.Operator?], said: inout [String]) async -> DoorAccess.FleetHolder {
        switch DoorAccess.fleetCandidate(hub: view, devices: devices, operators: operators) {
        case .keep: return .keep
        case .nobody: return .nobody
        case .agent(let found): return .agent(found)
        case .box(let agent, let address):
            guard let box = devices.first(where: { $0.address == address && !$0.tags.contains(DoorAccess.doorTag) }) else {
                return .nobody          // the hub names a server that this Mac's Tailscale does not show
            }
            guard let answer = await ssh(box, address: address, DoorAccess.boxProgram) else {
                said.append("\(box.name), the server of the agent for the fleet's own servers, did not answer over SSH.")
                return .keep
            }
            let found = DoorAccess.operatorAgent(users: DoorAccess.boxUsers(output: answer.output))
                .map { DoorAccess.Operator(agent: $0, address: address) }
            guard let found, view?.name(of: found) == agent else {
                Self.log.notice("\(box.name, privacy: .public) does not hold the one agent \(agent, privacy: .public) alone: it holds none of the fleet's own servers.")
                return .nobody
            }
            return .agent(DoorAccess.Operator(agent: agent, address: address))
        }
    }

    /// The door's parts on a business's servers, one step a round (`DoorHosts.next`): the door's check of a server
    /// that got them (test 1, as code), or the install of the next one, the canary first and the others after the
    /// manager's `door_rollout`. A failure stops it at that server until a new build of the app or a new release of the
    /// door, with no clock, and the hub hears of each outcome; then that server's check runs again. A check that makes
    /// no step (it stops at its first connection, gives no answer, or the door's file does not hold the server) sets no
    /// stop: from the third round in a row the hub hears why, as `unchecked`, once for each cause (API 1.241). A server
    /// that does not answer, or runs a release that the install does not cover, is passed over for an hour; the canary
    /// is waited for.
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
        @discardableResult
        func report(_ host: String, _ outcome: String, _ words: String) async -> Bool {
            do {
                try await DoorSetupClient().hostReport(hub: hub, database: database, client: store.installation, host: host,
                                                       state: outcome, said: words)
                return true
            } catch {
                said.append("The hub did not take the word about \(host): \(Self.words(error))")
                return false
            }
        }
        let now = Date()
        skipped = skipped.filter { now.timeIntervalSince($0.value) < 3600 }
        // the fleet's own servers come after every business's server (API 1.210), with the mark of a machine of the
        // fleet; one whose parts lack that mark has not answered, so it gets its install again
        var fleetServers = DoorAccess.fleetServers(access: current, devices: devices, hub: view)
        // only when the door's own release knows the mark: an older install script would stop at the option
        if !fleetServers.isEmpty, !fleetInstall {
            fleetInstall = await ssh(door, address: doorAddress, DoorAccess.fleetProbe)?.output.contains("fleet=yes") == true
        }
        if !fleetInstall { fleetServers = [] }
        let order = DoorHosts.order(access: current, devices: devices, fleet: Set(fleet), heldOut: view.heldOut,
                                    fleetServers: fleetServers)
        let unmarked = Set(fleetServers.filter { facts.hosts[$0]?.fleet == false })
        // such a server can have a state from an earlier install without the mark: it starts again
        for name in unmarked where state.hosts[name] != nil { state.hosts[name] = nil }
        // a host with no second sshd running leaves the door's file this round, so a canary whose install stopped
        // stays the canary (7 November 2026: the next host became one, because the stopped install had made its key)
        let inFile = Set((current["hosts"] as? [String: Any] ?? [:]).keys).subtracting(facts.bare).subtracting(unmarked)
        if let stop = state.stop {
            let running = await revision()
            guard stop.app != build || stop.door != running else {
                said.append("The door's parts go on no further server: \(stop.host): \(stop.reason)")
                return false
            }
            // a new build of the app or release of the door: that server's check runs again while the door's file holds
            // it, else its install (API 1.241)
            state.clearStop(holds: inFile)
        }
        switch DoorHosts.next(order: order, state: state, inFile: inFile,
                              answered: Set(facts.hosts.keys).subtracting(unmarked), rollout: rollout,
                              skipped: Set(skipped.keys)) {
        case .wait:
            // an installed server that the door's file does not hold makes no step either (API 1.241): the round after
            // its install is the normal one, and from the third the hub hears why, once for each cause
            if let host = order.first(where: { state.hosts[$0] == "installed" }), !inFile.contains(host) {
                let cause = DoorHosts.waitCause(host: host, bare: facts.bare, answered: Set(facts.hosts.keys))
                if let word = DoorHosts.noStep(host: host, cause: cause, state: &state) {
                    said.append("The door has not checked \(host) yet: \(word).")
                    if await report(host, "unchecked", word) { DoorHosts.reported(word, host: host, state: &state) }
                }
            }
            // only a server of the order: one that door_hold took out stays installed, and would hold every round in full
            return order.contains { state.hosts[$0] == "installed" }
        case .probe(let host):
            // only a door whose code takes --first gets it, so a door from before gives no refusal (API 1.241)
            if !probeFirst {
                probeFirst = await ssh(door, address: doorAddress, DoorAccess.firstProbe)?.output.contains("first=yes") == true
            }
            guard let program = DoorHosts.probeProgram(host: host, first: probeFirst) else { return false }
            let started = Date()
            let answer = await ssh(door, address: doorAddress, program, always: true)
            guard let answer, let result = DoorHosts.probe(answer.output, host: host), result.stopped == nil else {
                // no step (API 1.241): the check stopped at its first connection, or gave no answer. The server stays
                // installed and is checked again each round; from the third round in a row the hub hears why as
                // unchecked, once for each cause, and no stop is set
                let cause = DoorHosts.noStepCause(answer.flatMap { DoorHosts.probe($0.output, host: host) },
                                                  status: answer?.status,
                                                  timedOut: Date().timeIntervalSince(started) >= DoorHosts.probeWait - 5)
                said.append("The door's check of \(host) made no step: \(cause).")
                if let word = DoorHosts.noStep(host: host, cause: cause, state: &state),
                   await report(host, "unchecked", word) {
                    DoorHosts.reported(word, host: host, state: &state)
                }
                return false
            }
            DoorHosts.stepped(host: host, state: &state)
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
            // a machine of the fleet says so itself before it becomes a host: the hub only proposed it
            let ofFleet = fleetServers.contains(host)
            if ofFleet {
                guard let word = await ssh(device, address: address, DoorAccess.fleetProgram),
                      word.output.contains("fleet-machine=yes") else {
                    skipped[host] = now
                    said.append("\(host) does not say that it is a server of this fleet: it gets no door parts.")
                    return false
                }
            }
            let mode = ofFleet || (DoorAccess.servers(access: current, devices: devices)[host]?.count ?? 0) > 1
                ? "rule-only" : "fix"
            guard let program = DoorHosts.installProgram(mode: mode, doorKey: bundle.doorKey, fleet: ofFleet) else {
                return false
            }
            let started = Date()
            let answer = await ssh(device, address: address, program, stdin: Data(bundle.tar.utf8))
            if let answer, answer.ok, answer.output.contains("host-key: ssh-ed25519 ") {
                state.hosts[host] = "installed"
                Self.log.notice("\(host, privacy: .public) has the door's parts now; the door checks it next.")
                await report(host, "installed", "")
            } else {
                // fixed words only: the server prints all of the install's output, and the hub quotes this reason in
                // the manager's [hub] line (DoorHosts.installStop)
                let reason = DoorHosts.installStop(status: answer?.status, output: answer?.output ?? "",
                                                   timedOut: Date().timeIntervalSince(started) >= DoorHosts.probeWait - 5)
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
    /// the door as the GitHub App rows' Save gives one (`DoorKeys.putGitHubApp`, with the owner's grant that this Mac signs), and
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
            let listed = devices.first { $0.address == host }
            let device = listed ?? DoorAccess.Device(name: "hub", address: host, tags: [])
            guard let read = await ssh(device, address: host, "cat -- '\(app.path)'", byName: listed != nil) else {
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
                let login = try await DoorKeys.putGitHubApp(pem, owner: found.owner.login, store: store,
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
        guard let read = await ssh(door, address: address, DoorAccess.readProgram), var current = DoorAccess.file(read.output) else {
            return String(l10n: "The door's access file could not be read over SSH.")
        }
        // The successor of a key that works: the file names it only once the door holds its copy, so that the door
        // makes tokens with the old key until then. The copy comes at the door's next minute, so this asks up to 36
        // times, 5 seconds apart; a door that does not answer ends it at once. A save after that goes to the same
        // entry again (`GitHubAppKey.place`).
        if DoorAccess.namesOtherKey(current, appID: appID, login: login) {
            let notYet = String(l10n: "The door did not get the App. Try again.")
            guard let program = DoorAccess.heldProgram(login: login) else { return notYet }
            var holds = false
            for attempt in 1...36 {
                guard let answer = await ssh(door, address: address, program) else { return notYet }
                holds = answer.output.contains("held=yes")
                if holds { break }
                if attempt < 36 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            }
            guard holds else { return notYet }
            // A round can write the file while this waits: the write starts from the file of now, not from the read
            // of before the wait, which would put back what that round took out.
            guard let again = await ssh(door, address: address, DoorAccess.readProgram), let now = DoorAccess.file(again.output) else {
                return String(l10n: "The door's access file could not be read over SSH.")
            }
            current = now
        }
        let file = DoorAccess.canonical(DoorAccess.withGitHubApp(current, owner: owner, login: login, appID: appID))
        // Counted before the write: a round that read the file before then sees the count at its own write and does
        // not write its plan over this file, which named the old key again while the owner read that the door had
        // the new one.
        outsideWrites += 1
        guard let written = await ssh(door, address: address, DoorAccess.writeProgram, stdin: file), written.ok else {
            return String(l10n: "The door did not take its new access file.")
        }
        lastRound = nil
        held = nil      // this write began from a file that a round may have written after its read (API 1.234)
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
    /// the owner's `~/.ssh/config` and one key of the app's kept root connections (`DoorAccess.LoginKeys`), at the port
    /// that the owner's `~/.ssh/config` names for that device, else 22 (`DoorAccess.configured`; `byName` is false for
    /// a device that this Mac's Tailscale did not name). A host key this Mac does not know stops it
    /// (StrictHostKeyChecking=yes). A device that refused the login gets no try for an hour, or until its line in the
    /// fingerprint changes (`DoorAccess.Refusals`). nil when SSH did not answer.
    private func ssh(_ device: DoorAccess.Device, address: String, _ program: String, stdin: Data? = nil,
                     always: Bool = false, byName: Bool = true) async -> LocalShell.Answer? {
        guard !DoorAccess.Refusals.read(hub: hub).waits(device, now: Date()) else { return nil }
        let kept = InstallTargets.target(machine: device.name, hub: hub)
        // a device with no kept connection: the port and root's key that ~/.ssh/config gives that device, and one key
        // a try: that key first, then the keys that this Mac already uses for root, besides ~/.ssh/config's own
        let configured = kept == nil ? await DoorAccess.configured(device, address: address, byName: byName) : nil
        let extra = kept == nil ? DoorAccess.LoginKeys.read(hub: hub).key(
            for: device, candidates: DoorAccess.LoginKeys.candidates(configured: configured?.key,
                                                                     kept: InstallTargets.rootKeys(hub: hub))) : nil
        // a kept connection with the app's own key gets the gate of its app mode first (`SSHRun`); a device with none
        // is the owner's own, with today's arguments
        let reached = kept.flatMap { DoorAccess.sshTarget(kept: $0, address: address) }
        guard let arguments = DoorAccess.sshArguments(kept: kept, address: address, program: program, key: extra,
                                                      port: configured?.port ?? 22),
              let answer = try? await SSHRun.run(arguments, to: reached, stdin: stdin, timeout: 120) else { return nil }
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

    static func recorded(hub: URL, database: String, in defaults: UserDefaults = AppDefaults.store) -> [String: [String: String]] {
        defaults.dictionary(forKey: name(hub, database)) as? [String: [String: String]] ?? [:]
    }

    static func keep(_ holdings: [String: [String: String]], hub: URL, database: String, in defaults: UserDefaults = AppDefaults.store) {
        defaults.set(holdings, forKey: name(hub, database))
    }

    private static func words(_ error: Error) -> String {
        HubError.said(error) ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
