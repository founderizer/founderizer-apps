import AppKit
import FleetCore
import FleetMark
import SwiftUI

/// **A server or an agent in a request's words is a badge with its icon** (the owner, 20 November 2026, of a card whose
/// words linked "worker-1": "for servers, show a server/vps or mac icon before its name, and enclose it in like a badge
/// entirely, so it is easily identifable. Same for agents, use the agent icon first and the badge/card to wrap it", and
/// "also show the hand cursor when hovering it so we know it is clickable"). `CardNames.pieces` finds them; the words
/// stay one text, so they wrap, centre and select as before.
///
/// The badge is drawn behind the words from their own layout (`Text.LayoutKey`): the text keeps a room before the name
/// for the icon, a no-break space with the link on it, so the icon never stands at the end of a line apart from its
/// name, and a press on the icon opens what the name opens.
enum CardBadgeText {
    /// The room before a badge's name, in the words' size: its edge, the icon and the gap after it (`CardBadge.icon`).
    static let slot: CGFloat = 1.18
    /// The room after its name, in the words' size.
    static let end: CGFloat = 0.36

    /// The words of `text` with each agent and server that `names` finds as a badge: the rest as `CardNames.link`
    /// draws it. `size` is the size of the words' font.
    static func text(_ text: AttributedString, names: CardNames?, size: CGFloat) -> Text {
        guard let names else { return Text(text) }
        let pieces = names.pieces(text)
        guard pieces.contains(where: { $0.badge != nil }) else { return Text(pieces.first?.words ?? text) }
        var drawn: [Text] = [], index = 0
        for piece in pieces {
            guard let target = piece.badge else {
                drawn.append(Text(piece.words))
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
        return drawn.dropFirst().reduce(drawn[0]) { Text("\($0)\($1)") }
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
    }

    /// The badges of the texts of a view, from their layouts.
    static func parts(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> [Part] {
        var parts: [Part] = []
        for (place, anchored) in layouts.enumerated() {
            let origin = proxy[anchored.origin]
            for (number, line) in anchored.layout.enumerated() {
                var order: [Int] = [], frames: [Int: CGRect] = [:], rooms: [Int: CGRect] = [:]
                var targets: [Int: CardNames.Target] = [:]
                for run in line {
                    guard let badge = run[CardBadge.self] else { continue }
                    let frame = run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                    if let kept = frames[badge.index] { frames[badge.index] = kept.union(frame) } else {
                        order.append(badge.index)
                        frames[badge.index] = frame
                        targets[badge.index] = badge.target
                    }
                    if badge.icon { rooms[badge.index] = frame }
                }
                for index in order {
                    guard let frame = frames[index], let target = targets[index] else { continue }
                    parts.append(Part(badge: "\(place)-\(index)", line: number, target: target,
                                      frame: frame.insetBy(dx: 0, dy: -frame.height * 0.06), room: rooms[index]))
                }
            }
        }
        return parts
    }
}

extension EnvironmentValues {
    /// The SF Symbol of each server of the fleet by its name, for its badge in a request's words: a Mac or a server
    /// rack, as Settings › Servers marks its kind (`ServerEntry.symbol`). A server that it does not hold is a rack.
    @Entry var cardServerSymbols: [String: String] = [:]
}

extension View {
    /// The badges of the agents and the servers in the texts of this view (`CardBadgeText`), and a press on one that
    /// opens it, with the hand under the pointer.
    func cardBadges(_ on: Bool = true) -> some View { modifier(CardBadges(on: on)) }
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
                        let looks = parts.reduce(into: [String: GlyphLook]()) { looks, part in
                            if case .agent(let name) = part.target { looks[name] = GlyphTeams.look(of: name, in: team) }
                        }
                        Canvas { context, _ in
                            for part in parts { draw(part, look: looks, in: &context) }
                        }
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

    /// The press of one badge: the link of its name opens, with the hand under the pointer. The words keep their link
    /// for the keyboard and VoiceOver, so this press is hidden from both.
    private func press(_ part: CardBadge.Part) -> some View {
        Button { if let url = part.target.url { openURL(url) } } label: {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: part.frame.width, height: part.frame.height)
        .position(x: part.frame.midX, y: part.frame.midY)
        // **The hand under the pointer.** The selectable words lay an AppKit field over the text whose cursor rect gives
        // the I-beam on the whole text, badges included, and AppKit sets it only where the pointer crosses that
        // rect's edge: each move over the badge sets the hand again, and its end lets AppKit set the cursor of the
        // place again (the I-beam on the words, the arrow beside them).
        .pointerStyle(.link)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if hovered != part.badge { hovered = part.badge }
                NSCursor.pointingHand.set()
            case .ended:
                if hovered == part.badge { hovered = nil }
                NSApp.keyWindow?.resetCursorRects()
            }
        }
        .focusable(false)
        .accessibilityHidden(true)
    }

    /// A badge: a soft violet fill with a violet edge (violet is what he can press), and the icon in the room before
    /// its name — the agent's own glyph, or the symbol of the server's kind in the link's colour.
    private func draw(_ part: CardBadge.Part, look: [String: GlyphLook], in context: inout GraphicsContext) {
        let frame = part.frame, size = frame.height / 1.3
        let shape = RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
        let over = hovered == part.badge
        context.fill(shape.path(in: frame), with: .color(FleetStyle.link.opacity(over ? 0.2 : 0.12)))
        context.stroke(shape.path(in: frame.insetBy(dx: 0.5, dy: 0.5)),
                       with: .color(FleetStyle.link.opacity(over ? 0.5 : 0.3)), lineWidth: 1)
        guard let room = part.room else { return }
        let side = size * 0.82
        let icon = CGRect(x: room.minX + size * 0.3, y: frame.midY - side / 2, width: side, height: side)
        switch part.target {
        case .agent(let name):
            guard let look = look[name] else { return }
            let absent = presences[name] == .offline || presences[name] == .unknown
            let light = absent ? AgentGlyph.absentLight : look.light, deep = absent ? AgentGlyph.absentDeep : look.deep
            context.fill(GlyphOutline(kind: look.kind).path(in: icon),
                         with: .linearGradient(Gradient(colors: [light, deep]), startPoint: icon.origin,
                                               endPoint: CGPoint(x: icon.maxX, y: icon.maxY)))
            context.fill(GlyphCore(kind: look.kind).path(in: icon),
                         with: .color(look.kind == .moon ? light : .white.opacity(GlyphLook.coreOpacity)))
        case .server(let name):
            let symbol = Text(Image(systemName: symbols[name] ?? "server.rack"))
                .font(.system(size: side * 0.86, weight: .medium)).foregroundColor(FleetStyle.link)
            context.draw(symbol, at: CGPoint(x: icon.midX, y: icon.midY), anchor: .center)
        case .repository, .page:
            break
        }
    }
}
