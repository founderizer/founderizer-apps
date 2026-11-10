import Foundation

/// **What one agent is doing now**, read out of what the app already holds: the line under its name in the main
/// sidebar (`ChatList.preview`).
///
/// The panel beside the chat listed its open tasks, its steps, its results and its messages with other agents too,
/// until the owner took that card away (6 November 2026: "i want to remove this panel, and keep tasks internal or maybe
/// in a new section called Tasks"). The tasks are the agent's Tasks part now, and its messages with other agents are
/// chats under its People › Conversations (`AgentConversations`).
public enum AgentActivity {
    /// **The one line under an agent's name in the fleet list**: what it is doing now, and nothing when it is
    /// doing nothing. An agent with no open task gets no line rather than a word that says "idle" in a place he
    /// reads at a glance — the status dot beside its name already says that much. With several open tasks it names
    /// the one that moved last and counts the rest, as the Dashboard does ("Check the price page · +2"), and not
    /// "3 tasks", which names none of them.
    public static func doingNow(_ agent: String, tasks: [FleetTask]) -> String? {
        let open = tasks.filter { $0.owner == agent && !$0.isTerminal }
        guard let last = open.max(by: { moved($0) < moved($1) }) else { return nil }
        return open.count == 1 ? last.title : "\(last.title) · +\(open.count - 1)"
    }

    /// When a task last moved: its last activity, else its start, else its creation.
    private static func moved(_ task: FleetTask) -> Double { task.last_activity ?? task.started ?? task.created }
}
