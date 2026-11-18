import AppKit
import SwiftUI

// The app's short motions (the owner's yes of 17 November 2026 to the moving demo of ten changes: "All ten"). Each
// one moves a thing that the app already drew in one frame, adds no element and no word, and stands still under
// Reduce Motion. One curve, ease-out, and the times that UI-PATTERNS.md names under "Short motions".
enum FleetMotion {
    /// A page that comes: its fade.
    static let page = 0.15
    /// The fill of the selected row of a sidebar, from the row that had it to the row that has it.
    static let selection = Animation.easeOut(duration: 0.18)
    /// The cards of a lane that close the room of a card that left, and the fade of a card that came.
    static let lane = Animation.easeOut(duration: 0.2)
    /// A card's fill when the pointer leaves it; it comes at once.
    static let pointerOut = Animation.easeOut(duration: 0.15)
    /// A pressed card, to its smaller size and back.
    static let press = Animation.easeOut(duration: 0.12)
    /// A usage bar to the length of a new reading.
    static let bar = Animation.easeOut(duration: 0.3)
    /// A number that rolls to a new reading (`rolls(_:)`, `rolls(words:)`).
    static let number = Animation.easeOut(duration: 0.25)
    /// "Latest": the chat to its end.
    static let latest = Animation.easeOut(duration: 0.25)
    /// His own message, up from the composer.
    static let sent = Animation.easeOut(duration: 0.18)
    /// The card over the page: its window's fade in and out, and the card's own growth to its size.
    static let cardIn = 0.15, cardOut = 0.12, cardGrows = Animation.easeOut(duration: 0.18)
    /// A menu's window: its fade in and out.
    static let menuIn = 0.1, menuOut = 0.08

    /// The system's Reduce Motion, for the windows that AppKit moves (a view reads its own environment).
    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// **A window's fade, in this app's own steps**: the alpha of a card's or a menu's window from where it stands to its
/// end over a time, ease-out, and then what comes after (the window leaves). It sets the window's alpha itself, 120
/// times a second, by the clock, and does not use AppKit's `animator()`: a window that closes must leave whatever
/// animation context AppKit has at that moment, and a SwiftUI update can call this inside one. A new run takes the
/// place of the one before it, from the alpha of that moment, so a card that closes while it comes goes from there.
/// A window that leaves with no fade stops its run first (`stop`), so that no run sets the alpha of a window that has
/// left. A run whose owner is gone ends its own timer.
@MainActor final class WindowFade {
    private var timer: Timer?
    private var step: (() -> Void)?

    func run(_ window: NSWindow, to end: CGFloat, over seconds: Double, then done: @escaping @MainActor () -> Void = {}) {
        stop()
        let start = window.alphaValue, began = CACurrentMediaTime()
        step = { [weak self, weak window] in
            guard let self else { return }
            guard let window else { self.stop(); return }
            let passed = min(1, (CACurrentMediaTime() - began) / max(seconds, 0.001))
            window.alphaValue = start + (end - start) * (1 - (1 - passed) * (1 - passed))
            if passed >= 1 {
                self.stop()
                done()
            }
        }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            // Its owner is gone, and nothing can stop it any more: it ends itself.
            guard self != nil else { timer.invalidate(); return }
            MainActor.assumeIsolated { self?.step?() }
        }
        // Also while a menu or a scroll holds the run loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Ends the run where it stands, with nothing after it.
    func stop() {
        timer?.invalidate()
        timer = nil
        step = nil
    }
}

extension Destination {
    /// **The page that a place shows**, for the fade of a page that comes (`marksPageChange` in `FleetView`). All of
    /// Settings is one page here, and all of one agent's details: their own sidebar stays while the part beside it
    /// changes, and that part has a fade of its own (`part` and `arrives`; `SettingsPage`, `AgentPage`).
    var page: String {
        switch self {
        case .needs: "needs"
        case .activity: "tasks"
        case .agents: "agents"
        case .addAgent: "add-agent"
        case .task(let id): "task/\(id)"
        case .work(let name, let key): "work/\(name)/\(key)"
        case .agent(let name): "agent/\(name)"
        case .signIn(let name): "sign-in/\(name)"
        case .agentDetail(let name, _), .agentRule(let name, _): "details/\(name)"
        case .settings, .server, .addServer, .app, .connectKey, .shapeChange: "settings"
        }
    }

    /// **The part that shows beside the own sidebar** of Settings or of an agent's details, for that part's fade. It
    /// leaves out the agent's name: from one agent's details to another's the whole page comes (`page`), and a second
    /// fade under the first would make the part come later than its own sidebar.
    var part: String {
        switch self {
        case .agentDetail(_, let tab): "tab/\(tab.rawValue)"
        case .agentRule(_, let id): "rule/\(id.map { "\($0.key)/\($0.occurrence)" } ?? "new")"
        default: "\(self)"
        }
    }
}

extension View {
    /// **A page that comes fades in over 0.15 s, and the page before it goes at once** (the owner's yes of 17 November
    /// 2026): the new page stood in the old one's place in one frame. Opacity only: nothing slides, and nothing of the
    /// page is laid out again. `key` names the page; the fade runs when it changes, never on the first frame. It stands
    /// on a view that stays while the page under it changes: a view that comes with the page has no change to see.
    func arrives<Key: Equatable & Sendable>(with key: Key) -> some View { modifier(PageArrival(key: key)) }

    /// **The same fade for a page whose parts do not stand in one view**: the window's column and the panel beside it,
    /// which keeps its own place in the window's row (its width gives way first in a narrow window, `sideMenu`). The
    /// part that stays marks the change of the page into `clear`, and each part draws by it (`.opacity`): so a panel
    /// that comes with its page fades in with it, and the row is laid out as it was.
    func marksPageChange<Key: Equatable & Sendable>(_ key: Key, clear: Binding<Bool>) -> some View {
        modifier(PageChange(key: key, clear: clear))
    }

    /// A value in words that changes rolls to its new digits, as a count does (`rolls(_:)` of a number): a share of
    /// usage, a load, a size.
    func rolls(words: String) -> some View { modifier(RollsWords(words: words)) }

    /// **A pressed card is 98% of its size and comes back over 0.12 s** (`FleetMotion.press`). Under Reduce Motion it
    /// keeps its size and is a little dimmer while it is pressed, so a press still shows.
    func pressScale(_ pressed: Bool) -> some View { modifier(PressScale(pressed: pressed)) }

    /// **A menu's list comes 4 points down into its place** while its window fades in (`FleetMenu.show`,
    /// `FleetMotion.menuIn`). Each menu is a new list, so each one comes.
    func menuArrives() -> some View { modifier(MenuArrival()) }
}

private struct MenuArrival: ViewModifier {
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.offset(y: arrived || reduceMotion ? 0 : -4)
            .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: FleetMotion.menuIn)) { arrived = true } }
    }
}

private struct PageArrival<Key: Equatable & Sendable>: ViewModifier {
    let key: Key
    /// The page that came is clear: for the one frame in which it takes the old page's place.
    @State private var clear = false

    func body(content: Content) -> some View {
        content.opacity(clear ? 0 : 1).modifier(PageChange(key: key, clear: $clear))
    }
}

private struct PageChange<Key: Equatable & Sendable>: ViewModifier {
    let key: Key
    @Binding var clear: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Clear with no animation in the update that brings the page, so no frame shows it whole first; whole again
        // over 0.15 s from the next turn of the run loop. A `keyframeAnimator` with this key as its trigger started
        // and drew nothing for a page under a second one of them (a section of Settings): its value stood at 0 and the
        // page at 1.
        content.onChange(of: key) {
            guard !reduceMotion else { return }
            var cut = Transaction(animation: nil)
            cut.disablesAnimations = true
            withTransaction(cut) { clear = true }
            let clear = $clear
            DispatchQueue.main.async { withAnimation(.easeOut(duration: FleetMotion.page)) { clear.wrappedValue = false } }
        }
    }
}

private struct RollsWords: ViewModifier {
    let words: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(.numericText())
            .animation(reduceMotion ? nil : FleetMotion.number, value: words)
    }
}

private struct PressScale: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .opacity(pressed && reduceMotion ? 0.85 : 1)
            .animation(reduceMotion ? nil : FleetMotion.press, value: pressed)
    }
}

/// A lane's card that is a button (Needs you): plain, and 98% of its size while it is pressed, as a card of Tasks is.
struct BoardCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.pressScale(configuration.isPressed) }
}

extension EnvironmentValues {
    /// **The sidebar whose selected row's fill moves** from the row that had it to the row that has it, over 0.18 s
    /// (`FleetMotion.selection`). The sidebar gives its namespace and the animation of its own selection, and each of
    /// its groups of rows draws the fill (`selectionFill`); a row outside one draws its fill in place (`SidebarFill`).
    @Entry var selectionSpace: Namespace.ID? = nil
}

/// Where the selected row of a group of rows stands, for the one fill that the group draws behind its rows.
private struct SelectedRowKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

extension View {
    /// On a row's own ground: it is the selected row of its sidebar, and its group draws its fill (`selectionFill`).
    func selectedRow(_ selected: Bool) -> some View {
        anchorPreference(key: SelectedRowKey.self, value: .bounds) { selected ? $0 : nil }
    }

    /// **On a group of rows of a sidebar: the selected row's fill, one thing behind all the rows**, so it moves under
    /// the words of the rows between and never over them. In its group it goes to the place and the size of the row
    /// that he opens, a nav row's 32 points or a chat's 50; to a row of another group (from Tasks to a chat, which
    /// scrolls with its list) the other group's fill starts where this one stood, whole from its first frame, and
    /// this one fades under it (`selectionSpace`). **A fill that he cannot see is no start for another group's**:
    /// when the selected chat is scrolled out of its list and he opens Tasks, that row's fill stands in its place at
    /// once, and does not come across the sidebar from a place outside the list.
    func selectionFill(_ color: Color) -> some View { modifier(SelectionFill(color: color)) }
}

private struct SelectionFill: ViewModifier {
    let color: Color
    @Environment(\.selectionSpace) private var space
    /// How often the selected row came into view or left it: each time, the fill is drawn again and reads its place.
    @State private var crossings = 0

    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(SelectedRowKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor, let space {
                    let row = proxy[anchor]
                    // **In view, read from the row's own place each time this is drawn**, never kept: the visible part
                    // of the list that the group scrolls in, or everything for a group that does not scroll. A kept
                    // answer stood wrong for the next selection, and an answer asked of the fill itself is no for a
                    // fill that comes from another group, which starts outside its list.
                    let _ = crossings
                    // By the probe's own measure, 1% of the row: with any overlap at all, the draw that follows the
                    // probe's "left" could still see a sliver and say in view, and no later crossing would correct it.
                    let inView = proxy.bounds(of: .scrollView).map { $0.intersection(row).height >= 0.01 * row.height } ?? true
                    Color.clear.frame(width: row.width, height: row.height)
                        .onScrollVisibilityChange(threshold: 0.01) { _ in crossings += 1 }
                        .position(x: row.midX, y: row.midY)
                    RoundedRectangle(cornerRadius: FormMetrics.inner).fill(color)
                        .frame(width: row.width, height: row.height)
                        .matchedGeometryEffect(id: inView ? "selected-row" : "selected-row-out-of-view", in: space)
                        .position(x: row.midX, y: row.midY)
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
        }
        // The groups around this one draw a fill for their own rows only.
        .transformPreference(SelectedRowKey.self) { $0 = nil }
    }
}

extension AnyTransition {
    /// A card that comes into a lane fades in while the cards under it make room; a card that leaves goes at once, and
    /// the cards under it close its room (`FleetMotion.lane`, which the lane gives).
    static var laneCard: AnyTransition { .asymmetric(insertion: .opacity, removal: .identity) }

    /// **His own message comes up 8 points from the composer and fades in over 0.18 s** (the owner's yes of 17 November
    /// 2026): an agent's reply fades in (`ReplyArrival`), and his own words stood there in one frame.
    static var sentMessage: AnyTransition {
        .asymmetric(insertion: .offset(y: 8).combined(with: .opacity).animation(FleetMotion.sent), removal: .identity)
    }
}
