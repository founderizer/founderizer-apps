import Foundation

/// **The place that the app's window shows, by a fixed name** (the plan "The app's pages and actions for the owner's
/// own agent", part 1): what `setup_state` gives as `place`, and what a later slice of `setup_show` takes. A name is
/// made of fixed words from closed lists, an agent's or a server's name in a narrow alphabet (`isName`), and a task's
/// number. It never carries a title, a typed value, a failure's words, a path or an address.
///
/// The names follow the app's own launch argument (`-openPage`, `FleetStore.asked`) where that one has a name; an
/// agent's parts differ (`runs_on` and `can_use` here, `runson` and `canuse` there). A name part that is not in the
/// narrow alphabet is left out, and the name says only the kind of the place: `agent`, `server` or `task`.
public enum AppPlace: Hashable, Sendable {
    /// A part of an agent's details (`AgentTab` in the app; its tab `chat` is the agent's chat, `agent.<name>`).
    public enum AgentPart: String, CaseIterable, Sendable {
        case runsOn = "runs_on", behaviour, tasks, people
        case canUse = "can_use"
    }

    /// A page of an agent's setup (`AgentSetupPage` in FleetCore, by its case).
    public enum SetupPage: String, CaseIterable, Sendable {
        case name, servers, server, provider, installing, switching
        case signIn = "sign_in"
        case activate
    }

    /// A page of the sign-in of an agent's machine (`SignInWizard.Page` in the app).
    public enum SignInPage: String, CaseIterable, Sendable {
        case start, link, code, done, failed
    }

    /// A section of Settings, by the raw value of `SettingsTab` in the app (a test reads the app's source).
    public enum SettingsPage: String, CaseIterable, Sendable {
        case general, servers, backup, status, secrets, knowledge, apps, people, team
    }

    /// One app's page of Settings, Apps, by the raw value of `AppsGroup` in the app.
    public enum AppGroup: String, CaseIterable, Sendable {
        case github, drive, gmail, mcp
    }

    /// A page of Add server (`AddServerView.Page` in the app; `key` and `token` are a provider's pages; `again` is
    /// "Start again", which only the setup of a manager with no server yet has).
    public enum AddServerPage: String, CaseIterable, Sendable {
        case ways, ai, opening, machine, install, key, token, vps, again
    }

    /// A step of Add agent: its servers, the new agent's name and AI, and the install that runs.
    public enum AddAgentStep: String, CaseIterable, Sendable {
        case server, name, progress
    }

    case needs, tasks, agents
    /// One task's thread.
    case task(Int)
    /// An agent's chat.
    case agent(String)
    case agentPart(String, AgentPart)
    /// The editor of one rule of an agent's Behaviour. The rule's id and section are not in the name.
    case agentRule(String)
    /// An agent's setup, in place of its chat or of its Runs on; nil when its page is not known.
    case agentSetup(String, SetupPage?)
    /// The server page of an agent's setup draws Add server inside it: the page of that Add server. A provider's
    /// token, a Tailscale key and a password are typed on its pages, so the name must say which one shows.
    case agentSetupServer(String, AddServerPage)
    /// "Setting up" in place of an agent's chat: its session is not ready yet.
    case agentSettingUp(String)
    /// The sign-in of an agent's machine; nil when its page is not known.
    case agentSignIn(String, SignInPage?)
    case settings(SettingsPage)
    case app(AppGroup)
    /// One server's page of Settings, Servers.
    case server(String)
    case addServer(AddServerPage?)
    case addAgent(AddAgentStep?)
    /// "Your Tailscale key" of Turn on for the connected apps.
    case connectKey
    /// A later change of the fleet's shape, from the slider of Settings › Servers: a wizard that fills the window,
    /// and that makes servers and moves agents. Its own pages have no name yet.
    case shapeChange
    /// The first run, on its page (nil when the page is not known).
    case firstRun(FirstRunPage?)
    /// The app has a hub's address, that hub answered this Mac before, and no reading is there now.
    case waiting
    /// No store yet, or nothing to name.
    case none
    /// A place of an agent, of a server or of a task whose name or number is not in its alphabet: the kind alone.
    case someAgent, someServer, someTask

    /// **The narrow alphabet of a name part**: `^[a-z][a-z0-9-]{1,30}$`, so 2 to 31 characters. The set `owner` reads
    /// agents' and servers' names in it today with `fleet_overview`.
    public static func isName(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (2...31).contains(scalars.count), ("a"..."z").contains(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// A task's number in a name has at most 18 digits: a greater one gives the kind alone, and a name reads back.
    public static let taskLimit = 1_000_000_000_000_000_000

    /// **The name of the place.** A name part out of its alphabet gives the kind alone (`agent`, `server`, `task`).
    public var name: String {
        func agent(_ name: String, _ rest: String?) -> String {
            guard Self.isName(name) else { return "agent" }
            return "agent." + name + (rest.map { "." + $0 } ?? "")
        }
        switch self {
        case .needs: return "needs"
        case .tasks: return "tasks"
        case .agents: return "agents"
        case .task(let number): return (0..<Self.taskLimit).contains(number) ? "task.\(number)" : "task"
        case .agent(let name): return agent(name, nil)
        case .agentPart(let name, let part): return agent(name, part.rawValue)
        case .agentRule(let name): return agent(name, "rule")
        case .agentSetup(let name, let page): return agent(name, "setup" + (page.map { "." + $0.rawValue } ?? ""))
        case .agentSetupServer(let name, let page): return agent(name, "setup.server." + page.rawValue)
        case .agentSettingUp(let name): return agent(name, "setting_up")
        case .agentSignIn(let name, let page): return agent(name, "sign_in" + (page.map { "." + $0.rawValue } ?? ""))
        case .settings(let page): return "settings." + page.rawValue
        case .app(let group): return "app." + group.rawValue
        case .server(let name): return Self.isName(name) ? "server." + name : "server"
        case .addServer(let page): return "add_server" + (page.map { "." + $0.rawValue } ?? "")
        case .addAgent(let step): return "add_agent" + (step.map { "." + $0.rawValue } ?? "")
        case .connectKey: return "connect_key"
        case .shapeChange: return "shape_change"
        case .firstRun(let page): return "first_run" + (page.map { "." + $0.rawValue } ?? "")
        case .waiting: return "waiting"
        case .none: return "none"
        case .someAgent: return "agent"
        case .someServer: return "server"
        case .someTask: return "task"
        }
    }

    /// **Every name with no agent, server or task in it**, in a fixed order: each of them is a word of a closed list.
    public static var fixedNames: [String] {
        var places: [AppPlace] = [.needs, .tasks, .agents]
        places += SettingsPage.allCases.map(AppPlace.settings) + AppGroup.allCases.map(AppPlace.app)
        places += [.addServer(nil)] + AddServerPage.allCases.map { .addServer($0) }
        places += [.addAgent(nil)] + AddAgentStep.allCases.map { .addAgent($0) }
        places += [.connectKey, .shapeChange, .firstRun(nil)] + FirstRunPage.allCases.map { .firstRun($0) }
        places += [.waiting, .none, .someAgent, .someServer, .someTask]
        return places.map(\.name)
    }

    /// **The places that the fleet has now** (`setup_state`'s `places`), in a fixed order: Needs you, Tasks and Agents,
    /// each section of Settings that the app offers, each app's page that exists, then Add server and Add agent. Without
    /// a reading of the hub only the sections of Settings count. `settings` and `apps` are the app's own lists for the
    /// hub's features (`SettingsTab.available`, `AppsGroup.available`); their order here is this type's.
    /// `canAdd`: the hub can add a server and an agent (its feature `servers`). Without it the sidebar's plus still
    /// opens Add agent and Add server, and they draw only a line that asks for an update of the hub: the list leaves
    /// both out, because neither can add anything there.
    public static func places(hasReading: Bool, settings: [SettingsPage], apps: [AppGroup], canAdd: Bool) -> [AppPlace] {
        var places: [AppPlace] = hasReading ? [.needs, .tasks, .agents] : []
        places += SettingsPage.allCases.filter(settings.contains).map(AppPlace.settings)
        guard hasReading else { return places }
        places += AppGroup.allCases.filter(apps.contains).map(AppPlace.app)
        return places + (canAdd ? [.addServer(nil), .addAgent(nil)] : [])
    }

    /// **What the window draws over its destination** (`FleetView.body`, in its order): nothing in the moment before
    /// the launch's first read, the first run (also the welcome page in front of an unfinished setup), then the place
    /// of the destination when it is a place of Settings or there is a reading, else the waiting page of a hub that
    /// answered before, or the first run. `destination`: the place that the destination draws when nothing covers it.
    public static func shows(_ window: WindowFacts, destination: AppPlace) -> AppPlace {
        if !window.launched && !window.hasReading { return .none }
        let firstRun = ((!window.hasReading && !window.answeredBefore) || window.firstRunHolds) && !window.settings
        if firstRun || window.welcomeCovers { return .firstRun(window.firstRunPage) }
        if window.settings || window.hasReading { return destination }
        return window.answeredBefore ? .waiting : .firstRun(window.firstRunPage)
    }

    /// **A name read back**, or nil for a text that is no name of this list.
    public init?(name: String) {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first, !parts.contains(where: \.isEmpty) else { return nil }
        let rest = Array(parts.dropFirst())
        switch (head, rest.count) {
        case ("needs", 0): self = .needs
        case ("tasks", 0): self = .tasks
        case ("agents", 0): self = .agents
        case ("connect_key", 0): self = .connectKey
        case ("shape_change", 0): self = .shapeChange
        case ("waiting", 0): self = .waiting
        case ("none", 0): self = .none
        case ("agent", 0): self = .someAgent
        case ("server", 0): self = .someServer
        case ("task", 0): self = .someTask
        case ("add_server", 0): self = .addServer(nil)
        case ("add_agent", 0): self = .addAgent(nil)
        case ("first_run", 0): self = .firstRun(nil)
        case ("task", 1):
            // One text for one number: no sign, no zero in front, at most 18 digits.
            guard rest[0].count <= 18, rest[0].unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let number = Int(rest[0]), String(number) == rest[0] else { return nil }
            self = .task(number)
        case ("settings", 1):
            guard let page = SettingsPage(rawValue: rest[0]) else { return nil }
            self = .settings(page)
        case ("app", 1):
            guard let group = AppGroup(rawValue: rest[0]) else { return nil }
            self = .app(group)
        case ("server", 1):
            guard Self.isName(rest[0]) else { return nil }
            self = .server(rest[0])
        case ("add_server", 1):
            guard let page = AddServerPage(rawValue: rest[0]) else { return nil }
            self = .addServer(page)
        case ("add_agent", 1):
            guard let step = AddAgentStep(rawValue: rest[0]) else { return nil }
            self = .addAgent(step)
        case ("first_run", 1):
            guard let page = FirstRunPage(rawValue: rest[0]) else { return nil }
            self = .firstRun(page)
        case ("agent", 4):
            guard Self.isName(rest[0]), rest[1] == "setup", rest[2] == "server",
                  let page = AddServerPage(rawValue: rest[3]) else { return nil }
            self = .agentSetupServer(rest[0], page)
        case ("agent", 1...3):
            let agent = rest[0]
            guard Self.isName(agent) else { return nil }
            switch (rest.count, rest.dropFirst().first, rest.dropFirst(2).first) {
            case (1, _, _): self = .agent(agent)
            case (2, "rule"?, _): self = .agentRule(agent)
            case (2, "setting_up"?, _): self = .agentSettingUp(agent)
            case (2, "setup"?, _): self = .agentSetup(agent, nil)
            case (2, "sign_in"?, _): self = .agentSignIn(agent, nil)
            case (2, let part?, _):
                guard let part = AgentPart(rawValue: part) else { return nil }
                self = .agentPart(agent, part)
            case (3, "setup"?, let page?):
                guard let page = SetupPage(rawValue: page) else { return nil }
                self = .agentSetup(agent, page)
            case (3, "sign_in"?, let page?):
                guard let page = SignInPage(rawValue: page) else { return nil }
                self = .agentSignIn(agent, page)
            default: return nil
            }
        default: return nil
        }
    }
}

/// **The window's facts that decide whether a destination shows** (`FleetView.body` and `FleetView.firstRun`).
public struct WindowFacts: Equatable, Sendable {
    /// The launch's first read of the hub answered, or a second went by (`FleetStore.launched`).
    public var launched: Bool
    /// The app holds a reading of the hub.
    public var hasReading: Bool
    /// This hub's address answered this Mac before.
    public var answeredBefore: Bool
    /// The first run holds the window after its hub answered.
    public var firstRunHolds: Bool
    /// The first run's welcome page stands in front of an unfinished setup (`FleetStore.welcomeCovers`).
    public var welcomeCovers: Bool
    /// The destination is a place of Settings (a section, a server's page, Add server, an app's page, the key).
    public var settings: Bool
    /// The first run's page, when it shows one (`FleetStore.setupSnapshot`).
    public var firstRunPage: FirstRunPage?

    public init(launched: Bool, hasReading: Bool, answeredBefore: Bool, firstRunHolds: Bool, welcomeCovers: Bool,
                settings: Bool, firstRunPage: FirstRunPage?) {
        self.launched = launched
        self.hasReading = hasReading
        self.answeredBefore = answeredBefore
        self.firstRunHolds = firstRunHolds
        self.welcomeCovers = welcomeCovers
        self.settings = settings
        self.firstRunPage = firstRunPage
    }
}

/// **What the app has open over the page of its window, or beside it** (`setup_state`'s `over`). `place` names the
/// page that the window draws, and a page is not all that the screen can show: a card over the window ("Save a
/// secret", Search, Delete), a sheet, a panel of macOS (a file to choose, an alert), a menu, a popover, a hover's words
/// and a second window (Report a problem) have no place, and each can show a secret or the owner's own text. So an
/// agent that may look at the window looks only while this is `nothing` (the guide's closed list of places says the
/// rest). The app reads it from AppKit's own list of its windows (`AppOver.of`), with no line in a view: a card or a
/// window that a later version adds counts with no change here.
///
/// **Every window that is not the fleet's counts, but one.** Measured in the real app on 15 November 2026 (macOS 26):
/// a card of the app is a panel that hangs on the window (`ModalPanel`), a hover's words are a panel
/// (`NSToolTipPanel`), a menu of the menu bar is a window that neither hangs nor can be the main window
/// (`NSPopupMenuWindow`), and in full screen macOS hangs the window's own title bar on it as a window
/// (`NSToolbarFullScreenWindow`). That bar is the one window that counts as nothing (`isBar`): it is a part of the
/// fleet's window. A window of a kind that nobody measured counts as a card or a window, which is the safe side.
public enum AppOver: String, CaseIterable, Sendable {
    /// Nothing: the fleet's window shows its page alone, or the app shows no window.
    case nothing
    /// Something of the app stands over one of its windows: a card, a sheet, a panel, a menu, a popover, a hover's
    /// words.
    case card
    /// Another window of the app shows: Report a problem, or one that this version does not know.
    case window

    /// One window of the app that is on the screen now.
    public struct Shown: Equatable, Sendable {
        /// The window of the fleet's pages.
        public var isFleet: Bool
        /// It hangs on another window (a child window, a sheet), or it is a panel.
        public var hangs: Bool
        /// It can be the app's main window: a window with content of its own. A menu cannot.
        public var standsAlone: Bool
        /// The title bar that macOS hangs on a window in full screen: a part of that window, and no card.
        public var isBar: Bool

        public init(isFleet: Bool, hangs: Bool, standsAlone: Bool, isBar: Bool = false) {
            self.isFleet = isFleet
            self.hangs = hangs
            self.standsAlone = standsAlone
            self.isBar = isBar
        }
    }

    /// The class of the full screen's title bar, by its name in AppKit (it is no public class). Under another name
    /// the bar counts as a card and an agent does not look in full screen: wrong, and on the safe side.
    public static let barClass = "NSToolbarFullScreenWindow"

    /// **The answer for the windows that show.** `modal`: the app runs a modal session (an alert, a panel that
    /// stops the app). A window that hangs, or that cannot stand alone (a menu), is a card, also over the second
    /// window. A window that is not the fleet's and stands alone is "another window". The full screen's bar counts
    /// as nothing.
    public static func of(_ windows: [Shown], modal: Bool) -> AppOver {
        let counted = windows.filter { !$0.isBar }
        if modal || counted.contains(where: { $0.hangs || !$0.standsAlone }) { return .card }
        return counted.contains { !$0.isFleet } ? .window : .nothing
    }
}

/// **The page that each wizard of the app shows now**, by its fixed name, as the views tell the store (`FleetStore`'s
/// `wizardPages`). The page of Add server, of Add agent, of an agent's setup and of a sign-in lives in its view, so each
/// view writes its own value when its page changes and clears it when it goes. The place of the window
/// (`AppPlace`) reads a value only for the destination that draws that view.
///
/// **A view clears only the value that it wrote.** When a new view of a wizard takes the place of an old one, SwiftUI
/// does not say which comes first, the new view's first page or the old view's going: a clear with no owner could
/// erase the page of the view that shows. So each view tells its page with a mark of its own (`tell`), and `gone`
/// clears a value only for the view that wrote it.
public struct WizardPages: Equatable, Sendable {
    public private(set) var addServer: AppPlace.AddServerPage?
    public private(set) var addAgent: AppPlace.AddAgentStep?
    /// The agent whose setup shows, and its page.
    public private(set) var agentSetup: AgentPage<AppPlace.SetupPage>?
    /// The agent whose sign-in shows, and its page.
    public private(set) var signIn: AgentPage<AppPlace.SignInPage>?
    /// The view that wrote each value, by its own mark.
    private var writers: [Kind: UUID] = [:]
    private enum Kind: Hashable, Sendable { case addServer, addAgent, agentSetup, signIn }

    public mutating func tell(addServer page: AppPlace.AddServerPage?, by view: UUID) {
        addServer = page; writers[.addServer] = view
    }
    public mutating func tell(addAgent step: AppPlace.AddAgentStep?, by view: UUID) {
        addAgent = step; writers[.addAgent] = view
    }
    public mutating func tell(agentSetup page: AgentPage<AppPlace.SetupPage>?, by view: UUID) {
        agentSetup = page; writers[.agentSetup] = view
    }
    public mutating func tell(signIn page: AgentPage<AppPlace.SignInPage>?, by view: UUID) {
        signIn = page; writers[.signIn] = view
    }

    /// The view went: each value that it wrote is cleared, and no other.
    public mutating func gone(_ view: UUID) {
        if writers[.addServer] == view { addServer = nil; writers[.addServer] = nil }
        if writers[.addAgent] == view { addAgent = nil; writers[.addAgent] = nil }
        if writers[.agentSetup] == view { agentSetup = nil; writers[.agentSetup] = nil }
        if writers[.signIn] == view { signIn = nil; writers[.signIn] = nil }
    }

    public struct AgentPage<Page: Equatable & Sendable>: Equatable, Sendable {
        public var agent: String
        public var page: Page

        public init(agent: String, page: Page) {
            self.agent = agent
            self.page = page
        }
    }

    public init(addServer: AppPlace.AddServerPage? = nil, addAgent: AppPlace.AddAgentStep? = nil,
                agentSetup: AgentPage<AppPlace.SetupPage>? = nil, signIn: AgentPage<AppPlace.SignInPage>? = nil) {
        self.addServer = addServer
        self.addAgent = addAgent
        self.agentSetup = agentSetup
        self.signIn = signIn
    }

    /// The page of this agent's setup, when its view told one.
    public func setup(of agent: String) -> AppPlace.SetupPage? { agentSetup?.agent == agent ? agentSetup?.page : nil }
    /// The page of this agent's sign-in, when its view told one.
    public func signIn(of agent: String) -> AppPlace.SignInPage? { signIn?.agent == agent ? signIn?.page : nil }
}
