import AppKit
import FleetCore
import Foundation
import SwiftUI
import Testing
@testable import Founderizer

/// **A restore that the hub refuses before it writes anything says so at once, and a resend of one that may have
/// landed is read by the generation** (the hub-side second reader's note for the Mac, round 3, and the app reader's
/// R5-1, 22 November 2026). The app read each refusal but a 409 as a copy that may have landed, watched the generation
/// for 240 seconds and then said "lost": a refusal from the hub's head or from its check of the copy writes nothing
/// (`RestoreRefusal`), so on a first send its words show at once and the copy stays chosen. But Send it again, after a
/// wait that gave up, sends the same id: its first send can have staged the copy, whose records take the room that the
/// hub's head checks (507), or the hub can have come back with the restored generation (409). Then the watch decides,
/// and the app never says "nothing was written". And when the hub came back with the restored generation after the
/// wait gave up, Send it again sends nothing: a second send would be a new command to the restored fleet, and with
/// `replace` a second restore, which loses the records that the first one kept aside (R6-1). A resend carries the
/// first send's generation. The stand-in hub answers each restore as the test gives it.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct RestoreRefusalTests {
    struct Seen: Sendable {
        let phases: [String]
        let failure: String?
        let sends: Int
        /// The generation that each send named (`db=` of its query), and its request id.
        var dbs: [String] = []
        var first = ""
        var ids: [String] = []
        /// Whether the store still reads the stand-in hub at the end.
        var stayed = true
    }

    private static let noRoom = Data(#"{"code": "restore_no_room", "names": {"free": "1.1 GB", "need": "1.2 GB"}, "error": "The hub's server has 1.1 GB free. This copy needs at least 1.2 GB there."}"#.utf8)
    private static let lostOnTheHub = Data(#"{"error": "hub error"}"#.utf8)
    /// The hub took the copy: whether it restarts itself for it.
    private static func took(restarting: Bool) -> Data {
        Data(#"{"ok": true, "fleet_id": "example", "records_bytes": 4096, "files": [], "changed": [], "removed": [], "keep_replaced": true, "restarting": \#(restarting)}"#.utf8)
    }
    private static let moved = Data(#"{"code": "hub_changed_sending", "error": "This hub changed while that was being sent."}"#.utf8)

    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("FleetCoreTests/Fixtures/copy.zip")

    private static func reading(_ db: String) throws -> Data {
        let state: [String: Any] = [
            "schema_version": 1, "db": db, "time": Int(Date().timeIntervalSince1970),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
            "reports": [], "ui_features": ["health", "restore"]]
        return try JSONSerialization.data(withJSONObject: state)
    }

    /// The restore's model with the fixture copy of FleetCoreTests chosen, on a store of the stand-in hub. `answers`
    /// are the hub's answers to the restores, in order; the first send has `replace`; `then` runs between the first
    /// send's end and Send it again, which comes only when it is given. The phase after each send, the last words, how
    /// many sends the hub saw, and the generation that each named.
    @MainActor private static func restore(_ answers: [(status: Int, body: Data)], replace: Bool = false,
                                           then: ((LoopbackHub, FleetStore) throws -> Void)? = nil,
                                           presses: Int = 1, third: Bool? = nil) throws -> Seen {
        let first = try reading("restore-\(UUID().uuidString)")
        let hub = try LoopbackHub(state: first)
        defer { hub.stop() }
        _ = ViewHost.store(try HubState.decode(first))       // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        store.state = try HubState.decode(first)
        hub.give(restore: answers)
        let model = RestoreModel()
        model.patience = 0.5                    // the wait gives up at its second look
        model.read(Self.fixture)
        guard model.phase == .chosen else { throw ViewHost.Missing(description: "the fixture copy is no copy") }
        var phases: [String] = []
        let sends = { hub.requests.filter { $0.method == "POST" && $0.path == "/ui/restore" }.count }
        let ended = { (count: Int) in        // that send reached the hub, and its answer was read to its end
            sends() == count && [.chosen, .lost, .landed, .holdsWork].contains(model.phase)
        }
        Task { await model.send(store: store, replace: replace) }
        ViewHost.turn(20) { ended(1) }
        phases.append("\(model.phase)")
        if let then {
            try then(hub, store)
            let before = hub.requests.filter { $0.path == "/ui/state" }.count
            for _ in 0..<presses {                          // Send it again: the same id; pressed `presses` times
                Task { await model.send(store: store) }
            }
            // ended by a second send, or by a look at the hub, no send and the landing (only .landed ends that path:
            // the phase is .lost too while the look waits, the validator's T1)
            ViewHost.turn(20) {
                ended(2) || (sends() == 1 && hub.requests.filter { $0.path == "/ui/state" }.count > before
                             && model.phase == .landed)
            }
            if presses > 1 { ViewHost.turn(3) }             // time for a second send, if a press made one
            phases.append("\(model.phase)")
            if let third {                                  // a third press: Replace it with the copy, or another
                Task { await model.send(store: store, replace: third) }
                ViewHost.turn(20) { ended(3) }
                phases.append("\(model.phase)")
            }
        }
        let dbs = hub.requests.filter { $0.method == "POST" && $0.path == "/ui/restore" }.map { request in
            String(request.query.split(separator: "&").first { $0.hasPrefix("db=") }?.dropFirst(3) ?? "")
        }
        return Seen(phases: phases, failure: model.failure, sends: sends(), dbs: dbs,
                    first: (try? HubState.decode(first).db) ?? "",
                    ids: hub.requests.filter { $0.method == "POST" && $0.path == "/ui/restore" }.map(\.id),
                    stayed: (try? HubClient.address(hub.address)) == store.hub)
    }

    @Test func aFirstSendThatTheHubRefusesBeforeAnyWriteShowsItsWordsAtOnce() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { try Self.restore([(507, Self.noRoom)]) }
        #expect(seen.sends == 1)
        #expect(seen.phases == ["chosen"], "a refusal before any write is no restore that may have landed")
        #expect(seen.failure == "The hub's server has 1.1 GB free. This copy needs at least 1.2 GB there.")
    }

    @Test func aResendWhoseRoomTheStagedCopyTookStaysInTheWait() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) {
            try Self.restore([(500, Self.lostOnTheHub), (507, Self.noRoom)], then: { _, _ in })
        }
        #expect(seen.sends == 2, "\(seen)")
        #expect(seen.phases == ["lost", "lost"], "a resend of a send that may have landed is no \"nothing written\"")
        #expect(seen.failure == "The hub's server has 1.1 GB free. This copy needs at least 1.2 GB there.")
    }

    /// The hub lands the first send while the resend goes up (after the resend's look at it): the resend gets the
    /// head's 409, and one read of the hub shows the moved generation, so the restore landed.
    @Test func aResendWhoseGenerationMovedDuringItsUploadHasLanded() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) {
            try Self.restore([(500, Self.lostOnTheHub)], then: { hub, _ in
                hub.give(restore: 409, body: Self.moved, thenState: try Self.reading("restored-\(UUID().uuidString)"))
            })
        }
        #expect(seen.sends == 2, "\(seen)")
        #expect(seen.phases == ["lost", "landed"], "the generation moved: the restore landed")
    }

    @Test func aResendAfterALateLandingSendsNothingAndLands() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) {
            try Self.restore([(500, Self.lostOnTheHub)], replace: true, then: { hub, store in
                hub.give(try Self.reading("restored-\(UUID().uuidString)"))
                store.addressText = "http://127.0.0.1:9"        // typed in its field, not connected
            })
        }
        #expect(seen.sends == 1, "a second send of a restore with replace restores twice: \(seen)")
        #expect(seen.phases == ["lost", "landed"], "the generation moved: the restore landed")
        #expect(seen.stayed, "after the landing the store reads the restored hub, not the typed address")
    }

    @Test func aResendCarriesTheGenerationOfItsFirstSend() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) {
            try Self.restore([(500, Self.lostOnTheHub), (507, Self.noRoom)],
                             then: { _, store in
                                 store.state = try HubState.decode(try Self.reading("its-poll-read-another"))
                             })
        }
        #expect(seen.sends == 2, "\(seen)")
        #expect(seen.dbs == [seen.first, seen.first], "the same command, with the generation of its first send")
    }

    /// A resend whose hub holds work and whose generation did not move: the hub has no answer for this id (its first
    /// send never reached it, or failed before anything was written), so its 409 offers Replace it with the copy, as
    /// on a first send. The bug that it catches: "lost" again at each resend, with no way out (the validator's F1).
    @Test func aResendThatAHubWithWorkRefusesOffersToReplaceIt() async throws {
        let holds = Data(#"{"error": "This hub already holds a fleet's work. A restore is for a new server."}"#.utf8)
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) {
            try Self.restore([(500, Self.lostOnTheHub), (409, holds)], then: { _, _ in })
        }
        #expect(seen.sends == 2, "\(seen)")
        #expect(seen.phases == ["lost", "holdsWork"], "the hub has no answer for this id: it asks before it replaces")
    }

    /// Send it again pressed twice while its look at the hub waits: one send. The bug that it catches: a copy of up to
    /// 2 GiB that goes up twice, because the look came before the phase that counts as busy (the reader's round 7).
    @Test func twoPressesOfSendItAgainWhileItLooksSendOnce() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) {
            try Self.restore([(500, Self.lostOnTheHub), (507, Self.noRoom), (507, Self.noRoom)],
                             then: { hub, _ in hub.slowState(1) }, presses: 2)
        }
        #expect(seen.sends == 2, "one first send and one resend: \(seen)")
    }

    /// Replace it with the copy, after a resend with replace that a changed copy made a reused command (409
    /// `command_reused`, the generation unmoved): a new id, so the hub takes it as a new command. The bug that it
    /// catches: the same id again, and the same 409 at each press (the reader's round 7).
    @Test func replaceFromHoldsWorkIsANewCommandEachTime() async throws {
        let reused = Data(#"{"code": "command_reused", "error": "This request id was used for another command."}"#.utf8)
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) {
            try Self.restore([(500, Self.lostOnTheHub), (409, reused), (507, Self.noRoom)], replace: true,
                             then: { _, _ in }, third: true)
        }
        #expect(seen.phases == ["lost", "holdsWork", "chosen"], "\(seen)")
        #expect(seen.ids.count == 3 && seen.ids[0] == seen.ids[1] && seen.ids[2] != seen.ids[0], "\(seen.ids)")
    }

    /// A resend's 409 whose read of the hub fails (a hub that just started), while the restore landed: the watch
    /// decides, and it lands. The bug that it catches: no reading taken as "the hub holds work", whose own read then
    /// says "Nothing was written", or whose Replace restores a second time (the validator's G1).
    @Test func aResendWhoseReadFailsAfterItsConflictGoesToTheWatch() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) {
            try Self.restore([(500, Self.lostOnTheHub)], then: { hub, _ in
                hub.give(restore: 409, body: Self.moved, thenState: try Self.reading("restored-\(UUID().uuidString)"),
                         failing: 1)
            })
        }
        #expect(seen.sends == 2, "\(seen)")
        #expect(seen.phases == ["lost", "landed"], "no reading is no \"nothing was written\" and no Replace")
    }

    /// The same with a reading whose generation is empty: the watch decides (here: still lost), never "Nothing was
    /// written" (the validator's G1).
    @Test func aResendWhoseReadHasNoGenerationGoesToTheWatch() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) {
            try Self.restore([(500, Self.lostOnTheHub)], then: { hub, _ in
                hub.give(restore: 409, body: Self.moved, thenState: try Self.reading(""))
            })
        }
        #expect(seen.sends == 2, "\(seen)")
        #expect(seen.phases == ["lost", "lost"], "an empty generation is no other one")
    }

    /// The first hub, a restore sent to it that stays unknown (its answer a 500), and a second hub with another
    /// fleet, ready for the app to move to (`move`). `body` gets the model, the store, the two hubs and `move`.
    @MainActor private static func twoHubs<T>(replace: Bool = false, patience: Double = 0.5, waitForLost: Bool = true,
                                              firstAnswer: (status: Int, body: Data) = (500, lostOnTheHub),
                                              until: RestoreModel.Phase? = nil,
                                              _ body: (RestoreModel, FleetStore, LoopbackHub, LoopbackHub,
                                                       () -> Void) throws -> T) throws -> T {
        let first = try Self.reading("restore-\(UUID().uuidString)")
        let hub = try LoopbackHub(state: first)
        defer { hub.stop() }
        _ = ViewHost.store(try HubState.decode(first))
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        store.state = try HubState.decode(first)
        hub.give(restore: [firstAnswer])
        let model = RestoreModel()
        model.patience = patience
        model.read(Self.fixture)
        Task { await model.send(store: store, replace: replace) }
        let wanted = until ?? (waitForLost ? .lost : .restarting)
        ViewHost.turn(20) { hub.requests.contains { $0.path == "/ui/restore" } && model.phase == wanted }
        let other = try Self.reading("another-fleet-\(UUID().uuidString)")
        let next = try LoopbackHub(state: other)
        defer { next.stop() }
        let move = {
            store.addressText = next.address
            Task { await store.connect() }
            ViewHost.turn(20) { store.state?.db == (try? HubState.decode(other).db) }
        }
        return try body(model, store, hub, next, move)
    }

    private static func posts(_ hub: LoopbackHub) -> [LoopbackHub.Request] {
        hub.requests.filter { $0.method == "POST" && $0.path == "/ui/restore" }
    }

    /// The app moved to another hub while a restore with `replace` stood at "lost". Send it again sends nothing there
    /// and leaves the copy chosen, with a new id and `replace` off; the next press, Restore this copy, is a first send
    /// to that hub with no `replace=yes`. The bugs that it catches: "Your fleet is back" for a hub that never got the
    /// copy (the validator's G3), and `replace=yes` with no question over the fleet of the hub that he reads now (the
    /// reader's R8-1, the validator's G4).
    @Test func aPressAfterTheAppMovedToAnotherHubSendsNothingAndChoosesAgain() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> [String] in
            try Self.twoHubs(replace: true) { model, store, _, next, move in
                next.give(restore: [(507, Self.noRoom)])
                move()
                Task { await model.send(store: store) }                     // Send it again
                ViewHost.turn(10) { model.phase == .chosen }
                let after = "\(model.phase) \(Self.posts(next).count)"
                Task { await model.send(store: store) }                     // Restore this copy
                ViewHost.turn(20) { Self.posts(next).count == 1 && model.phase == .chosen }
                return [after, "\(model.phase) \(Self.posts(next).count)"]
                    + Self.posts(next).map { $0.query.contains("replace=yes") ? "replace=yes" : "no replace" }
            }
        }
        #expect(seen == ["chosen 0", "chosen 1", "no replace"], "\(seen)")
    }

    /// A change of hub while the rows say "lost" leaves the watch of the first hub's send at once, for a chosen copy
    /// with a new id (the store calls hubMoved at each change of hub). The bug that it catches: "Your hub has not come
    /// back" and a Check again that does nothing that he can see (the validator's G5).
    @Test func aChangeOfHubWhileLostChoosesTheCopyAgain() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> [String] in
            try Self.twoHubs { model, store, hub, next, move in
                next.give(restore: [(507, Self.noRoom)])
                move()
                model.hubMoved(store: store)                                // as the store does at the change
                let phase = "\(model.phase)"
                Task { await model.send(store: store) }
                ViewHost.turn(20) { Self.posts(next).count == 1 && model.phase == .chosen }
                return [phase, Self.posts(hub).first?.id == Self.posts(next).first?.id ? "same id" : "new id"]
            }
        }
        #expect(seen == ["chosen", "new id"], "\(seen)")
    }

    /// A change of hub while the watch still looks (its patience not yet spent): the watch ends, for a chosen copy.
    /// The bug that it catches: "Your hub is restarting" for ever with no button, and a Cancel that the running model
    /// refuses (the reader's R8-2).
    @Test func aChangeOfHubDuringTheWatchEndsIt() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> String in
            try Self.twoHubs(patience: 60, waitForLost: false) { model, _, _, _, move in
                move()
                ViewHost.turn(10) { model.phase != .restarting }
                return "\(model.phase)"
            }
        }
        #expect(seen == "chosen", "the watch of the first hub's send ended")
    }

    private static let holdsWork =
        Data(#"{"error": "This hub already holds a fleet's work. A restore is for a new server."}"#.utf8)

    /// A first send's 409 shows the first hub's work (.holdsWork); the app moves to another hub; Replace it with the
    /// copy sends nothing there, and the next press, Restore this copy, has no `replace=yes`. The bug that it catches:
    /// a replace of the second hub's fleet after a question that showed the first one's (the reader's R9-1).
    @Test func replaceAfterAChangeOfHubFromHoldsWorkSendsNoReplace() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> [String] in
            try Self.twoHubs(firstAnswer: (409, Self.holdsWork), until: .holdsWork) { model, store, _, next, move in
                next.give(restore: [(507, Self.noRoom)])
                move()
                Task { await model.send(store: store, replace: true) }      // Replace it with the copy
                ViewHost.turn(10) { model.phase == .chosen }
                let after = "\(model.phase) \(Self.posts(next).count) \(model.failure ?? "no words")"
                Task { await model.send(store: store) }                     // Restore this copy
                ViewHost.turn(20) { Self.posts(next).count == 1 && model.phase == .chosen }
                return [after] + Self.posts(next).map {
                    $0.query.contains("replace=yes") ? "replace=yes" : "no replace"
                }
            }
        }
        #expect(seen == ["chosen 0 no words", "no replace"], "\(seen)")
    }

    /// Replace it with the copy refused before any write (a 507) leaves the copy chosen: the next press there, Restore
    /// this copy, is a new command with no `replace=yes`. Then the app moves to another hub: a press sends nothing
    /// there and takes the first hub's words away, and the next one has no `replace=yes`. The bugs that it catches: a
    /// silent `replace=yes` at either hub, days after his answer (the validator's list on R12-2, the reader's R9-1).
    @Test func restoreAfterARefusedReplaceSendsNoReplace() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> [String] in
            try Self.twoHubs(replace: true, firstAnswer: (507, Self.noRoom), until: .chosen) {
                model, store, hub, next, move in
                hub.give(restore: [(507, Self.noRoom)])
                Task { await model.send(store: store) }                     // Restore this copy
                ViewHost.turn(20) { Self.posts(hub).count == 2 && model.phase == .chosen }
                let same = Self.posts(hub).map { $0.query.contains("replace=yes") ? "replace=yes" : "no replace" }
                    + [Set(Self.posts(hub).map(\.id)).count == 2 ? "new id" : "same id"]
                next.give(restore: [(507, Self.noRoom)])
                move()
                Task { await model.send(store: store) }                     // Restore this copy
                ViewHost.turn(10) { model.phase == .chosen && model.failure == nil }    // the press ran
                let after = "\(model.phase) \(Self.posts(next).count) \(model.failure ?? "no words")"
                Task { await model.send(store: store) }                     // and again
                ViewHost.turn(20) { Self.posts(next).count == 1 && model.phase == .chosen }
                return same + [after] + Self.posts(next).map {
                    $0.query.contains("replace=yes") ? "replace=yes" : "no replace"
                }
            }
        }
        #expect(seen == ["replace=yes", "no replace", "new id", "chosen 0 no words", "no replace"],     // N5
                "\(seen)")
    }

    /// The store tells the model of a change of hub (hubMoved) while the watch of the first hub's send
    /// still runs; then a send to the second hub starts its own watch, and the first hub's generation moves. The first
    /// watch writes nothing more, so the second keeps its phase. The bug that it catches: the old watch that goes on
    /// reading the first hub and writes "Your fleet is back" over the new send, and clears its flag (the reader's
    /// R9-2).
    @Test func theWatchOfTheFirstHubWritesNothingAfterTheRowsLeftIt() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> String in
            try Self.twoHubs(patience: 60, waitForLost: false) { model, store, hub, next, move in
                next.give(restore: [(500, Self.lostOnTheHub)])
                move()
                model.hubMoved(store: store)                                // as the store does
                Task { await model.send(store: store) }                     // a send to the second hub
                ViewHost.turn(10) { Self.posts(next).count == 1 && model.phase == .restarting }
                hub.give(try Self.reading("restored-\(UUID().uuidString)"))  // the first hub's generation moves
                ViewHost.turn(6)                                            // past two looks of a stale watch
                return "\(model.phase)"
            }
        }
        #expect(seen == "restarting", "the second hub's watch keeps its phase")
    }

    /// A resend's 409 shows the first hub's work (.holdsWork: the hub has no answer for that id); the app moves to
    /// another hub; Replace it with the copy sends nothing there. The bug that it catches: the new id and `replace` of
    /// that press, made before the check of the hub, reaching the second hub (the validator's list).
    @Test func replaceFromAResendsHoldsWorkAfterAChangeOfHubSendsNothing() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> String in
            try Self.twoHubs { model, store, hub, next, move in
                hub.give(restore: [(409, Self.holdsWork)])
                Task { await model.send(store: store) }                     // Send it again
                ViewHost.turn(20) { model.phase == .holdsWork }
                move()
                Task { await model.send(store: store, replace: true) }      // Replace it with the copy
                ViewHost.turn(10) { model.phase == .chosen }
                return "\(model.phase) \(Self.posts(next).count)"
            }
        }
        #expect(seen == "chosen 0", "\(seen)")
    }

    /// A first send to the first hub is still on its way when the app moves to another hub (the store runs hubMoved).
    /// The send writes nothing more: no question about the first hub's work stands over the second hub, so no Replace
    /// can follow it; and the upload is cancelled, so the first hub gets no whole body to stage (it answers no one).
    /// The bugs that it catches: a send that checks the hub only before its waits (the validator's list), and an upload
    /// that goes on to the first hub (the validator's N6).
    @Test func aSendOnItsWayWhenTheHubChangesWritesNothingAfterIt() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> String in
            let first = try Self.reading("restore-\(UUID().uuidString)")
            let hub = try LoopbackHub(state: first)
            defer { hub.stop() }
            _ = ViewHost.store(try HubState.decode(first))
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            let store = FleetStore()
            store.state = try HubState.decode(first)
            hub.give(restore: [(409, Self.holdsWork)])
            hub.holdRestores()
            let model = RestoreModel()
            model.read(Self.fixture)
            Task { await model.send(store: store) }
            ViewHost.turn(10) { Self.posts(hub).count == 1 }                // on its way: the first hub waits
            let other = try Self.reading("another-fleet-\(UUID().uuidString)")
            let next = try LoopbackHub(state: other)
            defer { next.stop() }
            store.addressText = next.address
            Task { await store.connect() }
            ViewHost.turn(10) { store.state?.db == (try? HubState.decode(other).db) }
            model.hubMoved(store: store)                                    // as the store does
            ViewHost.turn(10) { hub.restoresCut == 1 }
            return "\(model.phase) \(hub.restoresCut)"
        }
        #expect(seen == "chosen 1", "no question about the first hub's work, and its upload cancelled: \(seen)")
    }

    /// A send with `replace` whose generation moved meanwhile (`.staleGeneration`): the copy stays chosen with a new
    /// id and `replace` off, so Restore this copy again asks about the new generation's work and never sends this
    /// send's `replace=yes` with it. The bug that it catches: a replace that nobody asked for over the fleet of the
    /// generation that came (the reader's round 10).
    @Test func aStaleGenerationTurnsReplaceOff() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 60) { () -> [String] in
            let first = try Self.reading("restore-\(UUID().uuidString)")
            let hub = try LoopbackHub(state: first)
            defer { hub.stop() }
            _ = ViewHost.store(try HubState.decode(first))
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            let store = FleetStore()
            store.state = try HubState.decode(first)
            let moved = try Self.reading("moved-\(UUID().uuidString)")
            hub.give(restore: 409, body: Self.moved, thenState: moved)
            hub.give(restore: [(507, Self.noRoom)])
            let model = RestoreModel()
            model.read(Self.fixture)
            Task { await model.send(store: store, replace: true) }          // Replace it with the copy
            ViewHost.turn(20) { Self.posts(hub).count == 1 && model.phase == .chosen
                && store.state?.db == (try? HubState.decode(moved).db) }
            Task { await model.send(store: store) }                         // Restore this copy again
            ViewHost.turn(20) { Self.posts(hub).count == 2 && model.phase == .chosen }
            return Self.posts(hub).map {
                ($0.query.contains("replace=yes") ? "replace=yes" : "no replace") + " " + $0.id
            }
        }
        #expect(seen.count == 2 && seen[0].hasPrefix("replace=yes") && seen[1].hasPrefix("no replace"), "\(seen)")
        #expect(seen.count == 2 && seen[0].split(separator: " ").last != seen[1].split(separator: " ").last,
                "a new command")
    }

    /// **The way back lives in the store, not in a page** (the validator's P1, 22 November 2026): the Settings shell
    /// builds its pages again at each change of tab and of hub, and the page's own model was then built new and idle,
    /// while the old one ran on unseen with its upload and its watch. Rendered here with the shell (the app's window,
    /// Settings › Backup): a restore to the first hub is on its way, he opens System status and comes back, and the
    /// rows still say that it is sent; then the app moves to another hub, and the rows show the copy chosen again and
    /// the first hub sees its upload end. The bugs that it catches: a restore that a change of tab hides while it
    /// goes on, so that he sends the same copy again with a new id; and an upload that no change of hub stops.
    @Test func aRestoreOutlivesAChangeOfTabAndEndsAtAChangeOfHub() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 90) { () -> [String] in
            try Self.shell([(409, Self.holdsWork)]) { at in
                at.hub.holdRestores()                                       // on its way until the app ends it
                at.send()                                                   // Restore this copy
                ViewHost.turn(10) { Self.posts(at.hub).count == 1 }
                at.open(.status)                                            // System status, and back
                at.open(.backup)
                let sending = try at.shows("Sending the copy to your hub")
                let held = AppAutoUpdate.busy(store: at.store, setup: false)
                at.move()
                let chosen = try at.shows("Restore this copy")
                ViewHost.turn(10) { at.hub.restoresCut == 1 }
                return ["sending after the tab: \(sending)", "the app's own restart waits: \(held)",
                        "chosen after the hub: \(chosen)", "\(at.model.phase)", "upload cut: \(at.hub.restoresCut)",
                        "and then: \(AppAutoUpdate.busy(store: at.store, setup: false))"]
            }
        }
        #expect(seen == ["sending after the tab: true", "the app's own restart waits: true",
                         "chosen after the hub: true", "chosen", "upload cut: 1", "and then: false"], "\(seen)")
    }

    /// The app's window on Settings › Backup, with its shell, the fixture copy chosen in the store's own model, the hub
    /// that the store reads, and another one, with another fleet.
    @MainActor private struct Shell {
        let store: FleetStore, window: NSWindow, hub: LoopbackHub, next: LoopbackHub
        let nextDatabase: String
        var model: RestoreModel { store.restore }

        func send(replace: Bool? = nil) {
            Task { [store] in await store.restore.send(store: store, replace: replace) }
        }
        /// He opens a section of Settings; the page of the one before goes.
        func open(_ section: SettingsTab) {
            store.destination = .settings(section)
            ViewHost.turn(1)
        }
        func shows(_ words: String, seconds: Double = 10) throws -> Bool {
            try ViewHost.middle(of: words, in: window, seconds: seconds) != nil
        }
        /// The hub's generation is `database`, and the store reads it. `last`: the hub answers no later read
        /// (`LoopbackHub.give(last:)`).
        func read(_ database: String, last: Bool = false) throws {
            let reading = try RestoreRefusalTests.reading(database)
            if last { hub.give(last: reading) } else { hub.give(reading) }
            let before = hub.requests.filter { $0.path == "/ui/state" }.count
            Task { [store] in await store.refresh() }
            ViewHost.turn(10) {
                store.state?.db == database
                    && (last || (hub.requests.filter { $0.path == "/ui/state" }.count > before && !store.refreshing))
            }
        }
        /// The app connects to the other hub.
        func move() {
            store.addressText = next.address
            Task { [store] in await store.connect() }
            ViewHost.turn(20) { store.state?.db == nextDatabase }
        }
    }

    /// `body` gets that window; the hub's restores get `answers`, in order.
    @MainActor private static func shell<T>(_ answers: [(status: Int, body: Data)],
                                            _ body: (Shell) throws -> T) throws -> T {
        let first = try Self.reading("restore-\(UUID().uuidString)")
        let hub = try LoopbackHub(state: first)
        defer { hub.stop() }
        let nextDatabase = "another-fleet-\(UUID().uuidString)"
        let next = try LoopbackHub(state: try Self.reading(nextDatabase))
        defer { next.stop() }
        _ = ViewHost.store(try HubState.decode(first))
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.state?.db == (try? HubState.decode(first).db) }
        hub.give(restore: answers)
        store.destination = .settings(.backup)
        let window = ViewHost.window(store)
        defer { ViewHost.close(window) }
        store.restore.read(Self.fixture)
        return try body(Shell(store: store, window: window, hub: hub, next: next, nextDatabase: nextDatabase))
    }

    enum Standing: CaseIterable { case staged, left, resent }

    /// **A send whose outcome is unknown lands by itself when the store reads the generation that moved** (the app
    /// reader's R12-2 and the validator's list, 23 November 2026), in each state: its copy waits on a hub that does not
    /// restart itself, and he restarted that hub as the rows say; he left that wait for the chosen copy; its resend is
    /// on its way, which then ends and writes nothing more. The same generation, none, or another hub's is no landing.
    /// The bugs that it catches: "The copy is waiting on your hub" for as long as the app runs, after the hub took it,
    /// and "Your hub is restarting" over the landing, from the resend that the landing cut.
    @Test(arguments: Standing.allCases) func anUnknownOutcomeLandsWhenTheStoreReadsIt(_ standing: Standing) async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 90) { () -> [String] in
            try Self.shell(standing == .resent ? [(500, Self.lostOnTheHub), (409, Self.holdsWork)]
                           : [(200, Self.took(restarting: false))]) { at in
                at.model.patience = 0.5
                at.send()
                ViewHost.turn(20) { at.model.phase == (standing == .resent ? .lost : .staged) }
                if standing == .left {
                    at.open(.status)
                    ViewHost.turn(10) { at.model.phase == .chosen }
                } else if standing == .resent {
                    at.hub.holdRestores()
                    at.send()                                               // Send it again
                    ViewHost.turn(20) { Self.posts(at.hub).count == 2 }
                }
                let stood = "\(at.model.phase)"
                try at.read(at.store.state?.db ?? "")
                at.model.hubRead("", at: at.store.hub)
                at.model.hubRead(at.nextDatabase, at: try HubClient.address(at.next.address))
                let same = "\(at.model.phase)"
                // The hub took the records, and the read that the store makes of them is the last one that it
                // answers: a look of a send that still writes after the landing waits there, in "Your hub is
                // restarting", whatever the order of the threads (the reader's round 14).
                try at.read("landed-\(UUID().uuidString)", last: true)
                ViewHost.turn(10) { at.hub.restoresCut == (standing == .resent ? 1 : 0) }
                ViewHost.turn(1)
                at.open(.backup)
                let back = try at.shows("Your fleet is back")
                return [stood, same, "back: \(back)", "\(at.model.phase)", "cut: \(at.hub.restoresCut)"]
            }
        }
        let stood = [Standing.staged: "staged", .left: "chosen", .resent: "sending"][standing] ?? ""
        #expect(seen == [stood, stood, "back: true", "landed", "cut: \(standing == .resent ? 1 : 0)"], "\(seen)")
    }

    /// **A wait that stands with no Cancel gives a way out when he leaves the page** (R12-2): .lost (its first send's
    /// answer a 500) and .staged stay while the page shows them; after he left, the rows show the copy chosen, with the
    /// words of .staged beside it. Restore this copy is then a send of unknown outcome, whose refusal is no "nothing
    /// written". After .lost it has a new id and no `replace=yes`; after .staged it is the same command, which the hub
    /// answers with its first answer. The hub stays too: after a change of hub, a press there is a first send. The bugs
    /// that it catches: a wait with no way out, its words that go before he read them, `replace=yes` days after his
    /// answer to a hub that never had the copy, and the question of .holdsWork for a copy that the hub has staged, whose
    /// Keep this fleet keeps nothing (the validator's N12).
    @Test(arguments: [false, true]) func leavingThePageGivesAWayOutOfAWaitThatStands(staged: Bool) async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 120) { () -> [String] in
            let answers = staged ? [(200, Self.took(restarting: false)), (200, Self.took(restarting: false))]
                : [(500, Self.lostOnTheHub), (507, Self.noRoom)]
            return try Self.shell(answers) { at in
                let wait: RestoreModel.Phase = staged ? .staged : .lost
                at.model.patience = 0.5
                at.send(replace: true)
                ViewHost.turn(20) { at.model.phase == wait }
                let words = try at.shows(staged ? "The copy is waiting on your hub" : "Your hub has not come back")
                ViewHost.turn(1)
                var seen = ["\(words) \(at.model.phase)"]
                at.open(.status)
                ViewHost.turn(10) { at.model.phase == .chosen }
                at.open(.backup)
                let button = try at.shows("Restore this copy"), said = try at.shows("does not restart itself", seconds: 2)
                seen.append("\(button) \(at.model.phase), the words of .staged: \(said)")
                at.send()                                                   // Restore this copy
                ViewHost.turn(20) { Self.posts(at.hub).count == 2 && at.model.phase == wait }
                seen.append("\(at.model.phase)")
                seen += Self.posts(at.hub).map { $0.query.contains("replace=yes") ? "replace=yes" : "no replace" }
                seen.append("ids: \(Set(Self.posts(at.hub).map(\.id)).count)")
                at.open(.status)                                            // he leaves it again, for another hub
                ViewHost.turn(10) { at.model.phase == .chosen }
                at.next.give(restore: [(507, Self.noRoom)])
                at.move()
                at.send()
                ViewHost.turn(20) { Self.posts(at.next).count == 1 && at.model.phase == .chosen }
                return seen + Self.posts(at.next).map { $0.query.contains("replace=yes") ? "replace=yes" : "no replace" }
            }
        }
        #expect(seen == (staged ? ["true staged", "true chosen, the words of .staged: true", "staged", "replace=yes",
                                   "replace=yes", "ids: 1"]
                         : ["true lost", "true chosen, the words of .staged: false", "lost", "replace=yes", "no replace",
                            "ids: 2"]) + ["no replace"], "\(seen)")
    }

    /// **The question of .holdsWork ends when the generation that it was about moves** (the validator's list on R12-2,
    /// 23 November 2026), because Replace names the generation that the store reads now. After a first send, the copy
    /// is chosen again and the next press is a new command with no `replace=yes`, to the new generation; after a resend
    /// of a send whose outcome is unknown, it is that send's landing. The bugs that it catches: a Replace that goes over
    /// a fleet that the question did not show, days later, and a landing that he is asked to replace.
    @Test(arguments: [false, true]) func theQuestionEndsWhenTheGenerationMoves(resent: Bool) async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 90) { () -> [String] in
            let answers = (resent ? [(500, Self.lostOnTheHub)] : []) + [(409, Self.holdsWork), (507, Self.noRoom)]
            return try Self.shell(answers) { at in
                at.model.patience = 0.5
                at.send()
                if resent {
                    ViewHost.turn(20) { at.model.phase == .lost }
                    at.send()                                               // Send it again
                }
                ViewHost.turn(20) { at.model.phase == .holdsWork }
                try at.read(at.store.state?.db ?? "")                       // the same generation: the question stands
                let asked = "\(at.model.phase)"
                let moved = "moved-\(UUID().uuidString)"
                try at.read(moved)
                let after = "\(at.model.phase)"
                guard !resent else { return [asked, after] }
                at.send()                                                   // Restore this copy
                ViewHost.turn(20) { Self.posts(at.hub).count == 2 && at.model.phase == .chosen }
                let posts = Self.posts(at.hub)
                return [asked, after, posts.last?.query.contains("replace=yes") == true ? "replace=yes" : "no replace",
                        posts.last?.query.contains("db=\(moved)") == true ? "the new one" : "another generation",
                        "ids: \(Set(posts.map(\.id)).count)"]
            }
        }
        #expect(seen == (resent ? ["holdsWork", "landed"]
                         : ["holdsWork", "chosen", "no replace", "the new one", "ids: 2"]), "\(seen)")
    }

    /// **A landing goes with its hub** (the app reader's R12-1, 23 November 2026): "Your fleet is back", its receipt and
    /// its reconnect steps are the first hub's, so after a connect to another hub, made while Backup is not on the
    /// screen, and after Start again, the model is at rest, and Backup offers Restore copy. Before the landing, the watch
    /// goes on over a change of tab. The bug that it catches: the first fleet's id, records and reconnect steps on the
    /// page of the second one.
    @Test(arguments: [false, true]) func aLandingGoesWithItsHub(startAgain: Bool) async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 90) { () -> [String] in
            try Self.shell([(200, Self.took(restarting: true))]) { at in
                at.send()
                ViewHost.turn(20) { at.model.phase == .restarting }
                at.open(.status)                                            // the watch goes on over a change of tab
                at.open(.backup)
                let waits = "\(at.model.phase), held: \(AppAutoUpdate.busy(store: at.store, setup: false))"
                try at.read("landed-\(UUID().uuidString)")
                ViewHost.turn(20) { at.model.phase == .landed }
                let back = "\(try at.shows("Your fleet is back"))"
                if startAgain {
                    ViewHost.close(at.window)                               // no first run opens its own searches here
                    at.store.forgetFleet(at.store.hub, hubServerDeleted: false)
                } else {
                    at.open(.status)
                    at.move()
                }
                let rest = "\(at.model.phase) \(at.model.copy == nil) \(at.model.receipt == nil)"
                guard !startAgain else { return [waits, back, rest] }
                at.open(.backup)
                let start = try at.shows("Put a copy back"), still = try at.shows("Your fleet is back", seconds: 1)
                return [waits, back, rest, "\(start) \(still)"]
            }
        }
        #expect(seen == ["restarting, held: true", "true", "idle true true"] + (startAgain ? [] : ["true false"]),
                "\(seen)")
    }
}
