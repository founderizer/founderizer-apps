import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **His bubble and an agent's reply with the same words each draw by their own rule** (`MessageText.asWritten`; F23
/// N1, 23 November 2026): his own words keep a role and a name as he wrote them, and an agent's words draw the agent's
/// name with its role (and of a name, its role: the owner, 25 November 2026, "show both agent name and role"), in
/// either order. **A quote in an agent's reply keeps its words as written too**, also one in a list item: it holds
/// somebody's exact words; and **the role shows once in a message**, on the first name of its first block (reviews of 26
/// November 2026). The words are the chat's book's, block by block (`MessageText.chatWords`). The bug that this catches:
/// the one store of read texts (`MessageText.blocks`) gives his bubble the agent's reading, so it shows a word that he
/// did not write, or gives an agent's reply his; a quote's "Atlas here" shows "Atlas · Marketing here", words that its
/// writer did not write; or each item of a list, or a heading and its paragraph, show the role again.
@MainActor @Test func hisWordsAndTheSameWordsOfAnAgentKeepTheirOwnReading() {
    let book = ChatNames(agents: [("atlas", "Marketing")])
    @MainActor func read(_ text: String, his: Bool = false) -> [ChatWords] {
        MessageText(text: text, chat: true, chatNames: book, asWritten: his).chatWords().compactMap { $0 }
    }
    @MainActor func drawn(_ text: String, his: Bool) -> String {
        read(text, his: his).map { String($0.text.characters) }.joined(separator: "\n")
    }
    let first = "I asked Marketing for the numbers, his words first."
    #expect(drawn(first, his: true) == first)
    #expect(drawn(first, his: false) == "I asked Atlas\u{00A0}·\u{00A0}Marketing for the numbers, his words first.")
    let then = "I asked Marketing for the numbers, an agent's words first."
    #expect(drawn(then, his: false) == "I asked Atlas\u{00A0}·\u{00A0}Marketing for the numbers, an agent's words first.")
    #expect(drawn(then, his: true) == then)
    let named = "Atlas wrote the numbers."
    #expect(drawn(named, his: false) == "Atlas\u{00A0}·\u{00A0}Marketing wrote the numbers.")
    #expect(drawn(named, his: true) == named)
    // a quote in an agent's reply: the name keeps its badge, with no role
    #expect(drawn("> Atlas here: the invoice is wrong.", his: false) == "Atlas here: the invoice is wrong.")
    #expect(drawn("Atlas here: the invoice is wrong.", his: false) == "Atlas\u{00A0}·\u{00A0}Marketing here: the invoice is wrong.")
    #expect(read("> Atlas here: the invoice is wrong.").map { $0.badges.map(\.target) } == [[.agent("atlas")]])
    #expect(drawn("- > Atlas here: the invoice is wrong.", his: false) == "> Atlas here: the invoice is wrong.")
    #expect(drawn("- >50% of the pages, by Atlas.", his: false) == ">50% of the pages, by Atlas\u{00A0}·\u{00A0}Marketing.")
    // the role once in a message: on the first item of a list, and in a heading and not in its paragraph
    #expect(drawn("- Atlas wrote it.\n- Atlas checked it.", his: false)
            == "Atlas\u{00A0}·\u{00A0}Marketing wrote it.\nAtlas checked it.")
    #expect(drawn("# Atlas wrote it\n\nThen I asked Marketing.", his: false)
            == "Atlas\u{00A0}·\u{00A0}Marketing wrote it\nThen I asked Atlas.")
}

/// **A quote in a request's words names an agent as Needs you does, in a chat's card too** (`MessageText.chatWords`; a
/// review of 26 November 2026): only the chat's book keeps a quote as written, and a request's card in a chat reads its
/// words with the card's book. The bug that this catches: a "> " quote in a request's reason draws "Marketing" in the
/// chat's card and "Wren · Marketing" on Needs you, against his rule "We should ALWAYS use the name".
@MainActor @Test func aQuoteInARequestsWordsDrawsTheAgentsNameOnEveryCard() {
    let team: [(name: String, role: String?)] = [("wren", "Marketing")]
    let book = CardNames(agents: team), roles = AgentNames.roles(team.map { ($0.name, $0.role) })
    let quote = "> I asked Marketing to check it."
    for card in [MessageText(text: quote, chat: true, card: true, names: book), MessageText(text: quote, step: true, names: book)] {
        let words = card.blocks.flatMap { CardBadgeText.pieces($0.formatted, names: book, roles: roles) }
            .map { String($0.words.characters) }
        #expect(words.contains("Wren · Marketing"), "the card names the agent: \(words)")
    }
}

/// **The role beside an agent's name in its badge is muted, and nothing else of the words is** (`mutedRole`; the owner's
/// answer of 23 November 2026: "The name with the role in grey"): an agent's words draw "Atlas" in the badge's colour
/// and " · Marketing" in the muted of an agent's line. The bug that this catches: the whole badge is one colour, or the
/// words around it turn grey too.
@MainActor @Test func theRoleBesideANameInItsBadgeIsMuted() {
    let words = ChatNames(agents: [("atlas", "Marketing")]).words(AttributedString("I asked Marketing.")).text.mutedRole()
    let muted = words.runs[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self]
        .compactMap { $0.0 == FleetStyle.muted ? String(words[$0.1].characters) : nil }
    #expect(muted == ["\u{00A0}·\u{00A0}Marketing"])
    #expect(words.runs[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self].filter { $0.0 != nil }.count == 1)
    #expect(String(words.characters) == "I asked Atlas\u{00A0}·\u{00A0}Marketing.")
}

/// **His typed answer to a request keeps a role as he wrote it, and an option that he pressed shows the agent's name
/// with its role** (`HisAnswer`; F23 N1): the folded card, "Your answer" and the row on Needs you draw his answer
/// through the card's names, and VoiceOver reads what they show. The bug that this catches: his words "I asked
/// Marketing." show "I asked Wren · Marketing.", words that he did not write, or VoiceOver reads the option's
/// "Marketing" where the card shows "Wren · Marketing", or a Markdown mark that the card does not show.
/// Or his `acme/shop` in inline code turns into a repository's badge, which is for the agent's words.
@MainActor @Test func hisTypedAnswerOnACardKeepsARoleAsHeWroteIt() throws {
    let team: [(name: String, role: String?)] = [("wren", "Marketing")]
    let book = CardNames(agents: team), roles = AgentNames.roles(team.map { ($0.name, $0.role) })
    let answer = "I asked Marketing."
    #expect(HisAnswer.spoken(answer, inWords: true, names: book, roles: roles) == answer)
    #expect(HisAnswer.spoken(answer, inWords: false, names: book, roles: roles) == "I asked Wren · Marketing.")
    #expect(HisAnswer.spoken("**Yes**, ask Marketing", inWords: false, names: nil) == "Yes, ask Marketing")
    // his words stay a badge of the agent, in his words
    let drawn = CardJoin.join(book.pieces(HisAnswer.words(answer, inWords: true)), roles: roles)
    #expect(drawn.map { String($0.words.characters) } == ["I asked ", "Marketing", "."])
    #expect(drawn.map(\.badge) == [nil, .agent("wren"), nil])
    // an answer in words that he did not write shows the agent's name: the hub's or an agent's end of the item
    // (`answered_by`), and the agent's recommended words that he pressed
    @MainActor func ended(_ more: [String: Any]) throws -> OwnerNeed {
        let row: [String: Any] = ["id": 5, "title": "Who runs the launch?", "why": "", "todo": "", "raised": 1,
                                  "by": "manager", "answer": answer, "answered": 2]
        return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(
            withJSONObject: row.merging(more) { $1 }))
    }
    #expect(HisAnswer.typed(try ended([:]), answer, inWords: true))
    #expect(!HisAnswer.typed(try ended(["answered_by": "Fleet"]), "Closed by the hub: Marketing left the fleet.",
                             inWords: true))
    #expect(!HisAnswer.typed(try ended(["recommended": "I asked Marketing. "]), answer, inWords: true))
    #expect(!HisAnswer.typed(try ended([:]), answer, inWords: false))
    // a repository in inline code is a badge in the agent's words (F9's rule b), and stays code in his typed words
    let shop = CardNames(agents: team, repositories: ["acme/shop"]), coded = "Deploy `acme/shop` now."
    #expect(CardBadgeText.pieces(MessageBlock.inline(coded), names: shop, roles: roles).map(\.badge)
            .contains(.repository("acme/shop")))
    #expect(CardBadgeText.pieces(HisAnswer.words(coded, inWords: true), names: shop, roles: roles)
            .allSatisfy { $0.badge == nil })
}

/// **A card's long reason, folded to its first lines, draws its names as the open card does** (`CardBadgeText.reason`;
/// S3 of the validation of F23 N1): Needs you's step and a chat's card read the names with the reason's line breaks,
/// and draw its words on one line, also a reason with no name, which is one `Text`. The bug that this catches: a
/// drawer joins the lines before the names are read, so "We asked\nMarketing spend rose." keeps "Marketing" on the
/// open card and shows "We asked Wren · Marketing spend rose." on the folded one; or it draws a line break, and the
/// three folded lines show less of the reason.
@Suite(.serialized, .timeLimit(.minutes(10))) struct FoldedReasonTests {
    @Test func aFoldedReasonDrawsItsNamesAsTheOpenCardDoes() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (named: [NSPoint?], plain: [NSPoint?]) in
            let team: [(name: String, role: String?)] = [("wren", "Marketing")]
            let roles = AgentNames.roles(team.map { ($0.name, $0.role) })
            @MainActor func window(_ why: String) -> NSWindow {
                let size = NSSize(width: 640, height: 140)
                let host = NSHostingView(rootView: CardBadgeText.reason(why, names: CardNames(agents: team),
                                                                        size: ChatStyle.size, roles: roles)
                    .font(ChatStyle.font).foregroundStyle(FleetStyle.text).lineLimit(3).padding(24)
                    .preferredColorScheme(.dark)
                    .frame(width: size.width, height: size.height, alignment: .topLeading).background(FleetStyle.canvas))
                host.sizingOptions = []
                return ViewHost.window(showing: host, size: size)
            }
            let named = window("We asked\nMarketing spend rose.")
            let first = [try ViewHost.middle(of: "We asked", in: named, seconds: 10),
                         try ViewHost.middle(of: "spend rose", in: named, seconds: 2),
                         try ViewHost.middle(of: "Wren", in: named, seconds: 0)]
            ViewHost.close(named)
            let plain = window("We asked\nthe whole team.")
            defer { ViewHost.close(plain) }
            return (first, [try ViewHost.middle(of: "We asked", in: plain, seconds: 10),
                            try ViewHost.middle(of: "whole team", in: plain, seconds: 2)])
        }
        let start = try #require(seen.named[0], "the folded reason is drawn")
        let end = try #require(seen.named[1], "the folded reason is drawn whole")
        #expect(abs(start.y - end.y) < 4, "the reason's two lines are drawn on one")
        #expect(seen.named[2] == nil, "a role at a line's start keeps its words, as on the open card")
        let plainStart = try #require(seen.plain[0], "a reason with no name is drawn")
        let plainEnd = try #require(seen.plain[1], "a reason with no name is drawn whole")
        #expect(abs(plainStart.y - plainEnd.y) < 4, "a reason with no name is drawn on one line too")
        #expect(screen.stayedHis)
    }
}

/// **The role beside an agent's name in a card's badge draws grey**, read from the window's picture (`CardBadgeText`,
/// `mutedRole`; the owner's answer F23-1 (b) of 23 November 2026, "The name with the role in grey", to a picture whose
/// role was grey). The bug that this catches: the role takes no grey, and draws in the words' white, or in the link's
/// violet. (A run with a link and its own colour draws its own colour: the role kept its grey with its link too, in
/// this test's run of 24 November 2026.)
@Suite(.serialized, .timeLimit(.minutes(10))) struct CardBadgeRoleLookTests {
    @Test func theRoleBesideANameInACardsBadgeDrawsGrey() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (name: Pixels?, role: Pixels?) in
            let team: [(name: String, role: String?)] = [("wren", "Marketing")]
            let size = NSSize(width: 640, height: 120)
            let words = CardBadgeText.text(AttributedString("I asked Marketing for the numbers."),
                                           names: CardNames(agents: team), size: ChatStyle.size,
                                           roles: AgentNames.roles(team.map { ($0.name, $0.role) }))
            let host = NSHostingView(rootView: words
                .font(ChatStyle.font).foregroundStyle(FleetStyle.text).tint(FleetStyle.link).padding(24)
                .preferredColorScheme(.dark)
                .frame(width: size.width, height: size.height, alignment: .topLeading).background(FleetStyle.canvas))
            host.sizingOptions = []
            let window = ViewHost.window(showing: host, size: size)
            defer { ViewHost.close(window) }
            guard let name = try ViewHost.middle(of: "Wren", in: window, seconds: 10),
                  let role = try ViewHost.middle(of: "Marketing", in: window, seconds: 2) else { return (nil, nil) }
            return (Self.colour(around: name, half: NSSize(width: 8, height: 4), in: window),
                    Self.colour(around: role, half: NSSize(width: 18, height: 4), in: window))
        }
        let name = try #require(seen.name, "the badge's name is drawn")
        let role = try #require(seen.role, "its role is drawn beside it")
        #expect(name.colour > 0.25, "the name draws in the link's violet")
        #expect(role.colour < name.colour / 2, "the role draws grey, not in the link's violet")
        #expect(role.light < 0.75, "the role draws in the muted grey (0.60), not in the words' white (0.90)")
        #expect(screen.stayedHis)
    }

    /// **His typed `acme/shop` stays code where a card draws his answer** (`CardBadgeText.text`, through `pieces`; the
    /// validation of F9, should 2), while the agent's same words draw the repository's badge in the link's violet. The
    /// bug that this catches: the drawer reads the names with no regard to his mark, so his code turns into a GitHub
    /// badge in the four places that draw his answer.
    @Test func hisTypedCodeOfARepositoryStaysCodeWhereTheCardDrawsIt() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (agent: Pixels?, his: Pixels?) in
            let book = CardNames(agents: [], repositories: ["acme/shop"])
            let size = NSSize(width: 640, height: 120)
            @MainActor func drawn(_ words: AttributedString) throws -> Pixels? {
                let text = CardBadgeText.text(words, names: book, size: ChatStyle.size, roles: [:])
                let host = NSHostingView(rootView: text
                    .font(ChatStyle.font).foregroundStyle(FleetStyle.text).tint(FleetStyle.link).padding(24)
                    .preferredColorScheme(.dark)
                    .frame(width: size.width, height: size.height, alignment: .topLeading).background(FleetStyle.canvas))
                host.sizingOptions = []
                let window = ViewHost.window(showing: host, size: size)
                defer { ViewHost.close(window) }
                // the text reader finds no "acme/shop" in the code font, so the box is the room between the plain
                // words around it, where the badge or the code stands (their own letters are the words' white)
                guard let start = try ViewHost.middle(of: "Deploy", in: window, seconds: 10),
                      let end = try ViewHost.middle(of: "now", in: window, seconds: 2), end.x > start.x + 40
                else { return nil }
                let middle = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                let half = NSSize(width: (end.x - start.x) / 2 - 10, height: 4)
                return Self.colour(around: middle, half: half, in: window)
            }
            let coded = "Deploy `acme/shop` now."
            return (try drawn(MessageBlock.inline(coded)), try drawn(HisAnswer.words(coded, inWords: true)))
        }
        let agent = try #require(seen.agent, "the agent's words are drawn")
        let his = try #require(seen.his, "his words are drawn")
        #expect(agent.colour > 0.25, "the agent's acme/shop is the repository's badge, in the link's violet")
        #expect(his.colour < agent.colour / 2, "his acme/shop stays code, not the badge's violet")
        #expect(screen.stayedHis)
    }

    /// The pixels of the window's picture in a box around a point, in sRGB: how colourful the most colourful one is
    /// (its largest channel less its smallest: the link's violet is 0.47, a grey and the window's ground nearly 0), and
    /// how light the lightest one is (its largest channel: the muted grey is 0.60, the words' white 0.90).
    struct Pixels: Sendable {
        var colour: CGFloat = 0
        var light: CGFloat = 0
    }

    /// `Pixels` of a box around `point` (the window's points, from its lower left corner, as `ViewHost.middle` gives
    /// them), `half` its half width and half height.
    @MainActor static func colour(around point: NSPoint, half: NSSize, in window: NSWindow) -> Pixels? {
        guard let view = window.contentView, let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: picture)
        let scale = CGFloat(picture.pixelsWide) / view.bounds.width
        let top = view.bounds.height - point.y
        let xs = max(0, Int((point.x - half.width) * scale))
            ... min(picture.pixelsWide - 1, Int((point.x + half.width) * scale))
        let ys = max(0, Int((top - half.height) * scale))...min(picture.pixelsHigh - 1, Int((top + half.height) * scale))
        var seen = Pixels()
        for x in xs {
            for y in ys {
                guard let pixel = picture.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let channels = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                seen.colour = max(seen.colour, (channels.max() ?? 0) - (channels.min() ?? 0))
                seen.light = max(seen.light, channels.max() ?? 0)
            }
        }
        return seen
    }
}
