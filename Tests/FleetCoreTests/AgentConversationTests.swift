import Foundation
import Testing
@testable import FleetCore

/// An agent's conversations with the other agents, one for each other agent, read out of its messages.
struct AgentConversationTests {
    private func message(_ id: Int, _ sender: String, _ recipient: String, at created: Double,
                         _ text: String = "words") -> AgentMessage {
        AgentMessage(id: id, sender: sender, recipient: recipient, text: text, created: created)
    }

    @Test func eachOtherAgentIsOneConversationTheNewestFirst() {
        let all = AgentConversation.of("leo", messages: [
            message(1, "leo", "ivy", at: 10),
            message(2, "ivy", "leo", at: 20, "a waited message"),
            message(15, "manager", "leo", at: 30),
            message(16, "leo", "manager", at: 40, "Noted,\nthanks."),
        ])
        #expect(all.map(\.other) == ["manager", "ivy"])
        // Whoever wrote it, one conversation holds both sides, oldest first.
        #expect(all[0].messages.map(\.id) == [15, 16])
        #expect(all[0].last == 40)
        // The row's one line is the newest message, on one line.
        #expect(all[0].line == "Noted, thanks.")
        #expect(all[1].line == "a waited message")
    }

    @Test func aMessageBetweenTwoOtherAgentsIsNotThisAgentsConversation() {
        let all = AgentConversation.of("leo", messages: [message(1, "manager", "ivy", at: 10),
                                                         message(2, "manager", "leo", at: 20)])
        #expect(all.map(\.other) == ["manager"])
        #expect(AgentConversation.of("leo", messages: []).isEmpty)
    }

    @Test func theOrderOfTheMessagesInIsNotTheOrderOut() {
        let all = AgentConversation.of("manager", messages: [message(9, "manager", "theo", at: 90),
                                                             message(3, "theo", "manager", at: 30)])
        #expect(all.first?.messages.map(\.id) == [3, 9])
        // A message without words gives the row no line.
        #expect(AgentConversation(other: "theo", messages: [message(1, "theo", "manager", at: 1, " \n ")]).line == nil)
    }
}
