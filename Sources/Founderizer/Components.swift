import AppKit
import SwiftUI
import FleetCore

enum FleetStyle {
    static let canvas = Color(red: 0.098, green: 0.098, blue: 0.098)
    static let rail = Color(white: 0.125)
    /// **A card on the rail** — the cards of an agent's chat panel (fix round 2): five levels over the panel's #202020,
    /// where a page's card (`surface`, #222222) stood two off it and the bar asks four.
    static let chrome = Color(white: 0.145)
    static let bubble = Color(white: 0.19)
    /// **The selected row of a page's own sidebar**: 16 levels over its ground, the canvas #191919, as the main
    /// sidebar's selected row (`bubble`, #303030) is over the rail #202020 (fix round 2: the page sidebars drew #303030
    /// on #191919, 23 levels; one contrast for one meaning).
    static let pageSelection = Color(white: 0x29 / 255)
    static let composer = Color(white: 0.205)
    /// The words of a page that set no font of their own: a row's 13 (`FormMetrics.text`; T-23: it was 12.5, a size of
    /// its own beside the rows' 13).
    static let body = Font.system(size: 13, weight: .regular)
    /// The one measure of a page's column. Every screen but the Tasks board keeps it, so the content does not move
    /// sideways when the owner goes from one page to the next; the board's lanes take the window's whole width.
    static let pageWidth: CGFloat = 1100
    /// A conversation and a task thread, where the measure is a line of prose and not a frame: a line of 1,100
    /// points is too long to read. This is the only second width in the app, and no page may take it.
    static let readingWidth: CGFloat = 780
    /// The window's own sidebar, at the left, and the panel at the right of an agent's chat and of a task thread.
    /// They are the frame around every page, so they are read side by side and take one measure between them: wide
    /// enough for an agent's name beside its glyph and its marks, and for an account address on one line. These are
    /// their widths until the owner drags an edge (`SideEdge`), and the ranges he can drag them in: he asked for both
    /// wider more than once, and then for the edges themselves (27 October 2026: "I want both sidemenus to be wider!
    /// ... Even make them resizable").
    static let sidebarWidth: CGFloat = 320
    static let sidebarWidths: ClosedRange<CGFloat> = 240...520
    static let panelWidth: CGFloat = 380
    static let panelWidths: ClosedRange<CGFloat> = 280...600
    /// The least a page keeps between the two: in a narrow window they give up width before the page does.
    static let pageMinWidth: CGFloat = 380
    /// A page's own sidebar (agent details, Settings).
    static let pageSidebarWidth: CGFloat = 220
    /// **A page sidebar's symbol column, and the room between it and the word** (the margins of 30 October 2026, row 5):
    /// its words begin 26 pt after the column's edge, and the head's name after its glyph begins there too (`AgentPage`).
    static let pageSidebarMark: CGFloat = 20, pageSidebarGap: CGFloat = 6
    static let surface = Color(red: 0.135, green: 0.135, blue: 0.135)
    static let line = hairline(0.065)
    /// Details, values and quiet words; lighter with Increase Contrast (`contrasted`), where they read 9.6:1 on the
    /// canvas instead of 6.2:1.
    static let muted = contrasted(NSColor(srgbRed: 0.60, green: 0.60, blue: 0.60, alpha: 1),
                                  increased: NSColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1))
    static let text = Color(white: 0.90)
    /// The brand's violet (`#635BFF`), which is the mark's own colour. It was a blue of its own until the mark
    /// existed; the app follows the mark rather than keeping a second palette.
    static let accent = Color(red: 0x63 / 255, green: 0x5B / 255, blue: 0xFF / 255)
    /// **The words of a link: the violet, lighter, so they read** (fix round 2; violet keeps its one job, D-8): #8F88FF
    /// stands 5.4:1 on a card and more on the canvas, where the accent's own 3.4:1 was too faint for words (text asks
    /// 4.5:1). The accent stays for the focus ring, a checked box, the mark and every filled control.
    static let link = Color(red: 0x8F / 255, green: 0x88 / 255, blue: 0xFF / 255)
    /// The brand's soft accent (`#ecebff`) and its ink (`#111213`), for the places that carry the mark itself.
    static let accentSoft = Color(red: 0xEC / 255, green: 0xEB / 255, blue: 0xFF / 255)
    static let ink = Color(red: 0x11 / 255, green: 0x12 / 255, blue: 0x13 / 255)

    /// **The higher-contrast scheme he gets when he turns on Increase Contrast** (Apple: provide "a higher contrast
    /// color scheme when the system setting Increase Contrast is turned on"; the app read no contrast at all). One
    /// helper for every user of these colours: the colour takes its higher value by itself wherever it is drawn, in
    /// the window's high-contrast appearance or with the system's setting on, so no page has to ask.
    static func contrasted(_ standard: NSColor, increased: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let high = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            return high == .accessibilityHighContrastDarkAqua || high == .accessibilityHighContrastAqua
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? increased : standard
        })
    }

    /// A hairline: white at `alpha`, and white at 0.40 with Increase Contrast, which an edge needs to read 3:1 on
    /// the canvas and on a card (0.30 measures 2.7:1).
    static func hairline(_ alpha: CGFloat) -> Color {
        contrasted(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha), increased: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.40))
    }

    /// The width of the edge of a card or a field: half a point, and one point with Increase Contrast. It reads the
    /// window's `colorSchemeContrast`, which the view passes, and the system's setting where the app's dark
    /// appearance hides it.
    @MainActor static func edgeWidth(_ contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
    }
}

/// The one spacing scale of a page. A screen that needs a measure takes it from here; a number written into a page
/// is a number that the next page will not have.
enum FleetSpace {
    /// Between the blocks of a page: the header, and each section under it.
    static let block: CGFloat = 22
    /// Inside a block: between a heading and its card, and between two controls on one line.
    static let inside: CGFloat = 10
    /// Over the title of a page, and under its last block.
    static let top: CGFloat = 28, bottom: CGFloat = 24
    /// Over a page's back link (`FleetBack`), which stands in the room over the title: its words begin 40 points
    /// from the window's top, under the traffic lights, and end 8 points over the title's line.
    static let back: CGFloat = 4
    /// The room the window's own traffic lights need at the top. Each pane of the window runs to the very top
    /// edge now — there is no bar of any kind — so each one leaves this much above its own first row, and the
    /// lights float over the pane's own background (the owner, 20 October 2026, with a picture of an app that
    /// does it: "remove the top bar, it does not look good"; "look at grok bot, no header/row at all"). It is
    /// the height the window header used to have, so nothing of his moved when that went.
    static let lights: CGFloat = 36
    /// **Under the band, over the first thing of a pane** (the margins of 30 October 2026, row 28: 12, 14 and 18): the
    /// main sidebar's first row, the chat's pill, the first card of the chat's panel and the head of a task's panel all
    /// begin 50 pt from the window's top.
    static let underBand: CGFloat = 14
    /// **Under the last thing of a pane at the window's bottom edge**: the main sidebar's Settings row, a chat's
    /// composer, a task's guidance or its controls (the margins of 30 October 2026, rows 7 and 29: 12, 14 and 0).
    static let under: CGFloat = 12
    /// Left and right of the column.
    static let margin: CGFloat = 24
    /// Between two buttons of a page header.
    static let actions: CGFloat = 8
}

/// The measures of an agent's chat and of a task thread, from the owner's reference (the Claude desktop chat, measured
/// on 16 October 2026): SF Pro 14 pt with lines 22.5 pt apart, 37.5 pt from the last line of one block to the first
/// line of the next, a lighter bubble with 16 pt corners, times in 12 pt, and activity rows in a light gray, 36.5 pt
/// apart. Forms keep `FleetStyle.body`.
enum ChatStyle {
    static let font = Font.system(size: 14)
    static let lineSpacing: CGFloat = 6
    /// Between two blocks. SwiftUI puts the line spacing only between the lines of one text, so the space between two
    /// blocks also takes the space that the reference has above and below each line.
    static let blockSpacing: CGFloat = 21
    /// Between two items of one list.
    static let itemSpacing: CGFloat = 10
    /// Under each row of a task thread.
    static let rowSpacing: CGFloat = 20
    static let heading = Font.system(size: 15.5, weight: .semibold)
    /// Code in a chat and a task thread, at its one size there: a block, a command, a tool's output. A page's is
    /// `FormMetrics.code`.
    static let code = Font.system(size: 12.5, design: .monospaced)
    /// A request's title in a chat and in its own window, where its words are the chat's 14: medium, at that size.
    static let title = Font.system(size: 14, weight: .medium)
    /// A time, a footer and a small label in the chat.
    static let detail = Font.system(size: 12)
    /// One line of the chat font, as AppKit lays it out: the step by which a message field grows.
    static let line: CGFloat = 17
    static let bubble = Color(white: 0.24)
    /// His own message's corners: his rule (the Claude desktop chat), and the third radius of a screen.
    static let bubbleRadius: CGFloat = 16
    static let activity = Color(white: 0.70)
}

/// One row of a sidebar, in the main sidebar and in a page's own sidebar: a mark 20 points wide, the name, and marks at
/// the right, 32 points high. A muted mark and the text color for the name; a soft fill under the pointer and a
/// stronger one for the selected row.
struct SidebarRow<Mark: View, Trailing: View>: View {
    private let title: String
    private let selected: Bool
    private let action: () -> Void
    private let mark: Mark
    private let trailing: Trailing
    @State private var hovered = false
    @Environment(\.pageSidebar) private var pageSidebar

    init(_ title: String, selected: Bool, action: @escaping () -> Void,
         @ViewBuilder mark: () -> Mark, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.selected = selected
        self.action = action; self.mark = mark(); self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if pageSidebar {
                    // **In a page's own sidebar the word follows its symbol by 6** (the margins of 30 October 2026, row
                    // 5, with the owner's crop: 15.5–23.5 pt between a symbol and its word): the symbol in the middle of
                    // a 20-pt column, as a word follows a mark of its own column everywhere (a chat row's glyph, a card's
                    // mark), and the words begin where the agent's name begins over them.
                    mark.frame(width: FleetStyle.pageSidebarMark).padding(.trailing, FleetStyle.pageSidebarGap)
                } else {
                    // Flush to the leading edge of the one mark column, as every other row of the app is: a glyph and
                    // an SF Symbol of different widths must begin at the same x, not share a centre. The main sidebar's
                    // words begin where the agents' names begin, after their glyphs.
                    RowMark { mark }
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                trailing
            }
            .font(FormMetrics.text).foregroundStyle(FleetStyle.text)
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(SidebarFill(selected: selected, hovered: hovered))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The fill under a sidebar row: a soft one under the pointer and a stronger one for the selected row, which stands as
/// far over a page sidebar's ground as over the main sidebar's (`FleetStyle.pageSelection`).
private struct SidebarFill: View {
    let selected: Bool
    let hovered: Bool
    @Environment(\.pageSidebar) private var pageSidebar

    var body: some View {
        RoundedRectangle(cornerRadius: FormMetrics.inner)
            .fill(selected ? (pageSidebar ? FleetStyle.pageSelection : FleetStyle.bubble) : hovered ? Color.white.opacity(0.04) : .clear)
    }
}

/// **One agent's chat in the main sidebar**, as a chat app lists its conversations. The owner, 24 October 2026, with
/// Grok's list beside his own: "should be more like Grok (taller, with preview…) KEEP STYLE". So the row is taller
/// than a navigation row, with the agent's glyph at a size that carries it, its name, and under the name one muted
/// line (`ChatList.preview`); the fonts, the colours, the marks at the right and the fills are this app's own.
///
/// **Every row is the same height**, with or without its line: the fleet is read every three seconds and a line
/// comes and goes with it, so a list where only some rows were taller would move the row under his pointer. A row
/// with nothing to say keeps its name in the middle of the same height.
struct ChatRow<Mark: View, Trailing: View>: View {
    /// The glyph's size, and the room its column takes.
    static var glyph: CGFloat { GlyphSize.list }
    private let title: String
    private let preview: String?
    private let selected: Bool
    /// The name in semibold: a new reply in the agent's chat.
    private let emphasized: Bool
    /// **The agent works now, and its line moves as the chat's "Thinking" does** (the owner, 13 November 2026: "The
    /// subtitle text on the sidebar task item should animate like the Thinking label, while the agent is Thinking"):
    /// the same band of light over the same words in the same place (`ShimmeringWords`). Still with Reduce Motion.
    private let working: Bool
    /// **When the row's line is from, at the end of the name's line**, as a chat app writes it (`ChatList.time`; the
    /// owner, 13 November 2026: "maybe I would like this relative time label on the side menu too"): muted, in the
    /// line's own size. The row's marks (a setup that runs, the unread dot) then stand under it, at the end of the
    /// line. A row with no line has no time, and its marks stay in the row's middle.
    private let time: String?
    private let action: () -> Void
    private let mark: Mark
    private let trailing: Trailing
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, preview: String?, selected: Bool, emphasized: Bool, working: Bool = false,
         time: String? = nil, action: @escaping () -> Void, @ViewBuilder mark: () -> Mark,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.preview = preview; self.selected = selected; self.emphasized = emphasized
        self.working = working; self.time = preview == nil ? nil : time
        self.action = action; self.mark = mark(); self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            // The name begins where the title of every navigation row above it begins, as the agent's name does
            // beside its larger glyph in the status panel.
            HStack(spacing: FormMetrics.markColumn + FormMetrics.markGap - Self.glyph) {
                mark.frame(width: Self.glyph, height: Self.glyph)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).fontWeight(emphasized ? .semibold : .regular).lineLimit(1)
                        if let time {
                            Spacer(minLength: 0)
                            Text(time).font(FormMetrics.detail).monospacedDigit().foregroundStyle(FleetStyle.muted)
                                .lineLimit(1).fixedSize()
                        }
                    }
                    if let preview {
                        HStack(spacing: 6) {
                            previewLine(preview)
                            if time != nil {
                                Spacer(minLength: 0)
                                trailing
                            }
                        }
                    }
                }
                if time == nil {
                    Spacer(minLength: 0)
                    trailing
                }
            }
            .font(FormMetrics.text).foregroundStyle(FleetStyle.text)
            .padding(.horizontal, 10).frame(height: 50)
            .background(SidebarFill(selected: selected, hovered: hovered))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension SidebarRow where Mark == SidebarSymbol, Trailing == EmptyView {
    /// A row with an SF Symbol in the muted color and nothing at the right.
    init(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) {
        self.init(title, selected: selected, action: action) { SidebarSymbol(name: symbol) } trailing: { EmptyView() }
    }
}

/// The SF Symbol of a sidebar row, in the muted color.
struct SidebarSymbol: View {
    let name: String
    var body: some View { Image(systemName: name).font(IconMetrics.symbol(14)).foregroundStyle(FleetStyle.muted).accessibilityHidden(true) }
}

/// Every icon-only control of the app has one shape: the symbol stands in a circle of its own that fills under the
/// pointer, so the pointer finds it and two icons never touch. The words that say what it does are its hover text and
/// its accessibility label. `IconButton` is the control itself; `FleetIconButtonStyle` is for a button whose label
/// draws something else (the round Send), and `.iconSurface()` for an icon that opens a menu.
///
/// **An icon button stands in a soft grey circle at rest** (the owner's yes of 28 October 2026, D-8, as Grok Bot draws
/// its icons): "+", pause, stop, refresh and trash read as buttons before the pointer finds them. A mark that only
/// opens its words (`StateMark`) and a message's own footer, which shows under the pointer, keep no circle at rest.
enum IconMetrics {
    /// **The two drawn sizes of an icon button**: the square of every icon button that stands alone (the composer's
    /// plus, Send, pause, stop, refresh, trash, close), and the smaller one of an icon in a line of words (a message's
    /// footer, a staged file's ×). One chat screen drew four (22 × 20, 22 × 22, 28 and 32), and two things of one kind
    /// that differ read as a mistake.
    static let side: CGFloat = 28, small: CGFloat = 22
    /// The room a small text control (Back, a fold row of a thread) takes above and below its words for the pointer:
    /// a line of 16 points is clicked in 28, the side of an icon button, and nothing clickable is under 20 points
    /// (Apple's macOS default and minimum for a control).
    static let reach: CGFloat = 6

    /// **The point size of an SF Symbol**: an icon's own measure, which keeps the size it is drawn at. It is not a size
    /// of type: words take the tokens of `FormMetrics`, `ChatStyle` and `SetupMetrics` (T-23), and an icon takes its
    /// size from here, so no view writes a font of its own.
    static func symbol(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    /// The circle's fill: white 0.06 at rest (0.08 on a card, a step lighter), 0.11 under the pointer and 0.14 while
    /// pressed; none at rest for a control that keeps no circle there, and none at all while it is disabled.
    static func fill(hovered: Bool, pressed: Bool, enabled: Bool, rest: Bool = false, onCard: Bool = false) -> Color {
        guard enabled else { return .clear }
        return Color.white.opacity(pressed ? 0.14 : hovered ? 0.11 : rest ? (onCard ? 0.08 : 0.06) : 0)
    }
}

/// The circle under an icon: it fills under the pointer, and at rest for an icon button (`rest`), and gives the
/// symbol room on every side.
struct IconSurface: ViewModifier {
    var side: CGFloat = IconMetrics.side
    var pressed = false
    /// An icon button: the soft circle shows at rest too.
    var rest = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.onCard) private var onCard
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .frame(minWidth: side, minHeight: side)
            .background(IconMetrics.fill(hovered: hovered, pressed: pressed, enabled: isEnabled, rest: rest, onCard: onCard),
                        in: Circle())
            .contentShape(Circle())
            .onHover { hovered = $0 }
    }
}

extension View {
    /// The hover circle of an icon that is no button: the icon of a menu or of a `FleetSelect`.
    func iconSurface(side: CGFloat = IconMetrics.side) -> some View { modifier(IconSurface(side: side)) }

    /// **The click of a smaller icon button still reaches 28 × 28 points**, the side of an icon button that stands
    /// alone: the square under the pointer keeps the size it is drawn at, and the room around it takes nothing from
    /// the line it stands in.
    func iconReach(_ side: CGFloat) -> some View {
        let room = max(0, (IconMetrics.side - side) / 2)
        return padding(room).contentShape(Rectangle()).padding(-room)
    }
}

/// An icon button whose label is not one symbol: the round Send keeps its own filled circle, which the pointer
/// darkens, and every other label gets the hover circle.
struct FleetIconButtonStyle: ButtonStyle {
    var side: CGFloat = IconMetrics.side
    /// A label that draws its own filled shape.
    var filled = false
    /// An icon button that shows its soft circle at rest (`IconButton`).
    var rest = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, side: side, filled: filled, rest: rest)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let side: CGFloat
        let filled: Bool
        let rest: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            if filled {
                configuration.label
                    .brightness(isEnabled ? (configuration.isPressed ? -0.14 : hovered ? -0.07 : 0) : 0)
                    .onHover { hovered = $0 }
            } else {
                configuration.label.modifier(IconSurface(side: side, pressed: configuration.isPressed, rest: rest))
                    .iconReach(side)
            }
        }
    }
}

/// **A checkbox that clicks in 28 points** (T-21, fix round): the box drawn at 14 points, as the system's, its words
/// beside it, and the whole of it — box, words and the room over and under them — the click. The system checkbox
/// clicked in its 18 × 18 points (14 × 16 small), and nothing around it did; a SwiftUI frame around an AppKit control
/// widens nothing. Checked is the violet of what he presses, with a white check; a disabled one fades.
struct FleetCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Checkbox(configuration: configuration) }

    private struct Checkbox: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.labelsVisibility) private var labels

        var body: some View {
            let box = RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 6) {
                    ZStack {
                        box.fill(configuration.isOn ? FleetStyle.accent : Color.white.opacity(0.05))
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(IconMetrics.symbol(9, weight: .bold)).foregroundStyle(Color.white)
                        } else {
                            box.strokeBorder(FleetStyle.hairline(0.32), lineWidth: max(1, FleetStyle.edgeWidth(contrast)))
                        }
                    }
                    .frame(width: 14, height: 14)
                    if labels != .hidden { configuration.label }
                }
                .frame(minWidth: IconMetrics.side, minHeight: IconMetrics.side)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

/// One icon button: the symbol, and the words that say what it does.
struct IconButton: View {
    let symbol: String
    /// What the button does, in the owner's words: the hover text and the accessibility label.
    let words: String
    var size: CGFloat = 13
    var side: CGFloat = IconMetrics.side
    var tint: Color = FleetStyle.muted
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(IconMetrics.symbol(size)).foregroundStyle(tint)
        }
        .buttonStyle(FleetIconButtonStyle(side: side, rest: true))
        .help(words)
        .accessibilityLabel(words)
    }
}

/// A field for a message that can be long: it is as tall as its text, between the two line counts, and then it
/// scrolls. A plain `TextField(axis: .vertical)` stops at its line limit and holds the rest where neither the wheel
/// nor the eye reaches it, so the owner cannot read back what he wrote. Give the field no `lineLimit`.
struct GrowingField: ViewModifier {
    let lines: ClosedRange<Int>
    var line: CGFloat = ChatStyle.line
    /// The height of the text now.
    @State private var written: CGFloat = 0

    func body(content: Content) -> some View {
        let least = CGFloat(lines.lowerBound) * line, most = CGFloat(lines.upperBound) * line
        ScrollView {
            // The field keeps its own lowest height, so a click under a short text still reaches it.
            content.lineLimit(lines.lowerBound...)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { written = $0 }
        }
        .frame(height: min(max(written, least), most))
        .scrollDisabled(written <= most)
    }
}

extension View {
    /// The field grows with its text to `lines.upperBound` lines and then scrolls (`GrowingField`).
    func growingField(_ lines: ClosedRange<Int>, line: CGFloat = ChatStyle.line) -> some View {
        modifier(GrowingField(lines: lines, line: line))
    }
}

struct Rule: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(FleetStyle.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

/// The edge of a side menu, which the owner drags to set the menu's width. Nothing new is drawn: the hairline beside
/// the menu stays the only line, and the pointer turns into the column-resize arrows over a strip 8 points wide on
/// it. It lies over the menu, so it knows the width the menu shows, which a narrow window can make smaller than the
/// one he set: a drag starts from what he sees.
struct SideEdge: View {
    /// Where the menu stands: `.leading` for the window's sidebar, `.trailing` for the panel at the right. A drag
    /// toward the page makes the menu wider.
    let menu: HorizontalEdge
    @Binding var width: Double
    let range: ClosedRange<CGFloat>
    @State private var start: Double?
    /// The window's zoom (View › Bigger): the drag is measured in the window's points, the width in the page's.
    @Environment(\.viewZoom) private var zoom

    var body: some View {
        GeometryReader { shown in
            Color.clear.frame(width: 8).contentShape(Rectangle())
                .pointerStyle(.columnResize)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? Double(shown.size.width)
                        start = from
                        let moved = Double((menu == .leading ? drag.translation.width : -drag.translation.width) / zoom)
                        width = min(Double(range.upperBound), max(Double(range.lowerBound), from + moved))
                    }
                    .onEnded { _ in start = nil })
                // Five points on the menu and three over the hairline and the page: the strip is where the eye puts
                // the edge, and it keeps off the page's own scroll bar.
                .offset(x: menu == .leading ? 3 : -3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: menu == .leading ? .trailing : .leading)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// A side menu of the window: as wide as the owner set it, with the edge he drags to set it (`SideEdge`). In a
    /// narrow window it gives up width, down to the least of its range, before the page beside it does.
    func sideMenu(_ menu: HorizontalEdge, width: Binding<Double>, range: ClosedRange<CGFloat>) -> some View {
        frame(minWidth: range.lowerBound, maxWidth: min(range.upperBound, max(range.lowerBound, CGFloat(width.wrappedValue))))
            .overlay { SideEdge(menu: menu, width: width, range: range) }
            .layoutPriority(1)
            .zIndex(1)
    }
}

/// The count of a sidebar row, as an unread count is: the number in a small capsule at the right of the row. It
/// shows only while there is something to count. **A grey pill** (the owner's yes of 28 October 2026, D-8): violet is
/// what he can press and the brand's mark, and a count is neither.
struct SidebarBadge: View {
    let count: Int
    /// What the number means, for the hover text and for assistive apps.
    let words: String
    var body: some View {
        if count > 0 {
            Text("\(count)").font(FormMetrics.detailTitle).monospacedDigit()
                .foregroundStyle(FleetStyle.text).rolls(count)
                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                // Lighter than the selected row's fill, so it reads on the row it counts for when that row is open.
                .background(Color.white.opacity(0.12), in: Capsule(style: .circular))
                .help(words).accessibilityHidden(true)
        }
    }
}

struct StatusLabel: View {
    let text: String
    var color: Color = FleetStyle.muted
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(FormMetrics.detail)
        }.foregroundStyle(color)
    }
}

struct DetailField: View {
    let title: String
    let value: String
    /// The agent the value names — the task panel's Agent and Asked by — whose glyph stands before it (`AgentNamed`).
    var agent: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            AgentNamed(agent: agent) {
                Text(value).font(FormMetrics.detail).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// **The agent's 16-point glyph before the words that name it, where a request or a task names it** (the owner's yes
/// of 28 October 2026, D-8, as Grok Bot names a bot with its avatar in every list): "✦ From Manager" on a request, the
/// Agent and Asked by of a task. A name that is no agent of the hub — the owner, an agent gone — keeps its words alone.
struct AgentNamed<Words: View>: View {
    let agent: String?
    private let words: Words
    @Environment(\.glyphTeam) private var team

    init(agent: String?, @ViewBuilder words: () -> Words) { self.agent = agent; self.words = words() }

    var body: some View {
        if let agent, team.contains(agent) {
            HStack(alignment: .center, spacing: 6) {
                AgentGlyph(name: agent, size: GlyphSize.inline)
                words
            }
        } else {
            words
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    /// A state that fills the window (the first connection) stands in the middle of it; one inside a
    /// list or a page stays at the left, where its rows begin.
    var centered = false
    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: centered ? 10 : 8) {
            Image(systemName: symbol).font(IconMetrics.symbol(centered ? 30 : 22)).foregroundStyle(FleetStyle.muted)
            Text(title).font(FormMetrics.title)
            Text(detail).foregroundStyle(FleetStyle.muted).lineSpacing(3)
                .multilineTextAlignment(centered ? .center : .leading)
        }.frame(maxWidth: centered ? 340 : .infinity, alignment: centered ? .center : .leading)
            .padding(18)
            .frame(maxWidth: centered ? .infinity : nil, maxHeight: centered ? .infinity : nil, alignment: .center)
    }
}

struct FoldRow<Content: View>: View {
    let title: String
    let symbol: String
    var status: String = ""
    var statusColor: Color = FleetStyle.muted
    /// A row of a task thread: the chat's font and its light gray (`ChatStyle`).
    var chat = false
    @ViewBuilder let content: () -> Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: chat ? 10 : 9) {
                    Image(systemName: symbol).frame(width: chat ? 17 : 15, height: chat ? 17 : 15)
                    Text(title).multilineTextAlignment(.leading)
                    if !status.isEmpty {
                        Spacer(minLength: 8)
                        Text(status).font(chat ? ChatStyle.detail : FormMetrics.detail).foregroundStyle(statusColor)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(IconMetrics.symbol(chat ? 10 : 9))
                    if status.isEmpty { Spacer(minLength: 0) }
                }.font(chat ? ChatStyle.font : FormMetrics.detail).foregroundStyle(chat ? ChatStyle.activity : FleetStyle.muted)
                    // The click reaches over and under the line (`IconMetrics.reach`); the thread keeps its rhythm.
                    .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).accessibilityLabel(title)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                content().padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                    .transition(.identity)
            }
        }.transaction { $0.animation = nil }
    }
}

func fleetDate(_ timestamp: Double?) -> String {
    guard let timestamp else { return String(l10n: "Not reported") }
    return Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
}

extension View {
    /// The column that every screen stands in: one width and one pair of margins, in the middle of what the window
    /// leaves. A page takes it from `FleetPage` and never sets it itself; the Tasks board's is all that the window
    /// leaves (`wide`).
    func fleetColumn(wide: Bool = false) -> some View { column(wide ? nil : FleetStyle.pageWidth) }

    /// The narrower column of a conversation and of a task thread, which are no pages: there the measure is the
    /// length of a line of prose.
    func chatColumn() -> some View { column(FleetStyle.readingWidth) }

    /// The column of what stands over a page: the page's own, or the one of prose over a conversation.
    func fleetColumn(reading: Bool) -> some View { column(reading ? FleetStyle.readingWidth : FleetStyle.pageWidth) }

    private func column(_ width: CGFloat?) -> some View { modifier(PageColumn(width: width)) }
}

extension EnvironmentValues {
    /// **How far a page's column is pulled back to the left: half of the page's own sidebar** (agent details,
    /// Settings), so that such a page stands its title and its header's button where every other page has them. They
    /// jumped 110 pt between, say, Agents and Settings (the capture of 28 October 2026: the title at x = 889 on the
    /// main pages and at 999 beside a page sidebar, at 2560 pt). The page that draws a sidebar sets it.
    @Entry var columnPull: CGFloat = 0
    /// The rows stand in a page's own sidebar, on the canvas and not on the rail (`SidebarFill`).
    @Entry var pageSidebar = false
}

/// The column, in the middle of what the window leaves, pulled back by `columnPull` as far as the free space at its
/// left allows: a narrow window keeps it clear of the page's sidebar. With no width it is all that the window leaves,
/// in the same margins.
private struct PageColumn: ViewModifier {
    let width: CGFloat?
    @Environment(\.columnPull) private var pull

    func body(content: Content) -> some View {
        if let width {
            CenteredColumn(width: width + 2 * FleetSpace.margin, pull: pull) {
                content.frame(maxWidth: width, alignment: .leading).padding(.horizontal, FleetSpace.margin)
            }
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, FleetSpace.margin)
        }
    }
}

private struct CenteredColumn: Layout {
    let width: CGFloat
    let pull: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: min(width, proposal.width ?? width), height: proposal.height))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let column = min(width, bounds.width)
        let free = (bounds.width - column) / 2
        child.place(at: CGPoint(x: bounds.minX + free - min(pull, free), y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: column, height: bounds.height))
    }
}

extension FleetTask {
    /// **A task's state in one word, the same in its panel, over its guidance box, in an agent's panel and on the phone**
    /// (T-12; fix round 2): `TaskWords.state` in FleetCore, with its hold and its agent's usage limit from the fleet's
    /// state. One task read "Limited" in its panel and "Working" over its guidance box at the same moment, and
    /// "Delivered" in its agent's panel where its thread said "Checked".
    func stateWord(in state: HubState?) -> String {
        stateWord(holds: state?.holds ?? [], limited: state?.agents.first(where: { $0.name == owner })?.limit != nil)
    }

    /// Its state word from its own fields alone, with no hold and no usage limit.
    var displayStatus: String { stateWord(holds: [], limited: false) }
}

extension ChatRow {
    /// **The preview line, whose count of more tasks is never cut** (T-25): "Compare our prices with the three main
    /// competitors · +1" ends in "…" before the count, never inside it, so a row with two tasks never reads as one.
    ///
    /// **While the agent works, the same line moves** (`working`): the still line keeps its place and its words for
    /// VoiceOver, clear, and the moving words stand over it in its own room, cut where it is cut. So a row neither
    /// moves nor changes its height when its agent's work starts or ends.
    @ViewBuilder func previewLine(_ preview: String) -> some View {
        let parts = Self.splitCount(preview)
        let still = HStack(spacing: 0) {
            Text(parts.text).lineLimit(1).truncationMode(.tail)
            if let count = parts.count { Text(count).lineLimit(1).fixedSize() }
        }
        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        if working && !reduceMotion {
            still.opacity(0).overlay(alignment: .leading) {
                ShimmeringWords(text: parts.text, tail: parts.count, fits: true).accessibilityHidden(true)
            }
        } else {
            still
        }
    }

    /// The line's own words and its trailing " · +n", when it has one.
    static func splitCount(_ preview: String) -> (text: String, count: String?) {
        guard let range = preview.range(of: #" · \+\d+$"#, options: .regularExpression) else { return (preview, nil) }
        return (String(preview[..<range.lowerBound]), String(preview[range]))
    }
}
