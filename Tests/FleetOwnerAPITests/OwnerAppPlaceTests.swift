import Foundation
import Testing
@testable import FleetOwnerAPI

/// **The place of the app's window by a fixed name** (`AppPlace`): each name builds and reads back, a name part out of
/// its alphabet is left out, no name carries free text, the window's rule of what covers a destination, the places of
/// a fleet, and the lists against the app's own types (read from its source: the app has no test target).
struct OwnerAppPlaceTests {
    /// One place of each form, with example names.
    static let every: [AppPlace] = {
        var places: [AppPlace] = [.needs, .tasks, .agents, .task(0), .task(42), .agent("nova"), .agentRule("nova"),
                                  .agentSetup("nova", nil), .agentSettingUp("nova"), .agentSignIn("nova", nil),
                                  .server("fleet-1"), .addServer(nil), .addAgent(nil), .connectKey, .shapeChange,
                                  .firstRun(nil),
                                  .waiting, .none, .someAgent, .someServer, .someTask]
        places += AppPlace.AgentPart.allCases.map { .agentPart("nova", $0) }
        places += AppPlace.SetupPage.allCases.map { .agentSetup("nova", $0) }
        places += AppPlace.SignInPage.allCases.map { .agentSignIn("fleet-1", $0) }
        places += AppPlace.SettingsPage.allCases.map(AppPlace.settings) + AppPlace.AppGroup.allCases.map(AppPlace.app)
        places += AppPlace.AddServerPage.allCases.map { .addServer($0) }
        places += AppPlace.AddAgentStep.allCases.map { .addAgent($0) }
        places += FirstRunPage.allCases.map { .firstRun($0) }
        return places
    }()

    @Test func eachNameBuildsAndReadsBack() {
        let names = Self.every.map(\.name)
        #expect(Set(names).count == names.count, "two places with one name")
        for place in Self.every { #expect(AppPlace(name: place.name) == place, "\(place.name)") }
        #expect(AppPlace.agentSetup("nova", .signIn).name == "agent.nova.setup.sign_in")
        #expect(AppPlace.agentPart("nova", .canUse).name == "agent.nova.can_use")
        #expect(AppPlace.agentSettingUp("nova").name == "agent.nova.setting_up")
        #expect(AppPlace.task(42).name == "task.42")
        #expect(AppPlace.firstRun(.tailscaleKey).name == "first_run.tailscale_key")
        for name in AppPlace.fixedNames { #expect(AppPlace(name: name)?.name == name, "\(name)") }
        #expect(AppPlace.fixedNames.count == Set(AppPlace.fixedNames).count)
        #expect(!AppPlace.fixedNames.contains { $0.hasPrefix("agent.") || $0.hasPrefix("server.") || $0.hasPrefix("task.") })
    }

    /// **A name part out of its alphabet is left out**: a capital, a space, a dot, a slash, a single character or 32
    /// characters. The name then says the kind alone, and the reader refuses such a text.
    @Test func aNamePartOutOfItsAlphabetIsLeftOut() {
        let bad = ["Nova", "no va", "no.va", "no/va", "n", String(repeating: "a", count: 32), "1nova", "-nova", "nov@",
                   "", "nováa", "nova\n"]
        for name in bad {
            #expect(!AppPlace.isName(name), "\(name)")
            #expect(AppPlace.agent(name).name == "agent")
            #expect(AppPlace.agentSetup(name, .provider).name == "agent")
            #expect(AppPlace.agentPart(name, .people).name == "agent")
            #expect(AppPlace.agentSignIn(name, .code).name == "agent")
            #expect(AppPlace.server(name).name == "server")
            #expect(AppPlace(name: "agent.\(name)") == nil, "agent.\(name)")
            #expect(AppPlace(name: "server.\(name)") == nil)
        }
        #expect(AppPlace.isName("nova") && AppPlace.isName("fleet-1") && AppPlace.isName(String(repeating: "a", count: 31)))
        #expect(AppPlace.task(-1).name == "task")
        for text in ["agent.nova.secrets", "agent.nova.rule.3", "agent.nova.setup.token", "settings.devices",
                     "app.slack", "task.-4", "task.+4", "task.4a", "needs.x", "add_server.vps.1", "first_run.other",
                     "agent..rule", "agent.nova.", ".needs", "Needs", "http://example.com", "connect_key.1"] {
            #expect(AppPlace(name: text) == nil, "\(text)")
        }
    }

    /// **No name can carry free text**: every name is made of small letters, digits, "_", "-" and "." only, and each
    /// part between dots is a word of a closed list, a name in its alphabet, or a number.
    @Test func noNameCarriesFreeText() throws {
        let alphabet = try NSRegularExpression(pattern: "^[a-z0-9_.-]+$")
        let words = Set(["needs", "tasks", "agents", "task", "agent", "rule", "setup", "setting_up", "sign_in", "settings",
                         "app", "server", "add_server", "add_agent", "connect_key", "shape_change", "first_run", "waiting",
                         "none"]
            + AppPlace.AgentPart.allCases.map(\.rawValue) + AppPlace.SetupPage.allCases.map(\.rawValue)
            + AppPlace.SignInPage.allCases.map(\.rawValue) + AppPlace.SettingsPage.allCases.map(\.rawValue)
            + AppPlace.AppGroup.allCases.map(\.rawValue) + AppPlace.AddServerPage.allCases.map(\.rawValue)
            + AppPlace.AddAgentStep.allCases.map(\.rawValue) + FirstRunPage.allCases.map(\.rawValue))
        // Texts out of the alphabet. A text in it ("sk-example-1") passes as a name, as the agent's name in
        // `fleet_overview` does: the alphabet is the bound, not a check of meaning.
        let hostile = ["Example Person", "203.0.113.9", "a/b", "x.y", "token=abc", "sk_example"]
        let places = Self.every + hostile.flatMap { [AppPlace.agent($0), .server($0), .agentSetup($0, .server)] }
        for place in places {
            let name = place.name
            #expect(alphabet.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil, "\(name)")
            for part in name.split(separator: ".").map(String.init) {
                #expect(words.contains(part) || AppPlace.isName(part) || Int(part) != nil, "\(part) of \(name)")
                #expect(!hostile.contains(part))
            }
        }
    }

    /// **What the window draws over its destination**, in `FleetView`'s order.
    @Test func theWindowSaysWhatCoversTheDestination() {
        func window(launched: Bool = true, reading: Bool = true, before: Bool = true, holds: Bool = false,
                    covers: Bool = false, settings: Bool = false, page: FirstRunPage? = nil) -> WindowFacts {
            WindowFacts(launched: launched, hasReading: reading, answeredBefore: before, firstRunHolds: holds,
                        welcomeCovers: covers, settings: settings, firstRunPage: page)
        }
        let chat = AppPlace.agent("nova")
        #expect(AppPlace.shows(window(), destination: chat) == chat)
        // The moment before the launch's first read: the background only.
        #expect(AppPlace.shows(window(launched: false, reading: false), destination: chat) == .none)
        #expect(AppPlace.shows(window(launched: false), destination: chat) == chat)
        // No hub that answered: the first run, over every destination but a place of Settings.
        #expect(AppPlace.shows(window(reading: false, before: false, page: .vps), destination: chat) == .firstRun(.vps))
        #expect(AppPlace.shows(window(reading: false, before: false, settings: true), destination: .settings(.status))
                == .settings(.status))
        // The first run holds the window after its hub answered.
        #expect(AppPlace.shows(window(holds: true, page: .done), destination: chat) == .firstRun(.done))
        #expect(AppPlace.shows(window(holds: true, settings: true), destination: .server("fleet-1")) == .server("fleet-1"))
        // The welcome page in front of an unfinished setup, also over a page of Settings.
        #expect(AppPlace.shows(window(covers: true, page: .welcome), destination: chat) == .firstRun(.welcome))
        // A hub that answered before, with no reading now: the waiting page.
        #expect(AppPlace.shows(window(reading: false), destination: .tasks) == .waiting)
        #expect(AppPlace.shows(window(reading: false, settings: true), destination: .settings(.general))
                == .settings(.general))
    }

    /// **The places of a fleet follow its features**, in a fixed order, and without a reading only Settings counts.
    @Test func thePlacesFollowTheFeatures() {
        #expect(AppPlace.places(hasReading: false, settings: [.status, .general, .backup], apps: [.github], canAdd: true).map(\.name)
                == ["settings.general", "settings.backup", "settings.status"])
        #expect(AppPlace.places(hasReading: true, settings: [.team, .general], apps: [.mcp, .drive], canAdd: true).map(\.name)
                == ["needs", "tasks", "agents", "settings.general", "settings.team", "app.drive", "app.mcp",
                    "add_server", "add_agent"])
        let all = AppPlace.places(hasReading: true, settings: AppPlace.SettingsPage.allCases,
                                  apps: AppPlace.AppGroup.allCases, canAdd: true)
        #expect(all.count == 3 + 10 + 4 + 2)      // ten sections of Settings since Help came (16 November 2026)
        // A hub that cannot add a server or an agent (no feature servers) offers neither, and its list has neither.
        #expect(AppPlace.places(hasReading: true, settings: [.general], apps: [], canAdd: false).map(\.name)
                == ["needs", "tasks", "agents", "settings.general"])
        for place in all { #expect(AppPlace.fixedNames.contains(place.name)) }
    }

    /// The wizards' pages are read only for their own agent.
    @Test func aWizardPageIsOnlyItsAgents() {
        let pages = WizardPages(agentSetup: .init(agent: "nova", page: .provider), signIn: .init(agent: "nova", page: .code))
        #expect(pages.setup(of: "nova") == .provider && pages.setup(of: "juno") == nil)
        #expect(pages.signIn(of: "nova") == .code && pages.signIn(of: "juno") == nil)
    }

    // ------------------------------------------------------------ the lists, against the app

    static func source(_ path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(path)
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The case names of the first `case` line after `start` (one line of cases, as these enums have).
    static func cases(_ path: String, after start: String) throws -> [String] {
        let text = try source(path)
        let begin = try #require(text.range(of: start))
        let rest = text[begin.upperBound...]
        let line = try #require(rest.split(separator: "\n").first { $0.contains("case ") })
        let body = line.components(separatedBy: "case ").last ?? ""
        return body.replacingOccurrences(of: "}", with: "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).components(separatedBy: CharacterSet(charactersIn: "(="))[0]
                .trimmingCharacters(in: .whitespaces)
        }
    }

    @Test func theListsAreTheAppsOwn() throws {
        #expect(try Self.cases("Sources/Founderizer/SettingsPage.swift", after: "enum SettingsTab")
                == AppPlace.SettingsPage.allCases.map(\.rawValue))
        #expect(try Self.cases("Sources/Founderizer/AppsSettings.swift", after: "enum AppsGroup")
                == AppPlace.AppGroup.allCases.map(\.rawValue))
        #expect(try Self.cases("Sources/Founderizer/AddMachineView.swift", after: "private enum Page")
                == AppPlace.AddServerPage.allCases.map(\.rawValue))
        #expect(try Self.cases("Sources/Founderizer/SignInWizard.swift", after: "private enum Page")
                == AppPlace.SignInPage.allCases.map(\.rawValue))
        // `AgentTab`: its `chat` is the agent's chat, and its `settings` is Runs on.
        #expect(try Self.cases("Sources/Founderizer/AgentPage.swift", after: "enum AgentTab")
                == ["settings", "capabilities", "chat", "behaviour", "tasks", "people", "canUse"])
        // `AgentSetupPage` in FleetCore, one case on each line.
        let flow = try Self.source("Sources/FleetCore/AgentSetupFlow.swift")
        let begin = try #require(flow.range(of: "public enum AgentSetupPage"))
        let end = try #require(flow.range(of: "\n}\n", range: begin.upperBound..<flow.endIndex))
        let body = String(flow[begin.upperBound..<end.lowerBound])
        let pattern = try NSRegularExpression(pattern: #"^\s*case (\w+)"#, options: .anchorsMatchLines)
        let setup = pattern.matches(in: body, range: NSRange(body.startIndex..., in: body))
            .map { (body as NSString).substring(with: $0.range(at: 1)) }
        #expect(setup == ["name", "servers", "server", "provider", "installing", "switching", "signIn", "activate"])
        #expect(AppPlace.SetupPage.allCases.map(\.rawValue)
                == ["name", "servers", "server", "provider", "installing", "switching", "sign_in", "activate"])
    }

    /// **The server page of an agent's setup draws Add server inside it**, where a provider's token, a Tailscale key
    /// and a password are typed: the place names that inner page, so that it never reads as the plain server page.
    @Test func theSetupsServerPageNamesTheAddServerPageInsideIt() {
        for page in AppPlace.AddServerPage.allCases {
            let place = AppPlace.agentSetupServer("nova", page)
            #expect(place.name == "agent.nova.setup.server.\(page.rawValue)")
            #expect(AppPlace(name: place.name) == place)
        }
        #expect(AppPlace.agentSetupServer("Nova Agent", .token).name == "agent")
        #expect(AppPlace(name: "agent.nova.setup.server.none") == nil)
        #expect(AppPlace(name: "agent.nova.setup.provider.token") == nil)
        #expect(AppPlace(name: "agent.nova.setup.server.token.more") == nil)
    }

    /// **A view clears only the page that it wrote**: when a new view of a wizard tells its page before the old one
    /// goes, the old one's going does not erase the new page.
    @Test func aViewThatGoesClearsOnlyItsOwnPage() {
        let old = UUID(), new = UUID()
        var pages = WizardPages()
        pages.tell(addServer: .token, by: old)
        pages.tell(addServer: .ways, by: new)                   // the new view's first page
        pages.gone(old)                                         // the old view goes after it
        #expect(pages.addServer == .ways)
        pages.gone(new)
        #expect(pages.addServer == nil)
        // The other order: the old view goes first, then the new one tells its page.
        pages.tell(addServer: .token, by: old)
        pages.gone(old)
        #expect(pages.addServer == nil)
        pages.tell(addServer: .ways, by: new)
        #expect(pages.addServer == .ways)
        // One view's going leaves the pages of the other wizards.
        pages.tell(signIn: .init(agent: "nova", page: .code), by: old)
        pages.tell(agentSetup: .init(agent: "nova", page: .server), by: old)
        pages.tell(addAgent: .name, by: new)
        pages.gone(old)
        #expect(pages.signIn == nil && pages.agentSetup == nil && pages.addAgent == .name && pages.addServer == .ways)
    }

    /// **One text for one task**: no zero in front, at most 18 digits, and a number above that gives the kind alone.
    @Test func aTasksNumberHasOneText() {
        #expect(AppPlace(name: "task.7") == .task(7))
        #expect(AppPlace(name: "task.007") == nil && AppPlace(name: "task.0") == .task(0))
        #expect(AppPlace.task(999_999_999_999_999_999).name == "task.999999999999999999")
        #expect(AppPlace(name: "task.999999999999999999") == .task(999_999_999_999_999_999))
        #expect(AppPlace.task(1_000_000_000_000_000_000).name == "task" && AppPlace.task(-1).name == "task")
    }

    /// **What stands over the page** (`setup_state`'s `over`): a window that hangs, a window that cannot stand alone
    /// (a menu) or a modal session is a card, also over the second window; another window that stands alone is a
    /// window; the fleet's own window and the title bar of full screen are nothing. The four kinds are the ones
    /// measured in the real app on 15 November 2026.
    @Test func whatStandsOverThePage() {
        typealias Shown = AppOver.Shown
        let fleet = Shown(isFleet: true, hangs: false, standsAlone: true)
        let report = Shown(isFleet: false, hangs: false, standsAlone: true)
        let card = Shown(isFleet: false, hangs: true, standsAlone: false)       // ModalPanel, NSToolTipPanel
        let menu = Shown(isFleet: false, hangs: false, standsAlone: false)      // NSPopupMenuWindow
        let bar = Shown(isFleet: false, hangs: true, standsAlone: false, isBar: true)   // NSToolbarFullScreenWindow
        #expect(AppOver.of([], modal: false) == .nothing)
        #expect(AppOver.of([fleet], modal: false) == .nothing)
        // Full screen: the bar hangs on the window and is no card. Without its mark it is one.
        #expect(AppOver.of([fleet, bar], modal: false) == .nothing)
        #expect(AppOver.of([fleet, Shown(isFleet: false, hangs: true, standsAlone: false)], modal: false) == .card)
        #expect(AppOver.of([fleet, bar, card], modal: false) == .card)
        #expect(AppOver.of([fleet, card], modal: false) == .card)
        #expect(AppOver.of([fleet, menu], modal: false) == .card)
        #expect(AppOver.of([card], modal: false) == .card)
        #expect(AppOver.of([fleet], modal: true) == .card)
        #expect(AppOver.of([], modal: true) == .card)
        #expect(AppOver.of([fleet, report], modal: false) == .window)
        #expect(AppOver.of([fleet, bar, report], modal: false) == .window)
        // Report a problem alone, with the fleet's window closed: the screen shows the owner's text.
        #expect(AppOver.of([report], modal: false) == .window)
        #expect(AppOver.of([fleet, report, card], modal: false) == .card)
        // A window that says it is the fleet's and hangs is a card: no mark of a window makes a card pass.
        #expect(AppOver.of([Shown(isFleet: true, hangs: true, standsAlone: true)], modal: false) == .card)
        // A window whose scene SwiftUI names another way is no fleet window: the answer is the safe one.
        #expect(AppOver.of([Shown(isFleet: false, hangs: false, standsAlone: true)], modal: false) == .window)
        #expect(AppOver.allCases.map(\.rawValue) == ["nothing", "card", "window"])
        #expect(AppOver.barClass == "NSToolbarFullScreenWindow")
    }
}
