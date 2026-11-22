import FleetCore
import Foundation

/// **One key for a cluster's store, as one Save writes it**: the fleet, the Needs-you item and its agent, and the
/// store's part of the request. It names the item in the store and its mark.
public struct StoreKeyJob: Equatable, Sendable {
    public let fleet: String
    public let need: Int
    public let agent: String
    public let target: StoreKeyTarget

    /// nil for a fleet that is no fleet id, an item that is no item, or an agent that is no agent's name.
    public init?(fleet: String, need: Int, agent: String, target: StoreKeyTarget) {
        guard fleet.range(of: "\\A[0-9a-f]{16}\\z", options: .regularExpression) != nil, need > 0,
              agent.range(of: "\\A[a-z0-9][a-z0-9-]{0,62}\\z", options: .regularExpression) != nil else { return nil }
        self.fleet = fleet; self.need = need; self.agent = agent; self.target = target
    }

    /// The item's name in the store: `<namespace>/<name>`.
    public var itemName: String { "\(target.namespace)/\(target.name)" }

    /// **The mark**, the item's note: `founderizer-store-key:<fleet id>:<repo>:<namespace>/<name>`. The find path
    /// knows an item that this Mac's create made by it, after an outcome that is not known.
    public var mark: String { "founderizer-store-key:\(fleet):\(target.repo):\(itemName)" }

    /// The owner's statement of the record of `remote`.
    func statement(remote: String, at: Int) -> String {
        OwnerStatement.storeKey(fleet: fleet, need: need, agent: agent, repo: target.repo, storeKind: target.storeKind,
                                store: target.store, namespace: target.namespace, name: target.name, remote: remote, at: at)
    }
}

/// What the hub's step `open` answers.
public enum StoreOpened: Equatable, Sendable {
    /// This command wrote the row, with state `creating`.
    case first
    /// Another command wrote the row.
    case creating
    /// The row has its secret and its item already.
    case made(secret: String, remote: String)
}

/// **The hub's steps of one store request** (`POST /ui/door/store-key`, piece H-S): the form makes one for its
/// request. A throw is the hub's refusal or no answer, in its own words.
public protocol StoreKeySteps: Sendable {
    func open(openID: String) async throws -> StoreOpened
    /// Deletes the `creating` row that the command `openID` opened.
    func none(openID: String) async throws
    func made(secret: String, remote: String, statement: String, signature: String) async throws
    func updated(statement: String?, signature: String?) async throws
}

/// The hub's clock as the store's last state read it, for the clock check of `GrantSigning.checkClock`.
public struct StoreClock: Sendable {
    public let hubTime: Double?
    public let readAt: Double?
    public init(hubTime: Double?, readAt: Double?) { self.hubTime = hubTime; self.readAt = readAt }
}

/// **This Mac's owner key, for the record's statement.** CryptoKit's keys are immutable values, so one key may sign
/// from the save's actor.
public struct StoreSigner: @unchecked Sendable {
    let key: any OwnerKey
    public init(_ key: any OwnerKey) { self.key = key }
}

/// **Why a save stopped.** Each one but `refused` with a definite cause has Try again.
public enum StoreStop: Equatable, Sendable {
    /// This Mac holds no owner key: nothing went out.
    case noOwnerKey
    /// This Mac's clock and the hub's are more than an hour apart, in `VaultPlan.clockProblem`'s words: nothing went
    /// out.
    case clock(String)
    /// A step of the hub was refused or not answered, in its words.
    case hub(String)
    /// The store refused the create: nothing was made there. The writer check that followed it.
    case refused(StoreWriterCheck)
    /// The create was not sent: nothing was sent there.
    case notSent
    /// Founderizer does not know if the store took the key: Try again looks for it, and makes no second one.
    case unknown
    /// The find path found no item with the mark yet.
    case notFoundYet
    /// The find path found two items with the mark: the Mac changes none.
    case twins
    /// The item in the store is not the one that this Mac made: nothing was changed.
    case notOwn
    /// The store does not have the item any more: nothing was changed.
    case gone
    /// The store did not answer a read, a find or an update.
    case store(StoreFailure)
    /// The owner key did not sign.
    case sign
    /// The vault step did not end, in its words.
    case vault(String)
}

public enum StoreSaveResult: Equatable, Sendable {
    /// The store and the vault have the key, and the hub has its record: the form answers the request with `secret`.
    case saved(secret: String)
    case stopped(StoreStop)
}

/// **The steps of one Save of a key for a cluster's store** (the design's section 4): the store comes before the
/// vault, so a save that stops makes no entry in the list, and the vault never has a value that the store refused.
///
/// - Before anything goes out: this Mac holds the owner key, and the clock check passes. Else no call at all.
/// - **One create call only.** The hub's `open` says `first` to one command; a create whose outcome is not known
///   leaves the row `creating`, and each later Try again takes the find path, which never creates. This save also
///   keeps that itself: after its own create's outcome was not known, it creates no more, whatever the hub says.
/// - The find path: `find` looks for the mark at each Try again; one item, whose project, name and note this Mac
///   read, gets the value with `update`. Two items stop the save, and none is changed.
/// - **What the Mac signs**: only a `remote` that the store confirmed to this Mac's own write, the id of its create's
///   answer or of an item that it read and whose update answered 200. Nothing of a list answer alone, of the hub or of
///   an agent reaches a signature.
/// - An update writes only an item that this Mac made: its project, name and note are the record's (`own`).
///
/// The form keeps one save for each value that it saves, so Try again goes on where the save stopped. The value
/// leaves this save after the vault step.
public actor StoreSave {
    private let job: StoreKeyJob
    private let store: any StoreProvider
    private let steps: any StoreKeySteps
    private let signer: StoreSigner?
    private let time: @Sendable () -> Int
    private var value: String?
    /// A command whose `none` did not reach the hub: the next try sends it first.
    private var noneOwed: String?
    /// This save sent a create whose outcome was not known, or that made the item: it never creates again.
    private var createdOrUnknown = false
    /// The item that the store confirmed to this save's own write, on the path of a first Save.
    private var remote: String?
    /// The reference of the key in the vault, once the vault step of a first Save ended.
    private var secret: String?
    private var signed: (statement: String, signature: String)?
    /// The path of a second Save, once this save took it: the record's item and the key's reference. Each Try again
    /// goes on there, so a first Save whose row had its item never makes a second entry in the vault.
    private var again: (remote: String, secret: String, recorded: StoreKeyMade?)?
    /// On that path: this save wrote the value into the item, and then into the vault.
    private var againWritten = false
    private var againReplaced = false

    public init(job: StoreKeyJob, value: String, store: any StoreProvider, steps: any StoreKeySteps, signer: StoreSigner?,
                time: @escaping @Sendable () -> Int = { OwnerStatement.now() }) {
        self.job = job; self.value = value; self.store = store; self.steps = steps; self.signer = signer
        self.time = time
    }

    /// **A first Save** (steps 0 to 5): open, then the create or the find path, the vault step (`vault`: seal, add and
    /// intake of today, which gives the reference), the signed record and step `made`. A row that has its item already
    /// takes the path of a second Save, with `replace` (the replace of a key's value under its reference).
    public func first(clock: StoreClock, vault: @escaping @Sendable () async throws -> String,
                      replace: @escaping @Sendable (String) async throws -> Void) async -> StoreSaveResult {
        if let stop = ready(clock) { return .stopped(stop) }
        if let again { return await second(again, replace: replace) }
        if remote == nil {
            if let owed = noneOwed {
                do { try await steps.none(openID: owed) } catch { return .stopped(.hub(Self.words(error))) }
                noneOwed = nil
            }
            let openID = UUID().uuidString.lowercased()
            let opened: StoreOpened
            do { opened = try await steps.open(openID: openID) } catch { return .stopped(.hub(Self.words(error))) }
            switch opened {
            case .made(let secret, let remote):
                again = (remote, secret, nil)
                return await second((remote, secret, nil), replace: replace)
            case .first where !createdOrUnknown:
                if let stop = await create(openID: openID) { return .stopped(stop) }
            case .first, .creating:
                if let stop = await findOwn() { return .stopped(stop) }
            }
        }
        guard let remote else { return .stopped(.unknown) }
        if secret == nil {
            do { secret = try await vault() } catch { return .stopped(.vault(Self.words(error))) }
            value = nil
        }
        guard let secret, let signer else { return .stopped(.noOwnerKey) }
        if signed == nil {
            let statement = job.statement(remote: remote, at: time())
            guard let signature = try? signer.key.sign(statement) else { return .stopped(.sign) }
            signed = (statement, signature)
        }
        guard let signed else { return .stopped(.sign) }
        do {
            try await steps.made(secret: secret, remote: remote, statement: signed.statement, signature: signed.signature)
        } catch { return .stopped(.hub(Self.words(error))) }
        return .saved(secret: secret)
    }

    /// **A second Save** of a key that the store has (a request with `failed`, the key's own card, Add secret under
    /// the same name): the record's item first, then `replace` in the vault, then step `updated`. `secret` is the
    /// key's reference, and the job's `need` is the record's (`made.need`).
    public func second(secret: String, clock: StoreClock,
                       replace: @escaping @Sendable (String) async throws -> Void) async -> StoreSaveResult {
        if let stop = ready(clock) { return .stopped(stop) }
        // The job of a second Save names the record's own item (`made.need`): the statement's fields are the row's.
        guard let made = job.target.made, made.need == job.need else { return .stopped(.notOwn) }
        if again == nil { again = (made.remote, secret, made) }
        return await second(again ?? (made.remote, secret, made), replace: replace)
    }

    // MARK: the steps

    /// Step 0: the owner key and the clock.
    private func ready(_ clock: StoreClock) -> StoreStop? {
        guard signer != nil else { return .noOwnerKey }
        if let problem = VaultPlan.clockProblem(hubTime: clock.hubTime, readAt: clock.readAt) { return .clock(problem) }
        return nil
    }

    /// Step 2: one create call. nil when it made the item.
    private func create(openID: String) async -> StoreStop? {
        guard let value else { return .unknown }
        switch await store.create(name: job.itemName, value: value, note: job.mark, project: job.target.project) {
        case .made(let id):
            createdOrUnknown = true
            remote = id
            return nil
        case .unknown:
            // Nothing goes to the hub: the row stays `creating`, and each Try again takes the find path.
            createdOrUnknown = true
            return .unknown
        case .refused:
            await deleteRow(openID)
            // A token can end between the card's opening and the Save: the check says whether it did.
            return .refused(await StoreWriter.check(store, project: job.target.project))
        case .notSent:
            await deleteRow(openID)
            return .notSent
        }
    }

    /// Step `none` for the command that opened the row: nothing was made, so the next try may create again.
    private func deleteRow(_ openID: String) async {
        do { try await steps.none(openID: openID) } catch { noneOwed = openID }
    }

    /// Step 3, the find path: never a create call. nil when the one item with the mark got this save's value.
    private func findOwn() async -> StoreStop? {
        guard let value else { return .unknown }
        switch await store.find(name: job.itemName, note: job.mark, project: job.target.project) {
        case .failed(let failure): return .store(failure)
        case .items(let items):
            guard !items.isEmpty else { return .notFoundYet }
            guard items.count == 1 else { return .twins }
            guard let own = Self.own(items[0], id: items[0].id, job: job) else { return .notOwn }
            switch await store.update(own, value: value) {
            case .updated:
                remote = own.id
                return nil
            case .gone: return .notFoundYet
            case .failed(let failure): return .store(failure)
            }
        }
    }

    /// The path of a second Save: read the record's item, update it, replace the vault's value, step `updated`.
    private func second(_ path: (remote: String, secret: String, recorded: StoreKeyMade?),
                        replace: @escaping @Sendable (String) async throws -> Void) async -> StoreSaveResult {
        let (remote, secret, recorded) = path
        // The hub names the item and the key: an item that is no STORE_UUID, or a key that is no reference of the
        // list, reaches no call and no replace.
        guard StoreUUID.valid(remote), LoginSecret.isReference(secret) else { return .stopped(.notOwn) }
        if !againWritten {
            guard let value else { return .stopped(.unknown) }
            let own: OwnStoreItem
            switch await store.read(id: remote) {
            case .item(let item):
                guard let mine = Self.own(item, id: remote, job: job) else { return .stopped(.notOwn) }
                own = mine
            case .gone: return .stopped(.gone)
            case .failed(let failure): return .stopped(.store(failure))
            }
            switch await store.update(own, value: value) {
            case .updated: againWritten = true
            case .gone: return .stopped(.gone)
            case .failed(let failure): return .stopped(.store(failure))
            }
        }
        if !againReplaced {
            do { try await replace(secret) } catch { return .stopped(.vault(Self.words(error))) }
            againReplaced = true
            value = nil
        }
        guard let signer else { return .stopped(.noOwnerKey) }
        // A record whose statement this Mac's owner key did not sign (a new Mac, a new owner key), or that this save
        // does not know, gets a new statement of its own fields: only now, after this Mac's own update answered 200.
        var statement: String?
        var signature: String?
        if !(recorded.map { Self.checks($0, job: job, key: signer.key) } ?? false) {
            let text = job.statement(remote: remote, at: time())
            guard let made = try? signer.key.sign(text) else { return .stopped(.sign) }
            statement = text
            signature = made
        }
        do { try await steps.updated(statement: statement, signature: signature) } catch {
            return .stopped(.hub(Self.words(error)))
        }
        return .saved(secret: secret)
    }

    /// **The item as this Mac made it**: the id that the record names, the record's project, the name
    /// `<namespace>/<name>` and the mark, all as the store gave them back. Else nil, and nothing writes the item.
    static func own(_ item: StoreItem, id: String, job: StoreKeyJob) -> OwnStoreItem? {
        guard StoreUUID.valid(id), item.id == id, item.project == job.target.project, item.name == job.itemName,
              item.note == job.mark else { return nil }
        return OwnStoreItem(id: id, project: job.target.project, name: job.itemName, note: job.mark)
    }

    /// Whether this Mac's owner key signed the record's statement of exactly this job and item.
    static func checks(_ made: StoreKeyMade, job: StoreKeyJob, key: any OwnerKey) -> Bool {
        let record = StoreKeyRecord(repo: job.target.repo, store_kind: job.target.storeKind, store: job.target.store,
                                    remote: made.remote, namespace: job.target.namespace, name: job.target.name,
                                    agent: job.agent, need: made.need, statement: made.statement, signature: made.signature)
        return record.kept(ownerKey: key.publicKey, fleet: job.fleet, agent: job.agent, repo: job.target.repo)
    }

    private static func words(_ error: Error) -> String { error.localizedDescription }
}
