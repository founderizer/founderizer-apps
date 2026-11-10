import Foundation
import Observation
import Synchronization
import Testing
@testable import FleetCore

// An agent by its role (the owner, 10 November 2026): both apps name an agent by its team.json `title`, its name under
// it on its panel and on Agents, and an agent with no role keeps its name. These tests read the book of their own;
// `AgentNames.shared` belongs to the app that runs, and other tests read it in parallel.

private let roles = AgentNames.roles([("nova", "  Customer   Support "), ("manager", "Fleet Manager"), ("atlas", nil),
                                      ("kai", ""), ("web-dev", "Web Developer")])

@Test func aRoleIsOneLineAndAnEmptyTitleIsNoRole() {
    #expect(roles == ["nova": "Customer Support", "manager": "Fleet Manager", "web-dev": "Web Developer"])
}

@Test func theLabelIsTheRoleElseTheNameWithCapitals() {
    #expect(AgentNames.label("nova", roles: roles) == "Customer Support")
    #expect(AgentNames.label("web-dev", roles: roles) == "Web Developer")
    #expect(AgentNames.label("atlas", roles: roles) == "Atlas")
    #expect(AgentNames.label("mini-2b", roles: roles) == "Mini-2B")
    #expect(AgentNames.label("owner", roles: roles) == "Owner")
}

@Test func theNameStandsUnderTheRoleUnlessTheRoleSaysIt() {
    #expect(AgentNames.under("nova", roles: roles) == "Nova")
    #expect(AgentNames.under("web-dev", roles: roles) == "Web-Dev")
    #expect(AgentNames.under("manager", roles: roles) == nil)       // "Fleet Manager" over "Manager" says it twice
    #expect(AgentNames.under("atlas", roles: roles) == nil)           // no role: the name is the label already
}

@Test func aSearchFindsAnAgentByItsRoleOrByItsName() {
    #expect(AgentNames.matches("nova", "support", roles: roles))
    #expect(AgentNames.matches("nova", "Nova", roles: roles))
    #expect(AgentNames.matches("atlas", "atl", roles: roles))
    #expect(!AgentNames.matches("nova", "devops", roles: roles))
}

@Test func aNewReadingReplacesTheRolesAndTellsTheViewsThatReadThem() async {
    let book = AgentNames()
    book.read([("nova", "Customer Support")])
    #expect(book.label("nova") == "Customer Support")
    #expect("unknown-agent-x".agentLabel == "Unknown-Agent-X")
    let changed = Mutex(false)
    withObservationTracking { _ = book.label("nova") } onChange: { changed.withLock { $0 = true } }
    book.read([("nova", "Customer Support")])           // the same roles: nothing changes, nothing redraws
    #expect(!changed.withLock { $0 })
    book.read([("nova", nil)])                          // the role he removed is gone at once
    #expect(changed.withLock { $0 })
    #expect(book.label("nova") == "Nova")
    #expect(book.under("nova") == nil)
}
