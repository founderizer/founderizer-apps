import Foundation
import Testing
@testable import FleetCore

/// **The rules of the first run's new pages** (`FleetShape.swift`): the step that the slider opens on, what runs where
/// at each step, the count in words, and the manager's name. The counts of the two example teams are the ones on the
/// pictures that the owner approved on 14 November 2026.
struct FleetShapeTests {
    /// The team of pictures 04 to 09: two agents, and neither needs a browser.
    private let small = FleetPlan(manager: "Juno", agents: [
        .init(name: "research", role: "Research"),
        .init(name: "mail", role: "Mail", asksFirst: "before it sends", uses: .init(kind: .mailbox, name: "ana@example.com")),
    ])

    /// The team of picture 10: five agents, and one of them needs a browser.
    private let large = FleetPlan(manager: "Juno", agents: [
        .init(name: "support", role: "Customer Support"),
        .init(name: "web", role: "Web app", uses: .init(kind: .repository, name: "northwind/shop")),
        .init(name: "billing", role: "Billing", uses: .init(kind: .key, name: "Stripe key")),
        .init(name: "research", role: "Research"),
        .init(name: "outreach", role: "Outreach", uses: .init(kind: .login, name: "LinkedIn login"), needsBrowser: true),
    ])

    @Test func theSliderOpensOnTheMiddleStepForPersonalUseAndOnTheLastForABusiness() {
        #expect(ServersStep.opens(for: .personal) == .two)
        #expect(ServersStep.opens(for: .business) == .each)
        #expect(ServersStep.allCases == [.one, .two, .each])
    }

    @Test func oneServerHoldsTheHubTheManagerAndEachAgent() {
        #expect(small.places(.one) == [FleetPlace(kind: .server, parts: [.hub, .manager, .agent(0), .agent(1)])])
    }

    @Test func twoServersKeepTheHubApartFromTheTeam() {
        #expect(small.places(.two) == [FleetPlace(kind: .server, parts: [.hub]),
                                       FleetPlace(kind: .server, parts: [.manager, .agent(0), .agent(1)])])
    }

    @Test func theLastStepGivesTheHubTheManagerAndEachAgentAServer() {
        #expect(small.places(.each) == [FleetPlace(kind: .server, parts: [.hub]), FleetPlace(kind: .server, parts: [.manager]),
                                        FleetPlace(kind: .server, parts: [.agent(0)]), FleetPlace(kind: .server, parts: [.agent(1)])])
    }

    @Test func theCountsOfThePictures() {
        #expect(small.count(.one).words == "1 server")
        #expect(small.count(.two).words == "2 servers")
        #expect(small.count(.each).words == "4 servers")
        #expect(large.count(.each).words == "6 servers and 1 Mac")
        #expect(large.count(.each).serverWords == "6 servers")
    }

    @Test func anAgentThatNeedsABrowserRunsOnAMacAtEachStep() {
        #expect(large.places(.one).last == FleetPlace(kind: .mac, parts: [.agent(4)]))
        #expect(large.places(.two).last == FleetPlace(kind: .mac, parts: [.agent(4)]))
        #expect(large.places(.each).last == FleetPlace(kind: .mac, parts: [.agent(4)]))
        #expect(large.count(.one) == FleetCount(servers: 1, macs: 1))
        #expect(large.count(.two).words == "2 servers and 1 Mac")
        #expect(!large.places(.one)[0].parts.contains(.agent(4)))
    }

    /// A Mac runs one agent, at each step of the slider (the owner's answer of 10 November 2026: "one agent on each
    /// Mac"): two agents that need a browser are two Macs, also where the other agents share a server.
    @Test func eachAgentThatNeedsABrowserHasAMacOfItsOwnAtEachStep() {
        var plan = large
        plan.agents[0].needsBrowser = true
        for step in ServersStep.allCases {
            let macs = plan.places(step).filter { $0.kind == .mac }
            #expect(macs == [FleetPlace(kind: .mac, parts: [.agent(0)]), FleetPlace(kind: .mac, parts: [.agent(4)])])
            #expect(plan.places(step).allSatisfy { $0.kind == .server || $0.parts.count == 1 })
        }
        #expect(plan.count(.one).words == "1 server and 2 Macs")
        #expect(plan.count(.two).words == "2 servers and 2 Macs")
        #expect(plan.count(.each).words == "5 servers and 2 Macs")
    }

    @Test func aTeamWithNoAgentStillHasTheHubAndTheManager() {
        let alone = FleetPlan(manager: "Juno", agents: [])
        #expect(alone.places(.one) == [FleetPlace(kind: .server, parts: [.hub, .manager])])
        #expect(alone.count(.each).words == "2 servers")
    }

    @Test func eachPartIsOnOneMachineAtEachStep() {
        for step in ServersStep.allCases {
            let parts = large.places(step).flatMap(\.parts)
            #expect(parts.count == large.agents.count + 2)
            #expect(parts.filter { $0 == .hub }.count == 1)
            #expect(parts.filter { $0 == .manager }.count == 1)
            for index in large.agents.indices { #expect(parts.filter { $0 == .agent(index) }.count == 1) }
        }
    }

    @Test func theSentencesOfTheThreeSteps() {
        #expect(ServersStep.one.means.hasPrefix("Everything runs on one server."))
        #expect(ServersStep.two.means.hasSuffix("but not those keys."))
        #expect(ServersStep.each.means.hasSuffix("finds nothing else there."))
    }

    @Test(arguments: [("Juno", "juno"), ("  Juno ", "juno"), ("ops-2", "ops-2"), ("MAX", "max"), ("Vaulter", "vaulter"),
                      (String(repeating: "a", count: 26), String(repeating: "a", count: 26))])
    func aNameThatTheHubTakes(typed: String, name: String) {
        #expect(ManagerName.agentName(typed) == name)
    }

    @Test(arguments: ["", "J", "2fast", "Ana María", "josé", "juno!", "-juno", String(repeating: "a", count: 32)])
    func wordsThatAreNoName(typed: String) {
        #expect(ManagerName.agentName(typed) == nil)
    }

    /// The installer's own rule (`hub.sh --manager-name`): at most 26 characters, and no name that the fleet uses
    /// itself on a server. The hub lets nobody rename the manager afterwards, so the page refuses what the installer
    /// would refuse.
    @Test(arguments: [String(repeating: "a", count: 27), "owner", "Hub", "agents", "channels", "chats", "checks", "git",
                      "pilot", "server", "vault", "watch", "work", "login-juno", "Vault-2"])
    func aNameThatTheInstallerRefuses(typed: String) {
        #expect(ManagerName.agentName(typed) == nil)
    }

    /// A manager with a name of its own is the manager by its role: the reading names it, its chat takes its
    /// messages, and its new request notifies. An agent's request does not, as before.
    @Test func aManagerWithItsOwnNameIsFoundByItsRole() throws {
        func state(_ agents: [[String: Any]]) throws -> HubState {
            try HubState.decode(JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": "named", "time": 1000.0, "ui_features": ["direct_chat"], "agents": agents,
                "tasks": [], "notes": [], "permissions": [],
                "needs": [["id": 2, "by": "juno", "title": "Example", "why": "", "todo": "", "raised": 2, "answered": NSNull()],
                          ["id": 3, "by": "mail", "title": "Example", "why": "", "todo": "", "raised": 3, "answered": NSNull()]],
                "messages": [["request_id": "6F1C2A30-0000-4000-8000-000000000001", "kind": "message", "text": "Hello",
                              "event_id": 1, "created": 1.0, "client": "mac", "recipient": "juno", "read_at": NSNull()]],
                "reports": [["id": 1, "agent": "juno", "text": "Hello", "about": "", "created": 2.0]]]))
        }
        let named = try state([["name": "mail", "role": "worker", "runtime": "claude", "can": [String]()],
                               ["name": "juno", "role": "manager", "runtime": "claude", "can": [String]()]])
        #expect(named.managerName == "juno")
        #expect(named.supportsChat(with: "juno"))
        #expect(try state([["name": "mail", "role": "worker", "runtime": "claude", "can": [String]()]]).managerName == "manager")

        var ledger = NotificationLedger()
        #expect(ledger.observe(context: "hub", needs: [], manager: named.managerName).isEmpty)
        #expect(ledger.observe(context: "hub", needs: named.needs, manager: named.managerName) == [2])

        var timeline = ChatTimeline()
        _ = timeline.update(messages: named.messages, reports: named.reports)
        #expect(timeline.count(for: "juno") == 2)
        #expect(timeline.count(for: "manager") == 0)

        // His message to it on its way: the app's saved request names the manager as the hub's copy does.
        let hub = try #require(URL(string: "https://hub.example"))
        let sent = PendingRequest(hub: hub, database: "named", client: "mac", recipient: "juno", text: "On its way")
        #expect(WordsOnTheirWay.message(to: "juno", pending: sent, kept: nil, receipt: nil, hub: hub, database: "named",
                                        messages: named.messages) == sent)
        #expect(WordsOnTheirWay.message(to: "mail", pending: sent, kept: nil, receipt: nil, hub: hub, database: "named",
                                        messages: named.messages) == nil)
    }

    @Test func theTeamsNamesStartWithTheManager() {
        #expect(small.names == ["juno", "research", "mail"])
        #expect(FleetPlan(manager: "Ana María", agents: []).names == ["manager"])
        #expect(ManagerName.shown("  Juno ") == "Juno")
    }

    // MARK: the graph's places

    /// The layout with a stand-in for the width of a role's words: 7 points for each character.
    private func graph(_ plan: FleetPlan, _ step: ServersStep) -> FleetGraphLayout {
        FleetGraphLayout(plan: plan, step: step) { CGFloat($0.count) * 7 }
    }

    @Test func thePlacesOfThePictureWithTwoServers() {
        let graph = graph(small, .two)
        #expect(graph.height == 139)
        #expect(graph.managerAt == CGPoint(x: 160, y: 53))
        #expect(graph.hubAt == CGPoint(x: 44, y: 53))
        #expect(graph.rows.map(\.y) == [38, 90])
        #expect(graph.islands.map(\.rect) == [CGRect(x: 108, y: 8, width: 364, height: 123), CGRect(x: 0, y: 8, width: 88, height: 92)])
    }

    @Test func theDottedLineStartsAfterTheRoleOfAnAgentThatUsesSomething() {
        let rows = graph(small, .two).rows
        #expect(rows[0].dotted == nil)
        #expect(rows[1].dotted == 332...484)
        var plan = small
        plan.agents[1].role = String(repeating: "m", count: 30)
        #expect(graph(plan, .two).rows[1].dotted == nil)
    }

    @Test func eachPartStandsInItsOwnMachineAtEachStep() {
        let alone = FleetPlan(manager: "Juno", agents: []), one = FleetPlan(manager: "Juno", agents: [small.agents[0]])
        for plan in [small, large, alone, one] {
            for step in ServersStep.allCases {
                let graph = graph(plan, step)
                #expect(graph.rows.map(\.agent).sorted() == Array(plan.agents.indices))
                for island in graph.islands {
                    #expect(island.rect.minX >= 0 && island.rect.maxX <= FleetGraphLayout.width)
                    #expect(island.rect.minY >= 0 && island.rect.maxY <= graph.height)
                }
                for (index, island) in graph.islands.enumerated() {
                    for other in graph.islands[(index + 1)...] { #expect(!island.rect.intersects(other.rect)) }
                }
                for row in graph.rows {
                    let mark = CGRect(x: FleetGraphLayout.markX, y: row.y - 14, width: 28, height: 28)
                    let holds = graph.islands.filter { $0.rect.contains(mark) }
                    #expect(holds.count == 1)
                    #expect(holds.first?.kind == (plan.agents[row.agent].needsBrowser ? .mac : .server))
                }
                // The manager's mark with its two lines of words, and the hub's tile with its one line.
                let manager = CGRect(x: graph.managerAt.x - 18, y: graph.managerAt.y - 18, width: 36, height: 74)
                let hub = CGRect(x: graph.hubAt.x - 18, y: graph.hubAt.y - 18, width: 36, height: 58)
                #expect(graph.islands.filter { $0.rect.contains(manager) }.count == 1)
                #expect(graph.islands.filter { $0.rect.contains(hub) }.count == 1)
                let together = graph.islands.contains { $0.rect.contains(manager) && $0.rect.contains(hub) }
                #expect(together == (step == .one))
            }
        }
    }

    @Test func aTeamOfOneAgentWithAServerEachKeepsTheRoomOfTheManagersIsland() {
        let graph = graph(FleetPlan(manager: "Juno", agents: [small.agents[0]]), .each)
        #expect(graph.height == 124)
        #expect(graph.rows.map(\.y) == [62])
        #expect(graph.islands.count == 3)
    }

    // ------------------------------------------------------------ the first run with the manager first

    /// The page "Your fleet's servers" before a team exists: the hub, the manager and two agents to come, so that each
    /// step is another drawing. Without those agents the last two steps would be the same two servers.
    @Test func beforeATeamExistsEachStepIsAnotherDrawing() {
        #expect(ServersSketch.servers(.one) == [[.hub, .manager, .next, .next]])
        #expect(ServersSketch.servers(.two) == [[.hub], [.manager, .next, .next]])
        #expect(ServersSketch.servers(.each) == [[.hub], [.manager], [.next], [.next]])
        #expect(Set(ServersStep.allCases.map(ServersSketch.servers)).count == 3)
        #expect(ServersStep.allCases.map(ServersSketch.words) == ["1 server", "2 servers", "1 per agent"])
        // `setup_state` gives the step by these names (`FirstRunLayout` of the owner's API, held to the same list there).
        #expect(ServersStep.allCases.map(\.rawValue) == ["one", "two", "each"])
        // The same shape as a team of two has, by the rule of the card "Your fleet".
        for step in ServersStep.allCases {
            #expect(ServersSketch.servers(step).map(\.count) == small.places(step).map(\.parts.count))
        }
    }

    /// The two sentences of a step stand apart on the page, and together they are the sentences of the pictures.
    @Test func aStepsTwoSentences() {
        for step in ServersStep.allCases {
            #expect(step.means == "\(step.fact) \(step.risk)")
            #expect(step.fact.hasSuffix(".") && step.risk.hasPrefix("An agent that breaks out of its account"))
        }
    }

    /// The steps on Back's line: each page of the first way has its step, a build and an install show their own steps,
    /// and the pages after "Name your manager" show none on the way of the owner's own agent.
    @Test func theStepsOfTheFirstRun() {
        #expect(FirstRunSteps.inFlow == FirstRunSteps.allCases)
        #expect(FirstRunSteps.inFlow.map(\.name) == ["Manager", "Servers", "Network", "Provider", "Build"])
        #expect(FirstRunSteps.names == ["Manager", "Servers", "Network", "Provider", "Build"])
        let steps: [(String, FirstRunSteps?)] = [
            ("name", .manager), ("servers", .servers), ("network", .network), ("key", .network), ("cloud", .provider),
            ("token", .provider), ("vps", .provider), ("machine", .provider), ("building", nil), ("installing", nil),
            ("welcome", nil), ("paste", nil), ("done", nil), ("restore", nil), ("address", nil), ("", nil)]
        for (page, step) in steps {
            #expect(FirstRunSteps.of(page: page, named: true) == step, "\(page)")
            #expect(FirstRunSteps.of(page: page, named: false) == (page == "name" ? .manager : nil), "\(page)")
        }
        // No page of the flow has a step that the line does not show.
        for (page, _) in steps {
            if let step = FirstRunSteps.of(page: page, named: true) { #expect(FirstRunSteps.inFlow.contains(step)) }
        }
    }

    /// The steps of the manager's own setup: each page of an agent's setup has its place in the line, the AI provider
    /// comes before the servers (the owner, 16 November 2026), a wait for the provider's install on its server and a
    /// switch are the step Servers, and after the sign-in each step is done.
    @Test func theStepsOfTheManagersSetup() {
        #expect(ManagerSetupSteps.names == ["Manager", "AI provider", "Servers", "Sign in"])
        #expect(ManagerSetupSteps.current(.provider) == 1)
        #expect(ManagerSetupSteps.current(.server) == 2)
        #expect(ManagerSetupSteps.current(.installing(runtime: "claude")) == 2)
        #expect(ManagerSetupSteps.current(.switching(runtime: "codex")) == 2)
        #expect(ManagerSetupSteps.current(.signIn(runtime: "claude")) == 3)
        #expect(ManagerSetupSteps.current(.activate) == ManagerSetupSteps.names.count)
    }

    /// "Name your manager" among the first run's pages: it looks for a fleet as the VPS page does, because the owner's
    /// own agent can install a hub while it shows; it is no start page; Back goes to the welcome page; and no new build
    /// of the app goes in by itself while the owner types there.
    @Test func theNamePageAmongTheFirstRunsPages() {
        #expect(WelcomeRules.looksForAFleet(on: .name, began: false, busy: false))
        #expect(!WelcomeRules.looksForAFleet(on: .name, began: true, busy: false))
        #expect(!WelcomeRules.looksForAFleet(on: .name, began: false, busy: true))
        #expect(!WelcomeRules.looksForAFleet(on: .name, began: false, busy: false, fleet: true))
        #expect(!WelcomeRules.atStart(.name))
        #expect(!WelcomeRules.guideTakesTheApp(on: .name, busy: false))
        #expect(WelcomeRules.back(from: .name) == .welcome)
        #expect(!WelcomeRules.atRest(on: .name, began: false, busy: false))
    }
}
