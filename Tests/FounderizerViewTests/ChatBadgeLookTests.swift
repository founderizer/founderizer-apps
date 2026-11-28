import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **A chat's message looks the same at rest and under the pointer, and the name that begins a block has its icon**
/// (the owner, 25 November 2026, of a paragraph that began with "Iris": "hovering it changes the layout! and the agent
/// does not show his icon! I think we agreed that we should show both agent name and role? like in a nice card
/// badge?"). At rest a renderer draws a block's words (`ChatBadgeRenderer`); under the pointer the words can be selected
/// (`messageWordsSelectable`, which the chat's row under the pointer sets), with the badges on a canvas behind them.
/// The pictures are the window's, read as a person reads them. **The test's program is of a newer SDK than the app's**
/// (the app's says 15.0, the runner of the tests a newer one), so here SwiftUI draws selectable words in a view of its
/// own and makes no AppKit field (`SelectionTextField`), which the app makes: these tests read what both draw.
@Suite(.serialized, .timeLimit(.minutes(10))) struct ChatBadgeLookTests {
    /// The agents of the tests: example names, with roles.
    static let book = ChatNames(agents: [("iris", "SEO & AI Search"), ("leo", "Web Lead")])
    /// A paragraph of three lines that begins with an agent's name.
    static let paragraph = "Iris checked the twelve pages of the example site in both languages and wrote a list of what "
        + "to change on each one. Nothing is live yet. The next step is the page about prices, and nobody has sent its new "
        + "numbers, so that page stays as it is until somebody sends the numbers, and the other pages wait with it."
    /// A paragraph of about 200 characters that begins with a name and has a second one: the most usual message, which
    /// wraps, and which takes its wrapped form in `ViewThatFits` (`MessageText.badged`), where the no-break space before
    /// the words moves the second name by one character.
    static let short = "Leo's team finished the page about prices and the list of the twelve pages of the example site. "
        + "Iris read each one again, and both now wait for you to take them in."
    /// A block that begins with a name, of one line that is 10 points narrower than the column that it gets
    /// (`edgeWidth`): with the 20 points of its icon's room it wraps.
    static let edge = "Iris rewrote the guides of the example site and read them twice."
    /// A block of two lines with a line break between them, which begins with a name: its second line starts at the
    /// column's edge, as the lines of the blocks around it do.
    static let broken = "Iris rewrote the pages.\nLeo read them twice."
    /// Where the message's words begin in the window, from its top left.
    static let inset: CGFloat = 24

    /// The pointer on the message or not, as the chat's row gives it to the words (`ChatSelection`).
    @MainActor @Observable final class Pointer { var on = false }

    /// A message of the chat, an agent's (`AgentReply`'s words), in a window of the app's dark look, `width` points
    /// wide, with the pointer of `pointer`.
    @MainActor static func window(_ text: String, width: CGFloat, pointer: Pointer? = nil, units: Units? = nil) -> NSWindow {
        let size = NSSize(width: width + 2 * inset, height: 170)
        let host = NSHostingView(rootView: Message(text: text, pointer: pointer ?? Pointer())
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                let _ = units?.read(layouts)
                Color.clear
            }
            .frame(width: width, alignment: .topLeading).padding(inset).preferredColorScheme(.dark)
            .environment(\.glyphTeam, ["iris", "leo"])
            .frame(width: size.width, height: size.height, alignment: .topLeading).background(FleetStyle.canvas))
        host.sizingOptions = []
        return ViewHost.window(showing: host, size: size)
    }

    /// How many UTF-16 units each drawn text of a message holds: what a copy of its words takes.
    @MainActor final class Units {
        var counts: [Int] = []

        func read(_ layouts: Text.LayoutKey.Value) {
            counts = layouts.map { anchored in
                anchored.layout.flatMap { line in line.flatMap { run in run.characterIndices.map { unsafeBitCast($0, to: Int.self) } } }
                    .max().map { $0 + 1 } ?? 0
            }
        }
    }

    struct Message: View {
        let text: String
        let pointer: Pointer
        var body: some View {
            MessageText(text: text, chat: true, chatNames: ChatBadgeLookTests.book)
                .environment(\.messageWordsSelectable, pointer.on)
        }
    }

    /// **A paragraph that begins with a name keeps its lines under the pointer, and they end inside the column**
    /// (`ChatBadgeRenderer.displayPadding`): a long paragraph, the usual one of about 200 characters with a second name,
    /// a block whose one line is narrower than the column by less than its icon's room, and a block with a line break,
    /// whose second line starts at the column's edge (not 20 points in, as a block of one line with the room in its
    /// leading space would draw it).
    /// The bug that this catches: the renderer's padding at a side makes SwiftUI lay the words out wider than their
    /// frame, so at rest the lines go on past the column's edge, and when the pointer comes onto the message, where the
    /// field draws them, the last word of a line goes to the next (his picture: the last word of line 2 at rest was the
    /// first of line 3 under the pointer). The test waits until the hover took: the message's badges have their presses
    /// (`chatBadgeLayer`), which only the row under the pointer has.
    @Test func aParagraphThatBeginsWithANameKeepsItsLinesUnderThePointer() async throws {
        struct Pass: Sendable {
            let words: String, width: CGFloat, least: Int, rest: [CGRect], hover: [CGRect], pressesAtRest: Int, hovered: Bool
        }
        let (passes, screen) = try await ViewHost.onMainLoop(limit: 170) { () -> [Pass] in
            @MainActor func pass(_ text: String, _ word: String, width: CGFloat, least: Int) throws -> Pass {
                let pointer = Pointer()
                let window = Self.window(text, width: width, pointer: pointer)
                defer { ViewHost.close(window) }
                guard try ViewHost.middle(of: word, in: window, seconds: 10) != nil else {
                    throw ViewHost.Missing(description: "the message is not drawn")
                }
                let rest = try Self.picture(window).lines(), pressesAtRest = Self.presses(in: window.contentView!)
                pointer.on = true
                let hovered = ViewHost.turn(10) { Self.presses(in: window.contentView!) > 0 }
                // the lines under the pointer, once they are drawn as at rest (else, after 5 seconds, as they are), and
                // as they stay over the next frames
                var hover: [CGRect] = []
                ViewHost.turn(5) {
                    hover = (try? Self.picture(window).lines()) ?? []
                    return Self.same(hover, rest)
                }
                for _ in 0..<5 where Self.same(hover, rest) {
                    ViewHost.turn(0.03)
                    hover = try Self.picture(window).lines()
                }
                return Pass(words: word, width: width, least: least, rest: rest, hover: hover,
                            pressesAtRest: pressesAtRest, hovered: hovered)
            }
            var passes: [Pass] = []
            for width in [FleetStyle.readingWidth, 700, 620] {
                passes.append(try pass(Self.paragraph, "checked", width: width, least: 3))
                passes.append(try pass(Self.short, "finished", width: width, least: 2))
            }
            passes.append(try pass(Self.edge, "rewrote", width: Self.edgeWidth(), least: 2))
            passes.append(try pass(Self.broken, "pages", width: 700, least: 2))
            return passes
        }
        for pass in passes {
            let at = "\(pass.words) at \(pass.width)"
            #expect(pass.pressesAtRest == 0 && pass.hovered, "the pointer came onto the message, \(at)")
            #expect(pass.rest.count >= pass.least, "the block wraps, \(at): \(pass.rest)")
            #expect(pass.hover.count == pass.rest.count, "as many lines under the pointer, \(at): \(pass.hover)")
            #expect(pass.rest.allSatisfy { $0.maxX <= Self.inset + pass.width + 1 },
                    "each line at rest ends inside the column, \(at): \(pass.rest)")
            #expect(Self.same(pass.rest, pass.hover), "each line stays where it was, \(at): \(pass.rest) at rest, \(pass.hover)")
        }
        let edge = passes[passes.count - 2], broken = passes[passes.count - 1]
        #expect(edge.rest.count == 2, "the block 10 points narrower than its column wraps with its icon's room")
        // the room of the icon is on the first line only: the line after the break starts at the column's edge
        #expect(broken.rest.count == 2 && abs(broken.rest[1].minX - Self.inset) <= 2,
                "the line after a line break starts at the column's edge: \(broken.rest)")
        #expect(screen.stayedHis)
    }

    /// The same lines: as many, each within 2 points of the other's place.
    static func same(_ one: [CGRect], _ other: [CGRect]) -> Bool {
        one.count == other.count && zip(one, other).allSatisfy { a, b in
            abs(a.minX - b.minX) <= 2 && abs(a.maxX - b.maxX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.maxY - b.maxY) <= 2
        }
    }

    /// The width of the column that `edge` gets: the width of its words on one line, as the chat draws them, and 10
    /// points, less than its icon's room.
    @MainActor static func edgeWidth() -> CGFloat {
        let words = ChatBadgeText.text(book.words(MessageBlock.inline(edge)), links: false, size: ChatStyle.size)
        let host = NSHostingView(rootView: words.text.font(ChatStyle.font).fixedSize())
        return (host.fittingSize.width + 10).rounded(.up)
    }

    /// The presses of a message's badges in a view (`ChatBadgePress`), which only the row under the pointer has.
    @MainActor static func presses(in view: NSView) -> Int {
        view.subviews.reduce(String(reflecting: type(of: view)).contains("ChatBadgePress") ? 1 : 0) { $0 + presses(in: $1) }
    }

    /// **A block of one line that begins with a name holds its words exactly, so a copy of it does** (`ChatBadgeText.text`;
    /// the review of 21 November 2026: "\u{00A0}mini-2 restarts" in every copy): the text that the chat draws has no
    /// character before the name, and a block that wraps has the one no-break space of its icon's room. The bug that
    /// this catches: the room of the icon of a name that begins its block is a no-break space in a block of one line
    /// too, so a line that he copies and pastes begins with a space that he did not see. (The test reads the drawn
    /// text's layout: its program makes no AppKit field to read, as the type's comment says.)
    @Test func aBlockOfOneLineThatBeginsWithANameHoldsNoCharacterBeforeIt() async throws {
        let texts = ["Iris rewrote the guides.", Self.paragraph]
        let (counts, screen) = try await ViewHost.onMainLoop { () -> [[Int]] in
            try texts.map { text in
                let units = Units()
                let window = Self.window(text, width: 700, units: units)
                defer { ViewHost.close(window) }
                guard ViewHost.turn(10, until: { !units.counts.isEmpty }) else {
                    throw ViewHost.Missing(description: "the message's words are not drawn")
                }
                return units.counts
            }
        }
        let words = texts.map { String(Self.book.words(MessageBlock.inline($0)).text.characters).utf16.count }
        #expect(counts[0] == [words[0]], "the block of one line holds its words and nothing before them: \(counts[0])")
        #expect(counts[1] == [words[1] + 1], "the block that wraps holds the no-break space of its icon: \(counts[1])")
        #expect(screen.stayedHis)
    }

    /// **The name that begins a wrapped paragraph draws its icon, as the name of a block of one line does, and its role
    /// beside it in grey**, in a long paragraph and in the usual one of about 200 characters, whose second name has its
    /// icon too (`ChatBadgeText.text`'s no-break space before the words, which moves the second name by one character;
    /// `RoleNames.withRoles`). The bugs that this catches: a block that wraps draws its first name with no icon (the room
    /// in the words' leading space only for a block of one line), the name stands at the column's edge with the icon
    /// over it, the second name's badge stands one character off, or the role draws in the name's violet or is not there.
    @Test func aWrappedParagraphsFirstNameDrawsItsIconAndItsRoleInGrey() async throws {
        struct First: Sendable { let wrapped: NSPoint?, oneLine: NSPoint?, differ: Double, colourful: Int }
        struct Seen: Sendable {
            let firsts: [First], second: Int
            let name: CardBadgeRoleLookTests.Pixels?, role: CardBadgeRoleLookTests.Pixels?
        }
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 150) { () -> Seen in
            let width: CGFloat = 700, room = ChatBadgeText.room(ChatStyle.size)
            // the room of the icon of the name that begins the words
            let box = CGRect(x: Self.inset - 2, y: Self.inset - 3, width: room + 4, height: 23)
            @MainActor func first(_ text: String, _ line: String, _ name: String) throws -> First {
                let wrapped = Self.window(text, width: width)
                defer { ViewHost.close(wrapped) }
                let oneLine = Self.window(line, width: width)
                defer { ViewHost.close(oneLine) }
                let a = try ViewHost.middle(of: name, in: wrapped, seconds: 10)
                let b = try ViewHost.middle(of: name, in: oneLine, seconds: 10)
                let one = try Self.picture(wrapped), two = try Self.picture(oneLine)
                return First(wrapped: a, oneLine: b, differ: one.differs(from: two, in: box), colourful: one.colourful(in: box))
            }
            let firsts = [try first(Self.paragraph, "Iris rewrote the guides.", "Iris"),
                          try first(Self.short, "Leo checked the guides.", "Leo")]
            // the usual paragraph's second name, and the grey role of the long one's first
            let short = Self.window(Self.short, width: width)
            defer { ViewHost.close(short) }
            var second = 0
            if let iris = try ViewHost.middle(of: "Iris", in: short, seconds: 10) {
                let half = ("Iris" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: ChatStyle.size)]).width / 2
                let top = short.contentView!.bounds.height - iris.y
                second = try Self.picture(short).colourful(in: CGRect(x: iris.x - half - room, y: top - 8, width: room - 1,
                                                                      height: 16))
            }
            let long = Self.window(Self.paragraph, width: width)
            defer { ViewHost.close(long) }
            var name: CardBadgeRoleLookTests.Pixels?, role: CardBadgeRoleLookTests.Pixels?
            if let iris = try ViewHost.middle(of: "Iris", in: long, seconds: 10),
               let seo = try ViewHost.middle(of: "SEO", in: long, seconds: 2) {
                name = CardBadgeRoleLookTests.colour(around: iris, half: NSSize(width: 8, height: 4), in: long)
                role = CardBadgeRoleLookTests.colour(around: seo, half: NSSize(width: 8, height: 4), in: long)
            }
            return Seen(firsts: firsts, second: second, name: name, role: role)
        }
        for (index, first) in seen.firsts.enumerated() {
            let wrapped = try #require(first.wrapped, "the wrapped paragraph's name is drawn (\(index))")
            let oneLine = try #require(first.oneLine, "the one-line block's name is drawn (\(index))")
            // the left edge of the words is `inset`, and the icon's room is 20 points (`ChatBadgeText.room`)
            #expect(wrapped.x > Self.inset + 20, "the name stands after its icon's room (\(index)): its middle at \(wrapped.x)")
            #expect(abs(wrapped.x - oneLine.x) <= 2 && abs(wrapped.y - oneLine.y) <= 2,
                    "the name stands where a one-line block's stands (\(index)): \(wrapped), \(oneLine)")
            #expect(first.differ < 0.12, "the icon's room draws as a one-line block's (\(index)): \(first.differ) differ")
            #expect(first.colourful > 30, "the icon's room holds the agent's glyph (\(index)): \(first.colourful) pixels")
        }
        #expect(seen.second > 30, "the second name's icon stands before it: \(seen.second) coloured pixels")
        let name = try #require(seen.name, "the badge's name is drawn")
        let role = try #require(seen.role, "its role is drawn beside it")
        #expect(name.colour > 0.25, "the name draws in the link's violet")
        #expect(role.colour < name.colour / 2, "the role draws grey, not in the link's violet")
        #expect(role.light < 0.75 && role.light > 0.4, "the role draws in the muted grey, not in the words' white")
        #expect(screen.stayedHis)
    }

    /// The window's picture, or the test's step that cannot go on.
    @MainActor static func picture(_ window: NSWindow) throws -> Picture {
        guard let picture = Picture(window) else { throw ViewHost.Missing(description: "no picture of the window") }
        return picture
    }

    /// **The window's picture, read pixel by pixel** in its own points from its top left corner.
    struct Picture: Sendable {
        let width: Int
        let height: Int
        let scale: CGFloat
        private let bytes: [UInt8]
        private let perRow: Int
        private let perPixel: Int
        private let first: Int      // where red is in a pixel's bytes

        @MainActor init?(_ window: NSWindow) {
            guard let view = window.contentView else { return nil }
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: picture)
            guard picture.bitsPerSample == 8, !picture.isPlanar, let data = picture.bitmapData else { return nil }
            width = picture.pixelsWide
            height = picture.pixelsHigh
            scale = CGFloat(picture.pixelsWide) / view.bounds.width
            perRow = picture.bytesPerRow
            perPixel = picture.bitsPerPixel / 8
            first = picture.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            bytes = Array(UnsafeBufferPointer(start: data, count: perRow * height))
        }

        func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let at = y * perRow + x * perPixel + first
            return (Double(bytes[at]) / 255, Double(bytes[at + 1]) / 255, Double(bytes[at + 2]) / 255)
        }

        /// Words, a grey role or an icon: not the dark ground, a badge's fill or its faint edge.
        func ink(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return max(p.r, p.g, p.b) > 0.45
        }

        /// The pixels of `box` (points), clipped to the picture.
        private func pixels(_ box: CGRect) -> (xs: Range<Int>, ys: Range<Int>) {
            let xs = max(0, Int(box.minX * scale))..<min(width, Int(box.maxX * scale))
            let ys = max(0, Int(box.minY * scale))..<min(height, Int(box.maxY * scale))
            return (xs, ys)
        }

        /// The lines of words: each band of rows with ink, as its frame in points.
        func lines() -> [CGRect] {
            var lines: [CGRect] = [], band: (top: Int, left: Int, right: Int)?
            for y in 0..<height {
                var left = Int.max, right = -1
                for x in 0..<width where ink(x, y) {
                    left = min(left, x)
                    right = x
                }
                if right >= 0 {
                    band = band.map { (top: $0.top, left: min($0.left, left), right: max($0.right, right)) }
                        ?? (y, left, right)
                } else if let open = band {
                    lines.append(CGRect(x: CGFloat(open.left) / scale, y: CGFloat(open.top) / scale,
                                        width: CGFloat(open.right - open.left + 1) / scale,
                                        height: CGFloat(y - open.top) / scale))
                    band = nil
                }
            }
            return lines
        }

        /// The share of the pixels of `box` that differ from another picture's by more than 0.12 in a channel.
        func differs(from other: Picture, in box: CGRect) -> Double {
            let (xs, ys) = pixels(box)
            var differ = 0
            for y in ys {
                for x in xs {
                    let a = pixel(x, y), b = other.pixel(x, y)
                    if max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) > 0.12 { differ += 1 }
                }
            }
            return Double(differ) / Double(max(xs.count * ys.count, 1))
        }

        /// The pixels of `box` with a colour of their own (an agent's glyph, the link's violet), not grey.
        func colourful(in box: CGRect) -> Int {
            let (xs, ys) = pixels(box)
            var count = 0
            for y in ys {
                for x in xs {
                    let p = pixel(x, y)
                    if max(p.r, p.g, p.b) > 0.45, max(p.r, p.g, p.b) - min(p.r, p.g, p.b) > 0.2 { count += 1 }
                }
            }
            return count
        }
    }
}
