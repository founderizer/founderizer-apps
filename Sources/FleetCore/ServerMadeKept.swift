#if os(macOS)
import Foundation
import os

/// **How this Mac's records of the servers that it made reach the hub, signed** (F17's SP1; `ServerMade`).
///
/// Two ways, and no other:
///
/// 1. **A server that this run of the app makes** is signed from the provider's answer in memory (`Fresh`, from
///    `FleetCloudModel.build`), never from a file: a program that runs as the owner's user can write this Mac's files
///    and settings, but it cannot make a statement that this Mac's owner key signs.
/// 2. **The servers that this Mac's files held before** (`BuildRecord`, `MadeServers`) are signed from those files,
///    only while the hub does not say that this key moved them (`Listing.swept`), and only from a record with no mark
///    beside it: once the hub kept a server's statement and answered, the record gets a mark beside it (an empty file
///    `<id>.swept`, `KeptRecords.sweep`; a copy of the entry in a list of its own, `MadeServers.sweep`), and the record
///    itself stays where it is, so every other reader, an older build of the app too, has it as before. A sweep so
///    needs both, a record with no mark and the hub's "not swept": a program of the owner's user alone, and a hub that
///    is broken into alone, open nothing. Nothing of it is in the keychain.
///
/// **Only for the fleet that this Mac pinned for the hub's address** (`pinnedFleet`): the fleet's id that the hub names
/// is the hub's word, and a hub that is broken into could name another fleet of this Mac, whose key would then sign
/// this hub's servers.
///
/// **What was signed stays on this Mac** (`Statements`), and each round sends what the hub lacks of it: an answer that
/// was lost and a hub that was restored from an older copy both heal so. The hub hears `swept` only when it keeps a
/// record of this key and each statement is kept, or settled for good, and this Mac believes the word only then.
extension ServerMade {

    // MARK: - The fleet

    /// **The fleet whose records this Mac signs and counts for `hub`**: the one that the hub names, only when it is the
    /// one fleet whose central vault this Mac pinned at this address itself, from root's own output over its own SSH
    /// (`CentralVaultPins`). With two pins at one address (a hub that was made new there) the hub's word would choose
    /// between two keys of this Mac: then none.
    public static func pinnedFleet(hub: URL, named fleet: String?, in defaults: UserDefaults = AppDefaults.store) -> String? {
        guard let fleet, CentralVaultPins.fleets(hub: hub, in: defaults) == [fleet] else { return nil }
        return fleet
    }

    // MARK: - This Mac's old records

    /// **This Mac's records of the servers that it made**: every build's, those of them with no mark beside them, and
    /// the entries of `MadeServers` for the hub with no mark beside them.
    public struct Files: Sendable {
        public let builds: [BuildRecord]
        public let unswept: [BuildRecord]
        public let made: [String: String]

        public init(builds: [BuildRecord], unswept: [BuildRecord], made: [String: String]) {
            self.builds = builds; self.unswept = unswept; self.made = made
        }

        /// An entry names an id that no build names: only a provider's list can say at which provider its server is.
        var needsLists: Bool {
            let built = Set(builds.compactMap(\.serverID))
            return made.values.contains { CloudServers.isID($0) && !built.contains($0) }
        }
    }

    /// Old records that get a mark beside them: builds by their id, and entries of `MadeServers` by name and id.
    public struct Old: Equatable, Sendable {
        public var builds: Set<UUID> = []
        public var entries: [String: String] = [:]
        public init(builds: Set<UUID> = [], entries: [String: String] = [:]) { self.builds = builds; self.entries = entries }
        public var isEmpty: Bool { builds.isEmpty && entries.isEmpty }
    }

    /// **What this Mac's old records say of the servers that it made for `hub`**, one server for each id:
    ///
    /// - each build of this hub with the provider's id (`StartAgain.isOwn`), as it was made, the hub's own server too;
    /// - each entry of `MadeServers` with an id that no build of this hub names: by the build that names its id when
    ///   that build has no hub yet and the entry's name (a first run's server, whose `use` the build says), and else
    ///   when exactly one provider's list holds it (`StartAgain.listedMade`), as a server for agents; never the hub's
    ///   own machine (`hubMachine`, the hub's word, which can only hold a signature back). While a held provider's list
    ///   did not come for a fault of the moment (`waits`, `listWaits`) such an entry waits (`open`): a list that is not
    ///   there says nothing of where its server is. It waits too while the hub names no machine of its own: then it
    ///   could be the hub's own server, whose build left the kept ones, and a record of it as a server for agents would
    ///   stay so. A provider whose token is gone or refused has no list, and says no more later.
    ///
    /// `settled`: each other record of this hub with an id. Nothing here can say more of it, so it gets no statement
    /// and stays this Mac's own proof.
    public struct Kept: Equatable, Sendable {
        public let servers: [Fields]
        public let settled: Old
        /// An entry waits for a provider's list.
        public let open: Bool
    }

    public static func kept(hub: URL, files: Files, hubMachine: String? = nil, listed: [CloudProvider: [CloudExisting]],
                            waits: Bool) -> Kept {
        var servers: [Fields] = [], seen = Set<String>(), settled = Old(), open = false
        func add(_ fields: Fields?) -> Bool {
            guard let fields else { return false }
            if seen.insert(fields.server).inserted { servers.append(fields) }
            return true
        }
        for build in files.unswept where StartAgain.isOwn(build, hub: hub) {
            guard let id = build.serverID else { continue }
            if !add(Fields(machine: build.name.lowercased(), provider: build.provider, id: id, use: build.use)) {
                settled.builds.insert(build.id)
            }
        }
        let own = Set(files.builds.filter { StartAgain.isOwn($0, hub: hub) }.compactMap(\.serverID))
        let built = Set(files.builds.compactMap(\.serverID))
        let proven = StartAgain.listedMade(files.made, except: built, listed: listed)
        for (name, id) in files.made.sorted(by: { $0.key < $1.key }) where CloudServers.isID(id) && !own.contains(id) {
            var fields: Fields?
            if let build = files.builds.first(where: { $0.serverID == id }) {
                if build.hub == nil, build.name.lowercased() == name {
                    fields = Fields(machine: name, provider: build.provider, id: id, use: build.use)
                }
            } else if waits || hubMachine == nil {
                open = true
                continue
            } else if name != hubMachine?.lowercased(),
                      let one = proven.first(where: { $0.server.id == id && $0.server.name.lowercased() == name }) {
                fields = Fields(machine: name, provider: one.provider, id: id, use: .agent)
            }
            if !add(fields) { settled.entries[name] = id }
        }
        return Kept(servers: servers, settled: settled, open: open)
    }

    // MARK: - A server that this run of the app made

    /// **The servers that this run of the app made, by the hub that they were made for**, from the provider's answer
    /// in memory, until a round signs them, which needs no hub (`sweep`). A server that no round signed by the app's
    /// end (no pin, no owner key) is in this Mac's own files alone.
    public enum Fresh {
        private static let held = OSAllocatedUnfairLock<[String: [Fields]]>(initialState: [:])

        /// The build of a server for `hub` got the provider's answer, or the server goes to `hub` now (a first run's
        /// second try): it is no other hub's.
        public static func add(_ made: Fields, hub: URL) {
            held.withLock { all in
                all = all.mapValues { servers in servers.filter { $0.server != made.server } }
                all[hub.absoluteString, default: []].append(made)
            }
        }

        /// The servers made for `hub` since the last take, which a round signs now.
        public static func take(hub: URL) -> [Fields] {
            held.withLock { $0.removeValue(forKey: hub.absoluteString) ?? [] }
        }

        /// Servers that a round could not sign: they wait for the next one.
        public static func putBack(_ made: [Fields], hub: URL) {
            guard !made.isEmpty else { return }
            held.withLock { $0[hub.absoluteString, default: []].insert(contentsOf: made, at: 0) }
        }

        /// Whether a server of `hub` waits to be signed.
        public static func holds(hub: URL) -> Bool { held.withLock { !($0[hub.absoluteString] ?? []).isEmpty } }

        /// The app forgets the fleet of `hub`.
        public static func drop(hub: URL) { held.withLock { _ = $0.removeValue(forKey: hub.absoluteString) } }
    }

    // MARK: - What this Mac signed

    /// One statement that this Mac signed, with what it says.
    public struct Statement: Equatable, Sendable {
        public var signed: Signed
        public let made: Fields
        public init(signed: Signed, made: Fields) { self.signed = signed; self.made = made }
    }

    /// **The statements that this Mac signed, kept for good**: one file for each fleet and signer, beside the records
    /// with a mark beside them. The file is no proof of anything: a program of the owner's user can write it, so a
    /// read takes only a `server-made` of that fleet that that very key signed, and the server from the text itself. A
    /// statement of another key is in another file, and hides no server from this one. What this build does not read
    /// (a later build's statement, of a provider that this build does not know) stays in the file as it is, and a file
    /// that is not a list is moved aside before a write: the heal of a restored hub needs each statement.
    public struct Statements: Sendable {
        let folder: URL
        public init(folder: URL) { self.folder = folder }
        public static let app = Statements(folder: KeptRecordsPlace.folder("server-made"))
        /// The largest file that is read, and the most statements of it: the hub keeps 256 of one signer.
        static let largest = 1024 * 1024, most = 1024

        private func file(fleet: String, key: String) -> URL? {
            guard CentralVault.isFleet(fleet), let by = ServerMade.by(key) else { return nil }
            return folder.appendingPathComponent("\(fleet)-\(by).json", isDirectory: false)
        }

        public func all(fleet: String, key: String) -> [Statement] {
            guard let file = file(fleet: fleet, key: key),
                  let data = KeptFile.bytes(of: file, atMost: Self.largest, followsLinks: false),
                  let kept = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
            var seen = Set<String>()
            return kept.prefix(Self.most).compactMap { entry in
                guard let signed = entry.signed, signed.key == key, let made = ServerMade.fields(of: signed.statement, fleet: fleet),
                      ServerMade.verifies(signed.statement, signature: signed.signature, key: key),
                      seen.insert(made.server).inserted else { return nil }
                return Statement(signed: signed, made: made)
            }
        }

        public func keep(_ statements: [Statement], fleet: String, key: String) throws {
            guard let file = file(fleet: fleet, key: key) else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let ours = try JSONSerialization.jsonObject(with: JSONEncoder().encode(statements.map(\.signed))) as? [Any] ?? []
            try JSONSerialization.data(withJSONObject: ours + unread(file, besides: statements))
                .write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        /// The entries of the file that are not among `statements`, as they are. A file that is not a list (or that is
        /// too large, or a link) is moved aside, and is not written over.
        private func unread(_ file: URL, besides statements: [Statement]) -> [Any] {
            guard (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil else { return [] }
            if let data = KeptFile.bytes(of: file, atMost: Self.largest, followsLinks: false),
               let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                let texts = Set(statements.map(\.signed.statement))
                return entries.filter { (($0 as? [String: Any])?["statement"] as? String).map { !texts.contains($0) } ?? true }
            }
            let aside = "\(file.lastPathComponent).unread-\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.moveItem(at: file, to: folder.appendingPathComponent(aside, isDirectory: false))
            return []
        }

        /// One entry of the file: a statement that this build reads, or nil.
        private struct Entry: Decodable {
            let signed: Signed?
            init(from decoder: any Decoder) { signed = try? Signed(from: decoder) }
        }

        /// The app forgets this fleet ("Start again"): its statements go, of every key, and the files moved aside.
        public func forget(fleet: String) {
            guard CentralVault.isFleet(fleet) else { return }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix("\(fleet)-") {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: false))
            }
        }
    }

    /// The app forgets the fleets that this Mac pinned at `hub` ("Start again"): what waits to be signed for it, and
    /// what was signed. Before the pins go.
    public static func forget(hub: URL, in defaults: UserDefaults = AppDefaults.store, statements: Statements = .app) {
        Fresh.drop(hub: hub)
        for fleet in CentralVaultPins.fleets(hub: hub, in: defaults) { statements.forget(fleet: fleet) }
    }

    // MARK: - When a round runs

    /// **Whether a round reads this Mac's files, and why not** (`Pace.files`). Only a round that read them, or one
    /// after a round of this start that read them and did all that it had, tells the hub `swept`: a round whose files
    /// wait for the next start read none, and its `swept` would keep them from the hub for good.
    public enum FileRead: Equatable, Sendable {
        /// The files are read in this round.
        case read
        /// A round of this hub generation and fleet read them in this start and did all that it had.
        case closed
        /// `VaultTries.most` rounds of this hub generation and fleet waited in a row, in this start: the files wait for
        /// the next start of the app.
        case givenUp
    }

    /// **When the app's sweep runs a round**: at most one look a minute, ten minutes after a round that waits
    /// (`VaultTries.wait`), and none any more for a hub generation and fleet once a round did all that it had, or after
    /// `VaultTries.most` rounds in a row that waited, in this start of the app. A server that this run made is signed
    /// at the next look, with the files closed or given up; one that a round could not sign waits the ten minutes too,
    /// so a keychain that is locked is not asked each minute.
    public struct Pace: Sendable {
        public static let every: TimeInterval = 60
        private var looked: Date?
        private var waits: Date?
        private var freshWaits = false
        private var done: Set<String> = []
        private var failed: [String: Int] = [:]
        public init() {}

        /// `fresh`: a server of this run waits to be signed.
        public func due(_ now: Date, fresh: Bool) -> Bool {
            if let looked, now.timeIntervalSince(looked) < Self.every { return false }
            if !fresh || freshWaits, let waits, now.timeIntervalSince(waits) < VaultTries.wait { return false }
            return true
        }
        public mutating func look(at now: Date) { looked = now }
        /// `name`: the hub's generation and the fleet that it names.
        public func runs(_ name: String, fresh: Bool) -> Bool { fresh || files(name) == .read }
        /// Whether a round of this name reads the files: until a round that read them did all that it had, or gave up.
        public func files(_ name: String) -> FileRead {
            if done.contains(name) { return .closed }
            return failed[name, default: 0] < VaultTries.most ? .read : .givenUp
        }
        /// `files`: what the round had of the files (`files(_:)` at its start); one whose files were given up closes
        /// nothing, so a later round of this start does not take its end for the files' end. `freshLeft`: a server of
        /// this run waits still.
        public mutating func ended(_ name: String, done all: Bool, files: FileRead, freshLeft: Bool, at now: Date) {
            if files != .givenUp {
                if all { done.insert(name) }
                failed[name] = all ? nil : failed[name, default: 0] + 1
            }
            waits = all ? nil : now
            freshWaits = !all && freshLeft
        }
    }

    /// **This start of the app**, for a refusal for good (`Signed.refusedIn`): another one at each start.
    public static let thisStart = UUID().uuidString

    // MARK: - One round

    /// **What one round reaches**, from the sweep of the app (`ServerMadeModel`) or a test.
    public struct Sweep {
        public let hub: URL
        /// The fleet and the machine of the hub that the hub's vault reading names: the hub's word.
        public let named: String?
        public let hubMachine: String?
        /// Why this Mac's clock signs nothing now (`VaultPlan.clockProblem`), or nil.
        public let clock: String?
        /// Whether the files are read in this round, and why not (`Pace.files`).
        public let fileRead: FileRead
        /// This start of the app (`ServerMade.thisStart`): a statement that the hub refused for good goes again at the
        /// next one.
        public let start: String
        /// This Mac's owner key for a fleet: it signs, and it is the one anchor of the hub's records here.
        public let key: (String) -> (any OwnerKey)?
        public let listing: () async throws -> Listing
        public let send: (Signed) async throws -> Receipt
        /// The hub is told that this key's files were moved (`POST /ui/servers/made/swept`).
        public let swept: (String) async throws -> Void
        public let files: () -> Files
        /// Each held provider's list, only when an entry needs one; `waits` when one did not come for a fault of the
        /// moment (`listWaits`).
        public let lists: () async -> (listed: [CloudProvider: [CloudExisting]], waits: Bool)
        /// These old records get a mark beside them.
        public let move: (Old) -> Void
        public let statements: Statements
        public let defaults: UserDefaults

        public init(hub: URL, named: String?, hubMachine: String?, clock: String?, fileRead: FileRead,
                    start: String = ServerMade.thisStart,
                    key: @escaping (String) -> (any OwnerKey)?, listing: @escaping () async throws -> Listing,
                    send: @escaping (Signed) async throws -> Receipt, swept: @escaping (String) async throws -> Void,
                    files: @escaping () -> Files,
                    lists: @escaping () async -> (listed: [CloudProvider: [CloudExisting]], waits: Bool),
                    move: @escaping (Old) -> Void, statements: Statements = .app,
                    defaults: UserDefaults = AppDefaults.store) {
            self.hub = hub; self.named = named; self.hubMachine = hubMachine; self.clock = clock
            self.fileRead = fileRead; self.start = start; self.key = key; self.listing = listing; self.send = send; self.swept = swept
            self.files = files; self.lists = lists; self.move = move; self.statements = statements; self.defaults = defaults
        }
    }

    /// How a round ended.
    public struct Outcome: Equatable, Sendable {
        public var signed = 0, sent = 0, refused = 0
        /// It did all that it had. Else `waits` says what it waits for, and it is tried again (`Pace`).
        public var done = false
        public var waits: String?

        public init(signed: Int = 0, sent: Int = 0, refused: Int = 0, done: Bool = false, waits: String? = nil) {
            self.signed = signed; self.sent = sent; self.refused = refused; self.done = done; self.waits = waits
        }
    }

    /// **One round.** First, with no hub: each server of this run's builds is signed and kept. Then the hub's records
    /// are read; while the hub does not say `swept` beside a record of this key, each server of the old records that has
    /// no statement of this key is signed and kept; each statement that the hub lacks goes to it (one that this hub
    /// generation refused for good in this start of the app does not), and one that it refuses stops no other; each
    /// record whose statement the hub keeps, or that is settled, gets its mark; and the hub hears `swept` when it keeps
    /// a record of this key, no record waits, and this round read the files or they are closed (`FileRead`). A hub that
    /// does not answer stops the round: what is signed stays, and the next round goes on. A round that the app stops
    /// (`Task.isCancelled`, "Start again") writes nothing more that it can still hold back.
    public static func sweep(_ sweep: Sweep, now: Int = OwnerStatement.now()) async -> Outcome {
        var outcome = Outcome()
        func waiting(_ why: String) -> Outcome {
            outcome.waits = why
            return outcome
        }
        guard let fleet = pinnedFleet(hub: sweep.hub, named: sweep.named, in: sweep.defaults) else {
            return waiting("this Mac pinned no vault of the fleet that the hub names, or more than one, at its address")
        }
        guard let key = sweep.key(fleet), let signer = ServerMade.by(key.publicKey) else {
            return waiting("this Mac has no owner key for the fleet now")
        }
        if let clock = sweep.clock { return waiting(clock) }
        var own = sweep.statements.all(fleet: fleet, key: key.publicKey)
        /// Signs each server that has no statement of this key, and keeps the statements before anything is sent.
        func sign(_ servers: [Fields]) throws {
            var all = own
            for made in servers where !all.contains(where: { $0.made.server == made.server }) {
                all.append(Statement(signed: try Signed.sign(made, fleet: fleet, key: key, at: now), made: made))
            }
            guard all.count > own.count else { return }
            guard !Task.isCancelled else { throw CancellationError() }
            try sweep.statements.keep(all, fleet: fleet, key: key.publicKey)
            outcome.signed += all.count - own.count
            own = all
        }
        /// Each old record of these servers, and each that is settled, gets its mark: a build of this hub by its
        /// provider and id, an entry of `MadeServers` by its name and id, as the statement names them.
        func move(_ servers: [Fields], _ settled: Old = Old()) {
            guard !Task.isCancelled else { return }
            let files = sweep.files(), signed = Set(servers.map(\.server))
            var old = settled
            for build in files.unswept where StartAgain.isOwn(build, hub: sweep.hub) {
                if signed.contains("\(build.provider.rawValue)|\(build.serverID ?? "")") { old.builds.insert(build.id) }
            }
            for (name, id) in files.made where servers.contains(where: { $0.machine == name && $0.id == id }) {
                old.entries[name] = id
            }
            if !old.isEmpty { sweep.move(old) }
        }

        guard !Task.isCancelled else { return waiting("the app left the fleet") }
        let fresh = Fresh.take(hub: sweep.hub)
        do { try sign(fresh) } catch {
            if !Task.isCancelled { Fresh.putBack(fresh, hub: sweep.hub) }
            return waiting(error.localizedDescription)
        }
        let listing: Listing
        do { listing = try await sweep.listing() } catch { return waiting(error.localizedDescription) }
        guard !Task.isCancelled else { return waiting("the app left the fleet") }
        guard listing.fleet == fleet else { return waiting("the hub's records are of another fleet") }
        let theirs = ServerMade.counted(listing.records, fleet: fleet, anchors: [key.publicKey])
        var held = Set(theirs.map(\.server)), keptFields = theirs
        var settled = Old(), open = false
        if sweep.fileRead == .read, !listing.swept.contains(signer) || held.isEmpty {
            let files = sweep.files()
            var lists: (listed: [CloudProvider: [CloudExisting]], waits: Bool) = ([:], false)
            if files.needsLists { lists = await sweep.lists() }
            guard !Task.isCancelled else { return waiting("the app left the fleet") }
            let found = kept(hub: sweep.hub, files: files, hubMachine: sweep.hubMachine, listed: lists.listed,
                             waits: lists.waits)
            do { try sign(found.servers) } catch { return waiting(error.localizedDescription) }
            settled = found.settled
            open = found.open
        }
        // A refusal for good holds for this hub generation in this start of the app: a release that fixes the hub
        // gets the statement at the next start.
        let generation = "\(listing.db)|\(sweep.start)"
        var settledServers: [Fields] = [], refused = false
        /// What the hub refused for good is kept as refused.
        func keepRefused() {
            if refused, !Task.isCancelled { try? sweep.statements.keep(own, fleet: fleet, key: key.publicKey) }
        }
        for index in own.indices where own[index].signed.refusedIn != generation && !held.contains(own[index].made.server) {
            let made = own[index].made
            do {
                _ = try await sweep.send(own[index].signed)
                held.insert(made.server)
                keptFields.append(made)
                outcome.sent += 1
            } catch {
                guard !Task.isCancelled else { return waiting("the app left the fleet") }
                switch refusal(error) {
                case .forGood:
                    own[index].signed.refusedIn = generation
                    refused = true
                    settledServers.append(made)
                case .noRoom:
                    settledServers.append(made)
                case nil:
                    keepRefused()
                    move(keptFields)
                    return waiting(error.localizedDescription)
                }
                outcome.refused += 1
            }
        }
        guard !Task.isCancelled else { return waiting("the app left the fleet") }
        keepRefused()
        let ended = own.filter { $0.signed.refusedIn == generation }.map(\.made)
        move(keptFields + settledServers + ended, settled)
        if open { return waiting("a provider's list did not come") }
        if !held.isEmpty, !listing.swept.contains(signer), sweep.fileRead != .givenUp {
            do { try await sweep.swept(signer) } catch {
                if refusal(error) == nil { return waiting(error.localizedDescription) }
            }
        }
        outcome.done = true
        return outcome
    }
}

extension CentralVaultPins {
    /// The fleets whose central vault this Mac pinned at this hub's address, by the names that `pin` writes.
    static func fleets(hub: URL, in defaults: UserDefaults = AppDefaults.store) -> Set<String> {
        let prefix = "\(hub.absoluteString)|"
        return Set((defaults.dictionary(forKey: key) as? [String: String] ?? [:]).keys.compactMap { name in
            guard name.hasPrefix(prefix) else { return nil }
            let fleet = String(name.dropFirst(prefix.count))
            return CentralVault.isFleet(fleet) ? fleet : nil
        })
    }
}
#endif
