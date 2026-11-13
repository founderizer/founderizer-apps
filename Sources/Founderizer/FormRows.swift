import AppKit
import SwiftUI

// The owner's page and form pattern, after the Codex Settings references: a large page title, a page sidebar with
// icons in place of tabs, a heading over one soft rounded card, and rows that hairlines separate. A row has an optional symbol, its title and a short
// detail at the left and one control at the right. See UI-PATTERNS.md for which control to use and where explicit
// Save stays.

/// The measures of the pattern, from the references.
enum FormMetrics {
    /// **Three corner radii on a screen**, besides capsules and circles: `radius` for a card (a section, a choice, the
    /// card over the page), `inner` for what stands in a card or is chosen in a list (a row's fill, a field, a code
    /// block, an answer), and `ChatStyle.bubbleRadius` for his own message. Ten literal radii, 5 to 20,
    /// put up to six on one screen. The composer of a chat is a capsule (`ComposerCapsule`).
    static let radius: CGFloat = 13
    static let inner: CGFloat = 8
    static let rowInset: CGFloat = 16
    /// **The column every row's leading mark stands in**, and the gap after it: one width and one gap for an SF
    /// Symbol, an agent's glyph, a provider's icon or a service's mark, so a card of symbol rows and a list of
    /// glyph rows begin at the same two x positions.
    ///
    /// The owner, 20 October 2026: "when there are logos, align that to the left". Two things were wrong, and a
    /// mark in a `frame(width:)` had both: the box centres what is in it, so a wide symbol and a narrow one began
    /// at different x, and a glyph that nearly filled the box began at a third. Now the mark is flush to the
    /// leading edge of its column, and the column is the same everywhere.
    static let markColumn: CGFloat = 22
    static let markGap: CGFloat = 12
    /// **The type of a page: three sizes and two weights** (T-23; the owner, 26 October 2026: "try to maintain consistency
    /// in font sizes and font type during this process! it changes so many times!"). The title 26; a heading, a row and
    /// a value 13; every small line 12; medium for a title or a heading, regular for the rest. A chat takes `ChatStyle`,
    /// a setup step `SetupMetrics` and an icon `IconMetrics.symbol`: no view writes a size of its own, which is how one
    /// app came to show 19 sizes from 8 to 44 points.
    static let pageTitle = Font.system(size: 26, weight: .medium)
    /// A row's title, a card's title, the head of a page's own sidebar ("Settings", an agent's name), a plan's name.
    static let title = Font.system(size: 13, weight: .medium)
    /// A row's words, a value, a field's words.
    static let text = Font.system(size: 13)
    /// A detail, a footer, a time, a T-number, a table's small words, a count.
    static let detail = Font.system(size: 12)
    /// A section's heading over its card: a row title's size (it was 13.5, a size of its own).
    static let heading = Font.system(size: 13, weight: .medium)
    /// The head of a few details ("Subtasks", "What it needs from you"), and the word of a small mark ("New").
    static let detailTitle = Font.system(size: 12, weight: .medium)
    /// Code on a page: a command, its output, a file's text, a fingerprint, a request's id. A chat keeps its own
    /// (`ChatStyle.code`); a name in code on a row (a secret's variable) takes the row's size, monospaced.
    static let code = Font.system(size: 12, design: .monospaced)
    /// **A code he types elsewhere**, a provider's sign-in code or a phone's pairing code, at the size of the page's
    /// title, as a setup step shows Codex's code at its own title's (`SetupMetrics.codeFont`). A chat app's link
    /// message, which he copies or sends from its QR code, is a row's words: `title`. **In the app's own typeface,
    /// never monospaced** (the owner, 10 November 2026: no "console" font where he pastes or reads a key or a code).
    static let oneTimeCode = Font.system(size: 26, weight: .medium)

    /// A form's words on a setup step, at the step's one size (`stepText`); nil on a page, where they keep the page's.
    static func onStep(_ size: CGFloat?, weight: Font.Weight = .regular) -> Font? {
        size.map { .system(size: $0, weight: weight) }
    }
    /// A capsule's words, medium: 13 on a page, and the step's 15 on a setup step (`fleetButtonText`).
    static func button(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
    /// **The one height of a control**: every capsule button, a select's capsule and a one-line field, on a page and on
    /// a setup step alike. Capsules came out 26 on a page, 27 with a symbol and 32.2 on a setup step, and two buttons of
    /// one kind that differ read as a mistake.
    static let control: CGFloat = 28
    /// **The one height of a heading row**, a section's and every heading of its own over a card (fix round 3, item 5):
    /// a control's, so a heading with a capsule and one without stand as far from their card. Five headings of their own
    /// stood 14 points from their card where every section's stood 20.
    static let headingRow: CGFloat = control
    /// **The two heights of a form row**: one line, and a title with its detail (or its warning) under it, whatever
    /// the control at the right. One card had rows of 44.5, 48, 49 and 57 points, because a capsule added its own
    /// height to the row's padding.
    static let row: CGFloat = 44, twoLineRow: CGFloat = 56
    /// **The least room of a row's detail beside its control**, or the detail's own width where it is shorter: with
    /// less, the control goes under the title and the detail has the row's width (fix round 2, item 101). "As the
    /// installer shows it, for example 192.168.1.42." stood in about 67 points at 960, in six lines, its address
    /// broken in two.
    static let detailRoom: CGFloat = 120
    /// **Where the heading of a page's own sidebar begins** — "Settings", an agent's name — from the window's top: on the
    /// page title's line, its baseline on the title's (the margins of 30 October 2026, row 3, with the owner's crop:
    /// "Settings" stood 22 pt over that line). The title's line begins `FleetSpace.top` under the band, and the title's font
    /// rises higher over its baseline than the heading's.
    static let sidebarHeadingTop: CGFloat = FleetSpace.lights + FleetSpace.top
        + NSFont.systemFont(ofSize: 26, weight: .medium).ascender - NSFont.systemFont(ofSize: 13, weight: .medium).ascender
    /// **The width of a form page's cards and of its header** (the owner's yes of 28 October 2026, D-8): its title stands
    /// where every page has it, and its header and cards take 680 points from the same left edge, with the free room at
    /// their right. At 2560 points "Tell me when I am needed" stood 1,036 points from its switch; Grok Bot keeps a label
    /// 501 points from its control, ChatGPT 572 and Muse about 627. The header kept the column's 1,100 until 5 November
    /// 2026, so Add URL and Add file stood 420 points past the cards' edge on Settings › Knowledge. Boards and tables
    /// keep the page's 1,100 (`FleetPage(board:)`).
    static let formWidth: CGFloat = 680
}

/// A titled group of form rows in one rounded card. Rows that conditions leave out take no space and no hairline;
/// with no rows, the section shows no card. The detail is one muted line under the heading. The accessory, such as
/// a New button, sits at the right of the heading.
struct FormSection<Content: View, Accessory: View>: View {
    private let title: String?
    private let detail: String?
    private let footer: String?
    /// **A long list makes only the rows that are on the screen** (`AccessSettings`). Settings › Apps made all 213
    /// repositories of the owner's fleet at once, about 200 ms of the main thread when it opened, and made them again
    /// at each reading of the hub, every 3 seconds (10 November 2026). The card looks the same either way.
    private let lazy: Bool
    private let content: Content
    private let accessory: Accessory
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.formMeasure) private var measure
    @Environment(\.cardFill) private var cardFill
    @Environment(\.stepText) private var stepText

    @_disfavoredOverload
    init(_ title: String? = nil, detail: String? = nil, footer: String? = nil, lazy: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.detail = detail; self.footer = footer; self.lazy = lazy
        self.content = content(); self.accessory = accessory()
    }

    var body: some View {
        let section = VStack(alignment: .leading, spacing: 10) {
            // **A heading row only where it says something** (fix round 3, item 5): a section with no title and an
            // accessory with nothing to show stood an empty 38-pt band over its card (Settings › Secrets).
            Group(subviews: accessory) { accessories in
                if title != nil || !accessories.isEmpty {
                    // **One height for a heading row, with or without its capsule** (fix round 2): the control's 28
                    // points, the words in its middle (`FormMetrics.headingRow`). A heading that held a capsule stood 6
                    // points farther from its card than one that did not.
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let title {
                                Text(title).font(FormMetrics.onStep(stepText, weight: .medium) ?? FormMetrics.heading)
                                    .foregroundStyle(FleetStyle.text).accessibilityAddTraits(.isHeader)
                            }
                            if let detail {
                                Text(detail).font(FormMetrics.onStep(stepText) ?? FormMetrics.detail)
                                    .foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        ForEach(accessories) { accessory in accessory }
                    }.frame(minHeight: FormMetrics.headingRow).padding(.leading, 2)
                }
            }
            Group(subviews: content) { rows in
                if !rows.isEmpty {
                    stack(rows)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardFill, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
                        .strokeBorder(FleetStyle.hairline(0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
                    .environment(\.onCard, true)
                }
            }
            if let footer {
                Text(footer).font(FormMetrics.onStep(stepText) ?? FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
        // On a form page the section — its heading, its card and its footer — takes the form's width from the page's
        // left edge (`formMeasure`); anywhere else (a board, the status panel, a card over the page) all it is given.
        if let measure {
            section.frame(maxWidth: measure, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            section
        }
    }

    /// The card's rows, one under the other, with a hairline between two: all of them, or only the ones on the screen
    /// (`lazy`), where each row and the hairline over it are one view, so that the two come and go together.
    @ViewBuilder private func stack(_ rows: SubviewsCollection) -> some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        if row.id != rows.first?.id { Rule().padding(.horizontal, FormMetrics.rowInset) }
                        row
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Rule().padding(.horizontal, FormMetrics.rowInset) }
                    row
                }
            }
        }
    }
}

extension FormSection where Accessory == EmptyView {
    @_disfavoredOverload
    init(_ title: String? = nil, detail: String? = nil, footer: String? = nil, lazy: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.init(title, detail: detail, footer: footer, lazy: lazy, content: content) { EmptyView() }
    }
}

/// One form row: an optional symbol, the title, an optional short detail and an optional warning with its next step
/// at the left, and one control or value at the right.
struct FormRow<Control: View>: View {
    private let title: String
    private let symbol: String?
    /// A leading mark that is not an SF Symbol: a provider's icon, a service's mark, a brand mark.
    private let mark: AnyView?
    private let detail: String?
    private let warning: String?
    private let control: Control
    @Environment(\.stepText) private var stepText

    @_disfavoredOverload
    init(_ title: String, symbol: String? = nil, detail: String? = nil, warning: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.symbol = symbol; self.mark = nil
        self.detail = detail; self.warning = warning; self.control = control()
    }

    /// The same row with a drawn mark in place of a symbol — a provider's icon on an account row, for one. It
    /// stands in `RowMark`, the one column every leading mark stands in.
    @_disfavoredOverload
    init(_ title: String, mark: some View, detail: String? = nil, warning: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.symbol = nil; self.mark = AnyView(mark)
        self.detail = detail; self.warning = warning; self.control = control()
    }

    /// The title, then a detail and a warning when they have words: only a warning adds a line to a row with a detail.
    private var lines: Int { [detail, warning].reduce(1) { $0 + ($1?.isEmpty == false ? 1 : 0) } }
    /// A row title: 13 points on a page, the step's 15 on a setup step (`stepText`), medium.
    private var titleFont: Font { FormMetrics.onStep(stepText, weight: .medium) ?? FormMetrics.title }

    /// The row's leading mark, in the one column every mark stands in.
    @ViewBuilder private var leading: some View {
        if let mark {
            RowMark { mark }.accessibilityHidden(true)
        } else if let symbol {
            RowMark { Image(systemName: symbol).font(IconMetrics.symbol(15)).foregroundStyle(FleetStyle.text) }
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        // **A control that does not fit beside its title goes under it** (T-17), where a capsule wrapped its words
        // or pushed the card past the window's edge at 960 points. The title and the control have to fit, and the
        // detail needs `FormMetrics.detailRoom` of the room they leave, or its own width where it is shorter; it wraps
        // in the rest, so a wide window keeps every row as it was.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 0) {
                leading
                // The words keep their room over and under them, and the control centres in the row: a 28-point
                // capsule, a switch and a value give one height. A control taller than the row keeps 8 points over
                // and under it.
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(titleFont).foregroundStyle(FleetStyle.text)
                    if lines > 1 { DetailRoom { FormNotes(detail: detail, warning: warning) } }
                }.padding(.vertical, 10)
                Spacer(minLength: 16)
                control.padding(.vertical, 8)
            }
            HStack(alignment: .top, spacing: 0) {
                leading
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(titleFont).foregroundStyle(FleetStyle.text)
                    FormNotes(detail: detail, warning: warning)
                    control.padding(.top, 5)
                }.padding(.vertical, 10)
                Spacer(minLength: 0)
            }
        }
        .font(FormMetrics.onStep(stepText) ?? FormMetrics.text)
        .padding(.horizontal, FormMetrics.rowInset)
        .frame(minHeight: lines > 1 ? FormMetrics.twoLineRow : FormMetrics.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

extension FormRow where Control == EmptyView {
    @_disfavoredOverload
    init(_ title: String, symbol: String? = nil, detail: String? = nil, warning: String? = nil) {
        self.init(title, symbol: symbol, detail: detail, warning: warning) { EmptyView() }
    }

    @_disfavoredOverload
    init(_ title: String, mark: some View, detail: String? = nil, warning: String? = nil) {
        self.init(title, mark: mark, detail: detail, warning: warning) { EmptyView() }
    }
}

/// **A row's leading mark**, in the one column every leading mark stands in, flush to that column's leading edge.
/// Use it wherever a row begins with a symbol, an agent's glyph, a provider's icon or a brand mark, so that every
/// list in the app starts its marks and its titles at the same two places.
struct RowMark<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(width: FormMetrics.markColumn, alignment: .leading)
            .padding(.trailing, FormMetrics.markGap)
    }
}

extension EnvironmentValues {
    /// What stands here is on a card (`FormSection`), where a field's fill is a step lighter than on the canvas.
    @Entry var onCard = false
    /// The fill of a `FormSection`'s card: a page's surface, and a step lighter on the rail of a side panel
    /// (`FleetStyle.chrome`), so a card stands out from what it stands on (fix round 2).
    @Entry var cardFill: Color = FleetStyle.surface
    /// **On a setup step, the size of every line under its title** (`SetupMetrics.text`, his two sizes of one typeface;
    /// fix round 2): a section's heading, a row's title, its detail, a footer and a field's words there, which were a
    /// page's 13.5, 13 and 12 beside the step's 15. Nil on a page.
    @Entry var stepText: CGFloat? = nil
    /// The width a section's card takes on this page: `FormMetrics.formWidth` on a form page, nil on a board or a
    /// table and outside a page (`FleetPage`).
    @Entry var formMeasure: CGFloat?
}

extension View {
    /// **A field's own placeholder, in the muted words that read, while the field is empty** (fix round 3, item 3): AppKit's
    /// field draws a prompt in its own placeholder grey whatever colour SwiftUI gives it — 2.25:1 on the field ("Search",
    /// "Their name", "Bot token"), and fainter still with the cursor in it — so such a field gives AppKit an empty prompt
    /// and these words stand where its words start, as the composer's do. Put it on the field before its font and its
    /// box (`setupField`), so the two share them. The field keeps its label, which VoiceOver reads.
    func fieldPlaceholder(_ words: String, shows: Bool) -> some View {
        overlay(alignment: .leading) {
            if shows {
                Text(words).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

/// **The look of every one-line field of the app**: one box of one height (`FormMetrics.control`), a little lighter than
/// what it stands on, a hairline, the words at its left, and a ring in the brand's violet while it has the cursor —
/// at full strength, which the eye finds (3.4:1 on a card), where the violet at 0.55 measured 1.9:1. **The whole box
/// takes the click**: only the line of words inside it did, so a click on its edge went nowhere. It replaced the
/// stock bezel and seven looks of field, from 16 to 51 points high, that one form could show side by side. On a setup
/// step it is the same field in the step's size (`setupField`).
struct FleetFieldLook: ViewModifier {
    /// The cursor's state where the caller keeps it; the field keeps its own where none is given.
    var focus: FocusState<Bool>.Binding?
    /// What it holds is no answer: an orange edge (a setup step's code or name).
    var wrong = false
    /// The words' size and the box's height: a row's, or a setup step's. Nil words take the place's (`stepText`).
    var text: CGFloat? = nil, height: CGFloat = FormMetrics.control
    @FocusState private var own: Bool

    func body(content: Content) -> some View {
        let focused = focus ?? $own
        content
            .focused(focused)
            .modifier(FleetFieldBox(focused: focused.wrappedValue, wrong: wrong, text: text, height: height))
            .onTapGesture { focused.wrappedValue = true }
    }
}

/// The box of a field (`FleetFieldLook`), drawn from what the field says about its cursor.
struct FleetFieldBox: ViewModifier {
    let focused: Bool
    var wrong = false
    /// The words' size: nil for a row's 13, or the setup step's 15 where the field stands on one (`stepText`).
    var text: CGFloat? = nil, height: CGFloat = FormMetrics.control
    @Environment(\.onCard) private var onCard
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.stepText) private var stepText

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: FormMetrics.inner)
        content
            .textFieldStyle(.plain)
            .font(FormMetrics.onStep(text ?? stepText) ?? FormMetrics.text)
            .multilineTextAlignment(.leading)
            .lineLimit(1)
            .focusEffectDisabled()
            .padding(.horizontal, height > FormMetrics.control ? 14 : 10)
            .frame(height: height)
            // **Its edge and its focus ring read 3:1** (T-30, fix round): the edge white 0.32 — 3.1:1 against a card and
            // 3.3:1 on the canvas, where white 0.10 read 1.7:1 and the stock bezel had read 4.3:1 — and on a card a
            // fill of 0.035, against which the violet ring reads 3.05:1 (2.72:1 against 0.07).
            .background(Color.white.opacity(onCard ? 0.035 : 0.05), in: shape)
            .overlay(shape.strokeBorder(wrong ? Color.orange.opacity(0.8) : focused ? FleetStyle.accent : FleetStyle.hairline(0.32),
                                        lineWidth: wrong || focused ? 1 : FleetStyle.edgeWidth(contrast)))
            .contentShape(shape)
    }
}

extension View {
    /// A one-line field (`TextField` or `SecureField`) in the one look of the app's fields (`FleetFieldLook`). Give it
    /// the cursor's state where the form moves the cursor itself; a font set on the field before it stays.
    func fleetField(focus: FocusState<Bool>.Binding? = nil, wrong: Bool = false) -> some View {
        modifier(FleetFieldLook(focus: focus, wrong: wrong))
    }

    /// The same field in a form that keeps one cursor state for its fields (`focused(_:equals:)`).
    func fleetField<Value: Hashable>(focus: FocusState<Value?>.Binding, equals value: Value, wrong: Bool = false) -> some View {
        focused(focus, equals: value)
            .modifier(FleetFieldBox(focused: focus.wrappedValue == value, wrong: wrong))
            .onTapGesture { focus.wrappedValue = value }
    }

    /// **A box of several lines (`TextEditor`) in the one look of the app's fields** (fix round 3, item 56; T-30): the
    /// field's fill, its edge that reads 3:1, the violet ring while it has the cursor, its radius, and 7 points of room
    /// around its words, which take the click too. Four boxes kept a look of their own — Report a problem's text, a
    /// person's note, a role's prompt and Add person's note: a hairline of 1.1–1.2:1, and the note's ring at 0.55, 1.9:1.
    /// Give it the cursor's state where the form moves the cursor itself; set its height after it.
    func fleetTextBox(focus: FocusState<Bool>.Binding? = nil) -> some View {
        modifier(FleetTextBoxLook(focus: focus))
    }

    /// The same box in a form that keeps one cursor state for its fields (`focused(_:equals:)`).
    func fleetTextBox<Value: Hashable>(focus: FocusState<Value?>.Binding, equals value: Value) -> some View {
        focused(focus, equals: value)
            .modifier(FleetTextBoxFrame(focused: focus.wrappedValue == value) { focus.wrappedValue = value })
    }
}

/// The cursor of a box of several lines (`fleetTextBox`): the caller's, or its own.
struct FleetTextBoxLook: ViewModifier {
    var focus: FocusState<Bool>.Binding?
    @FocusState private var own: Bool

    func body(content: Content) -> some View {
        let focused = focus ?? $own
        content.focused(focused)
            .modifier(FleetTextBoxFrame(focused: focused.wrappedValue) { focused.wrappedValue = true })
    }
}

/// The box of a box of several lines (`fleetTextBox`), drawn as a one-line field's box (`FleetFieldBox`).
struct FleetTextBoxFrame: ViewModifier {
    let focused: Bool
    let takeCursor: () -> Void
    @Environment(\.onCard) private var onCard
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: FormMetrics.inner)
        content
            .scrollContentBackground(.hidden)
            .padding(7)
            // The room around the words gives the box the cursor; the words take their own clicks.
            .background { shape.fill(Color.white.opacity(onCard ? 0.035 : 0.05)).contentShape(shape).onTapGesture(perform: takeCursor) }
            .overlay(shape.strokeBorder(focused ? FleetStyle.accent : FleetStyle.hairline(0.32),
                                        lineWidth: focused ? 1 : FleetStyle.edgeWidth(contrast)).allowsHitTesting(false))
    }
}

/// **A choice of two or three, side by side**, in place of the stock segmented control, which drew a rectangle 24
/// points high among 28-point capsules: a capsule track of the controls' one height with the chosen part filled.
struct FleetSegmented<Value: Hashable>: View {
    private let title: String
    @Binding private var selection: Value
    private let options: [FleetOption<Value>]
    @Environment(\.onCard) private var onCard
    @Environment(\.colorSchemeContrast) private var contrast

    @_disfavoredOverload
    init(_ title: String, selection: Binding<Value>, options: [FleetOption<Value>]) {
        self.title = title; self._selection = selection; self.options = options
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button { selection = option.value } label: {
                    // **The chosen part reads 3:1 against its track, and its words 4.5:1 on it** (T-30, fix round): a
                    // light part with dark words, 10:1 and 15:1, where white 0.14 under light words read 1.57:1.
                    Text(option.title).font(FormMetrics.title).lineLimit(1)
                        .foregroundStyle(chosen ? FleetStyle.ink : FleetStyle.muted)
                        .padding(.horizontal, 12).frame(maxHeight: .infinity)
                        .background(chosen ? FleetStyle.text : .clear, in: Capsule(style: .circular))
                        .contentShape(Capsule(style: .circular))
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: FormMetrics.control)
        .background(Color.white.opacity(onCard ? 0.07 : 0.05), in: Capsule(style: .circular))
        .overlay(Capsule(style: .circular).strokeBorder(FleetStyle.hairline(0.10), lineWidth: FleetStyle.edgeWidth(contrast)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A form row with full-width content under its title: text editors, checkbox lists and check results. The
/// accessory, such as a remove button, sits at the right of the title.
struct FormBlock<Content: View, Accessory: View>: View {
    private let title: String
    private let detail: String?
    private let content: Content
    private let accessory: Accessory
    @Environment(\.stepText) private var stepText

    @_disfavoredOverload
    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.detail = detail; self.content = content(); self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(FormMetrics.onStep(stepText, weight: .medium) ?? FormMetrics.title)
                        .foregroundStyle(FleetStyle.text)
                    FormNotes(detail: detail, warning: nil)
                }
                Spacer(minLength: 16)
                accessory
            }
            content
        }
        .font(FormMetrics.onStep(stepText) ?? FormMetrics.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

extension FormBlock where Accessory == EmptyView {
    @_disfavoredOverload
    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, detail: detail, content: content) { EmptyView() }
    }
}

/// The empty state of a card: a symbol, one sentence and an optional main action, in the center.
struct FormEmpty<Action: View>: View {
    private let symbol: String
    private let text: String
    private let action: Action
    /// **The mark draws itself, and the words come after it** (Needs you, when his answer sent the last request away;
    /// the owner's yes of 11 November 2026 to its moving picture). Every other empty state stands at once. It is
    /// what the page said when the state first showed: a later change of it does not cut the drawing short.
    @State private var draws: Bool
    @State private var drawn = false
    @State private var said = false

    @_disfavoredOverload
    init(_ text: String, symbol: String, draws: Bool = false, @ViewBuilder action: () -> Action) {
        self.text = text; self.symbol = symbol; _draws = State(initialValue: draws); self.action = action()
    }

    var body: some View {
        let mark = Image(systemName: symbol).font(IconMetrics.symbol(22, weight: .light)).foregroundStyle(FleetStyle.text).accessibilityHidden(true)
        VStack(spacing: 12) {
            if draws {
                mark.hidden().overlay { if drawn { mark.transition(.drawsOn) } }
            } else {
                mark
            }
            Text(text).font(FormMetrics.text).foregroundStyle(FleetStyle.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).opacity(draws && !said ? 0 : 1)
            action
        }.frame(maxWidth: .infinity).padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 26)
        .task {
            guard draws, !drawn else { return }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeInOut(duration: 0.8)) { drawn = true }
            try? await Task.sleep(for: .milliseconds(640))
            withAnimation(.easeOut(duration: 0.32)) { said = true }
        }
    }
}

extension FormEmpty where Action == EmptyView {
    @_disfavoredOverload
    init(_ text: String, symbol: String, draws: Bool = false) { self.init(text, symbol: symbol, draws: draws) { EmptyView() } }
}

/// **The room a row's detail and warning ask for beside its control** (`FormMetrics.detailRoom`): what `ViewThatFits`
/// measures them by. Laid out, they are the lines they always were, three points apart, in the room the row gives them.
private struct DetailRoom: Layout {
    private let spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(proposal) }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: proposal.width == nil ? min(width, FormMetrics.detailRoom) : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var top = bounds.minY
        for subview in subviews {
            let room = ProposedViewSize(width: bounds.width, height: nil)
            subview.place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading, proposal: room)
            top += subview.sizeThatFits(room).height + spacing
        }
    }
}

/// The secondary lines under a row title: a muted detail and an orange warning that can be copied.
private struct FormNotes: View {
    let detail: String?
    let warning: String?
    @Environment(\.stepText) private var stepText

    var body: some View {
        if let detail, !detail.isEmpty {
            Text(detail).font(FormMetrics.onStep(stepText) ?? FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let warning, !warning.isEmpty {
            Text(warning).font(FormMetrics.onStep(stepText) ?? FormMetrics.detail).foregroundStyle(.orange)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The one head of a page: the title, once, and the page's actions at its right. There is no line under the title,
/// and nowhere to put one: a page says what it is by its name and by what it shows.
struct PageHeader<Actions: View>: View {
    private let title: String
    /// One mark beside the title, where a page's whole state is one mark: a server's page puts its connected tick
    /// there.
    private let mark: AnyView?
    private let actions: Actions

    @_disfavoredOverload
    init(_ title: String, mark: AnyView? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.mark = mark; self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 10) {
                Text(title).font(FormMetrics.pageTitle).foregroundStyle(FleetStyle.text)
                    .accessibilityAddTraits(.isHeader)
                if let mark { mark }
            }
            Spacer(minLength: 8)
            HStack(spacing: FleetSpace.actions) { actions }
        }
    }
}

extension PageHeader where Actions == EmptyView {
    @_disfavoredOverload
    init(_ title: String) { self.init(title) { EmptyView() } }
}

/// The link back to the page that a detail came from, over its title. Its words are 16 points high and its click 28
/// (`IconMetrics.reach`): the room over and under them is the link's, and takes nothing from the page.
struct FleetBack: View {
    private let title: String
    private let action: () -> Void

    @_disfavoredOverload
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(IconMetrics.symbol(11, weight: .semibold))
                Text(title)
            }.font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
                .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach)
            .keyboardShortcut(.cancelAction).accessibilityLabel("Back to \(title)")
    }
}

/// **Every screen of the app is one of these.** It holds the whole standard, so that a page cannot be built another
/// way: one column of one width with one pair of margins, one header — the title once, its actions at the right —
/// and one spacing between the blocks under it. It scrolls when it is taller than the window. A page that needs a
/// detail over it gives that detail to `fleetModal`, which stands over the window, not over the page.
///
/// **A form page's header and cards take 680 points from the column's left edge** (`FormMetrics.formWidth`, D-8): the
/// title stands where every page has it, and the header's actions end where the cards end. A board or a table
/// (`board`, and a page that `fills`) keeps the column's 1,100, and the Tasks board (`wide`) the window's whole width.
///
/// A page passes only its title, its actions and its blocks. Nothing here can be set from outside, because every
/// number that a page could choose is a number that the next page would choose differently.
struct FleetPage<Actions: View, Content: View>: View {
    private let title: String
    private let back: FleetBack?
    /// The mark beside the title (`PageHeader`).
    private let mark: AnyView?
    /// The page's content is as high as the window and scrolls inside itself — the lanes of the Activity board.
    /// Every other page scrolls as a whole, which is what a page of blocks under a title does.
    private let fills: Bool
    /// A board or a table, whose cards take the column's whole width; every other page is a form.
    private let board: Bool
    /// **The page takes the window's whole width, in the column's margins**: the Tasks board, whose lanes share it (the
    /// owner, 2 November 2026, of its lanes in the 1,100-pt column in the middle of his 2,560-pt window: "this page
    /// should be full width").
    private let wide: Bool
    private let actions: Actions
    private let content: Content
    /// The page's loading lines: one draws its words at a time (`LoadingSlots`).
    @State private var loadingSlots = LoadingSlots()

    @_disfavoredOverload
    init(_ title: String, back: FleetBack? = nil, mark: AnyView? = nil, fills: Bool = false, board: Bool = false,
         wide: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.back = back; self.mark = mark; self.fills = fills; self.board = board; self.wide = wide
        self.actions = actions(); self.content = content()
    }

    var body: some View {
        // **A page that scrolls lays out at its own height** (the polish of 30 October 2026): its column is placed at the
        // height it measured, and the stack shared that height out again among its blocks. A long page cut a heading with
        // a detail line back to its 28-pt least height and gave the 7 pt to a text box, so Report a problem's heading moved
        // 3.5 pt and its card 7 when its count came; a row with a long detail lost its room the same way. A page that fills
        // the window keeps the share-out: its lanes take the window's height.
        if fills { column(blocks) } else { ScrollView { column(blocks.fixedSize(horizontal: false, vertical: true)) } }
    }

    /// The header and the page's blocks under it. **On a form page the header takes the cards' width**, so its actions
    /// end where the cards end (the owner, 5 November 2026, of Settings › Knowledge, its Add URL and Add file at the
    /// right of the column's 1,100 points over cards of 680: "either the content needs to be wider or the top buttons
    /// moved"). A board keeps both at the column's width.
    private var blocks: some View {
        let measure = fills || board ? nil : FormMetrics.formWidth
        return VStack(alignment: .leading, spacing: FleetSpace.block) {
            PageHeader(title, mark: mark) { actions }.frame(maxWidth: measure, alignment: .leading)
            content.environment(\.formMeasure, measure)
                .environment(\.loadingSlots, loadingSlots)
        }
    }

    private func column(_ blocks: some View) -> some View {
        blocks.padding(.top, FleetSpace.top).padding(.bottom, FleetSpace.bottom)
            // **The back link has one place, in the band over the title**, at the title's x: so the title and the
            // header's buttons stand where every page has them, with a back link or without: a sub-page dropped both 22
            // points under its link (the capture of 28 October 2026).
            .overlay(alignment: .topLeading) { if let back { back.padding(.top, FleetSpace.back) } }
            .fleetColumn(wide: wide)
    }
}

extension FleetPage where Actions == EmptyView {
    @_disfavoredOverload
    init(_ title: String, back: FleetBack? = nil, fills: Bool = false, board: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.init(title, back: back, fills: fills, board: board, content: content) { EmptyView() }
    }
}

/// A page's own sidebar at the left of its content, in place of tabs: a head (a title, or a back link and the agent),
/// then one row for each section, with its symbol and its title. The selected row has the soft fill of the main
/// sidebar. The app has no horizontal tab bar.
struct PageSidebar<Value: Hashable, Head: View>: View {
    /// `attention`: the words of an orange dot at the row's end, for the hover text.
    struct Item { let value: Value; let title: String; let symbol: String; var attention: String? = nil }
    private let items: [Item]
    private let selection: Value
    private let identifier: String
    private let select: (Value) -> Void
    private let head: Head

    init(items: [Item], selection: Value, identifier: String, select: @escaping (Value) -> Void, @ViewBuilder head: () -> Head) {
        self.items = items; self.selection = selection; self.identifier = identifier; self.select = select; self.head = head()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            head.padding(.horizontal, 10).padding(.bottom, 14)
            ForEach(items, id: \.value) { item in
                SidebarRow(item.title, selected: item.value == selection) { select(item.value) } mark: {
                    SidebarSymbol(name: item.symbol)
                } trailing: {
                    if let attention = item.attention {
                        Circle().fill(Color.orange).frame(width: 6, height: 6).help(attention).accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("\(identifier)-\(item.title.lowercased())")
                .accessibilityValue(item.attention ?? "")
            }
            Spacer(minLength: 0)
        }
        // **It runs to the window's top edge, and its head begins where a page's back link begins** (margins rows 2 and
        // 4), 40 pt from the window's top: an agent's "Back to chat" stands on the line of the page's own "‹ Behaviour".
        .padding(.horizontal, 10).padding(.top, FleetSpace.lights + FleetSpace.back).padding(.bottom, 12)
        // Its own width, and down to 180 points in the narrowest window, where its rows end in "…" (T-17).
        .frame(minWidth: 180, idealWidth: FleetStyle.pageSidebarWidth, maxWidth: FleetStyle.pageSidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Its selected row stands 16 levels over its own ground, as the main sidebar's does (fix round 2, item 23).
        .environment(\.pageSidebar, true)
    }
}

extension View {
    /// **The one modal of the app.** The detail of one item stands in the middle of the whole window, on a dimmed
    /// backdrop: a click outside the card closes it, and so does Esc. The backdrop is the window itself, so it makes
    /// no difference where in a page this modifier sits — a modifier on a section used to dim that section alone and
    /// leave a black frame around it.
    ///
    /// It is a window of its own over the app's window, not a `sheet`: a sheet brings its own frame and its own
    /// colour, which is the second thing a modal must never do.
    func fleetModal<Item: Identifiable, Card: View>(item: Binding<Item?>, @ViewBuilder card: @escaping (Item) -> Card) -> some View {
        background(FleetModalAnchor(card: item.wrappedValue.map { shown in
            AnyView(FleetModalCard(dismiss: { item.wrappedValue = nil }) { card(shown) })
        }, dismiss: { item.wrappedValue = nil }))
    }
}

/// What the modal's own window shows: the dimmed backdrop, which a click closes, and the card in the middle of it.
private struct FleetModalCard<Card: View>: View {
    let dismiss: () -> Void
    @ViewBuilder let card: () -> Card
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            // The window goes dark enough under the card for the card to be the one thing on the screen: the canvas
            // #191919 goes to #080808 and the sidebar #202020 to #0A0A0A (at 0.45 the canvas was #0E0E0E, and the page
            // still read through; at 0.65 the sidebar stayed #0B0B0B, T-41).
            Color.black.opacity(0.69).contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .accessibilityElement().accessibilityLabel("Close").accessibilityAddTraits(.isButton)
                .accessibilityAction { dismiss() }
            ViewThatFits(in: .vertical) {
                card()
                ScrollView { card() }
            }
            .background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(FleetStyle.hairline(0.1), lineWidth: FleetStyle.edgeWidth(contrast)))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
            .accessibilityAddTraits(.isModal)
            .padding(32)
        }.ignoresSafeArea()
        // The card is a window of its own over the app's window, so it takes the zoom he chose itself (View › Bigger).
        .viewZoomed()
    }
}

/// A view of no size that keeps the modal's window over the window it stands in.
private struct FleetModalAnchor: NSViewRepresentable {
    let card: AnyView?
    let dismiss: () -> Void

    func makeNSView(context: Context) -> NSView { ModalHolder() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ModalHolder)?.show(card, dismiss: dismiss)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? ModalHolder)?.show(nil, dismiss: {}) }

    /// It makes the panel on the first showing and keeps it on the window of its own view, over the whole of it.
    private final class ModalHolder: NSView {
        private var panel: ModalPanel?
        private var watching: NSWindow?

        func show(_ card: AnyView?, dismiss: @escaping () -> Void) {
            guard let card else { close(); return }
            guard let host = window else {
                // The view is not in a window yet: try again once it is.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil else { return }
                    self.show(card, dismiss: dismiss)
                }
                return
            }
            let panel = panel ?? makePanel()
            panel.onCancel = dismiss
            panel.content.rootView = card
            follow(host)
            panel.setFrame(host.frame, display: true)
            // **The page's keyboard goes before the panel arrives.** Attaching a child window makes AppKit set up
            // the first responder of the window under it, and that chain can still name a view SwiftUI has already
            // torn down — a field of the page that this modal replaces. SwiftUI then reaches it through an unowned
            // reference and the process aborts: `swift_abortRetainUnowned` under `_makeParentWindowHaveFirstResponder`,
            // which is what took the app down twice on the owner's Mac, once as his saved secret opened its detail
            // (22 October 2026). Nothing of his is lost: a field commits its value as it resigns.
            if panel.parent == nil {
                host.makeFirstResponder(nil)
                host.addChildWindow(panel, ordered: .above)
                // Take focus only when first shown in the active app. Polling can update an open card while
                // another app is in front; that update must leave its keyboard focus alone.
                if NSApp.isActive { panel.makeKeyAndOrderFront(nil) }
            }
        }

        private func makePanel() -> ModalPanel {
            // A regular panel releases keyboard focus when the app becomes inactive. A nonactivating panel
            // can take it while another app stays in front, which made the owner's keyboard stop there.
            let made = ModalPanel(contentRect: .zero, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            made.isOpaque = false
            made.backgroundColor = .clear
            made.hasShadow = false
            made.isMovable = false
            made.animationBehavior = .none
            made.collectionBehavior = [.fullScreenAuxiliary, .transient]
            made.contentView = made.content
            panel = made
            return made
        }

        private func follow(_ host: NSWindow) {
            guard watching !== host else { return }
            stopWatching()
            watching = host
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(hostMoved), name: name, object: host)
            }
        }

        private func stopWatching() {
            if watching != nil { NotificationCenter.default.removeObserver(self) }
            watching = nil
        }

        @objc private func hostMoved() {
            guard let panel, let host = watching else { return }
            panel.setFrame(host.frame, display: true)
        }

        private func close() {
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            panel = nil
            stopWatching()
        }

        /// **Only a view that left its window for good closes the card** (fix round 3, item 19): SwiftUI takes this view
        /// out of the window and puts it back when views before it on the page change — a page's loading lines ending —
        /// and a card opened from Can use while the page still read closed by itself 53 ms after it opened. It closes
        /// when the view is still out of a window after that turn, and follows the window it is put back in.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let host = window {
                guard let panel, panel.parent !== host else { return }
                panel.parent?.removeChildWindow(panel)
                host.addChildWindow(panel, ordered: .above)
                follow(host)
                panel.setFrame(host.frame, display: true)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window == nil else { return }
                    self.close()
                }
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }

    /// The modal's window. It takes the keyboard, so that Esc and the fields of a card work, and gives it back when
    /// the card closes.
    private final class ModalPanel: NSPanel {
        let content = NSHostingView(rootView: AnyView(EmptyView()))
        var onCancel: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel() }
    }
}

// The three kinds of button have one shape: a capsule of one font, height and padding. Under the pointer the fill is
// lighter, and while pressed it is darker.

/// The one main action of a page or an empty state: a white capsule, as the Add button of the references.
struct FleetPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { FleetButton(configuration: configuration, kind: .primary) }
}

/// Every other button, the secondary kind: a dark capsule with a hairline border.
struct FleetOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { FleetButton(configuration: configuration, kind: .secondary) }
}

/// A list row that opens its detail (Secrets, Integrations): the whole row is the button. It is not a capsule: under
/// the pointer the row has a soft fill, and while pressed a stronger one.
struct FleetRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowButton(configuration: configuration) }

    private struct RowButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : hovered && isEnabled ? 0.035 : 0))
                    .padding(.horizontal, 6).padding(.vertical, 3))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// A card that is a choice of its own: the surface of a form card, which lifts a little under the pointer and
/// presses in. Two of them side by side are a choice a person can see at once (the first-run wizard).
struct FleetCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CardButton(configuration: configuration) }

    private struct CardButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: FormMetrics.radius)
                    .fill(FleetStyle.surface)
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
                        .strokeBorder(hovered && isEnabled ? FleetStyle.accent.opacity(0.55) : FleetStyle.line,
                                      lineWidth: hovered && isEnabled ? 1 : FleetStyle.edgeWidth(contrast))))
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// A destructive action: red text on a red-tinted capsule, apart from the normal controls.
struct FleetDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { FleetButton(configuration: configuration, kind: .danger) }
}

extension EnvironmentValues {
    /// The size of a capsule button's words: 13 on a page, the size of a row's words (the owner's yes of 28 October
    /// 2026, D-8: it was 12.5, so a page showed 26 / 13 / 12.5 / 12 / 10.5), and the size of every other line on a
    /// setup step (`SetupStep`). The capsule keeps its one height (`FormMetrics.control`) for both.
    @Entry var fleetButtonText: CGFloat = 13
}

private struct FleetButton: View {
    enum Kind { case primary, secondary, danger }
    let configuration: ButtonStyleConfiguration
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.fleetButtonText) private var text
    @State private var hovered = false

    var body: some View {
        // The circular style: a hairline on the continuous style draws short stray lines at the two ends.
        let shape = Capsule(style: .circular), hot = hovered && isEnabled, pressed = configuration.isPressed
        let scale = text / 13
        configuration.label
            .font(FormMetrics.button(text))
            .foregroundStyle(foreground)
            // **A capsule's words never wrap** (T-17): at the 960-pt window "Use another account" stood on two lines
            // and "Choose the .pem file" on three. A row whose control does not fit puts it under its title (`FormRow`).
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            // One height whatever the size of the words: 13 points on a page and 15 on a setup step both stand in 28
            // points.
            .padding(.horizontal, 13 * scale).padding(.vertical, 4)
            .frame(minHeight: FormMetrics.control)
            .background(fill(hot: hot, pressed: pressed), in: shape)
            .overlay { if kind == .secondary { shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5) } }
            .opacity(kind == .primary || isEnabled ? 1 : kind == .secondary ? 0.6 : 0.5)
            .contentShape(shape)
            .onHover { hovered = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color.black.opacity(isEnabled ? 0.92 : 0.5)
        case .secondary: isEnabled ? FleetStyle.text : FleetStyle.muted
        case .danger: Color(red: 0.93, green: 0.42, blue: 0.38)
        }
    }

    private func fill(hot: Bool, pressed: Bool) -> Color {
        switch kind {
        case .primary: Color.white.opacity(pressed ? 0.78 : !isEnabled ? 0.5 : hot ? 1 : 0.94)
        case .secondary: pressed ? FleetStyle.bubble : hot ? Color(white: 0.165) : FleetStyle.surface
        case .danger: Color(red: 0.86, green: 0.25, blue: 0.22).opacity(pressed ? 0.3 : hot ? 0.24 : 0.18)
        }
    }
}
