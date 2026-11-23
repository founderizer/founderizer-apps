import Foundation
import Observation
import Synchronization
import Testing
@testable import FleetCore

// An agent by its name (the owner, 22 November 2026): both apps name an agent by its name with capitals, its team.json
// `title` beside it where a place shows the agent as an entry of its own, and a role that holds the name is the label
// alone. These tests read the book of their own; `AgentNames.shared` belongs to the app that runs, and other tests read
// it in parallel.

private let roles = AgentNames.roles([("nova", "  Customer   Support "), ("manager", "Fleet Manager"), ("atlas", nil),
                                      ("kai", ""), ("web-dev", "Web Developer")])

@Test func aRoleIsOneLineAndAnEmptyTitleIsNoRole() {
    #expect(roles == ["nova": "Customer Support", "manager": "Fleet Manager", "web-dev": "Web Developer"])
}

/// The bug: a later change puts the role back as the label, or drops the exception, and "Manager" stands where "Fleet
/// Manager" stood.
@Test func theLabelIsTheNameWithCapitalsUnlessTheRoleHoldsTheName() {
    #expect(AgentNames.label("nova", roles: roles) == "Nova")
    #expect(AgentNames.label("web-dev", roles: roles) == "Web-Dev")
    #expect(AgentNames.label("manager", roles: roles) == "Fleet Manager")    // one word of the role is the name
    #expect(AgentNames.label("atlas", roles: roles) == "Atlas")
    #expect(AgentNames.label("mini-2b", roles: roles) == "Mini-2B")
    #expect(AgentNames.label("owner", roles: roles) == "Owner")
}

@Test func theRoleStandsBesideTheNameUnlessItIsTheLabel() {
    #expect(AgentNames.role("nova", roles: roles) == "Customer Support")
    #expect(AgentNames.role("web-dev", roles: roles) == "Web Developer")
    #expect(AgentNames.role("manager", roles: roles) == nil)       // "Fleet Manager · Fleet Manager" says it twice
    #expect(AgentNames.role("atlas", roles: roles) == nil)           // no role
}

/// The line under a name in Settings › Reporting lines, in its four cases. The bug: a lead loses "Lead", or an agent
/// with no role beside its name gets an empty second line.
@Test func reportingLinesPutTheRoleAndALeadsPositionUnderTheName() {
    let worker = AgentNames.graphLine("nova", lead: false, roles: roles)
    #expect(worker == AgentNames.GraphLine(role: "Customer Support", position: nil))
    #expect(worker?.words == "Customer Support")
    let lead = AgentNames.graphLine("nova", lead: true, roles: roles)
    #expect(lead == AgentNames.GraphLine(role: "Customer Support", position: "Lead"))
    #expect(lead?.end == " · Lead")
    #expect(lead?.words == "Customer Support · Lead")
    #expect(AgentNames.graphLine("atlas", lead: true, roles: roles)?.words == "Lead")             // a lead with no role
    #expect(AgentNames.graphLine("atlas", lead: true, roles: roles)?.role == nil)
    #expect(AgentNames.graphLine("atlas", lead: false, roles: roles) == nil)                      // no role: one line
    #expect(AgentNames.graphLine("manager", lead: false, roles: roles) == nil)                    // its role is its label
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
    #expect(book.role("nova") == "Customer Support")
    #expect("unknown-agent-x".agentLabel == "Unknown-Agent-X")
    let changed = Mutex(false)
    withObservationTracking { _ = book.role("nova") } onChange: { changed.withLock { $0 = true } }
    book.read([("nova", "Customer Support")])           // the same roles: nothing changes, nothing redraws
    #expect(!changed.withLock { $0 })
    book.read([("nova", nil)])                          // the role he removed is gone at once
    #expect(changed.withLock { $0 })
    #expect(book.label("nova") == "Nova")
    #expect(book.role("nova") == nil)
}
