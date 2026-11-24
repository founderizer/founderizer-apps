import AppKit
import FleetCore
import FleetMark
import SwiftUI

/// **A name in a request's words is a badge with its icon** (the owner, 20 November 2026, of a card whose words linked
/// "worker-1": "for servers, show a server/vps or mac icon before its name, and enclose it in like a badge entirely, so
/// it is easily identifable. Same for agents, use the agent icon first and the badge/card to wrap it", "also show the
/// hand cursor when hovering it so we know it is clickable", and then "Badge them too" of repositories and the app's
/// pages). `CardNames.pieces` finds them; the words stay one text, so they wrap and centre as before.
///
/// The badge is drawn behind the words from their own layout (`Text.LayoutKey`): the text keeps a room before the name
/// for the icon, a no-break space with the link on it, so the icon never stands at the end of a line apart from its
/// name, and a press on the icon opens what the name opens.
enum CardBadgeText {
    /// The room before a badge's name, in the words' size: its edge, the icon and the gap after it (`CardBadge.icon`).
    static let slot: CGFloat = 1.18
    /// The room after its name, in the words' size.
    static let end: CGFloat = 0.36

    /// The words of `text` with each name that `names` finds as a badge, a name and its role beside it as one
    /// (`CardJoin`), each link of its own a piece with its mark (`LinkRun`, which `linkPresses` gives the hand), and
    /// the rest as it is. `size` is the size of the words' font. `values`: each value of a request's words, which the
    /// agent put in inline code, is a piece with its mark too, which `cardValues` draws as a chip (`CardValueText`). A
    /// text with no name, no link and no such value is the one `Text` that it was.
    static func text(_ text: AttributedString, names: CardNames?, size: CGFloat, values: Bool = false) -> Text {
        let pieces = names.map { CardJoin.join($0.pieces(text)) } ?? []
        let chips = values && (names == nil ? [text] : pieces.filter { $0.badge == nil }.map(\.words))
            .contains { !CardValues.runs(in: $0).isEmpty }
        guard chips || pieces.contains(where: { $0.badge != nil }) || LinkRun.has(text) else { return Text(text) }
        var drawn: [Text] = [], index = 0, links = 0, found = 0
        // Words that are no badge: each link among them is a piece of its own, with its mark, and so is each value.
        func words(_ piece: AttributedString) {
            let (plain, values) = chips ? CardValueText.marked(piece, size: size) : (piece, [])
            for (url, range) in plain.runs[\.link] {
                guard let url else {
                    drawn += CardValueText.texts(plain, range, values: values, size: size, index: &found)
                    continue
                }
                drawn.append(Text(AttributedString(plain[range])).customAttribute(LinkRun(index: links, url: url)))
                links += 1
            }
        }
        for piece in pieces {
            guard let target = piece.badge else {
                words(piece.words)
                continue
            }
            var room = AttributedString("\u{00A0}")
            room.link = target.url
            room.swiftUI.kern = size * slot
            var name = piece.words
            if let last = name.characters.indices.last { name[last..<name.endIndex].swiftUI.kern = size * end }
            drawn.append(Text(room).customAttribute(CardBadge(index: index, icon: true, target: target)))
            drawn.append(Text(name).customAttribute(CardBadge(index: index, icon: false, target: target)))
            index += 1
        }
        if pieces.isEmpty { words(text) }
        guard let first = drawn.first else { return Text(text) }
        return drawn.dropFirst().reduce(first) { Text("\($0)\($1)") }
    }
}

/// The mark of a badge's pieces in a text's layout: which badge of the text, and whether it is the room of its icon.
struct CardBadge: TextAttribute {
    let index: Int
    let icon: Bool
    let target: CardNames.Target

    /// One badge on one line: a name that breaks at a hyphen at a line's end is a badge on each line, and only the
    /// first has the icon.
    struct Part: Identifiable {
        /// The text's place in the view and the badge's in the text, which both lines of one badge share.
        let badge: String
        let line: Int
        let target: CardNames.Target
        /// In the coordinates of the view that holds the texts.
        let frame: CGRect
        /// The room of the icon, where this line has it.
        let room: CGRect?
        var id: String { "\(badge)-\(line)" }
        /// Where its icon stands, on the line that has the icon's room.
        var icon: CGRect? { room.map { CardBadge.icon(room: $0, frame: frame) } }
    }

    /// Where a badge's icon stands in the room before its name, on the line that has the room.
    static func icon(room: CGRect, frame: CGRect) -> CGRect {
        let em = frame.height / 1.3
        return CGRect(x: room.minX + em * 0.3, y: frame.midY - em * 0.41, width: em * 0.82, height: em * 0.82)
    }

    /// How far the badges' canvas reaches past the text on each side: a badge stands 6% of its line over the line and
    /// under it, and its edge half a point more, so a badge of the first or the last line drew past a canvas of the
    /// text's own size, which cut it flat (the owner, 20 November 2026: "badge cutting off at the bottom side").
    static let bleed: CGFloat = 4

    /// The badges of the texts of a view, from their layouts.
    static func parts(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> [Part] {
        var parts: [Part] = []
        for (place, anchored) in layouts.enumerated() {
            let origin = proxy[anchored.origin]
            for (number, line) in anchored.layout.enumerated() {
                for badge in badges(of: line, offset: origin) {
                    parts.append(Part(badge: "\(place)-\(badge.index)", line: number, target: badge.target,
                                      frame: badge.frame, room: badge.room))
                }
            }
        }
        return parts
    }

    /// The badges of one line of a text's layout, in their order: each one's frame on the line, 6% of the line over
    /// and under it, and the room of its icon where the line has it, moved by `offset` (the text's place in a view).
    /// The card's canvas reads them from the layout of its texts (`parts`).
    static func badges(of line: Text.Layout.Line, offset: CGPoint)
        -> [(index: Int, target: CardNames.Target, frame: CGRect, room: CGRect?)] {
        var order: [Int] = [], frames: [Int: CGRect] = [:], rooms: [Int: CGRect] = [:]
        var targets: [Int: CardNames.Target] = [:]
        for run in line {
            guard let badge = run[CardBadge.self] else { continue }
            let frame = run.typographicBounds.rect.offsetBy(dx: offset.x, dy: offset.y)
            if let kept = frames[badge.index] { frames[badge.index] = kept.union(frame) } else {
                order.append(badge.index)
                frames[badge.index] = frame
                targets[badge.index] = badge.target
            }
            if badge.icon { rooms[badge.index] = frame }
        }
        return order.compactMap { index in
            guard let frame = frames[index], let target = targets[index] else { return nil }
            return (index, target, frame.insetBy(dx: 0, dy: -frame.height * 0.06), rooms[index])
        }
    }

    /// What a badge shows in the room before its name, ready to draw: an agent's glyph in its colours, a symbol in the
    /// link's colour, or a mark that is a view of its own (`CardBadgeIcon.isMark`), which the caller draws.
    enum Room: Equatable {
        case glyph(GlyphKind, light: Color, deep: Color)
        case symbol(String)
        case mark

        /// An agent's glyph in its own colours, or in grey while the agent is not there (`AgentGlyph.absentLight`).
        @MainActor static func agent(_ look: GlyphLook, absent: Bool) -> Room {
            .glyph(look.kind, light: absent ? AgentGlyph.absentLight : look.light,
                   deep: absent ? AgentGlyph.absentDeep : look.deep)
        }
    }

    /// **One badge**, as the card's canvas (`CardBadges`) and a chat's (`ChatBadgeIcon.draw`) both draw it: a
    /// soft violet fill with a violet edge in `frame` (violet is what he can press), a little more of both under the
    /// pointer (`over`), and in `place`, the icon's place on the line that has its room, what `room` shows; `mark` draws
    /// a mark there.
    static func draw(_ frame: CGRect, over: Bool, room: Room?, at place: CGRect?, in context: inout GraphicsContext,
                     mark: (inout GraphicsContext, CGRect) -> Void) {
        let shape = RoundedRectangle(cornerRadius: frame.height / 1.3 * 0.36, style: .continuous)
        context.fill(shape.path(in: frame), with: .color(FleetStyle.link.opacity(over ? 0.2 : 0.12)))
        context.stroke(shape.path(in: frame.insetBy(dx: 0.5, dy: 0.5)),
                       with: .color(FleetStyle.link.opacity(over ? 0.5 : 0.3)), lineWidth: 1)
        guard let place, let room else { return }
        switch room {
        case .glyph(let kind, let light, let deep):
            context.fill(GlyphOutline(kind: kind).path(in: place),
                         with: .linearGradient(Gradient(colors: [light, deep]), startPoint: place.origin,
                                               endPoint: CGPoint(x: place.maxX, y: place.maxY)))
            context.fill(GlyphCore(kind: kind).path(in: place),
                         with: .color(kind == .moon ? light : .white.opacity(GlyphLook.coreOpacity)))
        case .symbol(let name):
            let symbol = Text(Image(systemName: name))
                .font(.system(size: place.width * 0.86, weight: .medium)).foregroundColor(FleetStyle.link)
            context.draw(symbol, at: CGPoint(x: place.midX, y: place.midY), anchor: .center)
        case .mark:
            mark(&context, place)
        }
    }
}

extension EnvironmentValues {
    /// The SF Symbol of each server of the fleet by its name, for its badge in a request's words: a Mac or a server
    /// rack, as Settings › Servers marks its kind (`ServerEntry.symbol`). A server that it does not hold is a rack.
    @Entry var cardServerSymbols: [String: String] = [:]
}

/// What a badge shows before its name: what the app shows for the same thing elsewhere.
enum CardBadgeIcon: Hashable {
    /// An agent's own glyph, by its name.
    case glyph(String)
    /// An SF Symbol, in the link's colour.
    case symbol(String)
    /// The GitHub mark, in the link's colour, as Settings › Apps marks GitHub.
    case github
    /// The mark of Google Drive or Gmail, in its own colours.
    case service(GoogleService)
    /// **A skill that the owner gave an agent** (owner feature `message_skills`): the bolt (`skillSymbol`) in the link's
    /// colour, not the closed book of a knowledge file. The badge of a gift in his message (`SkillBadge`) and the chip of
    /// a skill in the box show it; no name of a card's words is a skill (`of(_:servers:)`).
    case skill

    /// The SF Symbol of a skill's mark (`skill`).
    static let skillSymbol = "bolt"

    /// A server's kind (a Mac or a server rack, `ServerEntry.symbol`), a repository's GitHub, and a page's own mark: the
    /// symbol of its section in Settings, of its row in the sidebar, or the mark of its app on the Apps page.
    @MainActor static func of(_ target: CardNames.Target, servers: [String: String]) -> CardBadgeIcon {
        switch target {
        case .agent(let name): .glyph(name)
        case .server(let name): .symbol(servers[name] ?? "server.rack")
        case .repository: .github
        case .knowledge: .symbol("book.closed")     // one file; the Knowledge page's own mark is books.vertical
        // the marks of the secret's own detail (`SecretsPage.detail`): an API key, or a login
        case .secret(_, let key): .symbol(key ? "key.horizontal" : "person.badge.key")
        case .page(let page):
            switch FleetStore.cardPage(page) {
            case .settings(let tab): .symbol(tab.symbol)
            case .app(.github): .github
            case .app(.drive): .service(.drive)
            case .app(.gmail): .service(.gmail)
            case .app(.mcp): .symbol("puzzlepiece.extension")
            case .activity: .symbol("rectangle.split.3x1")      // the Tasks row of the sidebar
            case .agents: .symbol(AgentsPage.symbol)
            default: .symbol("macwindow")
            }
        }
    }

    /// A mark that is a view of its own, which the badges' canvas draws as one of its symbols.
    var isMark: Bool {
        switch self {
        case .github, .service: true
        case .glyph, .symbol, .skill: false
        }
    }
}

extension View {
    /// The badges of the names in the texts of this view (`CardBadgeText`), and a press on one that opens it, with the
    /// hand under the pointer; and the press of each link of the texts (`linkPresses`), unless `links` is false: a
    /// `MessageText` gives each of its blocks their own. A card's folded reason, which takes this, has no selection
    /// field, so its links keep their presses as its badges do.
    func cardBadges(_ on: Bool = true, links: Bool = true) -> some View {
        modifier(CardBadges(on: on)).linkPresses(links, always: true)
    }
}

private struct CardBadges: ViewModifier {
    let on: Bool
    /// The badge under the pointer, which fills a little more.
    @State private var hovered: String?
    @Environment(\.openURL) private var openURL
    @Environment(\.glyphTeam) private var team
    @Environment(\.glyphPresence) private var presences
    @Environment(\.cardServerSymbols) private var symbols

    func body(content: Content) -> some View {
        if on {
            content
                .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { proxy in
                        let parts = CardBadge.parts(layouts, in: proxy)
                        let icons = parts.reduce(into: [String: CardBadgeIcon]()) { icons, part in
                            icons[part.id] = CardBadgeIcon.of(part.target, servers: symbols)
                        }
                        let looks = parts.reduce(into: [String: GlyphLook]()) { looks, part in
                            if case .agent(let name) = part.target { looks[name] = GlyphTeams.look(of: name, in: team) }
                        }
                        Canvas { context, _ in
                            context.translateBy(x: CardBadge.bleed, y: CardBadge.bleed)     // the text's own places
                            for part in parts { draw(part, icon: icons[part.id], look: looks, in: &context) }
                        } symbols: {
                            ForEach(parts.filter { $0.icon != nil && icons[$0.id]?.isMark == true }) { part in
                                if let icon = icons[part.id], let frame = part.icon { mark(icon, side: frame.width).tag(part.id) }
                            }
                        }
                        .padding(-CardBadge.bleed)      // the canvas reaches past the text, so no badge edge is cut
                    }
                }
                .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { proxy in
                        ForEach(CardBadge.parts(layouts, in: proxy)) { part in press(part) }
                    }
                }
        } else {
            content
        }
    }

    /// The press of one badge: the link of its name opens, with the hand under the pointer (`BadgePress`). The words
    /// keep their link for the keyboard and VoiceOver, so this press is hidden from both.
    private func press(_ part: CardBadge.Part) -> some View {
        BadgePress(open: { if let url = part.target.url { openURL(url) } }, hover: { inside in
            if inside { hovered = part.badge } else if hovered == part.badge { hovered = nil }
        })
        .frame(width: part.frame.width, height: part.frame.height)
        .accessibilityHidden(true)
        // last: a modifier after it takes the whole text, and the press of the last badge then took every press on it
        .position(x: part.frame.midX, y: part.frame.midY)
    }

    /// A badge with its icon in the room before its name (`CardBadge.draw`, `CardBadgeIcon`): a mark that is a view of
    /// its own is the canvas's symbol.
    private func draw(_ part: CardBadge.Part, icon: CardBadgeIcon?, look: [String: GlyphLook],
                      in context: inout GraphicsContext) {
        let room: CardBadge.Room? = switch icon {
        case .glyph(let name)?:
            look[name].map { .agent($0, absent: presences[name] == .offline || presences[name] == .unknown) }
        case .symbol(let name)?: .symbol(name)
        case .skill?: .symbol(CardBadgeIcon.skillSymbol)
        case .github?, .service?: .mark
        case nil: nil
        }
        CardBadge.draw(part.frame, over: hovered == part.badge, room: room, at: part.icon, in: &context) { context, place in
            if let mark = context.resolveSymbol(id: part.id) { context.draw(mark, in: place) }
        }
    }

    /// The marks that are views of their own, at the icon's side.
    @ViewBuilder private func mark(_ icon: CardBadgeIcon, side: CGFloat) -> some View {
        switch icon {
        case .github: GitHubMark(size: side).foregroundStyle(FleetStyle.link)
        case .service(let service): ServiceMark(service: service, size: side)
        case .glyph, .symbol, .skill: EmptyView()
        }
    }
}

/// **A badge's press is an AppKit view, so the hand comes with the pointer** (the owner, 20 November 2026: "while
/// hovering a badge, the typing cursor blinks briefly before showing the hand"). The selectable words lay an AppKit
/// field over the text whose cursor rect gives the I-beam on the whole text, badges included, and AppKit sets it in the
/// event that crosses the field's edge; a SwiftUI hover sets the hand only at the next drawing, so the I-beam showed
/// first. This view lies over the field, so AppKit sends it the cursor's events of its own place, and it sets the hand in
/// those same events: where the pointer comes in, where it moves, and where the cursor is asked for. A link's press is
/// this view too (`LinkPresses`).
struct BadgePress: NSViewRepresentable {
    let open: () -> Void
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> PressView { PressView() }

    func updateNSView(_ view: PressView, context: Context) {
        view.open = open
        view.hover = hover
    }

    final class PressView: NSView {
        var open: () -> Void = {}
        var hover: (Bool) -> Void = { _ in }
        /// A press that began here, which a release here opens.
        private var pressed = false
        /// The pointer is over this view by its last event: what a window that loses the keyboard ends (`hovers`).
        private var hovering = false
        private var resigned: NSObjectProtocol?

        /// **The tracking of a window that stands over other apps works in any state.** A request card's own window
        /// is a panel that does not take the app to the front (`NeedPanel`): it stands over another app, which has the
        /// keyboard, so a tracking of the key window gave no hand and no lighter look until the press (a check in a
        /// guest Mac, 21 November 2026). The app's other windows keep the key window's tracking.
        private var tracksAlways: Bool { window?.styleMask.contains(.nonactivatingPanel) ?? false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved,
                                                                  tracksAlways ? .activeAlways : .activeInKeyWindow,
                                                                  .inVisibleRect], owner: self))
        }

        /// **A window that loses the keyboard ends the hover of its presses**: the key window's tracking sends no
        /// `mouseExited` then, so the lighter look of a badge or a chip stayed until the pointer came in and went out
        /// again. A view that leaves its window ends it too, and its watch of the window goes with it.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resigned { NotificationCenter.default.removeObserver(resigned) }
            resigned = nil
            hovers(false)
            updateTrackingAreas()
            guard let window, !tracksAlways else { return }
            // no queue: the window posts it on the main thread, and the block runs there at once
            resigned = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                              queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.hovers(false) }
            }
        }

        private func hovers(_ inside: Bool) {
            guard inside != hovering else { return }
            hovering = inside
            hover(inside)
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func mouseEntered(with event: NSEvent) {
            NSCursor.pointingHand.set()
            hovers(true)
        }
        override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func mouseExited(with event: NSEvent) { hovers(false) }
        /// A press in a window that is not in front opens the badge too, as the link under it did.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// A press on a badge never moves the window, whose content runs to its top edge.
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { pressed = true }
        /// A double click opens it once.
        override func mouseUp(with event: NSEvent) {
            defer { pressed = false }
            if pressed, event.clickCount <= 1, bounds.contains(convert(event.locationInWindow, from: nil)) { open() }
        }
    }
}
