import Foundation
import Testing
@testable import FleetCore

/// The agents' chats in the main sidebar, as a chat app lists its conversations. The owner, 24 October 2026: "should
/// be more like Grok (taller, with preview, and we could have some right click extras) KEEP STYLE".
struct ChatListTests {
    private func report(_ text: String, agent: String = "vps") throws -> ChatEntry {
        .report(try JSONDecoder().decode(ManagerReport.self, from: JSONSerialization.data(withJSONObject: [
            "id": 7, "agent": agent, "text": text, "about": "", "created": 10.0,
        ])))
    }

    private func message(_ text: String, files: [String] = [], hand: String? = nil) throws -> ChatEntry {
        let attachments = files.enumerated().map { index, name in
            ["id": index + 1, "name": name, "mime": "text/plain", "size": 3, "sha256": "", "created": 1.0] as [String: Any]
        }
        var fields: [String: Any] = ["request_id": "r", "recipient": "vps", "kind": "message", "text": text, "event_id": 1,
                                     "created": 9.0, "client": "test", "attachments": attachments]
        if let hand { fields["hand"] = hand; fields["runtime"] = hand == "tool" ? "claude-code" : NSNull() }
        return .message(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: fields)))
    }

    /// A task created at 1 that last moved at `moved`.
    private func task(owner: String = "vps", state: String = "working", title: String = "The shop page",
                      moved: Double = 50) throws -> FleetTask {
        let json = "{\"id\": 1, \"title\": \"\(title)\", \"details\": \"\", \"done_when\": \"\", \"needs\": \"\", "
            + "\"goal\": \"\", \"owner\": \"\(owner)\", \"requester\": \"manager\", \"state\": \"\(state)\", "
            + "\"created\": 1, \"last_activity\": \(moved), \"attempt\": 1, \"restarts\": 0, \"nudge_level\": 0, "
            + "\"stop_sent\": 0}"
        return try JSONDecoder().decode(FleetTask.self, from: Data(json.utf8))
    }

    @Test func pinnedAgentsComeFirstNewestPinOnTopThenTheHubsOrder() {
        let hub = ["manager", "vps", "worker4", "studio"]
        #expect(ChatList.order(hub, pinned: []) == hub)
        #expect(ChatList.order(hub, pinned: ["studio", "vps"]) == ["studio", "vps", "manager", "worker4"])
        // A pin of an agent this hub does not list is kept for later and takes no place now.
        #expect(ChatList.order(hub, pinned: ["gone", "worker4"]) == ["worker4", "manager", "vps", "studio"])
    }

    /// "You: " stands only before his own words (owner feature `message_hands`): the bugs are an AI session's, a
    /// connected app's or a later hand's words that read as his on the row, his own that lose it, a hub without the
    /// feature that changes the row, and a row's line that does not pass the hub's features on.
    @Test func theLineIsTheLastMessageAndHisOwnSaysSo() throws {
        #expect(ChatList.preview("vps", last: try report("The page is live."), tasks: []) == "The page is live.")
        #expect(ChatList.preview("vps", last: try message("Is it live?"), tasks: []) == "You: Is it live?")
        // A message of files alone is its files, as the chat shows it.
        #expect(ChatList.preview("vps", last: try message("", files: ["brief.pdf", "logo.png"]), tasks: [])
                == "You: brief.pdf, logo.png")
        // Before the first message there is no line, and the row shows the name alone.
        #expect(ChatList.preview("vps", last: nil, tasks: []) == nil)
        #expect(ChatList.preview("vps", last: try message(""), tasks: []) == nil)

        let hands = ["direct_chat", OwnerHand.feature]
        for hand in ["tool", "connected", "other", "job"] {
            #expect(ChatList.preview("vps", last: try message("Draft **it**", hand: hand), tasks: [], features: hands)
                    == "Draft it", "\(hand)")
        }
        #expect(ChatList.preview("vps", last: try message("Draft it", hand: "app"), tasks: [], features: hands) == "You: Draft it")
        #expect(ChatList.preview("vps", last: try message("Draft it", hand: "tool"), tasks: []) == "You: Draft it")
        #expect(ChatList.line("vps", entries: [try message("Draft it", hand: "tool")], whole: true, needs: [], tasks: [],
                              features: hands)?.words == "Draft it")
    }

    /// The line is the newest thing the agent did: a task that moved after its last message says what it is doing,
    /// as a chat app says "typing…"; a message after that — a question it asks while it works — is not hidden
    /// behind the task. A task that is over, or another agent's, leaves the last message there.
    @Test func theNewestOfItsLastMessageAndItsOpenTaskIsTheLine() throws {
        let last = try report("Done.")  // at 10
        #expect(ChatList.preview("vps", last: last, tasks: [try task(moved: 50)]) == "The shop page")
        #expect(ChatList.preview("vps", last: last, tasks: [try task(moved: 5)]) == "Done.")
        #expect(ChatList.preview("vps", last: nil, tasks: [try task(moved: 5)]) == "The shop page")
        #expect(ChatList.preview("vps", last: last, tasks: [try task(state: "completed")]) == "Done.")
        #expect(ChatList.preview("vps", last: last, tasks: [try task(owner: "worker4")]) == "Done.")
    }

    @Test func markdownIsReadAsTheWordsItShowsOnOneLine() throws {
        let text = """
        ## Two blockers

        - **AWS account** needs a `key`
        - [x] See [the console](https://example.com)
        > quoted

        | a | b |
        |---|---|
        """
        #expect(ChatList.preview("vps", last: try report(text), tasks: [])
                == "Two blockers AWS account needs a key See the console quoted a b")
        #expect(ChatList.preview("vps", last: try report("```\nswift build\n```"), tasks: []) == "swift build")
        #expect(ChatList.preview("vps", last: try report("  \n\n "), tasks: []) == nil)
    }

    /// A long reply is read only as far as one line can show it.
    @Test func aLongReplyIsNotReadToTheEnd() throws {
        let long = String(repeating: "word ", count: 4_000)
        let line = try #require(ChatList.preview("vps", last: try report(long), tasks: []))
        #expect(line.count < ChatList.reads)
        #expect(line.hasPrefix("word word"))
    }

    /// The owner, 13 November 2026, with a chat app's rows beside his sidebar: "maybe I would like this relative time
    /// label on the side menu too". The time of day today, "Yesterday", the weekday within the last week, the date.
    @Test func theRowsTimeIsTheDayOrTheTimeAsAChatAppWritesIt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_GB")
        func at(_ day: Int, _ hour: Int, _ minute: Int) throws -> Double {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)))
                .timeIntervalSince1970
        }
        let now = try at(13, 9, 30)        // a Friday
        func words(_ time: Double) -> String { ChatList.time(time, now: now, calendar: calendar, locale: locale) }
        #expect(words(try at(13, 9, 23)) == "9:23")
        #expect(words(try at(13, 0, 0)) == "0:00")
        // The hub's clock a few seconds ahead of this device's: today's time, never a day.
        #expect(words(now + 4) == "9:30")
        #expect(words(try at(12, 23, 59)) == "Yesterday")
        #expect(words(try at(12, 0, 1)) == "Yesterday")
        #expect(words(try at(11, 18, 0)) == "Wednesday")
        #expect(words(try at(7, 8, 0)) == "Saturday")
        // A week back and more: the date, so no weekday names two days.
        #expect(words(try at(6, 22, 0)) == "06/11/2026")
        #expect(words(try at(5, 9, 0)) == "05/11/2026")
    }

    /// The owner, 13 November 2026, to the picture of an action line in his sidebar: "Yes, build it". While an agent
    /// works, its row says what it does now, in the words that the hub sends with the task whose session works.
    @Test func anAgentsActionNowIsTheWordsOfItsTaskThatWorks() throws {
        func task(_ id: Int, moved: Double, _ more: String) throws -> FleetTask {
            try JSONDecoder().decode(FleetTask.self, from: Data("""
            {"id": \(id), "title": "The shop page", "details": "", "done_when": "", "needs": "", "goal": "",
             "owner": "vps", "requester": "manager", "state": "working", "created": 1, "last_activity": \(moved),
             "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0\(more)}
            """.utf8))
        }
        let runs = try task(1, moved: 50, #", "works": true, "doing": "Read live API health and public status""#)
        let newer = try task(2, moved: 60, #", "works": true, "doing": "Reading its messages""#)
        let waits = try task(3, moved: 70, #", "works": false, "doing": "Words that a turn's end left""#)
        let silent = try task(4, moved: 80, #", "works": true"#)
        #expect(AgentActivity.actionNow("vps", tasks: [runs]) == "Read live API health and public status")
        // Several tasks work: the one that moved last. A task that waits, and one that says nothing, give no words.
        #expect(AgentActivity.actionNow("vps", tasks: [runs, newer, waits, silent]) == "Reading its messages")
        #expect(AgentActivity.actionNow("vps", tasks: [waits, silent]) == nil)
        #expect(AgentActivity.actionNow("worker4", tasks: [runs]) == nil)
    }

    /// The owner, 14 November 2026, of a row that said this morning's minute over a chat whose last message was two
    /// days old: "last message is from Thursday but on the sidebar it says 8:09 today". Every session had started
    /// again that minute, which moved every open task.
    @Test func theRowsTimeIsTheTimeOfTheChatsLastMessage() throws {
        let last = try report("Done.")                  // created at 10
        #expect(ChatList.lastTime(last) == 10)
        #expect(ChatList.lastTime(try message("Is it live?")) == 9)
        // A task that moved after the message changes the line, and not the time.
        #expect(ChatList.preview("vps", last: last, tasks: [try task(moved: 50)]) == "The shop page")
        // No message, no time: also where the line names a task.
        #expect(ChatList.lastTime(nil) == nil)
        #expect(ChatList.lastTime(try message("")) == nil)
    }

    /// An entry of the manager's chat: his message (`asked`: its request id) or the agent's reply.
    private func entry(_ id: Int, at created: Double, his asked: String? = nil, replyingTo: String? = nil) throws -> ChatEntry {
        if let asked {
            return .message(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: [
                "request_id": asked, "recipient": "manager", "kind": "message", "text": "Synthetic", "event_id": id,
                "created": created, "client": "test", "attachments": [],
            ])))
        }
        return .report(try JSONDecoder().decode(ManagerReport.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "agent": "manager", "text": "Synthetic", "about": "", "created": created,
            "in_reply_to": replyingTo as Any? ?? NSNull(),
        ])))
    }

    private func need(_ id: Int, raised: Double, by agent: String = "manager", answered: Double? = nil) throws -> OwnerNeed {
        try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "by": agent, "title": "Request \(id)", "why": "", "todo": "", "raised": raised,
            "answer": answered == nil ? NSNull() : "Yes", "answered": answered as Any? ?? NSNull(),
        ]))
    }

    /// The owner, 14 November 2026: "why does the preview not show the card if the card is the latest element on the
    /// chat?", and his yes to its title in orange. Only a card that still waits for him and that is the newest thing in
    /// its chat, where the chat itself places it.
    @Test func aWaitingCardThatIsTheNewestThingInTheChatIsTheLine() throws {
        let chat = [try entry(1, at: 10), try entry(2, at: 20, his: "a"), try entry(3, at: 30)]
        // Raised after the last message: its card is the newest thing, and the row's time is the card's.
        let newest = try ChatList.waitingRequest("manager", entries: chat, whole: true, needs: [try need(7, raised: 40), try need(6, raised: 35)])
        #expect(newest?.id == 7)
        #expect(ChatList.requestTime(try need(7, raised: 40), last: chat.last) == 40)
        // A message after it: the message is the line.
        #expect(try ChatList.waitingRequest("manager", entries: chat, whole: true, needs: [try need(7, raised: 25)]) == nil)
        // Answered, or another agent's: no orange line.
        #expect(try ChatList.waitingRequest("manager", entries: chat, whole: true, needs: [try need(7, raised: 40, answered: 50)]) == nil)
        #expect(try ChatList.waitingRequest("manager", entries: chat, whole: true, needs: [try need(7, raised: 40, by: "vps")]) == nil)
        #expect(try ChatList.waitingRequest("manager", entries: chat, whole: true, needs: []) == nil)
        // With no message yet, a waiting card is the whole chat.
        #expect(try ChatList.waitingRequest("manager", entries: [], whole: true, needs: [try need(7, raised: 40)])?.id == 7)
    }

    /// The agent's reply of the turn in which it raised the request ("It is in Needs you.") came after the request, and
    /// the chat draws the card under it: the card is still the newest thing, at the reply's time.
    @Test func aCardUnderTheReplyOfItsTurnIsStillTheLine() throws {
        let chat = [try entry(1, at: 10), try entry(2, at: 20, his: "a"), try entry(3, at: 45, replyingTo: "a")]
        let request = try need(7, raised: 40)
        #expect(ChatList.waitingRequest("manager", entries: chat, whole: true, needs: [request])?.id == 7)
        #expect(ChatList.requestTime(request, last: chat.last) == 45)
        // A later message of the agent's that answers nothing of his comes after the card.
        let later = chat + [try entry(4, at: 90)]
        #expect(ChatList.waitingRequest("manager", entries: later, whole: true, needs: [request]) == nil)
    }
}
