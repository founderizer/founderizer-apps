import Foundation
import Testing
@testable import FleetCore

/// **A message that an AI session sent for him does not look like his own** (owner feature `message_hands`; the
/// owner's "B, go ahead" of 24 November 2026, after "why does it look like I sent that message? I didn't"). One rule
/// draws every bubble of his on the Mac and the iPhone (`OwnerHand.look`), from the hand that the hub gives each
/// message, each older row and each of his lines of a card's talk. Example names only.
struct OwnerHandTests {
    private typealias Look = OwnerHand.Look
    private static let on = ["need_clarify", OwnerHand.feature]

    /// The bugs that this catches: an AI session's message in his filled bubble (the fault that he saw); his own words
    /// from this Mac, his phone or a chat app, or a row from before the hand, in the outline; a mark on a connected
    /// app's or another hand's words, or on an AI session whose program has no mark here (a wrong logo); and an outline
    /// or a mark on a hub that does not give the hand; and VoiceOver that reads "You: " before words that he did not
    /// write.
    @Test func eachHandHasItsLookAndOnlyAnAISessionOfAKnownProgramHasAMark() {
        func look(_ hand: String?, _ runtime: String?, features: [String]? = Self.on) -> Look {
            OwnerHand.look(features: features, hand: hand, runtime: runtime)
        }
        // his own hands, and a row from before owner API 1.289: the filled bubble, whatever runtime stands beside
        for hand in ["app", "device", "chat", nil] as [String?] {
            #expect(look(hand, nil) == .his, "\(hand ?? "nil")")
            #expect(look(hand, "claude-code") == .his, "\(hand ?? "nil")")
        }
        // an AI session through the owner tools: the outline, with its mark when its program has one
        #expect(look("tool", "claude-code") == Look(outlined: true, mark: .claude))
        #expect(look("tool", "codex") == Look(outlined: true, mark: .codex))
        #expect(look("tool", "grok") == Look(outlined: true, mark: .grok))
        #expect(look("tool", "opencode") == Look(outlined: true, mark: .opencode))
        #expect(look("tool", nil) == Look(outlined: true, mark: nil))
        #expect(look("tool", "another-program") == Look(outlined: true, mark: nil))
        // a connected app, another hand, and a hand that this app does not know: the outline, never a mark
        for hand in ["connected", "other", "a-new-hand"] {
            for runtime in ["claude-code", "codex", "grok", "opencode"] {
                #expect(look(hand, runtime) == Look(outlined: true, mark: nil), "\(hand) \(runtime)")
            }
        }
        // what VoiceOver reads: "You: " only before his own words, the mark's words before an AI session's
        #expect(look("app", nil).spoken("Pin it.") == "You: Pin it.")
        #expect(look("tool", "codex").spoken("Pin it.") == "Sent by your AI session: Pin it.")
        #expect(look("tool", nil).spoken("Pin it.") == "Pin it.")
        #expect(look("connected", nil).spoken("Pin it.") == "Pin it.")
        // a hub without the feature, or with no list of features: every bubble as before
        for hand in ["app", "device", "chat", "connected", "tool", "other", nil] as [String?] {
            #expect(look(hand, "claude-code", features: ["need_clarify"]) == .his, "\(hand ?? "nil")")
            #expect(look(hand, "claude-code", features: nil) == .his, "\(hand ?? "nil")")
        }
    }

    /// The bugs that this catches: the fields are not read where the hub gives them (`messages[]` of the state, the
    /// message rows of an older block, his guidance of a task, his lines of a card's talk in the state, in an older
    /// block of items and in the answer of his message under a card), so an AI session's words look like his there; a message or a talk line
    /// without the keys, or with null, stops the reading; and an agent's reply in a talk is drawn by a hand. The phone's
    /// items of `GET /ui/mobile` (`needs`, `answered_needs`) are these items too.
    @Test func theHandIsReadOnMessagesOlderRowsAndTalkAndIsNilWhenMissingOrNull() throws {
        func message(_ id: String, _ fields: [String: Any]) -> [String: Any] {
            ["request_id": id, "kind": "message", "text": "Words \(id)", "event_id": 1, "created": 400.0,
             "client": "client-\(id)", "recipient": "manager"].merging(fields) { $1 }
        }
        let rows = [message("a", ["hand": "tool", "runtime": "claude-code"]),
                    message("b", ["hand": NSNull(), "runtime": NSNull()]),
                    message("c", [:]),
                    message("d", ["hand": "chat", "runtime": NSNull()])]
        let talk: [[String: Any]] = [
            ["who": "owner", "text": "Which account?", "ts": 10.0, "hand": "tool", "runtime": "codex"],
            ["who": "manager", "text": "The shared one.", "ts": 11.0, "hand": NSNull(), "runtime": NSNull()],
            ["who": "owner", "text": "Thanks", "ts": 12.0],
            ["who": "manager", "text": "Done.", "ts": 13.0, "hand": "tool", "runtime": "claude-code"]]
        let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "db", "time": 1000.0, "tasks": [], "notes": [], "permissions": [], "reports": [],
            "agents": [["name": "manager", "role": "manager", "runtime": "codex", "can": []]],
            "messages": rows,
            "steers": [["id": 1, "task": 3, "attempt": 1, "text": "Look at the logs first.", "created": 5.0,
                        "read_at": NSNull(), "request_id": "r-9", "client": "example-tool", "hand": "tool",
                        "runtime": "codex"],
                       ["id": 2, "task": 3, "attempt": 1, "text": "Then the config.", "created": 6.0,
                        "request_id": "r-10", "client": "example-app"]],
            "needs": [["id": 5, "title": "Pick an account", "why": "", "todo": "", "raised": 9.0, "by": "manager",
                       "talk": talk]],
            "ui_features": Self.on] as [String: Any]))
        let looks = state.messages.map { $0.look(features: state.ui_features) }
        #expect(state.messages.map(\.hand) == ["tool", nil, nil, "chat"])
        #expect(state.messages.map(\.runtime) == ["claude-code", nil, nil, nil])
        #expect(looks == [Look(outlined: true, mark: .claude), .his, .his, .his])

        // his guidance of a task: an AI session steers through the owner tools too
        #expect(state.steers?.map { $0.look(features: state.ui_features) } == [Look(outlined: true, mark: .codex), .his])

        let lines = try #require(state.needs.first?.talk)
        #expect(lines.map(\.hand) == ["tool", nil, nil, "tool"])
        #expect(lines.map { $0.look(features: state.ui_features) } == [Look(outlined: true, mark: .codex), .his, .his, .his])

        let block = try OlderRowsBlock.decode(JSONSerialization.data(withJSONObject: [
            "db": "db", "list": "messages", "from": 0, "mark": "1.0", "messages": rows] as [String: Any]))
        #expect(block.messages?.map(\.hand) == ["tool", nil, nil, "chat"])
        #expect(block.messages?.first?.look(features: Self.on) == Look(outlined: true, mark: .claude))

        let needs = try OlderRowsBlock.decode(JSONSerialization.data(withJSONObject: [
            "db": "db", "list": "needs", "from": 0, "mark": "1.0",
            "needs": [["id": 2, "title": "Pick an account", "why": "", "todo": "", "raised": 9.0, "by": "manager",
                       "answer": "Shared", "answered": 20.0, "talk": talk]]] as [String: Any]))
        #expect(needs.needs?.first?.talk?.map { $0.look(features: Self.on) }
                == [Look(outlined: true, mark: .codex), .his, .his, .his])
        let receipt = try JSONDecoder().decode(ControlReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "ok": true, "request_id": "r-1", "client": "example-tool", "replayed": false, "need": 5, "talk": talk]))
        #expect(receipt.talk?.first?.look(features: Self.on) == Look(outlined: true, mark: .codex))
    }
}
