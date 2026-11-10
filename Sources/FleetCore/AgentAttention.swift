import Foundation

/// The machine problems of one agent that need the owner, most important first. They count only for an online agent
/// in a fresh hub state; the agent's status shows the rest (unknown, in setup, offline, limited). Each one is resolved
/// in Technical details (Check machine, Update Fleet, Terminal). A vault token that is not isolated is not one: the
/// owner can keep administrator access on purpose.
public enum AgentAttention: Hashable, Sendable {
    case staleReading
    case signIn
    case updateFailed
    case checkFailed
    case restart

    public static func items(for agent: FleetAgent, serverTime: Double, isFresh: Bool, machine: MachineStatus?) -> [AgentAttention] {
        guard isFresh, agent.helperIsRecent(serverTime: serverTime), let machine else { return [] }
        guard machine.isCurrent(at: serverTime) else { return [.staleReading] }
        var items: [AgentAttention] = []
        if machine.runtime.signed_in == false { items.append(.signIn) }
        if machine.update.state == "failed" { items.append(.updateFailed) }
        if let check = machine.check, ["failed", "offline"].contains(check.state) { items.append(.checkFailed) }
        if machine.security.reboot_required == true { items.append(.restart) }
        return items
    }
}
