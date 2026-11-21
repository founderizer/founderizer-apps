#if os(macOS)
import Foundation

/// **The words of the list in which the owner chooses a server he has at a provider, or a new one** (the owner's yes
/// of 5 November 2026 to the list of existing servers and to the step that asks before a server is made). From what the
/// provider says of each server alone: the check of a chosen server says the rest, as for any other VPS.
extension CloudExisting {
    /// **Why this server cannot take an install of `job`**, in a few words, or nil when it can as far as its provider
    /// says. `fleet`: the names of the fleet's own servers, in lower case.
    ///
    /// **A server that Founderizer made, and that the hub's list does not have by its name**, says where it stands to
    /// this fleet only as far as `known` proves it (the owner's yes of 14 November 2026 to "Not in this fleet", after
    /// "Used by Founderizer" stood on a server that nothing used and on the fleet's own VPS alike, which the hub
    /// calls `hub` and its provider `worker-1`). With nothing known, and wherever the proof ends, the row keeps
    /// "Used by Founderizer": words that tell nobody that a server is free to delete.
    ///
    ///   - **"In your fleet"**: a device of this Mac's network that carries its name has an address of the fleet. The
    ///     fleet's own VPS is one, and so is a server that Tailscale gave a second name ("worker-2-1"). A device
    ///     carries a name by its name in Tailscale or by the name that it gave Tailscale itself.
    ///   - **"Not in this fleet"**: only a server for agents, and only when a device that carries its name is online on
    ///     this Mac's network and no device of that name has an address of the fleet: a machine of that name runs, and
    ///     the hub does not have it. Never a server with the label of a fleet's own VPS, and never one whose name
    ///     with Tailscale's number is a name of the fleet.
    ///
    /// **The link between a provider's server and a device is the name alone**, so the words are as true as the names.
    /// A server that never came to this Mac's network, and one whose owner changed its name at the provider or on the
    /// machine, has no device of its name and keeps the old words. A server of another project or provider that has
    /// the name of one of the fleet's devices says "In your fleet": the wrong words there are the safe ones. The one
    /// state that says "Not in this fleet" of a server of the fleet needs both at once: a new name that its owner
    /// gave it on the machine itself, and a second machine that runs outside the fleet under its old name.
    public func unfit(for job: InstallJob, fleet: Set<String>, known: FleetKnown? = nil) -> String? {
        let name = name.lowercased()
        if fleet.contains(name) { return String(l10n: "In your fleet") }
        if madeFor == CloudServerUse.hub.rawValue || madeFor == CloudServerUse.agent.rawValue {
            // A provider that takes a server with no name gives nothing to find a device by.
            guard let known, !name.isEmpty else { return String(l10n: "Used by Founderizer") }
            let carriers = known.devices.filter { $0.name == name || $0.host == name }
            if carriers.contains(where: { known.addresses.contains($0.address) }) { return String(l10n: "In your fleet") }
            let second = fleet.contains {
                $0.count > name.count + 1 && $0.hasPrefix(name + "-")
                    && $0.dropFirst(name.count + 1).allSatisfy { ("0"..."9").contains($0) }
            }
            // An offline device of the name can be what a deleted server left on the network: it proves nothing.
            guard madeFor == CloudServerUse.agent.rawValue, !second, carriers.contains(where: \.online) else {
                return String(l10n: "Used by Founderizer")
            }
            return String(l10n: "Not in this fleet")
        }
        if !running { return String(localized: "Off (a server)", defaultValue: "Off", bundle: Localized.bundle, locale: Localized.digits) }
        if ipv4 == nil { return String(l10n: "No IPv4 address") }
        let need = job == .hub ? ServerCheck.hubMemory : ServerCheck.agentMemory
        if let memoryMB, memoryMB < need.megabytes { return String(l10n: "\(Self.size(memoryMB)): too small") }
        if let system, let version, !Self.takes(job, system, version) {
            let name = (InstallPlan.systems(.hub) + InstallPlan.systems(.join)).first { $0.id == system }?.name
                ?? system.capitalized
            return job == .hub && Self.takes(.join, system, version) ? String(l10n: "\(name) \(version): not yet for a hub")
                : String(l10n: "\(name) \(version): not supported")
        }
        return nil
    }

    /// **What the fleet can do again with a server of the account that it holds already**, or nil when its row stays
    /// as it is (the owner's report of 14 November 2026: a new user's server was made, its install stopped, and from
    /// then on the list showed it grey, so the one press left made a second paid server). Only for a server for agents,
    /// and only from what the hub and this Mac say now:
    ///
    ///   - **It is in the fleet, free, and the hub offers it.** The hub offers a server from its first reading, which
    ///     comes right after the join and before the install's updates, firewall, hardening and checks. So a server
    ///     whose install this Mac did not see end (`finished`) gets the same install again, which repeats only what is
    ///     missing. One whose install it saw end goes to the agent that waits for its first server (`placing`), with
    ///     no install; with no such agent it is a server of the fleet and nothing more.
    ///   - **It joined the fleet and its server service never reported**: the same install again.
    ///   - **This Mac made it for this hub (`made`), the hub lists no server of its name or at its address, and it is
    ///     online on this Mac's network**: its install stopped before the join. The same install, at that address. The
    ///     provider's label alone is never enough: it names no fleet, so a working server of another fleet of the same
    ///     account would be taken out of that fleet.
    ///
    /// An install on a server of the hub's list always goes to the address that the hub itself has for it, and the hub
    /// takes the join of a server that it knows by its key as a repeat. `servers` is the hub's own list, read now: with
    /// none (nil) nothing can be said. `finished` and `made` hold names in lower case. A server that has an agent, the
    /// hub's own server, a server that reported before and is offline now, and one whose job runs are never taken here.
    public func reuse(for job: InstallJob, servers: [ServerEntry]?, devices: [FleetOnTailscale.Device],
                      finished: Set<String>, made: Set<String>, placing: Bool) -> CloudReuse? {
        guard job == .join, running, let servers else { return nil }
        let name = name.lowercased()
        if let entry = servers.first(where: { $0.name.lowercased() == name }) {
            guard !entry.hub, entry.agents.isEmpty, !entry.why.contains("busy") else { return nil }
            let address = entry.address ?? devices.first(where: { $0.name == name })?.address
            if AgentSetupFlow.isFree(entry) {
                guard finished.contains(name) else { return address.map { .install(address: $0) } }
                return placing ? .place(server: entry.name) : nil
            }
            guard entry.joined, entry.why.contains("no_reading"), let address else { return nil }
            return .install(address: address)
        }
        // The fleet's own VPS is never a server for agents, whatever name it has.
        guard made.contains(name), madeFor != CloudServerUse.hub.rawValue,
              let device = devices.first(where: { $0.name == name && $0.online }),
              !servers.contains(where: { $0.address == device.address }) else { return nil }
        return .install(address: device.address)
    }

    /// **The hub's install can run again on this server, in a first run's list of the fleet's own VPS**, or nil when
    /// its row stays as it is (the owner's report of 14 November 2026, of which `reuse` closed the half of a server
    /// for agents: a hub's server that this Mac made, and whose install stopped, stood grey in that list, so the one
    /// press left made a second paid server). Only from what this Mac kept and sees now:
    ///
    ///   - **This Mac made it for a hub**: a record of its own build names it by the provider's own id, at this
    ///     provider (`BuildRecord`; the newest one). The provider's label alone is never enough: it names no Mac and
    ///     no fleet.
    ///   - **Its provider says that it runs.**
    ///   - **It is online on this Mac's network now**, as a device that carries the name of that build. For a build
    ///     that this Mac saw join, the device has the address of that join (`BuildRecord.hub`). A build that stopped
    ///     before has only its name, which a later try can take too (a new server gets a name that no device has, and
    ///     a server that is not on the network yet has left its name free). So such a build counts only when the
    ///     private network's own list had its server at the build's end (`BuildRecord.onNetwork`: a rule of the
    ///     network kept it from this Mac), exactly one device carries the name now, and no other build of this Mac has
    ///     that name, whatever that build left at its provider.
    ///   - **Its address is none of `except`**: the hub that the app is connected to, a hub that "Start again" left
    ///     alive (`StartAgain.LeftHubs`), and a hub that answered there and refused this Mac when the page asked it.
    ///
    /// The install goes to that address, as root with this Mac's own key, as the build's own end sends it: a server
    /// that the app made has no way in at its public address. **A second run of the hub's installer destroys
    /// nothing** (`hub.sh`: "every step checks first, nothing is destroyed"): each step runs again and checks first,
    /// so an install that stopped goes on. On a hub that has its owner the installer makes no code and leaves the
    /// team as it is, and it starts the hub's services and the agents of that server again. When that hub serves
    /// this Mac, the install's wait for the code ends and the plan goes on with no code
    /// (`InstallStep.Action.waitForClaim`).
    /// **The second run gets the choices that the first run's pages have now** (the manager's name, the step of the
    /// fleet's servers, the AI program). A hub that has its owner keeps the manager's name and the step of its claim.
    /// One fault of the installer stands there: a run without the word for one server for all, on a hub whose claim
    /// wrote that word, skips the installer's two steps of it (`hub_word` in hub.sh, the installer's lane's).
    public func hubAgain(at provider: CloudProvider, builds: [BuildRecord], devices: [FleetOnTailscale.Device],
                         except: Set<String> = []) -> CloudReuse? {
        guard running, CloudServers.isID(id),
              let build = builds.filter({ $0.use == .hub && $0.provider == provider && $0.serverID == id })
                  .max(by: { ($0.began, $0.id.uuidString) < ($1.began, $1.id.uuidString) }) else { return nil }
        let name = build.name.lowercased()
        guard !name.isEmpty else { return nil }
        let carriers = devices.filter { $0.online && ($0.name == name || $0.host == name) }
        let device: FleetOnTailscale.Device?
        if let joined = build.hub {
            guard let address = URL(string: joined)?.host else { return nil }
            device = carriers.first { $0.address == address }
        } else {
            let alone = !builds.contains { $0.id != build.id && $0.name.lowercased() == name }
            device = build.onNetwork && alone && carriers.count == 1 ? carriers[0] : nil
        }
        guard let device, !except.contains(device.address) else { return nil }
        return .install(address: device.address)
    }

    /// Its row's detail: the type at Hetzner, the memory, the system, and the project at DigitalOcean
    /// ("CX23 · 4 GB · Ubuntu 24.04").
    public var summary: String {
        var parts: [String] = []
        if !type.isEmpty, !type.contains("-") { parts.append(type.uppercased()) }
        if let memoryMB { parts.append(Self.size(memoryMB)) }
        if let system, let version {
            let name = (InstallPlan.systems(.hub) + InstallPlan.systems(.join)).first { $0.id == system }?.name
                ?? system.capitalized
            parts.append("\(name) \(version)")
        }
        if let project { parts.append(project) }
        return parts.joined(separator: " · ")
    }

    static func takes(_ job: InstallJob, _ system: String, _ version: String) -> Bool {
        InstallPlan.systems(job).contains { $0.id == system && $0.version == version }
    }

    /// "4 GB", "1.5 GB", "512 MB".
    static func size(_ megabytes: Int) -> String {
        if megabytes < 1024 { return "\(megabytes) MB" }
        if megabytes % 1024 == 0 { return "\(megabytes / 1024) GB" }
        return String(format: "%.1f GB", Double(megabytes) / 1024)
    }
}

/// **What the hub and this Mac's network say of the fleet's servers**, for the words of a server that Founderizer
/// made and that the hub's list does not have by its name (`CloudExisting.unfit`). There is one only when the two
/// agree: the hub's list, and a list of this Mac's network's devices that said what the network was at its read
/// (`FleetOnTailscale.live`) and that holds at least one address of the fleet. A network that did not answer, an old
/// list of devices, and the network of another fleet give none, and the row then says no more than its provider's
/// label.
public struct FleetKnown: Equatable, Sendable {
    /// The addresses of the fleet's servers on the private network: the ones of the hub's list, and the address
    /// that this app reaches the hub at.
    public let addresses: Set<String>
    /// The devices of this Mac's private network.
    public let devices: [FleetOnTailscale.Device]

    public init?(servers: [ServerEntry], hub: String?, devices: [FleetOnTailscale.Device]?) {
        guard let devices else { return nil }
        var addresses = Set(servers.compactMap(\.address))
        if let hub, !hub.isEmpty { addresses.insert(hub) }
        guard devices.contains(where: { addresses.contains($0.address) }) else { return nil }
        self.addresses = addresses; self.devices = devices
    }
}

/// **The servers that this Mac made at a provider, by the hub that they were made for**: the one proof that a server of
/// the account which its hub does not list is this fleet's own, whose install never reached its join
/// (`CloudExisting.reuse`). A provider's label says that Founderizer made a server and not for which fleet. Each one is
/// kept by its name and, once its provider answered, by the provider's own id: names come back (a deleted `worker-3`
/// gives its name to the next server, which can be another fleet's), and ids do not. Names and ids only, in the app's
/// settings: no secret.
public enum MadeServers {
    static let key = "serversMadeFor"

    private static func prefix(_ hub: URL) -> String { "\(hub.absoluteString)|" }

    /// Keeps a server made for this hub: by its name right before its provider is asked for it (a call that fails can
    /// leave the server there), and with the provider's id once the provider gave one.
    public static func note(_ name: String, id: String? = nil, hub: URL, in defaults: UserDefaults = AppDefaults.store) {
        let name = name.lowercased(), start = "\(prefix(hub))\(name)"
        var all = (defaults.stringArray(forKey: key) ?? []).filter { $0 != start && !$0.hasPrefix(start + "|") }
        all.append(id.map { "\(start)|\($0)" } ?? start)
        defaults.set(all, forKey: key)
    }

    /// The servers made for this hub: each name in lower case with the provider's id, or an empty id where the provider
    /// gave none.
    public static func kept(hub: URL, in defaults: UserDefaults = AppDefaults.store) -> [String: String] {
        let prefix = prefix(hub)
        var kept: [String: String] = [:]
        for entry in defaults.stringArray(forKey: key) ?? [] where entry.hasPrefix(prefix) {
            let parts = entry.dropFirst(prefix.count).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { continue }
            kept[String(name)] = parts.count > 1 ? String(parts[1]) : ""
        }
        return kept
    }

    /// Forgets the servers made for this hub: the app forgets that fleet ("Start again").
    public static func forget(hub: URL, in defaults: UserDefaults = AppDefaults.store) {
        let prefix = prefix(hub)
        defaults.set((defaults.stringArray(forKey: key) ?? []).filter { !$0.hasPrefix(prefix) }, forKey: key)
    }

    /// **The provider's ids of the hub's own servers among the builds of this Mac**, for Add server's list: since a
    /// first run's server is kept here too ("Start again"), the fleet's own VPS is in `kept`, and it is never a server
    /// for agents to use again (`CloudExisting.reuse`), also at a provider whose list has no label for it.
    public static func hubsOwn(hub: URL, builds: [BuildRecord]) -> Set<String> {
        Set(builds.filter { $0.hub == hub.absoluteString && $0.use == .hub }.compactMap(\.serverID))
    }

    /// This server of the account is one that this Mac made for the hub of `kept`: its name is kept, and the id that
    /// was kept with it, if any, is its own.
    public static func holds(_ server: CloudExisting, in kept: [String: String]) -> Bool {
        guard let id = kept[server.name.lowercased()] else { return false }
        return id.isEmpty || id == server.id
    }
}

/// **The installs that this Mac saw end, by server and hub**, with the address that the install reached: written only
/// where an install from this Mac ran to its last step. A server of the hub's list is one whose install ended only
/// while the hub has it at that address (`CloudExisting.reuse`'s `finished`): a new server under the name of a removed
/// one has another address, and a check from a server's own page writes nothing here.
public enum InstallEnds {
    static let key = "installsEnded"

    public static func note(_ server: String, address: String, hub: URL, in defaults: UserDefaults = AppDefaults.store) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all["\(hub.absoluteString)|\(server.lowercased())"] = address
        defaults.set(all, forKey: key)
    }

    /// Forgets the ended installs of this hub: the app forgets that fleet ("Start again").
    public static func forget(hub: URL, in defaults: UserDefaults = AppDefaults.store) {
        let prefix = "\(hub.absoluteString)|"
        let all = (defaults.dictionary(forKey: key) as? [String: String] ?? [:]).filter { !$0.key.hasPrefix(prefix) }
        defaults.set(all, forKey: key)
    }

    /// The address that each ended install of this hub reached, by the server's name in lower case.
    public static func ended(hub: URL, in defaults: UserDefaults = AppDefaults.store) -> [String: String] {
        let prefix = "\(hub.absoluteString)|"
        var ended: [String: String] = [:]
        for (key, address) in defaults.dictionary(forKey: key) as? [String: String] ?? [:] where key.hasPrefix(prefix) {
            ended[String(key.dropFirst(prefix.count))] = address
        }
        return ended
    }
}

/// What "Use this server" does with a server that the fleet holds already (`CloudExisting.reuse`), and with the
/// hub's server that this Mac made in a first run's list (`CloudExisting.hubAgain`, which gives `install` only).
public enum CloudReuse: Equatable, Sendable {
    /// The agent that waits for its first server takes this one, by its name in the fleet.
    case place(server: String)
    /// Its install runs again, at this address on the private network.
    case install(address: String)
}

/// **The line that the first run's list says over its press for a server of an earlier try** (the owner's yes of 18
/// November 2026, "A: say it at the press": a server that this Mac made for a hub, and whose row cannot be taken,
/// still costs money, and a press on "Make the server" rented a second one). The rule only: the page gives the
/// words of each line (`FirstRunView.makeServer`), and takes the second click of a double click for no press.
public struct EarlierServerLines: Equatable, Sendable {
    /// One line for each listed server that this Mac's own record names as a hub's server that it made, in the
    /// list's order: by these the page knows such a line over its press.
    public let lines: [String]
    /// The line that a press says: of the first such server whose row cannot be taken. Nil when each can be.
    public let now: String?

    public init(_ servers: [(line: String, taken: Bool)]) {
        lines = servers.map(\.line)
        now = servers.first { !$0.taken }?.line
    }

    /// A line over the press is one of these.
    public func has(_ line: String?) -> Bool { line.map { lines.contains($0) } ?? false }

    /// **What a press says in place of a new server**, or nil when it makes one. `shown` is the line over the press
    /// at the press. The press makes the server only over the line that it would say: with no line, with a line that
    /// went, and with another line over it, the press says the line.
    public func says(over shown: String?) -> String? { shown == now ? nil : now }

    /// A reading of the network takes such a line away when a press would say it no more: that server's row can be
    /// taken now. The line that a press would say stays, through each reading.
    public func stale(_ shown: String?) -> Bool { has(shown) && shown != now }
}

extension CloudOffer {
    /// "CX23 · 2 vCPU · 4 GB · 40 GB": the type at Hetzner, then what it is made of.
    public var size: String {
        var parts: [String] = []
        if provider == .hetzner { parts.append(type.uppercased()) }
        if let cores { parts.append("\(cores) vCPU") }
        if let memoryGB { parts.append(CloudExisting.size(Int((memoryGB * 1024).rounded()))) }
        if let diskGB { parts.append("\(diskGB) GB") }
        return parts.joined(separator: " · ")
    }

    /// "€5.49 a month", in this Mac's own way of writing an amount.
    public var monthly: String { String(l10n: "\(amount) a month") }

    /// "€5.49": a month's price alone, for a row of a provider's types, whose capsule says "a month".
    public var amount: String {
        let format = NumberFormatter()
        format.numberStyle = .currency
        format.currencyCode = currency
        format.maximumFractionDigits = 2
        return format.string(from: monthlyPrice as NSDecimalNumber) ?? "\(monthlyPrice) \(currency)"
    }

    /// The new server's row in the list: "CX23 · 4 GB · Nuremberg · €5.49 a month".
    public var row: String {
        var parts: [String] = []
        if provider == .hetzner { parts.append(type.uppercased()) }
        if let memoryGB { parts.append(CloudExisting.size(Int((memoryGB * 1024).rounded()))) }
        parts.append(String(place.split(separator: ",").first ?? Substring(place)))
        parts.append(monthly)
        return parts.joined(separator: " · ")
    }

    /// **The line under a server on the first run's page "Your fleet"** (slice 2 of the one wizard): "CX23 · €5.49 a
    /// month", as the build page's picture has it. A provider whose type the app does not show gives the server's
    /// memory in its place, as `row` does.
    public var brief: String {
        var parts: [String] = []
        if provider == .hetzner {
            parts.append(type.uppercased())
        } else if let memoryGB {
            parts.append(CloudExisting.size(Int((memoryGB * 1024).rounded())))
        }
        parts.append(monthly)
        return parts.joined(separator: " · ")
    }

    /// **The capsule under a server on "Your fleet"** (slice 2b; the owner's "Yes, build them" of 18 November 2026):
    /// its provider and its line, "Hetzner · CX23 · €5.49 a month".
    public var pick: String { "\(provider.name) · \(brief)" }

    /// **One row of that capsule's list of the provider's types**: "CX23 · 2 cores · 4 GB · Nuremberg", and the price
    /// beside it (`amount`). Another provider's row has no type, as `row` has none.
    public var choice: String {
        var parts: [String] = []
        if provider == .hetzner { parts.append(type.uppercased()) }
        if let cores { parts.append(Self.cores(cores, dedicated: dedicated)) }
        if let memoryGB { parts.append(CloudExisting.size(Int((memoryGB * 1024).rounded()))) }
        parts.append(String(place.split(separator: ",").first ?? Substring(place)))
        return parts.joined(separator: " · ")
    }

    /// "2 cores", or "2 own cores" for a type whose cores no other server shares.
    static func cores(_ count: Int, dedicated: Bool) -> String {
        switch (count, dedicated) {
        case (1, false): String(l10n: "1 core")
        case (1, true): String(l10n: "1 own core")
        case (_, false): String(l10n: "\(count) cores")
        case (_, true): String(l10n: "\(count) own cores")
        }
    }
}
#endif
