import Foundation
import Testing
@testable import FleetCore

/// The rules of a later change of the fleet's shape (`ShapeChange.swift`) and of the step where a fleet stands
/// (`ServersStep.now`), with the example fleet of the pictures: the hub, and Juno (the manager), Research and Mail.
struct ShapeChangeTests {
    let hub = ShapePlace(name: "hub", hub: true)

    // MARK: Where a fleet stands

    @Test func aFleetReadsAsTheStepThatItsServersShow() {
        #expect(ServersStep.now([ShapePlace(name: "hub", hub: true, agents: ["juno", "research"])]) == .one)
        #expect(ServersStep.now([hub, ShapePlace(name: "worker-1", agents: ["juno", "research", "mail"])]) == .two)
        #expect(ServersStep.now([hub, ShapePlace(name: "worker-1", agents: ["juno"]), ShapePlace(name: "worker-2", agents: ["research"]),
                                 ShapePlace(name: "worker-3", agents: ["mail"])]) == .each)
    }

    @Test func aFleetBetweenTwoStepsHasNone() {
        // An agent added on a server of its own beside a 2-server team.
        #expect(ServersStep.now([hub, ShapePlace(name: "worker-1", agents: ["juno", "research"]),
                                 ShapePlace(name: "worker-2", agents: ["mail"])]) == nil)
        // The manager beside the hub, and an agent on a server of its own.
        #expect(ServersStep.now([ShapePlace(name: "hub", hub: true, agents: ["juno"]), ShapePlace(name: "worker-1", agents: ["mail"])]) == nil)
        // No agent that the slider moves.
        #expect(ServersStep.now([hub, ShapePlace(name: "mac-1", mac: true, agents: ["juno"])]) == nil)
    }

    /// The manager alone on its server fits two steps: the step that the owner chose last settles it, and with none the
    /// first run's default.
    @Test func theKeptWordSettlesATie() {
        let alone = [hub, ShapePlace(name: "worker-1", agents: ["juno"])]
        #expect(ServersStep.now(alone) == .two)
        #expect(ServersStep.now(alone, kept: .two) == .two)
        #expect(ServersStep.now(alone, kept: .each) == .each)
        // A fleet that fits one step only keeps it, whatever the word says.
        #expect(ServersStep.now([hub, ShapePlace(name: "worker-1", agents: ["juno", "mail"])], kept: .each) == .two)
    }

    @Test func macsAndAgentsThatRunAloneDoNotChangeTheStep() {
        let places = [hub, ShapePlace(name: "worker-1", agents: ["juno", "research"]), ShapePlace(name: "mac-1", mac: true, agents: ["outreach"]),
                      ShapePlace(name: "ops-1", agents: ["devops"], alone: true)]
        #expect(ServersStep.now(places) == .two)
    }

    // MARK: Toward more secure

    /// Picture 3: from 2 servers to 1 per agent, the manager keeps its server and the two others get a new one each.
    @Test func theTeamSplitsOntoNewServers() {
        let plan = ShapeChange.plan([hub, ShapePlace(name: "worker-1", agents: ["juno", "research", "mail"])], manager: "juno", to: .each,
                                    hubShared: false, joins: false)
        #expect(plan.boxes == [.init(server: "hub", hub: true), .init(server: "worker-1", agents: ["juno"]),
                               .init(server: nil, agents: ["research"]), .init(server: nil, agents: ["mail"])])
        #expect(plan.moves == [.init(agent: "research", box: 2), .init(agent: "mail", box: 3)])
        #expect(plan.newServers == 2 && plan.emptied.isEmpty && plan.blocked == nil)
        #expect(plan.signIns == ["research", "mail"])
    }

    /// An empty server of the fleet takes an agent before a new one is made.
    @Test func anEmptyServerOfTheFleetIsUsedFirst() {
        let plan = ShapeChange.plan([hub, ShapePlace(name: "worker-1", agents: ["juno", "research", "mail"]), ShapePlace(name: "spare")],
                                    manager: "juno", to: .each, hubShared: false, joins: false)
        #expect(plan.boxes[2] == .init(server: "spare", agents: ["research"]))
        #expect(plan.boxes[3] == .init(server: nil, agents: ["mail"]))
        #expect(plan.newServers == 1)
    }

    /// Separating the hub: the manager beside the hub moves to a server of its own, and moves last.
    @Test func theAgentsLeaveTheHubsServerAndTheManagerMovesLast() {
        let plan = ShapeChange.plan([ShapePlace(name: "hub", hub: true, agents: ["juno", "research"])], manager: "juno", to: .each,
                                    hubShared: true, joins: false)
        #expect(plan.boxes.first == .init(server: "hub", hub: true))
        #expect(plan.moves.map(\.agent) == ["research", "juno"])
        #expect(plan.newServers == 2 && plan.blocked == nil)
    }

    /// From 1 server to 2: the first agent goes to a new, empty server, and each next one onto a server that has one.
    @Test func aTeamThatJoinsOnANewServerNeedsTheHubsJoins() {
        let places = [ShapePlace(name: "hub", hub: true, agents: ["juno", "research"])]
        #expect(ShapeChange.plan(places, manager: "juno", to: .two, hubShared: true, joins: false).blocked == .joins)
        let plan = ShapeChange.plan(places, manager: "juno", to: .two, hubShared: true, joins: true)
        #expect(plan.blocked == nil && plan.newServers == 1)
        #expect(plan.moves == [.init(agent: "research", box: 1), .init(agent: "juno", box: 1)])
        // The manager alone moves to its new server with no join at all.
        let alone = ShapeChange.plan([ShapePlace(name: "hub", hub: true, agents: ["juno"])], manager: "juno", to: .two, hubShared: false,
                                     joins: false)
        #expect(alone.blocked == nil && alone.moves == [.init(agent: "juno", box: 1)])
    }

    // MARK: Toward lower cost

    /// Picture 5: from 1 per agent to 2 servers, the two agents join the manager's server, and two servers are emptied.
    /// Until the app deletes an emptied server at its provider, the plan says so and has no press.
    @Test func theTeamJoinsTheManagersServer() {
        let places = [hub, ShapePlace(name: "worker-1", agents: ["juno"]), ShapePlace(name: "worker-2", agents: ["research"]),
                      ShapePlace(name: "worker-3", agents: ["mail"])]
        let plan = ShapeChange.plan(places, manager: "juno", to: .two, hubShared: false, joins: true)
        #expect(plan.boxes == [.init(server: "hub", hub: true), .init(server: "worker-1", agents: ["juno", "research", "mail"])])
        #expect(plan.moves == [.init(agent: "research", box: 1), .init(agent: "mail", box: 1)])
        #expect(plan.emptied == ["worker-2", "worker-3"] && plan.newServers == 0 && plan.blocked == .empties)
        // A hub that cannot join agents yet: the join is the first reason.
        #expect(ShapeChange.plan(places, manager: "juno", to: .two, hubShared: false, joins: false).blocked == .joins)
    }

    @Test func oneServerNeedsAHubWhoseServerTakesAgents() {
        let places = [hub, ShapePlace(name: "worker-1", agents: ["juno", "research"])]
        #expect(ShapeChange.plan(places, manager: "juno", to: .one, hubShared: false, joins: true).blocked == .hubTakesNone)
        let plan = ShapeChange.plan(places, manager: "juno", to: .one, hubShared: true, joins: true)
        #expect(plan.emptied == ["worker-1"])
        #expect(plan.boxes == [.init(server: "hub", hub: true, agents: ["juno", "research"])])
        #expect(plan.moves.map(\.agent) == ["research", "juno"])
    }

    /// A change that leaves a server with no agent waits until the app deletes such a server at its provider: a shared
    /// hub and the manager alone on worker-1, to 1 server, needs no join and would still leave worker-1 paid for.
    @Test func aChangeThatEmptiesAServerIsBlocked() {
        let places = [hub, ShapePlace(name: "worker-1", agents: ["juno"])]
        let plan = ShapeChange.plan(places, manager: "juno", to: .one, hubShared: true, joins: false)
        #expect(plan.emptied == ["worker-1"] && plan.blocked == .empties)
        let joined = ShapeChange.plan([hub, ShapePlace(name: "worker-1", agents: ["juno"]), ShapePlace(name: "worker-2", agents: ["mail"])],
                                      manager: "juno", to: .two, hubShared: false, joins: true)
        #expect(joined.blocked == .empties)
    }

    /// An empty server that the hub does not offer for a new agent (offline, busy, no service) is not used.
    @Test func anEmptyServerThatTheHubDoesNotOfferIsNotUsed() {
        let plan = ShapeChange.plan([hub, ShapePlace(name: "worker-1", agents: ["juno", "research"]), ShapePlace(name: "spare", available: false)],
                                    manager: "juno", to: .each, hubShared: false, joins: false)
        #expect(plan.boxes[2] == .init(server: nil, agents: ["research"]) && plan.newServers == 1)
    }

    /// The agents of a hub that runs on a Mac stay in its box at every step.
    @Test func theHubsOwnAgentsThatStayAreDrawnInItsBox() {
        let places = [ShapePlace(name: "hub", hub: true, mac: true, agents: ["juno"]), ShapePlace(name: "worker-1", agents: ["research", "mail"])]
        let plan = ShapeChange.plan(places, manager: "juno", to: .each, hubShared: false, joins: false)
        #expect(plan.boxes.first == .init(server: "hub", hub: true, agents: ["juno"]))
        #expect(plan.moves.map(\.agent) == ["mail"])
    }

    // MARK: What stays

    @Test func macsAndAgentsThatRunAloneStayWhereTheyAre() {
        let places = [hub, ShapePlace(name: "worker-1", agents: ["juno", "research"]), ShapePlace(name: "mac-1", mac: true, agents: ["outreach"]),
                      ShapePlace(name: "ops-1", agents: ["devops"], alone: true)]
        let plan = ShapeChange.plan(places, manager: "juno", to: .each, hubShared: false, joins: false)
        #expect(!plan.moves.contains { ["outreach", "devops"].contains($0.agent) })
        #expect(plan.boxes.suffix(2) == [.init(server: "mac-1", mac: true, agents: ["outreach"]), .init(server: "ops-1", agents: ["devops"])])
    }

    @Test func theStepWhereTheFleetStandsChangesNothing() {
        let places = [hub, ShapePlace(name: "worker-1", agents: ["juno", "research"])]
        let plan = ShapeChange.plan(places, manager: "juno", to: .two, hubShared: false, joins: false)
        #expect(!plan.changes && plan.blocked == nil && plan.emptied.isEmpty && plan.newServers == 0)
    }
}
