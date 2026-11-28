import AppKit
import FleetCore
import FleetMark
import SwiftUI
import Synchronization

/// **A name in a chat's message is a badge, as on a request's card** (the owner, 20 November 2026: "ok but use always
/// the agent badges and icons!!", and "Yes, as drawn" to the third mock-up): in an agent's reply (`AgentReply`) and his
/// own bubble (`OwnerBubble`), each name that the chat's book finds (`ChatNames`) is the card's badge (`CardBadge.draw`),
/// with the agent's glyph or the icon of what it names, and a press on it opens it with the hand.
///
/// **A chat is not lazy, so its badges must cost little at its opening, at a frame of its scroll and when the pointer
/// comes onto a message**:
/// - each block is one text of one attributed string, and the places of its badges go with it as values
///   (`ChatBadgeMap.Entry`): a join of a text for each part of the words took most of a chat's opening (a review of 21
///   November 2026);
/// - the text is the same in every row, so the pointer that comes onto a message or leaves it makes none of its texts
///   again: a text marked only in that row took 135-140 ms for a message of 31 blocks, 48-52 ms with no badges;
/// - a `TextRenderer` (`ChatBadgeRenderer`) draws the badges with the words, which a frame of a scroll does not do;
/// - in the row under the pointer or pressed last (`messageWordsSelectable`), each block with a badge gives the places
///   that the renderer found when it drew the words last (`ChatBadgeFound`) to one canvas of the card's behind the
///   message's words, which the app's SDK 15 field draws itself and never through a renderer, and one AppKit view with
///   the press of each badge (`ChatBadgeLayer`): no block reads its words' layout (`Text.LayoutKey`, which SwiftUI gives
///   again at each frame of a scroll: 1.0-1.3 ms of each frame over two long messages), but where the renderer's places
///   cannot be the words' (`ChatBadges.found`);
/// - **the renderer and the canvas are the two sides of one choice** (`ChatBadges`): no frame draws a badge twice.
enum ChatBadgeText {
    /// The width of the room before a name: a card's room, a no-break space with its kern (`CardBadgeText.slot`).
    @MainActor static func room(_ size: CGFloat) -> CGFloat {
        if let kept = rooms[size] { return kept }
        let space = ("\u{00A0}" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
        rooms[size] = size * CardBadgeText.slot + space
        return size * CardBadgeText.slot + space
    }
    @MainActor private static var rooms: [CGFloat: CGFloat] = [:]

    /// **A block's words with their names as badges**, as a card draws them (`CardBadgeText`) but for a copy of them,
    /// which holds the words as they show (`ChatWords.text`): the room of a name's icon is a kern on the
    /// character before it, and the end of its badge a kern on the character that `ChatWords.Badge.end` names. A link
    /// of the words' own is a part of its own (`LinkRun`, which `linkPresses` gives the hand); words with no name and no
    /// link are one plain text. `badges`: where the names stand, for their drawing (`chatBadges`).
    ///
    /// **A name that begins the words** (`ChatWords.Badge.leads`) has the room of its icon before them, in one of two
    /// forms of the block, which its width chooses (`MessageText.badged`): on one line their own leading space (`lead`),
    /// no character, so a copy holds the words exactly; where they wrap, a no-break space before them with a kern
    /// (`spaced`), as `MessageText.lead` gives room before a block's first words, so that only their first line has the
    /// room and the others keep the column of the blocks around them (the owner, 25 November 2026, of a paragraph that
    /// began with a name: "the agent does not show his icon!"). A copy of such a block from its start holds that space:
    /// the field that draws the words under the pointer lays out its own characters, and takes no room but theirs.
    @MainActor static func text(_ words: ChatWords, links: Bool, size: CGFloat) -> Words {
        guard !words.badges.isEmpty else {
            return Words(text: links ? CardBadgeText.text(words.text, names: nil, size: size) : Text(words.text))
        }
        guard words.badges.first?.leads == true else {
            let part = Self.part(words, links: links, size: size, spaced: false)
            return Words(text: part.text, badges: part.badges)
        }
        let spaced = Self.part(words, links: links, size: size, spaced: true)
        // a block that has a line break, or that no width of a chat holds on one line, takes no look at its one line
        if words.text.characters.count > Self.oneLineMost || words.text.characters.contains(where: \.isNewline) {
            return Words(text: spaced.text, badges: spaced.badges)
        }
        let part = Self.part(words, links: links, size: size, spaced: false)
        return Words(text: part.text, badges: part.badges, lead: room(size), spaced: spaced)
    }

    /// The most characters that a chat's column (`FleetStyle.readingWidth`) holds on one line: 780 points of the
    /// narrowest words. A block of more wraps at every width.
    static let oneLineMost = 240

    /// A block's words as a chat draws them, and where their names' badges stand.
    struct Part {
        let text: Text
        let badges: [ChatBadgeMap.Entry]
    }

    /// The forms of a block's words (`text(_:links:size:)`).
    struct Words {
        let text: Text
        var badges: [ChatBadgeMap.Entry] = []
        /// The words' own leading space, for the icon of a name that begins them, on one line; 0 for none.
        var lead: CGFloat = 0
        /// The words where they wrap, with a no-break space for that icon before them; nil where `text` is for every
        /// width.
        var spaced: Part?
    }

    /// The text of `words` with the kerns of their badges, and where these stand. `spaced`: a no-break space before
    /// the words holds the room of the icon of the name that begins them.
    @MainActor private static func part(_ words: ChatWords, links: Bool, size: CGFloat, spaced: Bool) -> Part {
        var text = Self.drawn(words.text)
        let width = room(size), end = size * CardBadgeText.end
        // the no-break space, its own width and a kern, is as wide as the room that the words' leading space would be
        let shift = spaced ? 1 : 0
        if spaced {
            var space = AttributedString("\u{00A0}")
            space.swiftUI.kern = size * CardBadgeText.slot
            text = space + text
        }
        func moved(_ range: Range<Int>) -> Range<Int> { range.lowerBound + shift..<range.upperBound + shift }
        func kern(at offset: Int, _ more: CGFloat) {
            let at = text.characters.index(text.startIndex, offsetBy: offset + shift)
            let next = text.characters.index(after: at)
            text[at..<next].swiftUI.kern = (text[at..<next].swiftUI.kern ?? 0) + more
        }
        for badge in words.badges {
            kern(at: badge.end, end)
            if badge.room { kern(at: badge.characters.lowerBound - 1, width) }
        }
        // the characters, only where a badge ends on the character after its name (a line written right to left)
        let characters = words.badges.contains(where: \.endAfter) ? Array(words.text.characters) : []
        let badges = words.badges.map {
            ChatBadgeMap.Entry(index: $0.index, target: $0.target, utf16: moved($0.utf16),
                               room: $0.room || $0.leads ? width : nil,
                               before: spaced && $0.leads ? 0..<1 : moved($0.before), leads: $0.leads && !spaced,
                               endAfter: $0.endAfter ? end : 0, endSpace: $0.endAfter && characters[$0.end].isWhitespace)
        }
        guard links else { return Part(text: Text(text), badges: badges) }
        // the links of the words' own: each a part with its mark, all joined in one key
        var parts: [Text] = [], index = 0
        for (url, range) in text.runs[\.link] {
            let part = Text(AttributedString(text[range]))
            let start = text.characters.distance(from: text.startIndex, to: range.lowerBound)
            let own = url.map { _ in !words.badges.contains { $0.characters.contains(start - shift) } } ?? false
            if own, let url {
                parts.append(part.customAttribute(LinkRun(index: index, url: url)))
                index += 1
            } else {
                parts.append(part)
            }
        }
        var joined = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: parts.count)
        for part in parts { joined.appendInterpolation(part) }
        return Part(text: Text(LocalizedStringKey(stringInterpolation: joined)), badges: badges)
    }

    /// **A block's words as its badges draw them**: the role beside an agent's name muted (`mutedRole`), and no part of
    /// the name's link, as in a card's badge (`CardBadgeText`): one link for one name, for the keyboard and VoiceOver, and
    /// the role apart from the name as his approved picture has it. (A run with its own colour keeps that colour with or
    /// without a link: measured with ImageRenderer and in an NSHostingView, 24 November 2026.) The badge's press is its
    /// own, by the badge's place (`chatBadgeLayer`), and the name keeps its link.
    static func drawn(_ text: AttributedString) -> AttributedString {
        var text = text.mutedRole()
        for (mark, range) in text.runs[RoleNames.RolePart.self] where mark == true { text[range].link = nil }
        return text
    }
}

extension AttributedString {
    /// **The role beside an agent's name in its badge is muted** (`RoleNames.RolePart`; the owner's answer of 23 November
    /// 2026: "The name with the role in grey"), in the muted of the line of an agent's name (`AgentNameLine`): "Wren"
    /// keeps the badge's colour, and " · Marketing" is grey. A card's words take it too (`CardBadgeText`).
    func mutedRole() -> AttributedString {
        var words = self
        for (mark, range) in words.runs[RoleNames.RolePart.self] where mark == true {
            words[range].swiftUI.foregroundColor = FleetStyle.muted
        }
        return words
    }
}

/// **Where the badges of one text stand**: in its words (`Entry`, made with the text), and on each line of its layout.
enum ChatBadgeMap {
    struct Entry: Hashable, Sendable {
        let index: Int
        let target: CardNames.Target
        /// Its name in the words' UTF-16 units, as a layout counts its characters.
        let utf16: Range<Int>
        /// The width of its icon's room: a kern on the character before it (the no-break space before words that wrap
        /// is one, `ChatBadgeText.Words.spaced`), or the words' leading space (`leads`); nil where a line break of the
        /// words begins with it.
        let room: CGFloat?
        /// The character before it, in all its UTF-16 units (`ChatWords.Badge.before`).
        var before: Range<Int> = 0..<0
        /// It begins the words, and its room is their leading space, before their one line (`ChatBadgeText.Words.lead`).
        let leads: Bool
        /// The width of its badge's end beside its name, a kern on the character after it (`ChatWords.Badge.endAfter`);
        /// 0 where the end is a kern of the name's own, inside its frame.
        let endAfter: CGFloat
        /// That character is a space, where a line can break: a line that ends with it hangs it past its edge.
        var endSpace = false
    }

    /// The badge of `run`, among `entries`: its first character's offset in the words (a layout's
    /// `Text.Layout.CharacterIndex`, one Int) stands in the badge's name.
    static func entry(of run: Text.Layout.Run, in entries: [Entry]) -> Entry? {
        guard let first = run.characterIndices.first else { return nil }
        let offset = unsafeBitCast(first, to: Int.self)
        return entries.first { $0.utf16.contains(offset) }
    }

    /// The badges of one line of a text's layout, in their order: each one's frame on the line, 6% of the line over
    /// and under it, and the room of its icon, moved by `offset`. `entries` are the text's badges. **The room is where
    /// the layout put the kerned character before the name**, on this line: left of the name in a line left to right,
    /// right of it in one right to left ("שאלתי את Nova", a review of 21 November 2026: the icon stood on the next
    /// word); a name whose character before it is on another line has none. A name that begins the words has its room
    /// before the line, in their leading space (`Entry.leads`), where they have it (`leading`). **The end of a badge whose kern is on the character after the name** (`Entry.endAfter`) is on
    /// the side where the layout put that character on this line ("שלום, I asked Nova": on its right), and nowhere
    /// where the line breaks at it: the space at a line's end hangs past the line's edge (a review of 21 November 2026).
    static func badges(of line: Text.Layout.Line, entries: [Entry], offset: CGPoint, leading: Bool)
        -> [(entry: Entry, frame: CGRect, room: CGRect?)] {
        var order: [Entry] = [], frames: [Int: CGRect] = [:], firsts: Set<Int> = []
        // the glyphs on this line of the character before a name (its room) and after it (its end), by their offset
        var before: [Int: Entry] = [:], after: [Int: Entry] = [:], gaps: [Int: CGRect] = [:], ends: [Int: CGRect] = [:]
        var last = -1       // the line's last character
        for entry in entries {
            if entry.room != nil && !entry.leads {
                for at in entry.before { before[at] = entry }
            }
            if entry.endAfter > 0 { after[entry.utf16.upperBound] = entry }
        }
        for run in line {
            // a run right to left gives its characters from the last
            if !after.isEmpty, let end = run.characterIndices.lazy.map({ unsafeBitCast($0, to: Int.self) }).max() {
                last = max(last, end)
            }
            guard let entry = Self.entry(of: run, in: entries) else {
                guard !before.isEmpty || !after.isEmpty else { continue }
                for glyph in run {
                    for index in glyph.characterIndices {
                        let at = unsafeBitCast(index, to: Int.self)
                        let box = glyph.typographicBounds.rect.offsetBy(dx: offset.x, dy: offset.y)
                        if let owner = before[at] { gaps[owner.index] = gaps[owner.index]?.union(box) ?? box }
                        if let owner = after[at] { ends[owner.index] = ends[owner.index]?.union(box) ?? box }
                    }
                }
                continue
            }
            let frame = run.typographicBounds.rect.offsetBy(dx: offset.x, dy: offset.y)
            if let kept = frames[entry.index] { frames[entry.index] = kept.union(frame) } else {
                order.append(entry)
                frames[entry.index] = frame
            }
            if run.characterIndices.contains(where: { unsafeBitCast($0, to: Int.self) == entry.utf16.lowerBound }) {
                firsts.insert(entry.index)
            }
        }
        return order.compactMap { entry in
            guard let name = frames[entry.index] else { return nil }
            var frame = name, room: CGRect?
            if let width = entry.room {
                if entry.leads {
                    if leading, firsts.contains(entry.index) {
                        room = CGRect(x: name.minX - width, y: name.minY, width: width, height: name.height)
                    }
                } else if let gap = gaps[entry.index] {
                    let right = gap.minX >= name.maxX - 0.5
                    room = CGRect(x: right ? name.maxX : name.minX - width, y: name.minY, width: width, height: name.height)
                }
                if let room { frame = frame.union(room) }
            }
            if entry.endAfter > 0, let end = ends[entry.index], !(entry.endSpace && last == entry.utf16.upperBound) {
                let right = end.minX >= name.maxX - 0.5
                frame = frame.union(CGRect(x: right ? name.maxX : name.minX - entry.endAfter, y: name.minY,
                                           width: entry.endAfter, height: name.height))
            }
            return (entry, frame.insetBy(dx: 0, dy: -frame.height * 0.06), room)
        }
    }
}

/// What a chat's badge shows before its name, made where the window's team is read, as the values that a renderer,
/// which holds no view, draws.
struct ChatBadgeIcon: Equatable {
    /// The image of a mark that the card draws as a view of its own (`CardBadgeIcon.isMark`): the GitHub mark, in the
    /// link's colour, or a Google service's mark in its own colours.
    struct Mark: Equatable {
        let name: String
        let image: Image
        let size: CGSize
        let tinted: Bool

        static func == (lhs: Mark, rhs: Mark) -> Bool { lhs.name == rhs.name }
    }

    let room: CardBadge.Room
    var mark: Mark?

    /// The icon of a badge, as the card shows it (`CardBadgeIcon.of`), with the agent's look and presence of now.
    @MainActor static func of(_ target: CardNames.Target, team: [String], presences: [String: AgentPresence],
                              servers: [String: String]) -> ChatBadgeIcon {
        switch CardBadgeIcon.of(target, servers: servers) {
        case .glyph(let name):
            return ChatBadgeIcon(room: .agent(GlyphTeams.look(of: name, in: team),
                                              absent: presences[name] == .offline || presences[name] == .unknown))
        case .symbol(let name):
            return ChatBadgeIcon(room: .symbol(name))
        case .skill:
            return ChatBadgeIcon(room: .symbol(CardBadgeIcon.skillSymbol))
        case .github:
            return ChatBadgeIcon(room: .mark, mark: Mark(name: "github", image: Image(nsImage: GitHubMark.image)
                .renderingMode(.template).interpolation(.high), size: GitHubMark.image.size, tinted: true))
        case .service(let service):
            let image = service == .gmail ? ServiceMark.gmail : ServiceMark.drive
            return ChatBadgeIcon(room: .mark, mark: Mark(name: service.rawValue, image: Image(nsImage: image)
                .renderingMode(.original).interpolation(.high), size: image.size, tinted: false))
        }
    }

    /// The icons of `targets`, by what they open.
    @MainActor static func of(_ targets: some Sequence<CardNames.Target>, team: [String],
                              presences: [String: AgentPresence], servers: [String: String]) -> [CardNames.Target: Self] {
        var icons: [CardNames.Target: Self] = [:]
        for target in targets where icons[target] == nil {
            icons[target] = of(target, team: team, presences: presences, servers: servers)
        }
        return icons
    }

    /// What one drawing of badges resolved: the symbols that each badge of the same symbol draws again.
    struct Drawn {
        var symbols: [String: GraphicsContext.ResolvedText] = [:]
    }

    /// The badge in `frame`, with this icon in the room of `room`'s line, as the card draws it (`CardBadge.draw`); an
    /// agent's glyph from its kept paths (`ChatGlyph`), and a symbol resolved once in a drawing (`drawn`).
    func draw(_ frame: CGRect, room: CGRect?, over: Bool, in context: inout GraphicsContext, drawn: inout Drawn) {
        let place = room.map { CardBadge.icon(room: $0, frame: frame) }
        switch self.room {
        case .glyph(let kind, let light, let deep):
            CardBadge.draw(frame, over: over, room: .mark, at: place, in: &context) { context, place in
                ChatGlyph.draw(kind, light: light, deep: deep, in: place, context: &context)
            }
        case .symbol(let name):
            CardBadge.draw(frame, over: over, room: .mark, at: place, in: &context) { context, place in
                // as the card draws it (`CardBadge.draw`)
                let size = place.width * 0.86, key = "\(name) \(size)"
                let symbol = drawn.symbols[key] ?? context.resolve(Text(Image(systemName: name))
                    .font(.system(size: size, weight: .medium)).foregroundColor(FleetStyle.link))
                drawn.symbols[key] = symbol
                context.draw(symbol, at: CGPoint(x: place.midX, y: place.midY), anchor: .center)
            }
        case .mark:
            CardBadge.draw(frame, over: over, room: .mark, at: place, in: &context) { context, place in
                guard let mark else { return }
                // as the mark's view draws it: whole and centred in the icon's place
                let scale = min(place.width / max(mark.size.width, 1), place.height / max(mark.size.height, 1))
                let size = CGSize(width: mark.size.width * scale, height: mark.size.height * scale)
                let rect = CGRect(x: place.midX - size.width / 2, y: place.midY - size.height / 2, width: size.width,
                                  height: size.height)
                guard mark.tinted else { return context.draw(mark.image, in: rect) }
                // the GitHub mark in the link's colour, as the card's view draws it: a resolved image's shading left it
                // white, so the mark is the mask of the colour
                context.drawLayer { layer in
                    layer.clipToLayer { mask in mask.draw(mark.image, in: rect) }
                    layer.fill(Path(rect), with: .color(FleetStyle.link))
                }
            }
        }
    }
}

/// **An agent's glyph in a chat's badge**, drawn as a card draws it (`CardBadge.draw`), from its outline and core made
/// once for each kind: making them, where the lobes and the moon join and cut paths, took two thirds of the drawing of
/// a message of 150 badges (4.3 of 6.6 ms, a debug build, 21 November 2026).
enum ChatGlyph {
    /// The side of the square that the kept paths fill.
    private static let side: CGFloat = 100
    private static let kept = Mutex<[GlyphKind: (outline: Path, core: Path)]>([:])

    static func draw(_ kind: GlyphKind, light: Color, deep: Color, in place: CGRect, context: inout GraphicsContext) {
        let paths = kept.withLock { kept in
            if let paths = kept[kind] { return paths }
            let square = CGRect(x: 0, y: 0, width: side, height: side)
            let paths = (outline: GlyphOutline(kind: kind).path(in: square), core: GlyphCore(kind: kind).path(in: square))
            kept[kind] = paths
            return paths
        }
        // the shapes stand in the square in the middle of their place
        let scale = min(place.width, place.height) / side
        let move = CGAffineTransform(translationX: place.midX - side * scale / 2, y: place.midY - side * scale / 2)
            .scaledBy(x: scale, y: scale)
        context.fill(paths.outline.applying(move),
                     with: .linearGradient(Gradient(colors: [light, deep]), startPoint: place.origin,
                                           endPoint: CGPoint(x: place.maxX, y: place.maxY)))
        context.fill(paths.core.applying(move), with: .color(kind == .moon ? light : .white.opacity(GlyphLook.coreOpacity)))
    }
}

/// **The badges of a chat's words, drawn with the words** (`chatBadges`): SwiftUI calls it when it draws the text, never
/// at a frame of a scroll that only moves the text.
private struct ChatBadgeRenderer: TextRenderer {
    /// The text's badges (`ChatBadgeText`).
    let badges: [ChatBadgeMap.Entry]
    /// The block's place in its message (`ChatBadgePart.badge`).
    let block: Int
    /// The words' leading space, where a name that begins them has its icon (`ChatBadgeText.Words.lead`): left of the
    /// text, and 0 where the words wrap.
    let lead: CGFloat
    /// What each badge shows before its name, by what it opens.
    let icons: [CardNames.Target: ChatBadgeIcon]
    /// Where it drew them, in the places of the block's text, for the row under the pointer (`ChatBadges`).
    let found: ChatBadgeFound

    /// A badge reaches over its words' first line and under their last (`CardBadge.bleed`), and the icon of a name that
    /// begins words of one line into their leading space. **Never past the sides of words that wrap: SwiftUI lays the
    /// words out in their width and a padding at a side** (a bubble's words, whose edge then cut them, off screen, 21
    /// November 2026). A block that began with a name had the padding of its icon's room, 20.3 points, also where it
    /// wraps, so at rest its lines went past the column's edge, and under the pointer, where the field draws the words in
    /// their own width, they broke elsewhere (the owner, 25 November 2026: "hovering it changes the layout!"; measured on
    /// 26 November 2026 in the app's own program, of SDK 15, and in the tests' program: the first line of a paragraph in
    /// a column of 780 points ended at 795 points with that padding, and at 775.5 with none and in the field).
    var displayPadding: EdgeInsets { EdgeInsets(top: CardBadge.bleed, leading: lead, bottom: CardBadge.bleed, trailing: 0) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var drawn = ChatBadgeIcon.Drawn(), parts: [ChatBadgePart] = []
        for line in layout {
            for badge in ChatBadgeMap.badges(of: line, entries: badges, offset: .zero, leading: lead > 0) {
                if let icon = icons[badge.entry.target] {
                    icon.draw(badge.frame, room: badge.room, over: false, in: &context, drawn: &drawn)
                } else {
                    CardBadge.draw(badge.frame, over: false, room: nil, at: nil, in: &context) { _, _ in }
                }
                parts.append(ChatBadgePart(block: block, badge: badge))
            }
            context.draw(line)
        }
        found.keep(parts, of: badges)
    }
}

extension View {
    /// **The badges of the names of one block of a chat's message** (`MessageText.badged`; `badges` and `lead` from
    /// `ChatBadgeText`; `block`, the block's place in the message): drawn with its words by a renderer, and in the row
    /// under the pointer or pressed last, where a field of the selection draws the words (`messageWordsSelectable`),
    /// given where the renderer drew them to the message's canvas and presses (`chatBadgeLayer`). `fold` is where a
    /// fold cuts the message's words (`MessageText.fold`): folded words have no field, so the renderer draws their
    /// badges there too.
    func chatBadges(_ badges: [ChatBadgeMap.Entry], block: Int, lead: CGFloat, fold: CGFloat?) -> some View {
        modifier(ChatBadges(badges: badges, block: block, lead: lead, fold: fold))
    }

    /// **The canvas behind a chat's message's badges and the AppKit view with their presses**, one of each for the whole
    /// message, from the badges that its blocks found in the row under the pointer (`chatBadges`); nothing elsewhere.
    /// `on`: the message is a chat's (`MessageText.chatNames`). `fold`: where its fold cuts its words.
    func chatBadgeLayer(_ on: Bool, fold: CGFloat?) -> some View { modifier(ChatBadgeLayer(on: on, fold: fold)) }

}

extension EnvironmentValues {
    /// The chat's row of a message is under the pointer or was pressed last (`messageWordsSelectable` around the
    /// message), also where its fold keeps its words from a field (`MessageText.fold`): its badges have their presses.
    @Entry var messageRowLive = true
}

/// **One block's badges, drawn by the renderer or found for the canvas, never both**: SwiftUI takes one side of the
/// choice in one update, and the canvas draws only what the blocks on the other side give, in the same update, so no
/// frame shows the badges of the text that was drawn and those of the canvas that comes (a review of 21 November 2026).
/// The words' text is the same on both sides. Under a fold, the renderer draws them and the canvas only adds the
/// pointer's.
private struct ChatBadges: ViewModifier {
    let badges: [ChatBadgeMap.Entry]
    let block: Int
    let lead: CGFloat
    let fold: CGFloat?
    /// The words can be selected now: AppKit's field draws them, with the canvas behind for their badges, and they take
    /// no renderer, which a newer SDK's field would call to draw each badge a second time.
    @Environment(\.messageWordsSelectable) private var selectable
    @Environment(\.messageRowLive) private var rowLive
    @Environment(\.glyphTeam) private var team
    @Environment(\.glyphPresence) private var presences
    @Environment(\.cardServerSymbols) private var servers
    /// Where the renderer drew the badges last (`ChatBadgeFound`), kept while the pointer comes and goes.
    @State private var drawn = ChatBadgeFound()
    /// The words' width changed while the row was under the pointer, where no renderer draws them: the places that it
    /// found are not theirs any more.
    @State private var moved = false

    func body(content: Content) -> some View {
        if badges.isEmpty {
            content
        } else if selectable {
            content.background(alignment: .topLeading) { found(content) }.onDisappear { moved = false }
        } else {
            let renderer = ChatBadgeRenderer(badges: badges, block: block, lead: lead, icons: ChatBadgeIcon.of(
                badges.map(\.target), team: team, presences: presences, servers: servers), found: drawn)
            if rowLive && fold != nil {
                content.textRenderer(renderer).background(alignment: .topLeading) { found(content) }
                    .onDisappear { moved = false }
            } else {
                content.textRenderer(renderer)
            }
        }
    }

    /// **Where the block's badges stand, for the message's canvas and presses** (`ChatBadgeSpots`): the places that the
    /// renderer drew them in, which a frame of a scroll leaves as they are. Where there are none for these words (the
    /// row came under the pointer before its words were drawn, its words changed, or its width changed since), a hidden
    /// copy of the words finds them in its layout.
    @ViewBuilder private func found(_ words: Content) -> some View {
        if !moved, let parts = drawn.parts(of: badges) {
            Color.clear
                .anchorPreference(key: ChatBadgeSpots.self, value: .topLeading) { [ChatBadgeSpots.Block(origin: $0, parts: parts)] }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { old, new in if old != new { moved = true } }
        } else {
            words.environment(\.messageWordsSelectable, false).hidden()
                .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { proxy in
                        let parts = layouts.flatMap { anchored in
                            let origin = proxy[anchored.origin]
                            return anchored.layout.flatMap { line in
                                ChatBadgeMap.badges(of: line, entries: badges, offset: origin, leading: lead > 0).map {
                                    ChatBadgePart(block: block, badge: $0)
                                }
                            }
                        }
                        Color.clear.anchorPreference(key: ChatBadgeSpots.self, value: .topLeading) {
                            [ChatBadgeSpots.Block(origin: $0, parts: parts)]
                        }
                    }
                }
                // the copy's layout is for these badges alone: a link's press (`linkPresses`) reads the words' own
                .transformPreference(Text.LayoutKey.self) { $0 = [] }
        }
    }
}

/// **Where a block's renderer drew its badges last**, in its text's own places, for the row under the pointer, where
/// the field draws the words and no renderer does. SwiftUI may draw on another thread than the views'.
final class ChatBadgeFound: Sendable {
    private let kept = Mutex<(entries: [ChatBadgeMap.Entry], parts: [ChatBadgePart])?>(nil)

    fileprivate func keep(_ parts: [ChatBadgePart], of entries: [ChatBadgeMap.Entry]) {
        kept.withLock { $0 = (entries, parts) }
    }

    /// The places of the badges of `entries`, where the renderer drew these.
    fileprivate func parts(of entries: [ChatBadgeMap.Entry]) -> [ChatBadgePart]? {
        kept.withLock { $0.flatMap { $0.entries == entries ? $0.parts : nil } }
    }
}

/// The badges that the blocks of a message give (`ChatBadges`), each block's from its top left.
private struct ChatBadgeSpots: PreferenceKey {
    struct Block {
        let origin: Anchor<CGPoint>
        let parts: [ChatBadgePart]
    }

    /// A block's badges and where its top left stands in the view of the message's canvas and presses. Two are equal
    /// at a frame of a scroll, which moves neither, at the cost of their origins: the badges are the same array.
    struct Placed: Equatable {
        let origin: CGPoint
        let parts: [ChatBadgePart]
    }

    static var defaultValue: [Block] { [] }
    static func reduce(value: inout [Block], nextValue: () -> [Block]) { value += nextValue() }

    static func placed(_ blocks: [Block], in proxy: GeometryProxy) -> [Placed] {
        blocks.map { Placed(origin: proxy[$0.origin], parts: $0.parts) }
    }

    /// The badges of `blocks`, each moved to its place.
    static func parts(_ blocks: [Placed]) -> [ChatBadgePart] {
        blocks.flatMap { block in block.parts.map { $0.moved(by: block.origin) } }
    }
}

/// One badge on one line of a message.
private struct ChatBadgePart: Equatable, Sendable {
    /// The block's place in the message and the badge's in the block, which all lines of one badge share.
    let badge: String
    let target: CardNames.Target
    let frame: CGRect
    let room: CGRect?

    init(badge: String, target: CardNames.Target, frame: CGRect, room: CGRect?) {
        self.badge = badge
        self.target = target
        self.frame = frame
        self.room = room
    }

    init(block: Int, badge: (entry: ChatBadgeMap.Entry, frame: CGRect, room: CGRect?)) {
        self.init(badge: "\(block)-\(badge.entry.index)", target: badge.entry.target, frame: badge.frame, room: badge.room)
    }

    func moved(by offset: CGPoint) -> ChatBadgePart {
        ChatBadgePart(badge: badge, target: target, frame: frame.offsetBy(dx: offset.x, dy: offset.y),
                      room: room?.offsetBy(dx: offset.x, dy: offset.y))
    }
}

private struct ChatBadgeLayer: ViewModifier {
    let on: Bool
    let fold: CGFloat?
    /// The badge under the pointer (`ChatBadgePart.badge`).
    @State private var hovered: String?
    @Environment(\.openURL) private var openURL
    @Environment(\.glyphTeam) private var team
    @Environment(\.glyphPresence) private var presences
    @Environment(\.cardServerSymbols) private var servers

    func body(content: Content) -> some View {
        if on {
            content
                .backgroundPreferenceValue(ChatBadgeSpots.self) { blocks in
                    if !blocks.isEmpty {
                        GeometryReader { proxy in
                            ChatBadgeCanvas(blocks: ChatBadgeSpots.placed(blocks, in: proxy), team: team, presences: presences,
                                            servers: servers, hovered: hovered, folded: fold != nil).equatable()
                        }
                    }
                }
                .overlayPreferenceValue(ChatBadgeSpots.self) { blocks in
                    if !blocks.isEmpty {
                        GeometryReader { proxy in
                            ChatBadgePress(blocks: ChatBadgeSpots.placed(blocks, in: proxy), cut: fold, open: { openURL($0) },
                                           hover: { hovered = $0 }).equatable()
                        }
                        // the names keep their links for the keyboard and VoiceOver, as a card's press (`LinkPresses`)
                        .accessibilityHidden(true)
                        // a press that goes takes its hover with it: the pointer may have left the badge
                        .onDisappear { hovered = nil }
                    }
                }
        } else {
            content
        }
    }
}

/// **The card's canvas behind a message's badges** (`CardBadges`), drawn again only when its badges move within the
/// message or the pointer comes onto one: a frame of the chat's scroll gives it the same badges. Folded words have no
/// field: the renderer draws their badges, and the canvas only adds to the one under the pointer, so that it fills as
/// much as a card's.
private struct ChatBadgeCanvas: View, Equatable {
    let blocks: [ChatBadgeSpots.Placed]
    let team: [String]
    let presences: [String: AgentPresence]
    let servers: [String: String]
    let hovered: String?
    let folded: Bool

    nonisolated static func == (lhs: ChatBadgeCanvas, rhs: ChatBadgeCanvas) -> Bool {
        lhs.blocks == rhs.blocks && lhs.team == rhs.team && lhs.presences == rhs.presences && lhs.servers == rhs.servers
            && lhs.hovered == rhs.hovered && lhs.folded == rhs.folded
    }

    var body: some View {
        let parts = ChatBadgeSpots.parts(blocks)
        let icons = ChatBadgeIcon.of(parts.map(\.target), team: team, presences: presences, servers: servers)
        Canvas { context, _ in
            context.translateBy(x: CardBadge.bleed, y: CardBadge.bleed)     // the message's own places
            var drawn = ChatBadgeIcon.Drawn()
            for part in parts {
                let over = hovered == part.badge
                if folded {
                    // under the renderer's own fill and edge: together they are a card's under the pointer
                    guard over else { continue }
                    let shape = RoundedRectangle(cornerRadius: part.frame.height / 1.3 * 0.36, style: .continuous)
                    context.fill(shape.path(in: part.frame), with: .color(FleetStyle.link.opacity(0.09)))
                    context.stroke(shape.path(in: part.frame.insetBy(dx: 0.5, dy: 0.5)),
                                   with: .color(FleetStyle.link.opacity(0.29)), lineWidth: 1)
                } else if let icon = icons[part.target] {
                    icon.draw(part.frame, room: part.room, over: over, in: &context, drawn: &drawn)
                }
            }
        }
        .padding(-CardBadge.bleed)
    }
}

/// **One AppKit view with the press of every badge of a message**: the hand over each badge, as a card's press
/// (`BadgePress`), a press that opens it, and the pointer's badge for its fill. Anywhere else the view is not there, so
/// a press selects the words below. A frame of a scroll gives it the same badges, and AppKit nothing to do; one view
/// for each badge took 3 ms of each frame for 160 badges, and one for each block 7 ms of a hover onto a long message.
private struct ChatBadgePress: NSViewRepresentable, Equatable {
    struct Spot: Equatable {
        let badge: String
        let frame: CGRect
        let url: URL?
    }

    let blocks: [ChatBadgeSpots.Placed]
    /// Where a fold cuts the words: no press stands under it (`LinkPresses.shown`).
    let cut: CGFloat?
    let open: (URL) -> Void
    /// The pointer came onto a badge, or left every badge (nil).
    let hover: (String?) -> Void

    nonisolated static func == (lhs: ChatBadgePress, rhs: ChatBadgePress) -> Bool {
        lhs.blocks == rhs.blocks && lhs.cut == rhs.cut
    }

    func makeNSView(context: Context) -> PressView { PressView() }

    func updateNSView(_ view: PressView, context: Context) {
        view.open = open
        view.hover = hover
        let spots = ChatBadgeSpots.parts(blocks).compactMap { part in
            LinkPresses.shown(part.frame, above: cut).map { Spot(badge: part.badge, frame: $0, url: part.target.url) }
        }
        if view.spots != spots {
            view.spots = spots
            view.window?.invalidateCursorRects(for: view)
        }
    }

    final class PressView: NSView {
        var spots: [Spot] = []
        var open: (URL) -> Void = { _ in }
        var hover: (String?) -> Void = { _ in }
        /// The badge that a press began on, which a release on it opens.
        private var pressed: Spot?
        private var current: String?

        override var isFlipped: Bool { true }
        private func spot(at event: NSEvent) -> Spot? {
            let point = convert(event.locationInWindow, from: nil)
            return spots.first { $0.frame.contains(point) }
        }

        /// Only a badge is this view's: a press anywhere else reaches the words under it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview else { return nil }
            let local = convert(point, from: superview)
            return spots.contains { $0.frame.contains(local) } ? self : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow,
                                                                  .inVisibleRect], owner: self))
        }

        override func resetCursorRects() {
            for spot in spots { addCursorRect(spot.frame, cursor: .pointingHand) }
        }

        override func mouseMoved(with event: NSEvent) { follow(event) }
        override func mouseEntered(with event: NSEvent) { follow(event) }
        override func mouseExited(with event: NSEvent) { mark(nil) }

        /// The hand in the event that crosses a badge's edge, before the words' field sets its I-beam.
        private func follow(_ event: NSEvent) {
            let spot = spot(at: event)
            if spot != nil { NSCursor.pointingHand.set() }
            mark(spot?.badge)
        }

        private func mark(_ badge: String?) {
            guard badge != current else { return }
            current = badge
            hover(badge)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { pressed = spot(at: event) }
        /// A double click opens it once.
        override func mouseUp(with event: NSEvent) {
            defer { pressed = nil }
            guard let pressed, event.clickCount <= 1, spot(at: event)?.badge == pressed.badge, let url = pressed.url
            else { return }
            open(url)
        }
    }
}
