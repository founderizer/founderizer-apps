import FleetCore
import SwiftUI
import UIKit

/// The small parts that every page of the phone app uses.
///
/// The app takes its **sizes and its type** from the system, so Dynamic Type, Bold Text and the accessibility text
/// sizes work as they do in the system's own apps. Its **colours are the brand's**, and they live in one place:
/// `Assets.xcassets`, where each one is written four times — light, dark, light under Increase Contrast and dark
/// under Increase Contrast. The system picks the right one, so taking the brand did not take away what the system
/// colours were giving: a page still turns with the phone's appearance and still answers Increase Contrast.
///
/// `Brand` below is the only door to them. No page writes a colour of its own.
///
/// Two things stayed the system's own on purpose. **The main text colour** (`.primary`) is untouched: it is what
/// makes Increase Contrast and Smart Invert read correctly. The quiet words, the warning words, "Online" and the
/// placeholders have sets of their own, because the system's read below 4.5:1 on the light canvas. And **the
/// materials** of the keyboard's own bar stay materials, because a flat fill under a keyboard is wrong on this
/// platform.
///
/// The Mac app keeps its own `FleetStyle` for its measures, because a desktop window and a phone screen are read at
/// different distances; what the two now share is the words *and* the palette.

// MARK: - The brand

/// Every colour of the app. The values are in `Assets.xcassets`, one colour set each, so that the system resolves
/// light, dark and Increase Contrast before SwiftUI ever sees them.
enum Brand {
    /// The interactive accent: what the owner can touch, and what the system tints with it (the bar, the caret, a
    /// button's words). **Violet is what he can press, and the brand's mark; a state is never violet** (the owner's yes
    /// of 28 October 2026 to D-8): working is green, needs you orange, failed red, and the unread dot is the one violet
    /// dot. It is one step deeper than the brand violet in light and one step lighter in dark, because
    /// `#635BFF` as *text* clears 4.5:1 on neither of the two canvases, and this is read as text far more often than
    /// the mark is read as a shape. It is the `AccentColor` of the catalogue, so `Color.accentColor` and every
    /// system control already carry it with no call site of their own.
    static let accent = Color.accentColor
    /// The brand violet, `#635BFF`, exactly as the mark and the icon carry it: the plate under the mark's white
    /// chevrons. It is never used as text itself.
    static let violet = Color("BrandViolet")
    /// Behind every page.
    static let canvas = Color("BrandCanvas")
    /// A card, a row of a grouped list, and the bar that a composer sits in.
    static let surface = Color("BrandSurface")
    /// The owner's own message, as the Mac draws it (D-6), the field of an answer, its option rows and the search
    /// field: the quiet fill of what is his to write or press.
    static let bubble = Color("BrandBubble")
    /// The accent, quietly: a tint behind something that belongs to the accent without being touchable.
    static let soft = Color("BrandSoft")

    // The words. The system's grey, orange and green read 3.3:1, 2.1:1 and 2.2:1 on the light canvas, where every
    // word that carries information needs 4.5:1; these four keep the system's colour in dark, where it passed, and
    // under Increase Contrast they reach 7:1.

    /// Words that carry a fact quietly: a time, a preview, the facts under a title, a note under a composer.
    static let muted = Color("BrandMuted")
    /// Words that ask the owner to act: "Not sent", "Waiting", "Not answering", "Usage limit", a refusal. The marks and the bars
    /// beside them keep the system's orange.
    static let warning = Color("BrandWarning")
    /// The words of a state that is well: "Online" and "Working". The dot keeps the system's green.
    static let online = Color("BrandOnline")
    /// What a field says before he writes in it: 3:1 against the field, where the system's grey was 1.7:1.
    static let placeholder = Color("BrandPlaceholder")
    /// Near-black, the same in every appearance: the arrow of a chat's Send on an agent's light colour.
    static let ink = Color("BrandInk")

    /// **The line between two rows: the system's own, and under Increase Contrast one that reads 3:1 or more against
    /// the card and the page** (fix round 2, item 55): there the rows' lines read 1.23:1 in light and 1.35:1 in dark.
    static let separator = Color(uiColor: UIColor { traits in
        traits.accessibilityContrast == .high ? strongEdge(traits) : .separator
    })
    /// The veil under the words of the dark composer's glass (item 91): the canvas, nearly whole, in dark; nothing in
    /// light, where the glass already keeps the words behind it under its placeholder.
    static let glassVeil = Color(uiColor: UIColor { traits in
        guard traits.userInterfaceStyle == .dark else { return .clear }
        // The chat's own neutral, #222222 (fix round 3, item 28): the canvas's veil made a fourth fill, #171819.
        return UIColor(red: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255, alpha: 0.85)
    })
    /// The edge of a card that the app draws itself (a request, the work that only he can move): none at the usual
    /// contrast, where the card stands on the page by its fill, and the strong line under Increase Contrast, where the
    /// card and the page are 1.2:1 apart in light and 1.5:1 in dark.
    static let cardEdge = Color(uiColor: UIColor { traits in
        traits.accessibilityContrast == .high ? strongEdge(traits) : .clear
    })

    /// 3.0:1 on the light page under Increase Contrast and 3.6:1 on a card; 4.2:1 on a dark card and 6.2:1 on black.
    private static func strongEdge(_ traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x8D / 255, green: 0x8D / 255, blue: 0x93 / 255, alpha: 1)
            : UIColor(red: 0x86 / 255, green: 0x86 / 255, blue: 0x89 / 255, alpha: 1)
    }
}

extension View {
    /// A page's background: the brand's canvas in place of the system's own list fill.
    func brandPage() -> some View {
        scrollContentBackground(.hidden).background(Brand.canvas)
    }

    /// A page that a tab opens, with no navigation bar over it.
    ///
    /// The bottom bar already says which page this is, so a bar that writes the word again costs its 44 points and
    /// the band of air around it to tell him what the lit tab under his thumb has just told him. The page starts at
    /// the top of the screen instead. A page he pushed to — an agent's chat, one task, Settings — keeps its bar,
    /// because there the title is a name he needs and the bar carries Back.
    @ViewBuilder func tabRootPage() -> some View {
        // A bar was also keeping the page's words off the clock. Without one, a row scrolled under the status bar
        // and sat behind the time; this platform's own edge effect is what puts it back, and it needs no bar. A
        // phone too old for it keeps its bar: a tall header is worse than this one, and a row over the clock is
        // worse than both.
        if #available(iOS 26.0, *) {
            toolbar(.hidden, for: .navigationBar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            navigationBarTitleDisplayMode(.inline)
        }
    }

    /// The fill of the rows under it: the brand's card on a grouped page, and the canvas itself on a plain list,
    /// whose rows are not cards. It has to stand **inside** the list, on a section or on a row — a list does not
    /// take this one from outside itself, and a page that puts it there gets the system's black rows back.
    func brandRows(cards: Bool = true) -> some View {
        listRowBackground(cards ? Brand.surface : Brand.canvas)
            .listRowSeparatorTint(Brand.separator)
    }
}

// MARK: - What an agent does now

/// An agent's state, as the hub reports it. It is the Mac app's `AgentPresence` without the machine problems: the
/// phone does not read `GET /ui/machines`. Working means that the hub reports a task of this agent in work now; a
/// queued, held or waiting task is not work, and the hub reports no other activity, so this is never "idle".
indirect enum AgentState: Equatable {
    case unknown, setup, offline, limited, working, online
    /// A task of its needs someone, in that task's own word: "Waiting for Manager", "Sign-in needed", "Stalled".
    case attention(String)
    /// **What a reading that is old now says** (review B3; fix round 3, COPY): the look it read — its colour, its dot, its
    /// mark at rest, because motion would say that the work goes on now — and "Last reading" in words, on the screen
    /// and for VoiceOver, as the Mac's.
    case old(AgentState)

    /// The state its look is drawn from.
    var base: AgentState { if case .old(let state) = self { state.base } else { self } }

    var words: String {
        switch self {
        // An old reading, in the Mac's words (fix round 2, item 35), on the screen and for VoiceOver.
        case .unknown: "Last reading"
        case .setup: "In setup"
        // One word for each state on both screens, the Mac's (lane E's fix): "Offline" and "Limited" were the
        // phone's own.
        case .offline: "Not answering"
        case .limited: "Usage limit"
        case .attention(let words): words
        case .working: "Working"
        case .old: "Last reading"
        case .online: "Online"
        }
    }
    /// The colour of the state's dot. **Work is green** (D-8): the accent is what he can press, and a state is never
    /// violet. **The brand's own green and orange** (fix round 2, item 54): the system's read 2.05:1 and 2.13:1 for an
    /// 8-point dot on the light canvas, where a mark needs 3:1; the brand's read about 5:1 there, and in dark they are
    /// the system's own values.
    var color: Color {
        switch base {
        case .online, .working: Brand.online
        case .offline, .limited, .attention: Brand.warning
        case .unknown, .setup, .old: .secondary
        }
    }
    /// The colour of the state's word, which must read as text: the brand's text colours of the same meaning.
    var wordColor: Color {
        switch self {
        case .online, .working: Brand.online
        case .offline, .limited, .attention: Brand.warning
        case .unknown, .setup, .old: Brand.muted
        }
    }
    /// **A dot is a problem: neither online nor work has one** (the owner, 13 November 2026, of the Mac's sidebar: "remove
    /// all green status dots. if agent is available, just dont show it (that should be the default). only show
    /// red/other colors if there is some kind of problem", and of the phone: "Yes, iPhone too"). Online is the usual
    /// state (D-8), and work shows as motion: the agent's mark moves and the line of its row on Chats moves. With Reduce
    /// Motion nothing moves, so there work keeps its green dot, the one sign of it that is left.
    func hasDot(reduceMotion: Bool) -> Bool {
        switch base {
        case .online: false
        case .working: reduceMotion
        case .unknown, .setup, .offline, .limited, .attention, .old: true
        }
    }
    /// A ring, not a filled dot: the agent takes no work now, so colour is not the only cue.
    var isRing: Bool { base == .unknown || base == .setup || base == .offline }
}

extension MobileAgent {
    /// **The Mac's own state of an agent** (`FleetAgent.presence`; review B3): in setup, not answering, its usage
    /// limit, then its open tasks by their marks — work only for a task that the hub reports in work with no hold, stall
    /// or lost session, so a paused task is not work; a stalled task, one that waits for its requester and one that
    /// needs a sign-in say their own word, in orange — and else online. **An old reading keeps the look it read**: only
    /// the motion rests (`old`), because a moving mark says that the work goes on now. The phone greyed
    /// every mark for an old reading, called a paused or a stalled task work, and said "Waiting" for every wait.
    /// **An agent that works on his newest chat message works too** (`thinking`: its chat says "Thinking",
    /// `MobileStore.thinks`), as on the Mac since 13 November 2026.
    func mobileState(in snapshot: MobileSnapshot, isFresh: Bool, thinking: Bool = false) -> AgentState {
        let state = readState(in: snapshot, thinking: thinking)
        return isFresh ? state : .old(state)
    }

    private func readState(in snapshot: MobileSnapshot, thinking: Bool) -> AgentState {
        if active == false { return .setup }
        if !helperIsRecent(serverTime: snapshot.time) { return .offline }
        if limit != nil { return .limited }
        let marks = snapshot.tasks.filter { $0.owner == name }.map { $0.mark(holds: snapshot.holds, limited: false) }
        if thinking || marks.contains(where: { $0.inWork }) { return .working }
        if let waiting = marks.first(where: { $0.attention }) { return .attention(waiting.words) }
        return .online
    }
}

// MARK: - Small parts that every page uses

/// An agent's state as a dot, with its word for assistive apps.
struct StatusDot: View {
    let state: AgentState
    /// Its size where the mark it sits on sets one; otherwise it follows the text.
    var size: CGFloat?
    @ScaledMetric(relativeTo: .footnote) private var scaled: CGFloat = 9

    var body: some View {
        let side = size ?? scaled
        Circle()
            .strokeBorder(state.color, lineWidth: state.isRing ? max(1.5, side / 6) : side / 2)
            .frame(width: side, height: side)
            .accessibilityLabel(state.words)
    }
}

/// **A group's heading in the quiet words' colour** (T-29, fix round 1): the system's own grey for a heading read
/// 3.3:1 on the light canvas, where a word that carries information needs 4.5:1; this one reads 5.3:1.
struct GroupHeading: View {
    let words: String
    init(_ words: String) { self.words = words }
    var body: some View { Text(words).foregroundStyle(Brand.muted).wholePoints() }
}

/// **A row or a heading of a grouped list is a whole number of points high** (margins pass, fault 8): the list starts
/// each row on a whole point, so after a heading 40.33 points high or a row 93.67 points high a line of the page's
/// colour, one pixel high, crossed the card between two rows (Tasks, a task, Settings at the largest text sizes).
struct WholePoints: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(proposal)
        // A height that is whole but for a rounding error stays as it is.
        return CGSize(width: size.width, height: (size.height - 0.01).rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

extension View {
    /// The view in a frame a whole number of points high, its content at the top (`WholePoints`).
    func wholePoints() -> some View { WholePoints { self } }
}

/// **The line between two rows of a card that the app draws: the grouped list's own line, 1 point high** (margins
/// pass, fault 16). A request's rows had the system's hairline, a third of a point, in a darker grey than the line
/// between two rows of Tasks, a task or Settings.
struct RowLine: View {
    var body: some View { Rectangle().fill(Brand.separator).frame(height: 1) }
}

/// **Words after a mark, the mark in the 22-point column of a task's mark** (margins pass, fault 11), so the words
/// start where a task's title starts. It takes the place of a `Label`, whose own icon column put the words 1.7 points
/// off that column.
struct MarkedLine: View {
    let symbol: String
    var markColor: Color = .secondary
    let words: String
    var wordsColor: Color = .primary
    @ScaledMetric(relativeTo: .title3) private var markWidth: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // **At the accessibility sizes the mark stands over the words, as a task's row puts its mark over its title**
        // (T-38; review A): with its column kept there, the manager's warning started about 70 points right of the
        // Activity titles under it.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Image(systemName: symbol).foregroundStyle(markColor)
                .frame(width: typeSize.isAccessibilitySize ? nil : markWidth)
                .accessibilityHidden(true)
            Text(words).foregroundStyle(wordsColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A long value under its name, where a grouped list holds a field that does not fit on one line.
struct FieldRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(Brand.muted)
            Text(verbatim: value.isEmpty ? "Not reported" : value)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wholePoints()
    }
}

/// One row of a grouped list that carries its own explanation: a title, a line under it, and one value at the right.
/// Where a row needs no explanation of its own, `LabeledContent` is used instead, and where the explanation belongs
/// to the whole group it goes in the group's footer.
struct DetailRow: View {
    let title: String
    var detail: String = ""
    var value: String = ""
    var valueColor: Color = Brand.muted
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !value.isEmpty {
                if !stacked { Spacer(minLength: 8) }
                Text(value).font(.subheadline).foregroundStyle(valueColor)
                    .multilineTextAlignment(stacked ? .leading : .trailing)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wholePoints()
    }
}

/// The quiet facts under a title, joined by the middle dot. It wraps instead of truncating, so it still reads at the
/// large text sizes.
struct MetaLine: View {
    let parts: [String]

    var body: some View {
        Text(parts.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.footnote).foregroundStyle(Brand.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The send button of a composer: the platform's own filled circle with an arrow.
///
/// **It shows only while something can go** (the owner, 26 October 2026: "dont show the send button if it's not
/// clickable"), in a slot of the circle's own size, so the field beside it never moves when it comes and goes; it was
/// a grey circle under every chat with an empty field (T-05). **Its touch is 44 points, the platform's own, around the
/// 30-point circle**; it was 30 by 30. The touch reaches past the circle and the composer keeps its height: the frame
/// is the button's own, and the layout keeps the circle's.
///
/// **A chat's Send is the agent's own colour** (the owner's yes of 28 October 2026 to D-6): the circle takes the agent's
/// deeper hue and the arrow whichever of white and near-black reads stronger on it — near-black on Manager's lime, Mia's
/// coral and Ivy's rose, white on Leo's blue and on orchid. Every other Send keeps the accent.
struct SendButton: View {
    let enabled: Bool
    let label: String
    /// The circle and the arrow.
    let fill: Color
    let arrow: Color
    let action: () async -> Void
    @ScaledMetric private var size: CGFloat

    init(enabled: Bool, label: String, side: CGFloat = 30, fill: Color = Brand.accent, arrow: Color = Brand.surface,
         action: @escaping () async -> Void) {
        self.enabled = enabled
        self.label = label
        self.fill = fill
        self.arrow = arrow
        self.action = action
        _size = ScaledMetric(wrappedValue: side, relativeTo: .title2)
    }

    /// The arrow on an agent's colour: white or near-black, whichever reads stronger on it by the contrast ratio of
    /// the two. White wins on Leo's blue and on orchid, near-black on lime, coral, rose and the other light hues.
    static func arrow(on fill: Color) -> Color {
        // **White where white reads 3:1 on the colour, near-black on the lighter ones** (fix round 3b, as the Mac's
        // 9ff5432 and D-6's words): white everywhere read 1.73:1 on Manager's lime.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(fill).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .white }
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05) >= 3 ? .white : Brand.ink
    }

    var body: some View {
        let touch = max(44, size)
        ZStack {
            if enabled {
                Button { Task { await action() } } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: size))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(arrow, fill)
                        .frame(width: touch, height: touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-(touch - size) / 2)
                .accessibilityLabel(label)
                // **It comes in over 0.15 s and goes in the frame the field empties** (fix round 2, item 72): its
                // fade out kept it, at full colour for 105 ms, in the shrinking composer's old place, half under the
                // keyboard.
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.15), value: enabled)
    }
}

/// A plain text action beside a line of text: the tint, grey while it cannot be used, and no frame around it.
///
/// **Its touch is at least 44 points high**, as the platform asks of every control: Retry, Discard and Cancel were
/// caption words of 14 points. The touch reaches above, below and beside the word, and the line keeps its height.
struct TextAction: View {
    let title: String
    var enabled = true
    var font: Font = .subheadline
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.vertical, 15).padding(.horizontal, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -15).padding(.horizontal, -7)
        .disabled(!enabled)
        .font(font.weight(.medium))
        .foregroundStyle(enabled ? Brand.accent : Color.secondary)
    }
}

/// One quiet line under a composer: a reason, a character count, or where a waiting request stands. Orange only for
/// something that the owner must act on.
struct ComposerNote: View {
    let words: String
    var isWarning = false
    /// The system's own words for a failure, which VoiceOver reads as the line's value and the screen never shows.
    var detail: String?

    var body: some View {
        Text(words)
            .font(.caption).foregroundStyle(isWarning ? Brand.warning : Brand.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityValue(detail ?? "")
    }
}

/// **The one loading element of a page**, as the Mac's `LoadingLine`: nothing for the first second, then the page's
/// own words ("Reading the task…"), muted, with a band of light moving across them, faded in over 150 ms. No spinner,
/// no row of its own, no card: it stands in the page's first content slot, where what it reads will stand.
///
/// A read that answers inside that second shows nothing that blinks away. The words move because the owner chose
/// moving words over a circle for every wait ("remove that circle, I liked the Thinking text animation"); under Reduce
/// Motion they stand still, and at the accessibility text sizes they stand still too, so that they can wrap. Its room
/// is kept from the first frame, so the words take no space that something else had.
struct LoadingLine: View {
    let words: String
    @State private var shows = false
    /// When a loading line last drew its words, a frame after their state changed: `MobileStore.settle` counts its half
    /// second from there (fix round 3, item 43).
    @MainActor static var shownAt: ContinuousClock.Instant?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ words: String) { self.words = words }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(words).font(.footnote).hidden()
            if shows {
                Group {
                    if reduceMotion || typeSize.isAccessibilitySize {
                        Text(words).font(.footnote).foregroundStyle(Brand.muted)
                    } else {
                        ShimmeringWords(text: words)
                    }
                }
                .transition(.opacity)
                .onAppear { LoadingLine.shownAt = ContinuousClock.now + .milliseconds(17) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { shows = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// **What a page says about a wait, only once that wait has had a second** (the Mac's `Held`): a wait that ends inside
/// the second shows nothing that comes and goes. The words fade in over 150 ms.
struct Held<Content: View>: View {
    let content: Content
    /// The words may still come: false once the wait ended, so a wait that ended inside its second never shows them,
    /// and words that already show stay.
    let comes: Bool
    @State private var shows = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(comes: Bool = true, @ViewBuilder content: () -> Content) {
        self.comes = comes
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if shows { content.transition(.opacity) }
        }
        .task(id: comes) {
            guard comes else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { shows = true }
        }
    }
}

/// **The words, muted, with a brighter band sweeping across their glyphs, right to left, for ever** — the Mac's
/// `ShimmeringWords`, with its geometry and its 2.8-second pass, on this platform's layers.
///
/// It is Core Animation and not SwiftUI for the reason the Mac's is: a repeating SwiftUI animation drives the whole
/// view tree every frame, and a `CABasicAnimation` runs on the render server while the page draws once
/// (`UI-PATTERNS.md`: motion that runs for ever is Core Animation).
struct ShimmeringWords: UIViewRepresentable {
    let text: String
    /// The loading line's words are a footnote; the chat's waiting line is a line of its own size (`ChatWaitingLine`).
    var style: UIFont.TextStyle = .footnote
    /// **The line takes the width it is given, and words that are longer end in "…"**, as a `Text` of one line does:
    /// the last line of a conversation on Chats, whose width is the row's (the Mac's `ShimmeringWords.fits`). False for
    /// a word or two that always fit, which keep their own width whatever they are offered.
    var fits = false

    func makeUIView(context: Context) -> ShimmerView { ShimmerView() }
    func updateUIView(_ view: ShimmerView, context: Context) { view.show(text, style: style, fits: fits) }
    /// The words' own size, so the line is laid out as a `Text` would be, and not across the room it is offered. A line
    /// that fits its room takes at most its words' own width, so its band still crosses the words and not the room.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ShimmerView, context: Context) -> CGSize? {
        let words = uiView.intrinsicContentSize
        guard fits, let width = proposal.width, width.isFinite else { return words }
        return CGSize(width: min(words.width, max(0, width)), height: words.height)
    }
}

/// The words twice and a gradient between them: the muted words, then a sliding band of light that reaches the screen
/// only where a second copy of the words lets it through. Both copies are drawn images, because a text layer used as a
/// mask does not give the alpha of its glyphs (the Mac's `ShimmerView` found that first).
final class ShimmerView: UIView {
    /// One pass, as on the Mac: slower than the recipe's 2 seconds, because the owner asked for slower.
    private static let pass: CFTimeInterval = 2.8
    /// The gradient box, as a multiple of the words' width, and where the light begins and ends inside it.
    private static let box: CGFloat = 4
    private static let lightBegins: CGFloat = 0.4
    private static let lightEnds: CGFloat = 0.6

    private let word = CALayer()
    private let lit = CALayer()             // holds the band and carries the fixed mask
    private let band = CAGradientLayer()
    private let glyphs = CALayer()          // the mask: the same words, not moving
    private var text = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(word)
        layer.addSublayer(lit)
        lit.addSublayer(band)
        lit.mask = glyphs
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.locations = [0, NSNumber(value: Double(Self.lightBegins)), 0.5, NSNumber(value: Double(Self.lightEnds)), 1]
        band.anchorPoint = .zero
        // The words are drawn again for the phone's appearance, its contrast and its text size.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                                 UITraitPreferredContentSizeCategory.self]) { (view: ShimmerView, _: UITraitCollection) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { nil }

    private var style: UIFont.TextStyle = .footnote
    private var font: UIFont { UIFont.preferredFont(forTextStyle: style, compatibleWith: traitCollection) }

    override var intrinsicContentSize: CGSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// The line is cut to its room (`ShimmeringWords.fits`).
    private var fits = false

    func show(_ text: String, style: UIFont.TextStyle = .footnote, fits: Bool = false) {
        guard text != self.text || style != self.style || fits != self.fits else { return }
        self.text = text
        self.style = style
        self.fits = fits
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// **What the view draws: its words whole, or cut to the room of a line that fits its room.** A line is cut only
    /// where its room is more than a point short of its words: SwiftUI and UIKit measure one line within a fraction of
    /// a point of each other, and a line that fits must not end in "…" for that fraction (the Mac's own rule).
    private var shownSize: CGSize {
        let words = intrinsicContentSize
        guard fits, bounds.width > 0, bounds.width + 1 < words.width else { return words }
        return CGSize(width: bounds.width, height: words.height)
    }

    /// The words as they are drawn: whole, or the longest beginning that fits the room with "…" after it, with no
    /// space before the "…".
    private func shownWords(in width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard width < intrinsicContentSize.width else { return text }
        let letters = Array(text)
        func line(_ count: Int) -> String { String(letters.prefix(count)).trimmingCharacters(in: .whitespaces) + "…" }
        var low = 0, high = letters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if (line(middle) as NSString).size(withAttributes: attributes).width <= width { low = middle } else { high = middle - 1 }
        }
        return line(low)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A layer that left the window lost its motion.
        if window != nil { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard intrinsicContentSize.width > 0, intrinsicContentSize.height > 0 else { return }
        let size = shownSize
        let words = shownWords(in: size.width)
        let scale = max(traitCollection.displayScale, 1)
        let frame = CGRect(origin: .zero, size: size)
        let light = UIColor.label.resolvedColor(with: traitCollection)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        word.frame = frame
        word.contentsScale = scale
        let muted = UIColor(named: "BrandMuted") ?? .secondaryLabel
        word.contents = drawn(words, muted.resolvedColor(with: traitCollection), size: size, scale: scale)
        lit.frame = frame
        glyphs.frame = frame
        glyphs.contentsScale = scale
        // The mask reads alpha, so the colour only has to be opaque where the glyphs are.
        glyphs.contents = drawn(words, .white, size: size, scale: scale)
        band.frame = CGRect(x: 0, y: 0, width: size.width * Self.box, height: size.height)
        let clear = light.withAlphaComponent(0).cgColor       // the same colour, so the fade has no grey in it
        band.colors = [clear, clear, light.cgColor, clear, clear]
        CATransaction.commit()
        sweep(width: size.width)
    }

    private func drawn(_ text: String, _ color: UIColor, size: CGSize, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            (text as NSString).draw(at: .zero, withAttributes: attributes)
        }.cgImage
    }

    /// One pass is the band crossing the words and nothing else: the bright centre enters half a band-width off the
    /// right edge and leaves half a band-width past the left, and the next pass begins there (the Mac's own sweep).
    private func sweep(width: CGFloat) {
        let half = (Self.lightEnds - Self.lightBegins) * Self.box / 2
        let centre = Self.box / 2
        let from = (1 + half - centre) * width
        let travel = (-half - centre) * width
        if let running = band.animation(forKey: "sweep") as? CABasicAnimation,
           (running.toValue as? CGFloat) == travel { return }
        band.removeAnimation(forKey: "sweep")
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = from
        sweep.toValue = travel
        sweep.duration = Self.pass
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        band.add(sweep, forKey: "sweep")
    }
}

extension View {
    /// The round control of a page's corner, as this platform draws Back on a pushed page: a 44-point circle of glass,
    /// with its glyph in the text colour, the size of Back. Settings was a 36-point solid circle with a grey glyph,
    /// 2.15:1 on its own fill. A phone older than the glass gets a 44-point circle of the brand's surface.
    @ViewBuilder func cornerControl() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(CornerGlass())
        } else {
            buttonStyle(CornerCircle())
        }
    }

    /// The rounded field of an answer's composer: the brand's quiet fill, the one his own message's bubble takes.
    func composerField() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Brand.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// **A chat's composer is one shape of the system's glass** (the owner's yes of 28 October 2026 to D-6), 25 points
    /// round, so one line at rest is a capsule 50 points high, and the conversation scrolls under it: it was a white band
    /// the whole width of the screen. **In dark the glass is denser** (fix round 2, item 91): a veil of the canvas under
    /// its words, so what passes behind it stays a shade (1.2:1 at most) and its placeholder reads 3:1 or more over the
    /// busiest message; the clear dark glass let words behind it read at 1.43:1 and dropped the placeholder to 1.68:1. A
    /// phone older than the glass gets the system's regular material and a hairline.
    @ViewBuilder func composerGlass() -> some View {
        let shape = RoundedRectangle(cornerRadius: 25, style: .continuous)
        if #available(iOS 26.0, *) {
            background(Brand.glassVeil, in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        }
    }

    /// **The composer as the page's bottom bar** (fix round 2, item 52): on a phone with the glass it is a safe-area
    /// bar, which the system's scroll edge effect knows, so the conversation fades where it runs under it; on an older
    /// phone, an inset as before.
    @ViewBuilder func composerBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
    }

    /// The system's soft scroll edge at the bottom of a conversation, under its composer (iOS 26 and later).
    @ViewBuilder func softBottomEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }

    /// The pill over a chat that names its agent: the system's glass that reacts to a touch, or the brand's surface
    /// with a hairline on a phone older than the glass.
    @ViewBuilder func titlePill() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(Brand.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

/// The corner's round control on a phone older than the glass: a 44-point circle of the brand's surface, all of it
/// the touch.
/// **The corner's round control at Back's own size** (T-28, fix round 1): a 44-point circle of glass. The system's
/// large glass button drew it at 50.7 points beside Back's 44.
@available(iOS 26.0, *)
private struct CornerGlass: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

private struct CornerCircle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .background(Brand.surface, in: Circle())
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Words for times and names

extension String {
    /// The first letter in upper case, the rest unchanged: a hub word stays as the hub wrote it.
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}

/// A hub word as a sentence: "not_confirmed" becomes "Not confirmed".
func hubWords(_ value: String) -> String { value.replacingOccurrences(of: "_", with: " ").capitalizedFirst }

/// An agent's name as the pages show it.
func agentName(_ name: String) -> String { name.agentLabel }

/// A time of day, for a message or a note.
func fleetTime(_ timestamp: Double) -> String {
    Date(timeIntervalSince1970: timestamp).formatted(date: .omitted, time: .shortened)
}

/// **When a request was raised, as the Mac writes it** (`messageTime` there; fix round 2, item 31): the time today, the
/// weekday and the time in the last week, else the date and the time. The phone said "12 min ago" where the Mac said
/// "0:08".
func requestTime(_ timestamp: Double, now: Date = .now, calendar: Calendar = .current) -> String {
    let date = Date(timeIntervalSince1970: timestamp)
    if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    return days > 0 && days < 7 ? date.formatted(.dateTime.weekday(.wide).hour().minute())
        : date.formatted(date: .abbreviated, time: .shortened)
}

/// The head of a request, in the Mac's form: "From Iris · 0:08".
func requestHead(by agent: String, raised: Double, now: Date = .now) -> String {
    "From \(agentName(agent)) · \(requestTime(raised, now: now))"
}

/// **A time to come, as the Mac writes it** (`fleetComingTime` there; the lead's call on item 32): the time today, the
/// weekday and the time in the next week, else the day and the month.
func comingTime(_ timestamp: Double, now: Double, calendar: Calendar = .current) -> String {
    let date = Date(timeIntervalSince1970: timestamp)
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSince1970: now)),
                                       to: calendar.startOfDay(for: date)).day ?? 0
    if days == 0 { return date.formatted(date: .omitted, time: .shortened) }
    if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    return date.formatted(.dateTime.day().month(.abbreviated))
}

/// A date and a time, or "Not reported" without one.
func fleetDate(_ timestamp: Double?) -> String {
    guard let timestamp else { return "Not reported" }
    return Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
}

/// How long ago, in a few words: "just now", "4 min ago", "3 h ago", then the date and the time.
func fleetAge(_ timestamp: Double, now: Double) -> String {
    let seconds = max(0, now - timestamp)
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(Int(seconds / 60)) min ago"
    case ..<86_400: return "\(Int(seconds / 3600)) h ago"
    default: return fleetDate(timestamp)
    }
}

/// The mark that a conversation puts above a message after a gap: the day, then the time, as this platform's own
/// chat writes it.
func chatStamp(_ timestamp: Double) -> Text {
    let date = Date(timeIntervalSince1970: timestamp)
    let calendar = Calendar.current
    let day: String
    if calendar.isDateInToday(date) {
        day = "Today"
    } else if calendar.isDateInYesterday(date) {
        day = "Yesterday"
    } else if let aWeekBack = calendar.date(byAdding: .day, value: -6, to: .now), date > aWeekBack {
        day = date.formatted(.dateTime.weekday(.wide))
    } else {
        day = date.formatted(date: .abbreviated, time: .omitted)
    }
    return Text(day).fontWeight(.semibold) + Text(" " + fleetTime(timestamp))
}

/// Where an owner message was written: this phone, the Mac, or a chat app. The compact read gives the client label
/// only, and a chat app writes its own label (`fleet-channels/1/<account>`).
func messageSource(_ client: String?) -> String {
    guard let client else { return "Another client" }
    if client.hasPrefix("founderizer-ios/") { return "iPhone" }
    if client.hasPrefix("founderizer-swift/") { return "Mac" }
    if client.hasPrefix("fleet-channels/") {
        let account = client.split(separator: "/").last.map(String.init) ?? ""
        if account.hasPrefix("discord") { return "Discord" }
        if account.hasPrefix("whatsapp") { return "WhatsApp" }
        return "A channel"
    }
    return "Another client"
}
