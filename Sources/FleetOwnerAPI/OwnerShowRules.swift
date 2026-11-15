import Foundation

// ------------------------------------------------------------ setup_show for the fleet's own pages

/// **Whether `setup_show` can change the page now** (`setup_state`'s `show`), by a fixed name: `yes`, or the kind of
/// the reason. It answers for a place of the fleet's own pages; in a first run the tool has its own rules for its
/// pages `welcome` and `name`.
public enum ShowNow: String, CaseIterable, Sendable {
    case yes
    /// The first run shows, also its welcome page in front of a setup that never finished, or it holds the window
    /// behind a page of Settings that the owner opened over it.
    case firstRun = "first_run"
    /// A setup fills the window: Add server, Add agent, a later change of the fleet's shape, the setup of an agent
    /// that is being added or of a new fleet's manager.
    case setup
    /// `setup_show` changed the page, and no click of the owner reached the app's main window since: one change of
    /// page for each click of the owner that reaches the app. The click that the app drops after a change of page
    /// is no such click, and a key ends nothing.
    case shown
    /// The place that shows is not one from which the page changes (`fromForms`): on it the owner can be in the
    /// middle of typing or of work. Needs you is such a place while a request waits there.
    case inUse = "in_use"
    /// A card, a sheet, a panel or a menu of the app is open over the page (`AppOver.card`).
    case card
    /// The app has no reading of the hub.
    case noReading = "no_reading"
}

/// **What the app's store says of a place that `setup_show` was asked to open** (the rules 4 and 6 of the plan's
/// part 2). Only the app knows it, on the main actor, right before the page changes. It is judged by the reading
/// of the hub that the app has, which can be minutes old while the hub does not answer.
public enum ShowTarget: Equatable, Sendable {
    /// The fleet has it, and the app draws it when its page shows.
    case has
    /// The hub does not list this agent, or it has no such task.
    case missing
    /// The agent has no such part on this hub (the manager has no Tasks and no Can use).
    case noPart
    /// The agent's setup, its "Setting up" or its sign-in would show in place of its pages.
    case inSetup
}

/// **The facts that the rules of `setup_show` read.** The link asks the rules twice: when the request comes, with what
/// `setup_state`'s facts can tell (the five last values are nil then), and again on the main actor right before the
/// page changes, with the store's own state.
public struct ShowFacts: Equatable, Sendable {
    /// The place that the window shows now (`setup_state`'s `place`).
    public var place: AppPlace
    public var firstRun: SetupFirstRun
    public var over: AppOver
    /// The app holds a reading of the hub, a current one or the last one.
    public var hasReading: Bool
    /// The sections that Settings offers for this hub.
    public var sections: [AppPlace.SettingsPage]
    /// A setup fills the window (`FleetStore.fillsWindow` of the page that shows). Nil at the first ask.
    public var setupFills: Bool?
    /// The first run holds the window (`FleetStore.firstRunHolds`), also behind a page of Settings that the owner
    /// opened over it: the place is then that page of Settings. Nil at the first ask.
    public var firstRunHolds: Bool?
    /// The hub lists a request that waits for the owner (`FleetStore.openNeeds`): Needs you then draws it, with its
    /// options, its field for an answer or its form for a secret. Nil at the first ask.
    public var openRequest: Bool?
    /// `setup_show` changed the page, and the app handled no click of the owner that reached its main window since
    /// (`ShownPage.waitsForOwner`). Nil at the first ask.
    public var shown: Bool?
    /// What the store says of the place that was asked for. Nil at the first ask, and for a call that names none.
    public var target: ShowTarget?
    /// A mouse button is down now (`NSEvent.pressedMouseButtons`): a change of page would cut a click of the owner
    /// in two. Only the app's last check knows it, right before the change: nil at the first ask and for
    /// `setup_state`'s `show`, which no button moves.
    public var buttonDown: Bool?

    public init(place: AppPlace, firstRun: SetupFirstRun, over: AppOver, hasReading: Bool,
                sections: [AppPlace.SettingsPage], setupFills: Bool? = nil, firstRunHolds: Bool? = nil,
                openRequest: Bool? = nil, shown: Bool? = nil, target: ShowTarget? = nil, buttonDown: Bool? = nil) {
        self.place = place
        self.firstRun = firstRun
        self.over = over
        self.hasReading = hasReading
        self.sections = sections
        self.setupFills = setupFills
        self.firstRunHolds = firstRunHolds
        self.openRequest = openRequest
        self.shown = shown
        self.target = target
        self.buttonDown = buttonDown
    }

    /// **What `setup_state`'s facts can tell**, for the first ask. The list of places has `needs` only with a
    /// reading of the hub (`AppPlace.places`), and its sections of Settings are the ones that the app offers.
    public init(_ facts: SetupFacts) {
        self.init(place: facts.place, firstRun: facts.firstRun, over: facts.over,
                  hasReading: facts.places.contains(.needs),
                  sections: facts.places.compactMap { if case .settings(let page) = $0 { page } else { nil } })
    }
}

extension SetupShow {
    /// **The places from which `setup_show` changes the page** (the plan's rule 2), by their forms: a place where
    /// nothing that the owner typed or chose is lost and where no work reads a change of page as "the owner left".
    /// Tasks and Agents hold no field and no choice of their own. **Needs you is such a place only while the hub
    /// lists no open request** (`ShowFacts.openRequest`): with a request, a change of page loses the options that the
    /// owner ticked on an item, the request that they chose, and what they typed into a secret's form
    /// (`SecretRequestForm`, whose fields live only while their page shows). A test holds the list word for word.
    ///
    /// **Not on the list in this version, each for what a change of page loses there** (two reviews of 15 November
    /// 2026 read these pages):
    /// - `agent.<name>`, an agent's chat: one text field serves every agent's chat (`composer()` in
    ///   `FleetView.swift` has no id for each agent), so words that the owner types for one agent can go to another
    ///   agent after a show. It comes back when the chat's own thread gives the field an id for each agent and a
    ///   live fleet proved it.
    /// - `settings.status`: the state of a run's button is lost, so a second press would send again.
    /// - `settings.general`: a model choice that the hub refused, and its "Try again", are lost; and its group
    ///   Updates clears its failure line when it goes (`UpdatesModel.left`), as the page Settings › Updates did
    ///   until it went on 15 November 2026.
    public static let fromForms = ["tasks", "agents", "needs"]

    /// The list `fromForms` in the words of a refusal and of the tool's description, with the rule for Needs you.
    public static let fromWords = "tasks, agents, and needs while no request waits there"

    /// **The places that `setup_show` opens** (the plan's rule 3), by their forms: a place is on the list only when
    /// its page does nothing by itself when it shows (a read of the hub, or of the app's own update channel, is
    /// nothing) and makes macOS ask nothing. Each page's view, its `.onAppear`, `.task` and `.onChange` and its
    /// model's start were read for this at `a64ed0306` (15 November 2026). A test holds the list word for word.
    ///
    /// **Left out, each for what its code does by itself:**
    /// - `agent.<name>.runs_on` (`AgentSetupView`): it carries out a Rename… or a Deactivate that waits in the store
    ///   (`FleetStore.agentAction`, taken with `.onChange(initial: true)`; Deactivate is a write to the hub). Its part
    ///   for the AI provider opens by itself while a provider's setup goes on, stopped or ended
    ///   (`ProviderSetup.reopens`), and that part asks this Mac's installer and starts the machine check of a setup
    ///   that ended while it did not show (`ProviderView`'s `.task`: `askInstaller`, `afterSetup`).
    /// - `settings.servers` (`ServersPage`): with the connected apps on, it makes a code on the hub when it shows
    ///   (`ConnectedAppsModel.run`, then `keepCode`: a write); its devices make a device's code when a Needs-you
    ///   answer asked for one (`DevicesView`, `FleetStore.addDeviceAsked`: a write); and its going ends a stop of
    ///   Turn on (`ConnectSwitchModel.left`).
    /// - `settings.backup` (`BackupSettings`): not decided. Its row "Where" looks for iCloud Drive on the disk when
    ///   it draws (`FleetCopyKeeper.iCloudDrive`, `shownFolderName`), a folder that macOS guards, and the code alone
    ///   does not say that macOS never asks there.
    ///
    /// **Never on the list** (the plan's rule 4): Add server, Add agent, a later change of the fleet's shape, the
    /// Tailscale key of Turn on, one server's page, one app's page, an agent's rule editor, and each place of an
    /// agent's setup (its pages `name` and `servers` too), "Setting up" and sign-in.
    public static let targetForms = ["needs", "tasks", "agents", "agent.<name>", "settings.general",
                                     "settings.status", "task.<number>", "agent.<name>.behaviour",
                                     "agent.<name>.tasks", "agent.<name>.people", "agent.<name>.can_use",
                                     "settings.secrets", "settings.knowledge", "settings.apps", "settings.people",
                                     "settings.team"]

    /// **The form of a place**: its name with `<name>` for an agent's or a server's name and `<number>` for a
    /// task's number. A switch with no default: a place that a later version adds does not build until it has a
    /// form here, and so a decision about the two lists.
    public static func form(of place: AppPlace) -> String {
        switch place {
        case .task: return "task.<number>"
        case .agent: return "agent.<name>"
        case .agentPart(_, let part): return "agent.<name>." + part.rawValue
        case .agentRule: return "agent.<name>.rule"
        case .agentSetup(_, let page): return "agent.<name>.setup" + (page.map { "." + $0.rawValue } ?? "")
        case .agentSetupServer(_, let page): return "agent.<name>.setup.server." + page.rawValue
        case .agentSettingUp: return "agent.<name>.setting_up"
        case .agentSignIn(_, let page): return "agent.<name>.sign_in" + (page.map { "." + $0.rawValue } ?? "")
        case .server: return "server.<name>"
        case .needs, .tasks, .agents, .settings, .app, .addServer, .addAgent, .connectKey, .shapeChange, .firstRun,
             .waiting, .none, .someAgent, .someServer, .someTask:
            return place.name
        }
    }

    /// The place is on the list `fromForms`. Needs you has one more condition, which `now` asks.
    public static func isFrom(_ place: AppPlace) -> Bool { fromForms.contains(form(of: place)) }
    public static func isTarget(_ place: AppPlace) -> Bool { targetForms.contains(form(of: place)) }

    /// **Whether `setup_show` can change the page now**, and when it cannot, the kind of the reason
    /// (`setup_state`'s `show`). `refusal` refuses a place for the same facts, in the same order: the first run, no
    /// reading, a setup that fills the window, a page that a show changed already, a card, then the place.
    public static func now(_ facts: ShowFacts) -> ShowNow {
        if case .firstRun = facts.place { return .firstRun }
        if facts.firstRun.shows || facts.firstRunHolds == true { return .firstRun }
        if !facts.hasReading { return .noReading }
        // Add server, Add agent and a change of the fleet's shape fill the window whenever there is a reading
        // (`FleetStore.fillsWindow`); an agent's setup that fills it is the store's to say.
        let wizard: Bool = switch facts.place {
        case .addServer, .addAgent, .shapeChange: true
        default: false
        }
        if facts.setupFills ?? wizard { return .setup }
        if facts.shown == true { return .shown }
        if facts.over == .card { return .card }
        if !isFrom(facts.place) || (facts.place == .needs && facts.openRequest == true) { return .inUse }
        return .yes
    }

    // ------------------------------------------------------------ the words of the refusals

    /// The refusal of a `page` that is no name of a place at all. It repeats nothing of what the caller sent.
    public static let pageWords = "page must be front, or for a first run welcome or name, or one of these places "
        + "of the fleet's own pages: " + targetForms.joined(separator: ", ") + "."

    /// The refusal of a `seen` that is missing or is no text.
    public static let seenWords = "seen must be the place that setup_state gave last, such as tasks, agent.<name> "
        + "or first_run.welcome."

    /// The refusal of a field that the tool does not take. It does not say the field's name back.
    public static let fieldsWords = "setup_show takes only page and seen."

    /// Rule 1: `seen` is not the place that shows now. `now` is a name that the app made (`AppPlace.name`).
    static func notSeen(_ now: String) -> String {
        "The place that shows now is \(now), and seen names another one. Read setup_state again, and call "
            + "setup_show with seen \(now) if the owner should still see another page."
    }

    /// A place of the map that is on no list of targets. `name` was read back by `AppPlace(name:)`, so it holds only
    /// fixed words, a name in its narrow alphabet and a number.
    static func notOpened(_ name: String) -> String {
        "setup_show does not open \(name): only the owner opens that page, because it can act by itself when it "
            + "shows or the owner works on it. It opens these places: " + targetForms.joined(separator: ", ") + "."
    }

    static let firstRunPlace = "For a page of the first run, page is welcome or name, not a place."

    static func firstRunShows(_ now: String) -> String {
        "The first run shows (the place is \(now)), so setup_show opens no page of the fleet. There, page is "
            + "front, welcome or name."
    }

    /// The first run holds the window, and the owner has a page of Settings open over it.
    static func firstRunBehind(_ now: String) -> String {
        "The first run holds the app's window, behind the page of Settings that shows now (the place is \(now)), so "
            + "setup_show opens no page of the fleet. setup_show with page front still asks macOS to bring the app to "
            + "the front."
    }

    static func noReading(_ now: String) -> String {
        "The app has no reading of the hub (the place is \(now)), so setup_show opens no page of the fleet. Read "
            + "setup_diagnosis for the reason. setup_show with page front still asks macOS to bring the app to the "
            + "front."
    }

    static func setupFills(_ now: String) -> String {
        "A setup fills the app's window (the place is \(now)), and the owner is in the middle of it, so setup_show "
            + "changes no page. The owner ends that setup or closes it."
    }

    /// **No page changes while a mouse button is down.** A change in the middle of a click would cut it in two: its
    /// release, and the owner's next click some 100 ms later, would land on a page that the owner did not see yet.
    /// So the tool waits for no button: it refuses, and the caller calls again.
    static let buttonHeld = "The owner holds a mouse button down now, so setup_show changes no page under that "
        + "click. Call setup_show again."

    /// One change of page for each click of the owner that reached the app (`ShownPage`). A key ends nothing.
    static func shownAlready(_ now: String) -> String {
        "setup_show changed the page already (the place is \(now)), and no click of the owner reached the app's "
            + "main window since, so it changes no page again: one change of page for each click of the owner that "
            + "reaches the app. After a change of page the app drops one click of the owner. The next click that "
            + "reaches the app ends this (a click on a text field, a switch or a slider can pass unseen, and then the "
            + "next one counts); a key does not. Say the page in words. setup_show with page front still asks macOS "
            + "to bring the app to the front."
    }

    static let cardOver = "A card, a panel or a menu of the app is open over the page (over is card), and the owner "
        + "is in the middle of it, so setup_show changes no page under it. Call setup_state with after to wait for "
        + "the next change."

    /// The place that shows is not on the list. The words make no claim about that page.
    static func notFrom(_ now: String) -> String {
        "setup_show changes the page only from these places: " + fromWords + ", because on every other place the "
            + "owner can be in the middle of typing or of work. The place that shows now is \(now)."
    }

    /// Needs you while a request waits there.
    static let requestWaits = "The place that shows now is needs, and a request waits there: the owner may be in "
        + "the middle of an answer, so setup_show changes no page. It changes the page only from these places: "
        + fromWords + "."

    static func noSection(_ name: String) -> String {
        "Settings has no such section for this hub (\(name)). setup_state gives the sections that it has in places."
    }

    /// Rule 6, for a place that names an agent or a task. `name` is the place's own name (`AppPlace.name`).
    static func missing(_ place: AppPlace) -> String {
        if case .task = place {
            return "This fleet has no such task (\(place.name)): the hub does not list it. fleet_overview gives the open "
                + "tasks."
        }
        return "This fleet has no such agent (\(place.name)): the hub does not list it. fleet_overview gives the agents."
    }

    /// The parts by role are the app's own (`AgentTab.available`): Tasks and Can use for a worker or a lead only.
    static func noPart(_ name: String) -> String {
        "That agent has no such part on this hub (\(name)): tasks and can_use are parts of a worker or a lead, and "
            + "the manager has neither; each part also needs a hub that offers it. Say the page in words, or offer "
            + "the owner another place."
    }

    /// Rule 4: a place of an agent whose setup, "Setting up" or sign-in would show in its place.
    static func inSetup(_ name: String) -> String {
        "The app shows that agent's setup, its \"Setting up\" or its sign-in in place of its pages (\(name)): the "
            + "agent is not set up, not ready or signed out. setup_show opens no place of such an agent."
    }

    /// The app's last check, on the main actor: the page that was asked for would draw another place.
    public static func wouldShowAnother(_ name: String) -> String {
        "The app would show another page than \(name) now, so setup_show changed nothing. Read setup_state again."
    }

    // ------------------------------------------------------------ the rules

    /// **The place that `page` names, when it is no page of the first run and not `front`**: nil for `front`,
    /// `welcome` and `name`, which keep the rules of the first run.
    public static func place(of page: String) -> AppPlace? {
        pages.contains(page) ? nil : AppPlace(name: page)
    }

    /// **Whether an ask that `refusal` let pass changes the page of the fleet**: not for `front`, not for a page of
    /// the first run (`changesPage(to:from:)` says that), and not for the place that shows already, which only
    /// comes to the front.
    public static func changesPlace(to page: String, from place: AppPlace) -> Bool {
        guard let target = self.place(of: page) else { return false }
        return target != place
    }

    /// **Why `setup_show` does not show `page` now**, or nil when it may: every rule of the tool, for `front`, for
    /// the first run's pages and for a place of the fleet's own pages. Each refusal has fixed words, with names that
    /// the app made itself (`AppPlace.name`: fixed words, a name in its narrow alphabet, a number). So a refusal can
    /// name the place that was asked for in that fixed form, and nothing else that the caller sent is said back.
    ///
    /// The rules for a place, in this order: `page` is a place of the list `targetForms`; `seen` is the place that
    /// shows now (rule 1); no first run shows or holds the window, the app has a reading of the hub and no setup
    /// fills the window (rule 5); no show changed the page since the owner's last act; no card stands over the page
    /// (rule 8); the place that shows is on the list `fromForms`, and for Needs you no request waits (rule 2); the
    /// fleet has the place (rule 6); and no setup shows in its place (rule 4).
    public static func refusal(page: String, seen: String, facts: ShowFacts) -> String? {
        if pages.contains(page) {
            return refusal(page: page, seen: seen, firstRun: facts.firstRun, place: facts.place)
        }
        guard let target = AppPlace(name: page) else { return pageWords }
        guard isTarget(target) else {
            switch target {
            case .firstRun: return firstRunPlace
            // No page: the waiting page, nothing, and the kind alone of a place whose name is not known.
            case .waiting, .none, .someAgent, .someServer, .someTask: return pageWords
            default: return notOpened(target.name)
            }
        }
        let now = facts.place.name
        guard seen == now else { return notSeen(now) }
        switch self.now(facts) {
        case .firstRun:
            if case .firstRun = facts.place { return firstRunShows(now) }
            return facts.firstRun.shows ? firstRunShows(now) : firstRunBehind(now)
        case .noReading: return noReading(now)
        case .setup: return setupFills(now)
        case .shown: return shownAlready(now)
        case .card: return cardOver
        case .inUse: return facts.place == .needs ? requestWaits : notFrom(now)
        case .yes: break
        }
        if case .settings(let section) = target, !facts.sections.contains(section) { return noSection(target.name) }
        switch facts.target {
        case .missing?: return missing(target)
        case .noPart?: return noPart(target.name)
        case .inSetup?: return inSetup(target.name)
        case .has?, nil: break
        }
        // Last, and only for a call that would change the page: a call for the place that shows changes nothing.
        if facts.buttonDown == true, changesPlace(to: page, from: facts.place) { return buttonHeld }
        return nil
    }
}

// ------------------------------------------------------------ after a show changed the page

/// **What a `setup_show` that changed the page leaves open until the owner acts in the app's main window.** Two
/// things, in one value with no clock:
///
/// - **One change of page for each click of the owner that reached the app** (`waitsForOwner`). After a show that
///   changed the page, the next one is refused until the app handled a click of the owner that reached its main
///   window. **A key never ends it**: with a key, a caller that shows again at once could make the app drop every
///   click of the owner (a show; the click is dropped and frees the keys; a key frees the next show; and so on).
/// - **A page that the owner's own agent opened is not a page that the owner read** (the plan's rule 7, `chat`).
///   The app counts an agent's open chat as read (`FleetStore.markRepliesSeen`). The chat that a show opened does
///   not count until a click or a key of the owner reached the app's main window **and that chat still shows after
///   the app handled it**: the click that leaves the chat does not mark it. A change of page ends the mark: the chat
///   that the owner opens themselves counts as read, as before. A new name of the agent keeps it.
///
/// **What is no act of the owner** (`handled` then does nothing):
/// - **A click that the app dropped** (`Act.reached` false). After a change of page the app drops one click of the
///   owner, which was for the page that went (`OutsideFront`), and holds the keys until that click. If that click
///   freed the next change of page, a caller in a loop would make the app drop every click.
/// - **An event that began before the latest change of page by a show** (`Act.began`): a key whose handling still
///   waits on the main queue when a show comes, or a mouse-up of a click that went down on the page before. Each
///   show that changes the page has a number (`change`), and the app's watch notes the number at the mouse-down and
///   at the key-down.
///
/// So the order under a caller that shows again as early as it can is: a show; one click of the owner is dropped;
/// the next click reaches the page, and when the app handled its mouse-up, one more change of page is free. **Of any
/// two clicks of the owner at least one reaches the app**, whatever keys come between (a test plays that caller). A
/// click is over at its mouse-up, so the click that reached does its work on the page that it was aimed at before
/// the page can change again, and no page changes while a mouse button is down (`SetupShow.buttonHeld`). **One
/// exception, of a short moment (usually a few milliseconds, longer while the app's main thread is busy):** a show
/// that lands between the release of a button and the delivery of its mouse-up to the app finds no button down.
/// That click then ends on the page that came and does nothing there (AppKit's controls start their action from a
/// mouse-down; that is AppKit's behaviour, and no test of this code holds it), and the next click is the dropped
/// one. A caller that reads the button's state can aim at that moment, so such a show costs the owner two clicks
/// in a row.
///
/// The app's watch does not see a mouse-up that a control of AppKit takes in its own tracking loop (a text field,
/// a switch, a slider): such a click is not told, and the next one counts.
///
/// The store tells it a show before the page changes (`shows`), each change of page (`went`), a new name of an agent
/// (`renamed`), each click or key of the owner in the main window after the app handled it (`handled`), and asks
/// it before it marks a chat as read (`countsAsRead`).
public struct ShownPage: Equatable, Sendable {
    /// A show changed the page, and the app handled no click of the owner that reached its main window since.
    public private(set) var waitsForOwner = false
    /// The agent whose chat a show opened, until the owner acted with that chat still on the page, or the page
    /// changed again.
    public private(set) var chat: String?
    /// The number of the latest change of page by a show: 0 before the first one. An event of the owner carries the
    /// number that stood when it began (`Act.began`).
    public private(set) var change = 0

    /// **One click or one key of the owner in the app's main window**, as the app's watch tells it after the app
    /// handled it.
    public struct Act: Equatable, Sendable {
        /// A click, told after its mouse-up; false for a key.
        public var isClick: Bool
        /// It reached the app's controls (`OutsideFront`): false for a click that the app dropped.
        public var reached: Bool
        /// The number of the latest change of page by a show (`ShownPage.change`) when the event began: at the
        /// mouse-down of a click, at the key-down of a key.
        public var began: Int

        public init(isClick: Bool, reached: Bool, began: Int) {
            self.isClick = isClick
            self.reached = reached
            self.began = began
        }
    }

    public init() {}

    /// `setup_show` is about to change the page: `chat` is the agent whose chat it opens, or nil for another page.
    public mutating func shows(_ chat: String?) {
        change += 1
        waitsForOwner = true
        self.chat = chat
    }

    /// The page changed. `chat`: the agent whose chat shows now, or nil. The chat that a show just opened keeps its
    /// mark; every other change of page ends it.
    public mutating func went(to chat: String?) { if self.chat != chat { self.chat = nil } }

    /// The hub gave an agent a new name, and the app moves its page to that name by itself: the mark goes with it.
    public mutating func renamed(from old: String, to new: String) { if chat == old { chat = new } }

    /// **The app handled a click (its mouse-up) or a key of the owner in its main window.** `chat`: the agent whose
    /// chat shows now, after that event, or nil. An event that did not reach the app, or that began before the
    /// latest change of page by a show, does nothing. A click that counts frees the next change of page; a key never
    /// does. True when the chat that a show opened counts as read from now on: for a click or a key that counts, and
    /// only when that chat still shows.
    public mutating func handled(_ act: Act, showing chat: String?) -> Bool {
        guard act.reached, act.began == change else { return false }
        if act.isClick { waitsForOwner = false }
        guard let shown = self.chat, shown == chat else { return false }
        self.chat = nil
        return true
    }

    /// Whether the open chat of `chat` counts as read.
    public func countsAsRead(_ chat: String) -> Bool { self.chat != chat }
}

// ------------------------------------------------------------ the window in front

/// **Whether the Founderizer window is in front** (`setup_state`'s `in_front`): the app is the active app, and its
/// main window, the window of the fleet's pages, is on the screen, on the Space that shows, not in the Dock, and is
/// the app's main window or its key window. With another window of the app as the key window (Report a problem) the
/// main window can stand behind another app's window. The app reads it from AppKit at each call, as `over`. It says
/// nothing of what a picture of each display shows.
public enum AppInFront {
    /// One window of the app.
    public struct Window: Equatable, Sendable {
        /// The app's main window: the window of the fleet's pages.
        public var isFleet: Bool
        /// It is on the screen (not closed, not hidden).
        public var onScreen: Bool
        /// It is on the Space that shows now.
        public var onActiveSpace: Bool
        /// It is in the Dock.
        public var miniaturized: Bool
        /// AppKit names it as the app's main window, or as its key window.
        public var mainOrKey: Bool

        public init(isFleet: Bool, onScreen: Bool, onActiveSpace: Bool = true, miniaturized: Bool = false,
                    mainOrKey: Bool = true) {
            self.isFleet = isFleet
            self.onScreen = onScreen
            self.onActiveSpace = onActiveSpace
            self.miniaturized = miniaturized
            self.mainOrKey = mainOrKey
        }
    }

    public static func of(active: Bool, windows: [Window]) -> Bool {
        active && windows.contains {
            $0.isFleet && $0.onScreen && $0.onActiveSpace && !$0.miniaturized && $0.mainOrKey
        }
    }
}
