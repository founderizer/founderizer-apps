import FleetCore
import Foundation
import Testing
@testable import FleetStoreKeys

/// **The steps of a Save** (`StoreSave`) against a store and a hub in memory.
struct StoreSaveTests {
    private func save(_ store: FakeStore, _ steps: FakeSteps, job: StoreKeyJob = Invented.job(),
                      key: (any OwnerKey)? = SoftwareOwnerKey()) -> StoreSave {
        StoreSave(job: job, value: "sk_test_invented", store: store, steps: steps, signer: key.map(StoreSigner.init),
                  time: { 1_795_000_000 })
    }

    private let vault: @Sendable () async throws -> String = { Invented.reference }
    private let replace: @Sendable (String) async throws -> Void = { _ in }

    private func item(note: String? = nil, project: String = Invented.project) -> StoreItem {
        let job = Invented.job()
        return StoreItem(id: Invented.item, project: project, name: job.itemName, note: note ?? job.mark)
    }

    /// The bug: a second item after a timeout, because a Try again creates again.
    @Test func oneCreateOnlyAndAfterAnUnknownOutcomeEachTryAgainFinds() async {
        let store = FakeStore(), steps = FakeSteps()
        await store.set { $0.createAnswers = [.unknown] }
        let saving = save(store, steps)
        #expect(await saving.first(clock: Clocks.good, vault: vault, replace: replace) == .stopped(.unknown))
        #expect(await steps.log == ["open"])                        // nothing goes to the hub after an unknown create
        // The hub's row stays `creating`; a hub that says `first` again gets the find path too.
        await steps.set { $0.opens = [.first, .creating] }
        #expect(await saving.first(clock: Clocks.good, vault: vault, replace: replace) == .stopped(.notFoundYet))
        #expect(await saving.first(clock: Clocks.good, vault: vault, replace: replace) == .stopped(.notFoundYet))
        #expect(await store.count("create") == 1)
        #expect(await store.count("find") == 2)
    }

    /// The bug: a row that a refused or unsent create leaves `creating`, so the request waits for an item that never
    /// comes; or a vault entry for a key that the store refused; or no new writer check after a refused create.
    @Test func aRefusedOrUnsentCreateDeletesItsOwnRowAndChecksTheWriterAgain() async {
        let store = FakeStore(), steps = FakeSteps()
        await store.set { $0.createAnswers = [.refused]; $0.canWriteAnswer = .noAccess }
        let vaulted = Counter()
        let counted: @Sendable () async throws -> String = { await vaulted.add(); return Invented.reference }
        let saving = save(store, steps)
        #expect(await saving.first(clock: Clocks.good, vault: counted, replace: replace)
                == .stopped(.refused(.definite(.lostProject))))
        #expect(await steps.noneIDs == steps.openIDs)
        #expect(await store.log == ["create", "signIn", "canWrite"])
        // Not sent, and the hub does not answer its `none`: the next try sends it first, then a create is allowed.
        await store.set { $0.createAnswers = [.notSent, .made(Invented.item)] }
        await steps.set { $0.refuseNone = true }
        #expect(await saving.first(clock: Clocks.good, vault: counted, replace: replace) == .stopped(.notSent))
        await steps.set { $0.refuseNone = false }
        #expect(await saving.first(clock: Clocks.good, vault: counted, replace: replace) == .saved(secret: Invented.reference))
        let ids = await steps.openIDs
        #expect(await steps.noneIDs == [ids[0], ids[1]])
        #expect(await steps.log.suffix(3) == ["none", "open", "made"])
        #expect(await vaulted.count == 1)
    }

    /// On the find path the Mac signs only an item that it read as its own and whose update answered 200. The bug: a
    /// signed record for an item that a list answer named, or for one whose update failed.
    @Test func theFindPathSignsOnlyAfterItsOwnReadAndUpdate() async throws {
        let log = LoggingKey.Log()
        let key = LoggingKey(log: log)
        for (found, update) in [(item(note: "another mark"), StoreUpdate.updated),
                                (item(project: Invented.ownProject), .updated),
                                (item(), .failed(.noAnswer))] {
            let store = FakeStore(), steps = FakeSteps()
            await store.set { $0.findAnswer = .items([found]); $0.updateAnswer = update }
            await steps.set { $0.opens = [.creating] }
            _ = await save(store, steps, key: key).first(clock: Clocks.good, vault: vault, replace: replace)
            #expect(log.all.isEmpty)
            #expect(await steps.made.isEmpty)
        }
        let store = FakeStore(), steps = FakeSteps()
        await store.set { $0.findAnswer = .items([self.item()]) }
        await steps.set { $0.opens = [.creating] }
        #expect(await save(store, steps, key: key).first(clock: Clocks.good, vault: vault, replace: replace)
                == .saved(secret: Invented.reference))
        #expect(await store.log == ["find", "update"])
        #expect(await store.updated.map(\.1) == ["sk_test_invented"])
        #expect(log.all == ["sign"])
        let made = try #require(await steps.made.first)
        #expect(made.remote == Invented.item)
        #expect(made.statement == Invented.job().statement(remote: Invented.item, at: 1_795_000_000))
        // Two items with the mark: the Mac changes none.
        let twins = FakeStore(), hub = FakeSteps()
        await twins.set { $0.findAnswer = .items([self.item(), self.item()]) }
        await hub.set { $0.opens = [.creating] }
        #expect(await save(twins, hub).first(clock: Clocks.good, vault: vault, replace: replace) == .stopped(.twins))
        #expect(await twins.count("update") == 0)
    }

    /// The bug: an item that no record can name, from a Mac with a wrong clock or with no owner key.
    @Test func aWrongClockOrNoOwnerKeyMakesNoCall() async {
        for (clock, key) in [(Clocks.wrong, SoftwareOwnerKey() as (any OwnerKey)?), (Clocks.good, nil)] {
            let store = FakeStore(), steps = FakeSteps()
            let saving = save(store, steps, key: key)
            let first = await saving.first(clock: clock, vault: vault, replace: replace)
            let second = await saving.second(secret: Invented.reference, clock: clock, replace: replace)
            #expect(first == second)
            let words = VaultPlan.clockProblem(hubTime: clock.hubTime, readAt: clock.readAt)
            #expect(first == (key == nil ? .stopped(.noOwnerKey) : words.map { .stopped(.clock($0)) }))
            #expect(await store.log.isEmpty)
            #expect(await steps.log.isEmpty)
        }
    }

    /// A second Save writes only the record's own item, and the store before the vault. The bug: the Mac changes an
    /// old item; the vault has a value that the store refused; a record of a new Mac never comes back.
    @Test func aSecondSaveWritesItsOwnItemBeforeTheVault() async throws {
        let owner = SoftwareOwnerKey()
        let job = Invented.job()
        let statement = job.statement(remote: Invented.item, at: 1_794_000_000)
        let made: [String: Any] = ["need": 42, "remote": Invented.item, "statement": statement,
                                   "signature": try owner.sign(statement)]
        let recorded = Invented.job(Invented.target(made: made))
        let order = LoggingKey.Log()
        let replaced: @Sendable (String) async throws -> Void = { _ in order.add("replace") }
        // Not its own item: no update and no replace.
        let foreign = FakeStore(), hub = FakeSteps()
        await foreign.set { $0.readAnswer = .item(self.item(note: "founderizer-store-key:other")) }
        #expect(await save(foreign, hub, job: recorded, key: owner).second(secret: Invented.reference, clock: Clocks.good, replace: replaced)
                == .stopped(.notOwn))
        #expect(await foreign.log == ["read"])
        // An update that fails: no replace.
        let failing = FakeStore()
        await failing.set { $0.readAnswer = .item(self.item()); $0.updateAnswer = .failed(.noAnswer) }
        _ = await save(failing, FakeSteps(), job: recorded, key: owner).second(secret: Invented.reference, clock: Clocks.good, replace: replaced)
        #expect(order.all.isEmpty)
        // Its own item: the update, then the replace; the record's statement checks, so `updated` carries none.
        let store = FakeStore(), steps = FakeSteps()
        await store.set { $0.readAnswer = .item(self.item()) }
        let ordered: @Sendable (String) async throws -> Void = { _ in
            order.add(await store.log.last == "update" ? "replace after update" : "replace first")
        }
        #expect(await save(store, steps, job: recorded, key: owner).second(secret: Invented.reference, clock: Clocks.good, replace: ordered)
                == .saved(secret: Invented.reference))
        #expect(order.all == ["replace after update"])
        let kept = try #require(await steps.updatedWith.first)
        #expect(kept.statement == nil && kept.signature == nil)
        // Another owner key (a new Mac): a new statement of the row's own fields, after its own update.
        let newMac = FakeStore(), newSteps = FakeSteps()
        await newMac.set { $0.readAnswer = .item(self.item()) }
        _ = await save(newMac, newSteps, job: recorded).second(secret: Invented.reference, clock: Clocks.good, replace: replace)
        let renewed = try #require(await newSteps.updatedWith.first)
        #expect(renewed.statement == job.statement(remote: Invented.item, at: 1_795_000_000))
        // A remote of the hub that is no STORE_UUID reaches no call.
        let odd = FakeStore(), oddSteps = FakeSteps()
        await oddSteps.set { $0.opens = [.made(secret: Invented.reference, remote: "../\(Invented.item)")] }
        #expect(await save(odd, oddSteps).first(clock: Clocks.good, vault: vault, replace: replace) == .stopped(.notOwn))
        #expect(await odd.log.isEmpty)
    }
}

actor Counter {
    var count = 0
    func add() { count += 1 }
}
