import FleetCore
import Foundation
import Testing
@testable import FleetOwnerAPI

/// **`setup_state` and `setup_show`**: their facts, the page names, the change number and its wait, the refusals and the
/// one effect of `setup_show` (on the app's side, `SetupBoard`), and the two tools in the program, with a stand-in for the
/// link and for the start of the app: no test starts the real app.
@MainActor
struct OwnerSetupBoardTests {
    /// The facts that a test's app gives, and what its `setup_show` effect was asked.
    final class App {
        var facts: SetupFacts
        var shown: [(String, String)] = []
        var refuses: String?
        init(_ facts: SetupFacts) { self.facts = facts }
    }

    nonisolated static func facts(_ firstRun: SetupFirstRun = .none, hub: SetupFacts.Hub = .none) -> SetupFacts {
        SetupFacts(version: "0.1.300", build: 301, hub: hub, firstRun: firstRun, programs: ["codex", "claude_code"])
    }

    nonisolated static func page(_ page: FirstRunPage, title: String? = nil, works: Bool = false, began: Bool = false,
                     holds: Bool = false, provider: String? = nil) -> SetupFirstRun {
        SetupFirstRun(shows: true, page: page, title: title, works: works, began: began, holdsWindow: holds,
                      provider: provider, atStart: page == .welcome || page == .paste)
    }

    func board(_ app: App, waitMax: Duration = .seconds(1)) -> SetupBoard {
        SetupBoard(read: { app.facts }, show: { page, seen in
            app.shown.append((page, seen))
            if let words = app.refuses { return words }
            if page == "welcome" { app.facts.firstRun = Self.page(.welcome); app.facts.place = .firstRun(.welcome) }
            if page == "name" { app.facts.firstRun = Self.page(.name); app.facts.place = .firstRun(.name) }
            // A place of the fleet's own pages: the stand-in for the app's change of page.
            if let place = SetupShow.place(of: page) { app.facts.place = place }
            return nil
        }, waitMax: waitMax)
    }

    func ask(_ board: SetupBoard, _ tool: String, _ fields: [String: JSONValue] = [:],
             set: String = "owner") async -> OwnerChannel.Answer {
        await board.answer(OwnerChannel.Request(set: set, tool: tool, fields: fields))
    }

    // ------------------------------------------------------------ the facts

    /// **The keys of `setup_state`, all of them**: a field added to the answer fails here, and with it any field of a
    /// secret's kind. The values are fixed names, booleans and numbers, or texts of fixed lists.
    /// **The layout** is the owner's choice on the page `servers` by its fixed name, null before that choice and for a
    /// first run that does not show.
    @Test func theLayoutIsAFixedNameOrNull() {
        for layout in FirstRunLayout.allCases {
            var state = Self.page(.vps)
            state.layout = layout
            #expect(Self.facts(state).json(change: 1, map: true)["first_run"]?["layout"] == .string(layout.rawValue))
            state.shows = false
            #expect(Self.facts(state).json(change: 1, map: true)["first_run"]?["layout"] == .null)
        }
        #expect(FirstRunLayout.allCases.map(\.rawValue) == ["one", "two", "each"])
        #expect(Self.facts(Self.page(.servers)).json(change: 1, map: true)["first_run"]?["layout"] == .null)
    }

    /// **The manager's AI provider** is the owner's choice on the page `ai_provider` by its fixed name (the program's
    /// name on a server, as `runtime` of `install_hub` has it), null before that choice and for a first run that does
    /// not show.
    @Test func theAIProviderIsAFixedNameOrNull() {
        for provider in FirstRunAI.allCases {
            var state = Self.page(.servers)
            state.aiProvider = provider
            #expect(Self.facts(state).json(change: 1, map: true)["first_run"]?["ai_provider"] == .string(provider.rawValue))
            state.shows = false
            #expect(Self.facts(state).json(change: 1, map: true)["first_run"]?["ai_provider"] == .null)
        }
        #expect(FirstRunAI.allCases.map(\.rawValue) == ["claude", "codex"])
        #expect(Self.facts(Self.page(.aiProvider)).json(change: 1, map: true)["first_run"]?["ai_provider"] == .null)
    }

    @Test func theAnswerHasTheseKeysAndNoOther() {
        let allowedTop: Set<String> = ["change", "app", "hub", "first_run", "programs", "place", "places", "over",
                                       "show", "in_front"]
        let allowedFirst: Set<String> = ["shows", "page", "title", "works", "began", "holds_window", "provider", "layout",
                                         "ai_provider"]
        var states: [SetupFirstRun] = [.none]
        for page in FirstRunPage.allCases {
            for title in [nil] + FirstRunPage.titles.sorted() {
                states.append(Self.page(page, title: title, works: true, began: true, holds: true, provider: "hetzner"))
            }
        }
        let secretWords = try! NSRegularExpression(pattern: "token|key|pass|secret|code|address|account|mail|user",
                                                   options: .caseInsensitive)
        for state in states {
            for hub in [SetupFacts.Hub.none, .set, .answers] {
                for noChange in [false, true] {
                    let json = Self.facts(state, hub: hub).json(change: 7, noChange: noChange, map: true)
                    let top = Set(json.object!.keys)
                    #expect(top == (noChange ? allowedTop.union(["no_change"]) : allowedTop))
                    #expect(Set(json["first_run"]!.object!.keys) == allowedFirst)
                    #expect(Set(json["app"]!.object!.keys) == ["version", "build"])
                    for key in top.union(allowedFirst) {
                        let range = NSRange(location: 0, length: key.utf16.count)
                        #expect(secretWords.firstMatch(in: key, range: range) == nil, "a key of a secret's kind: \(key)")
                    }
                    let first = json["first_run"]!
                    if let page = first["page"]?.string { #expect(FirstRunPage(rawValue: page) != nil) }
                    if let title = first["title"]?.string { #expect(FirstRunPage.titles.contains(title)) }
                    if let provider = first["provider"]?.string { #expect(SetupFacts.providers.contains(provider)) }
                    #expect(first["layout"] == .null)
                    #expect(first["ai_provider"] == .null)
                    #expect(json["hub"] == .string(hub.rawValue))
                    #expect(json["place"] == .string("none") && json["places"] == .array([]))
                    #expect(json["over"] == .string("nothing"))
                    #expect(json["show"] == .string("no_reading") && json["in_front"] == .bool(false))
                    // **Without the map, the answer is the one of before it** (a set that reads no agent's name).
                    let bare = Self.facts(state, hub: hub).json(change: 7, noChange: noChange, map: false)
                    #expect(Set(bare.object!.keys) == top.subtracting(["place", "places", "over", "show", "in_front"]))
                }
            }
        }
    }

    /// **The place and the places**: the names of `AppPlace`, a place that changes moves the number and ends a wait,
    /// and an answer without the map has neither key.
    @Test func thePlaceIsInTheAnswerAndMovesTheNumber() async {
        var facts = Self.facts(hub: .answers)
        facts.place = .agentSetup("nova", .provider)
        facts.places = AppPlace.places(hasReading: true, settings: [.general, .status], apps: [.github], canAdd: true)
        let json = facts.json(change: 4, map: true)
        #expect(json["place"] == .string("agent.nova.setup.provider"))
        #expect(json["places"] == .array(["needs", "tasks", "agents", "settings.general", "settings.status", "app.github",
                                          "add_server", "add_agent"].map(JSONValue.string)))
        let bare = facts.json(change: 4, map: false)
        #expect(bare["place"] == nil && bare["places"] == nil && bare["over"] == nil)
        #expect(bare["show"] == nil && bare["in_front"] == nil)
        // The answer's own default is without the map: a set that comes later gets it only when its route asks.
        #expect(facts.json(change: 4) == bare)
        #expect(bare == Self.facts(hub: .answers).json(change: 4, map: false))
        // A name out of its alphabet never reaches the answer.
        facts.place = .server("Example Server 1")
        #expect(facts.json(change: 4, map: true)["place"] == .string("server"))

        let app = App(Self.facts())
        let board = board(app)
        async let answer = ask(board, "setup_state", ["after": .int(1)])
        for _ in 0..<10_000 where board.waiting == 0 { await Task.yield() }
        #expect(board.waiting == 1)
        app.facts.place = .addServer(.ways)
        board.refresh()
        let changed = await answer
        #expect(changed == .result(app.facts.json(change: 2, map: true)))
        guard case .result(let value) = changed else { return }
        #expect(value["place"] == .string("add_server.ways"))
        app.facts.places = [.needs]
        board.refresh()
        #expect(board.change == 3)
        board.refresh()
        #expect(board.change == 3)
        // **A card over the page, or a second window, is in the answer and moves the number**: the place stays.
        for (over, change) in [(AppOver.card, Int64(4)), (.window, 5), (.nothing, 6)] {
            app.facts.over = over
            board.refresh()
            #expect(board.change == change)
            let now = await ask(board, "setup_state", [:])
            guard case .result(let read) = now else { Issue.record("no answer"); return }
            #expect(read["over"] == .string(over.rawValue) && read["place"] == .string("add_server.ways"))
        }
        // A read of the same windows moves nothing.
        board.refresh()
        #expect(board.change == 6)
        // **Whether a show can change the page, and whether the window is in front, are in the answer and move
        // the number**: the first by its fixed name, the second as a boolean.
        var change: Int64 = 6
        for show in ShowNow.allCases where show != .noReading {
            app.facts.show = show
            board.refresh()
            change += 1
            #expect(board.change == change)
            let now = await ask(board, "setup_state", [:])
            guard case .result(let read) = now else { Issue.record("no answer"); return }
            #expect(read["show"] == .string(show.rawValue))
        }
        for inFront in [true, false] {
            app.facts.inFront = inFront
            board.refresh()
            change += 1
            #expect(board.change == change)
            let now = await ask(board, "setup_state", [:])
            guard case .result(let read) = now else { Issue.record("no answer"); return }
            #expect(read["in_front"] == .bool(inFront))
        }
        board.refresh()
        #expect(board.change == change)
    }

    /// **A wait that ends by time reads the facts once more**: a fact that no watch told (a menu or a hover's words
    /// over the page change no key window) is in the answer with its new number, and never under "no change".
    @Test func theEndOfAWaitReadsTheFactsAgain() async {
        let app = App(Self.facts(hub: .answers))
        let board = board(app, waitMax: .milliseconds(200))
        async let answer = ask(board, "setup_state", ["after": .int(1)])
        for _ in 0..<10_000 where board.waiting == 0 { await Task.yield() }
        #expect(board.waiting == 1)
        // The fact changes, and nothing tells the board: no `refresh`.
        app.facts.over = .card
        let late = await answer
        #expect(late == .result(app.facts.json(change: 2, map: true)))
        guard case .result(let read) = late else { Issue.record("no answer"); return }
        #expect(read["over"] == .string("card") && read["no_change"] == nil)
        // With no change the wait still says so, with the same number.
        #expect(await ask(board, "setup_state", ["after": .int(2)])
                == .result(app.facts.json(change: 2, noChange: true, map: true)))
    }

    /// A value that is no fixed name is left out: a server's address as a title, a provider or a program that the list
    /// does not have, a version with letters.
    @Test func aValueOutsideItsListIsLeftOut() {
        var facts = Self.facts(Self.page(.otherVPS, title: "203.0.113.9", provider: "root@203.0.113.9"))
        facts.programs = ["codex", "sk-example"]
        facts.version = "0.1.300 secret"
        let json = facts.json(change: 1, map: true)
        #expect(json["first_run"]?["title"] == .null)
        #expect(json["first_run"]?["provider"] == .null)
        #expect(json["programs"] == .array([.string("codex")]))
        #expect(json["app"]?["version"] == .string(""))
    }

    @Test func noFirstRunGivesNoPageAndNoWork() {
        let json = Self.facts(SetupFirstRun(shows: false, page: .token, title: "Your %@ token", works: true, began: true,
                                            holdsWindow: true, provider: "hetzner", atStart: false)).json(change: 2, map: true)
        #expect(json["first_run"] == .object(["shows": .bool(false), "page": .null, "title": .null,
                                              "works": .bool(false), "began": .bool(false),
                                              "holds_window": .bool(false), "provider": .null,
                                              "layout": .null, "ai_provider": .null]))
        #expect(json["app"] == .object(["version": .string("0.1.300"), "build": .int(301)]))
        #expect(json["programs"] == .array([.string("claude_code"), .string("codex")]))
    }

    // ------------------------------------------------------------ the names, against the app

    /// **Each step of the first run has a name**: the cases of `FirstRunModel.Step`, read from the app's source, are each
    /// a key of the table, and each name but `building` (the app's own for a provider's build) is a step's.
    @Test func everyStepOfTheFirstRunHasAName() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer/FirstRunView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "enum Step: Equatable {"))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let pattern = try NSRegularExpression(pattern: #"^\s*case (\w+)"#, options: .anchorsMatchLines)
        let cases = pattern.matches(in: body, range: NSRange(body.startIndex..., in: body))
            .map { (body as NSString).substring(with: $0.range(at: 1)) }
        #expect(cases.count == 15)
        #expect(Set(cases) == Set(FirstRunPage.ofStep.keys))
        #expect(Set(FirstRunPage.ofStep.values).union([.building]) == Set(FirstRunPage.allCases))
        #expect(Set(FirstRunPage.allCases.map(\.rawValue)) == ["welcome", "paste", "error_reports", "name", "ai_provider", "servers", "vps",
                                                               "tailscale", "tailscale_key",
                                                               "token", "building", "other_vps", "machine",
                                                               "installing", "address", "done"])
    }

    /// Each title that `setup_state` may give is a key of the app's string table in English.
    @Test func everyTitleIsAKeyOfTheAppsStringTable() throws {
        let table = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Localization/Localizable.xcstrings")
        let strings = try JSONSerialization.jsonObject(with: Data(contentsOf: table)) as? [String: Any]
        let keys = Set((strings?["strings"] as? [String: Any] ?? [:]).keys)
        for title in FirstRunPage.titles { #expect(keys.contains(title), "no key \(title)") }
    }

    /// The providers and the programs by the names of the app's own types; the start pages by `WelcomeRules`.
    @Test func theNamesAreTheAppsOwn() {
        #expect(SetupFacts.providers == Set(CloudProvider.allCases.map(\.rawValue)))
        #expect(Set(SetupFacts.programNames.keys) == Set(AgentPrograms.Program.allCases.map(\.rawValue)))
        #expect(WelcomeRules.atStart(.welcome) && WelcomeRules.atStart(.paste))
        #expect(!WelcomeRules.atStart(.cloud) && !WelcomeRules.atStart(.other))
    }

    // ------------------------------------------------------------ the change number and after

    @Test func theNumberGoesUpAtEachChangeAndOnlyThen() async {
        let app = App(Self.facts())
        let board = board(app)
        #expect(await ask(board, "setup_state") == .result(app.facts.json(change: 1, map: true)))
        board.refresh()
        #expect(board.change == 1)
        app.facts.hub = .set
        board.refresh()
        #expect(board.change == 2)
        app.facts.firstRun = Self.page(.welcome, title: "Your own team of AI agents")
        #expect(await ask(board, "setup_state") == .result(app.facts.json(change: 3, map: true)))
    }

    @Test func afterAnOlderNumberAnswersAtOnce() async {
        let app = App(Self.facts())
        let board = board(app)
        app.facts.hub = .answers
        board.refresh()
        #expect(await ask(board, "setup_state", ["after": .int(1)]) == .result(app.facts.json(change: 2, map: true)))
        // A number that this app never gave (it started again): at once too.
        #expect(await ask(board, "setup_state", ["after": .int(40)]) == .result(app.facts.json(change: 2, map: true)))
    }

    @Test func afterTheSameNumberAnswersOnTheNextChange() async {
        let app = App(Self.facts())
        let board = board(app)
        async let answer = ask(board, "setup_state", ["after": .int(1)])
        // A bound of looks: a regression fails here at once, and the answer below fails within the 1 s of `waitMax`.
        for _ in 0..<10_000 where board.waiting == 0 { await Task.yield() }
        #expect(board.waiting == 1)
        app.facts.firstRun = Self.page(.vps, title: "A VPS for your fleet")
        board.refresh()
        #expect(await answer == .result(app.facts.json(change: 2, map: true)))
        #expect(board.waiting == 0)
    }

    @Test func afterWithNoChangeSaysSoAtTheBound() async {
        let app = App(Self.facts())
        let board = board(app, waitMax: .milliseconds(50))
        #expect(await ask(board, "setup_state", ["after": .int(1)])
                == .result(app.facts.json(change: 1, noChange: true, map: true)))
        #expect(board.waiting == 0)
        #expect(SetupBoard.waitLimit == .seconds(50))
    }

    @Test func setupStateRefusesWhatItDoesNotTake() async {
        let board = board(App(Self.facts()))
        #expect(await ask(board, "setup_state", ["after": .int(-1)])
                == .refused("after must be a whole number of 0 or more: the change of an earlier setup_state."))
        #expect(await ask(board, "setup_state", ["after": .string("3")])
                == .refused("after must be a whole number of 0 or more: the change of an earlier setup_state."))
        #expect(await ask(board, "setup_state", ["token": .string("x")])
                == .refused("setup_state takes only after, not token."))
        #expect(await ask(board, "setup_state", set: "guide") == .refused("The Founderizer app's link has no set guide."))
        guard case .refused(let words) = await ask(board, "rent_server") else { Issue.record("taken"); return }
        #expect(words.hasPrefix("The Founderizer app's link has no tool rent_server for the set owner"))
    }

    // ------------------------------------------------------------ setup_show

    @Test func setupShowRefusesAndSaysWhy() {
        func refusal(_ page: String, _ seen: String, _ firstRun: SetupFirstRun) -> String? {
            SetupShow.refusal(page: page, seen: seen, firstRun: firstRun)
        }
        // No page of the first run but welcome and name, and no name of a place: the tool's fixed words.
        #expect(refusal("token", "welcome", Self.page(.welcome)) == SetupShow.pageWords)
        #expect(SetupShow.pageWords.hasPrefix("page must be front, or for a first run welcome or name, or one of these "
                                              + "places of the fleet's own pages: needs, tasks, agents, agent.<name>, "))
        // The VPS page is no page of setup_show since "Name your manager" is the first page of the setup: the way to
        // it is that page's own Continue, so no first run that an agent leads goes past the name.
        #expect(refusal("vps", "welcome", Self.page(.welcome)) == SetupShow.pageWords)
        #expect(refusal("vps", "vps", Self.page(.vps)) == SetupShow.pageWords)
        // **The refusal names the place, and says nothing back of what the caller sent as seen.**
        #expect(refusal("name", "paste", Self.page(.welcome))
                == "The place that shows now is first_run.welcome, and seen names another one. Read setup_state again, "
                + "and call setup_show with seen first_run.welcome if the owner should still see another page.")
        #expect(refusal("name", "sk-example token", Self.page(.welcome)) == refusal("name", "paste", Self.page(.welcome)))
        #expect(refusal("welcome", "none", .none)?.hasPrefix("No page of the first run shows") == true)
        #expect(refusal("name", "welcome", Self.page(.welcome, works: true))?.hasPrefix("Work of the first run runs now") == true)
        #expect(refusal("welcome", "vps", Self.page(.vps, began: true))?.hasPrefix("An install of this first run began") == true)
        #expect(refusal("welcome", "vps", Self.page(.vps, holds: true))?.hasPrefix("The first run holds the window") == true)
        // At its start pages, an install that began earlier does not hold the page.
        #expect(refusal("name", "welcome", Self.page(.welcome, began: true)) == nil)
        #expect(refusal("welcome", "paste", Self.page(.paste)) == nil)
        #expect(refusal("welcome", "vps", Self.page(.vps)) == nil)
        #expect(refusal("name", "welcome", Self.page(.welcome)) == nil)
        #expect(refusal("name", "paste", Self.page(.paste)) == nil)
        #expect(refusal("name", "vps", Self.page(.vps)) == nil)
        // On "Name your manager" itself the owner may be typing the name: no change of page from it, to itself too.
        #expect(refusal("name", "name", Self.page(.name))?.hasPrefix("The first run shows its page first_run.name, where the owner may be typing") == true)
        #expect(refusal("welcome", "name", Self.page(.name))?.hasPrefix("The first run shows its page first_run.name, where the owner may be typing") == true)
        // front changes no page: only the page that the agent saw counts.
        #expect(refusal("front", "token", Self.page(.token, works: true)) == nil)
        #expect(refusal("front", "none", .none) == nil)
        #expect(refusal("front", "welcome", .none)?.hasPrefix("The place that shows now is none, and seen names another one.") == true)
    }

    /// **`seen` is the place that `setup_state` gave** (`first_run.<page>`, or the fleet's place with no first run).
    /// For `front`, `welcome` and `name` the short form of before the map passes too: the first run's page alone,
    /// and `none` while no first run shows. Nothing else passes.
    @Test func seenIsThePlaceAndTheShortFormOfBeforeStillPasses() {
        func refusal(_ page: String, _ seen: String, _ firstRun: SetupFirstRun, _ place: AppPlace? = nil) -> String? {
            SetupShow.refusal(page: page, seen: seen, firstRun: firstRun, place: place)
        }
        for (page, shown) in [("name", FirstRunPage.welcome), ("welcome", .paste), ("name", .vps), ("front", .token)] {
            // In the first run's window (no place given) and on the link (the window's place): both forms.
            for place in [nil, AppPlace.firstRun(shown)] {
                #expect(refusal(page, "first_run." + shown.rawValue, Self.page(shown), place) == nil, "\(page) \(shown)")
                #expect(refusal(page, shown.rawValue, Self.page(shown), place) == nil, "\(page) \(shown)")
                #expect(refusal(page, "first_run", Self.page(shown), place) != nil)
                #expect(refusal(page, "none", Self.page(shown), place) != nil)
            }
        }
        // With no first run: front passes with the fleet's place, and with the short form `none`.
        #expect(refusal("front", "tasks", .none, .tasks) == nil)
        #expect(refusal("front", "none", .none, .tasks) == nil)
        #expect(refusal("front", "agent.nova", .none, .agent("nova")) == nil)
        #expect(refusal("front", "agents", .none, .tasks)
                == "The place that shows now is tasks, and seen names another one. Read setup_state again, and call "
                + "setup_show with seen tasks if the owner should still see another page.")
        // A first run whose page the window did not tell: the place is first_run alone.
        #expect(refusal("front", "first_run", .none, .firstRun(nil)) == nil)
        #expect(refusal("welcome", "first_run", .none, .firstRun(nil))?.hasPrefix("No page of the first run shows") == true)
        #expect(Self.page(.vps).seenName == "vps" && SetupFirstRun.none.seenName == "none")
    }

    /// **From no page but a start page** (round 2, S1): the owner may be typing a token, a key or a password there,
    /// and a change of page would erase it. So each other page refuses welcome and name, with no work running too; front
    /// stays allowed.
    @Test func setupShowChangesThePageOnlyFromAStartPage() {
        let others = FirstRunPage.allCases.filter { !SetupShow.startPages.contains($0) }
        #expect(Set(others) == [.errorReports, .name, .aiProvider, .servers, .tailscale, .tailscaleKey, .token, .building, .otherVPS,
                                .machine, .installing, .address, .done])
        for page in others {
            for target in ["welcome", "name"] {
                let words = SetupShow.refusal(page: target, seen: page.rawValue, firstRun: Self.page(page))
                #expect(words == "The first run shows its page first_run.\(page.rawValue), where the owner may be "
                        + "typing or choosing: setup_show changes the page only from first_run.welcome, "
                        + "first_run.paste or first_run.vps. The owner goes on there, or presses Back.",
                        "\(page) to \(target)")
            }
            #expect(SetupShow.refusal(page: "front", seen: page.rawValue, firstRun: Self.page(page)) == nil)
        }
    }

    /// **P3: an ask for the page that shows already changes nothing**: from one start page to another it changes the
    /// page, as Back does.
    @Test func anAskForThePageThatShowsChangesNothing() {
        #expect(!SetupShow.changesPage(to: "welcome", from: Self.page(.welcome)))
        #expect(!SetupShow.changesPage(to: "name", from: Self.page(.name)))
        #expect(!SetupShow.changesPage(to: "front", from: Self.page(.paste)))
        #expect(SetupShow.changesPage(to: "name", from: Self.page(.welcome)))
        #expect(SetupShow.changesPage(to: "name", from: Self.page(.vps)))
        #expect(SetupShow.changesPage(to: "welcome", from: Self.page(.paste)))
        #expect(SetupShow.changesPage(to: "welcome", from: Self.page(.vps)))
    }

    /// One more waiting call than the bound answers "no change" at once; it takes no other caller's wait.
    @Test func theWaitsHaveACountBound() async {
        let app = App(Self.facts())
        let board = board(app, waitMax: .seconds(1))
        var calls: [Task<OwnerChannel.Answer, Never>] = []
        for _ in 0..<SetupBoard.waitsMax {
            calls.append(Task { await ask(board, "setup_state", ["after": .int(1)]) })
        }
        for _ in 0..<10_000 where board.waiting < SetupBoard.waitsMax { await Task.yield() }
        #expect(board.waiting == SetupBoard.waitsMax)
        #expect(await ask(board, "setup_state", ["after": .int(1)]) == .result(app.facts.json(change: 1, noChange: true, map: true)))
        #expect(board.waiting == SetupBoard.waitsMax)
        app.facts.hub = .set
        board.refresh()
        for call in calls { #expect(await call.value == .result(app.facts.json(change: 2, map: true))) }
        #expect(SetupBoard.waitsMax == 4)
    }

    /// The end of a call's connection cancels its task, and its wait ends at once.
    @Test func aCancelledCallEndsItsWaitAtOnce() async {
        let app = App(Self.facts())
        let board = board(app, waitMax: .seconds(1))
        let call = Task { await ask(board, "setup_state", ["after": .int(1)]) }
        for _ in 0..<10_000 where board.waiting == 0 { await Task.yield() }
        #expect(board.waiting == 1)
        let started = ContinuousClock.now
        call.cancel()
        #expect(await call.value == .result(app.facts.json(change: 1, noChange: true, map: true)))
        #expect(ContinuousClock.now - started < .milliseconds(500))
        #expect(board.waiting == 0)
    }

    @Test func setupShowHasOneEffectAndGivesTheNewState() async {
        var first = Self.facts(Self.page(.paste))
        first.place = .firstRun(.paste)
        first.show = .firstRun
        let app = App(first)
        let board = board(app)
        var after = Self.facts(Self.page(.name))
        after.place = .firstRun(.name)
        after.show = .firstRun
        guard case .object(var shown) = after.json(change: 2, map: true) else { return }
        shown["front"] = .string("asked")                   // only what happened: macOS was asked
        // `seen` in the short form of before the map, as a caller of an earlier version sends it.
        #expect(await ask(board, "setup_show", ["page": .string("name"), "seen": .string("paste")]) == .result(.object(shown)))
        #expect(app.shown.count == 1 && app.shown.first! == ("name", "paste"))
        // A refusal before the effect: nothing is asked of the app.
        #expect(await ask(board, "setup_show", ["page": .string("welcome"), "seen": .string("first_run.paste")])
                == .refused(SetupShow.refusal(page: "welcome", seen: "paste", firstRun: Self.page(.name))!))
        // From "Name your manager" no page changes, with the right seen too: the owner may be typing the name.
        #expect(await ask(board, "setup_show", ["page": .string("welcome"), "seen": .string("first_run.name")])
                == .refused(SetupShow.refusal(page: "welcome", seen: "name", firstRun: Self.page(.name))!))
        #expect(app.shown.count == 1)
        app.facts.firstRun = Self.page(.vps)
        app.facts.place = .firstRun(.vps)
        // The app's own refusal (its wizard moved meanwhile) comes as it is.
        app.refuses = "The first run's window closed before it took the page. Call setup_state again."
        #expect(await ask(board, "setup_show", ["page": .string("welcome"), "seen": .string("first_run.vps")])
                == .refused(app.refuses!))
        #expect(await ask(board, "setup_show", ["page": .string("welcome")])
                == .refused("seen must be the place that setup_state gave last, such as tasks, agent.<name> or "
                            + "first_run.welcome."))
        #expect(await ask(board, "setup_show", ["page": .int(3), "seen": .string("vps")]) == .refused(SetupShow.pageWords))
        // A field that the tool does not take: a fixed sentence, which does not say the field's name back.
        #expect(await ask(board, "setup_show", ["page": .string("welcome"), "seen": .string("vps"), "press": .bool(true)])
                == .refused("setup_show takes only page and seen."))
    }
}

/// **The two setup tools in the program**: in `tools`, in `call` and in the MCP form, never through `write`, with no hub
/// and no command lock, and with the app that does not run started through a stand-in.
final class OwnerSetupProgramTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    /// What a stand-in link was asked, and what it answers.
    final class Link: @unchecked Sendable {
        private let lock = NSLock()
        var requests: [OwnerChannel.Request] = []
        var starts = 0
        var pauses = 0
        var fronts = 0
        /// The reaches, in order; the last one stays.
        var reaches: [ChannelClient.Reach]
        var starts_ok = true
        init(_ reaches: [ChannelClient.Reach]) { self.reaches = reaches }

        func appLink(tries: Int = 4) -> AppLink {
            AppLink(exchange: { [self] request, _ in
                lock.lock(); defer { lock.unlock() }
                requests.append(request)
                return reaches.count > 1 ? reaches.removeFirst() : reaches[0]
            }, start: { [self] in
                lock.lock(); defer { lock.unlock() }
                starts += 1
                return starts_ok
            }, pause: { [self] in
                lock.lock(); defer { lock.unlock() }
                pauses += 1
            }, tries: tries, front: { [self] in
                lock.lock(); defer { lock.unlock() }
                fronts += 1
            })
        }
    }

    static let state: JSONValue = OwnerSetupBoardTests.facts().json(change: 1, map: true)

    private func tools(_ link: Link) -> OwnerTools {
        let context = OwnerContext(hubSetting: { nil }, transport: Fixture.transport(), home: home,
                                   userAgent: "founderizer-cli/test", ownBuild: nil, startedBuild: { nil },
                                   clientLabel: { "founderizer-cli/1/test" }, appLink: link.appLink())
        return OwnerTools(table: Fixture.table, context: context)
    }

    private func program() throws -> URL {
        let folder = home.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = Bundle.module.url(forResource: "owner-tools", withExtension: "json", subdirectory: "Fixtures")!
        try? FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("owner-tools.json"))
        return folder.appendingPathComponent("founderizer-cli")
    }

    private func run(_ arguments: [String], link: Link, input: [String] = []) throws -> (Int32, [String], [String]) {
        let out = Lines()
        var errors: [String] = [], lines = input
        let status = OwnerCLI.run(arguments: arguments, executable: try program(), context: tools(link).context,
                                  version: "0.1.0", input: { lines.isEmpty ? nil : lines.removeFirst() },
                                  output: { out.add($0) }, errors: { errors.append($0) })
        return (status, out.all, errors)
    }

    @Test func theTwoToolsAreReadsOfTheSetOwner() throws {
        let listed = tools(Link([.nothingListens])).listed
        #expect(listed.count == 70 + 3 + 6)                 // and the link's six write tools
        for name in OwnerSetupTools.names {
            let tool = try #require(listed.first { $0.name == name })
            #expect(tool.annotations == .object(["readOnlyHint": .bool(true)]))
            #expect(tool.inputSchema["type"] == .string("object"))
            #expect(tool.inputSchema["additionalProperties"] == .bool(false))
            #expect(OwnerTools.verb(of: tool) == .call)
        }
        #expect(OwnerCLI.setupTools == ["setup_state", "setup_show", "setup_diagnosis"])
        let show = try #require(listed.first { $0.name == "setup_show" })
        #expect(show.inputSchema["required"] == .array([.string("page"), .string("seen")]))
        // `page` is front, a page of the first run, or the name of a place: a text, which the app's rules check.
        #expect(show.inputSchema["properties"]?["page"] == .object(["type": .string("string")]))
        #expect(show.inputSchema["properties"]?["seen"] == .object(["type": .string("string")]))
        // Not tools of owner_mcp.py's table.
        #expect(Fixture.table.tool("setup_state") == nil && Fixture.table.tool("setup_show") == nil)
    }

    @Test func toolsAndCallTakeThemAndWriteDoesNot() throws {
        let link = Link([.answer(.result(Self.state))])
        let (status, out, _) = try run(["tools"], link: link)
        #expect(status == 0 && out.count == 79)
        #expect(out.filter { $0.hasPrefix("call ") }.count == 7)
        #expect(out.contains { $0.hasPrefix("call setup_state: Setup: Where the setup of the fleet stands") })
        #expect(out.contains { $0.hasPrefix("call setup_show: Setup: Asks macOS to bring the Founderizer app to the front") })
        let (one, read, said) = try run(["call", "setup_state", #"{"after": 3}"#], link: link)
        #expect(one == 0 && said.isEmpty)
        #expect(read == [Self.state.dumps(indent: 1)])
        #expect(link.requests == [OwnerChannel.Request(set: "owner", tool: "setup_state", fields: ["after": .int(3)])])
        let (two, _, refused) = try run(["write", "setup_show", #"{"page": "front", "seen": "none"}"#], link: link)
        #expect(two == 1 && refused == ["setup_show only reads, so founderizer-cli write does not take it: run "
                                        + "founderizer-cli call setup_show '<json object>'."])
        #expect(link.requests.count == 1)
    }

    @Test func theMCPFormCallsThemWithNoHubAndNoLock() throws {
        let link = Link([.answer(.refused("The page that shows now is welcome, not vps."))])
        let lines = Lines()
        let mcp = OwnerMCP(tools: tools(link), version: "0.1.0", sink: { lines.add($0) })
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "setup_show", "#
                 + #""arguments": {"page": "welcome", "seen": "vps"}}}"#)
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "setup_state", "#
                 + #""arguments": [1]}}"#)
        mcp.finish()
        let said = lines.wait(for: 2)
        let first = try #require(said.first { $0["id"] == .int(1) }?["result"])
        #expect(first["isError"] == .bool(true))
        #expect(first["content"]?.array?.first?["text"] == .string("The page that shows now is welcome, not vps."))
        let second = try #require(said.first { $0["id"] == .int(2) }?["result"])
        #expect(second["isError"] == .bool(true))
        #expect(link.requests.map(\.tool) == ["setup_show"])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".founderizer/lock").path))
    }

    // ------------------------------------------------------------ the app does not run

    @Test func anAppThatCannotStartIsRefusedWithWhatTheOwnerCanDo() {
        let link = Link([.nothingListens])
        link.starts_ok = false
        let (text, isError) = tools(link).call("setup_state", .object([:]))
        #expect(isError && text == AppLink.notStarted)
        #expect(link.starts == 1 && link.pauses == 0 && link.requests.count == 1)
    }

    @Test func aStartedAppThatNeverAnswersEndsAtTheCountOfTries() {
        let link = Link([.nothingListens])
        let (text, isError) = tools(link).call("setup_state", .object([:]))
        #expect(isError && text == AppLink.noAnswer)
        #expect(link.starts == 1 && link.pauses == 4 && link.requests.count == 1 + 4)
        #expect(AppLink.startTries == 40)
    }

    @Test func aStartedAppThatAnswersGivesItsAnswer() {
        let link = Link([.nothingListens, .nothingListens, .answer(.result(Self.state))])
        let (text, isError) = tools(link).call("setup_state", .object([:]))
        #expect(!isError && text == Self.state.dumps(indent: 1))
        #expect(link.starts == 1 && link.pauses == 2)
    }

    /// **The program asks macOS for the front itself** (round 2, R2): after a `setup_show` that the app took, never after
    /// a refusal or a `setup_state`, and after `guide`'s sign.
    @Test func theProgramAsksForTheFrontAfterAShowThatTheAppTook() throws {
        let link = Link([.answer(.result(Self.state))])
        _ = tools(link).call("setup_state", .object([:]))
        #expect(link.fronts == 0)
        _ = tools(link).call("setup_show", .object(["page": .string("front"), "seen": .string("none")]))
        #expect(link.fronts == 1)
        let refused = Link([.answer(.refused("The page that shows now is welcome, not vps."))])
        _ = tools(refused).call("setup_show", .object(["page": .string("welcome"), "seen": .string("vps")]))
        #expect(refused.fronts == 0)
        var order: [String] = []
        let status = OwnerCLI.run(arguments: ["guide"], executable: home.appendingPathComponent("x/founderizer-cli"),
                                  context: tools(link).context, version: "0.1.0", input: { nil }, output: { _ in },
                                  errors: { _ in }, announce: { order.append("announce") },
                                  front: { order.append("front") })
        #expect(status == 0 && order == ["announce", "front"])
    }

    /// A full queue of the app's link is no app that is gone: the program starts nothing and says that it is busy.
    @Test func aBusyAppIsNotStarted() {
        let link = Link([.busy])
        let (text, isError) = tools(link).call("setup_state", .object([:]))
        #expect(isError && text == AppLink.busy)
        #expect(link.starts == 0)
        // During a start, busy is a start that has not ended: the tries go on.
        let starting = Link([.nothingListens, .busy, .busy, .answer(.result(Self.state))])
        let (answer, failed) = tools(starting).call("setup_state", .object([:]))
        #expect(!failed && answer == Self.state.dumps(indent: 1))
        #expect(starting.starts == 1 && starting.pauses == 3)
    }

    @Test func anotherCopyOfTheAppIsAskedNothing() {
        let link = Link([.notTheApp])
        let (text, isError) = tools(link).call("setup_show", .object(["page": .string("front"), "seen": .string("none")]))
        #expect(isError && text == AppLink.notTheApp)
        #expect(link.starts == 0)
    }

    @Test func aProgramWithNoBundleHasNoAppToAsk() {
        let context = OwnerContext(hubSetting: { nil }, transport: Fixture.transport(), home: home,
                                   userAgent: "founderizer-cli/test", ownBuild: nil, startedBuild: { nil },
                                   clientLabel: { "founderizer-cli/1/test" })
        let (text, isError) = OwnerTools(table: Fixture.table, context: context).call("setup_state", nil)
        #expect(isError && text == AppLink.noBundle)
        #expect(AppLink.mac(bundle: nil).tries == 0)
    }

    /// The program's real exchange against a listener of the test's own, through `AppLink`: the whole way, with a
    /// stand-in check and no app.
    @Test func theProgramReachesAListenerThroughTheWholeLink() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fzs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("app.sock").path
        let board = await MainActor.run {
            SetupBoard(read: { OwnerSetupBoardTests.facts() }, show: { _, _ in nil })
        }
        let listener = ChannelListener(path: path, check: StandInCheck(takes: true)) { request in
            await board.answer(request)
        }
        defer { listener.stop() }
        #expect(listener.start() == .listening)
        let appLink = AppLink(exchange: { request, value in
            ChannelClient.exchange(path: path, request: request, value: value, check: StandInCheck(takes: true))
        }, start: { false }, pause: {}, tries: 0)
        let (text, isError) = appLink.call(tool: "setup_state", fields: [:])
        #expect(!isError && JSONValue.parse(text) == Self.state)
        let (shown, shownError) = appLink.call(tool: "setup_show", fields: ["page": .string("front"), "seen": .string("none")])
        #expect(!shownError && JSONValue.parse(shown)?["front"] == .string("asked"))
    }
}
