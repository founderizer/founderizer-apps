@testable import FleetCore
import Foundation
import Security
import Testing
@testable import FleetStoreKeys

/// **The writer check and step `no_writer`.**
struct StoreWriterTests {
    /// The bug: a network fault removes the writer row and closes the owner's card, a copy that is not the
    /// Developer ID build (which reads no keychain item) asks for a new key, or one card sends it again and again.
    @Test func noWriterGoesOnceForEachCardOnlyFromTheDeveloperIDBuildAfterADefiniteCause() {
        #expect(!NoWriterLedger(developerID: false).sends(need: 7, after: .definite(.noKey)))
        let ledger = NoWriterLedger(developerID: true)
        #expect(!ledger.sends(need: 7, after: .noAnswer))
        #expect(!ledger.sends(need: 7, after: .works))
        #expect(ledger.sends(need: 7, after: .definite(.lostProject)))
        #expect(!ledger.sends(need: 7, after: .definite(.tokenRefused)))
        #expect(ledger.sends(need: 8, after: .definite(.readOnly)))
    }

    /// The definite causes, through the client and its stand-in. The bug: a token that lost its project leaves a card
    /// with Try again and no end, or a 5xx, a timeout or a locked keychain counts as a refusal.
    @Test func onlyADefiniteAnswerOfBitwardenOrOfTheKeychainCounts() async {
        let route = "/projects/\(Invented.project)"
        let cases: [(StoreWire.Reply, StoreWire.Reply, StoreWriterCheck)] = [
            (.answer(200, Invented.signIn(), [:]), .answer(404, "{}", [:]), .definite(.lostProject)),
            (.answer(200, Invented.signIn(), [:]), .answer(401, "{}", [:]), .definite(.tokenRefused)),
            (.answer(200, Invented.signIn(), [:]),
             .answer(200, "{\"id\":\"\(Invented.project)\",\"read\":true,\"write\":false}", [:]), .definite(.readOnly)),
            (.answer(400, "{\"error\":\"invalid_client\"}", [:]), .answer(200, "{}", [:]), .definite(.tokenRefused)),
            (.answer(200, Invented.signIn(organization: Invented.otherOrganization), [:]), .answer(200, "{}", [:]),
             .definite(.tokenUnusable)),
            (.answer(200, Invented.signIn(), [:]), .answer(503, "{}", [:]), .noAnswer),
            (.answer(200, Invented.signIn(), [:]), .fail(.timedOut), .noAnswer),
            (.answer(502, "{}", [:]), .answer(200, "{}", [:]), .noAnswer),
            (.fail(.notConnectedToInternet), .answer(200, "{}", [:]), .noAnswer),
            (.answer(200, Invented.signIn(), [:]),
             .answer(200, "{\"id\":\"\(Invented.project)\",\"read\":true,\"write\":true}", [:]), .works),
        ]
        for (signIn, project, outcome) in cases {
            let wire = StoreWire()
            wire.on("POST", "/connect/token", signIn)
            wire.on("GET", route, project)
            #expect(await StoreWriter.check(wire.store(), project: Invented.project) == outcome, "\(signIn) \(project)")
        }
        let wire = StoreWire()
        let make: @Sendable (String, String, String) -> (any StoreProvider)? = { _, _, _ in wire.store() }
        for (status, outcome) in [(errSecItemNotFound, StoreWriterCheck.definite(.noKey)),
                                  (errSecInteractionNotAllowed, .noAnswer), (errSecAuthFailed, .noAnswer)] {
            let found = await StoreWriter.check(account: "a", region: "us", organization: Invented.organization,
                                                project: Invented.project,
                                                keychain: { _ in .failure(.init(label: "cluster store key", status: status)) },
                                                store: make)
            #expect(found.check == outcome)
        }
        #expect(wire.calls.isEmpty)
        let garbled = await StoreWriter.check(account: "a", region: "us", organization: Invented.organization,
                                              project: Invented.project, keychain: { _ in .success(Data("no token".utf8)) })
        #expect(garbled.check == .definite(.tokenUnusable))
    }

    /// Own project: the key must write exactly one project, and not the store's. The bug: a token of another cluster,
    /// or of the whole store, passes as an own project.
    @Test func anOwnProjectTokenWritesExactlyOneProjectThatIsNotTheStores() async {
        let cases: [(StoreWritable, StoreWriterCard)] = [
            (.projects([Invented.ownProject]), .works(writeProject: Invented.ownProject)),
            (.projects([Invented.ownProject, "bbbbcccc-dddd-4eee-8fff-000011112222"]), .notOwnProject),
            (.projects([Invented.project]), .notOwnProject),
            (.projects([]), .notOwnProject),
            (.failed(.noAnswer), .noAnswer),
        ]
        for (writable, outcome) in cases {
            let store = FakeStore()
            await store.set { $0.writableAnswer = writable }
            #expect(await StoreWriter.card(store, way: .ownProject, storeProject: Invented.project) == outcome)
        }
        let whole = FakeStore()
        await whole.set { $0.canWriteAnswer = .readOnly }
        #expect(await StoreWriter.card(whole, way: .wholeProject, storeProject: Invented.project) == .cannotWrite)
        await whole.set { $0.canWriteAnswer = .writes }
        #expect(await StoreWriter.card(whole, way: .wholeProject, storeProject: Invented.project)
                == .works(writeProject: Invented.project))
    }
}
