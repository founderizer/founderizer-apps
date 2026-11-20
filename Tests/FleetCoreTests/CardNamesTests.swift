import Foundation
import Testing
@testable import FleetCore

// The names in a request's words are links (the lane "Give on a card", 19 November 2026): an agent by its role, the
// start of its role or its name with a capital; a repository; a server; a page of the app. A plain word that is no
// name stays words: a link that opens the wrong agent, or Founderizer's page for another product's, is worse than none.

private let book = CardNames(
    agents: [("nova", "Customer Support Lead"), ("atlas", "Customer Developer"), ("manager", "Fleet Manager"),
             ("kai", nil), ("studio", nil), ("rex", "Head of Growth"), ("ana", "Designer"), ("bo", "Designer")],
    repositories: ["acme/web", "acme/shop-api", "other/shop-api", "acme/docs-site", "acme/acme.com", "acme/.github"],
    servers: ["app-1", "hub"])

private func names(_ text: String) -> [String: CardNames.Target] {
    Dictionary(book.find(in: text).map { (String(text[$0.range]), $0.target) }, uniquingKeysWith: { first, _ in first })
}

@Test func anAgentIsItsRoleTheUniqueStartOfItsRoleOrItsNameWithACapital() {
    let found = names("Customer Support asks Kai, the Manager and Customer Developer; the manager and Customer wait.")
    #expect(found == ["Customer Support": .agent("nova"), "Kai": .agent("kai"), "Manager": .agent("manager"),
                      "Customer Developer": .agent("atlas")])
    // the whole role wins over its start and over a name inside it
    #expect(names("Customer Support Lead and Fleet Manager") ==
            ["Customer Support Lead": .agent("nova"), "Fleet Manager": .agent("manager")])
}

@Test func aNameThatCanBePartOfAnotherNameIsNoAgent() {
    // a name or a role of one word beside a word with a capital; the start of a role before one; a role that two hold
    #expect(names("Open Visual Studio and your Password Manager. Android Studio is no agent; ask Studio.") ==
            ["Studio": .agent("studio")])
    #expect(names("Ask the Head of Growth, not the Head of Sales.") == ["Head of Growth": .agent("rex")])
    #expect(names("Ask a Designer.").isEmpty)
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
    var code = AttributedString("acme/web")
    code.inlinePresentationIntent = .code
    var linked = AttributedString("app-1")
    linked.link = URL(string: "https://example.com/")
    text += code + AttributedString(" on ") + linked + AttributedString(" and acme/web.")
    let pieces = book.pieces(text)
    #expect(pieces.map { String($0.words.characters) } == ["Nova", " reads acme/web on app-1 and ", "acme/web", "."])
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
