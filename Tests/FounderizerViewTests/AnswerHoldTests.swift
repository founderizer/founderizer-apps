import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **His answer waits 5 seconds on its card, with Undo, and Pause stands on the card while its task works** (the
/// owner's "Yes, 5 seconds (Recommended)" and "Both (Recommended)", 21 November 2026; `AnswerHolds`). The tests read
/// what the app sends to a stand-in hub (`LoopbackHub`): the app writes only after a hub's answer.
@Suite(.serialized, .timeLimit(.minutes(2))) struct AnswerHoldTests {
    private static let now = Int(Date().timeIntervalSince1970)

    /// A reading with the manager and DevOps, these requests and tasks, and the features of marks and task controls.
    private static func reading(needs: [[String: Any]], tasks: [[String: Any]] = [], holds: [[String: Any]] = [])
        throws -> Data {
        let agents: [[String: Any]] = [
            ["name": "manager", "role": "manager", "title": "Fleet Manager", "runtime": "claude", "can": [], "placed": true],
            ["name": "devops", "role": "worker", "title": "DevOps", "runtime": "claude", "can": [], "placed": true]]
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "undo-\(UUID().uuidString)", "time": now, "agents": agents, "tasks": tasks,
            "holds": holds, "outcomes": [], "notes": [], "needs": needs, "permissions": [], "messages": [], "reports": [],
            "ui_features": [AnsweredMark.feature, "task_controls"]] as [String: Any])
    }

    private static func need(_ id: Int, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "title": "Choose the day of the move", "why": "", "todo": "", "raised": now - 300, "by": "manager",
         "answered": NSNull()].merging(extra) { _, new in new }
    }

    /// A store of the app that reads `hub`, after the hub's first answer: it can write.
    @MainActor private static func store(on hub: LoopbackHub, _ state: Data) throws -> FleetStore {
        _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.canWrite }
        return store
    }

    struct Waits: Sendable {
        let heldAtPress: Bool
        let sentBeforeUndo: Bool
        let openAgain: Bool
        let waited: Double?
        let choice: Bool
    }

    /// In a chat: a press of an option folds the card with Undo, and nothing reaches the hub; Undo opens the card with
    /// its options; a press that is not taken back reaches the hub once the wait is over, never before.
    @Test func anAnswerWaitsAndUndoOpensTheCardAgain() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Waits in
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(51, ["options": ["Friday", "Monday"]])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let posts = { hub.requests.filter { $0.method == "POST" && $0.path == "/ui/needs/51" } }
            guard let monday = try ViewHost.middle(of: "Monday", in: window) else {
                throw ViewHost.Missing(description: "the card's option Monday is not drawn")
            }
            ViewHost.atOnce(ViewHost.click(monday, in: window))
            let held = holds.held[51] != nil
            guard let undo = try ViewHost.middle(of: String(l10n: "Undo"), in: window) else {
                throw ViewHost.Missing(description: "the folded card has no Undo")
            }
            ViewHost.atOnce(ViewHost.click(undo, in: window))
            let sentBeforeUndo = !posts().isEmpty
            ViewHost.turn(5) { holds.held[51] == nil }
            let friday = try ViewHost.middle(of: "Friday", in: window, seconds: 5)
            let open = holds.held[51] == nil && friday != nil
            // a press that he does not take back
            holds.wait = .milliseconds(800)
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            guard let again = try ViewHost.middle(of: "Monday", in: window) else {
                throw ViewHost.Missing(description: "the card did not open again with Monday")
            }
            let pressed = Date()
            ViewHost.atOnce(ViewHost.click(again, in: window))
            ViewHost.turn(15) { !posts().isEmpty }
            let post = posts().first
            return Waits(heldAtPress: held, sentBeforeUndo: sentBeforeUndo, openAgain: open,
                         waited: post.map { $0.at.timeIntervalSince(pressed) },
                         choice: post?.body.contains(#""choice":1"#) == true)
        }
        #expect(seen.heldAtPress && !seen.sentBeforeUndo, "the press waits, and nothing reaches the hub")
        #expect(seen.openAgain, "Undo opens the card with its options")
        #expect((seen.waited ?? 0) >= 0.8, "the answer reaches the hub only once the wait is over")
        #expect(seen.choice, "and it is the option that he pressed")
        #expect(screen.stayedHis)
    }

    /// On Needs you: his key 2 and Return answer the request at hand, which stays at hand with Undo while his answer
    /// waits (his "Yes, Undo there too"); Undo brings its options back.
    @Test func onNeedsYouTheAnsweredRequestStaysWithUndo() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (held: Bool, open: Bool) in
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(55, ["options": ["Friday", "Monday"]])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            store.destination = .needs
            store.selectedNeed = 55
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard try ViewHost.middle(of: "Monday", in: window) != nil else {
                throw ViewHost.Missing(description: "the step's option Monday is not drawn")
            }
            ViewHost.atOnce(ViewHost.keys("2\r", in: window))
            ViewHost.turn(5) { holds.held[55] != nil }
            // past the moment in which an answer settles at hand (under a second): the held one is still there
            ViewHost.turn(2)
            guard let undo = try ViewHost.middle(of: String(l10n: "Undo"), in: window, seconds: 3) else {
                throw ViewHost.Missing(description: "the answered request has no Undo on Needs you")
            }
            let held = holds.held[55] != nil
            ViewHost.atOnce(ViewHost.click(undo, in: window))
            ViewHost.turn(5) { holds.held[55] == nil }
            let friday = try ViewHost.middle(of: "Friday", in: window, seconds: 5)
            return (held, holds.held[55] == nil && friday != nil && store.selectedNeed == 55)
        }
        #expect(seen.held, "the key's answer waits, at hand with Undo")
        #expect(seen.open, "Undo brings the request back at hand with its options")
        #expect(screen.stayedHis)
    }

    /// **A held answer whose wait ends while the hub cannot take it waits, and goes once it can** (review): another
    /// request on its way blocks the store at the end of the wait; the ticked options went nowhere then.
    @Test func ticksWhoseWaitEndsWhileTheStoreIsBusyGoOnceItCanWrite() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (blocked: Bool, held: Bool, before: Bool, after: Bool) in
            let task: [String: Any] = ["id": 41, "title": "Reopen the two stuck app nodes", "details": "",
                                       "done_when": "Checked", "needs": "none", "goal": "", "owner": "devops",
                                       "requester": "manager", "state": "working", "created": Self.now - 2000,
                                       "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0,
                                       "started": Self.now - 1900, "last_activity": Self.now - 30]
            let reading = try Self.reading(needs: [Self.need(56, ["options": ["Dark", "Orange", "Blue"], "multi": true])],
                                           tasks: [task])
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, reading)
            store.destination = .needs
            store.selectedNeed = 56
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard try ViewHost.middle(of: "Orange", in: window) != nil else {
                throw ViewHost.Missing(description: "the step's options are not drawn")
            }
            // keys 1 and 3 tick two options, and Return sends them, while the store can write: they wait
            holds.wait = .seconds(3)
            let keys: [(String, UInt16)] = [("1", 18), ("3", 20), ("\r", 36)]
            ViewHost.atOnce(keys.flatMap { character, code in
                [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: code)
                }
            })
            ViewHost.turn(5) { holds.held[56] != nil }
            let held = holds.held[56]?.shown.choices == [0, 2]
            // before their wait ends another request blocks the store: the hub refuses it, and it waits for his Discard
            Task { _ = await store.command(.control(task: 41, action: .pause)) }
            ViewHost.turn(10) { store.pending?.refusal != nil }
            let blocked = !store.canWrite
            ViewHost.turn(10) { holds.held[56] == nil }        // the wait ended
            ViewHost.turn(1)
            let posts = { hub.requests.filter { $0.method == "POST" && $0.path == "/ui/needs/56" } }
            let before = !posts().isEmpty
            // he discards the refused request, and the hub answers again: the ticked options go
            store.discardRefused()
            Task { await store.refresh() }
            ViewHost.turn(10) { !posts().isEmpty }
            return (blocked, held, before, posts().first?.body.contains(#""choices":[0,2]"#) == true)
        }
        #expect(seen.held, "keys 1, 3 and Return hold the two ticked options")
        #expect(seen.blocked, "another request blocked the store before their wait ended")
        #expect(!seen.before, "nothing went while the store could not write")
        #expect(seen.after, "the ticked options went once it could")
        #expect(screen.stayedHis)
    }

    /// His words go into the box, Return holds them, and Undo puts them back in the box, with nothing sent.
    @Test func undoPutsHisWordsBackInTheBox() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (box: String, sent: Bool) in
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(52)]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let field = try ViewHost.middle(of: String(l10n: "Your answer"), in: window) else {
                throw ViewHost.Missing(description: "the card's box is not drawn")
            }
            ViewHost.atOnce(ViewHost.click(field, in: window))
            ViewHost.turn(1) { ViewHost.fieldWords(in: window) != nil }
            ViewHost.atOnce(ViewHost.keys("hello\r", in: window))
            ViewHost.turn(5) { holds.held[52] != nil }
            guard let undo = try ViewHost.middle(of: String(l10n: "Undo"), in: window) else {
                throw ViewHost.Missing(description: "the folded card has no Undo")
            }
            ViewHost.atOnce(ViewHost.click(undo, in: window))
            // the card opens (its own replies stand again, which only the open card has), with his words in its box
            let shows = try ViewHost.middle(of: String(l10n: "Tell me more"), in: window, seconds: 5) != nil
            let need = try #require(store.state?.needs.first)
            return (shows ? store.answerText(for: need) : "", hub.requests.contains { $0.method == "POST" })
        }
        #expect(seen.box == "hello", "the card opens with his words in its box")
        #expect(!seen.sent, "nothing reached the hub")
        #expect(screen.stayedHis)
    }

    struct Reply: Sendable {
        var boxWhileHeld: String?, boxAfterUndo: String?, boxAfterSend: String?
        var sentBeforeUndo = true, sentDone = false
    }

    /// **A reply that he presses never stands in his box** (the owner's report of 22 November 2026: he pressed Done,
    /// and "Done" stood in his Your answer box). Done waits with Undo as an option's press does; his own unsent words
    /// stay in the box through the wait, through Undo and after the reply went, and the reply reaches the hub as his
    /// answer.
    @Test func aReplyHePressesNeverStandsInHisBox() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Reply in
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(53)]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let posts = { hub.requests.filter { $0.method == "POST" && $0.path == "/ui/needs/53" } }
            store.answers["53"] = "half a thought"
            var seen = Reply()
            guard let done = try ViewHost.middle(of: String(l10n: "Done"), in: window) else {
                throw ViewHost.Missing(description: "the card's reply Done is not drawn")
            }
            ViewHost.atOnce(ViewHost.click(done, in: window))
            ViewHost.turn(5) { holds.held[53] != nil }
            seen.boxWhileHeld = store.answers["53"]
            guard let undo = try ViewHost.middle(of: String(l10n: "Undo"), in: window) else {
                throw ViewHost.Missing(description: "the folded card has no Undo")
            }
            ViewHost.atOnce(ViewHost.click(undo, in: window))
            seen.sentBeforeUndo = !posts().isEmpty
            ViewHost.turn(5) { holds.held[53] == nil }
            seen.boxAfterUndo = store.answers["53"]
            // a press that he does not take back
            holds.wait = .milliseconds(300)
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            guard let again = try ViewHost.middle(of: String(l10n: "Done"), in: window) else {
                throw ViewHost.Missing(description: "the card did not open again with Done")
            }
            ViewHost.atOnce(ViewHost.click(again, in: window))
            // the store has ended its send (the stand-in hub refuses it): what it does to his box is done
            ViewHost.turn(15) { !posts().isEmpty && !store.sending }
            seen.sentDone = posts().first?.body.contains(#""answer":"Done""#) == true
            seen.boxAfterSend = store.answers["53"]
            return seen
        }
        #expect(seen.boxWhileHeld == "half a thought", "his box keeps his words while Done waits")
        #expect(!seen.sentBeforeUndo && seen.boxAfterUndo == "half a thought",
                "Undo sends nothing and leaves his words")
        #expect(seen.sentDone, "Done reaches the hub as his answer")
        #expect(seen.boxAfterSend == "half a thought", "his box keeps his words after Done went")
        #expect(screen.stayedHis)
    }

    /// **The take-over card's ✓ Done leaves his words in the request's box** (the same fault as the card's own Done,
    /// the owner's report of 22 November 2026): it wrote "Done" into his box and sent it from there, and his unsent
    /// words were gone. It goes as its own words now, and reaches the hub as his answer.
    @Test func aTakeOversDoneLeavesHisWordsInTheBox() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 60) { () -> (box: String?, sent: Bool) in
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(54)]))
            defer { hub.stop() }
            // no window here, whose end removes it (`ViewHost.close`): the refused Done in the outbox, which the next
            // test's store would read as its own unsent request, and write nothing
            defer { try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer")) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            ViewHost.turn(10) { store.openNeeds.contains { $0.id == 54 } }
            store.answers["54"] = "half a thought"
            Task { _ = await store.answerTakeOver(54) {} }
            let posts = { hub.requests.filter { $0.method == "POST" && $0.path == "/ui/needs/54" } }
            // the store has ended its send (the stand-in hub refuses it)
            ViewHost.turn(15) { !posts().isEmpty && !store.sending }
            return (store.answers["54"], posts().first?.body.contains(#""answer":"Done""#) == true)
        }
        #expect(seen.sent, "Done reaches the hub as his answer")
        #expect(seen.box == "half a thought", "his box keeps his words")
        #expect(screen.stayedHis)
    }

    /// **A reply over a file that waits with no upload still ends its wait** (the readers of 23 November 2026): a file
    /// whose upload a quit cut off comes back "Waiting", with no number and no failure, and nothing sends it up again.
    /// A reply that waited for such a file never went, its card stood on its way with no Undo, and a quit never ended.
    @Test func aReplyOverAWaitingFileEndsItsWait() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 60) { () -> (pressed: Bool, ended: Bool) in
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(55)]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .milliseconds(300)
            defer { holds.wait = .seconds(5) }
            _ = ViewHost.store(try HubState.decode(Self.reading(needs: [])))   // the test's own defaults and folder
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            // a file of the request's box whose upload a quit cut off: no number, no failure
            let waiting = FleetStore.StagedFile(requestID: UUID(), name: "notes.txt", mime: "text/plain", size: 12)
            AppDefaults.store.set(try JSONEncoder().encode([FleetStore.stageKey(need: 55): [waiting]]),
                                  forKey: "stagedFiles")
            let store = FleetStore()
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let done = try ViewHost.middle(of: String(l10n: "Done"), in: window) else {
                throw ViewHost.Missing(description: "the card's reply Done is not drawn")
            }
            ViewHost.atOnce(ViewHost.click(done, in: window))
            let pressed = ViewHost.turn(5) { holds.held[55] != nil }
            // the hold ends, and so does the press that it let go: nothing waits for the file
            return (pressed, ViewHost.turn(10) { !holds.busy })
        }
        #expect(seen.pressed, "Done waits with Undo")
        #expect(seen.ended, "nothing waits for a file that no upload sends")
        #expect(screen.stayedHis)
    }

    /// A quit sends what waits: the app ends once the held answer went, and at once when nothing waits.
    @Test func aQuitSendsTheAnswerThatWaits() async throws {
        @MainActor final class Flags { var went = false, replied = false }
        let (seen, _) = try await ViewHost.onMainLoop { () -> (now: Bool, later: Bool, went: Bool, replied: Bool) in
            let store = ViewHost.store(try ViewHost.reading(needs: [Self.need(53, ["options": ["Friday", "Monday"]])],
                                                            features: []))
            let need = try #require(store.state?.needs.first)
            let holds = AnswerHolds()
            holds.wait = .seconds(60)
            let flags = Flags()
            let now = FleetAppDelegate.ends(after: holds) { flags.replied = true } == .terminateNow
            let shown = PendingRequest(hub: store.hub, database: store.state?.db ?? "", client: store.installation,
                                       needID: 53, choice: 1, text: "Monday")
            holds.hold(need, store: store, shown: shown) { flags.went = true }
            let later = FleetAppDelegate.ends(after: holds) { flags.replied = true } == .terminateLater
            ViewHost.turn(5) { flags.replied }
            return (now, later, flags.went, flags.replied)
        }
        #expect(seen.now, "nothing waits: the app ends at once")
        #expect(seen.later && seen.went && seen.replied, "the held answer goes, and then the app ends")
    }

    struct Pauses: Sendable {
        let whileWorking: [String]
        let sent: Bool
        let whileHeld: [String]
        let whilePaused: [String]
        let opened: Bool
    }

    /// The folded card of an answer whose task works has Pause, which sends the task's pause; once the task is held
    /// it has none, and its orange mark, then the gray mark of his pause, open the task. VoiceOver's actions of the card
    /// are the same presses.
    @Test func pauseStandsOnlyWhileTheTaskWorksAndSendsThePause() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Pauses in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let task: [String: Any] = ["id": 41, "title": "Reopen the two stuck app nodes", "details": "",
                                       "done_when": "Checked", "needs": "none", "goal": "", "owner": "devops",
                                       "requester": "manager", "state": "working", "created": Self.now - 2000,
                                       "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0,
                                       "started": Self.now - 1900, "last_activity": Self.now - 30]
            let answered = Self.need(54, ["options": ["Reopen both", "No"], "answer": "Reopen both", "chosen": 0,
                                          "answered": Self.now - 200, "task": 41])
            let working = try Self.reading(needs: [answered], tasks: [task])
            let hub = try LoopbackHub(state: working)
            defer { hub.stop() }
            let store = try Self.store(on: hub, working)
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let card = "need-folded-54"
            ViewHost.turn(10) { !Self.actions(card, in: window).isEmpty }
            let whileWorking = Self.actions(card, in: window)
            Self.perform("Pause", on: card, in: window)
            ViewHost.turn(10) { hub.requests.contains { $0.path == "/ui/tasks/41/control" } }
            let sent = hub.requests.contains { $0.method == "POST" && $0.path == "/ui/tasks/41/control"
                && $0.body.contains(#""action":"pause""#) }
            // the hub held the task, which waits for his word that it stopped: its row is orange
            let hold: [String: Any] = ["id": 1, "task": 41, "kind": "pause", "state": "not_confirmed", "attempt": 1]
            hub.give(try Self.reading(needs: [answered], tasks: [task], holds: [hold]))
            Task { await store.refresh() }
            ViewHost.turn(10) { store.state?.holds?.isEmpty == false && !Self.actions(card, in: window).contains("Pause") }
            let whileHeld = Self.actions(card, in: window)
            // the helper confirmed his pause (the hub's state "stopped"): the gray pause mark, which opens the task too
            let paused: [String: Any] = ["id": 1, "task": 41, "kind": "pause", "state": "stopped", "attempt": 1]
            hub.give(try Self.reading(needs: [answered], tasks: [task], holds: [paused]))
            Task { await store.refresh() }
            ViewHost.turn(10) { store.state?.holds?.first?.state == "stopped" }
            ViewHost.turn(1)
            let whilePaused = Self.actions(card, in: window)
            Self.perform(String(l10n: "Open the task"), on: card, in: window)
            ViewHost.turn(10) { store.detail?.shown == .task(41) }
            return Pauses(whileWorking: whileWorking, sent: sent, whileHeld: whileHeld, whilePaused: whilePaused,
                          opened: store.detail?.shown == .task(41))
        }
        #expect(seen.whileWorking.contains("Pause") && seen.whileWorking.contains("Open the task"),
                "Pause and the open task on the card of an answer whose task works")
        #expect(seen.sent, "Pause sends the task's pause")
        #expect(!seen.whileHeld.contains("Pause") && seen.whileHeld.contains("Open the task"),
                "no Pause once the task is held, and its orange mark opens the task")
        #expect(!seen.whilePaused.contains("Pause") && seen.whilePaused.contains("Open the task"),
                "his confirmed pause: no Pause, and its gray mark opens the task")
        #expect(seen.opened, "the task opens")
        #expect(screen.stayedHis)
    }

    /// The VoiceOver actions of the element with this identifier in the window, by the accessibility tree: SwiftUI
    /// makes its elements once the app says that an assistive app reads it (`JobCardPressTests`).
    @MainActor private static func customActions(_ identifier: String, in window: NSWindow) -> [NSAccessibilityCustomAction] {
        var queue: [NSObject] = window.contentView.map { [$0] } ?? []
        while !queue.isEmpty {
            let object = queue.removeFirst()
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.perform(NSSelectorFromString("accessibilityIdentifier"))?.takeUnretainedValue() as? String == identifier {
                guard object.responds(to: NSSelectorFromString("accessibilityCustomActions")) else { return [] }
                return object.perform(NSSelectorFromString("accessibilityCustomActions"))?.takeUnretainedValue()
                    as? [NSAccessibilityCustomAction] ?? []
            }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let kids = object.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any] {
                queue += kids.compactMap { $0 as? NSObject }
            }
        }
        return []
    }

    @MainActor private static func actions(_ identifier: String, in window: NSWindow) -> [String] {
        customActions(identifier, in: window).map(\.name)
    }

    @MainActor private static func perform(_ name: String, on identifier: String, in window: NSWindow) {
        guard let action = customActions(identifier, in: window).first(where: { $0.name == name }) else { return }
        if let handler = action.handler { _ = handler() } else if let target = action.target as? NSObject, let selector = action.selector {
            _ = target.perform(selector, with: action)
        }
    }
}
