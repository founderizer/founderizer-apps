import FleetCore
import Foundation
import Testing
@testable import FleetOwnerAPI

/// **`setup_show` for the fleet's own pages** (the plan "The app's pages and actions for the owner's own agent", part
/// 2): the two closed lists word for word, each rule with its fixed words, the key `show` of `setup_state`, what a
/// show leaves open until the owner acts (one change of page for each act, and no chat marked as read), the window in
/// front, and the tool on the app's side of the link (`SetupBoard`) with a stand-in for the app's change of page.
@MainActor
struct OwnerShowRulesTests {
    /// The facts of a fleet that runs, with the owner on `place`: a reading of the hub, each section of Settings, no
    /// first run, nothing over the page, no request that waits, no show before. The store's own values are known, as
    /// at the second ask.
    static func facts(on place: AppPlace, over: AppOver = .nothing, reading: Bool = true, fills: Bool? = false,
                      holds: Bool? = false, request: Bool? = false, shown: Bool? = false, target: ShowTarget? = .has,
                      sections: [AppPlace.SettingsPage] = AppPlace.SettingsPage.allCases,
                      firstRun: SetupFirstRun = .none, buttonDown: Bool? = false) -> ShowFacts {
        ShowFacts(place: place, firstRun: firstRun, over: over, hasReading: reading, sections: sections,
                  setupFills: fills, firstRunHolds: holds, openRequest: request, shown: shown, target: target,
                  buttonDown: buttonDown)
    }

    static func refusal(_ page: String, from place: AppPlace, seen: String? = nil, _ facts: ShowFacts? = nil) -> String? {
        SetupShow.refusal(page: page, seen: seen ?? place.name, facts: facts ?? Self.facts(on: place))
    }

    /// The places from which the page changes, and one place of each form that `setup_show` opens.
    static let from: [AppPlace] = [.tasks, .agents, .needs]
    static let targets: [AppPlace] = [.needs, .tasks, .agents, .agent("nova"), .settings(.general),
                                      .settings(.status), .task(42), .agentPart("nova", .behaviour),
                                      .agentPart("nova", .tasks), .agentPart("nova", .people),
                                      .agentPart("nova", .canUse), .settings(.secrets), .settings(.knowledge),
                                      .settings(.apps), .settings(.people), .settings(.team)]

    // ------------------------------------------------------------ the two lists

    /// **The list of the places from which the page changes, word for word** (rule 2): Tasks, Agents, and Needs you
    /// while no request waits there. A place that is added to it fails here: its page must be read first for what the
    /// owner can lose there, and a live fleet must prove it.
    @Test func thePageChangesOnlyFromTheseThreePlaces() {
        #expect(SetupShow.fromForms == ["tasks", "agents", "needs"])
        #expect(SetupShow.fromWords == "tasks, agents, and needs while no request waits there")
        for place in Self.from {
            #expect(SetupShow.isFrom(place), "\(place.name)")
            #expect(SetupShow.now(Self.facts(on: place)) == .yes)
        }
        // Every other place of the map is none of them: each form of `OwnerAppPlaceTests.every`.
        for place in OwnerAppPlaceTests.every where !Self.from.contains(place) {
            #expect(!SetupShow.isFrom(place), "\(place.name)")
        }
        // **Off the list in this version**, each for what a change of page loses there: an agent's chat (one text
        // field serves every agent's chat) and the three sections of Settings (a failure line, the state of a run's
        // button, a refused choice with its "Try again").
        for place in [AppPlace.agent("nova"), .settings(.general), .settings(.status)] {
            #expect(!SetupShow.isFrom(place), "\(place.name)")
            #expect(SetupShow.isTarget(place), "\(place.name)")
            #expect(SetupShow.now(Self.facts(on: place)) == .inUse)
        }
    }

    /// **Needs you is a place to change from only while the hub lists no open request**: with one, the owner may be
    /// in the middle of an answer (ticked options, the chosen request, a secret's form). The words do not tell the
    /// owner what to do with the request.
    @Test func needsIsAPlaceToChangeFromOnlyWithNoOpenRequest() {
        let waits = Self.facts(on: .needs, request: true)
        #expect(SetupShow.now(waits) == .inUse)
        #expect(Self.refusal("tasks", from: .needs, waits)
                == "The place that shows now is needs, and a request waits there: the owner may be in the middle of an "
                + "answer, so setup_show changes no page. It changes the page only from these places: tasks, agents, "
                + "and needs while no request waits there.")
        #expect(SetupShow.requestWaits.contains("answer or decline") == false)
        #expect(SetupShow.now(Self.facts(on: .needs, request: false)) == .yes)
        #expect(Self.refusal("tasks", from: .needs, Self.facts(on: .needs, request: false)) == nil)
        // A request that waits holds no change of page from Tasks or Agents.
        for place in [AppPlace.tasks, .agents] {
            #expect(SetupShow.now(Self.facts(on: place, request: true)) == .yes)
            #expect(Self.refusal("needs", from: place, Self.facts(on: place, request: true)) == nil)
        }
        // The first ask does not know it, and lets the ask pass to the app, which asks again with its store.
        #expect(Self.refusal("tasks", from: .needs, Self.facts(on: .needs, request: nil)) == nil)
    }

    /// **The list of the places that `setup_show` opens, word for word** (rule 3). A place that is added to it fails
    /// here: its page's code must be read first for what it does by itself when it shows.
    @Test func itOpensOnlyTheseSixteenPlaces() {
        #expect(SetupShow.targetForms == ["needs", "tasks", "agents", "agent.<name>", "settings.general",
                                          "settings.status", "task.<number>",
                                          "agent.<name>.behaviour", "agent.<name>.tasks", "agent.<name>.people",
                                          "agent.<name>.can_use", "settings.secrets", "settings.knowledge",
                                          "settings.apps", "settings.people", "settings.team"])
        #expect(Self.targets.count == SetupShow.targetForms.count)
        #expect(Self.targets.map(SetupShow.form(of:)) == SetupShow.targetForms)
        for place in Self.targets { #expect(SetupShow.isTarget(place), "\(place.name)") }
        // Each place from which the page changes is a place that it opens.
        for form in SetupShow.fromForms { #expect(SetupShow.targetForms.contains(form)) }
        // Every other place of the map is no target.
        for place in OwnerAppPlaceTests.every where !Self.targets.contains(place) && place != .task(0) {
            #expect(!SetupShow.isTarget(place), "\(place.name)")
        }
    }

    /// **Left out, and never a target** (rules 3 and 4): the three pages that can act by themselves when they show
    /// or that were not decided, and each place of the plan's rule 4, with each page of an agent's setup (the
    /// manager's `name` and `servers` too) and the later change of the fleet's shape. Each is refused with the same
    /// fixed words, also with every other fact in order.
    @Test func thesePlacesAreNeverOpened() {
        var never: [AppPlace] = [.agentPart("nova", .runsOn), .agentPart("nova", .capabilities), .settings(.servers),
                                 .settings(.backup),
                                 .addServer(nil), .addAgent(nil), .shapeChange, .connectKey, .server("fleet-1"),
                                 .agentRule("nova"), .agentSetup("nova", nil), .agentSetup("nova", .name),
                                 .agentSetup("nova", .servers), .agentSettingUp("nova"), .agentSignIn("nova", nil)]
        never += AppPlace.AddServerPage.allCases.map { .addServer($0) }
        never += AppPlace.AddAgentStep.allCases.map { .addAgent($0) }
        never += AppPlace.AppGroup.allCases.map(AppPlace.app)
        never += AppPlace.SetupPage.allCases.map { .agentSetup("nova", $0) }
        never += AppPlace.AddServerPage.allCases.map { .agentSetupServer("nova", $0) }
        never += AppPlace.SignInPage.allCases.map { .agentSignIn("nova", $0) }
        for place in never {
            #expect(!SetupShow.isTarget(place), "\(place.name)")
            #expect(Self.refusal(place.name, from: .tasks)
                    == "setup_show does not open \(place.name): only the owner opens that page, because it can act by "
                    + "itself when it shows or the owner works on it. It opens these places: "
                    + SetupShow.targetForms.joined(separator: ", ") + ".", "\(place.name)")
        }
        // A page of the first run is asked for by its own two words.
        for page in FirstRunPage.allCases {
            #expect(Self.refusal("first_run." + page.rawValue, from: .tasks)
                    == "For a page of the first run, page is welcome or name, not a place.")
        }
        #expect(Self.refusal("first_run", from: .tasks) == SetupShow.firstRunPlace)
        // What is no page: the waiting page, nothing, and the kind alone of a place.
        for name in ["waiting", "none", "agent", "server", "task"] {
            #expect(Self.refusal(name, from: .tasks) == SetupShow.pageWords)
        }
    }

    /// **The form of a place says nothing of an agent, a server or a task**: one form for every name and number.
    @Test func theFormOfAPlaceHasNoName() {
        #expect(SetupShow.form(of: .agent("nova")) == "agent.<name>" && SetupShow.form(of: .agent("juno")) == "agent.<name>")
        #expect(SetupShow.form(of: .task(7)) == "task.<number>" && SetupShow.form(of: .server("fleet-1")) == "server.<name>")
        #expect(SetupShow.form(of: .agentSetup("nova", .signIn)) == "agent.<name>.setup.sign_in")
        #expect(SetupShow.form(of: .agentSetupServer("nova", .token)) == "agent.<name>.setup.server.token")
        #expect(SetupShow.form(of: .agentSignIn("nova", .code)) == "agent.<name>.sign_in.code")
        #expect(SetupShow.form(of: .agentSettingUp("nova")) == "agent.<name>.setting_up")
        #expect(SetupShow.form(of: .agentRule("nova")) == "agent.<name>.rule")
        for place in OwnerAppPlaceTests.every {
            let form = SetupShow.form(of: place)
            #expect(!form.contains("nova") && !form.contains("fleet-1") && !form.contains("42"), "\(form)")
        }
        // A name out of its alphabet has the same form, and its place's own name is the kind alone.
        #expect(SetupShow.form(of: .agent("Example Agent")) == "agent.<name>" && AppPlace.agent("Example Agent").name == "agent")
    }

    // ------------------------------------------------------------ the rules, each with its words

    /// **Rule 1: `seen` must be the place that shows now.** For a place, only the place's own name passes: not the
    /// short form of the first run's pages, and not `none`. The refusal says nothing back of what the caller sent.
    @Test func seenMustBeThePlaceThatShowsNow() {
        #expect(Self.refusal("agents", from: .tasks) == nil)
        let words = "The place that shows now is tasks, and seen names another one. Read setup_state again, and call "
            + "setup_show with seen tasks if the owner should still see another page."
        for seen in ["agents", "none", "", "task", "Tasks", "tasks ", "first_run.welcome", "sk-example-1 secret"] {
            #expect(Self.refusal("agents", from: .tasks, seen: seen) == words, "\(seen)")
        }
        // A place with a name: by its whole name, also where the page does not change from it.
        #expect(Self.refusal("tasks", from: .agent("nova"), seen: "agent.juno")?.hasPrefix("The place that shows now is agent.nova, ") == true)
        #expect(Self.refusal("tasks", from: .agent("nova"), seen: "agent.nova")?.hasPrefix("setup_show changes the page only from") == true)
        // The chat of an agent whose name is out of its alphabet: the place is `agent`, and no name is said.
        for seen in ["agent", "agent.nova"] {
            let words = try! #require(Self.refusal("tasks", from: .agent("Example Agent"), seen: seen))
            #expect(!words.contains("Example"))
        }
    }

    /// **Rule 2: from the closed list only.** From each other place the answer says so, with the list and with the
    /// reason for the rule, and makes no claim about the page that shows.
    @Test func fromEachOtherPlaceItRefusesAndSaysWhy() {
        for place in [AppPlace.agent("nova"), .settings(.general), .settings(.status), .task(42),
                      .agentPart("nova", .behaviour), .agentPart("nova", .runsOn), .agentRule("nova"),
                      .agentSetup("nova", .provider), .agentSettingUp("nova"), .agentSignIn("nova", .code),
                      .settings(.servers), .settings(.secrets), .settings(.backup), .settings(.knowledge),
                      .settings(.apps), .settings(.people), .settings(.team), .app(.github), .server("fleet-1"),
                      .connectKey, .someAgent, .someTask, .someServer] {
            #expect(Self.refusal("tasks", from: place)
                    == "setup_show changes the page only from these places: tasks, agents, and needs while no request "
                    + "waits there, because on every other place the owner can be in the middle of typing or of work. "
                    + "The place that shows now is \(place.name).", "\(place.name)")
            #expect(SetupShow.now(Self.facts(on: place)) == .inUse)
        }
        // From each place of the list, to each place that it opens.
        let to = ["needs", "tasks", "agents", "agent.juno", "task.42", "agent.juno.behaviour", "agent.juno.tasks",
                  "agent.juno.people", "agent.juno.can_use", "settings.general", "settings.status",
                  "settings.secrets", "settings.knowledge", "settings.apps", "settings.people", "settings.team"]
        #expect(to.count == SetupShow.targetForms.count)
        for place in Self.from {
            for page in to { #expect(Self.refusal(page, from: place) == nil, "\(place.name) to \(page)") }
        }
    }

    /// **Rule 5: never while the first run shows or holds the window, a setup fills the window, or the app has no
    /// reading of the hub.** A first run that holds the window behind a page of Settings is the first run, with words
    /// of its own.
    @Test func neverInAFirstRunASetupOrWithNoReading() {
        // The first run, by the window's place or by its own page; its welcome page in front of a setup too.
        for (place, firstRun) in [(AppPlace.firstRun(.welcome), OwnerSetupBoardTests.page(.welcome)),
                                  (.firstRun(nil), SetupFirstRun.none), (.tasks, OwnerSetupBoardTests.page(.vps))] {
            let facts = Self.facts(on: place, firstRun: firstRun)
            #expect(SetupShow.now(facts) == .firstRun)
            #expect(Self.refusal("tasks", from: place, facts)
                    == "The first run shows (the place is \(place.name)), so setup_show opens no page of the fleet. "
                    + "There, page is front, welcome or name.")
        }
        // The first run holds the window, and the owner opened a page of Settings over it.
        for place in [AppPlace.settings(.general), .settings(.status), .settings(.secrets)] {
            let facts = Self.facts(on: place, fills: true, holds: true)
            #expect(SetupShow.now(facts) == .firstRun)
            #expect(Self.refusal("tasks", from: place, facts)
                    == "The first run holds the app's window, behind the page of Settings that shows now (the place is "
                    + "\(place.name)), so setup_show opens no page of the fleet. setup_show with page front still asks "
                    + "macOS to bring the app to the front.")
        }
        // No reading of the hub: the waiting page, nothing yet, and a section of Settings that shows without one.
        for place in [AppPlace.waiting, .none, .settings(.general), .settings(.status)] {
            let facts = Self.facts(on: place, reading: false)
            #expect(SetupShow.now(facts) == .noReading)
            #expect(Self.refusal("settings.status", from: place, facts)
                    == "The app has no reading of the hub (the place is \(place.name)), so setup_show opens no page "
                    + "of the fleet. Read setup_diagnosis for the reason. setup_show with page front still asks macOS "
                    + "to bring the app to the front.")
        }
        // A setup fills the window: Add server, Add agent, a change of the fleet's shape, by the place alone; the
        // setup of an agent that is being added, or of a new fleet's manager, by the store's own word.
        for place in [AppPlace.addServer(.ways), .addServer(nil), .addAgent(.name), .shapeChange] {
            for fills in [true, nil] {
                let facts = Self.facts(on: place, fills: fills)
                #expect(SetupShow.now(facts) == .setup)
                #expect(Self.refusal("tasks", from: place, facts)
                        == "A setup fills the app's window (the place is \(place.name)), and the owner is in the "
                        + "middle of it, so setup_show changes no page. The owner ends that setup or closes it.")
            }
        }
        for place in [AppPlace.agentSetup("nova", .provider), .agentSetup("nova", .name), .agentSettingUp("nova")] {
            #expect(SetupShow.now(Self.facts(on: place, fills: true)) == .setup)
            #expect(Self.refusal("tasks", from: place, Self.facts(on: place, fills: true))?
                .hasPrefix("A setup fills the app's window (the place is \(place.name))") == true)
        }
        // An agent's setup that stands in its page, and does not fill the window, is a place of work.
        #expect(SetupShow.now(Self.facts(on: .agentSetup("nova", .provider), fills: false)) == .inUse)
        #expect(SetupShow.now(Self.facts(on: .agentSetup("nova", .provider), fills: nil)) == .inUse)
    }

    /// **One change of page for each click of the owner that reaches the app**: after a show that changed the page,
    /// the next one is refused until such a click. The words say which click that is, and that a key ends nothing.
    /// `front`, which changes no page, passes.
    @Test func oneChangeOfPageForEachClickOfTheOwnerThatReaches() {
        for place in Self.from + [.agent("nova"), .settings(.secrets)] {
            let facts = Self.facts(on: place, shown: true)
            #expect(SetupShow.now(facts) == .shown)
            #expect(Self.refusal("agents", from: place, facts)
                    == "setup_show changed the page already (the place is \(place.name)), and no click of the owner "
                    + "reached the app's main window since, so it changes no page again: one change of page for each "
                    + "click of the owner that reaches the app. After a change of page the app drops one click of the "
                    + "owner. The next click that reaches the app ends this (a click on a text field, a switch or a "
                    + "slider can pass unseen, and then the next one counts); a key does not. Say the page in words. "
                    + "setup_show with page front still asks macOS to bring the app to the front.")
            // Also for the place that shows already.
            #expect(Self.refusal(place.name, from: place, facts) == SetupShow.shownAlready(place.name))
            #expect(Self.refusal("front", from: place, facts) == nil)
        }
        // When the owner acted, the place alone decides again; the first ask does not know it.
        #expect(Self.refusal("agents", from: .tasks, Self.facts(on: .tasks, shown: false)) == nil)
        #expect(Self.refusal("agents", from: .tasks, Self.facts(on: .tasks, shown: nil)) == nil)
    }

    /// **Rule 8: never while a card, a panel or a menu is open over the page.** A second window of the app holds no
    /// change of page.
    @Test func neverUnderACard() {
        let facts = Self.facts(on: .tasks, over: .card)
        #expect(SetupShow.now(facts) == .card)
        #expect(Self.refusal("agents", from: .tasks, facts)
                == "A card, a panel or a menu of the app is open over the page (over is card), and the owner is in the "
                + "middle of it, so setup_show changes no page under it. Call setup_state with after to wait for the "
                + "next change.")
        #expect(SetupShow.now(Self.facts(on: .tasks, over: .window)) == .yes)
        #expect(Self.refusal("agents", from: .tasks, Self.facts(on: .tasks, over: .window)) == nil)
        // front changes no page and passes, as before.
        #expect(Self.refusal("front", from: .tasks, facts) == nil)
    }

    /// **Rule 6: a place that this fleet does not have is refused, in words**, and **rule 4: no place of an agent
    /// whose setup, "Setting up" or sign-in would show**. The store says both, right before the page changes. The
    /// words for a part that an agent does not have say which role has which part, and a next step that works.
    @Test func aPlaceThatTheFleetDoesNotHaveIsRefused() {
        #expect(Self.refusal("agent.juno", from: .tasks, Self.facts(on: .tasks, target: .missing))
                == "This fleet has no such agent (agent.juno): the hub does not list it. fleet_overview gives the agents.")
        #expect(Self.refusal("agent.juno.people", from: .tasks, Self.facts(on: .tasks, target: .missing))
                == "This fleet has no such agent (agent.juno.people): the hub does not list it. fleet_overview gives "
                + "the agents.")
        #expect(Self.refusal("task.42", from: .tasks, Self.facts(on: .tasks, target: .missing))
                == "This fleet has no such task (task.42): the hub does not list it. fleet_overview gives the open tasks.")
        #expect(Self.refusal("agent.juno.can_use", from: .tasks, Self.facts(on: .tasks, target: .noPart))
                == "That agent has no such part on this hub (agent.juno.can_use): tasks and can_use are parts of a "
                + "worker or a lead, and the manager has neither; each part also needs a hub that offers it. Say the "
                + "page in words, or offer the owner another place.")
        for page in ["agent.juno", "agent.juno.behaviour", "agent.juno.tasks", "agent.juno.people", "agent.juno.can_use"] {
            #expect(Self.refusal(page, from: .tasks, Self.facts(on: .tasks, target: .inSetup))
                    == "The app shows that agent's setup, its \"Setting up\" or its sign-in in place of its pages "
                    + "(\(page)): the agent is not set up, not ready or signed out. setup_show opens no place of such "
                    + "an agent.")
        }
        // A section that Settings does not offer for this hub: known from the places at the first ask too.
        for target in [ShowTarget.has, nil] {
            #expect(Self.refusal("settings.knowledge", from: .tasks,
                                 Self.facts(on: .tasks, target: target, sections: [.general, .backup, .status]))
                    == "Settings has no such section for this hub (settings.knowledge). setup_state gives the sections "
                    + "that it has in places.")
        }
        // The first ask knows nothing of an agent or a task, and lets the ask pass to the app.
        #expect(Self.refusal("agent.juno", from: .tasks, Self.facts(on: .tasks, target: nil)) == nil)
        #expect(Self.refusal("task.42", from: .tasks, Self.facts(on: .tasks, target: nil)) == nil)
        #expect(SetupShow.wouldShowAnother("agent.juno")
                == "The app would show another page than agent.juno now, so setup_show changed nothing. Read "
                + "setup_state again.")
    }

    /// **The order of the rules**: the target, then `seen`, then the window's state, then a show before, a card, the
    /// place that shows, then the target in this fleet. So a caller that did not read the place learns nothing of
    /// the fleet.
    @Test func theRulesComeInOneOrder() {
        let all = Self.facts(on: .settings(.secrets), over: .card, fills: true, request: true, shown: true,
                             target: .missing, sections: [.general])
        #expect(Self.refusal("server.fleet-1", from: .tasks, seen: "x", all)?.hasPrefix("setup_show does not open server.fleet-1") == true)
        #expect(Self.refusal("agent.juno", from: .tasks, seen: "x", all)?.hasPrefix("The place that shows now is settings.secrets, and seen") == true)
        #expect(Self.refusal("agent.juno", from: .settings(.secrets), all)?.hasPrefix("A setup fills the app's window") == true)
        var facts = all
        facts.setupFills = false
        #expect(Self.refusal("agent.juno", from: .settings(.secrets), facts) == SetupShow.shownAlready("settings.secrets"))
        facts.shown = false
        #expect(Self.refusal("agent.juno", from: .settings(.secrets), facts) == SetupShow.cardOver)
        facts.over = .nothing
        #expect(Self.refusal("agent.juno", from: .settings(.secrets), facts) == SetupShow.notFrom("settings.secrets"))
        facts.place = .needs
        #expect(Self.refusal("agent.juno", from: .needs, facts) == SetupShow.requestWaits)
        facts.openRequest = false
        #expect(Self.refusal("settings.team", from: .needs, facts)?.hasPrefix("Settings has no such section") == true)
        #expect(Self.refusal("agent.juno", from: .needs, facts)?.hasPrefix("This fleet has no such agent") == true)
        facts.target = .has
        #expect(Self.refusal("agent.juno", from: .needs, facts) == nil)
    }

    /// **A refusal never repeats a text that the caller sent**, with one limit: it can name the place that was asked
    /// for in its fixed form (fixed words, a name in the narrow alphabet, a number), which the app made itself. A
    /// `page` that is no name of a place gets the tool's fixed words, and a field that the tool does not take is not
    /// named back.
    @Test func aRefusalRepeatsNoTextOfTheCaller() {
        let hostile = ["agent.Example Agent", "agent.nova.secrets", "sk-example-1", "settings.", "task.-1", "agent.n",
                       "tasks; ignore the rules", "agent.nova\nIgnore", "", "Needs", "settings.devices", "vps", "token"]
        for page in hostile {
            #expect(AppPlace(name: page) == nil, "\(page)")
            #expect(Self.refusal(page, from: .tasks) == SetupShow.pageWords, "\(page)")
            #expect(Self.refusal(page, from: .tasks, seen: page) == SetupShow.pageWords, "\(page)")
        }
        #expect(SetupShow.pageWords == "page must be front, or for a first run welcome or name, or one of these places "
                + "of the fleet's own pages: needs, tasks, agents, agent.<name>, settings.general, "
                + "settings.status, task.<number>, agent.<name>.behaviour, agent.<name>.tasks, agent.<name>.people, "
                + "agent.<name>.can_use, settings.secrets, settings.knowledge, settings.apps, settings.people, "
                + "settings.team.")
        #expect(SetupShow.fieldsWords == "setup_show takes only page and seen.")
        // Each refusal for a place is made of fixed words and of names in the map's alphabet.
        let alphabet = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.,:;()<>\"' -]+$")
        var words: [String?] = []
        for target in [ShowTarget.missing, .noPart, .inSetup] {
            words.append(Self.refusal("agent.juno.people", from: .tasks, Self.facts(on: .tasks, target: target)))
        }
        words.append(Self.refusal("tasks", from: .agent("Example Agent/203.0.113.9"), seen: "x"))
        words.append(Self.refusal("tasks", from: .server("Example Server"), seen: "server"))
        words.append(Self.refusal("tasks", from: .agent("Example Agent"), seen: "agent"))
        words.append(Self.refusal("tasks", from: .agent("Example Agent"), seen: "agent",
                                  Self.facts(on: .agent("Example Agent"), shown: true)))
        words.append(Self.refusal("tasks", from: .needs, Self.facts(on: .needs, request: true)))
        for text in words {
            let text = try! #require(text)
            #expect(alphabet.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil, "\(text)")
            #expect(!text.contains("Example") && !text.contains("203.0.113.9"))
        }
    }

    /// **`front`, `welcome` and `name` keep their rules**: `front` changes no page and passes from every place, with a
    /// card over the page, with no reading and after a show too; `welcome` and `name` are the first run's.
    @Test func frontAndTheFirstRunsPagesKeepTheirRules() {
        for place in OwnerAppPlaceTests.every {
            for facts in [Self.facts(on: place),
                          Self.facts(on: place, over: .card, reading: false, fills: true, holds: true, request: true,
                                     shown: true)] {
                #expect(SetupShow.refusal(page: "front", seen: place.name, facts: facts) == nil, "\(place.name)")
                #expect(SetupShow.refusal(page: "front", seen: "none", facts: facts) == nil, "\(place.name)")
            }
            #expect(!SetupShow.changesPlace(to: "front", from: place))
        }
        let firstRun = OwnerSetupBoardTests.page(.paste)
        let facts = Self.facts(on: .firstRun(.paste), firstRun: firstRun)
        #expect(SetupShow.refusal(page: "name", seen: "first_run.paste", facts: facts) == nil)
        #expect(SetupShow.refusal(page: "name", seen: "paste", facts: facts) == nil)
        #expect(SetupShow.refusal(page: "welcome", seen: "tasks", facts: Self.facts(on: .tasks))?
            .hasPrefix("No page of the first run shows") == true)
        #expect(SetupShow.pages == ["front", "welcome", "name"])
        #expect(SetupShow.place(of: "front") == nil && SetupShow.place(of: "name") == nil)
        #expect(SetupShow.place(of: "agent.nova") == .agent("nova") && SetupShow.place(of: "vps") == nil)
        // The place that shows already changes nothing and only comes to the front.
        #expect(!SetupShow.changesPlace(to: "tasks", from: .tasks) && SetupShow.changesPlace(to: "tasks", from: .agents))
        #expect(!SetupShow.changesPlace(to: "name", from: .firstRun(.welcome)))
    }

    // ------------------------------------------------------------ show, in setup_state

    /// **The names of `show`, word for word**, and their order: the first run, no reading, a setup, a show before, a
    /// card, then the place. A place is opened exactly while `show` is `yes`.
    @Test func showSaysWhetherAShowCanChangeThePageNow() {
        #expect(ShowNow.allCases.map(\.rawValue) == ["yes", "first_run", "setup", "shown", "in_use", "card", "no_reading"])
        let firstRun = OwnerSetupBoardTests.page(.welcome)
        #expect(SetupShow.now(Self.facts(on: .firstRun(.welcome), over: .card, reading: false, fills: true, shown: true,
                                         firstRun: firstRun)) == .firstRun)
        #expect(SetupShow.now(Self.facts(on: .settings(.general), over: .card, reading: false, fills: true, holds: true,
                                         shown: true)) == .firstRun)
        #expect(SetupShow.now(Self.facts(on: .addServer(nil), over: .card, reading: false, fills: true, shown: true)) == .noReading)
        #expect(SetupShow.now(Self.facts(on: .addServer(nil), over: .card, fills: true, shown: true)) == .setup)
        #expect(SetupShow.now(Self.facts(on: .settings(.secrets), over: .card, shown: true)) == .shown)
        #expect(SetupShow.now(Self.facts(on: .settings(.secrets), over: .card)) == .card)
        #expect(SetupShow.now(Self.facts(on: .settings(.secrets))) == .inUse)
        #expect(SetupShow.now(Self.facts(on: .needs, request: true)) == .inUse)
        #expect(SetupShow.now(Self.facts(on: .tasks)) == .yes)
        // For every place and every state of the window: a place of the list is opened exactly while it is `yes`.
        for place in OwnerAppPlaceTests.every {
            for over in AppOver.allCases {
                for flags in 0..<32 {
                    let facts = Self.facts(on: place, over: over, reading: flags & 1 == 0, fills: flags & 2 != 0,
                                           holds: flags & 4 != 0, request: flags & 8 != 0, shown: flags & 16 != 0)
                    let opens = SetupShow.refusal(page: "settings.status", seen: place.name, facts: facts) == nil
                        || SetupShow.refusal(page: "agents", seen: place.name, facts: facts) == nil
                    #expect(opens == (SetupShow.now(facts) == .yes), "\(place.name) \(over) \(flags)")
                }
            }
        }
    }

    /// **What `setup_state`'s facts can tell at the first ask**: the place, the first run, what stands over the
    /// page, a reading (the list of places has `needs` only with one) and the sections of Settings. The store's own
    /// values are not known there.
    @Test func theFirstAskReadsTheFactsOfSetupState() {
        var state = OwnerSetupBoardTests.facts(hub: .answers)
        state.place = .agent("nova")
        state.places = AppPlace.places(hasReading: true, settings: [.general, .status, .secrets], apps: [.github], canAdd: true)
        state.over = .card
        let facts = ShowFacts(state)
        #expect(facts == ShowFacts(place: .agent("nova"), firstRun: .none, over: .card, hasReading: true,
                                   sections: [.general, .status, .secrets]))
        #expect(facts.setupFills == nil && facts.firstRunHolds == nil && facts.openRequest == nil && facts.shown == nil
                && facts.target == nil)
        state.places = AppPlace.places(hasReading: false, settings: [.general, .status], apps: [], canAdd: false)
        #expect(!ShowFacts(state).hasReading && ShowFacts(state).sections == [.general, .status])
    }

    // ------------------------------------------------------------ the tool, on the app's side of the link

    func board(_ app: OwnerSetupBoardTests.App) -> SetupBoard {
        SetupBoard(read: { app.facts }, show: { page, seen in
            app.shown.append((page, seen))
            if let words = app.refuses { return words }
            // The stand-in for the app: the page changes, and the owner did not act since.
            if let place = SetupShow.place(of: page) { app.facts.place = place; app.facts.show = .shown }
            return nil
        }, waitMax: .seconds(1))
    }

    func ask(_ board: SetupBoard, _ page: String, seen: String) async -> OwnerChannel.Answer {
        await board.answer(OwnerChannel.Request(set: "owner", tool: "setup_show",
                                                fields: ["page": .string(page), "seen": .string(seen)]))
    }

    static func fleet(on place: AppPlace, show: ShowNow = .yes) -> SetupFacts {
        var facts = OwnerSetupBoardTests.facts(hub: .answers)
        facts.place = place
        facts.places = AppPlace.places(hasReading: true, settings: [.general, .status, .secrets],
                                       apps: [.github], canAdd: true)
        facts.show = show
        return facts
    }

    /// **A place of the fleet's own pages has one effect, and the answer is the state after it**, with `front` as
    /// `asked` and `show` as `shown`. A refusal of the first ask asks nothing of the app.
    @Test func aPlaceHasOneEffectAndGivesTheNewState() async {
        let app = OwnerSetupBoardTests.App(Self.fleet(on: .tasks))
        let board = board(app)
        guard case .object(var shown) = Self.fleet(on: .agent("nova"), show: .shown).json(change: 2, map: true) else { return }
        shown["front"] = .string("asked")
        #expect(await ask(board, "agent.nova", seen: "tasks") == .result(.object(shown)))
        #expect(shown["show"] == .string("shown"))
        #expect(app.shown.count == 1 && app.shown.first! == ("agent.nova", "tasks"))
        // The owner's page is another one now: an ask with the old place is refused before the app is asked.
        #expect(await ask(board, "settings.status", seen: "tasks") == .refused(SetupShow.notSeen("agent.nova")))
        // The short form of the first run does not pass for a place.
        #expect(await ask(board, "settings.status", seen: "none") == .refused(SetupShow.notSeen("agent.nova")))
        // The page does not change from an agent's chat.
        #expect(await ask(board, "tasks", seen: "agent.nova") == .refused(SetupShow.notFrom("agent.nova")))
        // A place that is no target, a section that this hub does not offer, a card over the page.
        app.facts.place = .agents
        #expect(await ask(board, "settings.servers", seen: "agents") == .refused(SetupShow.notOpened("settings.servers")))
        #expect(await ask(board, "settings.knowledge", seen: "agents") == .refused(SetupShow.noSection("settings.knowledge")))
        app.facts.over = .card
        #expect(await ask(board, "settings.status", seen: "agents") == .refused(SetupShow.cardOver))
        app.facts.over = .nothing
        #expect(app.shown.count == 1)
        // The app's own refusals, from its store's state, come as they are: a show before, an agent that is not there.
        app.refuses = SetupShow.shownAlready("agents")
        #expect(await ask(board, "tasks", seen: "agents") == .refused(app.refuses!))
        app.refuses = SetupShow.missing(.agent("juno"))
        #expect(await ask(board, "agent.juno", seen: "agents") == .refused(app.refuses!))
        #expect(app.shown.count == 3 && app.shown.last! == ("agent.juno", "agents"))
        // A field that the tool does not take is not said back.
        #expect(await board.answer(OwnerChannel.Request(set: "owner", tool: "setup_show",
                                                        fields: ["page": .string("tasks"), "seen": .string("agents"),
                                                                 "sk-example-1": .bool(true)]))
                == .refused("setup_show takes only page and seen."))
        // In a first run no place opens, and with no reading none either.
        app.refuses = nil
        app.facts = OwnerSetupBoardTests.facts(OwnerSetupBoardTests.page(.welcome))
        app.facts.place = .firstRun(.welcome)
        #expect(await ask(board, "tasks", seen: "first_run.welcome") == .refused(SetupShow.firstRunShows("first_run.welcome")))
        app.facts = OwnerSetupBoardTests.facts(hub: .set)
        app.facts.place = .waiting
        #expect(await ask(board, "tasks", seen: "waiting") == .refused(SetupShow.noReading("waiting")))
        #expect(app.shown.count == 3)
    }

    /// **The tool's own words name each place of the two lists**, from the lists themselves, and the three pages
    /// that are left out; `setup_state`'s words name each value of `show` and the key `in_front`. The sentences on
    /// the keys and the first click say what the code does.
    @Test func theToolsWordsNameTheListsAndTheKeys() throws {
        let show = try #require(OwnerSetupTools.tools.first { $0.name == "setup_show" }).description
        #expect(show.contains("a place of the fleet's own pages, by the name that setup_state gives a place: "
                              + SetupShow.targetForms.joined(separator: ", ") + "."))
        #expect(show.contains("It changes the page only from these places: " + SetupShow.fromWords
                              + ", because on every other place the owner can be in the middle of typing or of work."))
        for words in ["not agent.<name>.runs_on, settings.servers or settings.backup",
                      "never add_server, add_agent, shape_change, connect_key, server.<name>, app.<app>, an agent's "
                        + "rule editor, or a place of an agent's setup, \"Setting up\" or sign-in",
                      "seen: the place that setup_state gave last",
                      "after it changed the page and until a click of the owner reached the app's main window (one "
                        + "change of page for each such click; after a change the app drops one click of the owner, "
                        + "and a key ends nothing)",
                      "It judges the fleet by the reading of the hub that the app has, which can be minutes old while "
                        + "the hub does not answer.",
                      "It never shows another page than the one that was asked for, and the place that shows already "
                        + "changes nothing.",
                      "Call it for a place only when the owner asked for that page or said yes to it in this "
                        + "conversation",
                      "never use it to move the owner away from work",
                      "an agent's chat that it opened counts as read only when a click or a key of the owner reached "
                        + "the app's main window and that chat still shows after it; the first click after a change "
                        + "of page, which the app drops, marks nothing.",
                      "It presses nothing, changes no fleet",
                      "an owner who clicked in the app since it came to the front keeps their keys when the call "
                        + "changed no page",
                      "After a call that changed the page the app takes no key press from any owner, and it drops the "
                        + "owner's first click, which only ends that hold",
                      "Each hold also ends when the app leaves the front."] {
            #expect(show.contains(words), "setup_show's words lost: \(words)")
        }
        let state = try #require(OwnerSetupTools.tools.first { $0.name == "setup_state" }).description
        for value in ShowNow.allCases { #expect(state.contains(value.rawValue), "\(value.rawValue)") }
        for words in ["show, whether setup_show can change the page now",
                      "shown (setup_show changed the page, and no click of the owner reached the app's main window "
                        + "since: it ends at the next click that reaches the app and that the app sees to its end; a "
                        + "click on a text field, a switch or a slider can pass unseen, and then the next one counts; "
                        + "a key does not end it)",
                      "in_front, true while Founderizer is the active app and its main window is on the screen, on the "
                        + "Space that shows, not in the Dock, and is the app's main or key window",
                      "while it is false, another app can stand in front of that window",
                      "true does not say that a picture of every display shows it",
                      "a change of Space moves no change, so read with no after before a look"] {
            #expect(state.contains(words), "setup_state's words lost: \(words)")
        }
        // Both stay reads for the client: they change no fleet, no server and no file.
        for name in ["setup_show", "setup_state"] {
            #expect(OwnerSetupTools.tools.first { $0.name == name }?.annotations == .object(["readOnlyHint": .bool(true)]))
        }
    }

    // ------------------------------------------------------------ after a show changed the page

    /// A click of the owner in the main window, as the app's watch tells it after its mouse-up; and a key.
    static func click(reached: Bool = true, began: Int) -> ShownPage.Act { .init(isClick: true, reached: reached, began: began) }
    static func key(began: Int) -> ShownPage.Act { .init(isClick: false, reached: true, began: began) }

    /// **One change of page for each click of the owner that reached the app** (`ShownPage.waitsForOwner`): a show
    /// that changed the page waits until the app handled such a click. A change of page that is not the owner's act
    /// (the app's own, a new name of an agent) ends nothing, **and neither does the click that the app dropped**.
    @Test func aShowWaitsForAClickOfTheOwnerThatReachedTheApp() {
        var shown = ShownPage()
        #expect(!shown.waitsForOwner && shown.change == 0)
        shown.shows(nil)                                    // a show to Tasks
        shown.went(to: nil)
        #expect(shown.waitsForOwner && shown.change == 1)
        shown.went(to: "nova")                              // the app's own change of page
        shown.renamed(from: "nova", to: "juno")
        #expect(shown.waitsForOwner && shown.change == 1)
        // The click that the app dropped after the change of page: it is no act of the owner.
        let dropped = shown.handled(Self.click(reached: false, began: 1), showing: "juno")
        #expect(shown.waitsForOwner && !dropped)
        // The next click reached the app, and the app handled it: one more change of page is free.
        let reached = shown.handled(Self.click(began: 1), showing: "juno")
        #expect(!shown.waitsForOwner && !reached)
        // The next show waits again, also with a chat, and has the next number.
        shown.shows("nova")
        #expect(shown.waitsForOwner && shown.chat == "nova" && shown.change == 2)
    }

    /// **A key never frees the next change of page.** With a key as an act, a caller in a loop made the app drop
    /// every click: a show; the click is dropped and frees the keys; a key frees the next show; and so on. A key
    /// still marks the chat that a show opened as read, when that chat still shows, and it ends nothing else.
    @Test func aKeyNeverFreesTheNextChangeOfPage() {
        var shown = ShownPage()
        shown.shows(nil)
        shown.went(to: nil)
        for _ in 0..<5 {
            let read = shown.handled(Self.key(began: shown.change), showing: nil)
            #expect(!read && shown.waitsForOwner)
        }
        let click = shown.handled(Self.click(began: shown.change), showing: nil)
        #expect(!click && !shown.waitsForOwner)
        // On a chat that a show opened: the key marks it as read, and the show still waits for a click.
        shown.shows("nova")
        shown.went(to: "nova")
        let read = shown.handled(Self.key(began: shown.change), showing: "nova")
        #expect(read && shown.countsAsRead("nova") && shown.waitsForOwner)
    }

    /// **An event that began before a show does not count after it.** Two sequences: a key whose handling still
    /// waits on the main queue when the show comes; and a click whose button went down on the page before, with the
    /// show before its release. Neither frees the next show, and neither marks the chat that the show opened.
    @Test func anEventThatBeganBeforeAShowDoesNotCountAfterIt() {
        // 1. The key-down on Tasks (the number of then), the show, and only then the handling of the key.
        var shown = ShownPage()
        let key = Self.key(began: shown.change)
        shown.shows("nova")
        shown.went(to: "nova")
        let byKey = shown.handled(key, showing: "nova")
        #expect(!byKey && !shown.countsAsRead("nova") && shown.waitsForOwner)
        // The same for a click that was over before the show, with its handling still on the queue.
        let before = shown.handled(Self.click(began: 0), showing: "nova")
        #expect(!before && !shown.countsAsRead("nova") && shown.waitsForOwner)

        // 2. A click on Tasks is over for the hardware, and its mouse-up still waits in the app's queue when the
        // show changes the page (a show while the button is DOWN is refused, `SetupShow.buttonHeld`). The mouse-up
        // then comes on the page that came. The hold lets it pass, as a mouse-up with no mouse-down of its own, and
        // the store ignores it by its number. The next click is the one that the app drops.
        var front = OutsideFront(), page = ShownPage()
        front.click(appInFront: true)                       // the owner works in the app
        _ = front.pointer(up: true)
        let began = page.change
        let down = front.click(appInFront: true, event: OutsideFront.Event(number: 1, time: 1))
        front.came(appInFront: true, pageChanged: true)
        page.shows("nova")
        page.went(to: "nova")
        let up = front.pointer(up: true)
        #expect(down && up && front.holdsClick && front.holdsKeys)
        let byUp = page.handled(Self.click(reached: up, began: began), showing: "nova")
        #expect(!byUp && page.waitsForOwner && !page.countsAsRead("nova"))
        // The next click is dropped, and counts for nothing. The one after it reaches the app and counts.
        let next = front.click(appInFront: true, event: OutsideFront.Event(number: 2, time: 2))
        let nextUp = front.pointer(up: true)
        let dropped = page.handled(Self.click(reached: nextUp, began: page.change), showing: "nova")
        #expect(!next && !nextUp && !dropped && page.waitsForOwner && !page.countsAsRead("nova"))
        let third = front.click(appInFront: true, event: OutsideFront.Event(number: 3, time: 3))
        let thirdUp = front.pointer(up: true)
        let counts = page.handled(Self.click(reached: thirdUp, began: page.change), showing: "nova")
        #expect(third && thirdUp && counts && !page.waitsForOwner && page.countsAsRead("nova"))
    }

    /// **No page changes while a mouse button is down**: the app's last check reads the button, and the rule refuses
    /// with fixed words. Only a call that would change the page: a call for the place that shows, and `front`,
    /// change nothing and pass. The first ask and `setup_state`'s `show` do not know the button.
    @Test func noPageChangesWhileAMouseButtonIsDown() {
        for place in Self.from {
            let held = Self.facts(on: place, buttonDown: true)
            for target in Self.targets where target != place {
                #expect(Self.refusal(target.name, from: place, held) == SetupShow.buttonHeld, "\(target.name)")
                #expect(Self.refusal(target.name, from: place, Self.facts(on: place, buttonDown: false)) == nil)
                #expect(Self.refusal(target.name, from: place, Self.facts(on: place, buttonDown: nil)) == nil)
            }
            #expect(Self.refusal(place.name, from: place, held) == nil)
            #expect(Self.refusal("front", from: place, held) == nil)
            // The button moves no `show`: nothing observes it.
            #expect(SetupShow.now(held) == .yes)
        }
        #expect(SetupShow.buttonHeld == "The owner holds a mouse button down now, so setup_show changes no page under "
                + "that click. Call setup_show again.")
        // Each other refusal comes before it: the place, the card, a show that waits, a place that the fleet lacks.
        #expect(Self.refusal("agents", from: .settings(.general), Self.facts(on: .settings(.general), buttonDown: true))
                == SetupShow.notFrom("settings.general"))
        #expect(Self.refusal("agents", from: .tasks, Self.facts(on: .tasks, shown: true, buttonDown: true))
                == SetupShow.shownAlready("tasks"))
        #expect(Self.refusal("agent.nova", from: .tasks, Self.facts(on: .tasks, target: .missing, buttonDown: true))
                == SetupShow.missing(.agent("nova")))
    }

    /// **The app's watch and its store, as the two pure rules that they wire together** (`AppFront`, `FleetStore`):
    /// the owner's mouse-downs, mouse-ups and keys, the handlings that wait on the main queue, and a caller that
    /// calls `setup_show` whenever the rules allow.
    struct Played {
        var front = OutsideFront(), shown = ShownPage()
        var shows = 0
        private var clickBegan = 0
        private var buttonDown = false
        private var queue: [ShownPage.Act] = []
        private var number = 0

        /// The caller: a show passes only while no show waits for the owner (`show` is not `shown`) and no mouse
        /// button is down. The app is in front, and each show changes the page (between Tasks and Agents).
        mutating func callerTries() {
            // A show while a mouse button is down is refused (`SetupShow.buttonHeld`).
            guard !shown.waitsForOwner, !buttonDown else { return }
            front.came(appInFront: true, pageChanged: true)
            shown.shows(nil)
            shows += 1
        }
        mutating func mouseDown(count: Int = 1) -> Bool {
            number += 1
            clickBegan = shown.change
            buttonDown = true
            let event = OutsideFront.Event(number: number, time: Double(number), count: count)
            return front.click(appInFront: true, event: event)
        }
        mutating func mouseUp() -> Bool {
            buttonDown = false
            let reaches = front.pointer(up: true)
            queue.append(.init(isClick: true, reached: reaches, began: clickBegan))
            return reaches
        }
        /// A key press: true when the app takes it.
        mutating func key() -> Bool {
            guard front.takesKeys else { return false }
            queue.append(.init(isClick: false, reached: true, began: shown.change))
            return true
        }
        /// The handlings that waited on the main queue run.
        mutating func queueRuns() {
            for act in queue { _ = shown.handled(act, showing: nil) }
            queue = []
        }
    }

    /// **A caller in a loop cannot keep the owner from clicking: of any two clicks of the owner at least one reaches
    /// the app, whatever keys come between.** The caller calls `setup_show` as early as the rules allow, at each of
    /// seven moments of a click (before it, in the middle of it, after its mouse-up, before and after the handlings
    /// on the main queue ran), in each combination of those moments; and the owner presses a key in each of four
    /// positions, in each combination. A click reaches the app when its mouse-down and its mouse-up both do.
    @Test func aCallerThatShowsAgainAtOnceCostsOneClickInTwo() {
        for moments in 0..<128 {
            for keys in 0..<16 {
                var app = Played()
                _ = app.mouseDown()                         // the owner works in the app
                _ = app.mouseUp()
                app.queueRuns()
                var reached: [Bool] = []
                func tries(_ moment: Int) { if moments & (1 << moment) != 0 { app.callerTries() } }
                for _ in 0..<12 {
                    if keys & 1 != 0 { _ = app.key() }      // a key before the click
                    tries(0)
                    let down = app.mouseDown()
                    tries(1)                                // in the middle of the click
                    if keys & 2 != 0 { _ = app.key() }      // a key with the button down
                    tries(2)
                    let up = app.mouseUp()
                    tries(3)                                // after the mouse-up, before its handling ran
                    if keys & 4 != 0 { _ = app.key() }
                    app.queueRuns()
                    tries(4)
                    if keys & 8 != 0 { _ = app.key() }      // a key after the click
                    tries(5)
                    app.queueRuns()
                    tries(6)
                    reached.append(down && up)
                }
                for index in 1..<reached.count where !reached[index - 1] && !reached[index] {
                    Issue.record("moments \(moments), keys \(keys): the clicks \(index - 1) and \(index) did not reach the app")
                    return
                }
            }
        }
        // The plain loop, with a key after each click: exactly one click in two is dropped, and one change of page
        // comes for each click that reached. With a key as an act, every click would be dropped.
        var app = Played()
        _ = app.mouseDown()
        _ = app.mouseUp()
        app.queueRuns()
        app.callerTries()
        #expect(app.shows == 1 && app.front.holdsKeys && app.front.holdsClick)
        var reached: [Bool] = [], keys: [Bool] = []
        for _ in 0..<40 {
            let down = app.mouseDown()
            app.callerTries()
            let up = app.mouseUp()
            #expect(up == down)
            app.queueRuns()
            app.callerTries()
            keys.append(app.key())                          // the click before it freed the keys, or a show held them
            app.queueRuns()
            app.callerTries()
            reached.append(down)
        }
        #expect(reached == (0..<40).map { $0 % 2 == 1 })
        #expect(keys == (0..<40).map { $0 % 2 == 0 })       // after a dropped click the keys are free; a show holds them
        #expect(app.shows == 1 + 20)
    }

    /// **Rule 7: the chat that a show opened does not count as read until a click or a key of the owner reached the
    /// app's main window and that chat still shows after the app handled it.** The click that the app dropped marks
    /// nothing; the click that leaves the chat does not mark it; a change of page by the owner ends the mark, and the
    /// chat that the owner opens counts as before.
    @Test func theChatThatAShowOpenedIsNotReadUntilTheOwnerActsOnIt() {
        var shown = ShownPage()
        #expect(shown.countsAsRead("nova") && shown.chat == nil)
        // A show opens the chat of nova: told before the page changes, then the page changes to it.
        shown.shows("nova")
        shown.went(to: "nova")
        #expect(!shown.countsAsRead("nova") && shown.countsAsRead("juno"))
        // **The owner's click that the app dropped**: it was for the page that went. Its mouse-up is told as one
        // that did not reach the app: the chat is not read, and the show still waits for the owner.
        let dropped = shown.handled(Self.click(reached: false, began: shown.change), showing: "nova")
        #expect(!dropped && !shown.countsAsRead("nova") && shown.chat == "nova" && shown.waitsForOwner)
        // The next click reached the app, the app handled it, and the chat still shows: read from now on, once.
        let first = shown.handled(Self.click(began: shown.change), showing: "nova")
        #expect(first && shown.countsAsRead("nova") && !shown.waitsForOwner)
        let second = shown.handled(Self.click(began: shown.change), showing: "nova")
        #expect(!second)

        // **The click that leaves the chat**: it reached the app, the page changes while the app handles its
        // mouse-up, and then the handling is told. The chat was not marked by that click.
        shown.shows("nova")
        shown.went(to: "nova")
        #expect(!shown.countsAsRead("nova"))                // the store marks nothing at its readings meanwhile
        shown.went(to: nil)                                 // the click's own change of page, to Tasks
        let left = shown.handled(Self.click(began: shown.change), showing: nil)
        #expect(!left && shown.chat == nil && !shown.waitsForOwner)
        // The same with a click that goes to another agent's chat: that one counts as read, as the owner opened it.
        shown.shows("nova")
        shown.went(to: "nova")
        shown.went(to: "juno")
        let other = shown.handled(Self.click(began: shown.change), showing: "juno")
        #expect(!other && shown.countsAsRead("juno") && shown.countsAsRead("nova"))

        // The handling of an event is told while another page shows than the chat that waits: nothing is marked.
        shown.shows("nova")
        let elsewhere = shown.handled(Self.click(began: shown.change), showing: "juno")
        let nowhere = shown.handled(Self.key(began: shown.change), showing: nil)
        #expect(!elsewhere && !nowhere && shown.chat == "nova" && !shown.countsAsRead("nova"))
        // A second show takes the mark to its own chat; a show of a page that is no chat marks none.
        shown.went(to: "nova")
        shown.shows("juno")
        shown.went(to: "juno")
        #expect(!shown.countsAsRead("juno") && shown.countsAsRead("nova"))
        shown.shows(nil)
        shown.went(to: nil)
        #expect(shown.chat == nil)
        // A page that is set again to the chat that shows (no change) keeps the mark.
        shown.shows("nova")
        shown.went(to: "nova")
        shown.went(to: "nova")
        #expect(!shown.countsAsRead("nova"))
    }

    /// **A new name of the shown agent does not mark its chat as read**: the app moves the page to the new name by
    /// itself, and the mark goes with it. Another agent's new name changes nothing.
    @Test func aNewNameOfTheShownAgentKeepsItsChatNotRead() {
        var shown = ShownPage()
        shown.shows("nova")
        shown.went(to: "nova")
        shown.renamed(from: "juno", to: "vega")
        #expect(shown.chat == "nova")
        shown.renamed(from: "nova", to: "vega")             // told before the page moves to the new name
        shown.went(to: "vega")
        #expect(shown.chat == "vega" && !shown.countsAsRead("vega") && shown.waitsForOwner)
        // Without that word the move to the new name would end the mark.
        var plain = ShownPage()
        plain.shows("nova")
        plain.went(to: "nova")
        plain.went(to: "vega")
        #expect(plain.countsAsRead("vega"))
        let read = shown.handled(Self.click(began: shown.change), showing: "vega")
        #expect(read)
    }

    // ------------------------------------------------------------ the window in front

    /// **`in_front`**: the app is the active app, and its main window is on the screen, on the Space that shows, not
    /// in the Dock, and is the app's main or key window. Another window of the app does not count, and with another
    /// window as the main and key window (Report a problem) the fleet's window can stand behind another app.
    @Test func theWindowIsInFrontOnlyWhenItCanBeSeen() {
        typealias Window = AppInFront.Window
        let fleet = Window(isFleet: true, onScreen: true)
        let report = Window(isFleet: false, onScreen: true)
        #expect(AppInFront.of(active: true, windows: [fleet]))
        #expect(AppInFront.of(active: true, windows: [Window(isFleet: false, onScreen: true, mainOrKey: false), fleet]))
        #expect(!AppInFront.of(active: false, windows: [fleet]))
        #expect(!AppInFront.of(active: true, windows: []))
        #expect(!AppInFront.of(active: true, windows: [report]))
        #expect(!AppInFront.of(active: true, windows: [Window(isFleet: true, onScreen: false)]))
        #expect(!AppInFront.of(active: true, windows: [Window(isFleet: true, onScreen: true, miniaturized: true)]))
        #expect(!AppInFront.of(active: true, windows: [Window(isFleet: true, onScreen: true, onActiveSpace: false)]))
        // Report a problem is the app's main and key window: the fleet's window is on the screen and is neither.
        #expect(!AppInFront.of(active: true, windows: [report, Window(isFleet: true, onScreen: true, mainOrKey: false)]))
    }

    // ------------------------------------------------------------ the app's side, read from its source

    static func source(_ path: String) throws -> String { try OwnerAppPlaceTests.source(path) }

    /// The body of the function that starts with `head`, to the first line that closes it at its own indent.
    static func body(of head: String, in text: String) throws -> String {
        let start = try #require(text.range(of: head))
        let indent = String(text[..<start.lowerBound].reversed().prefix { $0 == " " })
        let end = try #require(text.range(of: "\n" + indent + "}\n", range: start.upperBound..<text.endIndex))
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// **The app asks the rules again and changes the page in one turn of the main actor** (the app has no test
    /// target, so its source is read): in `SetupChannel.showPlace` the rules come before the change, the window's
    /// own rule of what a page draws comes before it too, the page changes through `FleetStore.show`, and no `await`
    /// stands in the function, so nothing that the owner does comes between the check and the change.
    @Test func theAppChecksAndChangesThePageInOneTurn() throws {
        let channel = try Self.source("Sources/Founderizer/SetupChannel.swift")
        let body = try Self.body(of: "private func showPlace(", in: channel)
        let rules = try #require(body.range(of: "SetupShow.refusal(page: page, seen: seen, facts: facts)"))
        let draws = try #require(body.range(of: "Self.place(of: store, showing: destination) == target"))
        // The front holds the keys and the first click first (`OutsideFront`), then the page changes.
        let front = try #require(body.range(of: "AppFront.come(pageChanged: changes) {"))
        let change = try #require(body.range(of: "if changes { store.show(destination) }"))
        #expect(rules.upperBound < draws.lowerBound && draws.upperBound < front.lowerBound
                && front.upperBound < change.lowerBound)
        #expect(body.contains("let changes = SetupShow.changesPlace(to: page, from: facts.place)"))
        #expect(!body.contains("await") && !body.contains("Task"))
        #expect(!body.contains("store.destination ="))
        let come = try Self.body(of: "static func come(pageChanged: Bool = false, open: () -> Void) {", in: channel)
        let holds = try #require(come.range(of: "came(pageChanged ? \"show of a place\" : \"show\", pageChanged: pageChanged)"))
        let opens = try #require(come.range(of: "open()"))
        #expect(holds.upperBound < opens.lowerBound)
        // The hold has no branch for a button: a change of page always holds the next click.
        #expect(channel.contains("keys.came(appInFront: inFront, pageChanged: pageChanged)"))
        // The facts of that ask are the store's own, with the windows of that moment, the place asked for and the
        // mouse button's state now: no page changes while a button is down.
        #expect(body.contains("Self.showFacts(of: store, over: Self.over().0, target: target,"))
        #expect(body.contains("buttonDown: NSEvent.pressedMouseButtons != 0)"))
        let showFacts = try Self.body(of: "static func showFacts(of store: FleetStore, over: AppOver, target: AppPlace? = nil,",
                                      in: channel)
        #expect(showFacts.contains("buttonDown: buttonDown"))
        for fact in ["setupFills: store.fillsWindow(store.destination)", "firstRunHolds: store.firstRunHolds",
                     "openRequest: !store.openNeeds.isEmpty", "shown: store.shown.waitsForOwner"] {
            #expect(showFacts.contains(fact), "\(fact)")
        }
        // The same facts give `setup_state` its `show`, and AppKit gives `in_front` at each read.
        let facts = try Self.body(of: "private func facts() -> SetupFacts {", in: channel)
        #expect(facts.contains("show: SetupShow.now(Self.showFacts(of: store, over: over))"))
        #expect(facts.contains("inFront: Self.inFront()"))
        #expect(try Self.body(of: "static func inFront() -> Bool {", in: channel)
            .contains("mainOrKey: window.isMainWindow || window.isKeyWindow"))
        let windows = try Self.body(of: "private func watchWindows() {", in: channel)
        for name in ["NSApplication.didBecomeActiveNotification", "NSApplication.didResignActiveNotification"] {
            #expect(windows.contains(name), "\(name)")
        }
    }

    /// **The app's own watch of its clicks and keys**, read from its source: one function answers each mouse-down, the
    /// click that is for the page that went is dropped with its drags and its mouse-up, a mouse-down alone tells the
    /// store nothing, and the store hears of a mouse-up or a key of the main window on a later turn of the main queue:
    /// whether it is a click, whether it reached the app, and the number of the latest show when it began.
    @Test func theAppsWatchDropsTheFirstClickAndTellsWhatReached() throws {
        let channel = try Self.source("Sources/Founderizer/SetupChannel.swift")
        let watch = try Self.body(of: "static func watch() {", in: channel)
        // The mouse-down: the one function says whether it reaches the app, and the watch passes it on or drops it.
        #expect(watch.contains("MainActor.assumeIsolated { reaches(event) } ? event : nil"))
        let reaches = try Self.body(of: "static func reaches(_ event: NSEvent) -> Bool {", in: channel)
        // The event goes to the rule with its place in a click series: a double click is one click for the hold.
        let id = try #require(reaches.range(of: "let id = OutsideFront.Event(number: event.eventNumber, time: event.timestamp, "
                                              + "count: event.clickCount)"))
        // The same event asked a second time: the kept answer, and nothing else is done.
        let again = try #require(reaches.range(of: "guard !keys.answered(id) else { return keys.click(appInFront: NSApp.isActive, event: id) }"))
        // The click begins: the number of the latest show is noted here, for its mouse-up.
        let begins = try #require(reaches.range(of: "clickBegan = pageChange?() ?? 0"))
        let first = try #require(reaches.range(of: "let reaches = keys.click(appInFront: NSApp.isActive, event: id)"))
        #expect(id.upperBound < again.lowerBound && again.upperBound < begins.lowerBound
                && begins.upperBound < first.lowerBound)
        // **A mouse-down frees no change of page and marks no chat**: nothing of it is told to the store, so the
        // click that the app drops is no act of the owner.
        #expect(!reaches.contains("ownerHandled") && !reaches.contains("tellHandled"))
        #expect(!channel.contains("ownerActed"))
        // Its drags and its mouse-up. The store is told of a mouse-up of the main window as a click, with whether it
        // reached the app and with the number of its mouse-down: the rule (`ShownPage.handled`) decides.
        #expect(watch.contains("matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged,"))
        let up = try #require(watch.range(of: "let reaches = keys.pointer(up: up)"))
        let tells = try #require(watch.range(of: "if up, inMainWindow(event) { tellHandled(.init(isClick: true, "
                                               + "reached: reaches, began: clickBegan)) }"))
        #expect(up.upperBound < tells.lowerBound)
        #expect(watch.components(separatedBy: "return reaches ? event : nil").count == 2)
        // A key: none during the hold; one that the app takes is told as a key, in the main window only, with the
        // number of the moment of its key-down. A key is never told as a click, so it frees no change of page.
        let key = try #require(watch.range(of: "} else if inMainWindow(event) {"))
        #expect(watch[key.upperBound...].contains("tellHandled(.init(isClick: false, reached: true, began: pageChange?() ?? 0))"))
        #expect(watch.components(separatedBy: "tellHandled(").count == 3)
        #expect(watch.components(separatedBy: "isClick: true").count == 2)
        // The main window is the fleet's, and the handling is told after the event, on a later turn.
        #expect(channel.contains("event.window?.identifier?.rawValue == SetupChannel.fleetWindow"))
        let handled = try Self.body(of: "private static func tellHandled(_ act: ShownPage.Act) {", in: channel)
        #expect(handled.contains("Task { @MainActor in") && handled.contains("await Task.yield()")
                && handled.contains("ownerHandled?(act)"))
        #expect(channel.contains("AppFront.ownerHandled = { [weak store] act in store?.ownerHandled(act) }"))
        #expect(channel.contains("AppFront.pageChange = { [weak store] in store?.shown.change ?? 0 }"))
    }

    /// **The store's part of what a show leaves open**, read from its source: a show tells the chat that it opens
    /// before the page changes, each change of page is told, the open chat is marked only when it counts as read,
    /// the handling of the owner's click or key goes to the rule as the watch told it, and a new name of an agent is
    /// told before the page moves.
    @Test func theStoreKeepsWhatAShowLeavesOpen() throws {
        let store = try Self.source("Sources/Founderizer/FleetStore.swift")
        let show = try Self.body(of: "func show(_ page: Destination) {", in: store)
        let tells = try #require(show.range(of: "shown.shows(page.agentTab == .chat ? page.agentName : nil)"))
        let changes = try #require(show.range(of: "destination = page"))
        #expect(tells.upperBound < changes.lowerBound)
        #expect(store.contains("if shown.chat != nil { shown.went(to: destination.agentTab == .chat ? destination.agentName : nil) }"))
        let marks = try Self.body(of: "private func markRepliesSeen() {", in: store)
        #expect(marks.contains("if case .agent(let name) = destination, name != keptUnread, shown.countsAsRead(name) {"))
        let handled = try Self.body(of: "func ownerHandled(_ act: ShownPage.Act) {", in: store)
        #expect(handled.contains("let chat = destination.agentTab == .chat ? destination.agentName : nil"))
        #expect(handled.contains("if shown.handled(act, showing: chat) { markRepliesSeen() }"))
        // No other word of the owner's act: a mouse-down alone, or a dropped click, frees nothing and marks nothing.
        #expect(!store.contains("func ownerActed") && store.components(separatedBy: "shown.handled(").count == 2)
        let renamed = try #require(store.range(of: "shown.renamed(from: renamed.was, to: renamed.now)"))
        let moves = try #require(store.range(of: "if let page = Self.renamed(destination, was: renamed.was, now: renamed.now) { destination = page }"))
        #expect(renamed.upperBound < moves.lowerBound)
    }

    /// **Every watch of the app's own events is known, and each one that can act on a key or on a mouse-down asks
    /// the hold first** (`AppFront`). AppKit gives the watches no fixed order, so a key or a click that the hold drops
    /// must do nothing in a watch that ran before the hold's own. The search finds each `addLocalMonitorForEvents`
    /// of the app: a watch that is added fails here until it is on the list with its answer.
    @Test func everyEventWatchOfTheAppIsKnownAndAsksTheHold() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer")
        let call = try NSRegularExpression(pattern: #"addLocalMonitorForEvents\(matching:\s*(\[[^\]]*\]|\.?\w+)"#)
        var found: [String] = []
        var global = 0
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            global += text.components(separatedBy: "addGlobalMonitorForEvents(").count - 1
            for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let events = String(text[Range(match.range(at: 1), in: text)!])
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                found.append("\(file.lastPathComponent): \(events)")
            }
        }
        // **The ten watches of the app's own events**, by file and by the events that each takes.
        #expect(found == [
            "AttachmentViews.swift: .keyDown",                      // Command and V with a file: asks `holdsKeys`
            "ChatSelection.swift: [.leftMouseDown, .rightMouseDown, .otherMouseDown]",   // a chat's pressed row: asks `reaches`
            "FleetMenu.swift: kinds",                               // the app's menu while it is open (four, below)
            "FleetMenu.swift: [.rightMouseDown, .leftMouseDown]",   // a right click opens the app's menu: asks `reaches`
            "FleetView.swift: .keyDown",                            // ⌘1 to 9, the steps, ⌥⇧↓, typing: asks `holdsKeys`
            "NeedsBoard.swift: .keyDown",                           // the page keys and Escape: ask `holdsKeys`
            "SecretRequestViews.swift: .keyDown",                   // Command and V with a key: asks `holdsKeys`
            "SetupChannel.swift: [.leftMouseDown, .rightMouseDown, .otherMouseDown]",   // the hold's own: `reaches`
            "SetupChannel.swift: [.leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, "
                + ".otherMouseDragged]",                            // the hold's own: `pointer`
            "SetupChannel.swift: .keyDown",                         // the hold's own: `takesKeys`
        ])
        // The one watch of other apps' events closes the app's menu at a click in another app: it acts on no page.
        #expect(global == 1)

        // ---- the keys: each watch outside the hold's own asks `AppFront.holdsKeys` before it does anything.
        let guardLine = "guard !AppFront.holdsKeys else { return false }"
        let view = try Self.source("Sources/Founderizer/FleetView.swift")
        #expect(try Self.body(of: "private func take(_ event: NSEvent) -> Bool {", in: view)
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(guardLine))
        let needs = try Self.source("Sources/Founderizer/NeedsBoard.swift")
        for head in ["private func leavesField(_ event: NSEvent) -> Bool {", "private func mine(_ event: NSEvent) -> Bool {"] {
            #expect(try Self.body(of: head, in: needs).contains(guardLine), "\(head)")
        }
        #expect(try Self.body(of: "private func leavesField(_ event: NSEvent) -> Bool {", in: needs)
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(guardLine))
        // The two paste watches: the guard is the first line of what the watch does on the main actor.
        for path in ["Sources/Founderizer/AttachmentViews.swift", "Sources/Founderizer/SecretRequestViews.swift"] {
            let text = try Self.source(path)
            let watch = try #require(text.range(of: "NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in"))
            let block = try #require(text.range(of: "MainActor.assumeIsolated { () -> Bool in", range: watch.upperBound..<text.endIndex))
            #expect(text[block.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(guardLine), "\(path)")
        }

        // ---- **A press in an agent's chat keeps the words of the row that he pressed selectable** (`ChatSelection`):
        // the watch asks the hold first, and a click that the hold drops moves no row.
        let chat = try Self.source("Sources/Founderizer/ChatSelection.swift")
        let watches = try Self.body(of: "func start() {", in: chat)
        let asksHold = try #require(watches.range(of: "guard AppFront.reaches(event) else { return }"))
        let presses = try #require(watches.range(of: "self?.change { $0.press(onWords: Self.onWords(event)) }"))
        #expect(asksHold.upperBound < presses.lowerBound)
        #expect(watches.contains("return event"))

        // ---- the app's menu. While it is open it has four watches, through one helper: a click elsewhere, the
        // held button's drags and release, the scroll wheel, and its keys.
        let menu = try Self.source("Sources/Founderizer/FleetMenu.swift")
        let local = try NSRegularExpression(pattern: #"local\(\[([^\]]*)\], open\)"#)
        let open = local.matches(in: menu, range: NSRange(menu.startIndex..., in: menu)).map {
            String(menu[Range($0.range(at: 1), in: menu)!])
        }
        #expect(open == [".leftMouseDown, .rightMouseDown, .otherMouseDown",
                         ".rightMouseDragged, .rightMouseUp, .leftMouseDragged, .leftMouseUp", ".scrollWheel", ".keyDown"])
        // Its keys ask the hold first: Return chooses an item, and no key does that during the hold.
        #expect(menu.contains("local([.keyDown], open) { event in key(event) }"))
        #expect(try Self.body(of: "private static func key(_ event: NSEvent) -> Bool {", in: menu)
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(guardLine))
        // **A right click or a Control click that the hold drops opens no menu**: the watch asks the hold's one
        // function before it looks for a menu, and does nothing with a click that does not reach the app. The hold's
        // own watch then gets the same answer for that event, and drops it.
        let opens = try Self.body(of: "private static func open(_ event: NSEvent) -> Bool {", in: menu)
        let asks = try #require(opens.range(of: "guard AppFront.reaches(event) else { return false }"))
        let looks = try #require(opens.range(of: "frameView.hitTest(event.locationInWindow)"))
        let shows = try #require(opens.range(of: "return show(menu, for: event, in: window)"))
        #expect(asks.upperBound < looks.lowerBound && looks.upperBound < shows.lowerBound)
        #expect(menu.components(separatedBy: "FleetMenu.show(").count == 2)
        // The other three watches of an open menu ask nothing: a menu is a card (`over`), under which no page
        // changes, and with the two guards above no menu opens and no item is chosen during a hold.
    }
}
