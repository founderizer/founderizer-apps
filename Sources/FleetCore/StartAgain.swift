#if os(macOS)
import Foundation

/// **"Start again": what the app may delete of one fleet, and how the run goes** (the owner's "Yes, build it" of 15
/// November 2026 to the four pages; his words of 14 November: "the start again should clean tailscale etc and any
/// trace", and "be more specific and explain every step").
///
/// Two rules stand over all of it:
///
/// 1. **It deletes a server only when this Mac can prove that the server is this fleet's.** The proof is the
///    provider's own id of the server in this Mac's records for this hub (`proven`). A provider's label names no
///    fleet, so a label is never a proof, and a name alone is never one.
/// 2. **It never asks the hub.** It uses the provider's token and the key of the private network that this Mac keeps,
///    so it works when the hub does not answer.
///
/// What this file holds is the rules, with no call of its own: which servers are proven, which device of the private
/// network one build made (`device`), the rows and the words of the pages, the steps and their order (`run`), and
/// which kept values of a hub the app clears (`forgetKept`). The calls are the provider's (`CloudServers`), the
/// private network's (`TailscaleFleetKey`) and the store's.
public enum StartAgain {

    // MARK: - The proof

    /// One server that this Mac's records prove to be this fleet's, at its provider.
    public struct Server: Equatable, Sendable, Identifiable {
        public let provider: CloudProvider
        /// The provider's own id of the server: the one thing that the delete call names.
        public let serverID: String
        public let name: String
        /// What it was made for. A server that only `MadeServers` proves was made for agents: the first run's own
        /// server, the hub's, always has its build's record.
        public let use: CloudServerUse
        /// The provider's name of its type, and its price a month, each only when the app knows it.
        public let type: String?
        public let monthlyPrice: Decimal?
        public let currency: String?
        /// The build that made it, when a `BuildRecord` proves it: its times say which device of the private network
        /// is its own (`device`). A server that only `MadeServers` proves has none, so its device stays.
        public let build: BuildRecord?

        public var id: String { "\(provider.rawValue)|\(serverID)" }

        public init(provider: CloudProvider, serverID: String, name: String, use: CloudServerUse, type: String? = nil,
                    monthlyPrice: Decimal? = nil, currency: String? = nil, build: BuildRecord? = nil) {
            self.provider = provider; self.serverID = serverID; self.name = name; self.use = use
            self.type = type; self.monthlyPrice = monthlyPrice; self.currency = currency; self.build = build
        }
    }

    /// What this Mac's records prove for one hub.
    public struct Proven: Equatable, Sendable {
        /// The servers that a run deletes, the hub's own first.
        public var servers: [Server] = []
        /// The builds of this hub whose server the provider no longer has: nothing is deleted at the provider for
        /// them, and the device that each made on the private network still goes.
        public var gone: [BuildRecord] = []

        /// Every other build of this Mac's records that can have made a machine, of another hub or of none
        /// (`StartAgain.rivals`): a device that fits the times of one of them too is not provably this run's (`device`).
        public var rivals: [BuildRecord] = []

        public init(servers: [Server] = [], gone: [BuildRecord] = [], rivals: [BuildRecord] = []) {
            self.servers = servers; self.gone = gone; self.rivals = rivals
        }

        /// The builds whose device a run removes when the private network still has it: of the servers that go, and
        /// of the servers that are gone.
        public var builds: [BuildRecord] { servers.compactMap(\.build) + gone }
    }

    /// **The servers of this hub that this Mac may delete.** A server is proven in two ways, and in no other:
    ///
    /// - a `BuildRecord` with this hub and the provider's id of the server, at the record's own provider. When that
    ///   provider's list was read and no longer has the id, the server is gone (`Proven.gone`), **unless the machine
    ///   that the build made still runs** (`alive`): a list is the list of one token, and a token of another project
    ///   or account does not have this fleet's servers. Such a server stays a row, so that its step asks the provider
    ///   and says what the provider answers. When the list was not read, the row is the record's own, with no type
    ///   and no price;
    /// - an entry of `MadeServers` for this hub with an id, when exactly one list of a provider whose token this Mac
    ///   holds has a server with that id and that name. The entry names no provider, so two lists that both have such
    ///   a server prove nothing.
    ///
    /// Not a proof: a provider's label, a name, a device of the private network, a `BuildRecord` with no hub or with
    /// another one, and an entry of `MadeServers` with no id.
    ///
    /// - Parameters:
    ///   - made: `MadeServers.kept(hub:)`.
    ///   - builds: the kept records of every build (`BuildRecords.all`).
    ///   - listed: the servers of each provider whose list was read now. A provider whose read failed is not in it.
    ///   - alive: the machine that this build made still runs (`isAlive`); with no word of it, none does.
    public static func proven(hub: URL, made: [String: String], builds: [BuildRecord],
                              listed: [CloudProvider: [CloudExisting]],
                              alive: (BuildRecord) -> Bool = { _ in false }) -> Proven {
        var proven = Proven(rivals: rivals(hub: hub, builds: builds)), taken = Set<String>(), built = Set<String>()
        for build in builds {
            guard isOwn(build, hub: hub), let id = build.serverID else { continue }
            built.insert(id)
            guard taken.insert("\(build.provider.rawValue)|\(id)").inserted else { continue }
            guard let list = listed[build.provider] else {
                proven.servers.append(Server(provider: build.provider, serverID: id, name: build.name, use: build.use, build: build))
                continue
            }
            guard let there = list.first(where: { $0.id == id }) else {
                if alive(build) {
                    proven.servers.append(Server(provider: build.provider, serverID: id, name: build.name, use: build.use, build: build))
                } else {
                    proven.gone.append(build)
                }
                continue
            }
            proven.servers.append(Server(
                provider: build.provider, serverID: id, name: build.name, use: build.use,
                type: there.type.isEmpty ? build.type : there.type, monthlyPrice: build.monthlyPrice,
                currency: build.currency, build: build))
        }
        for (name, id) in made.sorted(by: { $0.key < $1.key }) where CloudServers.isID(id) && !built.contains(id) {
            let found = listed.flatMap { provider, list in
                list.filter { $0.id == id && $0.name.lowercased() == name }.map { (provider: provider, server: $0) }
            }
            guard found.count == 1, let one = found.first,
                  taken.insert("\(one.provider.rawValue)|\(id)").inserted else { continue }
            proven.servers.append(Server(provider: one.provider, serverID: id, name: one.server.name, use: .agent,
                                         type: one.server.type.isEmpty ? nil : one.server.type))
        }
        proven.servers.sort { first, second in
            if (first.use == .hub) != (second.use == .hub) { return first.use == .hub }
            let began = (first.build?.began ?? .distantFuture, second.build?.began ?? .distantFuture)
            if began.0 != began.1 { return began.0 < began.1 }
            return (first.name, first.id) < (second.name, second.id)
        }
        return proven
    }

    /// A record of a build is this hub's own for the proof: it names this hub, and it has an id of the provider.
    static func isOwn(_ build: BuildRecord, hub: URL) -> Bool {
        build.hub == hub.absoluteString && build.serverID.map(CloudServers.isID) == true
    }

    /// **The records of every other build that can have made a machine** (`Proven.rivals`): of another hub, of none,
    /// or with no id of the provider. A try that left nothing at its provider (the call was not sent, the provider
    /// refused it, or the app took the server back) made no machine, and is no rival.
    public static func rivals(hub: URL, builds: [BuildRecord]) -> [BuildRecord] {
        builds.filter { !isOwn($0, hub: hub) && $0.atProvider != .nothing }
    }

    // MARK: - The device of one build

    /// How long before a build's start its device can have been made (a clock that is off), and how long after the
    /// provider's answer a server can take to come up on the private network.
    public static let deviceSlack: TimeInterval = 300, deviceWindow: TimeInterval = 1800

    /// **The one device of the private network that this build made**, or nil: its `hostname` is the build's name,
    /// it has the fleet's tag, it is authorized and the tailnet's own, and it was made between the build's start less
    /// five minutes and thirty minutes after the provider's answer (after the start, for a record with no answer's
    /// time). That is the rule of `TailscaleFleetKey.joined` with an upper limit, because a later build can take the
    /// same name. Two devices that both fit prove nothing: none is taken. **A device that fits the times of another
    /// build of that name too** (`rivals`: a build of another hub, or of none) **proves nothing either**: it can be
    /// that build's machine, when this build's own never came up. **Never this Mac**: a device with one of this Mac's
    /// addresses or with this Mac's own name is never the answer.
    public static func device(of build: BuildRecord, in devices: [FleetDevice], thisMac: Set<String> = [],
                              thisMacName: String? = nil, rivals: [BuildRecord] = []) -> FleetDevice? {
        let wanted = build.name.lowercased()
        guard !wanted.isEmpty, build.serverID != nil else { return nil }
        if let own = thisMacName?.lowercased(), !own.isEmpty, own == wanted { return nil }
        let others = rivals.filter { $0.id != build.id && $0.name.lowercased() == wanted }
        let found = devices.filter { device in
            guard device.hostname.lowercased() == wanted, device.authorized, !device.external,
                  device.tags.contains(TailscaleFleetKey.tag), let created = device.created,
                  fits(created, build), thisMac.isDisjoint(with: device.addresses) else { return false }
            return !others.contains { fits(created, $0) }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// A device made at this time can be the machine of this build: from the build's start less the slack to the
    /// window's end after the provider's answer (after the start, for a record with no answer's time).
    static func fits(_ created: Date, _ build: BuildRecord) -> Bool {
        created >= build.began.addingTimeInterval(-deviceSlack)
            && created <= (build.madeAt ?? build.began).addingTimeInterval(deviceWindow)
    }

    /// **The machine that this build made still runs**: its one device of the private network (`device`) is there,
    /// and Tailscale says that it holds its connection, or this Mac's own Tailscale shows one of its addresses online
    /// (`online`). A server that runs is not a server that is gone, whatever one token's list says.
    public static func isAlive(_ build: BuildRecord, devices: [FleetDevice], online: Set<String>, thisMac: Set<String> = [],
                               thisMacName: String? = nil, rivals: [BuildRecord] = []) -> Bool {
        guard let device = device(of: build, in: devices, thisMac: thisMac, thisMacName: thisMacName, rivals: rivals)
        else { return false }
        return device.connected || !online.isDisjoint(with: device.addresses)
    }

    /// The addresses that this Mac's own Tailscale shows online now, out of its `tailscale status --json`.
    public static func onlineAddresses(in json: String?) -> Set<String> {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = object["Peer"] as? [String: Any] else { return [] }
        var online = Set<String>()
        for case let peer as [String: Any] in peers.values where peer["Online"] as? Bool == true {
            online.formUnion((peer["TailscaleIPs"] as? [String]) ?? [])
        }
        return online
    }

    /// This Mac's own addresses on the private network, out of its `tailscale status --json`; empty when the answer
    /// does not say.
    public static func ownAddresses(in json: String?) -> Set<String> {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let own = object["Self"] as? [String: Any] else { return [] }
        return Set((own["TailscaleIPs"] as? [String]) ?? [])
    }

    // MARK: - The plan: what the page shows before anything goes

    /// What one run takes away, as the page "Start again" shows it before the press.
    public struct Plan: Equatable, Sendable {
        public let hub: URL
        public let servers: [Server]
        /// **The builds whose device the run removes when the private network still has it**: only the ones whose
        /// machine the page names. They are the builds of `Proven.builds` whose device the read found by `device`,
        /// or, when the read of the private network failed, all of them. A device that the page did not name is
        /// never removed, also when it fits the rule by the time of the run.
        public let builds: [BuildRecord]
        /// The builds of another hub or of none (`Proven.rivals`), for the rule of `device`.
        public let rivals: [BuildRecord]
        /// The names of the machines in the row of the private network: the names of `builds`.
        public let machines: [String]

        public init(hub: URL, proven: Proven, devices: [FleetDevice]?, thisMac: Set<String> = [], thisMacName: String? = nil) {
            self.hub = hub
            servers = proven.servers
            rivals = proven.rivals
            var named: [BuildRecord] = [], names: [String] = []
            for build in proven.builds {
                if let devices, StartAgain.device(of: build, in: devices, thisMac: thisMac, thisMacName: thisMacName,
                                                  rivals: proven.rivals) == nil { continue }
                named.append(build)
                if !names.contains(build.name) { names.append(build.name) }
            }
            builds = named
            machines = names
        }

        /// The providers that have a server to delete, in the order of the rows.
        public var providers: [CloudProvider] {
            var found: [CloudProvider] = []
            for server in servers where !found.contains(server.provider) { found.append(server.provider) }
            return found
        }

        public func servers(at provider: CloudProvider) -> [Server] { servers.filter { $0.provider == provider } }

        /// The sections of the page, in its order. A section with no row is not there; the app's own always is.
        public var sections: [Section] {
            var sections: [Section] = providers.map { provider in
                let its = servers(at: provider)
                return Section(id: provider.rawValue, title: Words.deletedAt(provider), rows: its.map { server in
                    Row(id: server.id, title: server.name, symbol: "server.rack", detail: Words.detail(of: server))
                } + [Row(id: "\(provider.rawValue)|firewalls", title: Words.firewalls(its.count, at: provider),
                         symbol: "shield", detail: Words.madeFor(its.count, at: provider))])
            }
            if !machines.isEmpty {
                sections.append(Section(id: "tailscale", title: String(l10n: "Removed from your Tailscale network"), rows: [
                    Row(id: "machines", title: Words.machines(machines), symbol: "network",
                        detail: String(l10n: "This Mac and your other devices stay in the network."))]))
            }
            sections.append(Section(id: "app", title: String(l10n: "Removed from the Founderizer app"), rows: [
                Row(id: "app", title: String(l10n: "What the app keeps of this fleet"), symbol: "tray",
                    detail: String(l10n: "Its address, its keys and its copies. Nothing else on this Mac changes."))]))
            return sections
        }

        /// The steps of a run, in the order of the page: each server, then each provider's firewalls and key, then
        /// the machines of the private network, then the app's own part.
        public var steps: [Step] {
            var kinds: [Step.Kind] = servers.map { .server($0) }
            kinds += providers.map { .firewalls($0, servers: servers(at: $0)) }
            if !machines.isEmpty { kinds.append(.machines(machines.count)) }
            kinds.append(.app)
            return kinds.enumerated().map { Step(id: $0.offset, kind: $0.element) }
        }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let rows: [Row]
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let symbol: String
        public let detail: String
    }

    // MARK: - The words, and their variants for another count or another provider

    public enum Words {
        /// The link under the two cards, and the title of its page before the press.
        public static var start: String { String(l10n: "Start again") }
        /// The title while a run goes.
        public static var starting: String { String(l10n: "Starting again") }
        /// The press of the page.
        public static var press: String { String(l10n: "Delete and start again") }

        public static func deletedAt(_ provider: CloudProvider) -> String { String(l10n: "Deleted at \(provider.name)") }

        /// "Your fleet's server · CX23 · €5.49 a month": what the server is for, then its type and its price a month,
        /// each only when the app knows it.
        public static func detail(of server: Server) -> String {
            var parts = [server.use == .hub ? String(l10n: "Your fleet's server") : String(l10n: "The manager's server")]
            if let type = server.type, !type.isEmpty { parts.append(server.provider == .hetzner ? type.uppercased() : type) }
            if let price = server.monthlyPrice, let currency = server.currency, !currency.isEmpty {
                parts.append(monthly(price, currency))
            }
            return parts.joined(separator: " · ")
        }

        /// "€5.49 a month", in this Mac's own way of writing an amount (as `CloudOffer.monthly`).
        public static func monthly(_ price: Decimal, _ currency: String) -> String {
            let format = NumberFormatter()
            format.numberStyle = .currency
            format.currencyCode = currency
            format.maximumFractionDigits = 2
            let amount = format.string(from: price as NSDecimalNumber) ?? "\(price) \(currency)"
            return String(l10n: "\(amount) a month")
        }

        /// The row of what the app made beside the servers. Akamai keeps no SSH key of its own, so its row names none.
        public static func firewalls(_ count: Int, at provider: CloudProvider) -> String {
            switch (count == 1, provider == .akamai) {
            case (true, false): String(l10n: "Its firewall and Founderizer's SSH key")
            case (false, false): String(l10n: "Their \(count) firewalls and Founderizer's SSH key")
            case (true, true): String(l10n: "Its firewall")
            case (false, true): String(l10n: "Their \(count) firewalls")
            }
        }

        public static func madeFor(_ count: Int, at provider: CloudProvider) -> String {
            switch (count == 1, provider == .akamai) {
            case (true, false): String(l10n: "Founderizer made them for this server.")
            case (true, true): String(l10n: "Founderizer made it for this server.")
            case (false, _): String(l10n: "Founderizer made them for these servers.")
            }
        }

        /// "The machine worker-1", "The machines worker-1 and worker-2", "The machines worker-1, worker-2 and worker-3".
        public static func machines(_ names: [String]) -> String {
            guard names.count > 1, let last = names.last else { return String(l10n: "The machine \(names.first ?? "")") }
            let first = names.dropLast().joined(separator: ", ")
            return String(l10n: "The machines \(first) and \(last)")
        }

        /// The row of one step while the run goes.
        public static func title(of kind: Step.Kind) -> String {
            switch kind {
            case .server(let server): String(l10n: "Delete \(server.name) at \(server.provider.name)")
            case .firewalls(let provider, let servers):
                switch (servers.count == 1, provider == .akamai) {
                case (true, false): String(l10n: "Delete its firewall and SSH key at \(provider.name)")
                case (false, false): String(l10n: "Delete their firewalls and SSH key at \(provider.name)")
                case (true, true): String(l10n: "Delete its firewall at \(provider.name)")
                case (false, true): String(l10n: "Delete their firewalls at \(provider.name)")
                }
            case .machines(let count):
                count == 1 ? String(l10n: "Remove the machine from Tailscale")
                    : count == 2 ? String(l10n: "Remove both machines from Tailscale")
                    : String(l10n: "Remove the \(count) machines from Tailscale")
            case .app: String(l10n: "Clear what the app keeps of this fleet")
            }
        }

        public static func word(of state: Step.State) -> String {
            switch state {
            case .waiting: String(l10n: "Waiting")
            case .now: String(l10n: "Now")
            case .done: String(l10n: "Done")
            case .failed: String(l10n: "Failed")
            }
        }

        /// The orange line of a failed step: what the provider or the private network said, in the app's own words.
        /// A token that the provider does not take is said in one short sentence, because this page has no field to
        /// paste another one.
        public static func says(_ error: Error, at provider: CloudProvider? = nil) -> String {
            switch error {
            case CloudError.tokenNotAccepted(let provider), CloudError.readOnlyToken(let provider):
                return String(l10n: "\(provider.name) refused the token.")
            case let error as CloudError: return error.errorDescription ?? ""
            case let error as FleetKeyError: return error.errorDescription ?? ""
            default:
                // A call that ended with no word of the provider's or the network's (a task that was ended).
                return provider.map { CloudError.unreachable($0).errorDescription ?? "" }
                    ?? (FleetKeyError.unreachable.errorDescription ?? "")
            }
        }

        public static var stillCosts: String { String(l10n: "The server is still there and still costs money.") }

        /// Words that end as a sentence ends, so that another sentence can follow them: a provider's own words often
        /// end with none.
        public static func sentence(_ words: String) -> String {
            let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = words.last, !".!?".contains(last) else { return words }
            return words + "."
        }
    }

    // MARK: - The steps and the run

    /// One step of a run, as its row shows it.
    public struct Step: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// The provider deletes this one server, by its id.
            case server(Server)
            /// The firewalls of the servers that this run deleted at the provider, and the app's own SSH key there.
            case firewalls(CloudProvider, servers: [Server])
            /// The devices that the builds made go from the private network; the count is the row's.
            case machines(Int)
            /// The app clears what it keeps of this fleet.
            case app
        }

        public enum State: String, Sendable, CaseIterable { case waiting, now, done, failed }

        public let id: Int
        public let kind: Kind
        public var state: State = .waiting
        /// The orange line of a step that failed.
        public var says: String?
        /// The page's title while this step is the one that failed: "worker-2 is not deleted".
        public var failedTitle: String?
        /// For a server's step: **the provider took this run's deletion of the server.** A server that the provider
        /// did not have (404) is done too, and this run did not delete it: its firewalls, the app's key and this
        /// Mac's key for its hub are not this run's to take.
        public var deleted = false

        public init(id: Int, kind: Kind, state: State = .waiting, says: String? = nil, failedTitle: String? = nil,
                    deleted: Bool = false) {
            self.id = id; self.kind = kind; self.state = state; self.says = says; self.failedTitle = failedTitle
            self.deleted = deleted
        }

        public var title: String { Words.title(of: kind) }

        public var symbol: String {
            switch state {
            case .done: "checkmark.circle.fill"
            case .now: "circle.dotted"
            case .waiting: "circle.dashed"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    /// The calls of a run. The rules give each one only what the proof holds: a server's own id, the name of a server
    /// that this run deleted, a device's own id.
    public struct Work: Sendable {
        /// Deletes this one server at its provider, by its id, and says whether the provider had it
        /// (`CloudServers.deleteServer`). It calls `accepted` at the moment the provider takes the deletion, before
        /// the wait for its end.
        public var deleteServer: @Sendable (Server, _ accepted: @escaping @Sendable () -> Void) async throws -> CloudDeletion
        /// Deletes the firewalls that the app made for a server of this name at the provider. `deleted` are the ids of
        /// the servers that this run deleted there: a firewall in front of any other server stays.
        public var deleteFirewalls: @Sendable (CloudProvider, _ name: String, _ deleted: Set<String>) async throws -> Void
        /// Deletes the app's own SSH key at the provider.
        public var deleteKey: @Sendable (CloudProvider) async throws -> Void
        /// The devices of the private network now.
        public var devices: @Sendable () async throws -> [FleetDevice]
        /// Removes one device from the private network, by its id.
        public var deleteDevice: @Sendable (String) async throws -> Void
        /// This Mac's own addresses on the private network, and its own name.
        public var thisMac: @Sendable () async -> (addresses: Set<String>, name: String?)
        /// The addresses that this Mac's own Tailscale shows online now (`onlineAddresses`).
        public var online: @Sendable () async -> Set<String>
        /// A provider took a deletion of this server from this app, in this start of the app (`noteDeleted` keeps it,
        /// `deletedBefore` asks): Tailscale shows the machine of a deleted server connected for a while longer, and
        /// that is no machine that runs. `forgetDeleted` takes a server out again, when its provider said after all
        /// that the deletion did not go.
        public var noteDeleted: @Sendable (CloudProvider, _ id: String) -> Void
        public var forgetDeleted: @Sendable (CloudProvider, _ id: String) -> Void
        public var deletedBefore: @Sendable (CloudProvider, _ id: String) -> Bool
        /// Clears what the app keeps of this fleet. `hubServerDeleted`: this run deleted the hub's own server.
        public var clearApp: @Sendable (_ hubServerDeleted: Bool) async -> Void

        public init(deleteServer: @escaping @Sendable (Server, @escaping @Sendable () -> Void) async throws -> CloudDeletion,
                    deleteFirewalls: @escaping @Sendable (CloudProvider, String, Set<String>) async throws -> Void,
                    deleteKey: @escaping @Sendable (CloudProvider) async throws -> Void,
                    devices: @escaping @Sendable () async throws -> [FleetDevice],
                    deleteDevice: @escaping @Sendable (String) async throws -> Void,
                    thisMac: @escaping @Sendable () async -> (addresses: Set<String>, name: String?),
                    online: @escaping @Sendable () async -> Set<String> = { [] },
                    noteDeleted: @escaping @Sendable (CloudProvider, String) -> Void = { _, _ in },
                    forgetDeleted: @escaping @Sendable (CloudProvider, String) -> Void = { _, _ in },
                    deletedBefore: @escaping @Sendable (CloudProvider, String) -> Bool = { _, _ in false },
                    clearApp: @escaping @Sendable (Bool) async -> Void) {
            self.deleteServer = deleteServer; self.deleteFirewalls = deleteFirewalls; self.deleteKey = deleteKey
            self.devices = devices; self.deleteDevice = deleteDevice; self.thisMac = thisMac; self.online = online
            self.noteDeleted = noteDeleted; self.forgetDeleted = forgetDeleted; self.deletedBefore = deletedBefore
            self.clearApp = clearApp
        }
    }

    /// **A call for a server's deletion ended with its provider's own error**: the provider answered, and its answer
    /// is an error. A call that got no answer (no connection, a task that was ended) says nothing of the server.
    static func isProvidersOwn(_ error: Error) -> Bool {
        guard let error = error as? CloudError else { return false }
        if case .unreachable = error { return false }
        return true
    }

    /// One mark that a call sets from any thread: the provider took the deletion.
    private final class Taken: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        func mark() { lock.withLock { set = true } }
        var isSet: Bool { lock.withLock { set } }
    }

    /// Why a step stopped: the page's title, and the orange line.
    struct Stop: Error {
        let title: String
        let says: String
    }

    /// **Runs the steps that are not done, one at a time and in their order, and stops at the first that fails.**
    ///
    /// - A step that is done is never run again, so "Try again" goes on at the step that failed. Each step can run
    ///   again with the same result: what is gone already is done.
    /// - Nothing after a failed step runs. **The app's own step runs last and only when every step before it is
    ///   done**, so a run that stopped leaves the fleet as the app's fleet.
    /// - A run whose task was ended (the page closed) starts no further step: the task's end is read before a step
    ///   is said to run and again right before its call.
    /// - **A server that the provider does not have for this token, and whose machine still runs, is not deleted**
    ///   (`isAlive`): its step fails with the provider's own answer. Without this, a token of another project or
    ///   account would end the run with the servers still there, off the private network, and still paid for.
    /// - **A server that the provider did not have (404) is done, and this run did not delete it** (`Step.deleted`):
    ///   the firewalls, the app's key and this Mac's key for the hub go only for a server whose deletion the provider
    ///   took in this run. And the machines' step removes no machine that runs, unless the provider took its
    ///   server's deletion: such a server is there, and the step stops with its name.
    /// - It asks the hub nothing, and no clock ends a step: a wait ends on the provider's own answer or on a count of
    ///   reads (`CloudServers`).
    ///
    /// `builds` are the builds whose device the run removes (`Plan.builds`), and `rivals` the builds of another hub or
    /// of none (`Plan.rivals`). `tell` gets the steps at each change of a state. The answer is the steps as the run
    /// left them.
    public static func run(_ steps: [Step], builds: [BuildRecord], rivals: [BuildRecord] = [], work: Work,
                           tell: @escaping @Sendable ([Step]) async -> Void = { _ in }) async -> [Step] {
        var steps = steps
        for index in steps.indices where steps[index].state != .done {
            steps[index].state = .waiting; steps[index].says = nil; steps[index].failedTitle = nil
        }
        for index in steps.indices where steps[index].state != .done {
            guard !Task.isCancelled, steps[..<index].allSatisfy({ $0.state == .done }) else { break }
            steps[index].state = .now
            await tell(steps)
            // The page closed while the step was said: nothing of it is asked for.
            guard !Task.isCancelled else {
                steps[index].state = .waiting
                break
            }
            do {
                switch steps[index].kind {
                case .server(let server):
                    // The deletion is noted at the moment the provider takes it: a wait for its end that the page's
                    // close cuts off leaves a server that is being deleted.
                    let taken = Taken()
                    do {
                        let outcome = try await work.deleteServer(server) {
                            taken.mark()
                            work.noteDeleted(server.provider, server.serverID)
                        }
                        switch outcome {
                        case .deleted:
                            steps[index].deleted = true
                            work.noteDeleted(server.provider, server.serverID)
                        case .notThere(let said):
                            // The provider has no such server for this token. A machine that still runs says that the
                            // server is there all the same: in another project or account than the token's. (A
                            // server that this app deleted a moment ago shows its machine connected a while longer.)
                            guard let build = server.build, !work.deletedBefore(server.provider, server.serverID)
                            else { break }
                            let own = await work.thisMac()
                            if let devices = try? await work.devices(),
                               isAlive(build, devices: devices, online: await work.online(), thisMac: own.addresses,
                                       thisMacName: own.name, rivals: rivals) { throw said }
                        }
                    } catch {
                        // **The provider took the deletion and then said that it did not go** (Hetzner's action ended
                        // with an error): the server is there, and it is no server that this app deleted. Without
                        // this a later 404 for it, from a token of another project, would read as its deletion. A
                        // call that got no answer, or that the page's close ended, says nothing: its note stays.
                        if taken.isSet, isProvidersOwn(error) { work.forgetDeleted(server.provider, server.serverID) }
                        throw Stop(title: String(l10n: "\(server.name) is not deleted"),
                                   says: Words.sentence(Words.says(error, at: server.provider)) + " " + Words.stillCosts)
                    }
                case .firewalls(let provider, let servers):
                    // Only of the servers whose deletion the provider took in this run: a server that was not there
                    // (404) is not one that this run deleted.
                    let took = steps.compactMap { step -> Server? in
                        if case .server(let server) = step.kind, step.deleted, server.provider == provider { return server }
                        return nil
                    }
                    let deleted = Set(took.map(\.serverID))
                    var names: [String] = []
                    for server in took where !names.contains(server.name) { names.append(server.name) }
                    // Every name is asked, and the key too, also after one that failed: the first stop is the step's.
                    var stop: Stop?
                    for name in names {
                        do { try await work.deleteFirewalls(provider, name, deleted) } catch {
                            if stop == nil {
                                stop = Stop(title: servers.count == 1 ? String(l10n: "The firewall is not deleted")
                                                : String(l10n: "The firewalls are not deleted"), says: Words.says(error, at: provider))
                            }
                        }
                    }
                    if provider != .akamai, !took.isEmpty {
                        do { try await work.deleteKey(provider) } catch {
                            if stop == nil {
                                stop = Stop(title: String(l10n: "The SSH key is not deleted"), says: Words.says(error, at: provider))
                            }
                        }
                    }
                    if let stop { throw stop }
                case .machines:
                    var name = builds.first?.name ?? ""
                    do {
                        let devices = try await work.devices(), own = await work.thisMac(), online = await work.online()
                        let took = Set(steps.compactMap { step -> String? in
                            if case .server(let server) = step.kind, step.deleted { return server.id }
                            return nil
                        })
                        var removed = Set<String>()
                        for build in builds {
                            name = build.name
                            guard let device = device(of: build, in: devices, thisMac: own.addresses, thisMacName: own.name,
                                                      rivals: rivals),
                                  removed.insert(device.id).inserted else { continue }
                            // **A machine that runs is not removed, unless the provider took its server's deletion**
                            // (in this run, or from this app before): its server is there, whatever a list said.
                            let id = build.serverID ?? ""
                            let gone = took.contains("\(build.provider.rawValue)|\(id)")
                            if !gone, device.connected || !online.isDisjoint(with: device.addresses),
                               !work.deletedBefore(build.provider, id) {
                                throw Stop(title: String(l10n: "\(name) is not deleted"), says: Words.stillCosts)
                            }
                            try await work.deleteDevice(device.id)
                        }
                    } catch let stop as Stop {
                        throw stop
                    } catch {
                        throw Stop(title: String(l10n: "\(name) is not removed"), says: Words.says(error))
                    }
                case .app:
                    // This run deleted the hub's own server: the provider took its deletion, and a record of this
                    // Mac says that the server was made for the hub.
                    let hubServerDeleted = steps.contains { step in
                        if case .server(let server) = step.kind {
                            return step.state == .done && step.deleted && server.use == .hub && server.build != nil
                        }
                        return false
                    }
                    await work.clearApp(hubServerDeleted)
                }
                steps[index].state = .done
            } catch {
                let stop = error as? Stop
                steps[index].state = .failed
                steps[index].says = stop?.says ?? Words.says(error)
                steps[index].failedTitle = stop?.title
                await tell(steps)
                return steps
            }
            await tell(steps)
        }
        return steps
    }

    // MARK: - The address that a first run's hub will have

    /// **A hub's address as the app writes it for a server's address on the private network**: that address at the
    /// hub's own port. It is the one form for the two places that must agree: the address that a claim gives the app
    /// (`MachineInstallModel.claimedAddress`), and the address under which a first run's server is kept when its
    /// build hands it to the hub's install (`hubAddress(onNetwork:)`), before any hub exists.
    public static func hubText(at address: String) -> String { "http://\(address):\(FleetOnTailscale.hubPort)" }

    /// **The hub's address that a claim step's lines give the app**: the first address of the private network in
    /// them, at the hub's port (`hubText`). The lines are the installer's own, so only the address is taken.
    public static func claimedHub(in lines: [String]) -> String? {
        for line in lines {
            guard let found = line.range(of: "[0-9]{1,3}(\\.[0-9]{1,3}){3}", options: .regularExpression),
                  ClaimCode.isPrivateAddress(String(line[found])) else { continue }
            return hubText(at: String(line[found]))
        }
        return nil
    }

    /// The hub's address in the app's own form (`FleetStore.hub`), for a server at this address on the private
    /// network; nil for what is no such address.
    public static func hubAddress(onNetwork address: String) -> URL? {
        guard ClaimCode.isPrivateAddress(address) else { return nil }
        return try? HubClient.address(hubText(at: address))
    }

    // MARK: - When the link shows

    /// **The link "Start again" shows on the manager's server page** only while those pages give the manager its
    /// first server, no install and no build of a server runs, the page does not ask the hub, and the kept reading
    /// has no other agent than the manager and no server with an agent on it.
    public static func offers(givesManagerItsServer: Bool, runs: Bool, asksHub: Bool, otherAgents: Int,
                              serversWithAnAgent: Int) -> Bool {
        givesManagerItsServer && !runs && !asksHub && otherAgents == 0 && serversWithAnAgent == 0
    }

    // MARK: - A hub that a run left alive

    /// **The hubs that "Start again" left alive** (an own server, a server of an older build): the first run looks for
    /// a hub on this Mac's network and connects to the first that serves this Mac (`FirstRunModel.findFleet`), which
    /// would take the app back to the fleet that the owner just left. It passes over the addresses kept here. A
    /// connect that the owner asks for himself takes the address out again. Addresses only, in the app's settings.
    public enum LeftHubs {
        static let key = "hubsLeftByStartAgain"

        /// A hub's address as it is kept and compared: its host in lower case and its port.
        static func name(_ hub: URL) -> String? {
            guard let host = hub.host?.lowercased(), !host.isEmpty else { return nil }
            return "\(host):\(hub.port ?? (hub.scheme == "https" ? 443 : 80))"
        }

        /// Keeps a hub that a run left, and the other addresses that the same hub answers at (its address on the
        /// private network, when the kept one is a name).
        public static func note(_ hub: URL, also others: [URL] = [], in defaults: UserDefaults = .standard) {
            var all = defaults.stringArray(forKey: key) ?? []
            for name in ([hub] + others).compactMap(name) where !all.contains(name) { all.append(name) }
            defaults.set(all, forKey: key)
        }

        public static func holds(_ hub: URL, in defaults: UserDefaults = .standard) -> Bool {
            name(hub).map { (defaults.stringArray(forKey: key) ?? []).contains($0) } ?? false
        }

        /// **The addresses of this Mac's network that a left hub answers at**, for the first run's search, which asks
        /// each device at its address: a hub that was kept by its address, and one that was kept by a name of the
        /// private network, by the device that has that name now (its name in Tailscale, its own host name, or its
        /// whole name there).
        public static func addresses(among devices: [FleetOnTailscale.Device], dnsNames: [String: String] = [:],
                                     in defaults: UserDefaults = .standard) -> Set<String> {
            let kept = Set(defaults.stringArray(forKey: key) ?? [])
            guard !kept.isEmpty else { return [] }
            let port = FleetOnTailscale.hubPort
            return Set(devices.filter { device in
                let names = [device.address, device.name, device.host, dnsNames[device.address] ?? ""]
                return names.contains { !$0.isEmpty && kept.contains("\($0.lowercased()):\(port)") }
            }.map(\.address))
        }

        /// Each device's whole name in the private network by its address ("worker-1.example.ts.net"), out of this
        /// Mac's `tailscale status --json`.
        public static func dnsNames(in json: String?) -> [String: String] {
            guard let data = json?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let peers = object["Peer"] as? [String: Any] else { return [:] }
            var names: [String: String] = [:]
            for case let peer as [String: Any] in peers.values {
                let name = ((peer["DNSName"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard !name.isEmpty else { continue }
                for address in (peer["TailscaleIPs"] as? [String]) ?? [] { names[address] = name }
            }
            return names
        }

        /// The owner connects to this hub himself: it is no longer passed over.
        public static func forget(_ hub: URL, in defaults: UserDefaults = .standard) {
            guard let name = name(hub), let all = defaults.stringArray(forKey: key), all.contains(name) else { return }
            defaults.set(all.filter { $0 != name }, forKey: key)
        }
    }

    // MARK: - What the app keeps of one hub, in its settings

    /// **Clears the values that the app's settings keep by this hub's address, and no other hub's.** Each value is
    /// found by the exact form of its key, with the hub's whole address in it (`hub.absoluteString`, which ends in
    /// "/"), so the values of a hub whose address only starts the same stay.
    ///
    /// Always: the kept address when it is this hub's, the hub in the list of hubs that answered, the servers made for
    /// it and its ended installs, the agents that wait for a server and the servers that they joined, the pinned
    /// agents, the kept checks and install targets of its machines, the chat's kept marks, the marks of the owner's
    /// access and of the hardening on its servers, the mark of its TCP step, the page that the app left on it, a turn
    /// of connected apps that a quit cut off, and what the door's sync keeps of it (the keys that a server refused, the
    /// refusals, the hosts and the holdings that the hub recorded).
    ///
    /// **Only when the run deleted the hub's own server** (`hubServerDeleted`): the vault's pins of its servers, the
    /// kept target of this Mac's key on its server, the fleet id that this Mac made for it, and the references of App
    /// keys on their way to its door. A hub that stays alive keeps them: this Mac's key still opens it, and a later
    /// connect goes on with the same id and the same references.
    ///
    /// **Never**: a provider's token, the key of the private network, a key in the keychain, the backup's settings,
    /// the installation id, the app's own settings and what the first run keeps (the manager's name, the servers'
    /// step).
    public static func forgetKept(hub: URL, hubServerDeleted: Bool, in defaults: UserDefaults = .standard) {
        let address = hub.absoluteString
        if defaults.string(forKey: "hubAddress") == address { defaults.removeObject(forKey: "hubAddress") }
        if let answered = defaults.stringArray(forKey: "hubsAnswered"), answered.contains(address) {
            defaults.set(answered.filter { $0 != address }, forKey: "hubsAnswered")
        }
        MadeServers.forget(hub: hub, in: defaults)
        InstallEnds.forget(hub: hub, in: defaults)

        let bar = "\(address)|", space = "\(address) "
        for key in ["unplacedAgents", "addingAgents"] {
            guard let all = defaults.stringArray(forKey: key), all.contains(where: { $0.hasPrefix(bar) }) else { continue }
            defaults.set(all.filter { !$0.hasPrefix(bar) }, forKey: key)
        }
        var tables: [(key: String, prefix: String)] = [
            ("serversJoinedFor", bar), ("hubTCPDone", bar), ("ownerAccessInPlace", space), ("serverHardening", space)]
        if hubServerDeleted { tables.append(("centralVaultPins", bar)) }
        for table in tables {
            guard let all = defaults.dictionary(forKey: table.key),
                  all.keys.contains(where: { $0.hasPrefix(table.prefix) }) else { continue }
            defaults.set(all.filter { !$0.key.hasPrefix(table.prefix) }, forKey: table.key)
        }
        var named: [(key: String, name: String)] = [("pinnedAgents", address), ("lastPages", address)]
        if hubServerDeleted {
            named.append(("fleetIdsByHub", address))
        }
        for entry in named {
            guard var all = defaults.dictionary(forKey: entry.key), all[entry.name] != nil else { continue }
            all[entry.name] = nil
            defaults.set(all, forKey: entry.key)
        }
        // Two tables that the app keeps as JSON, each entry under "<hub>|<machine>".
        for key in ["machineChecklists", "machineInstallTargets"] { forget(prefix: bar, inJSON: key, defaults) }
        if hubServerDeleted, let name = OwnerMacKey.name(hub: hub) {
            forget(exactly: name, inJSON: "ownerKeyHubServer", defaults)
            forget(exactly: address, inJSON: "ownerKeyHubServer", defaults)
        }
        if let seen = defaults.dictionary(forKey: "chatRepliesSeen"), let context = seen["context"] as? String,
           context.hasPrefix("\(address)\n") {
            defaults.removeObject(forKey: "chatRepliesSeen")
        }
        // The keys that hold the hub's address in their own name.
        defaults.removeObject(forKey: ConnectGate.keptKey(hub))
        for key in ["doorLoginKeys|\(address)", "doorRefusals|\(address)"] { defaults.removeObject(forKey: key) }
        var starts = ["doorHosts|\(bar)", "doorHoldings|\(bar)"]
        if hubServerDeleted { starts.append("doorKeyReference|\(bar)") }
        for key in defaults.dictionaryRepresentation().keys where starts.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func forget(prefix: String, inJSON key: String, _ defaults: UserDefaults) {
        guard let data = defaults.data(forKey: key),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              all.keys.contains(where: { $0.hasPrefix(prefix) }),
              let kept = try? JSONSerialization.data(withJSONObject: all.filter { !$0.key.hasPrefix(prefix) }) else { return }
        defaults.set(kept, forKey: key)
    }

    private static func forget(exactly name: String, inJSON key: String, _ defaults: UserDefaults) {
        guard let data = defaults.data(forKey: key),
              var all = try? JSONSerialization.jsonObject(with: data) as? [String: Any], all[name] != nil else { return }
        all[name] = nil
        guard let kept = try? JSONSerialization.data(withJSONObject: all) else { return }
        defaults.set(kept, forKey: key)
    }

    /// **This Mac's key for a hub goes**, with the key that waits beside it: only for a hub whose own server a run
    /// deleted. A hub that stays alive keeps this Mac's key: without it, a later install on its server ends in "Your
    /// hub answered, and it does not serve its pages to this Mac". A hub that is called by a name that no longer
    /// answers has no file that this can find, and nothing is removed.
    public static func forgetMacKey(hub: URL, home: URL? = OwnerMacKey.home,
                                    lookup: (String) -> String? = OwnerMacKey.systemLookup) {
        guard let file = OwnerMacKey.file(hub: hub, home: home, lookup: lookup) else { return }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".pending"))
    }

    /// **The kept readings of this hub** in the app's own folder: `state-`, `health-`, `releases-` and `app-update-`
    /// with the hub's host and port, as `FleetStore` names them. Files of another hub, and every other file, stay.
    public static func readingFiles(of hub: URL, in folder: URL) -> [URL] {
        let address = [hub.host ?? "hub", hub.port.map(String.init)].compactMap { $0 }.joined(separator: "-")
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return ["state", "health", "releases", "app-update"].map { folder.appendingPathComponent("\($0)-\(address).json") }
    }
}
#endif
