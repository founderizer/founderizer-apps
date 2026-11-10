import Foundation

/// **One agent's conversation with another agent**: the messages that it sent to that agent or got from it, read out
/// of `GET /ui/agent-messages` (the owner, 6 November 2026: "conversations between the agent and other agents should
/// appear under Conversations section (inside people) not with these tasks", and his yes to the mockup the same day).
///
/// The hub keeps no conversation of its own for two agents, only their messages: a conversation here is every message
/// between the same two agents, whichever of them wrote first.
public struct AgentConversation: Equatable, Sendable, Identifiable {
    /// The other agent.
    public let other: String
    /// Their messages, oldest first.
    public let messages: [AgentMessage]

    public var id: String { other }
    /// When the newest message came.
    public var last: Double { messages.last?.created ?? 0 }
    /// The newest message's words on one line, for the row of the conversation; nil for a message without words.
    public var line: String? {
        guard let text = messages.last.map({ People.oneLine($0.text) }), !text.isEmpty else { return nil }
        return text
    }

    public init(other: String, messages: [AgentMessage]) {
        self.other = other; self.messages = messages
    }

    /// One conversation for each agent that `agent` wrote to or heard from, the newest first. The route answers for one
    /// agent, but this does not take that on trust: a message between two other agents is left out.
    public static func of(_ agent: String, messages: [AgentMessage]) -> [AgentConversation] {
        var byOther: [String: [AgentMessage]] = [:]
        for message in messages where message.sender == agent || message.recipient == agent {
            byOther[message.sender == agent ? message.recipient : message.sender, default: []].append(message)
        }
        return byOther.map { AgentConversation(other: $0.key, messages: $0.value.sorted { $0.id < $1.id }) }
            .sorted { ($0.last, $0.other) > ($1.last, $1.other) }
    }
}

extension ChatAppsClient {
    /// Every message of one agent after the message `after`, one page after the other, in one reading of at most
    /// `pages` pages: oldest first, as each page is.
    public func agentMessages(hub: URL, database: String, agent: String, after: Int, pages: Int) async throws -> [AgentMessage] {
        var all: [AgentMessage] = [], last = after
        for _ in 0..<max(1, pages) {
            let page = try await agentMessages(hub: hub, database: database, agent: agent, after: last).messages
            all += page
            guard page.count == AgentMessages.pageSize, let newest = page.last?.id else { break }
            last = newest
        }
        return all
    }
}
