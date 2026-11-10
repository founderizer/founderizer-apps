import FleetCore
import SwiftUI

/// **One row's whole answer: a mark.** The sentence it used to print is behind the mark, and it opens three ways.
///
/// The owner, 20 October 2026: "not even sentences, just a check or a cross, and on hover probably show the
/// detail? This applies to all menus, it needs to be simpler!"
///
/// **Hover is not enough on its own**, which is the one thing that makes the naive version of this worse than
/// what it replaces. A tooltip is invisible to the keyboard, invisible on a touch screen, and this family has an
/// iPhone app. So the same text opens four ways and is written once:
///
///   - the pointer rests on the mark (after a moment, as the provider card does);
///   - a click, which keeps it open until the next click or Esc;
///   - the keyboard: it is a `Button`, so Full Keyboard Access reaches it and Space opens it;
///   - VoiceOver, which reads the word and the detail off the mark itself and opens nothing at all.
///
/// **A cross carries its action.** The owner's oldest complaint about this app is a screen that reports a problem
/// and leaves him nowhere to go, and a cross with only a tooltip behind it is that same failure in a smaller
/// shape. So a mark that is not good takes either `act` — the one thing he presses — or `whoActs`, which says who
/// can when he cannot. One of the two, never neither.
///
/// **There are two kinds of `fix` in this app and they are not interchangeable.** A `fix` on a health warning is
/// written by our own hub code and names an action this app can take, so it becomes a button (`act`). A `fix`
/// that arrives inside a machine's own `verify` answer is **text that a machine sent us**, and a button that ran
/// it would be this Mac doing whatever a remote machine asked — the fleet's own first rule, that an instruction
/// is not a permission, arriving in the app. That one gets Report a problem, which carries it to one of his
/// agents, and never a button, however safe the command looks.
struct StateMark: View {
    let state: MarkState
    /// The word behind the mark, in this row's own terms. It is the accessibility label and the detail's heading.
    var words: String?
    /// The sentence the app keeps and shows when he asks for it.
    var detail: String?
    /// What to do about it, when he can do something: the button's words, and what it does.
    var act: (words: String, run: () -> Void)?
    /// Who can act, when he cannot. It stands in the place of the button, so a cross is never a dead end.
    var whoActs: String?
    var size: CGFloat = 14

    @State private var hovering = false
    @State private var shown = false
    /// A click keeps it open; the pointer leaving does not take it away again.
    @State private var kept = false
    @FocusState private var focused: Bool

    private var said: String { words ?? state.words }

    private var tint: Color { state.tint }

    var body: some View {
        Button {
            kept.toggle()
            shown = kept
        } label: {
            Image(systemName: state.symbol).font(IconMetrics.symbol(size)).foregroundStyle(tint)
                .frame(width: IconMetrics.small, height: IconMetrics.small)
        }
        .buttonStyle(FleetIconButtonStyle(side: IconMetrics.small))
        .focused($focused)
        // The pointer, with the same wait the provider card takes, so a mark does not flash while he moves past.
        .onHover { inside in
            hovering = inside
            if inside {
                Task { try? await Task.sleep(for: .milliseconds(350)); if hovering { shown = true } }
            } else if !kept {
                shown = false
            }
        }
        .onChange(of: focused) { _, now in
            if now { shown = true } else if !kept { shown = false }
        }
        .popover(isPresented: $shown, arrowEdge: .bottom) { card }
        .onChange(of: shown) { _, now in if !now { kept = false } }
        // What a reader hears without opening anything: the word, then the detail, then what to do about it.
        .accessibilityLabel(said)
        .accessibilityValue(spoken)
        .help(hovered)
    }

    /// What a reader hears off the mark itself, without opening anything.
    private var spoken: String {
        let next: String? = act.map { "Press for \($0.words)." } ?? whoActs
        let parts: [String] = [detail, next].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    /// What the pointer shows: the same word and the same sentence, written once.
    private var hovered: String {
        let parts: [String] = [said, detail].compactMap { $0 }
        return parts.joined(separator: " — ")
    }

    /// What the mark holds: the word, the sentence, and the one thing to do about it.
    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: state.symbol).font(IconMetrics.symbol(12)).foregroundStyle(tint)
                Text(said).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
            }
            if let detail {
                Text(detail).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let act {
                Button(act.words) { shown = false; kept = false; act.run() }
                    .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("mark-act")
            } else if let whoActs {
                Text(whoActs).font(FormMetrics.detail).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // **One width, and it is exact.** `maxWidth` here gave the popover no size it could settle on, and the
        // card came out several times as tall as its two lines with the text floating in the middle of it (the
        // owner, 20 October 2026: "popover is out of proportions!"). The provider card, the app's other popover,
        // has always said `width:` and has always been right, so this says the same number.
        .padding(14).frame(width: 300, alignment: .leading)
    }
}

extension MarkState {
    /// The one colour of each mark, so nothing that draws a mark picks its own.
    var tint: Color {
        switch self {
        case .good: Color.green.opacity(0.85)
        case .bad: .orange
        case .warn: .yellow
        case .unknown, .working: FleetStyle.muted
        }
    }
}

/// **The mark of a row that is already one button.** A list whose whole row opens a page cannot hold `StateMark`,
/// because a `Button` inside a `Button` is not a control the keyboard or VoiceOver can reach. So this is the shape
/// and the colour and nothing that can be pressed, and the row itself carries the sentence — `.help` for the
/// pointer, `accessibilityValue` for a reader — which is the same answer the duty list got.
///
/// **Two rules a column of marks needs, and both are about where it is, not what it says.**
///
/// It is the same box as `StateMark`, because the symbols are not the same width — a triangle is wider than a
/// circle — and a mark that sizes itself to its own glyph stands at a different place in each row. One box, and a
/// list of ticks and crosses is a column.
///
/// And it goes **immediately beside the row's last fixed-width control** — the chevron of a list row, the icon
/// button of a card row — because everything else in that cluster is a different width in every row: one person
/// writes from two chat apps and the next from one, an age is "2 min ago" over "yesterday", a button says Make a
/// code in one row and New code in the next.
struct RowStateMark: View {
    let state: MarkState
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: state.symbol).font(IconMetrics.symbol(size)).foregroundStyle(state.tint)
            .frame(width: IconMetrics.small, height: IconMetrics.small)
            .accessibilityHidden(true)
    }
}

/// **A row that states a fact, answered by one mark.** It is `FormRow` with the mark in the control slot and
/// nothing in the detail slot: the sentence is behind the mark, which is the whole of the rule.
///
/// A row that asks him to decide something is not one of these. It keeps its sentence and its buttons, because
/// the answer there is not yes or no.
struct FormMarkRow: View {
    let title: String
    let state: MarkState
    var symbol: String?
    var words: String?
    var detail: String?
    var act: (words: String, run: () -> Void)?
    var whoActs: String?
    var identifier: String?

    var body: some View {
        FormRow(title, symbol: symbol) {
            StateMark(state: state, words: words, detail: detail, act: act, whoActs: whoActs)
        }
        .accessibilityIdentifier(identifier ?? "mark-\(title)")
    }
}
