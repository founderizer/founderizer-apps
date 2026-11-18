import AppKit
import FleetCore
import FleetOwnerAPI
import Observation
import os

/// **A page of the first run that the owner's own agent asked to see** (`setup_show`, `FleetStore.setupAsk`): the
/// window's wizard takes it, checks it again (`SetupShow.refusal`) and writes its outcome.
struct SetupAsk: Equatable {
    enum Outcome: Equatable {
        case shown
        case refused(String)
    }

    let id = UUID()
    let page: FirstRunPage
    /// The page that the agent saw when it asked.
    let seen: String
    var outcome: Outcome?
}

/// **The app comes to the front by itself, once** (the owner's "Yes" of 14 November 2026 to "May the app come to the
/// front by itself when your own agent needs you there?"): its window, then the present way to ask macOS for the front.
/// The system may keep another app in front; when this app is still not active a moment later, the Dock's own sign asks
/// for the owner's attention, and nothing of ours shows. One function for the welcome page's notification and for
/// `setup_show`, so that a check on a real window changes how it asks in one place. **It is the second way**: on a test
/// Mac (round 2, R2) the app's own activate left Terminal in front 5 times of 5, so the program asks macOS too, with
/// `/usr/bin/open` on its bundle (`AppLink.front`), after each `setup_show` that the app took and after `guide`.
///
/// **After such a front the app takes no key press until the owner's first click in it** (`OutsideFront` in FleetCore,
/// which says when and why): the owner may be typing in another window at that moment, and the next keys of that
/// typing must not land in a field, on a default button or on a page that takes plain keys. A field that has the
/// cursor keeps it (to take it away would end an edit, and some fields save then); a field of a page that opens during
/// the hold does not take it (`SetupField`). `watch` starts the app's own watch of its clicks and keys, once, when the
/// app's store is made. **Three things count as a front from outside:** `come` (a `setup_show`, and the guide's sign in
/// a state that changes the page), every sign of the guide, whose program asks macOS for the front in each state, and
/// a start of the app by its own program (`AppLink.fromOutside`, a word of the start's arguments).
///
/// **After a `setup_show` that changed the page of the fleet's own pages** the hold comes for every owner, also for
/// one who works in the app, and the owner's first click only ends it: the app drops that click, so that it reaches
/// no control of the page that came. Each watch of the app's keys of another file asks `holdsKeys` first.
@MainActor
enum AppFront {
    private static var keys = OutsideFront()
    private static var watches = false
    /// The key presses that the hold dropped since it began: a count for the log, and nothing of a key.
    private static var dropped = 0
    /// The log says when a hold begins and ends, so that "typing does nothing" can be read afterwards: fixed words
    /// and counts, never a key.
    private static let log = Logger(subsystem: "com.founderizer.app", category: "front")

    /// The taker of the guide's sign: an object, because only that form of the observer can ask for a sign at once.
    private final class SignWatch: NSObject {
        @objc func came(_ notification: Notification) {
            // A distributed notification comes on the main thread.
            MainActor.assumeIsolated { AppFront.came("sign") }
        }
    }
    private static let sign = SignWatch()

    /// A front from outside, by one of its three ways. `pageChanged`: it changed the page that the window shows (a
    /// `setup_show` for a place of the fleet's own pages), so the hold comes for an owner who works in the app too.
    private static func came(_ way: String, pageChanged: Bool = false) {
        let inFront = NSApp.isActive, held = keys.holdsKeys
        // A change of page always holds the next click (`OutsideFront`); no page changes while a button is down.
        keys.came(appInFront: inFront, pageChanged: pageChanged)
        if keys.holdsKeys && !held { dropped = 0 }
        log.info("front from outside (\(way, privacy: .public)): in front \(inFront), keys held \(keys.holdsKeys)")
    }

    /// The hold ended, by a click or by the app's leaving the front.
    private static func freed(_ why: String, held: Bool) {
        if held { log.info("keys free (\(why, privacy: .public)) after \(dropped) dropped") }
    }

    /// The app takes no key press now. A page's own watch of plain keys asks this first (`PageKeys`), because two
    /// watches of the app's keys have no fixed order.
    static var holdsKeys: Bool { keys.holdsKeys }

    /// **The app handled a click or a key of the owner in its main window**: told on a later turn of the main queue
    /// than the mouse-up or the key press, so the page is the one that the event left (the store's
    /// `ownerHandled`). The act says whether it is a click, whether it reached the app's controls (false for the
    /// mouse-up of a click that the app dropped) and the number of the latest change of page by a show when it
    /// began: `ShownPage.handled` has the rule, and does nothing with a click that the app dropped or with an event
    /// that began before the latest show. A click that counts frees the next `setup_show`; a click or a key that
    /// counts marks the chat that a `setup_show` opened as read, when it still shows: a click on a control acts at
    /// its mouse-up, so the click that leaves the chat does not mark it. A click in another window of the app
    /// (Report a problem, a card) is not told. **A click
    /// whose mouse-up a control of AppKit takes in its own tracking loop (a text field, a switch, a slider) is not
    /// told**: the app's watch does not see that mouse-up (`NSEvent.addLocalMonitorForEvents`' own limit). The chat
    /// then stays not read until the next key or click that the watch sees, and the next change of page stays held
    /// until the next click that the watch sees to its end, which is the safe side. Set once, when the app's store
    /// is made.
    static var ownerHandled: (@MainActor (ShownPage.Act) -> Void)?
    /// The number of the latest change of page by a show, as the store has it (`ShownPage.change`): the watch notes
    /// it when an event of the owner begins. Set once, when the app's store is made.
    static var pageChange: (@MainActor () -> Int)?
    /// That number at the last mouse-down: its mouse-up is told with it.
    private static var clickBegan = 0

    /// The event is of the app's main window, the window of the fleet's pages (`SetupChannel.fleetWindow`).
    private static func inMainWindow(_ event: NSEvent) -> Bool {
        event.window?.identifier?.rawValue == SetupChannel.fleetWindow
    }

    /// After the event that the watch now passes on: one turn of the main queue for the app to handle it, and one
    /// more for what that handling put on the queue itself.
    private static func tellHandled(_ act: ShownPage.Act) {
        Task { @MainActor in
            await Task.yield()
            ownerHandled?(act)
        }
    }

    /// **Whether a mouse-down reaches the app's controls: the one answer for every watch of the app's mouse-downs.**
    /// The first click after a page that changed from outside reaches none (`OutsideFront.holdsClick`): it only ends
    /// the hold. AppKit gives the app's watches no fixed order, so each of them asks here before it acts on a
    /// mouse-down (this file's own watch, and `FleetContextMenus`, which opens the app's menu on a right click), and
    /// each gets the same answer for the same event: the rule keeps the event's number and time, so the second ask
    /// counts no second click (`OutsideFront.click`). A watch that gets false does nothing with the event and passes
    /// it on; this file's own watch drops it. For a dropped click the app asks AppKit to make the clicked window its
    /// key window and to put it in front, and asks for the front itself when it is not the active app: a click on a
    /// window does both, and the code alone does not say what macOS does when the click is dropped.
    static func reaches(_ event: NSEvent) -> Bool {
        let id = OutsideFront.Event(number: event.eventNumber, time: event.timestamp, count: event.clickCount)
        // Another watch asked for this event already: the same answer, and nothing is done a second time.
        guard !keys.answered(id) else { return keys.click(appInFront: NSApp.isActive, event: id) }
        clickBegan = pageChange?() ?? 0                     // the click begins: its mouse-up is told with this number
        let held = keys.holdsKeys
        let reaches = keys.click(appInFront: NSApp.isActive, event: id)
        freed(reaches ? "click" : "click, which the app dropped", held: held)
        if !reaches, let window = event.window, window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            if !NSApp.isActive { NSApp.activate() }
        }
        return reaches
    }

    /// `pageChanged`: the page of the window changed just before, from outside (`SetupChannel.showPlace`).
    static func come(pageChanged: Bool = false, open: () -> Void) {
        came(pageChanged ? "show of a place" : "show", pageChanged: pageChanged)
        open()
        NSApp.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    /// The watch of the app's own clicks and keys, and of its leaving the front. The handlers run on the main thread.
    static func watch() {
        guard !watches else { return }
        watches = true
        // **The first click after a page that changed from outside reaches no control** (`reaches`): the app drops
        // its mouse-down here, and its drags and its mouse-up in the watch below.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { reaches(event) } ? event : nil
        }
        // A mouse-up ends a click. The store is told of it, with whether that click reached the app: the mouse-up of
        // a dropped click is dropped too, and it is no act of the owner.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged,
                                                    .rightMouseDragged, .otherMouseDragged]) { event in
            let reaches = MainActor.assumeIsolated { () -> Bool in
                let up = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
                let reaches = keys.pointer(up: up)
                if up, inMainWindow(event) { tellHandled(.init(isClick: true, reached: reaches, began: clickBegan)) }
                return reaches
            }
            return reaches ? event : nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let takes = MainActor.assumeIsolated { () -> Bool in
                if !keys.takesKeys {
                    dropped += 1
                } else if inMainWindow(event) {
                    // The key begins here: the number of now goes with it. A key frees no change of page.
                    tellHandled(.init(isClick: false, reached: true, began: pageChange?() ?? 0))
                }
                return keys.takesKeys
            }
            return takes ? event : nil
        }
        // The guide's program asks macOS for the front after its sign, in each state of the app (`OwnerCLI`): so each
        // sign counts, also one that changes no page. **It is taken at once, also while the app is not in front**
        // (`deliverImmediately`): macOS keeps a sign for an app that is not in front until that app comes forward,
        // and a sign that macOS kept would begin a hold at the owner's own next coming, hours later.
        DistributedNotificationCenter.default().addObserver(
            sign, selector: #selector(SignWatch.came(_:)), name: Notification.Name(OwnerGuide.started), object: nil,
            suspensionBehavior: .deliverImmediately)
        // The app's own program started this app (`AppLink.fromOutside`): it came to the front from outside. Read from
        // the start's arguments only, never from a kept setting.
        if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[AppLink.fromOutside] != nil {
            keys.came(appInFront: false)
            log.info("front from outside (start): keys held true")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                let held = keys.holdsKeys
                keys.leftFront()
                freed("left the front", held: held)
            }
        }
    }
}

/// **The app's side of the link with its program** (`OwnerChannel` in FleetOwnerAPI; the plan's section 3.4): a local
/// socket in the app's own folder of the user's Library, on which the program inside this bundle (`founderizer-cli`)
/// asks the running app its reads (`setup_state`, `setup_show`, `setup_diagnosis`) and its six writes
/// (`save_bot_token`, `prepare_problem_report`, `save_secret`, `grant_secret`, `share_secret`,
/// `answer_secret_request`; `LinkTools`), and one write more of a tool of the table: a door card's signed press of
/// `answer_needs_you`. The
/// listener runs on a queue of its own; the answers come on the
/// main actor, from the store (`SetupBoard`). Nothing of it shows on the screen.
///
/// **Who it answers.** Only the program checked by its code signature (`SignatureCheck.of`): in a release build a
/// Developer ID program of this app's own team with the identifier `com.founderizer.cli`; in a test build only the exact
/// program of this own bundle. That proves which program calls, not who wanted the call: each process of the owner's
/// user can start the program. So the safety of the link is in what its tools can do: they read typed facts, and
/// `setup_show` asks macOS to bring one of this app's own pages to the front; none presses, rents or pays. Two carry a
/// secret (`LinkTools`). `save_bot_token` sends a Discord bot's token to the hub's route that any process of the
/// owner's user reaches already. `save_secret` adds a new entry to the hub's list of secrets and passes its value,
/// sealed to the central vault's key, on to the vault: through the hub's routes that any process of the owner's
/// user reaches already, so it gives such a process no new power; it gives the secret to no agent, replaces nothing
/// and sets no site itself. Proved with the released, Developer ID signed build (14 November 2026), before
/// `save_secret` was on the link; `save_secret` ran in the released build 0.1.275 on a test fleet (16 November 2026).
///
/// **Four tools sign, and that is a new power.** `grant_secret` makes this app sign the owner's grant of a secret of
/// the list to a worker or a lead, or its end, with the owner key of this Mac and with no question to the owner (the
/// owner, 15 November 2026: "No touch"). So each process of the owner's user can bring a secret's value to an
/// agent's server, and with `read` an API key into that agent's sessions. `share_secret` makes this app sign a secret
/// of the list into the grantable pool, or out of it, in the same way, and the hub then lets the fleet manager give
/// it to any worker or lead, at most at the level that the call names. `answer_secret_request` makes this app sign
/// the gives of one call as `grant_secret` does, and to the door for a request for the door, and then answer an
/// agent's open request for a secret with a secret of the list that fits it. A door card's press of
/// `answer_needs_you` (17 November 2026) makes this app sign the owner's yes to the card's door call, or Full access on
/// the server of the door's card of a run, by the rule of the owner's own press, and send it. `OWNER-MCP-BOUNDARY.md`,
/// section 7b, has the
/// powers, their traces and their limits. `grant_secret` ran in the released build 0.1.275 on a test fleet (16
/// November 2026): the signed give, the value on a worker's server, and the signed end. `share_secret` ran in the released
/// build 0.1.293 on a test fleet (16 November 2026): the signed pool statement, the delivery through the pool, and
/// the take-back with the copy taken back. `answer_secret_request` ran in the released build 0.1.300 on a test fleet
/// (17 November 2026): the signed give with the answer, the key's copy on a worker's server, and the refusals.
@MainActor
final class SetupChannel {
    static let shared = SetupChannel()
    /// The outcome of an ask when the wizard's window goes before it took the ask.
    static let windowWent = "The first run's window closed before it took the page. Call setup_state again."

    private static let log = Logger(subsystem: "com.founderizer.app", category: "link")
    private var listener: ChannelListener?
    private weak var store: FleetStore?
    private lazy var board: SetupBoard = {
        let board = SetupBoard(read: { [unowned self] in facts() },
                               show: { [unowned self] page, seen in await show(page, seen: seen) },
                               diagnose: { [unowned self] in
                                   store.map { Self.diagnosis(of: $0, kept: kept(for: $0)) } ?? .unknown
                               },
                               network: { [unowned self] in await network() },
                               ages: { [unowned self] in
                                   store?.lastSuccess.map { max(0, Int(Date().timeIntervalSince($0))) }
                               },
                               workAges: { [unowned self] in
                                   store.map { store in
                                       let kept = kept(for: store)
                                       return Self.workSeconds(of: store, last: kept?.last,
                                                               unjoined: kept?.unjoinedNewest)
                                   } ?? .none
                               },
                               // The bundle's Info.plist on the disk now: an update swaps the bundle at its path.
                               diskBuild: { ProgramPlace.build(of: Bundle.main.bundleURL) })
        // The link's write tools (`save_bot_token`, `prepare_problem_report`, `save_secret`, `grant_secret`,
        // `share_secret`, `answer_secret_request`) and a door card's press of `answer_needs_you`, on the same board and
        // the same store.
        LinkTools.add(to: board, store: { [weak self] in self?.store })
        return board
    }()

    /// **The listener, with one call at the app's start** (beside `ProgramLink`): off the main thread, because it makes
    /// the folder, reads the place and the program's code. A second copy of the app does not take the place of the
    /// first while the first lives; a place that is too long, or a folder that is not this user's, is one line of the
    /// app's log and nothing on the screen. **A copy that starts while an older run of this same app still listens
    /// takes the link when that one ends** (`startWhenFree`): the app's own restart for an update starts the new copy
    /// before the old one is gone, and without this the new copy had no link until the owner opened the app again. A
    /// copy of the app at ANOTHER place (a second download, a test build) does not wait: it would take the link of
    /// the first one's program, which starts its own app and gets its own listener when nothing listens, as before.
    static func listen() {
        let program = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/founderizer-cli")
        let path = OwnerChannel.place(home: OwnerChannel.userHome())
        DispatchQueue.global(qos: .utility).async {
            let check: PeerCheck = SignatureCheck.of(identifier: OwnerChannel.programIdentifier, expected: program)
                ?? RefuseEveryPeer()
            let listener = ChannelListener(path: path, check: check) { request, value in
                await SetupChannel.shared.answer(request, value: value)
            }
            var started = listener.start()
            if started == .anotherListens {
                if sameAppRuns() {
                    log.info("An older run of this app listens on the link: this one takes the link when that one ends.")
                    started = listener.startWhenFree()
                } else {
                    // The other one may have ended between the two looks: one more try, and no wait.
                    started = listener.start()
                }
            }
            let result = started
            Task { @MainActor in
                switch result {
                case .listening:
                    shared.listener = listener
                    log.info("The link listens.")
                case .anotherListens:
                    log.info("A copy of the app at another place listens on the link: this one does not.")
                case .cannot(let words): log.error("\(words, privacy: .public)")
                }
            }
        }
    }

    /// **Whether another process runs this same app from this same place**: the old run at the app's own restart for
    /// an update, which replaced the bundle where it stands. A copy of the app at another place is not that.
    nonisolated private static func sameAppRuns() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let here = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains {
            $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == here
        }
    }

    /// The store that the answers come from: the app's own, at its start.
    func attach(_ store: FleetStore) {
        self.store = store
        AppFront.ownerHandled = { [weak store] act in store?.ownerHandled(act) }
        AppFront.pageChange = { [weak store] in store?.shown.change ?? 0 }
        AppFront.watch()
        readRecords()
        watch()
        watchWindows()
        board.refresh()
    }

    /// **The tries of a request that comes before the store**: 100, a tenth of a second apart, then a refusal in
    /// words. The store is made at the app's start, so a request waits for it only while the app starts (round 2, S6).
    static let storeTries = 100

    func answer(_ request: OwnerChannel.Request, value: OwnerChannel.Value?) async -> OwnerChannel.Answer {
        var tries = Self.storeTries
        while store == nil && tries > 0 && !Task.isCancelled {
            tries -= 1
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard store != nil else { return .refused("The Founderizer app is starting. Call the tool again.") }
        // The one read of the kept records' folders, which began with the store: no answer is made before its end, so
        // none says "no record" of records that were only not read yet.
        await recordsRead?.value
        return await board.answer(request, value: value)
    }

    // ------------------------------------------------------------ the kept records

    /// **What the app's kept records say, for `setup_diagnosis`** (`InstallRecords.shared`, `BuildRecords.shared`: the
    /// app's own two folders, which `KeptRecords` reads one time and then gives from memory): the last install of the
    /// fleet that the app shows (`ReachFacts.lastRecord`) and the count of the servers that never joined
    /// (`ReachFacts.unjoined`). **Kept until a record changes or the hub's address does**: each read of the diagnosis
    /// asks the two counters of change and the hub's address, which open no file and sort nothing, and reads the
    /// records again only when one of the three moved.
    private struct Kept {
        var installs: Int
        var builds: Int
        var hub: String?
        var last: ReachFacts.LastInstall?
        var unjoined: ReachFacts.UnjoinedBuilds
        /// For the age of the newest of them only (`builds.newest_seconds_ago`).
        var unjoinedNewest: Date?
    }
    private var keptFacts: Kept?
    /// **The one read of the two folders, off the main thread** (`KeptRecords.load`, as that type asks of a caller that
    /// wants it there): it begins when the store comes, and each request of the link waits for its end.
    private var recordsRead: Task<Void, Never>?
    private var recordsAreRead = false

    private func readRecords() {
        guard recordsRead == nil else { return }
        // **A change of a record reads the diagnosis again.** The records are no observed values, so `watch()` cannot
        // see them: each write that changed one posts its own notification (`KeptRecords.write`), and that is what
        // moves the diagnosis's number for `last_install` and `builds`.
        for name in [InstallRecords.changed, BuildRecords.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.board.refresh() }
            }
        }
        recordsRead = Task.detached(priority: .userInitiated) { [weak self] in
            InstallRecords.shared.load()
            BuildRecords.shared.load()
            await MainActor.run {
                self?.recordsAreRead = true
                self?.board.refresh()
            }
        }
    }

    /// The records' facts for this store's hub, or nil until the folders were read. The hub's address is read from
    /// the store, so the diagnosis's observation watches it.
    private func kept(for store: FleetStore) -> Kept? {
        guard recordsAreRead else { return nil }
        let hub = store.hubIsUnset ? nil : store.hub.absoluteString
        let installs = InstallRecords.shared.changes, builds = BuildRecords.shared.changes
        if let keptFacts, keptFacts.installs == installs, keptFacts.builds == builds, keptFacts.hub == hub {
            return keptFacts
        }
        // The counters were read first: a write between them and the records leaves a newer reading under an older
        // count, and the next call reads again.
        let builtRecords = BuildRecords.shared.all()
        let now = Kept(installs: installs, builds: builds, hub: hub,
                       last: ReachFacts.lastRecord(in: InstallRecords.shared.all(), hub: hub)
                           .map(ReachFacts.lastInstall),
                       unjoined: ReachFacts.unjoined(builtRecords),
                       unjoinedNewest: ReachFacts.newestUnjoined(builtRecords))
        keptFacts = now
        return now
    }

    /// **Every change of a fact moves its change number**: the store's values that the facts and the diagnosis read are
    /// watched, and each change reads both again (`SetupBoard.refresh`), which ends the waits of the one that changed.
    /// `lastReadError` is not observed, so `clock` is: it is written once at the end of each read of the hub, so the
    /// kind of a failure is read again within one read (the plan, decision 4). The diagnosis's own builder runs inside
    /// the tracking, so each value that it reads is watched (version 2, point 5): the two builds, and the install
    /// model's plain facts (`linkFacts`), whose changes come through tasks of their own and no `didSet` could catch.
    /// The kept records are the one thing that the tracking cannot see: their own notification reads the diagnosis
    /// again (`readRecords`).
    private func watch() {
        withObservationTracking {
            _ = (store?.setupSnapshot, store?.hubIsUnset, store?.state != nil, store?.firstReadEnded, store?.readsFail,
                 store?.clock)
            _ = store.map { Self.diagnosis(of: $0, kept: kept(for: $0)) }
            // The place reads the destination, the wizards' pages, the first run and the reading: each is watched.
            _ = store.map { Self.place(of: $0) }
            _ = store.map(Self.places(of:))
            // `show` reads the store too: a setup that fills the window, a request that waits, and a show that
            // changed the page with no act of the owner since.
            _ = store.map { Self.showFacts(of: $0, over: .nothing) }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.board.refresh()
                self?.watch()
            }
        }
    }

    /// **The programs of the owner's own agent on this Mac**, read again only when the first run's page changes and
    /// once `programsEvery` went by: a read is a few file checks on the main thread, and the facts are read at each
    /// request of the link and at each end of a read of the hub (round 2, S2). By time, not by a count of reads, since
    /// `watch()` reads the facts every 3 seconds.
    private var programs: [String]?
    private var programsPage: FirstRunPage??
    private var programsAt: TimeInterval = 0
    static let programsEvery: TimeInterval = 30

    private func programsNow(page: FirstRunPage?) -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
        if let programs, programsPage == .some(page), now - programsAt < Self.programsEvery { return programs }
        let found = AgentPrograms.found().compactMap { SetupFacts.programNames[$0.rawValue] }.sorted()
        programs = found
        programsPage = .some(page)
        programsAt = now
        return found
    }

    /// The hub as `setup_state` gives it.
    private static func hub(of store: FleetStore) -> SetupFacts.Hub {
        store.hubIsUnset ? .none : store.state != nil && store.firstReadEnded && !store.readsFail ? .answers : .set
    }

    /// **The diagnosis now**, from the store's stored values only: no request, no subprocess. Where the window stands
    /// comes from the same values that `FleetView` draws from, so it holds when the window is closed too: the first run
    /// while it would show, then Add server, Add agent, or an agent's own setup in place of its chat or its settings.
    /// **The welcome page in front of a setup that never finished is the first run's page** (`store.welcomeCovers`,
    /// as `place` reads it): while the window is closed no page of the first run says that it shows, and without
    /// this value the answer named the manager's setup, which is the page behind the one that the window opens on.
    /// `kept`: what the app's kept records say, or nil until they were read.
    private static func diagnosis(of store: FleetStore, kept: Kept?) -> SetupDiagnosis {
        let hub = hub(of: store)
        let firstRun = store.setupSnapshot.shows || store.firstRunHolds
            || (store.state == nil && !store.hubAnsweredBefore)
        let page: ReachFacts.Page
        switch store.destination {
        case .addServer: page = .addServer
        case .addAgent: page = .addAgent
        case .agent(let name), .agentDetail(let name, .chat), .agentDetail(let name, .settings):
            if store.setupShows(name), let agent = store.state?.agents.first(where: { $0.name == name }) {
                page = .agentSetup(ReachFacts.AgentSetup(manager: agent.role == "manager", placed: agent.placed,
                                                         serverJoined: store.joinedServer(name) != nil))
            } else {
                page = .other
            }
        default: page = .other
        }
        let place = ReachFacts.window(firstRun: firstRun, settings: store.destination.settingsTab != nil,
                                      hasReading: store.state != nil, page: page, welcomeCovers: store.welcomeCovers)
        let install = ReachFacts.install(store.installModel().linkFacts).map(Self.wire)
        return SetupDiagnosis(
            hub: hub,
            failure: hub == .none ? ReachFacts.ReadKind.none.rawValue : ReachFacts.readKind(store.lastReadError).rawValue,
            readEnded: store.firstReadEnded, answeredThisLaunch: store.lastSuccess != nil,
            answeredBefore: store.hubAnsweredBefore, hasReading: store.state != nil, window: place.window.rawValue,
            agentSetup: place.agentSetup.map { SetupDiagnosis.AgentSetup(manager: $0.manager, placed: $0.placed,
                                                                           serverJoined: $0.serverJoined) },
            firstRunBuild: store.firstRunBuild.map(Self.wire), addServerBuild: store.addServerBuild.map(Self.wire),
            install: install,
            // Only while the model holds no install (`SetupDiagnosis.lastInstall`): else a record's change that no
            // answer shows would move the number.
            lastInstall: install == nil ? kept?.last.map(Self.wire) : nil,
            builds: kept.map { SetupUnjoinedBuilds(server: $0.unjoined.server, leftBehind: $0.unjoined.leftBehind,
                                                   notKnown: $0.unjoined.notKnown) } ?? .none,
            appBuild: appBuild(of: store.updates))
    }

    /// **The app's own build and the channel's offer** (`app_build`), from `AppAutoUpdate`'s stored values: the build
    /// that installs itself, the one that the channel's last read offered, or the one that waited when the app last
    /// quit; and the press of the window of the sidebar's Update while it downloads, checks or installs
    /// (`AppAutoUpdate.pressInstall`).
    private static func appBuild(of updates: AppAutoUpdate) -> SetupAppBuild {
        let offered = updates.waiting?.build
            ?? (updates.known?.offered == true ? updates.known?.manifest?.build : nil)
            ?? updates.keptWaiting.reading?.build
        return SetupAppBuild(running: AppVersion.running?.build, offered: offered, installing: updates.pressed != nil)
    }

    // ------------------------------------------------------------ what stands over the page

    /// The scene of the fleet's pages (`FounderizerApp`'s `Window("Founderizer", id: "fleet")`): SwiftUI gives the
    /// scene's id to its window as the window's identifier.
    static let fleetWindow = "fleet"
    private static let overLog = Logger(subsystem: "com.founderizer.app", category: "over")
    private var overLogged: String?
    private var watchesWindows = false

    /// **What the app has open over the page or beside it** (`setup_state`'s `over`), from AppKit's own list of this
    /// app's windows that are on the screen: a card of the app (`fleetModal`, a panel on the window), its menus
    /// (`FleetMenuPanel`), a sheet, a popover and a panel of macOS hang on a window or are panels; a menu of AppKit
    /// cannot be the main window; Report a problem is a window of its own. No view tells it, so a card that a later
    /// version adds counts with no line here. A window whose identifier is not the fleet's counts as another window:
    /// when SwiftUI names the fleet's window another way, the answer is `window` and an agent does not look, which
    /// is the safe side. The one window that counts as nothing is the title bar of full screen (`AppOver.barClass`).
    static func over() -> (AppOver, kinds: String) {
        let shown = NSApp.windows.filter(\.isVisible)
        let facts = shown.map { window in
            AppOver.Shown(isFleet: window.identifier?.rawValue == fleetWindow,
                          hangs: window.parent != nil || window.sheetParent != nil || window is NSPanel,
                          standsAlone: window.canBecomeMain,
                          isBar: String(describing: type(of: window)) == AppOver.barClass)
        }
        // For the log only: each window's class and what counted, never a title or a text of a window.
        let kinds = zip(shown, facts).map { window, fact in
            "\(type(of: window))" + (fact.isFleet ? " fleet" : "") + (fact.hangs ? " hangs" : "")
                + (fact.standsAlone ? " alone" : "") + (fact.isBar ? " bar" : "")
        }.sorted().joined(separator: ", ")
        return (AppOver.of(facts, modal: NSApp.modalWindow != nil), kinds)
    }

    /// `over` for the facts, with one log line at each change of the windows that count: fixed words and class names.
    private func overNow() -> AppOver {
        let (over, kinds) = Self.over()
        let line = "\(over.rawValue): \(kinds)"
        if line != overLogged {
            overLogged = line
            Self.overLog.info("over \(line, privacy: .public)")
        }
        return over
    }

    /// **A window that comes or goes reads the facts again**, so that a wait of `setup_state` ends when a card opens
    /// or closes. AppKit says no "a window shows now" for every way, so this takes the changes of the key and the main
    /// window and each close. What takes no key passes it: a menu of the app or of the menu bar, a hover's words, and
    /// a card that opens while another app is in front. That costs only the wait: each call of `setup_state` reads the
    /// windows itself before it answers, and a wait that ends by time reads them once more (`SetupBoard.state`).
    /// **The app's coming to the front and its leaving read them too**, for `in_front` (`inFront`).
    private func watchWindows() {
        guard !watchesWindows else { return }
        watchesWindows = true
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A close is told before the window goes: read on the next turn of the main queue.
                Task { @MainActor in self?.board.refresh() }
            }
        }
    }

    // ------------------------------------------------------------ the place of the window

    /// **The place that the window shows now** (`setup_state`'s `place`), from the same values that `FleetView` draws
    /// from, so it holds when the window is closed too: where it would open. `showing`: another destination than the
    /// store's, for the place that the window would show with it (`setup_show`'s last check before it changes the page).
    static func place(of store: FleetStore, showing destination: Destination? = nil) -> AppPlace {
        let destination = destination ?? store.destination
        let snapshot = store.setupSnapshot
        let window = WindowFacts(launched: store.launched, hasReading: store.state != nil,
                                 answeredBefore: store.hubAnsweredBefore, firstRunHolds: store.firstRunHolds,
                                 welcomeCovers: store.welcomeCovers, settings: destination.settingsTab != nil,
                                 firstRunPage: snapshot.shows ? snapshot.page : nil)
        return AppPlace.shows(window, destination: destinationPlace(of: store, destination))
    }

    /// **What a destination draws when nothing covers it**: a switch with no default, so that a new destination
    /// does not build until it has a name. An agent's own page is its setup, "Setting up" or its chat, as `FleetView`
    /// decides (`setupAgent`, `startingAgent`); its Runs on is its setup too while the setup shows (`AgentPage.part`).
    private static func destinationPlace(of store: FleetStore, _ destination: Destination) -> AppPlace {
        let pages = store.wizardPages
        let features = store.state?.ui_features ?? []
        // **A place of Settings whose section this hub does not offer draws General** (`SettingsPage.body`): a
        // section, and also a server's page, Add server inside Settings, the key's page and an app's page. Add server
        // and Add agent with a reading fill the window and are no page of Settings then (`fillsWindow`).
        if let tab = destination.settingsTab, !store.fillsWindow(destination),
           !SettingsTab.available(features: features).contains(tab) {
            return .settings(.general)
        }
        // An agent's setup: its page, and on its server page the page of the Add server that it draws inside it.
        func setup(_ name: String) -> AppPlace {
            let page = pages.setup(of: name)
            if page == .server, let inner = pages.addServer { return .agentSetupServer(name, inner) }
            return .agentSetup(name, page)
        }
        switch destination {
        case .needs: return .needs
        case .activity: return .tasks
        case .agents: return .agents
        case .addAgent: return .addAgent(pages.addAgent)
        case .server(let name): return .server(name)
        case .addServer: return .addServer(pages.addServer)
        // A task that the hub no longer has draws "Task not found": the kind alone (`FleetStore.currentTask`).
        case .task(let number):
            return store.state?.tasks.contains { $0.id == number } == true ? .task(number) : .someTask
        case .agent(let name):
            if store.setupShows(name) { return setup(name) }
            guard let state = store.state else { return .agent(name) }
            let starts = (store.isAdding(name) && !store.isFresh)
                || AgentSetupFlow.chatStarts(state.agents.first { $0.name == name }, serverTime: state.time,
                                             fresh: store.isFresh)
            return starts ? .agentSettingUp(name) : .agent(name)
        case .agentDetail(let name, let tab):
            switch tab {
            case .chat, .settings:
                return store.setupShows(name) ? setup(name) : .agentPart(name, .runsOn)
            case .behaviour: return .agentPart(name, .behaviour)
            case .tasks: return .agentPart(name, .tasks)
            case .people: return .agentPart(name, .people)
            case .canUse: return .agentPart(name, .canUse)
            case .capabilities: return .agentPart(name, .capabilities)
            }
        case .signIn(let name): return .agentSignIn(name, pages.signIn(of: name))
        case .agentRule(let name, _): return .agentRule(name)
        case .settings(let tab): return .settings(settingsPage(tab))
        case .app(let group): return .app(appGroup(group))
        case .connectKey: return .connectKey
        // The slider's step is the owner's choice and no page: the wizard's own pages have no name yet.
        case .shapeChange: return .shapeChange
        // One thing of an agent's work, from its chat panel (`WorkItemPage`), is a page of the agent's work: the name of
        // its Tasks, which lists the same work task by task. A name of its own waits for a lane of the owner's places.
        case .work(let name, _): return .agentPart(name, .tasks)
        }
    }

    /// **The places that the fleet has now** (`setup_state`'s `places`): Settings' sections and the apps by the app's
    /// own rules for the hub's features.
    static func places(of store: FleetStore) -> [AppPlace] {
        let features = store.state?.ui_features ?? []
        return AppPlace.places(hasReading: store.state != nil,
                               settings: SettingsTab.available(features: features).map(settingsPage),
                               apps: AppsGroup.available(features: features).map(appGroup),
                               canAdd: features.contains(Servers.feature))
    }

    // ------------------------------------------------------------ setup_show for the fleet's own pages

    /// **Whether the Founderizer window is in front** (`setup_state`'s `in_front`), from AppKit at each read, as
    /// `over`: the app is the active app, and its main window, the fleet's, is on the screen, on the Space that
    /// shows, not in the Dock, and is AppKit's main window or key window of the app (`AppInFront.of`).
    static func inFront() -> Bool {
        AppInFront.of(active: NSApp.isActive, windows: NSApp.windows.map { window in
            AppInFront.Window(isFleet: window.identifier?.rawValue == fleetWindow, onScreen: window.isVisible,
                              onActiveSpace: window.isOnActiveSpace, miniaturized: window.isMiniaturized,
                              mainOrKey: window.isMainWindow || window.isKeyWindow)
        })
    }

    /// **The facts that `setup_show`'s rules read, from the store's own state** (`SetupShow.refusal`, `SetupShow.now`):
    /// the second ask of the rules, on the main actor, and `setup_state`'s `show`. `over`: what stands over the page,
    /// read from AppKit by the caller. `target`: the place that was asked for, when the call names one.
    /// **A request that waits** is the hub's list of open requests (`FleetStore.openNeeds`): Needs you draws the one
    /// at hand with its options, its field or its secret's form, and the page changes from Needs you only with none.
    static func showFacts(of store: FleetStore, over: AppOver, target: AppPlace? = nil,
                          buttonDown: Bool? = nil) -> ShowFacts {
        ShowFacts(place: place(of: store), firstRun: store.setupSnapshot, over: over, hasReading: store.state != nil,
                  sections: SettingsTab.available(features: store.state?.ui_features ?? []).map(settingsPage),
                  setupFills: store.fillsWindow(store.destination), firstRunHolds: store.firstRunHolds,
                  openRequest: !store.openNeeds.isEmpty, shown: store.shown.waitsForOwner,
                  target: target.map { targetState($0, in: store) }, buttonDown: buttonDown)
    }

    /// **A page that the app may open by itself as it starts** (the page he left, `FleetStore.keptPage`): a place of
    /// `setup_show`'s list as it would show now, with `setup_show`'s own checks of that place (`targetState`): the hub
    /// lists it, it has the part that was asked for, no setup shows in its place, and the hub offers its section of
    /// Settings.
    static func opensAtStart(_ page: Destination, in store: FleetStore) -> Bool {
        let target = place(of: store, showing: page)
        guard SetupShow.isTarget(target), targetState(target, in: store) == .has else { return false }
        if case .settings(let section) = target {
            return SettingsTab.available(features: store.state?.ui_features ?? []).map(settingsPage).contains(section)
        }
        return true
    }

    /// **What the store says of a place that `setup_show` was asked to open**: an agent that the hub lists, with the
    /// part that was asked for (`AgentTab.available`, the list of the details' own sidebar), and whose own page draws
    /// its chat and not its setup or its "Setting up"; a task that the hub has. Every other place is the rules' own.
    private static func targetState(_ target: AppPlace, in store: FleetStore) -> ShowTarget {
        guard let state = store.state else { return .missing }
        func agent(_ name: String, part: AgentTab?) -> ShowTarget {
            guard let agent = state.agents.first(where: { $0.name == name }) else { return .missing }
            if let part, !AgentTab.available(features: state.ui_features ?? [], role: agent.role).contains(part) {
                return .noPart
            }
            // The agent's own page draws its setup or its "Setting up" (`destinationPlace`), or fills the window.
            let page = Destination.agent(name)
            return destinationPlace(of: store, page) != .agent(name) || store.fillsWindow(page) ? .inSetup : .has
        }
        switch target {
        case .agent(let name): return agent(name, part: nil)
        case .agentPart(let name, let part): return agent(name, part: agentTab(part))
        case .task(let number): return state.tasks.contains { $0.id == number } ? .has : .missing
        default: return .has
        }
    }

    /// The store's page for a place that `setup_show` opens, or nil for a place that is no page of this list.
    private static func destination(for target: AppPlace) -> Destination? {
        switch target {
        case .needs: .needs
        case .tasks: .activity
        case .agents: .agents
        case .task(let number): .task(number)
        case .agent(let name): .agent(name)
        case .agentPart(let name, let part): .agentDetail(name, agentTab(part))
        case .settings(let page): SettingsTab.allCases.first { settingsPage($0) == page }.map { .settings($0) }
        default: nil
        }
    }

    private static func agentTab(_ part: AppPlace.AgentPart) -> AgentTab {
        switch part {
        case .runsOn: .settings
        case .behaviour: .behaviour
        case .tasks: .tasks
        case .people: .people
        case .canUse: .canUse
        case .capabilities: .capabilities
        }
    }

    private static func settingsPage(_ tab: SettingsTab) -> AppPlace.SettingsPage {
        switch tab {
        case .general: .general
        case .servers: .servers
        case .backup: .backup
        case .status: .status
        case .secrets: .secrets
        case .knowledge: .knowledge
        case .apps: .apps
        case .people: .people
        case .team: .team
        case .help: .help
        }
    }

    private static func appGroup(_ group: AppsGroup) -> AppPlace.AppGroup {
        switch group {
        case .github: .github
        case .drive: .drive
        case .gmail: .gmail
        case .mcp: .mcp
        }
    }

    /// A build's facts by the names of the wire: the date stays here.
    private static func wire(_ build: ReachFacts.BuildFacts) -> SetupBuild {
        SetupBuild(stage: build.stage.rawValue, stoppedAt: build.stoppedAt?.rawValue, stopShows: build.stopShows,
                   use: build.use.rawValue, provider: build.provider?.rawValue)
    }

    /// The install's facts by the names of the wire: the date stays here.
    private static func wire(_ install: ReachFacts.InstallFacts) -> SetupInstall {
        SetupInstall(state: install.state.rawValue, kind: install.kind.rawValue, step: install.step.rawValue,
                     stop: install.stop?.rawValue ?? "none", cause: install.cause?.rawValue ?? "none",
                     waitsForNetwork: install.waitsForNetwork,
                     stepsDone: install.stepsDone, stepsPlanned: install.stepsPlanned, tries: install.tries)
    }

    /// The last install's facts by the names of the wire: the date stays here.
    private static func wire(_ last: ReachFacts.LastInstall) -> SetupLastInstall {
        SetupLastInstall(kind: last.kind.rawValue, outcome: last.outcome.rawValue, step: last.step.rawValue,
                         stop: last.stop?.rawValue ?? "none", cause: last.cause?.rawValue ?? "none",
                         waitsForNetwork: last.waitsForNetwork,
                         stepsDone: last.stepsDone, stepsPlanned: last.stepsPlanned, tries: last.tries,
                         retried: last.retried)
    }

    /// **The seconds of the app's own work**, read only when an answer is written, so that they never move a number.
    /// `last`: the last install by the kept records, for the seconds since its record changed.
    private static func workSeconds(of store: FleetStore, last: ReachFacts.LastInstall?,
                                    unjoined: Date?) -> SetupWorkSeconds {
        let now = Date()
        return SetupWorkSeconds(firstRunBuild: ReachFacts.seconds(in: store.firstRunBuild, now: now),
                                addServerBuild: ReachFacts.seconds(in: store.addServerBuild, now: now),
                                install: ReachFacts.seconds(in: ReachFacts.install(store.installModel().linkFacts),
                                                            now: now),
                                lastInstall: ReachFacts.seconds(since: last, now: now),
                                unjoinedBuild: unjoined.flatMap { ReachFacts.seconds(from: $0, to: now) })
    }

    /// **What a page's build model tells the store** (`FleetCloudModel.onState`): the page sets it with one line, the
    /// first run's window view for its model and Add server once for its model that lives while the page is closed.
    /// Each closure keeps its own model's last facts, so that a kept stop is that model's own, and the store's value
    /// follows `ReachFacts.kept`: an idle model does not replace another model's build that runs. The store is
    /// written only when its value changes.
    static func reports(to store: FleetStore, _ value: ReferenceWritableKeyPath<FleetStore, ReachFacts.BuildFacts?>)
        -> (FleetCloudModel.Stage, FleetCloudModel.Stage?, CloudServerUse, CloudProvider?) -> Void {
        var mine: ReachFacts.BuildFacts?
        return { [weak store] stage, stopped, use, provider in
            guard let store else { return }
            let new = ReachFacts.build(after: mine, stage: Self.stage(stage), stopped: stopped.map(Self.stage),
                                       use: use, provider: provider, now: Date())
            let stored = store[keyPath: value]
            let kept = ReachFacts.kept(new, over: stored, mine: mine)
            mine = new
            if kept != stored { store[keyPath: value] = kept }
        }
    }

    /// The model's stage by its fixed name, with no default: a new stage fails the build here (and a test of the
    /// names reads the model's source).
    private static func stage(_ stage: FleetCloudModel.Stage) -> ReachFacts.BuildStage {
        switch stage {
        case .token: .token
        case .choosing: .choosing
        case .making: .making
        case .joining: .joining
        }
    }

    /// **One read of Tailscale for all callers**, its two facts for the hub's host, a failed read's too, kept 10 seconds
    /// by uptime: a caller in a loop starts one local process in 10 seconds at most, and each read is parsed once.
    private let tailscale = KeptFlight<String?, ReachFacts.NetworkFacts>(keep: 10) { host in
        await ReachFacts.readNetwork(hubHost: host)
    }

    /// **Tailscale's facts for `setup_diagnosis`**, asked by the board only while the hub is `set`: the read and its
    /// parse run off the main thread. A call that was cancelled gets `not_read`.
    private func network() async -> SetupNetwork {
        guard let store, Self.hub(of: store) == .set else { return .notRead }
        guard let found = await tailscale.value(for: store.hub.host) else { return .notRead }
        return SetupNetwork(tailscale: found.tailscale.rawValue, hubDevice: found.hubDevice.rawValue)
    }

    /// The facts now, from the store and this Mac: no request to the hub, no value of a field.
    private func facts() -> SetupFacts {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = (info["CFBundleVersion"] as? String).flatMap { Int($0) }
        guard let store else {
            return SetupFacts(version: version, build: build, hub: .none, firstRun: .none,
                              programs: programsNow(page: nil), place: .none, places: [])
        }
        let hub = Self.hub(of: store)
        let firstRun = store.setupSnapshot
        let over = overNow()
        return SetupFacts(version: version, build: build, hub: hub, firstRun: firstRun,
                          programs: programsNow(page: firstRun.shows ? firstRun.page : nil),
                          place: Self.place(of: store), places: Self.places(of: store), over: over,
                          show: SetupShow.now(Self.showFacts(of: store, over: over)), inFront: Self.inFront())
    }

    /// **`setup_show`'s one effect.** `front`: the app asks macOS for the front as it is. A page of the first run: the
    /// window's wizard takes the ask (`FirstRunView`), checks it again, changes the page and asks for the front. A
    /// place of the fleet's own pages: `showPlace`. The
    /// program then asks macOS too, with `open` (`AppLink.front`), which is the way that worked on a test Mac. The wait
    /// for the wizard has no clock: it ends on the wizard's outcome, on another ask in its place, on the window's going
    /// (which refuses the ask), or on the end of the call's connection.
    private func show(_ page: String, seen: String) async -> String? {
        guard let store else { return "The Founderizer app is starting. Call setup_show again." }
        if page == "front" {
            AppFront.come { store.notifications.showWindow?() }
            return nil
        }
        if let place = SetupShow.place(of: page) { return showPlace(place, page: page, seen: seen, in: store) }
        guard SetupShow.pages.contains(page), let target = FirstRunPage(rawValue: page) else {
            return SetupShow.pageWords
        }
        let ask = SetupAsk(page: target, seen: seen)
        store.setupAsk = ask
        let once = AskOnce()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { resume in
                once.resume = resume
                Self.watch(ask: ask.id, in: store, once: once)
            }
        } onCancel: {
            Task { @MainActor in once.finish(nil) }
        }
        if store.setupAsk?.id == ask.id { store.setupAsk = nil }
        switch outcome {
        case .shown?: return nil
        case .refused(let words)?: return words
        case nil: return "Another ask took the place of this one, or the call ended. Call setup_state again."
        }
    }

    /// **A place of the fleet's own pages** (the plan "The app's pages and actions for the owner's own agent", part 2).
    /// The rules are asked once more here, with the store's own state and AppKit's windows of this moment, and the
    /// page changes in the same turn of the main actor: no `await` stands between the check and the change, so
    /// nothing that the owner does can come between them. **The last check is the window's own rule**: the store's
    /// page for the place must draw exactly that place now (`place(of:showing:)`, the rule that `setup_state` reads),
    /// so a show never falls back to another page (General for a section that the hub does not offer, "Task not
    /// found", an agent's setup in place of its chat). The page changes through the store (`FleetStore.show`): Back
    /// returns to the page before, the sidebar's row follows, and the chat that it opens is not marked as read. The
    /// place that shows already changes nothing and only comes to the front. No page gets a notice of it.
    private func showPlace(_ target: AppPlace, page: String, seen: String, in store: FleetStore) -> String? {
        // The button's state is the hardware's, read in this same turn as the change: no page changes while a
        // mouse button is down (`SetupShow.buttonHeld`).
        let facts = Self.showFacts(of: store, over: Self.over().0, target: target,
                                   buttonDown: NSEvent.pressedMouseButtons != 0)
        if let words = SetupShow.refusal(page: page, seen: seen, facts: facts) { return words }
        guard let destination = Self.destination(for: target),
              Self.place(of: store, showing: destination) == target else {
            return SetupShow.wouldShowAnother(target.name)
        }
        // **The keys and the first click are held before the page changes**, also for an owner who works in the app
        // (`OutsideFront`): what they type or click now is for the page that goes. And the store notes the change
        // (`ShownPage`): no second change of page until the owner acted in the app's main window.
        let changes = SetupShow.changesPlace(to: page, from: facts.place)
        AppFront.come(pageChanged: changes) {
            if changes { store.show(destination) }
            store.notifications.showWindow?()
        }
        return nil
    }

    /// The wait of `setup_show` for the wizard's outcome: it ends once.
    @MainActor private final class AskOnce: Sendable {
        nonisolated(unsafe) var resume: CheckedContinuation<SetupAsk.Outcome?, Never>?

        func finish(_ outcome: SetupAsk.Outcome?) {
            guard let resume else { return }
            self.resume = nil
            resume.resume(returning: outcome)
        }
    }

    private static func watch(ask id: UUID, in store: FleetStore, once: AskOnce) {
        guard store.setupAsk?.id == id else { return once.finish(nil) }
        if let outcome = store.setupAsk?.outcome { return once.finish(outcome) }
        withObservationTracking { _ = store.setupAsk } onChange: {
            Task { @MainActor in watch(ask: id, in: store, once: once) }
        }
    }
}
