import Foundation
import Testing
@testable import FleetCore

// Example names only (design 0): nova (Customer Support), atlas (Marketing), iris (DevOps), juno (no role), manager
// (Fleet Manager).

/// **@ tags in the chat's box** (the owner, 20 November 2026: "@<agent-name> or @<agent-role> allows tagging an agent",
/// "Name a helper", and "Yes, as drawn" to the list; `AgentTags`). Carets, starts and lengths are Unicode scalars, as the
/// hub counts them.
struct AgentTagsTests {
    private typealias Mention = AgentTags.Mention
    private static let team: [(name: String, role: String?)] = [
        ("manager", "Fleet Manager"), ("nova", "Customer Support"), ("atlas", "Marketing"), ("iris", "DevOps"),
        ("juno", nil)]
    /// The manager's chat: every other agent is a row.
    private let tags = AgentTags(agents: Self.team, except: "manager")

    // MARK: the label and the rows

    /// **Each label names one agent, as the hub's `tag_label` does, and a pick reads back as the agent he picked.** The
    /// bug that this catches: two rows that read the same, or "@Atlas" written for atlas and sent for the agent whose
    /// role is "Atlas", so the bubble and the hub's line name an agent that he did not pick.
    @Test func eachLabelNamesOneAgentAsTheHubsAndAPickReadsBackAsItsAgent() {
        #expect(tags.rows.map(\.label) == ["Customer Support", "Marketing", "DevOps", "Juno"])
        #expect(tags.rows.map(\.agent) == ["nova", "atlas", "iris", "juno"])
        #expect(tags.label(of: "manager") == "Fleet Manager")
        // the hub's own labels of test_direct_chat's tag team: "Marketing (other)", "Manager (manager)", ...
        let hub = AgentTags(agents: [("manager", nil), ("worker", nil), ("other", "Marketing"), ("desk", "DevOps"),
                                     ("boss", "Design Lead"), ("crew", "Designer"), ("fresh", "Research")], except: "worker")
        #expect(hub.rows.map(\.label) == ["Manager", "Marketing", "DevOps", "Design Lead", "Designer", "Research"])
        // a role that two agents hold, in any case and with any spaces, names neither: their names
        let shared = AgentTags(agents: [("nova", "Customer  Support"), ("kai", "customer support"), ("atlas", "Marketing")],
                               except: "atlas")
        #expect(shared.rows.map(\.label) == ["Nova", "Kai"])
        // a role that is another agent's name: the names
        let named = AgentTags(agents: [("nova", "Atlas"), ("atlas", nil), ("iris", "DevOps")], except: "iris")
        #expect(named.rows.map(\.label) == ["Nova", "Atlas"])
        // the chat's own agent still counts: in nova's chat, juno shares nova's role
        let own = AgentTags(agents: [("nova", "Support"), ("juno", "Support")], except: "nova")
        #expect(own.rows.map(\.label) == ["Juno"])
        // a name as the apps show it, which is the hub's shown_name
        #expect(AgentTags(agents: [("web-dev", nil), ("mini-2b", nil)], except: "").rows.map(\.label) == ["Web-Dev", "Mini-2B"])
        for book in [tags, hub, shared, named, own] {
            for row in book.rows {
                let edit = book.pick(row, in: "@", at: 0, caret: 1)
                #expect(book.mentions(in: edit.text) ==
                        [Mention(agent: row.agent, start: 0, length: row.label.unicodeScalars.count + 1)], "\(row)")
            }
        }
    }

    /// **The rows for his letters: a word start of the role, or the name's start, in the team's order** (design 4.3).
    /// The bug that this catches: letters inside a word find a row ("ops" in "DevOps"), the case or an accent hides one,
    /// the best match jumps first while he types, or the chat's own agent is a row.
    @Test func theRowsAreTheOtherAgentsByAWordStartOfTheRoleOrTheNameInTheTeamsOrder() {
        func labels(_ letters: String, in book: AgentTags = tags) -> [String] { book.rows(for: letters).map(\.label) }
        #expect(labels("") == ["Customer Support", "Marketing", "DevOps", "Juno"])
        #expect(labels("su") == ["Customer Support"])
        #expect(labels("customer su") == ["Customer Support"])
        #expect(labels("CUS") == ["Customer Support"])
        #expect(labels("dev") == ["DevOps"])
        #expect(labels("ops").isEmpty)
        #expect(labels("ju") == ["Juno"])
        #expect(labels("at") == ["Marketing"], "atlas, by its name")
        #expect(labels("fl").isEmpty, "the manager's own chat has no row for it")
        #expect(labels("x").isEmpty)
        let more = AgentTags(agents: [("leo", "Diseño Web"), ("iris", "SEO & AI Search"), ("bo", "Sales")], except: "")
        #expect(labels("diseno", in: more) == ["Diseño Web"] && labels("DISEÑ", in: more) == ["Diseño Web"])
        #expect(labels("ai s", in: more) == ["SEO & AI Search"])
        #expect(labels("s", in: more) == ["SEO & AI Search", "Sales"], "the team's order")
        #expect(labels("sa", in: more) == ["Sales"])
        // letters that are a row's whole label light that row, any case and spaces; else the first row
        let lead = AgentTags(agents: [("kai", "Customer Support Lead"), ("nova", "Customer Support"), ("juno", nil)],
                             except: "")
        #expect(lead.start(for: "customer SUPPORT", in: lead.rows(for: "customer SUPPORT")) == 1)
        #expect(lead.start(for: "customer  support", in: lead.rows) == 1)
        #expect(lead.start(for: "Customer Sup", in: lead.rows(for: "Customer Sup")) == 0)
        #expect(lead.start(for: "juno", in: lead.rows(for: "juno")) == 0 && lead.start(for: "", in: lead.rows) == 0)
    }

    // MARK: the box

    /// **The list opens at an "@" at the start of the words or after whitespace, on the caret's line** (design 4.3).
    /// The bug that this catches: an email or a handle opens it, or it stays open on the next line.
    @Test func theListOpensAtAnAtAfterWhitespaceOnTheCaretsLine() {
        func query(_ text: String, _ caret: Int? = nil) -> String? {
            tags.query(in: text, caret: caret ?? text.unicodeScalars.count).map { "\($0.at) \($0.letters)" }
        }
        #expect(query("@") == "0 ")
        #expect(query("Ask @cus") == "4 cus")
        #expect(query("Ask @customer su") == "4 customer su")
        #expect(query("Ask @mark", 6) == "4 m")
        #expect(query("Done.\n@ma") == "6 ma")
        #expect(query("👩‍💻 @ma") == "4 ma", "the emoji is three scalars")
        #expect(query("pat@mark") == nil)
        #expect(query("(@mark") == nil)
        #expect(query("@mark\nnext") == nil)
        #expect(query("@" + String(repeating: "a", count: 40)) == "0 " + String(repeating: "a", count: 40))
        #expect(query("@" + String(repeating: "a", count: 41)) == nil)
        #expect(query("") == nil && query("@", 0) == nil)
    }

    /// **A pick writes "@<label> " and the caret stands after the space** (his "a pick writes "@<role> ""). The bug that
    /// this catches: the caret before the space, two spaces before the words after it, or the words after it lost.
    @Test func aPickWritesTheLabelAndASpaceAndKeepsTheWordsAfterIt() {
        let atlas = tags.rows[1], juno = tags.rows[3]
        #expect(tags.pick(atlas, in: "Ask @ma", at: 4, caret: 7) == AgentTags.Edit(text: "Ask @Marketing ", caret: 15))
        #expect(tags.pick(atlas, in: "Ask @ma about it", at: 4, caret: 7)
                == AgentTags.Edit(text: "Ask @Marketing about it", caret: 15))
        #expect(tags.pick(juno, in: "@\nnext", at: 0, caret: 1) == AgentTags.Edit(text: "@Juno \nnext", caret: 6))
        #expect(tags.pick(atlas, in: "👩‍💻 @", at: 4, caret: 5) == AgentTags.Edit(text: "👩‍💻 @Marketing ", caret: 15))
    }

    /// **One Backspace at a tag's last character, or at the one space after it, takes the whole tag** (his "one
    /// Backspace removes it"). The bug that this catches: a Backspace anywhere near an "@" eats words, or a cut of two
    /// characters, a delete inside the tag or a key typed takes the tag.
    @Test func oneBackspaceAtATagsEndTakesTheWholeTagAndNoOtherEditDoes() {
        func after(_ old: String, _ new: String) -> AgentTags.Edit? { tags.afterDelete(old: old, new: new) }
        #expect(after("@Marketing", "@Marketin") == AgentTags.Edit(text: "", caret: 0))
        #expect(after("Hi @Marketing ", "Hi @Marketing") == AgentTags.Edit(text: "Hi ", caret: 3))
        #expect(after("Hi @Marketing now", "Hi @Marketin now") == AgentTags.Edit(text: "Hi now", caret: 3))
        #expect(after("Ask @Customer Support today", "Ask @Customer Suppor today") == AgentTags.Edit(text: "Ask today", caret: 4))
        #expect(after("👩‍💻 @Marketing ", "👩‍💻 @Marketing") == AgentTags.Edit(text: "👩‍💻 ", caret: 4))
        // two spaces after a tag: the caret says which one went; with no caret that fits, the first difference
        #expect(tags.afterDelete(old: "Hi @Marketing  x", new: "Hi @Marketing x", caret: 13)
                == AgentTags.Edit(text: "Hi  x", caret: 3))
        #expect(tags.afterDelete(old: "Hi @Marketing  x", new: "Hi @Marketing x", caret: 14) == nil)
        #expect(tags.afterDelete(old: "Hi @Marketing  x", new: "Hi @Marketing x", caret: 2) == nil)
        #expect(tags.afterDelete(old: "Hi @Marketing ", new: "Hi @Marketing", caret: 99) == AgentTags.Edit(text: "Hi ", caret: 3))
        for (old, new) in [("Hi @Marketing now", "Hi @Marketing no"), ("Hi @Marketing", "H @Marketing"),
                           ("@Marketing", "@Maketing"), ("Hi @Marketing  x", "Hi @Marketing x"),
                           ("Hi @Marketing", "Hi @Marketi"), ("Hi @Marketing", "Hi "), ("Hi @Marketing", "Hi @Marketing!"),
                           ("@Marketin", "@Marketi"), ("pat@Marketing", "pat@Marketin")] {
            #expect(after(old, new) == nil, "\(old) -> \(new)")
        }
    }

    // MARK: the tags of the words that he sends

    /// **The tags are in Unicode scalars, whole labels, outside code, at a tag start and before a tag end.** The bug that
    /// this catches: UTF-16 units or characters put the hub's range on other words after an emoji or an accent; an
    /// email, an address, code or an edited tag ("@Marketin") is taken for a tag.
    @Test func theTagsOfTheWordsAreWholeLabelsInUnicodeScalars() {
        // the technologist is 3 scalars, 5 UTF-16 units and 1 character
        #expect(tags.mentions(in: "👩‍💻 ask @Marketing") == [Mention(agent: "atlas", start: 8, length: 10)])
        // a decomposed é is 2 scalars and 1 character
        #expect(tags.mentions(in: "Cafe\u{301} @DevOps, then @Juno.")
                == [Mention(agent: "iris", start: 6, length: 7), Mention(agent: "juno", start: 20, length: 5)])
        #expect(tags.mentions(in: "@marketing and @JUNO") == [Mention(agent: "atlas", start: 0, length: 10),
                                                              Mention(agent: "juno", start: 15, length: 5)])
        #expect(tags.mentions(in: "Ask @Customer Support Lead") == [Mention(agent: "nova", start: 4, length: 17)])
        // a role that two agents hold names neither; their names do
        let shared = AgentTags(agents: [("nova", "Customer Support"), ("kai", "customer support"), ("atlas", nil)],
                               except: "atlas")
        #expect(shared.mentions(in: "@Customer Support, @Kai").map(\.agent) == ["kai"])
        for text in ["pat@Marketing.example", "see @Marketing.example", "https://example.com/@Marketing",
                     "run `@Marketing` now", "```\n@Marketing\n```\nok", "@Marketin please", "@Marketings",
                     "@Fleet Manager", "@manager", "@DevOps-team"] {
            #expect(tags.mentions(in: text).isEmpty, "\(text)")
        }
    }

    /// **The same table as the hub's reading of a chat app's words, for rules 1 and 2** (`test_chat_apps.ChatApps.
    /// test_the_hub_finds_the_tags_in_a_chat_app_message`; kept equal by hand, and that test names this one). The app
    /// reads rules 1 and 2 only, so the hub's one-word rule 3 ("@marketing" for "Growth Marketing Lead") is no tag here.
    /// A role that is another agent's name ("Grok") is that agent's name, and a role that the chat's own agent shares
    /// ("Studio Ops") names nobody, on both sides. The bug that this catches: the app and the hub read one text two
    /// ways, and a chat app's tag shows another agent's badge in the Mac's bubble.
    @Test func theTagsAreTheHubsRulesOneAndTwo() {
        let book = AgentTags(agents: [("manager", nil), ("studio", "Studio Ops"), ("vps", "VPS"), ("grok", nil),
                                      ("nova", "Customer Support"), ("kai", "Customer Support Lead"),
                                      ("atlas", "Growth Marketing Lead"), ("juno", "Grok"), ("mia", "Studio Ops")],
                             except: "studio")
        let table: [(String, [(String, Int, Int)])] = [
            ("@Customer Support, look at it", [("nova", 0, 17)]),
            ("Ask @Customer Support Lead?", [("kai", 4, 22)]),
            ("@Growth  Marketing\tLead now", [("atlas", 0, 23)]),
            ("@VPS and @vps", [("vps", 0, 4), ("vps", 9, 4)]),
            ("(@grok) then @marketing.", [("grok", 1, 5)]),         // the hub's rule 3 adds ("atlas", 13, 10)
            ("pat@marketing.example", []), ("https://example.com/@marketing", []),
            ("see @marketing.example", []), ("run `@marketing` now", []),
            ("```\n@marketing\n```\nok", []), ("@studio, you", []), ("@nobody here", []),
            ("@Grok, then", [("grok", 0, 5)]), ("@Studio Ops now", []), ("@support, then", [])]
        for (text, expected) in table {
            #expect(book.mentions(in: text) == expected.map { Mention(agent: $0.0, start: $0.1, length: $0.2) }, "\(text)")
        }
    }

    /// **A tag never stops his message**: at most the hub's 10 tags, and none longer than its 80 scalars. The bug that
    /// this catches: a wrong shape, which the hub refuses with 400, and his message shows "Not sent".
    @Test func theTagsKeepToTheHubsLimits() {
        let long = String(repeating: "Very ", count: 16) + "Long Role"
        let book = AgentTags(agents: [("nova", long), ("atlas", "Marketing")], except: "")
        #expect(book.rows.map(\.label) == [long, "Marketing"])
        #expect(book.mentions(in: "@\(long) and @Marketing") == [Mention(agent: "atlas", start: 95, length: 10)])
        let many = Array(repeating: "@Marketing", count: 12).joined(separator: " ")
        #expect(book.mentions(in: many).count == 10)
    }

    // MARK: the request and the reading

    /// **A message carries its tags, an answer never; an older saved request has none.** The bug that this catches: an
    /// answer to a Needs-you item with `mentions` (400), an empty list dropped (the hub then reads the words itself), a
    /// `pending.json` of a version before the tags that no longer decodes, so sending is blocked.
    @Test func aMessageCarriesItsTagsAndAnOlderSavedRequestHasNone() throws {
        let hub = try #require(URL(string: "http://127.0.0.1:9"))
        let tag = Mention(agent: "atlas", start: 4, length: 10)
        let message = PendingRequest(hub: hub, database: "db", client: "test", recipient: "nova", mentions: [tag],
                                     text: "Ask @Marketing")
        func body(_ request: PendingRequest) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: request.body()) as? [String: Any])
        }
        #expect(try body(message)["mentions"] as? [[String: AnyHashable]] == [["agent": "atlas", "start": 4, "length": 10]])
        let none = try body(PendingRequest(hub: hub, database: "db", client: "test", mentions: [], text: "Ask @marketin"))
        #expect((none["mentions"] as? [Any])?.isEmpty == true, "the app read the words and found no tag")
        #expect(try body(PendingRequest(hub: hub, database: "db", client: "test", text: "Hi"))["mentions"] == nil)
        let answer = PendingRequest(hub: hub, database: "db", client: "test", needID: 5, mentions: [tag], text: "Yes")
        #expect(answer.mentions == nil)
        #expect(try body(answer)["mentions"] == nil)
        // the disk keeps them; a file of a version before them has none, and sends none
        let saved = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(PendingRequest.self, from: saved).mentions == [tag])
        var older = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        older.removeValue(forKey: "mentions")
        let read = try JSONDecoder().decode(PendingRequest.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(read.mentions == nil && read.text == "Ask @Marketing")
        #expect(try body(read)["mentions"] == nil)
        // the waiting bubble draws from its own tags
        #expect(OwnerMessage(onItsWay: message).mentions?.tags == [tag])
    }

    /// **The hub's `messages[].mentions` is never strict.** The bug that this catches: one value of a shape that the app
    /// does not read makes the whole reading fail, and the chat shows nothing.
    @Test func theTagsOfTheHubsReadingAreNeverStrict() throws {
        func message(_ id: String, _ mentions: Any?) -> [String: Any] {
            var row: [String: Any] = ["request_id": id, "recipient": "nova", "kind": "message", "text": "Ask @Marketing",
                                      "event_id": 1, "created": 100, "client": "test"]
            row["mentions"] = mentions
            return row
        }
        let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": 200,
            "agents": [["name": "manager", "role": "manager", "runtime": "codex", "can": []]], "tasks": [], "holds": [],
            "outcomes": [], "notes": [], "needs": [], "permissions": [], "reports": [], "ui_features": [AgentTags.feature],
            "messages": [message("a", [["agent": "atlas", "start": 4, "length": 10]]), message("b", "atlas"),
                         message("c", [["agent": "atlas", "start": "4", "length": 10], ["agent": "iris", "start": 0, "length": 3]]),
                         message("d", nil)]]))
        let tags = Dictionary(uniqueKeysWithValues: state.messages.map { ($0.request_id, $0.mentions?.tags) })
        #expect(tags.count == 4)
        #expect(tags["a"] == [Mention(agent: "atlas", start: 4, length: 10)])
        #expect(tags["b"] == [] && tags["c"] == [Mention(agent: "iris", start: 0, length: 3)])
        #expect(tags["d"] == .some(nil))
    }

    // MARK: the bubble

    /// **In his sent message each tag is its agent's badge, over the whole tag, through the Markdown of its blocks.** The
    /// bug that this catches: the hub's range in his text falls on other words in a block (after an emoji, a mark of
    /// bold, a list's mark), a copy of the words changes, a tag in code is a badge, or an entry that does not hold an
    /// "@" changes his words.
    @Test func aTagOfHisSentMessageIsItsAgentsBadgeInItsBlock() throws {
        let book = ChatNames(agents: Self.team)
        let text = "**Hi** 👩‍💻 ask @Marketing\n- then @DevOps, and `@Marketing` stays code\n\n| @Juno |\n|---|\n| x |"
        let mentions = tags.mentions(in: text)
        #expect(mentions.map(\.agent) == ["atlas", "iris", "juno"])
        func drawn(_ text: String, _ mentions: [Mention]) throws -> [ChatWords] {
            let marked = AgentTags.marked(text, mentions: mentions)
            return MessageBlock.parse(marked?.text ?? text).filter { $0.kind != .table }.map { block in
                let words = MessageBlock.inline(block.text)
                return book.words(marked.map { AgentTags.unmarked(words, by: $0) } ?? words)
            }
        }
        let words = try drawn(text, mentions)
        #expect(words.map { String($0.text.characters) } == ["Hi 👩‍💻 ask @Marketing", "then @DevOps, and @Marketing stays code"])
        #expect(words.map { $0.badges.map(\.target) } == [[.agent("atlas")], [.agent("iris")]])
        #expect(words.map { $0.badges.map(\.characters) } == [[9..<19], [5..<12]])
        // a table's cell keeps its words, the "@" too
        let marked = try #require(AgentTags.marked(text, mentions: mentions))
        let table = try #require(MessageBlock.parse(marked.text).first { $0.kind == .table })
        #expect(table.cells.flatMap { $0 }.map { AgentTags.unmarked($0, by: marked) } == ["@Juno", "x"])
        // an entry with no "@" at its start, or past the end, is no tag, and the words stay his
        #expect(AgentTags.marked("Hi there", mentions: [Mention(agent: "atlas", start: 0, length: 2),
                                                        Mention(agent: "atlas", start: 6, length: 9)]) == nil)
        #expect(try drawn("Hi there", [Mention(agent: "atlas", start: 0, length: 2)]).map { String($0.text.characters) }
                == ["Hi there"])
        // the key of the blocks holds each tag's length: two lists with the same starts are two readings
        let short = try #require(AgentTags.marked("@DevOps Lead now", mentions: [Mention(agent: "iris", start: 0, length: 7)]))
        let long = try #require(AgentTags.marked("@DevOps Lead now", mentions: [Mention(agent: "iris", start: 0, length: 12)]))
        #expect(short.key != long.key)
        // his words whose tags the hub gave: only an entry is a tag; an "@" name outside them stays words
        let given = "tell @Juno and @DevOps"
        let only = try #require(AgentTags.marked(given, mentions: [Mention(agent: "iris", start: 15, length: 7)]))
        var block = AgentTags.unmarked(MessageBlock.inline(only.text), by: only)
        var mark = AttributeContainer()
        mark[AgentTags.Given.self] = true
        block.mergeAttributes(mark)
        #expect(book.words(block).badges.map(\.target) == [.agent("iris")])
        #expect(book.words(MessageBlock.inline(given)).badges.map(\.target) == [.agent("juno"), .agent("iris")],
                "with no list (a hub before the tags), a name after an \"@\" is its badge, as in a reply")
        // his own link on the words keeps them words
        let linked = "See [@Marketing](https://example.com)"
        #expect(try drawn(linked, tags.mentions(in: linked)).flatMap { $0.badges }.isEmpty)
    }
}
