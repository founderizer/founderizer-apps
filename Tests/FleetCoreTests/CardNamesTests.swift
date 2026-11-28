import Foundation
import Testing
@testable import FleetCore

// The names in a request's words are links (the lane "Give on a card", 19 November 2026): an agent by its role, the
// start of its role or its name with a capital; a repository; a server; a page of the app. A plain word that is no
// name stays words: a link that opens the wrong agent, or Founderizer's page for another product's, is worse than none.

private let book = card(given: [])

/// The book of a card whose own Give names the repositories `given`; none: the one book of every other card.
private func card(given: [String]) -> CardNames {
    CardNames(
        agents: [("nova", "Customer Support Lead"), ("atlas", "Customer Developer"), ("manager", "Fleet Manager"),
                 ("kai", nil), ("studio", nil), ("rex", "Head of Growth"), ("ana", "Designer"), ("bo", "Designer")],
        repositories: ["acme/web", "acme/shop-api", "other/shop-api", "acme/docs-site", "acme/acme.com",
                       "acme/.github"],
        servers: ["app-1", "hub"], given: given)
}

private func names(_ text: String, given: [String] = []) -> [String: CardNames.Target] {
    Dictionary(card(given: given).find(in: text).map { (String(text[$0.range]), $0.target) },
               uniquingKeysWith: { first, _ in first })
}

/// An agent is its role, the unique start of its role or its name with a capital; **where a role is also another
/// agent's name, the name decides** (F23: an agent shows by its name, as a tag's name decides in `AgentTags`). The bug
/// that this catches: with the role "Sales" for Bo and an agent named sales, "I asked Sales" links Bo and reads "Bo ·
/// Sales".
@Test func anAgentIsItsRoleTheUniqueStartOfItsRoleOrItsNameWithACapital() {
    let found = names("Customer Support asks Kai, the Manager and Customer Developer; the manager and Customer wait.")
    #expect(found == ["Customer Support": .agent("nova"), "Kai": .agent("kai"), "Manager": .agent("manager"),
                      "Customer Developer": .agent("atlas")])
    // the whole role wins over its start and over a name inside it
    #expect(names("Customer Support Lead and Fleet Manager") ==
            ["Customer Support Lead": .agent("nova"), "Fleet Manager": .agent("manager")])
    let team: [(name: String, role: String?)] = [("bo", "Sales"), ("sales", nil)]
    let both = CardNames(agents: team)
    #expect(both.find(in: "I asked Sales.").map(\.target) == [.agent("sales")])
    let drawn = CardJoin.join(both.pieces(AttributedString("I asked Sales.")),
                              roles: AgentNames.roles(team.map { ($0.name, $0.role) }))
    #expect(drawn.map { String($0.words.characters) } == ["I asked ", "Sales", "."])
    #expect(drawn.map(\.badge) == [nil, .agent("sales"), nil])
}

/// A name that can be a part of another name is no agent: a name or a role of one word beside a word with a capital,
/// the start of a role before one, a role that two hold. **A verb that opens the sentence is no such word** (C6 of F23
/// N1): "Give Marketing write" names the agent, at the sentence's start only. The bug that this catches: the step
/// "Give Marketing write" shows no badge, or a word with a capital at a sentence's start or a verb inside a product's
/// name makes "Android Studio", "Visual Studio" or "the Ask Studio app" a badge.
@Test func aNameThatCanBePartOfAnotherNameIsNoAgent() {
    #expect(names("Open Visual Studio and your Password Manager. Android Studio is no agent; ask Studio.") ==
            ["Studio": .agent("studio")])
    #expect(names("Ask the Head of Growth, not the Head of Sales.") == ["Head of Growth": .agent("rex")])
    #expect(names("Ask a Designer.").isEmpty)
    let opened = CardNames(agents: [("wren", "Marketing"), ("studio", nil)])
    func found(_ text: String) -> [CardNames.Target] { opened.find(in: text).map(\.target) }
    #expect(found("Give Marketing write") == [.agent("wren")])
    #expect(found("Done. Ask Studio first.\nTell Marketing too.") == [.agent("studio"), .agent("wren")])
    // a list item's, a heading's or a quote's mark at its line's start, which the folded reason reads (its open card
    // reads the line without it)
    #expect(found("Steps:\n- Give Marketing write\n  2. Ask Studio first\n> Tell Marketing") ==
            [.agent("wren"), .agent("studio"), .agent("wren")])
    // "Let" is no opening verb: its next word is often a noun of the sentence
    #expect(found("Let Marketing spend run until Friday.").isEmpty)
    for text in ["Android Studio is no agent.", "Visual Studio opens it.", "It runs. Visual Studio opens it.",
                 "Open the Ask Studio app.", "We use Visual Studio.", "Done - Ask Studio first."] {
        #expect(found(text).isEmpty, "\(text)")
    }
}

@Test func aRepositoryIsOwnerAndNameOrADistinctNameOfOneRepository() {
    #expect(names("Push to Acme/Web, read docs-site and the web.") ==
            ["Acme/Web": .repository("acme/web"), "docs-site": .repository("acme/docs-site")])
    // two repositories share the name: only owner/name says which
    #expect(names("shop-api and other/shop-api") == ["other/shop-api": .repository("other/shop-api")])
    #expect(names("acme/webhooks, acme/web/tree, ops@app-1.example").isEmpty)
    // a name with no hyphen or underscore, or one that starts with a point, is a word or a domain of another thing
    #expect(names("Read acme.com and the .github folder.").isEmpty)
}

/// **On the card whose own Give names a repository, its name alone is a badge in any form** (the owner, 23 November
/// 2026: "Yes: a name that the card's Give names is a badge"). The bugs that this catches: a name of letters only stays
/// words on the card that gives it; it is a badge on every card, so a common word of another card opens a repository
/// ("web", "docs"); one of two repositories of one name opens for the other; an opening verb before it ("Tell Sales
/// the price") keeps it words, where it lets an agent's name stand.
@Test func onTheCardOfItsOwnGiveARepositoryIsItsNameAloneInAnyForm() {
    let words = "Push it to web. Web is old, and shop-api too."
    #expect(names(words, given: ["acme/shop-api", "acme/web"]) ==
            ["web": .repository("acme/web"), "Web": .repository("acme/web"),
             // the one of two fleet repositories of this name that the Give names
             "shop-api": .repository("acme/shop-api")])
    // an opening verb before it lets the name stand, as before an agent's name (C6 of F23 N1), on that card only
    #expect(names("Tell Sales the price.", given: ["acme/sales"]) == ["Sales": .repository("acme/sales")])
    #expect(names("Tell Sales the price.").isEmpty)
    // the same words with no Give, and on a card whose Give names another repository
    #expect(names(words).isEmpty)
    #expect(names(words, given: ["acme/docs-site"]).isEmpty)
    // two repositories of one Give with one name: only owner/name says which
    #expect(names(words + " Read other/web.", given: ["acme/shop-api", "acme/web", "other/shop-api", "other/web"]) ==
            ["other/web": .repository("other/web")])
}

/// **A name alone that the card's Give names is no badge where it is part of another name** (the bug that this catches:
/// "Visual Studio" with a badge of the repository acme/studio): beside a word with a capital in capitals of its own,
/// inside a longer name or an address, and a folder's name (".github"). An agent of the same name stays the agent.
@Test func aNameThatTheCardsGiveNamesIsNoBadgeInAnotherName() {
    let given = ["acme/studio", "acme/web", "acme/.github"]
    #expect(names("Open Visual Studio and the Web Inspector in the .github folder.", given: given).isEmpty)
    #expect(names("Read web.example, web-2, my/web and https://example.com/web.", given: given).isEmpty)
    #expect(names("Then ask Studio to read studio.", given: given) ==
            ["Studio": .agent("studio"), "studio": .repository("acme/studio")])
}

/// **A Give's short name hides no secret of the same words** (a review of 23 November 2026). The bug that this catches:
/// on a card whose Give names x/stripe, the login `Stripe` in inline code is a copy chip, not its badge, and "stripe"
/// in words opens GitHub.
@Test func aGivesShortNameHidesNoSecretOfTheSameWords() {
    let book = CardNames(agents: [], secrets: [(name: "Stripe", key: false)], given: ["acme/stripe"])
    let text = AttributedString("Then rotate ") + coded("Stripe") + AttributedString(" for stripe.")
    #expect(book.pieces(text).compactMap(\.badge) == [.secret("Stripe", key: false)])
}

/// **A Give's short name hides no page of the app of the same words** (a review of 23 November 2026). The bug that this
/// catches: on a card whose Give names x/resources, "Resources" opens GitHub, not the page of who may use what, and
/// the card loses Open <page>.
@Test func aGivesShortNameHidesNoPageOfTheSameWords() {
    let book = CardNames(agents: [], given: ["acme/resources"])
    #expect(book.pages(inMarkdown: "In Founderizer, open Resources and give it resources.") == ["settings/apps"])
}

@Test func aServerIsANameWithADigitOrAHyphen() {
    #expect(names("Restart app-1 on the hub, not app-10.") == ["app-1": .server("app-1")])
}

@Test func aPageOfTheAppIsItsWordsInASentenceThatNamesFounderizer() {
    #expect(names("In Founderizer, open Settings › Apps, then the Secrets page.") ==
            ["Settings › Apps": .page("settings/apps"), "Secrets page": .page("settings/secrets")])
    // the same words of another product's settings
    #expect(names("On your iPhone, open Settings > Apps > Founderizer. In System Settings > General, turn it on.")
        .isEmpty)
    #expect(names("Allow Founderizer in System Settings > General > Login Items. For Founderizer's pushes, open "
                  + "Settings > Apps > Founderizer on your iPhone.").isEmpty)
    #expect(book.pages(inMarkdown: "In Founderizer: Settings, Apps, MCP servers, then Sign in again.") == ["app/mcp"])
    #expect(book.pages(inMarkdown: "1. In Founderizer on your Mac, on the Apps page under GitHub, choose the file.\n"
                                   + "2. Save it on the Apps page.") == ["settings/apps"])
    // the names that agents give the page of who may use what; Needs you is no page that a card opens
    #expect(book.pages(inMarkdown: "In Founderizer, open Resources, then the repository acme/web.") == ["settings/apps"])
    #expect(book.pages(inMarkdown: "It is on Needs you in Founderizer.").isEmpty)
    // a page in code, or as the words of a link of its own, is not the step's page
    #expect(book.pages(inMarkdown: "In Founderizer, open `Settings › Apps` or [Settings › Apps](https://example.com/).")
        .isEmpty)
}

@Test func aNameInCodeOrInALinkStaysWordsAndATargetComesBackFromItsLink() throws {
    var text = AttributedString("Nova reads ")
    var code = AttributedString("app-1")
    code.inlinePresentationIntent = .code
    var linked = AttributedString("app-1")
    linked.link = URL(string: "https://example.com/")
    text += code + AttributedString(" on ") + linked + AttributedString(" and acme/web.")
    let pieces = book.pieces(text)
    #expect(pieces.map { String($0.words.characters) } == ["Nova", " reads app-1 on app-1 and ", "acme/web", "."])
    #expect(pieces.map(\.badge) == [.agent("nova"), nil, .repository("acme/web"), nil])
    // the link of the words' own stays theirs
    #expect(pieces[1].words.runs.contains { $0.link == URL(string: "https://example.com/") })
    #expect(pieces[2].words.link == URL(string: "https://github.com/acme/web"))
    #expect(CardNames.Target(url: try #require(pieces[0].words.link)) == .agent("nova"))
    #expect(CardNames.Target(url: try #require(CardNames.Target.page("settings/apps").url)) == .page("settings/apps"))
    #expect(CardNames.Target(url: try #require(URL(string: "https://github.com/acme/web"))) == nil)
}

/// A knowledge file of the owner's is its path (the owner, 20 November 2026: "referencing knowledge files would be very
/// nice too", and "Yes, as drawn"): in words, or as the whole of an inline code, as agents write a path. A path that the
/// book does not hold, or one inside a longer code, stays words: a badge that opens no file is worse than none.
@Test func aKnowledgeFileIsItsPathInWordsOrAsTheWholeOfAnInlineCode() throws {
    let files = CardNames(agents: [], knowledge: ["knowledge/owner/brand.md", "knowledge/owner/prices-2026.md"])
    var whole = AttributedString("knowledge/owner/prices-2026.md")
    whole.inlinePresentationIntent = .code
    var longer = AttributedString("cat knowledge/owner/brand.md")
    longer.inlinePresentationIntent = .code
    let text = AttributedString("See knowledge/owner/brand.md, ") + whole + AttributedString(" and ") + longer
        + AttributedString(", not knowledge/owner/other.md or knowledge/owner/brand.md.bak.")
    let pieces = files.pieces(text)
    #expect(pieces.compactMap(\.badge) ==
            [.knowledge("knowledge/owner/brand.md"), .knowledge("knowledge/owner/prices-2026.md")])
    #expect(pieces.map { String($0.words.characters) }.joined() == String(text.characters))
    // the badge of a path from code has the badge's look, not code's
    let badge = try #require(pieces.first { $0.badge == .knowledge("knowledge/owner/prices-2026.md") })
    #expect(badge.words.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.code) != true })
    #expect(CardNames.Target(url: try #require(badge.words.link)) == .knowledge("knowledge/owner/prices-2026.md"))
}

/// **A repository's owner/name is its badge on a card also as the whole of an inline code** (the owner, 23 November
/// 2026, of "the whole code being owner/name of a repository of your fleet": "The repository's badge"), its words as
/// written and its press the page on GitHub. Code around it, a name alone, also one that the card's Give names, an
/// owner/name that the book does not hold, and code in a link's words ("1: it stays a link") stay as they are. The bugs
/// that this catches: the name stays code, or a command that holds the name is cut into a badge.
@Test func aRepositoryIsItsBadgeAsTheWholeOfAnInlineCode() throws {
    var linked = coded("acme/web")
    linked.link = URL(string: "https://example.com/")
    var text = AttributedString("Push ") + coded("Acme/Web")
    let others = ["git clone acme/web", "acme/web ", "acme/other", "docs-site", "web"]
    for other in others.map(coded) + [linked] { text += AttributedString(", not ") + other }
    let pieces = card(given: ["acme/web"]).pieces(text)
    #expect(pieces.map(\.badge) == [nil, .repository("acme/web"), nil])
    #expect(pieces.map { String($0.words.characters) }.joined() == String(text.characters))
    let badge = try #require(pieces.first { $0.badge != nil }).words
    #expect(String(badge.characters) == "Acme/Web")
    #expect(badge.link == URL(string: "https://github.com/acme/web"))
    #expect(badge.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.code) != true })
}

/// A card draws each name as a badge (the owner, 20 November 2026): every word of the request stays, once and in its
/// order, around them. A lost tail or a name drawn twice would change what the owner reads.
@Test func theBadgesOfTheNamesKeepEveryWordInItsPlace() {
    var bold = AttributedString("Nova")
    bold.inlinePresentationIntent = .stronglyEmphasized
    let text = AttributedString("Please ask ") + bold
        + AttributedString(" to push acme/web on app-1, then app-1 again. In Founderizer, open Settings › Apps")
    let pieces = book.pieces(text)
    #expect(pieces.map { String($0.words.characters) } ==
            ["Please ask ", "Nova", " to push ", "acme/web", " on ", "app-1", ", then ", "app-1",
             " again. In Founderizer, open ", "Settings › Apps"])
    #expect(pieces.map(\.badge) == [nil, .agent("nova"), nil, .repository("acme/web"), nil, .server("app-1"), nil,
                                     .server("app-1"), nil, .page("settings/apps")])
    // a badge keeps its marks
    #expect(pieces[1].words.inlinePresentationIntent == .stronglyEmphasized)
    #expect(book.pieces(AttributedString("No name here.")).map(\.badge) == [nil])
}

/// The names of a chat (`ChatNames`): the same agents, repositories, servers and secrets as a card's.
private let chat = ChatNames(
    agents: [("leo", "Web Lead"), ("mia", "Web Developer"), ("nova", "Customer Support Lead"), ("kai", "Marketing"),
             ("bo", "Sales"), ("iris", "SEO & AI Search")],
    repositories: ["acme/web", "acme/shop-api"], servers: ["m4", "app-1"],
    secrets: [(name: "EXAMPLE_API_KEY", key: true), (name: "Backup2", key: false), (name: "Stripe", key: false)])

/// `words` as the whole of one inline code, as an agent writes a key's name or a path.
private func coded(_ words: String) -> AttributedString {
    var text = AttributedString(words)
    text.inlinePresentationIntent = .code
    return text
}

/// **A chat's message badges only what names one thing in free words** (the owner, 20 November 2026: "ok but use
/// always the agent badges and icons!!"; the review of 21 November 2026): an agent's name with a capital and its whole
/// role, a role of one word right after a word, a server and a repository as written, a possessive with "'s" as words
/// after its badge, and a secret's name as a card shows it (the owner, 21 November 2026: "task cards in both agents chat
/// and needs you sohuld also have a badge for specific Credentials", and "Yes, both"): a name with an underscore or a
/// digit in words and as the whole of an inline code, a name of letters only ("Stripe") only as the whole of one. A role
/// of one word after anything but a word (a line's start, punctuation, a quote, a bracket, a digit, an emoji, an arrow),
/// the start of a role, a server or a repository in other capitals, a page of the app, a secret's name in other
/// capitals or inside a longer word or code, and a name of letters only in free words stay words with no link, where a
/// card's rules found them; and every character stays as written, in its order, but a whole role, which draws its
/// agent's name with the role muted beside it, and an agent's name, which draws its role beside it
/// (`anAgentsNameInAnAgentsWordsDrawsItsRoleBesideIt`), and a copy holds what shows (the owner, 23 November 2026: "We should
/// ALWAYS use the name", and "The name with the role in grey"; the bug that this catches: a reply shows the role where
/// the sidebar shows the name, the role is no part of its own, or his own bubble changes what he wrote). What
/// the book keeps of a text that it read is the text's alone, its marks too.
@Test func aChatMessageBadgesOnlyWhatNamesOneThingInFreeWords() {
    func words(_ text: String) -> [String] { chat.pieces(AttributedString(text)).map { String($0.words.characters) } }
    func badges(_ text: String) -> [CardNames.Target?] { chat.pieces(AttributedString(text)).map(\.badge) }
    // the owner's mock-up
    #expect(words("Leo is going ahead with 80 and updating Mia's duty.") ==
            ["Leo\u{00A0}·\u{00A0}Web Lead", " is going ahead with 80 and updating ", "Mia\u{00A0}·\u{00A0}Web Developer", "'s duty."])
    #expect(badges("Leo is going ahead with 80 and updating Mia's duty.") == [.agent("leo"), nil, .agent("mia"), nil])
    let named = "Customer Support Lead and SEO & AI Search read acme/web; Kai’s post waits for app-1."
    #expect(words(named) == ["Nova\u{00A0}·\u{00A0}Customer Support Lead", " and ", "Iris\u{00A0}·\u{00A0}SEO & AI Search", " read ", "acme/web", "; ",
                             "Kai\u{00A0}·\u{00A0}Marketing", "’s post waits for ", "app-1", "."])
    #expect(badges(named) == [.agent("nova"), nil, .agent("iris"), nil, .repository("acme/web"), nil, .agent("kai"), nil,
                              .server("app-1"), nil])
    // the book keeps what it read by the words with their marks: the same name in inline code is no badge
    var code = AttributedString("Leo")
    code.inlinePresentationIntent = .code
    #expect(chat.words(AttributedString("Leo")).badges.map(\.target) == [.agent("leo")])
    #expect(chat.words(code).badges.isEmpty)
    // a repository in inline code, which is a card's badge, stays the chat's code as it is
    #expect(chat.words(coded("acme/web")).text == coded("acme/web"))
    #expect(chat.words(coded("acme/web")).badges.isEmpty)
    // a secret of the fleet's, with its kind for its mark
    #expect(badges("Leo put the new value in EXAMPLE_API_KEY and Backup2.") ==
            [.agent("leo"), nil, .secret("EXAMPLE_API_KEY", key: true), nil, .secret("Backup2", key: false), nil])
    for (name, key) in [("EXAMPLE_API_KEY", true), ("Backup2", false), ("Stripe", false)] {
        let words = chat.words(AttributedString("Check ") + coded(name) + AttributedString(" now."))
        #expect(words.badges.map(\.target) == [.secret(name, key: key)], "\(name)")
        #expect(String(words.text.characters) == "Check \(name) now.")
    }
    #expect(chat.words(coded("export EXAMPLE_API_KEY=1")).badges.isEmpty)
    #expect(chat.words(coded("Stripe key")).badges.isEmpty)
    // a role of one word inside a sentence: its agent's name, where the badge stands in the words that a copy holds
    #expect(words("I asked Marketing to check it.") == ["I asked ", "Kai\u{00A0}·\u{00A0}Marketing", " to check it."])
    #expect(badges("I asked Marketing to check it.") == [nil, .agent("kai"), nil])
    #expect(badges("The quote goes to Sales today.") == [nil, .agent("bo"), nil])
    #expect(words("I read Marketing's post.") == ["I read ", "Kai\u{00A0}·\u{00A0}Marketing", "'s post."])
    let asked = chat.words(AttributedString("I asked Marketing to check it."))
    #expect(String(asked.text.characters) == "I asked Kai\u{00A0}·\u{00A0}Marketing to check it.")
    #expect(asked.badges.map(\.characters) == [8..<23])
    // the role is the marked part of the badge's words, which a drawer draws muted
    #expect(asked.text.runs[RoleNames.RolePart.self].compactMap { $0.0 == true ? String(asked.text[$0.1].characters) : nil }
            == ["\u{00A0}·\u{00A0}Marketing"])
    // his own bubble keeps what he wrote, and the book reads it apart from the same words of an agent
    let his = chat.words(RoleNames.written(AttributedString("I asked Marketing to check it.")))
    #expect(String(his.text.characters) == "I asked Marketing to check it.")
    #expect(his.badges.map(\.target) == [.agent("kai")])
    // the review's sentences, which a card's rules badge, and a role of one word after a sentence's end or a list's mark
    for sentence in ["Marketing spend rose 10%.", "Sales grew 5%.", "Done. Marketing waits for it.", "- Sales grew 5%.",
                     "It rose!\nMarketing spend too.", "We asked\nMarketing spend rose.",
                     "\"Marketing spend rose 10%,\" the report says.", "(Marketing spend rose 10%.)",
                     "Update: Marketing spend rose.", "He wrote \"done.\" Marketing spend rose.", "Done… Marketing spend rose.",
                     "✅ Sales grew 5%.", "→ Sales grew 5%.", "a) Sales grew 5%", "(1) Sales grew 5%.",
                     "SEO & content updates come next.",
                     "Customer Support answers first.", "Buy an M4 Mac mini.", "Push it to Acme/Web.",
                     "In Founderizer, see an Agents page and a Help page.",
                     "Open the Stripe dashboard.", "Rotate EXAMPLE_API_KEY_OLD and MY_EXAMPLE_API_KEY.",
                     "Set example_api_key and Backup23.", "Open EXAMPLE_API_KEY.txt now."] {
        let pieces = chat.pieces(AttributedString(sentence))
        #expect(pieces.count == 1 && pieces[0].badge == nil, "\(sentence)")
        #expect(pieces[0].words.runs.allSatisfy { $0.link == nil }, "\(sentence)")
        #expect(String(pieces[0].words.characters) == sentence)
    }
}

/// **An agent's name with its own role beside it is one badge** (the owner, 21 November 2026, of a card that drew an
/// agent's name and its role as two badges: "it should be the same, right? or show it only once!"): the name is the
/// badge and the role stays words, in a bracket, after a comma or a dash, and the other way round. Another agent's role
/// beside a name is that agent's badge. Every character stays, in its order.
@Test func anAgentsNameWithItsOwnRoleBesideItIsOneBadge() {
    for text in ["Nova (Customer Support Lead) answers first.", "Nova, Customer Support Lead, answers first.",
                 "Nova - Customer Support Lead answers first.", "Nova – Customer Support Lead answers first.",
                 "Nova—Customer Support Lead answers first.", "Customer Support Lead (Nova) answers first.",
                 "Customer Support Lead, Nova, answers first.", "Customer Support Lead - Nova answers first."] {
        let pieces = chat.pieces(AttributedString(text))
        #expect(pieces.compactMap(\.badge) == [.agent("nova")], "\(text)")
        #expect(pieces.filter { $0.badge != nil }.map { String($0.words.characters) } == ["Nova"], "\(text)")
        #expect(pieces.map { String($0.words.characters) }.joined() == text)
        #expect(pieces.filter { $0.badge == nil }.allSatisfy { $0.words.runs.allSatisfy { $0.link == nil } }, "\(text)")
    }
    #expect(chat.pieces(AttributedString("Nova (Web Developer) answers first.")).compactMap(\.badge) ==
            [.agent("nova"), .agent("mia")])
}

/// **In an agent's words in a chat, an agent's name draws its role beside it** (`RoleNames.withRoles`; the owner, 25
/// November 2026, of a message whose badge was "Iris" alone: "I think we agreed that we should show both agent name and
/// role? like in a nice card badge?"): "Iris · SEO & AI Search", with the role as the part that a drawer draws grey, and
/// "'s" after the badge. The name, the dot and the role's first word are joined by no-break spaces. The role shows
/// once in a block: not where the block writes it beside a name of the agent, either way round, or has a badge of its
/// role or of its whole role anywhere, and only on the first name of an agent; his own words keep what he wrote; an
/// agent with no role, the manager, whose role says its name, and an agent whose name is a person's of the fleet (in
/// any capitals and accents) keep the name alone. The bugs that this catches:
/// a name with no role in an agent's message, a role twice or on each mention, a role in his own bubble, a role that is
/// no part of its own (it would draw in the name's violet), "Manager · Fleet Manager", a line that breaks between a
/// name and its role, or a customer Mia that the words show as "Mia · Web Developer" (a review of 26 November 2026).
@Test func anAgentsNameInAnAgentsWordsDrawsItsRoleBesideIt() {
    let book = ChatNames(agents: [("iris", "SEO & AI Search"), ("leo", "Web Lead"), ("manager", "Fleet Manager"),
                                  ("juno", nil), ("nova", "Customer Support Lead"), ("kai", "Marketing")])
    func shown(_ text: AttributedString) -> [String] {
        book.pieces(text).map { $0.badge == nil ? String($0.words.characters) : "[\(String($0.words.characters))]" }
    }
    func shown(_ text: String) -> [String] { shown(AttributedString(text)) }
    #expect(shown("Iris rewrote all six guides.") == ["[Iris\u{00A0}·\u{00A0}SEO & AI Search]", " rewrote all six guides."])
    let iris = book.words(AttributedString("Iris rewrote all six guides."))
    #expect(iris.text.runs[RoleNames.RolePart.self].compactMap { $0.0 == true ? String(iris.text[$0.1].characters) : nil }
            == ["\u{00A0}·\u{00A0}SEO & AI Search"])
    #expect(iris.badges.map(\.characters) == [0..<22] && iris.badges.map(\.leads) == [true])
    // a possessive: "'s" stays after the badge, as after a badge of a whole role ("Wren · Marketing's plan")
    #expect(shown("Leo's team finished the patches.") == ["[Leo\u{00A0}·\u{00A0}Web Lead]", "'s team finished the patches."])
    // the name alone: an agent with no role, the manager (its role says its name), and his own words
    #expect(shown("Juno and Manager agreed.") == ["[Juno]", " and ", "[Manager]", " agreed."])
    #expect(shown(RoleNames.written(AttributedString("Iris rewrote it."))) == ["[Iris]", " rewrote it."])
    // the role once in a block: none where the block writes it beside one of the agent's names, either way round, or
    // has a badge of its role's words or of its whole role, before or after the name
    #expect(shown("Iris (SEO & AI Search) rewrote it.") == ["[Iris]", " (SEO & AI Search) rewrote it."])
    #expect(shown("SEO & AI Search, Iris, rewrote it.") == ["SEO & AI Search, ", "[Iris]", ", rewrote it."])
    #expect(shown("Marketing: Kai wrote it.") == ["Marketing: ", "[Kai]", " wrote it."])
    #expect(shown("Iris is our SEO & AI Search.") == ["[Iris]", " is our ", "[SEO & AI Search]", "."])
    #expect(shown("Nova is Customer Support Lead. Nova answers.") ==
            ["[Nova]", " is ", "[Customer Support Lead]", ". ", "[Nova]", " answers."])
    // the first name of an agent in a block only, also after a badge of its whole role
    #expect(shown("Iris wrote it, and later Iris checked it.") ==
            ["[Iris\u{00A0}·\u{00A0}SEO & AI Search]", " wrote it, and later ", "[Iris]", " checked it."])
    #expect(shown("I asked Marketing. Kai checked it.") ==
            ["I asked ", "[Kai\u{00A0}·\u{00A0}Marketing]", ". ", "[Kai]", " checked it."])
    // the role that the block shows anywhere, also after the name: a badge of the whole role, or the role beside it
    #expect(shown("Kai wrote the draft. Then I asked Marketing to check it.") ==
            ["[Kai]", " wrote the draft. Then I asked ", "[Kai\u{00A0}·\u{00A0}Marketing]", " to check it."])
    #expect(shown("Nova answered, and later Nova (Customer Support Lead) closed it.") ==
            ["[Nova]", " answered, and later ", "[Nova]", " (Customer Support Lead) closed it."])
    // a badge of the whole role named again is the name alone, also after an "@"
    #expect(shown("I asked Marketing and then told Marketing.") ==
            ["I asked ", "[Kai\u{00A0}·\u{00A0}Marketing]", " and then told ", "[Kai]", "."])
    #expect(shown("@Kai wrote it, and @Kai checked it.") ==
            ["[@Kai\u{00A0}·\u{00A0}Marketing]", " wrote it, and ", "[@Kai]", " checked it."])
    // once in a message: a block after one that shows the role shows it no more (`words(_:before:)`)
    let first = book.words(AttributedString("Iris wrote the list."))
    #expect(first.roles == ["iris"])
    #expect(String(book.words(AttributedString("Iris checked it."), before: first.roles).text.characters) == "Iris checked it.")
    #expect(String(book.words(AttributedString("I asked Marketing."), before: ["kai"]).text.characters) == "I asked Kai.")
    // one text read with two sets of earlier roles: two readings (the book's store keeps them apart)
    #expect(String(book.words(AttributedString("Kai sent it.")).text.characters) == "Kai\u{00A0}·\u{00A0}Marketing sent it.")
    #expect(String(book.words(AttributedString("Kai sent it."), before: ["kai"]).text.characters) == "Kai sent it.")
    // the role written beside the name counts as shown, for the next block and for a badge of the whole role after it
    #expect(book.words(AttributedString("Kai (Marketing) wrote it.")).roles == ["kai"])
    #expect(shown("Kai (Marketing) wrote it. Then I asked Marketing.") ==
            ["[Kai]", " (Marketing) wrote it. Then I asked ", "[Kai]", "."])
    // inside quotation marks, somebody's exact words: the name alone
    #expect(shown("The customer wrote: \"then Leo promised a refund\" and left.") ==
            ["The customer wrote: \"then ", "[Leo]", " promised a refund\" and left."])
    #expect(shown("She wrote \u{201C}thanks\u{201D}, and Leo replied.") ==
            ["She wrote \u{201C}thanks\u{201D}, and ", "[Leo\u{00A0}·\u{00A0}Web Lead]", " replied."])
    // each pair of marks, and a whole role inside them, as written
    for (open, close) in [("\u{201C}", "\u{201D}"), ("\u{00AB}", "\u{00BB}"), ("\u{201E}", "\u{201C}"),
                          ("\u{201D}", "\u{201D}"), ("\u{00BB}", "\u{00AB}")] {
        #expect(shown("She wrote \(open)then Leo left\(close), and Leo came back.") ==
                ["She wrote \(open)then ", "[Leo]", " left\(close), and ", "[Leo\u{00A0}·\u{00A0}Web Lead]", " came back."],
                "\(open)\(close)")
    }
    #expect(shown("She wrote \"I asked Marketing\" today.") == ["She wrote \"I asked ", "[Marketing]", "\" today."])
    // a mark with no partner is no quotation: an inch mark, a lone », a lone ”
    for lone in ["The 27\" screen is late.", "Open Settings \u{00BB} People.", "It is \u{201D} late."] {
        #expect(shown("\(lone) I asked Marketing.") == ["\(lone) I asked ", "[Kai\u{00A0}·\u{00A0}Marketing]", "."], "\(lone)")
    }
    // a person of the fleet's with the agent's name: the badge as before, with no role
    let mia = "Mia asked for a refund."
    #expect(ChatNames(agents: [("mia", "Web Developer")]).pieces(AttributedString(mia)).map { String($0.words.characters) }
            == ["Mia\u{00A0}·\u{00A0}Web Developer", " asked for a refund."])
    let people = ChatNames(agents: [("mia", "Web Developer")], people: ["Mia Example", "Pat"]).pieces(AttributedString(mia))
    #expect(people.map { String($0.words.characters) } == ["Mia", " asked for a refund."])
    #expect(people.map(\.badge) == [.agent("mia"), nil])
    // in any capitals and with any accents, on either side
    let zoe = ChatNames(agents: [("zoe", "Web Developer")], people: ["ZOË Example"]).pieces(AttributedString("Zoe asked."))
    #expect(zoe.map { String($0.words.characters) } == ["Zoe", " asked."])
    #expect(RoleNames.folded("Bjørn Weiß") == ["bjorn", "weiss"] && RoleNames.folded("Łukasz Æsir Yıldız") == ["lukasz", "aesir", "yildiz"])
    // all the agent's words, in their order, in one person's words
    let dev = AttributedString("Web-Dev asked.")
    #expect(ChatNames(agents: [("web-dev", "Web Developer")], people: ["Dev Example"]).pieces(dev)
                .map { String($0.words.characters) } == ["Web-Dev\u{00A0}·\u{00A0}Web Developer", " asked."])
    #expect(ChatNames(agents: [("web-dev", "Web Developer")], people: ["Ann Web Dev"]).pieces(dev)
                .map { String($0.words.characters) } == ["Web-Dev", " asked."])
    #expect(ChatNames(agents: [("web-dev", "Web Developer")], people: ["Dev Web Example"]).pieces(dev)
                .map { String($0.words.characters) } == ["Web-Dev\u{00A0}·\u{00A0}Web Developer", " asked."])
}

/// **A copy of a chat's words holds them as the message holds them** (the review of 21 November 2026: a no-break space
/// before a name that began its block went into the copy, "\u{00A0}mini-2 restarts"): the words that the chat's book
/// gives are the message's, character for character, but a name's role (`anAgentsNameInAnAgentsWordsDrawsItsRoleBesideIt`);
/// the Mac app adds one no-break space before a block that wraps and begins with a name (`ChatBadgeLookTests`), the
/// one exception that UI-PATTERNS writes. A name keeps its icon's room on a character before it on its line; one that
/// begins the words, left to right, has no character before it, and its icon stands before the words, also where they
/// have a line break (the owner's "use always the agent badges and icons!!", and of 25 November 2026, of a paragraph:
/// "the agent does not show his icon!"); one that a line break begins has no room, and neither has a name in a script
/// written right to left at the words' start. In a line written right to left, by the line's first letter (the review:
/// "שאלתי את Nova" drew the icon on the next word), the end of a badge is a kern on the character after the name,
/// whose side the layout gives.
@Test func aChatsDrawnWordsAreTheMessagesAndKeepARoomOnlyAfterACharacterOfTheirLine() {
    for text in ["app-1 restarts at 22:00.", "We restart app-1 tonight.", "We restart\napp-1 tonight.",
                 "EXAMPLE_API_KEY expired at 22:00.", "We put it in\nEXAMPLE_API_KEY tonight."] {
        #expect(String(chat.words(AttributedString(text)).text.characters) == text)
    }
    // a key's name from inline code: the badge's look, and the message's characters
    let key = chat.words(AttributedString("Put it in ") + coded("EXAMPLE_API_KEY") + AttributedString(" tonight."))
    #expect(String(key.text.characters) == "Put it in EXAMPLE_API_KEY tonight.")
    #expect(key.text.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.code) != true })
    // each name's room, and the character whose kern ends its badge, by its offset from the name's start
    func rooms(_ text: String, in book: ChatNames = chat) -> [String] {
        book.words(AttributedString(text)).badges.map {
            ($0.leads ? "leads" : $0.room ? "kern" : "none") + " end \($0.end - $0.characters.lowerBound)" + ($0.endAfter ? " after" : "")
        }
    }
    #expect(rooms("app-1 restarts at 22:00.") == ["leads end 4"])
    #expect(rooms("app-1 restarts at 22:00.\nThe logs stay.") == ["leads end 4"])
    #expect(rooms("We restart app-1 tonight.") == ["kern end 4"])
    #expect(rooms("We restart\napp-1 tonight.") == ["none end 4"])
    #expect(rooms("EXAMPLE_API_KEY expired at 22:00.") == ["leads end 14"])
    #expect(rooms("We put it in\nEXAMPLE_API_KEY tonight.") == ["none end 14"])
    let hebrew = ChatNames(agents: [("נובה", nil), ("nova", nil)])
    #expect(rooms("נובה בודקת את זה.", in: hebrew) == ["none end 4 after"])
    #expect(rooms("שאלתי את נובה לבדוק.", in: hebrew) == ["kern end 4 after"])
    #expect(rooms("שאלתי את Nova.", in: hebrew) == ["kern end 4 after"])
    #expect(rooms("שלום, I asked Nova to check.", in: hebrew) == ["kern end 4 after"])
    #expect(rooms("Done.\nשאלתי את Nova\nלבדוק.", in: hebrew) == ["kern end 3"])
    #expect(rooms("Nova בודקת, ואז נובה.", in: hebrew) == ["leads end 3", "kern end 0"])
    // where a layout finds the name: its UTF-16 units, past a character of two units before it
    let words = chat.words(AttributedString("🚀 We restart app-1."))
    #expect(words.badges.map(\.utf16) == [14..<19])
    #expect(words.badges.map(\.characters) == [13..<18])
    // the whole character before the name, whose glyph a layout gives at its first unit only
    #expect(chat.words(AttributedString("Done 👩‍💻Nova checks.")).badges.map(\.before) == [5..<10])
    #expect(chat.words(AttributedString("Done 🇪🇸Nova checks.")).badges.map(\.before) == [5..<9])
    #expect(words.badges.map(\.before) == [13..<14])
}

/// **A chat's new book with the same names keeps what the old one read** (the review of 21 November 2026: each new book
/// read all 500 blocks of a chat again): the app makes the book again when what it is made of changes, also when its
/// names stay the same; a book with other names reads anew.
@Test func aChatsNewBookWithTheSameNamesKeepsWhatTheOldOneRead() {
    let old = ChatNames(agents: [("nova", "Customer Support Lead")], servers: ["app-1", "app-2"])
    _ = old.words(AttributedString("Nova restarts app-1."))
    let same = ChatNames(agents: [("nova", "Customer Support Lead")], servers: ["app-2", "app-1"]).keeping(old)
    #expect(same.read === old.read)
    let other = ChatNames(agents: [("nova", "Customer Support Lead")], servers: ["app-1"]).keeping(old)
    #expect(other.read !== old.read)
}

/// **A tag of his message is its agent's badge over the whole tag, "@" included** (owner feature `agent_tags`; his "Yes,
/// as drawn": "in a sent message the tag is the chat's agent badge"; `AgentTags.Tagged`), with the glyph of the agent of
/// now, and it wins over a name that the book finds inside it; a tag of an agent that the book does not know is plain
/// words. **In an agent's reply, a name right after an "@" that starts a tag takes the "@" into its badge**, and a role
/// of one word counts there as after a word; any other name after such an "@" stays words, as it was. The bug that this
/// catches: his tag drawn as another agent's badge, a removed agent's tag drawn as the agent that now has its words,
/// "@" left outside the badge, or "@app-1" a server's badge where it was words. Every character stays, in its order, but
/// a whole role after an agent's "@", which draws the agent's name with its role, and an agent's name after it, which
/// draws its role (`RoleNames`).
@Test func aTagIsItsAgentsBadgeAndAnAtBeforeANameJoinsItsBadge() {
    func tagged(_ text: String, _ agent: String, _ range: Range<Int>) -> AttributedString {
        var words = AttributedString(text)
        let start = words.characters.index(words.startIndex, offsetBy: range.lowerBound)
        var tag = AttributeContainer()
        tag[AgentTags.Tagged.self] = agent
        words[start..<words.characters.index(start, offsetBy: range.count)].mergeAttributes(tag)
        return words
    }
    func shown(_ text: AttributedString) -> [String] {
        chat.pieces(text).map { piece in
            let words = String(piece.words.characters)
            guard case .agent(let agent)? = piece.badge else { return words }
            #expect(piece.words.runs.allSatisfy { $0.link == CardNames.Target.agent(agent).url }, "\(words)")
            return "[\(agent): \(words)]"
        }
    }
    // his tag of kai over "@Customer Support", where the book finds nova's "Customer Support Lead": kai's badge
    #expect(shown(tagged("Ask @Customer Support Lead now", "kai", 4..<21)) == ["Ask ", "[kai: @Customer Support]", " Lead now"])
    #expect(chat.pieces(tagged("Ask @Customer Support Lead now", "kai", 4..<21)).last?.words.runs.allSatisfy { $0.link == nil } == true)
    // a removed agent's tag is words, also where its words name another agent
    #expect(shown(tagged("Ask @Marketing now", "gone", 4..<14)) == ["Ask @Marketing now"])
    // an agent's reply: the name or the role after an "@" that starts a tag, with the "@"
    #expect(shown(AttributedString("I asked @Leo, then (@Marketing): ok.")) ==
            ["I asked ", "[leo: @Leo\u{00A0}·\u{00A0}Web Lead]", ", then (", "[kai: @Kai\u{00A0}·\u{00A0}Marketing]", "): ok."])
    #expect(shown(AttributedString("@Marketing drafts it.")) == ["[kai: @Kai\u{00A0}·\u{00A0}Marketing]", " drafts it."])
    #expect(shown(AttributedString("@Customer Support Lead answers.")) ==
            ["[nova: @Nova\u{00A0}·\u{00A0}Customer Support Lead]", " answers."])
    // the agent's "@" name in the same sentence: the role stays, in addition to the name
    #expect(shown(AttributedString("@Nova is Customer Support Lead now.")) ==
            ["[nova: @Nova]", " is ", "[nova: Customer Support Lead]", " now."])
    // no badge: a role of one word at a sentence's start with no "@", a server after "@", an email, a name in small letters
    for text in ["Marketing drafts it.", "Ping @app-1 now.", "Write to pat@Leo.example today.", "Ask @leo now.",
                 "Ask x@Leo now."] {
        #expect(chat.pieces(AttributedString(text)).allSatisfy { $0.badge == nil }, "\(text)")
        #expect(chat.pieces(AttributedString(text)).map { String($0.words.characters) }.joined() == text)
    }
    #expect(chat.words(AttributedString("I asked @Leo.")).badges.map(\.characters) == [8..<23])
}

/// **A secret of the fleet's is its name** (the owner, 21 November 2026: "task cards in both agents chat and needs you
/// sohuld also have a badge for specific Credentials", and "Yes, both"): a key's variable name in words or as the whole
/// of an inline code, with its kind for its mark and its own link. A name of words of letters only ("Stripe", "Google
/// Drive") is a product's words too, so it is a badge only as the whole of an inline code; a name that the list does
/// not have stays words.
@Test func aSecretIsItsNameWhereItCannotBeAWord() throws {
    let book = CardNames(agents: [], secrets: [(name: "DOOR_BACKBLAZE_ACME_KEY", key: true), (name: "Stripe", key: false),
                                               (name: "Google Drive", key: false)])
    var code = AttributedString("Stripe")
    code.inlinePresentationIntent = .code
    let text = AttributedString("Open DOOR_BACKBLAZE_ACME_KEY and the Stripe dashboard in Google Drive, then check ") + code
        + AttributedString(" and DOOR_BACKBLAZE_OTHER_KEY.")
    let pieces = book.pieces(text)
    #expect(pieces.compactMap(\.badge) == [.secret("DOOR_BACKBLAZE_ACME_KEY", key: true), .secret("Stripe", key: false)])
    #expect(pieces.map { String($0.words.characters) }.joined() == String(text.characters))
    let login = try #require(pieces.first { $0.badge == .secret("Stripe", key: false) })
    #expect(login.words.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.code) != true })
    #expect(CardNames.Target(url: try #require(login.words.link)) == .secret("Stripe", key: false))
    let key = try #require(pieces.first { $0.badge == .secret("DOOR_BACKBLAZE_ACME_KEY", key: true) })
    #expect(CardNames.Target(url: try #require(key.words.link)) == .secret("DOOR_BACKBLAZE_ACME_KEY", key: true))
}
