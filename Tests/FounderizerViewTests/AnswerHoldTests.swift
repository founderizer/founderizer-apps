import AppKit
import FleetCore
import Testing
import Vision
@testable import Founderizer

/// **His answer waits 5 seconds on its card, with Undo, and Pause stands on the card while its task works** (the
/// owner's "Yes, 5 seconds (Recommended)" and "Both (Recommended)", 21 November 2026; `AnswerHolds`). The tests read
/// what the app sends to a stand-in hub (`LoopbackHub`): the app writes only after a hub's answer.
@Suite(.serialized, .timeLimit(.minutes(2))) struct AnswerHoldTests {
    private static let now = Int(Date().timeIntervalSince1970)

    /// A reading with the manager and DevOps (and `team`: more agents by name and role), these requests and tasks,
    /// and the features of marks and task controls.
    private static func reading(needs: [[String: Any]], tasks: [[String: Any]] = [], holds: [[String: Any]] = [],
                                team: [(name: String, title: String)] = []) throws -> Data {
        let agents: [[String: Any]] = [
            ["name": "manager", "role": "manager", "title": "Fleet Manager", "runtime": "claude", "can": [], "placed": true],
            ["name": "devops", "role": "worker", "title": "DevOps", "runtime": "claude", "can": [], "placed": true]]
            + team.map { agent -> [String: Any] in
                ["name": agent.name, "role": "worker", "title": agent.title, "runtime": "claude", "can": [String](),
                 "placed": true]
            }
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "undo-\(UUID().uuidString)", "time": now, "agents": agents, "tasks": tasks,
            "holds": holds, "outcomes": [], "notes": [], "needs": needs, "permissions": [], "messages": [], "reports": [],
            "ui_features": [AnsweredMark.feature, "task_controls"]] as [String: Any])
    }

    private static func need(_ id: Int, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "title": "Choose the day of the move", "why": "", "todo": "", "raised": now - 300, "by": "manager",
         "answered": NSNull()].merging(extra) { _, new in new }
    }

    /// **No answer of a test stays held after it**, also when it stops halfway: one held answer for the whole app, so
    /// a held answer of an earlier test would go at the next test's press, to a hub that no longer answers.
    @MainActor private static func leaveNothingHeld(_ store: FleetStore) {
        for need in store.state?.needs ?? [] { AnswerHolds.shared.undo(need, store: store) }
    }

    /// A store of the app that reads `hub`, after the hub's first answer: it can write.
    @MainActor private static func store(on hub: LoopbackHub, _ state: Data) throws -> FleetStore {
        _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        try noneLeft(store)
        Task { await store.refresh() }
        ViewHost.turn(10) { store.canWrite }
        return store
    }

    /// **No earlier test left a request in this store's outbox**: the test folder lives for the whole test process
    /// (`ViewHost`), and only the end of a test's window removes its outbox (`ViewHost.close`). A request left there
    /// blocks this store's writes (`FleetStore.canWrite`) and draws its line of what was not sent under the page, so a
    /// test fails as the leak that it is, with its words, and not later as a send that never came. The outbox goes
    /// before the test fails: this test makes no window whose end would remove it, and each later test starts clean.
    @MainActor private static func noneLeft(_ store: FleetStore) throws {
        guard let left = store.pending else { return }
        try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer"))
        throw ViewHost.Missing(description: "an earlier test left its request in the outbox: request "
            + "\(left.needID.map(String.init) ?? "none"), \(left.refusal == nil ? "not refused" : "refused")")
    }

    struct Waits: Sendable {
        let heldAtPress: Bool
        let heldAgain: Bool
        /// Where the second click went, in the option's frame: the failure says it.
        let click: String
        let onlyBadge: Bool
        let sentBeforeUndo: Bool
        let openAgain: Bool
        let waited: Double?
        let choice: Bool
        let once: Bool
        let badgeGone: Bool
    }

    /// **In a chat his answer completes on its card, and the badge at the bottom of the page has Undo** (the owner's F12,
    /// 22 November 2026): a press of an option folds the card with his answer and no Undo on its line, "Undo" stands in
    /// the badge only, and nothing reaches the hub; the badge's Undo opens the card with its options; a press that is not
    /// taken back reaches the hub once, when the wait is over and never before, and the badge goes. Bug: Undo on the
    /// card's line beside the badge, or a badge whose Undo does not take the answer back.
    @Test func anAnswerWaitsAndUndoOpensTheCardAgain() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Waits in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(51, ["options": ["Friday", "Monday"]])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let posts = { hub.requests.filter { $0.method == "POST" && $0.path == "/ui/needs/51" } }
            guard let monday = try ViewHost.middle(of: "Monday", in: window) else {
                throw ViewHost.Missing(description: "the card's option Monday is not drawn")
            }
            ViewHost.atOnce(ViewHost.click(monday, in: window))
            let held = holds.held[51] != nil
            // the badge has come up to its place (0.18 s): "Undo" stands in it, and nowhere else
            ViewHost.turn(5) { Self.badge(in: window) != nil }
            ViewHost.turn(0.5)
            guard let badge = Self.badge(in: window) else {
                throw ViewHost.Missing(description: "the page has no badge of the held answer")
            }
            let undoes = try Self.everywhere(String(l10n: "Undo"), in: window)
            let onlyBadge = !undoes.isEmpty && undoes.allSatisfy { badge.frame.insetBy(dx: -2, dy: -2).contains($0) }
            ViewHost.atOnce(ViewHost.click(badge.undo, in: window))
            let sentBeforeUndo = !posts().isEmpty
            ViewHost.turn(5) { holds.held[51] == nil }
            let friday = try ViewHost.middle(of: "Friday", in: window, seconds: 5)
            let open = holds.held[51] == nil && friday != nil
            // a press that he does not take back, once the stand-in hub's reading has come again (the store writes
            // within 12 s of an answer) and the option takes a click where it is drawn, the same in two reads: after
            // Undo the card grows back and the chat moves to keep its end in sight
            holds.wait = .milliseconds(800)
            let read = store.lastSuccess
            Task { await store.refresh() }
            var reach = Reach(why: "not read"), before = Reach(why: "not read")
            ViewHost.turn(20) {
                guard store.lastSuccess != read, store.canWrite else { return false }
                before = reach
                reach = Self.reachable("Monday", option: "need-option-51-1", in: window)
                return reach.settled(after: before)
            }
            guard let again = reach.point else {
                throw ViewHost.Missing(description: "Monday takes no click: \(reach.why); read again "
                    + "\(store.lastSuccess != read), writes \(store.canWrite)")
            }
            let pressed = Date()
            ViewHost.atOnce(ViewHost.click(again, in: window))
            let heldAgain = holds.held[51] != nil, click = reach.why
            // the stand-in hub is read again, as the app reads its hub: the store writes within 12 s of an answer
            Task { await store.refresh() }
            ViewHost.turn(20) { !posts().isEmpty }
            let post = posts().first
            ViewHost.turn(5) { Self.badge(in: window) == nil }
            // the store has ended its send (the stand-in hub refuses it): the window's end removes the outbox after
            // the refusal is saved there; a send that does not end fails this test
            guard ViewHost.turn(10, until: { !store.sending }) else {
                throw ViewHost.Missing(description: "the store's send did not end in 10 s")
            }
            return Waits(heldAtPress: held, heldAgain: heldAgain, click: click, onlyBadge: onlyBadge,
                         sentBeforeUndo: sentBeforeUndo, openAgain: open,
                         waited: post.map { $0.at.timeIntervalSince(pressed) },
                         choice: post?.body.contains(#""choice":1"#) == true, once: posts().count == 1,
                         badgeGone: Self.badge(in: window) == nil)
        }
        #expect(seen.heldAtPress && !seen.sentBeforeUndo, "the press waits, and nothing reaches the hub")
        #expect(seen.onlyBadge, "Undo stands in the badge, and not on the card's line")
        #expect(seen.openAgain, "the badge's Undo opens the card with its options")
        #expect(seen.heldAgain, "his second press waits too (its click: \(seen.click))")
        #expect((seen.waited ?? 0) >= 0.8, "the answer reaches the hub only once the wait is over")
        #expect(seen.choice && seen.once, "and it is the option that he pressed, once")
        #expect(seen.badgeGone, "the badge goes with the wait")
        #expect(screen.stayedHis)
    }

    struct Leaves: Sendable {
        let next: Bool
        let lane: Bool
        let count: Bool
        let label: String?
        let actions: [String]
        let words: Bool
        let sent: Bool
        let back: Bool
        let countBack: Bool
    }

    /// **On Needs you an answered request leaves at once, and the badge's Undo brings it back at hand** (the owner's F12,
    /// 22 November 2026: "complete it immediately and show like a badge at the bottom of the page that shows what has
    /// been chosen"): his key 2 and Return answer the request at hand; inside two seconds the next request is at hand, the
    /// answered one has no card in the lane, the sidebar's count is one less, the badge says his answer with Undo (to
    /// VoiceOver too: one element and its action), and nothing reached the hub. A click on the badge's Undo gives the
    /// request back at hand with its options, and the count back. Bug: the request stays at hand for the 5 seconds, or an
    /// Undo that brings back a request that is in no lane.
    @Test func onNeedsYouAnAnsweredRequestLeavesAndTheBadgeBringsItBack() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Leaves in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [
                Self.need(55, ["options": ["Friday", "Monday"]]),
                Self.need(56, ["title": "Choose the colour of the site", "options": ["Dark", "Orange"]])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
            store.destination = .needs
            store.selectedNeed = 55
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let posts = { hub.requests.filter { $0.method == "POST" } }
            guard try ViewHost.middle(of: "Monday", in: window) != nil else {
                throw ViewHost.Missing(description: "the step's option Monday is not drawn")
            }
            ViewHost.atOnce(ViewHost.keys("2\r", in: window))
            ViewHost.turn(5) { holds.held[55] != nil }
            // inside two seconds: the moment in which his answer settles (0.78 s) is over, and the next one is at hand
            let next = ViewHost.turn(2) { store.selectedNeed == 56 }
            ViewHost.turn(0.5)
            let lane = Self.element("need-card-55", in: window) == nil && Self.element("need-card-56", in: window) != nil
            let count = Self.reads("nav-needs", in: window).value == String(l10n: "1 item needs you")
            let label = Self.reads("answer-badge", in: window).label
            let actions = Self.actions("answer-badge", in: window)
            guard let badge = Self.badge(in: window) else {
                throw ViewHost.Missing(description: "the page has no badge of the held answer")
            }
            // the request at hand is the next one: his answer's words stand in the badge
            let words = try ViewHost.middle(of: "Monday", in: window, seconds: 3)
                .map { badge.frame.insetBy(dx: -2, dy: -2).contains($0) } ?? false
            let sent = !posts().isEmpty
            ViewHost.atOnce(ViewHost.click(badge.undo, in: window))
            ViewHost.turn(5) { holds.held[55] == nil }
            let friday = try ViewHost.middle(of: "Friday", in: window, seconds: 5)
            let back = holds.held[55] == nil && store.selectedNeed == 55 && friday != nil && posts().isEmpty
            let two = String(l10n: "\(2) items need you")
            ViewHost.turn(2) { Self.reads("nav-needs", in: window).value == two }
            return Leaves(next: next, lane: lane, count: count, label: label, actions: actions, words: words, sent: sent,
                          back: back, countBack: Self.reads("nav-needs", in: window).value == two)
        }
        #expect(seen.next && seen.lane, "the next request is at hand inside two seconds, and the answered one left the lane")
        #expect(seen.count, "the sidebar's count is one less while the answer waits")
        #expect(seen.words && !seen.sent, "the badge says his answer, and nothing reached the hub")
        #expect(seen.label == "Choose the day of the move, answered: Monday" && seen.actions == ["Undo"],
                "VoiceOver reads the badge as one element with its action Undo")
        #expect(seen.back, "the badge's Undo brings the request back at hand with its options, and sends nothing")
        #expect(seen.countBack, "and the count back")
        #expect(screen.stayedHis)
    }

    /// **Edit › Undo takes his held answer back** (F12): on Needs you, with no field in use, the system's Undo (the
    /// action of Edit › Undo, ⌘Z, through the window) while the badge stands takes the answer back, and the request is at
    /// hand again with its options, with nothing sent. Bug: ⌘Z that does nothing while the badge says Undo.
    @Test func editUndoTakesTheHeldAnswerBack() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (held: Bool, undone: Bool, back: Bool, sent: Bool) in
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(65, ["options": ["Friday", "Monday"]])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
            store.destination = .needs
            store.selectedNeed = 65
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard try ViewHost.middle(of: "Monday", in: window) != nil else {
                throw ViewHost.Missing(description: "the step's option Monday is not drawn")
            }
            ViewHost.atOnce(ViewHost.keys("2\r", in: window))
            let held = ViewHost.turn(5) { holds.held[65] != nil }
            ViewHost.turn(1)
            // the action of Edit › Undo, up the responder chain of the window that has the keys (the app of a test is
            // never active, so it has no key window of its own to send it to)
            let undone = (window.firstResponder ?? window).tryToPerform(Selector(("undo:")), with: nil)
            ViewHost.turn(5) { holds.held[65] == nil }
            let friday = try ViewHost.middle(of: "Friday", in: window, seconds: 5)
            return (held, undone, holds.held[65] == nil && store.selectedNeed == 65 && friday != nil,
                    hub.requests.contains { $0.method == "POST" })
        }
        #expect(seen.held, "the key's answer waits")
        #expect(seen.undone && seen.back, "Edit › Undo brings the request back at hand with its options")
        #expect(!seen.sent, "nothing reached the hub")
        #expect(screen.stayedHis)
    }

    /// **The badge says what he chose, as the folded card's line does** (F12; his rule of 14 November 2026): the ticked
    /// options joined with "; ", with a check, and a role that an option names as that agent's name with its role
    /// beside it, as the card reads it (F23, `HisAnswer.spoken`); then the words that he wrote on the next request,
    /// with no check. Bugs: a check before his own words; a badge, and VoiceOver's words of it, that say the role where
    /// the card says the agent. The role's option is the first one: "Give" opens a step only at a sentence's start
    /// (`CardNames.opening`), so "Dark; Give Marketing write" keeps the role on the card and on the badge alike.
    @Test func theBadgeSaysWhatHeChose() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (ticked: String?, tickedCheck: Bool?, written: String?, writtenCheck: Bool?) in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [
                Self.need(58, ["title": "Choose the colours of the site",
                               "options": ["Give Marketing write", "Orange", "Dark"], "multi": true]),
                Self.need(59, ["title": "Name the new page"])], team: [("wren", "Marketing")]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
            store.destination = .needs
            store.selectedNeed = 58
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard try ViewHost.middle(of: "Orange", in: window) != nil else {
                throw ViewHost.Missing(description: "the step's options are not drawn")
            }
            // keys 1 and 3 tick two options, and Return sends them
            let keys: [(String, UInt16)] = [("1", 18), ("3", 20), ("\r", 36)]
            ViewHost.atOnce(keys.flatMap { character, code in
                [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: code)
                }
            })
            ViewHost.turn(5) { holds.held[58] != nil }
            ViewHost.turn(0.5)
            let ticked = Self.reads("answer-badge", in: window).label
            let tickedCheck = holds.held[58]?.look.check
            // his own words on the next request
            store.selectedNeed = 59
            guard let field = try ViewHost.middle(of: String(l10n: "Your answer"), in: window) else {
                throw ViewHost.Missing(description: "the box of the next request is not drawn")
            }
            ViewHost.atOnce(ViewHost.click(field, in: window))
            ViewHost.turn(1) { ViewHost.fieldWords(in: window) != nil }
            ViewHost.atOnce(ViewHost.keys("hello\r", in: window))
            ViewHost.turn(5) { holds.held[59] != nil }
            ViewHost.turn(0.5)
            let written = Self.reads("answer-badge", in: window).label
            let writtenCheck = holds.held[59]?.look.check
            // nothing stays held after the test
            if let need = store.state?.needs.first(where: { $0.id == 59 }) { holds.undo(need, store: store) }
            return (ticked, tickedCheck, written, writtenCheck)
        }
        #expect(seen.ticked == "Choose the colours of the site, answered: Give Wren · Marketing write; Dark",
                "the ticked options joined with \"; \", and the role's agent by name, as on the card")
        #expect(seen.tickedCheck == true, "a check before the ticked options")
        #expect(seen.written == "Name the new page, answered: hello", "his own words")
        #expect(seen.writtenCheck == false, "no check before his own words")
        #expect(screen.stayedHis)
    }

    /// **VoiceOver hears his own word "Answered" as his words** (a reader of F12): the announcement of a held answer
    /// (the row of Needs you, the capsule of a card's own window) says "Answered" alone only for files alone. Bug: it
    /// compared the words with "Answered", so his typed "Answered" was heard as an answer of files alone.
    @Test func hisWordAnsweredIsHeardAsHisWords() throws {
        let need = try HubState.decode(Self.reading(needs: [Self.need(60)])).needs[0]
        let hub = try #require(URL(string: "http://127.0.0.1:9"))
        let typed = AnswerBadge.Look(PendingRequest(hub: hub, database: "d", client: "c", needID: 60, text: "Answered"),
                                     need: need, names: nil)
        let files = AnswerBadge.Look(PendingRequest(hub: hub, database: "d", client: "c", needID: 60, attachments: [7],
                                                    text: ""), need: need, names: nil)
        #expect(typed.announced == "Answered: Answered", "his own word, after \"Answered:\"")
        #expect(files.announced == "Answered", "files alone")
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
            defer { Self.leaveNothingHeld(store) }
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
            // the store has ended its send (the stand-in hub refuses it): the window's end removes the outbox after
            // the refusal is saved there, and no later test reads it; a send that does not end fails this test
            guard ViewHost.turn(10, until: { !store.sending }) else {
                throw ViewHost.Missing(description: "the store's send did not end in 10 s")
            }
            return (blocked, held, before, posts().first?.body.contains(#""choices":[0,2]"#) == true)
        }
        #expect(seen.held, "keys 1, 3 and Return hold the two ticked options")
        #expect(seen.blocked, "another request blocked the store before their wait ended")
        #expect(!seen.before, "nothing went while the store could not write")
        #expect(seen.after, "the ticked options went once it could")
        #expect(screen.stayedHis)
    }

    /// His words go into the box, Return holds them, and the badge's Undo puts them back in the box, with nothing sent.
    @Test func undoPutsHisWordsBackInTheBox() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (box: String, sent: Bool) in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(52)]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
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
            ViewHost.turn(5) { Self.badge(in: window) != nil }
            ViewHost.turn(0.5)
            guard let badge = Self.badge(in: window) else {
                throw ViewHost.Missing(description: "the page has no badge of the held answer")
            }
            ViewHost.atOnce(ViewHost.click(badge.undo, in: window))
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
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(53)]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
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
            ViewHost.turn(5) { Self.badge(in: window) != nil }
            ViewHost.turn(0.5)
            guard let badge = Self.badge(in: window) else {
                throw ViewHost.Missing(description: "the held reply has no badge")
            }
            ViewHost.atOnce(ViewHost.click(badge.undo, in: window))
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
            try Self.noneLeft(store)
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

    /// **A quit sends what waits, and after two answers nothing stays unsent**: his second answer sends the first at
    /// once, so one answer waits (one held answer for the whole app); the app ends once that one went, and at once when
    /// nothing waits. Bug: two held answers, and the one outbox request takes only the first at the quit.
    @Test func aQuitSendsTheAnswerThatWaits() async throws {
        @MainActor final class Flags { var first = false, went = false, replied = false }
        let (seen, _) = try await ViewHost.onMainLoop { () -> (now: Bool, first: Bool, one: Bool, later: Bool, went: Bool, replied: Bool) in
            let store = ViewHost.store(try ViewHost.reading(needs: [Self.need(53, ["options": ["Friday", "Monday"]]),
                                                                    Self.need(57, ["options": ["Dark", "Orange"]])],
                                                            features: []))
            try Self.noneLeft(store)
            let needs = try #require(store.state?.needs)
            let holds = AnswerHolds()
            holds.wait = .seconds(60)
            let flags = Flags()
            let now = FleetAppDelegate.ends(after: holds) { flags.replied = true } == .terminateNow
            let shown = { (need: Int, text: String) in
                PendingRequest(hub: store.hub, database: store.state?.db ?? "", client: store.installation,
                               needID: need, choice: 1, text: text)
            }
            holds.hold(needs[0], store: store, shown: shown(53, "Monday")) { flags.first = true }
            holds.hold(needs[1], store: store, shown: shown(57, "Orange")) { flags.went = true }
            ViewHost.turn(5) { flags.first }
            let one = flags.first && !flags.went && Set(holds.held.keys) == [57]
            let later = FleetAppDelegate.ends(after: holds) { flags.replied = true } == .terminateLater
            ViewHost.turn(5) { flags.replied }
            return (now, flags.first, one, later, flags.went, flags.replied)
        }
        #expect(seen.now, "nothing waits: the app ends at once")
        #expect(seen.first && seen.one, "his second answer sent the first at once, and only the second waits")
        #expect(seen.later && seen.went && seen.replied, "the held answer goes, and then the app ends")
    }

    /// **His next answer sends the one before it at once** (one held answer for the whole app; F12): on Needs you he
    /// answers one request and then the next inside the wait; the stand-in hub has the first answer long before the wait
    /// of the second ends, only the second is held, and the badge says the second. Bug: two held answers, and a quit
    /// sends only one.
    @Test func aSecondAnswerSendsTheFirstAtOnce() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (first: Bool, held: Bool, second: Bool, badge: String?) in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [
                Self.need(66, ["options": ["Friday", "Monday"]]),
                Self.need(67, ["title": "Choose the colour of the site", "options": ["Dark", "Orange"]])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
            store.destination = .needs
            store.selectedNeed = 66
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let posts = { (id: Int) in hub.requests.filter { $0.method == "POST" && $0.path == "/ui/needs/\(id)" } }
            guard try ViewHost.middle(of: "Monday", in: window) != nil else {
                throw ViewHost.Missing(description: "the option Monday of the first request is not drawn")
            }
            ViewHost.atOnce(ViewHost.keys("2\r", in: window))
            ViewHost.turn(5) { holds.held[66] != nil }
            store.selectedNeed = 67
            guard try ViewHost.middle(of: "Orange", in: window) != nil else {
                throw ViewHost.Missing(description: "the option Orange of the second request is not drawn")
            }
            ViewHost.atOnce(ViewHost.keys("2\r", in: window))
            // the stand-in hub is read again, as the app reads its hub: the store writes within 12 s of an answer
            Task { await store.refresh() }
            ViewHost.turn(5) { holds.held[67] != nil }
            // far inside the second wait (60 s): the first answer reached the hub
            let first = ViewHost.turn(5) { !posts(66).isEmpty }
            let held = Set(holds.held.keys) == [67]
            let second = !posts(67).isEmpty
            ViewHost.turn(0.5)
            let badge = Self.reads("answer-badge", in: window).label
            // nothing stays held after the test
            if let need = store.state?.needs.first(where: { $0.id == 67 }) { holds.undo(need, store: store) }
            // the store has ended the first answer's send (the stand-in hub refuses it): the window's end removes the
            // outbox after the refusal is saved there; a send that does not end fails this test
            guard ViewHost.turn(10, until: { !store.sending }) else {
                throw ViewHost.Missing(description: "the store's send did not end in 10 s")
            }
            return (first, held, second, badge)
        }
        #expect(seen.first, "the first answer went at once when he gave the second")
        #expect(seen.held && !seen.second, "only the second answer waits, and nothing of it reached the hub")
        #expect(seen.badge == "Choose the colour of the site, answered: Orange", "the badge says the second answer")
        #expect(screen.stayedHis)
    }

    struct Sidebar: Sendable {
        let kept: Bool
        let inSidebar: Bool
        let windowClosed: Bool
        let back: Bool
        let sentBeforeClose: Bool
        let closed: Bool
    }

    /// **A held answer keeps its 5 seconds on every page, its badge stands at the foot of the sidebar, and its Undo
    /// brings the card back** (the owner's F22-1 (a), 23 November 2026, as Apple Mail's Undo Send): he answers on Needs
    /// you and opens Tasks inside the wait; the answer still waits, nothing reached the hub, and the badge stands in the
    /// sidebar; the request's own window, opened and closed meanwhile, leaves it as it is; its Undo opens Needs you
    /// with the request at hand and its options. **The close of the main window still sends a held answer at once.**
    /// Bugs: a page change that sends the answer, the close of the request's own window that sends the answer held on
    /// the page, or an Undo that changes nothing on the screen.
    @Test func aPageChangeKeepsTheHeldAnswerAndItsUndoBringsTheCardBack() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Sidebar in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(57, ["options": ["Friday", "Monday"]])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
            store.destination = .needs
            store.selectedNeed = 57
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let posts = { hub.requests.filter { $0.method == "POST" && $0.path == "/ui/needs/57" } }
            guard try ViewHost.middle(of: "Monday", in: window) != nil else {
                throw ViewHost.Missing(description: "the option Monday is not drawn")
            }
            ViewHost.atOnce(ViewHost.keys("2\r", in: window))
            ViewHost.turn(5) { holds.held[57] != nil }
            // he opens Tasks inside the wait (60 s)
            store.destination = .activity
            ViewHost.turn(2)
            let kept = holds.held[57] != nil && posts().isEmpty
            ViewHost.turn(5) { Self.badge(in: window) != nil }
            guard let badge = Self.badge(in: window) else {
                throw ViewHost.Missing(description: "no badge of the held answer on Tasks")
            }
            // the sidebar is the window's first 320 points (`FleetStyle.sidebarWidth`)
            let inSidebar = badge.frame.minX >= 0 && badge.frame.maxX <= FleetStyle.sidebarWidth
            // he opens the request's own window and closes it: the answer held on the page still waits, with its badge
            NeedWindows.room = NSRect(x: -40000, y: -40000, width: 1440, height: 900)
            defer { NeedWindows.room = nil }
            defer { NSApp.windows.first { $0.identifier?.rawValue == "need-window-57" }?.close() }
            let need = try #require(store.state?.needs.first { $0.id == 57 })
            NeedWindows.open(store: store, need: need)
            let opened = ViewHost.turn(5) { NeedWindows.window(of: 57)?.isVisible == true }
            Task { await store.refresh() }
            NeedWindows.window(of: 57)?.close()
            ViewHost.turn(2) { !posts().isEmpty }
            let windowClosed = opened && NeedWindows.window(of: 57) == nil && holds.held[57] != nil && posts().isEmpty
                && Self.badge(in: window) != nil
            ViewHost.atOnce(ViewHost.click(badge.undo, in: window))
            ViewHost.turn(5) { holds.held[57] == nil && store.destination == .needs }
            let friday = try ViewHost.middle(of: "Friday", in: window, seconds: 5)
            let back = holds.held[57] == nil && store.destination == .needs && store.selectedNeed == 57 && friday != nil
            // he answers again, and the main window closes inside the wait
            guard let monday = try ViewHost.middle(of: "Monday", in: window) else {
                throw ViewHost.Missing(description: "the option Monday is not drawn again")
            }
            ViewHost.atOnce(ViewHost.click(monday, in: window))
            guard ViewHost.turn(5, until: { holds.held[57] != nil }) else {
                throw ViewHost.Missing(description: "the second answer is not held")
            }
            let sentBeforeClose = !posts().isEmpty
            // the stand-in hub is read again, as the app reads its hub: the store writes within 12 s of an answer
            Task { await store.refresh() }
            window.close()
            let closed = ViewHost.turn(5) { posts().count == 1 } && holds.held[57] == nil
            // the store has ended its send (the stand-in hub refuses it): the window's end removes the outbox after
            // the refusal is saved there, and no later test reads it; a send that does not end fails this test
            guard ViewHost.turn(10, until: { !store.sending }) else {
                throw ViewHost.Missing(description: "the store's send did not end in 10 s")
            }
            return Sidebar(kept: kept, inSidebar: inSidebar, windowClosed: windowClosed, back: back,
                           sentBeforeClose: sentBeforeClose, closed: closed)
        }
        #expect(seen.kept, "the answer still waits on Tasks, and nothing reached the hub")
        #expect(seen.inSidebar, "its badge stands in the sidebar")
        #expect(seen.windowClosed, "the close of the request's own window sends nothing, and the badge stays")
        #expect(seen.back, "the badge's Undo opens Needs you with the request at hand and its options")
        #expect(!seen.sentBeforeClose && seen.closed, "the close of the main window sends the held answer at once")
        #expect(screen.stayedHis)
    }

    /// **The badge's Undo of an answer given in a chat opens that chat with its card** (F22-1 (a)): he answers on a card
    /// in the manager's chat and opens Needs you; the badge's Undo takes him back to that chat, where the card stands
    /// open with its options, and nothing reached the hub. Bug: an Undo whose card stays out of his sight.
    @Test func undoOfAChatAnswerFromAnotherPageOpensItsChat() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (held: Bool, chat: Bool, open: Bool, sent: Bool) in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(68, ["options": ["Friday", "Monday"]])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let monday = try ViewHost.middle(of: "Monday", in: window) else {
                throw ViewHost.Missing(description: "the card's option Monday is not drawn")
            }
            ViewHost.atOnce(ViewHost.click(monday, in: window))
            let held = ViewHost.turn(5) { holds.held[68] != nil }
            store.destination = .needs
            ViewHost.turn(5) { Self.badge(in: window) != nil }
            ViewHost.turn(0.5)
            guard let badge = Self.badge(in: window) else {
                throw ViewHost.Missing(description: "no badge of the held answer on Needs you")
            }
            ViewHost.atOnce(ViewHost.click(badge.undo, in: window))
            let chat = ViewHost.turn(5) { store.destination == .agent("manager") && holds.held[68] == nil }
            let open = try ViewHost.middle(of: "Friday", in: window, seconds: 5) != nil
            return (held, chat, open, hub.requests.contains { $0.method == "POST" })
        }
        #expect(seen.held, "the press in the chat waits")
        #expect(seen.chat, "the badge's Undo opens the manager's chat")
        #expect(seen.open && !seen.sent, "its card stands open with its options, and nothing reached the hub")
        #expect(screen.stayedHis)
    }

    struct WindowBadge: Sendable {
        let held: Bool
        let small: Bool
        let sentEarly: Bool
        let back: Bool
        let inSight: Bool
        /// The card's frame after Undo, and the room's: the failure says them.
        let place: String
        let onScreen: Bool
        /// The seconds until its options are drawn after Undo, or nil.
        let options: Double?
        let keys: Bool
        let goneBeforeHub: Bool
        let refused: Bool
        let noCapsule: Bool
    }

    /// **The card's own window becomes the badge of his answer, and its Undo gives the card back** (the owner's F22-2
    /// (a), 23 November 2026: "close immediately ... a small floating badge"): a press in the card's window makes it,
    /// inside one second, a window one line high with the badge and its Undo, the card out of sight, and nothing
    /// reaches the hub; Undo gives back the card in sight and on the screen with its options, also after he dragged the
    /// badge to a corner, and so does Edit › Undo (⌘Z) in the badge's window; when the wait of an answer that he does
    /// not take back ends, the badge goes, and the window with it, before the hub has the answer (the picture of his
    /// F22-2 (a): the badge goes after 5 seconds); the hub refuses it, and the request stays open with the refusal,
    /// which the main window shows under its page. Bugs: a card's window that stands whole until the hub has the
    /// answer; a card that comes back out of sight or off the screen; a badge whose Undo needs the mouse; a badge that
    /// stays after its wait, over every app, with an Undo that does nothing.
    @Test func theCardsWindowBecomesTheBadgeAndItsUndoGivesTheCardBack() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 120) { () -> WindowBadge in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [Self.need(69, ["options": ["Friday", "Monday"]])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            // no main window here, whose end removes it (`ViewHost.close`): the refused answer in the outbox, which the
            // next test's store would read as its own unsent request, and write nothing
            defer { try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer")) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
            // the card's window opens in a room off every screen, never on his screen
            let room = NSRect(x: -40000, y: -40000, width: 1440, height: 900)
            NeedWindows.room = room
            defer { NeedWindows.room = nil }
            let need = try #require(store.state?.needs.first { $0.id == 69 })
            NeedWindows.open(store: store, need: need)
            defer { NSApp.windows.first { $0.identifier?.rawValue == "need-window-69" }?.close() }
            let posts = { hub.requests.filter { $0.method == "POST" && $0.path == "/ui/needs/69" } }
            ViewHost.turn(5) { NeedWindows.window(of: 69)?.isVisible == true }
            guard let card = NeedWindows.window(of: 69), let monday = try ViewHost.middle(of: "Monday", in: card) else {
                throw ViewHost.Missing(description: "the card's window has no option Monday")
            }
            ViewHost.atOnce(ViewHost.click(monday, in: card))
            let held = ViewHost.turn(5) { holds.held[69] != nil }
            // inside one second the window is the badge: one line high, with its Undo, and the card is out of sight
            ViewHost.turn(1) { (NeedWindows.window(of: 69)?.frame.height ?? .infinity) < 60 }
            ViewHost.turn(0.4)
            guard let small = NeedWindows.window(of: 69), let badge = Self.badge(in: small) else {
                throw ViewHost.Missing(description: "the card's window did not become the badge")
            }
            let oneLine = small.frame.height < 60 && small !== card && small.isVisible && !card.isVisible
            let sentEarly = !posts().isEmpty
            // he drags the badge to the bottom-left corner, and its Undo: the card comes back in sight and inside the
            // screen's room, with its options
            small.setFrameOrigin(NSPoint(x: room.minX + 8, y: room.minY + 8))
            ViewHost.atOnce(ViewHost.click(badge.undo, in: small))
            ViewHost.turn(5) { holds.held[69] == nil && (NeedWindows.window(of: 69)?.frame.height ?? 0) > 200 }
            ViewHost.turn(0.5)
            guard let again = NeedWindows.window(of: 69) else {
                throw ViewHost.Missing(description: "no card's window after Undo")
            }
            let back = holds.held[69] == nil && again === card && again.frame.height > 200
            let inSight = again.isVisible
            let place = "card \(again.frame), room \(room)"
            let onScreen = room.insetBy(dx: -1, dy: -1).contains(again.frame)
            let undone = Date()
            let options = try ViewHost.middle(of: "Friday", in: again, seconds: 20)
                .map { _ in -undone.timeIntervalSinceNow }
            // he answers again, and Edit › Undo (⌘Z) in the badge's window takes it back, with no mouse
            guard let mondayKeys = try ViewHost.middle(of: "Monday", in: again) else {
                throw ViewHost.Missing(description: "the card did not come back with Monday")
            }
            ViewHost.atOnce(ViewHost.click(mondayKeys, in: again))
            ViewHost.turn(5) { holds.held[69] != nil && NeedWindows.window(of: 69) !== card }
            ViewHost.turn(0.4)
            let keyed = NeedWindows.window(of: 69)
            if let keyed, keyed !== card {
                _ = (keyed.firstResponder ?? keyed).tryToPerform(Selector(("undo:")), with: nil)
            }
            let undoneByKeys = ViewHost.turn(5) { holds.held[69] == nil && card.isVisible && card.frame.height > 200 }
            let keys = keyed != nil && keyed !== card && undoneByKeys
            ViewHost.turn(0.5)
            // a press that he does not take back: when its wait ends the badge goes, and the window with it, while the
            // hub has not answered (it holds its answer until the test has read the window, and then refuses it); the
            // request stays open, with the refusal
            let read = DispatchSemaphore(value: 0)
            defer { read.signal() }             // a test that stops halfway leaves no answer held
            hub.answer("POST", "/ui/needs/69") { _ in
                _ = read.wait(timeout: .now() + 20)
                return (404, Data(#"{"error":"not here"}"#.utf8))
            }
            holds.wait = .milliseconds(800)
            guard let mondayAgain = try ViewHost.middle(of: "Monday", in: again) else {
                throw ViewHost.Missing(description: "the card did not come back with Monday")
            }
            ViewHost.atOnce(ViewHost.click(mondayAgain, in: again))
            // the stand-in hub is read again, as the app reads its hub: the store writes within 12 s of an answer
            Task { await store.refresh() }
            let gone = ViewHost.turn(10) { !posts().isEmpty && NeedWindows.window(of: 69) == nil }
            let goneBeforeHub = gone && store.sending && store.pending?.refusal == nil
            read.signal()
            let refused = ViewHost.turn(10) { store.pending?.refusal != nil && !store.sending }
                && store.openNeeds.contains { $0.id == 69 }
            let noCapsule = !NSApp.windows.contains {
                $0.identifier?.rawValue.hasPrefix("need-window") == true && $0.isVisible
            }
            return WindowBadge(held: held, small: oneLine, sentEarly: sentEarly, back: back, inSight: inSight,
                               place: place, onScreen: onScreen, options: options, keys: keys,
                               goneBeforeHub: goneBeforeHub, refused: refused, noCapsule: noCapsule)
        }
        #expect(seen.held && seen.small, "a press in the card's window makes the window the badge, one line high")
        #expect(!seen.sentEarly, "nothing reached the hub during the wait")
        #expect(seen.back, "the badge's Undo gives back the card, whole")
        #expect(seen.inSight, "in sight")
        #expect(seen.onScreen, "inside the screen, after he dragged the badge to its corner: \(seen.place)")
        #expect((seen.options ?? .infinity) < 5, "with its options, inside 5 seconds")
        #expect(seen.keys, "Edit › Undo (⌘Z) in the badge's window gives back the card")
        #expect(seen.goneBeforeHub, "when the wait ends the badge goes, with the window, before the hub has the answer")
        #expect(seen.refused, "a refused answer leaves the request open, with the refusal")
        #expect(seen.noCapsule, "and no badge with an Undo stays")
        #expect(screen.stayedHis)
    }

    /// **The option that opens Add device goes at once and is not held** (F12, A1): the first option of an item for his
    /// phone reaches the hub at once and opens Settings › Servers in the frame of his press. Bug: the app changes the page
    /// by itself 5 seconds after the card completed.
    @Test func theOptionThatOpensAddDeviceGoesAtOnce() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (held: Bool, sent: Bool, page: Bool) in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let hub = try LoopbackHub(state: Self.reading(needs: [
                Self.need(60, ["title": "Add the new phone", "options": ["Add it", "Not now"], "add_device": 1])]))
            defer { hub.stop() }
            let holds = AnswerHolds.shared
            holds.wait = .seconds(60)
            defer { holds.wait = .seconds(5) }
            let store = try Self.store(on: hub, Self.reading(needs: []))
            defer { Self.leaveNothingHeld(store) }
            store.destination = .needs
            store.selectedNeed = 60
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            // the option takes a click where it is drawn, and the store can write (the stand-in hub's reading came)
            var reach = Reach(why: "not read")
            guard ViewHost.turn(20, until: {
                reach = Self.reachable("Add it", option: "need-option-60-0", in: window)
                return reach.point != nil && store.canWrite
            }) else {
                throw ViewHost.Missing(description: "Add it takes no press: \(reach.why), writes \(store.canWrite)")
            }
            // key 1 marks the first option, and Return presses it
            let keys: [(String, UInt16)] = [("1", 18), ("\r", 36)]
            ViewHost.atOnce(keys.flatMap { character, code in
                [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: code)
                }
            })
            let held = holds.held[60] != nil
            // the stand-in hub is read again, as the app reads its hub: the store writes within 12 s of an answer
            Task { await store.refresh() }
            // the test's hold is 60 s: a send inside 20 s went with no hold
            let sent = ViewHost.turn(20) { hub.requests.contains { $0.method == "POST" && $0.path == "/ui/needs/60" } }
            // the store has ended its send (the stand-in hub refuses it): the window's end removes the outbox after
            // the refusal is saved there, and no later test reads it; a send that does not end fails this test
            guard ViewHost.turn(10, until: { !store.sending }) else {
                throw ViewHost.Missing(description: "the store's send did not end in 10 s")
            }
            return (held || holds.held[60] != nil, sent, store.destination == .settings(.servers))
        }
        #expect(!seen.held, "the press is not held")
        #expect(seen.sent && seen.page, "it reaches the hub at once, and Settings › Servers opens")
        #expect(screen.stayedHis)
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

    /// The element with this identifier in the window, by the accessibility tree: SwiftUI makes its elements once the
    /// app says that an assistive app reads it (`JobCardPressTests`).
    @MainActor private static func element(_ identifier: String, in window: NSWindow) -> NSObject? {
        var queue: [NSObject] = window.contentView.map { [$0] } ?? []
        while !queue.isEmpty {
            let object = queue.removeFirst()
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.perform(NSSelectorFromString("accessibilityIdentifier"))?.takeUnretainedValue() as? String == identifier {
                return object
            }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let kids = object.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any] {
                queue += kids.compactMap { $0 as? NSObject }
            }
        }
        return nil
    }

    /// The VoiceOver actions of the element with this identifier in the window.
    @MainActor private static func customActions(_ identifier: String, in window: NSWindow) -> [NSAccessibilityCustomAction] {
        guard let object = element(identifier, in: window),
              object.responds(to: NSSelectorFromString("accessibilityCustomActions")) else { return [] }
        return object.perform(NSSelectorFromString("accessibilityCustomActions"))?.takeUnretainedValue()
            as? [NSAccessibilityCustomAction] ?? []
    }

    /// What VoiceOver reads of the element with this identifier: its label and its value. By the selectors, as
    /// `customActions`: SwiftUI's elements answer them, and a cast to the protocol finds none.
    @MainActor private static func reads(_ identifier: String, in window: NSWindow) -> (label: String?, value: String?) {
        guard let object = element(identifier, in: window) else { return (nil, nil) }
        func read(_ name: String) -> String? {
            guard object.responds(to: NSSelectorFromString(name)) else { return nil }
            return object.perform(NSSelectorFromString(name))?.takeUnretainedValue() as? String
        }
        return (read("accessibilityLabel"), read("accessibilityValue"))
    }

    /// **The badge of the held answer** (`AnswerBadge`): its frame in the window's points, by the accessibility tree,
    /// and the middle of its Undo, 26 points in from its trailing edge (12 of the capsule's room and half of the word):
    /// a click on the badge's own frame, not on words that the text reader finds in a line with a mark (`ViewHost`).
    @MainActor private static func badge(in window: NSWindow) -> (frame: NSRect, undo: NSPoint)? {
        guard let object = element("answer-badge", in: window),
              object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let screen = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return nil }
        let frame = window.convertFromScreen(screen)
        guard frame.width > 0 else { return nil }
        return (frame, NSPoint(x: frame.maxX - 26, y: frame.midY))
    }

    /// **The point where a click reaches this option now**: the middle of its words where the window draws them
    /// (`ViewHost.middle`), inside the option's own frame by the accessibility tree, while the option is enabled; else
    /// nil, and what is missing, for the failure's words. In a motion of the page the drawing and the frame that takes
    /// the click are not at the same place, so a test that clicks where it reads waits for the two to agree; the same
    /// words drawn elsewhere (a badge, a line of a request that was not sent) are not the option's.
    @MainActor private static func reachable(_ words: String, option identifier: String, in window: NSWindow) -> Reach {
        guard let object = element(identifier, in: window) else { return Reach(why: "no element \(identifier)") }
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let screen = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
            return Reach(why: "no frame of \(identifier)")
        }
        let enabled = object.responds(to: NSSelectorFromString("isAccessibilityEnabled"))
            ? (object.value(forKey: "accessibilityEnabled") as? Bool ?? true) : true
        let frame = window.convertFromScreen(screen)
        guard enabled else { return Reach(frame: frame, why: "\(identifier) not enabled") }
        guard let point = try? ViewHost.middle(of: words, in: window, seconds: 0) else {
            return Reach(frame: frame, why: "\(words) not drawn; its frame \(frame)")
        }
        guard frame.insetBy(dx: -2, dy: -2).contains(point) else {
            return Reach(frame: frame, why: "\(words) drawn at \(point), its frame \(frame)")
        }
        return Reach(point: point, frame: frame, why: "\(point) in its frame \(frame)")
    }

    /// What `reachable` read: the point of a click, or what is missing.
    struct Reach {
        var point: NSPoint?
        var frame: NSRect?
        var why: String
        /// The same point and frame as `other`: the page stands still under the option.
        func settled(after other: Reach) -> Bool {
            guard let point, let frame, let before = other.point, let then = other.frame else { return false }
            return abs(point.x - before.x) < 1 && abs(point.y - before.y) < 1 && frame.equalTo(then)
        }
    }

    /// **Each place where the window draws these words**, by the Mac's text recognition, as `ViewHost.middle` finds the
    /// first: a test that says that words stand only in one place reads them all.
    @MainActor private static func everywhere(_ words: String, in window: NSWindow) throws -> [NSPoint] {
        guard let view = window.contentView else { return [] }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: picture)
        guard let image = picture.cgImage else { return [] }
        let reading = VNRecognizeTextRequest()
        reading.recognitionLevel = .accurate
        reading.recognitionLanguages = ["en-US"]
        reading.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([reading])
        return (reading.results ?? []).compactMap { line in
            guard let text = line.topCandidates(1).first,
                  let range = text.string.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]),
                  let box = try? text.boundingBox(for: range)?.boundingBox else { return nil }
            return NSPoint(x: box.midX * view.bounds.width, y: box.midY * view.bounds.height)
        }
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
