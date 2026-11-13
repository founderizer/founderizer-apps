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

    private func message(_ text: String, files: [String] = []) throws -> ChatEntry {
        let attachments = files.enumerated().map { index, name in
            ["id": index + 1, "name": name, "mime": "text/plain", "size": 3, "sha256": "", "created": 1.0] as [String: Any]
        }
        return .message(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: [
            "request_id": "r", "recipient": "vps", "kind": "message", "text": text, "event_id": 1,
            "created": 9.0, "client": "test", "attachments": attachments,
        ])))
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

    @Test func theLineIsTheLastMessageAndHisOwnSaysSo() throws {
        #expect(ChatList.preview("vps", last: try report("The page is live."), tasks: []) == "The page is live.")
        #expect(ChatList.preview("vps", last: try message("Is it live?"), tasks: []) == "You: Is it live?")
        // A message of files alone is its files, as the chat shows it.
        #expect(ChatList.preview("vps", last: try message("", files: ["brief.pdf", "logo.png"]), tasks: [])
                == "You: brief.pdf, logo.png")
        // Before the first message there is no line, and the row shows the name alone.
        #expect(ChatList.preview("vps", last: nil, tasks: []) == nil)
        #expect(ChatList.preview("vps", last: try message(""), tasks: []) == nil)
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

    @Test func theRowsTimeIsTheTimeOfWhatItsLineShows() throws {
        let last = try report("Done.")                  // created at 10
        // The line is what the agent is doing: the task's last move.
        #expect(ChatList.previewTime("vps", last: last, tasks: [try task(moved: 50)]) == 50)
        #expect(ChatList.previewTime("vps", last: nil, tasks: [try task(moved: 5)]) == 5)
        // The line is its last message: that message's time, also beside an older or another agent's task.
        #expect(ChatList.previewTime("vps", last: last, tasks: [try task(moved: 5)]) == 10)
        #expect(ChatList.previewTime("vps", last: last, tasks: [try task(owner: "worker4")]) == 10)
        #expect(ChatList.previewTime("vps", last: try message("Is it live?"), tasks: []) == 9)
        // No line, no time.
        #expect(ChatList.previewTime("vps", last: nil, tasks: []) == nil)
        #expect(ChatList.previewTime("vps", last: try message(""), tasks: []) == nil)
    }
}
