import FleetCore
import Testing
@testable import Founderizer

/// **A menu's filter finds an agent's row by its role** (the readers of F16's piece 4, 22 November 2026): an agent's row
/// shows its name since the owner's answers of that day, and a list of more than eight rows has "Type to filter". The
/// bug that this catches: typing a role ("support") gives "No matches", because the role is no word of the row, where
/// Search finds the same agent by it. The test reads a book of its own, not `AgentNames.shared`, which other tests read.
@MainActor @Test func aMenuFilterFindsAnAgentsRowByItsRole() {
    let names = AgentNames()
    names.read([("nova", "Customer Support"), ("atlas", "Marketing")])
    let items = ["nova", "atlas"].map { FleetMenuItem(title: names.label($0), mark: .agent($0, nil)) }
        + [FleetMenuItem(title: "Support tickets", mark: .symbol("doc"))]
    let menu = FleetMenuModel(items: items, filters: true, highlighted: nil, maxHeight: 300, names: names)
    menu.query = "support"
    #expect(menu.shown == [0, 2])
    menu.query = "Atlas"
    #expect(menu.shown == [1])
    menu.query = "devops"
    #expect(menu.shown.isEmpty)
}
