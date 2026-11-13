import AppKit
import FleetCore
import SwiftUI

/// The measures of a centered setup step. **Two sizes of one typeface on every page of a setup** (the owner, 26
/// October 2026: "try to maintain consistency in font sizes and font type during this process! it changes so many
/// times!"): the title, and everything under it.
enum SetupMetrics {
    /// The title of a step, the moving words of one that waits, and Codex's code.
    static let title: CGFloat = 22
    /// Everything under the title: a line, a link, the field, a button and a provider's card.
    static let text: CGFloat = 15
    /// The two sizes as type (T-23): the title, semibold; everything under it; a choice's name on its card, medium; a
    /// field or a line that holds an address, monospaced; and Codex's code, at the title's size. A key or a token that
    /// he pastes takes the step's own words (`PasteField`), never this monospaced font.
    static let titleFont = Font.system(size: title, weight: .semibold)
    static let textFont = Font.system(size: text)
    static let choiceFont = Font.system(size: text, weight: .medium)
    static let monoFont = Font.system(size: text, design: .monospaced)
    static let codeFont = Font.system(size: title)
    /// The mark over the title: a provider's icon or an agent's glyph, at the glyph's largest size.
    static let mark: CGFloat = GlyphSize.hero
    /// The width of the step's column, and of the field that takes a code.
    static let width: CGFloat = 460, field: CGFloat = 380
    /// The width of a step whose cards stand three in a row with a line under each name, the VPS page's: each line on
    /// one line at the step's one size.
    static let cardsWidth: CGFloat = 540
    /// The height of a step's field: the app's field (`FleetFieldLook`) with the step's larger words.
    static let fieldHeight: CGFloat = 34
    /// The space between the mark, the title and what is under them.
    static let gap: CGFloat = 18
    /// The line of Back at a page's top left, on which the × of a wizard that fills the window stands (`SetupClose`).
    @MainActor static let backLine: CGFloat = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: text))
}

/// **A setup page: its step in the middle of the window, and its Back at the top left.** The owner, 26 October 2026,
/// of the sign-in pages: "surely we can do a better UI/UX, centering and only showing the next action (dont show the
/// send button if it's not clickable ...)". He approved the centered steps from a mockup the same day, for every page
/// of an agent's setup. **Back stands at one place on every page of every setup** (the owner, 10 November 2026: "back
/// shuld probably by at the top of the wizard? I want it to be always in the same position during all screens of the
/// onboarding so it is easier to use"): the top left of the page's column, where a step that scrolls does not move it.
/// Every setup gives its Back here, as a `SetupBack`, and none under its step.
struct SetupPage<Back: View, Step: View>: View {
    @ViewBuilder var back: () -> Back
    @ViewBuilder var step: () -> Step
    /// The step's own height: a step taller than its page keeps its way on at the window's bottom (`SetupAction`).
    @State private var stepHeight: CGFloat = 0

    var body: some View {
        GeometryReader { window in
            // The step scrolls when it and its room over and under it do not fit in the page.
            let scrolls = stepHeight + 2 * Self.margin + FleetSpace.lights > window.size.height
            ScrollView {
                step()
                    .environment(\.setupRoom, window.size.height - 128)
                    .environment(\.setupScrolls, scrolls)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stepHeight = $0 }
                    // **The whole step stands in the middle of the window** (the owner, 13 November 2026, of "A VPS for
                    // your fleet": "why is the wizard so below and not centered?? ... I think it gets worse as the
                    // screens progress"): its mark, its title and what is under them, as one block, with as much room
                    // over it as under it. The page starts under the band of the window's buttons (`FleetSpace.lights`),
                    // so the room under it counts that band too, and the block's middle is the window's. A step taller
                    // than its page starts 64 pt down and scrolls. Before, the mark and a one-line title stood in the
                    // middle and what was under the title hung below it: the VPS page's centre was 154 pt under the
                    // window's, and every page with more under its title stood lower.
                    // While it scrolls, its way on stands at the window's bottom (`SetupActionBar`, 86 pt high with its
                    // fade): the step keeps the button's place, and 40 pt under it bring its last row just over the fade.
                    .padding(.top, Self.margin).padding(.bottom, scrolls ? 40 : Self.margin + FleetSpace.lights)
                    .fleetColumn()
                    .frame(maxWidth: .infinity, minHeight: window.size.height, alignment: .center)
            }
            .overlayPreferenceValue(SetupActionKey.self, alignment: .bottom) { action in
                if scrolls, let action { SetupActionBar(action: action.view) }
            }
        }
        .overlay(alignment: .topLeading) {
            back().frame(maxWidth: .infinity, alignment: .leading).padding(.top, FleetSpace.top).fleetColumn()
        }
    }

    /// The least room over a step, which keeps it clear of Back's line, and under it.
    static var margin: CGFloat { 64 }
}

extension SetupPage where Back == EmptyView {
    init(@ViewBuilder step: @escaping () -> Step) { self.init(back: { EmptyView() }, step: step) }
}

/// **A step's way on, which stays in view** (the owner, 13 November 2026, of "Choose what to import": "Build all four
/// and review all other pages for the same issues!!", after "I have to scroll down!"). Under the step's content while
/// the step fits in its page; while it scrolls, at the window's bottom over the list (`SetupActionBar`), and the step
/// keeps its room, so the last row scrolls up above it. Only one copy is drawn, so its keyboard shortcut is pressed once.
struct SetupAction<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.setupScrolls) private var scrolls
    /// Its height under the content, which the step keeps for it while it stands at the bottom.
    @State private var height: CGFloat = 34

    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        if scrolls {
            // Content that draws nothing (a button that only shows while it can be pressed) leaves no bar.
            Color.clear.frame(height: height)
                .preference(key: SetupActionKey.self,
                            value: height > 0 ? SetupActionView(view: AnyView(VStack(spacing: SetupMetrics.gap) { content() })) : nil)
        } else {
            VStack(spacing: SetupMetrics.gap) { content() }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
    }
}

/// The way on that a step gives its page while it scrolls.
struct SetupActionView { let view: AnyView }

struct SetupActionKey: PreferenceKey {
    static var defaultValue: SetupActionView? { nil }
    static func reduce(value: inout SetupActionView?, nextValue: () -> SetupActionView?) { value = value ?? nextValue() }
}

/// The way on at the window's bottom: on the page's own ground, with the list fading out under it, at the step's sizes.
private struct SetupActionBar: View {
    let action: AnyView

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [FleetStyle.canvas.opacity(0), FleetStyle.canvas], startPoint: .top, endPoint: .bottom)
                .frame(height: 28).allowsHitTesting(false)
            action
                .font(SetupMetrics.textFont)
                .environment(\.fleetButtonText, SetupMetrics.text)
                .environment(\.stepText, SetupMetrics.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: SetupMetrics.width)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
                .background(FleetStyle.canvas)
        }
    }
}

/// **One step: its mark, its title and its one way on, and nothing else.** A step that waits for the machine has no
/// button and no spinner: its title is its moving words, as the chat's "Thinking" is (his own correction of 20
/// October 2026: "remove that circle, I liked the Thinking text animation").
struct SetupStep<Mark: View, Content: View>: View {
    let title: String
    /// The machine works and he has nothing to do: the title moves.
    var waits = false
    /// The column's width: the step's own, and wider only for a row of three cards (`SetupMetrics.cardsWidth`).
    var width: CGFloat = SetupMetrics.width
    @ViewBuilder var mark: () -> Mark
    @ViewBuilder var content: () -> Content
    @Environment(\.setupRoom) private var room

    var body: some View {
        SetupColumn(room: room) {
            VStack(spacing: SetupMetrics.gap) {
                // The step's mark is its subject, not a status: an agent's glyph here draws no dot (`glyphDots`).
                mark().environment(\.glyphDots, false)
                SetupTitle(title: title, moving: waits)
            }
            VStack(spacing: SetupMetrics.gap) { content() }
        }
        .font(SetupMetrics.textFont)
        .environment(\.fleetButtonText, SetupMetrics.text)
        // A form under the title takes the step's one size too (`stepText`, fix round 2): its headings, row titles,
        // details, footers and fields, which were a page's 13.5, 13 and 12 beside the step's 15.
        .environment(\.stepText, SetupMetrics.text)
        .multilineTextAlignment(.center)
        .frame(maxWidth: width)
        .frame(maxWidth: .infinity)
    }
}

/// **The mark, the title and what is under them, one under the other.** On a setup page the step is one block, which
/// the page puts in the middle of the window (`SetupPage`). Outside a setup page the step is centred on its mark and
/// title.
private struct SetupColumn: Layout {
    /// The height the page has for its step (`setupRoom`): set on a setup page, which places the step as a whole; nil
    /// elsewhere.
    var room: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (head, rest) = sizes(proposal, subviews)
        return CGSize(width: max(head.width, rest.width), height: above(head, rest) + head.height + below(rest))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (head, rest) = sizes(proposal, subviews)
        let top = bounds.minY + above(head, rest)
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: top), anchor: .top,
                              proposal: ProposedViewSize(width: bounds.width, height: head.height))
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.midX, y: top + head.height + SetupMetrics.gap), anchor: .top,
                              proposal: ProposedViewSize(width: bounds.width, height: rest.height))
        }
    }

    /// The mark and the title, and what is under them, at the width the page gives.
    private func sizes(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (head: CGSize, rest: CGSize) {
        let width = ProposedViewSize(width: proposal.width, height: nil)
        return (subviews.first?.sizeThatFits(width) ?? .zero, subviews.count > 1 ? subviews[1].sizeThatFits(width) : .zero)
    }

    /// The room under the title.
    private func below(_ rest: CGSize) -> CGFloat { rest.height > 0 ? rest.height + SetupMetrics.gap : 0 }

    /// The room over the mark: none on a setup page, which centres the step as a whole; elsewhere as much as under the
    /// title, so that the title stands in the middle.
    private func above(_ head: CGSize, _ rest: CGSize) -> CGFloat {
        room == nil ? below(rest) : 0
    }
}

extension EnvironmentValues {
    /// The height a setup page has for its step, which `SetupColumn` keeps a tall step inside.
    @Entry var setupRoom: CGFloat? = nil
    /// The setup page's step is taller than the page and scrolls: its way on stands at the window's bottom.
    @Entry var setupScrolls = false
    /// The page is a wizard that fills the window (`FleetStore.fillsWindow`): its × closes it, so its first page needs
    /// no Back.
    @Entry var fillsWindow = false
}

extension SetupStep where Content == EmptyView {
    init(title: String, waits: Bool = false, @ViewBuilder mark: @escaping () -> Mark) {
        self.init(title: title, waits: waits, mark: mark, content: { EmptyView() })
    }
}

/// The title of a step: still when he has something to do, moving words while the machine works.
struct SetupTitle: View {
    let title: String
    var moving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if moving && !reduceMotion {
                ShimmeringWords(text: title, font: .systemFont(ofSize: SetupMetrics.title, weight: .semibold))
            } else {
                Text(title).font(SetupMetrics.titleFont)
                    .foregroundStyle(moving ? FleetStyle.muted : FleetStyle.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityAddTraits(.isHeader)
    }
}

/// **The steps of a long wait, and the minutes left, under its moving title** (the owner, 4 November 2026: "maybe we
/// should add some time estimation for each step.. so user knows that it can take so long..or a progress bar with the
/// different steps and see how we move through them?", and his yes the same day to "Steps and minutes"). One line of
/// dots with each step's name under it, in the step's one size: a done step in the words' colour, the one that runs in
/// the green of work with a soft ring, the rest dim. Green and not violet, because a state is never violet (D-8). The
/// minutes are our own estimate, never under one, and they go once every step is done.
struct SetupPhases: View {
    let names: [String]
    /// The step that runs now; `names.count` once all of them are done.
    let current: Int
    var minutesLeft: Int?
    /// **What runs now, in a few words, as the line under the title** (the owner's yes of 5 November 2026 to the status
    /// line of "Building your fleet"): grey, one line, above the dots. Only the first run passes one.
    var status: String?

    private static let dot: CGFloat = 10, ring: CGFloat = 18, rule: CGFloat = 2

    var body: some View {
        VStack(spacing: SetupMetrics.gap / 2) {
            if let status, current < names.count {
                Text(status).font(SetupMetrics.textFont).foregroundStyle(FleetStyle.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.bottom, SetupMetrics.gap / 2)
                    .accessibilityIdentifier("setup-status")
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    VStack(spacing: 8) {
                        ZStack {
                            HStack(spacing: 0) {
                                Rectangle().fill(index == 0 ? Color.clear : segment(index)).frame(height: Self.rule)
                                Rectangle().fill(index == names.count - 1 ? Color.clear : segment(index + 1))
                                    .frame(height: Self.rule)
                            }
                            Circle().fill(Color.green.opacity(index == current ? 0.25 : 0))
                                .frame(width: Self.ring, height: Self.ring)
                            Circle().fill(dot(index)).frame(width: Self.dot, height: Self.dot)
                        }
                        .frame(height: Self.ring)
                        Text(name).foregroundStyle(index <= current ? FleetStyle.text : FleetStyle.muted)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let minutesLeft, current < names.count {
                Text("About \(max(1, minutesLeft)) min").foregroundStyle(FleetStyle.muted)
            }
        }
        .frame(maxWidth: SetupMetrics.width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The line into step `index`: done once that step has begun.
    private func segment(_ index: Int) -> Color { index <= current ? FleetStyle.text.opacity(0.85) : FleetStyle.muted.opacity(0.3) }

    private func dot(_ index: Int) -> Color {
        index < current ? FleetStyle.text : index == current ? .green : FleetStyle.muted.opacity(0.35)
    }

    private var spoken: String {
        guard current < names.count else { return String(l10n: "All \(names.count) steps are done.") }
        let step = current + 1, count = names.count, name = names[current]
        switch (status, minutesLeft) {
        case (nil, nil): return String(l10n: "Step \(step) of \(count): \(name).")
        case let (doing?, nil): return String(l10n: "Step \(step) of \(count): \(name). \(doing).")
        case let (nil, left?): return String(l10n: "Step \(step) of \(count): \(name). About \(max(1, left)) minutes left.")
        case let (doing?, left?):
            return String(l10n: "Step \(step) of \(count): \(name). \(doing). About \(max(1, left)) minutes left.")
        }
    }
}

/// A quiet way back to something, under a step: muted words, no capsule ("Open the page again").
struct SetupLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        // The click reaches over and under the words (`IconMetrics.reach`), and the step does not move for it.
        Button(action: action) {
            Text(title).padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).font(SetupMetrics.textFont)
            .foregroundStyle(FleetStyle.muted)
    }
}

/// **Back, at the top left of every setup page** (`SetupPage`): the app's own back link (`FleetBack`), a left chevron
/// and the word in the muted words of a setup link, at the step's size (the owner's yes of 10 November 2026 to a "‹"
/// before Back).
struct SetupBack: View {
    let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    var body: some View {
        // The click reaches over and under the words (`IconMetrics.reach`), as a setup link's does.
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(IconMetrics.symbol(13, weight: .semibold))
                Text("Back")
            }.font(SetupMetrics.textFont).foregroundStyle(FleetStyle.muted)
                .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach)
            .accessibilityLabel("Back")
            .preference(key: SetupBackShows.self, value: true)
    }
}

/// A page shows its Back: Esc is Back's then, and the × of a wizard that fills the window takes Esc only on a first
/// page where no Back stands (`SetupFirstPage`).
struct SetupBackShows: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The page is the first page of Add server (also as the manager's server) or of Add agent: where no Back stands there,
/// Esc closes the wizard, as × does (the owner's yes of 12 November 2026: "Esc does what Back does. On the first page,
/// it closes the wizard.").
struct SetupFirstPage: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// **× at the top right of a wizard that fills the window** (the owner's yes of 12 November 2026 to its two pictures):
/// it closes the wizard from any page, and what runs goes on. A muted xmark on Back's line, with no circle at rest.
struct SetupClose: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(IconMetrics.symbol(14, weight: .medium)).foregroundStyle(FleetStyle.muted)
        }
        .buttonStyle(FleetIconButtonStyle(side: IconMetrics.side))
        .help("Close")
        .accessibilityLabel("Close")
        .accessibilityIdentifier("wizard-close")
    }
}

/// **What he does before he pastes, as short numbered steps over the field** (the owner, 10 November 2026: "instead of
/// just a link to Open XXX, show simple steps ABOVE the input because thye should be done BEFORE pastign the key ...
/// this applies to everything!"). One line of the step's own words for each step, its number muted; the first names
/// the page to open as a link (Markdown, in the link's violet, underlined, with an arrow after it: `words`). The steps
/// stand at the field's width and read from their own leading edge, as the field's words do. No "Open …" link stands
/// under the field.
struct SetupSteps: View {
    let steps: [String]
    /// The field's width on a setup step; nil in a form's block, where the steps take the block's width.
    let width: CGFloat?

    init(_ steps: [String], width: CGFloat? = SetupMetrics.field) { self.steps = steps; self.width = width }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "\(index + 1)").foregroundStyle(FleetStyle.muted).monospacedDigit()
                    Text(Self.words(step)).foregroundStyle(FleetStyle.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // The words of where they stand: the step's 15 on a setup step, which `SetupStep` gives its column, and a
        // row's 13 in a form's block.
        .tint(FleetStyle.link)
        .multilineTextAlignment(.leading)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    /// A step's words with its link, if it has one. **A link reads as a link** (the owner, 12 November 2026, of "Open
    /// Keys in Tailscale": "make it obvious that Keys is a link, add an icon after it and underline the word too"): its
    /// words underlined, then a no-break space and the arrow ↗, all in the link's violet. The arrow is a character of
    /// the link, so a click on it opens the page too: an SF Symbol in a line of words cannot be part of a link (SwiftUI
    /// opens nothing on its click), and the text-style selector keeps the arrow from turning into an emoji.
    static func words(_ step: String) -> AttributedString {
        let markdown = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: step, options: markdown)) ?? AttributedString(step)
        var words = AttributedString()
        for run in parsed.runs {
            var part = AttributedString(parsed[run.range])
            guard let link = run.link else { words += part; continue }
            part.underlineStyle = Text.LineStyle(pattern: .solid, color: FleetStyle.link)
            var arrow = AttributedString("\u{00A0}\u{2197}\u{FE0E}")
            arrow.link = link
            words += part + arrow
        }
        return words
    }
}

/// Codex's code, in the title's size and typeface, for him to read against the provider's page.
struct SetupCode: View {
    let code: String

    init(_ code: String) { self.code = code }

    var body: some View {
        Text(code).font(SetupMetrics.codeFont).tracking(2).textSelection(.enabled)
    }
}

/// What stopped a step, in orange under its title: the hub's own words.
struct SetupWarning: View {
    let words: String

    init(_ words: String) { self.words = words }

    var body: some View {
        Text(words).font(SetupMetrics.textFont).foregroundStyle(.orange).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// **The field a sign-in code is pasted into, which sends it by itself** (the owner's choice, 26 October 2026:
/// "Paste and it sends"). A paste that is a code of the right shape goes at once; so does Return. Typing a few
/// characters sends nothing, because a code is never typed by hand. A paste that is no code shows as such in the
/// field's own border, and nothing goes.
struct CodeField: View {
    @Binding var code: String
    let send: () -> Void
    @FocusState private var focused: Bool

    private var wrong: Bool { !code.isEmpty && MachineLogin.code(code) == nil }

    var body: some View {
        TextField(text: $code, prompt: Text(verbatim: "")) { Text("Paste the code") }
            .fieldPlaceholder(String(l10n: "Paste the code"), shows: code.isEmpty)
            .setupField(focus: $focused, wrong: wrong)
            .onSubmit { if MachineLogin.code(code) != nil { send() } }
            // A paste arrives in one change of many characters; a hand types one at a time.
            .onChange(of: code) { before, after in
                if after.count - before.count >= 8, MachineLogin.code(after) != nil { send() }
            }
            .task { focused = true }
    }
}

/// **A field on a setup step for words he types**: a name, a phone number. It has the cursor when its step opens, and
/// Return is the step's way on. Its border is orange while what it holds is no answer.
struct SetupField: View {
    let placeholder: String
    @Binding var text: String
    var wrong = false
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        // **A step's placeholder in the app's muted words, whether or not the field has the cursor** (fix rounds 2 and 3):
        // the system's own placeholder read 2.3:1 on its fill ("Paste the code", "Their name"), where the muted words
        // read 5:1, and a colour given to its prompt does not reach it (`fieldPlaceholder`).
        TextField(text: $text, prompt: Text(verbatim: "")) { Text(placeholder) }
            .fieldPlaceholder(placeholder, shows: text.isEmpty)
            .setupField(focus: $focused, wrong: wrong)
            .onSubmit(submit)
            .task { focused = true }
    }
}

extension View {
    /// **The field of a setup step is the app's one field** (`FleetFieldLook`) in the step's size: its words at 15
    /// points in a box 34 high, a ring in the violet while it has the cursor, an orange edge while what it holds is no
    /// answer, and the whole box takes the click. Its words and its cursor start at its left edge, as in any field:
    /// centered, the cursor blinked in the middle of the words (the owner, 28 October 2026: "this centered blinking
    /// cursor is weird").
    func setupField(focus: FocusState<Bool>.Binding, wrong: Bool = false) -> some View {
        modifier(FleetFieldLook(focus: focus, wrong: wrong, text: SetupMetrics.text, height: SetupMetrics.fieldHeight))
            .frame(width: SetupMetrics.field)
    }
}

/// **"Setting up <Agent>" in place of a chat that cannot answer yet.** The owner, 26 October 2026, after his first
/// "Hi" to Leo waited 27 seconds: "if it's not ready we should show like a Setting up panel, not the chat interface
/// or a clunky status message", and yes to the mockup the same day: the agent's mark and its name, the words moving
/// as "Thinking" does, no text box and no messages (`AgentSetupFlow.chatStarts`). The chat takes its place the
/// moment the hub reports its session ready.
struct ChatSettingUp: View {
    let agent: String

    var body: some View {
        SetupPage {
            SetupStep(title: String(l10n: "Setting up \(agent.agentLabel)"), waits: true) {
                AgentGlyph(name: agent, size: SetupMetrics.mark)
            }
        }
        .accessibilityIdentifier("chat-setting-up")
    }
}
