import AppKit
import FleetCore
import SwiftUI

/// **The badge of his held answer, at the foot of the sidebar** (the owner, 22 November 2026: "complete it immediately
/// and show like a badge at the bottom of the page that shows what has been chosen, slightly animated nicely, and
/// include a button link to undo"; 23 November 2026: "a small floating badge on the side that says Undo ... which brings
/// the card back", and his answer F22-1 (a) to its pictures: the foot of the sidebar, as Apple Mail's Undo Send). His
/// answer completes on its card in the frame of his press, and the app still holds its send for 5 seconds
/// (`AnswerHolds`): the badge is the face of that hold. It stands at the foot of the main window's sidebar, under the
/// line that ends the agents' list and over Settings (and over the Update banner while that shows), on every page, while
/// an answer that he gave on a page of the main window waits; one at most. **Its Undo brings the card back**: Needs you
/// with the request at hand, or the agent's chat with its card open and in view. The card's own window becomes a badge
/// of its own (`NeedWindows`), and the job's detail card keeps Undo on the card's line (`NeedRequestCard.lineEnd`).
///
/// - One line: a check for an option that he pressed or ticked, none for words that he wrote (his rule of 14 November
///   2026); the words of the folded card's answer line, plain, as the card reads them (`Look`: the agent of a role that
///   an option names by its name, with the role beside it), cut with "…" at the sidebar's width less 12 points each
///   side, and "Undo" in the colour of a link, with the hand, never cut. No title, no count, no close button.
/// - The look of the hover tag (`HoverTag`): a capsule in `FleetStyle.lifted` with its one-point edge.
/// - It comes up 8 points and fades in over 0.18 s, as his own message does, and fades out over 0.12 s; a new answer
///   changes its words in place over 0.15 s (`AnyTransition.answerBadge`, `FleetMotion.badgeWords`), and the sidebar's
///   line over it moves with it over the same times (`FleetView.sidebar`). Under Reduce Motion it stands and goes in
///   one frame, and so does the line.
/// - Edit › Undo (⌘Z) takes the answer back while the badge stands and it is the newest act that can be undone: the
///   window's undo manager holds it from the badge's coming to its going, so words typed after it are undone first.
/// - VoiceOver reads one element, "<title>, answered: <words>", with the action Undo.
struct AnswerBadge: View {
    @Bindable var store: FleetStore
    /// The sidebar's width, which the badge stands in.
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    /// The owner of the badge's act in the window's undo manager, and the manager that holds it.
    @State private var undoTarget = UndoTarget()
    @State private var undoKept: UndoManager?

    /// From the sidebar's edges to the badge's, each side.
    static let inset: CGFloat = 12

    /// **What the badge says of a held answer**, as the folded card's answer line says it.
    struct Look: Equatable {
        /// An option that he pressed or ticked: a check before the words. Words that he wrote have none.
        let check: Bool
        /// The option's own words, the ticked options joined with "; ", his own words, or "Answered" for files alone,
        /// as the folded card reads them (`HisAnswer.spoken`): a role that an agent's words name is that agent's name
        /// with its role beside it, and his own words keep a role as he wrote it. VoiceOver reads the same words.
        let words: String
        /// Files alone, with no words: the badge says "Answered".
        let filesAlone: Bool

        /// `names`: the request's names, as its card has them (`FleetStore.cardNames`).
        init(_ shown: PendingRequest, need: OwnerNeed, names: CardNames?) {
            check = !shown.answersInWords
            let text = shown.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let typed = HisAnswer.typed(need, text, inWords: shown.answersInWords)
            filesAlone = text.isEmpty
            words = filesAlone ? String(l10n: "Answered") : HisAnswer.spoken(text, inWords: typed, names: names)
        }

        /// What VoiceOver hears of the held answer (the row of Needs you, the capsule of a card's own window):
        /// "Answered: <words>", and "Answered" alone only for files alone, also when his own words are "Answered".
        var announced: String { filesAlone ? words : String(l10n: "Answered: \(words)") }
    }

    var body: some View {
        let shown = AnswerHolds.shared.onAnyPage(in: store)
        let look = shown?.held.look
        ZStack {
            if let shown, let look {
                AnswerBadgeCapsule(look: look, title: shown.need.shownTitle) {
                    Self.undo(shown.need, store: store)
                }
                .animation(reduceMotion ? nil : FleetMotion.badgeWords, value: look)
                .transition(reduceMotion ? .identity : .answerBadge)
            }
        }
        // as wide as its words, at most the sidebar's width less 12 points each side (the sidebar's own room is 10)
        .frame(maxWidth: max(width - 2 * Self.inset, 0), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Self.inset - 10).padding(.bottom, shown == nil ? 0 : 6)
        .onChange(of: shown?.need.id, initial: true) { _, _ in keepUndo(for: shown?.need) }
        .onDisappear { keepUndo(for: nil) }
    }

    /// **Undo: his answer goes nowhere, and the card comes back as it was** (`AnswerHolds.undo`), on the page where he
    /// gave it, from any page: Needs you with the request at hand, or the agent's chat with its card in view
    /// (`FleetStore.chatFocus`, as a match of the search card opens a chat at its row).
    private static func undo(_ need: OwnerNeed, store: FleetStore) {
        let page = AnswerHolds.shared.pageOf(need)
        AnswerHolds.shared.undo(need, store: store)
        if page == Destination.needs.page {
            store.destination = .needs
        } else if let page, page.hasPrefix("agent/") {
            let agent = String(page.dropFirst("agent/".count))
            if store.destination != .agent(agent) {
                store.destination = .agent(agent)
                store.chatFocus = ChatFocus(agent: agent, entry: "need-\(need.id)", at: need.raised)
            }
        }
        if store.destination == .needs { store.selectedNeed = need.id }
    }

    /// **The badge's act in the window's undo manager**, from its coming to its going: Edit › Undo (⌘Z) takes the
    /// answer back while it is the newest act that can be undone. No new menu item: Edit › Undo is the system's.
    /// The main window's own undo manager, which its Edit › Undo reaches (`NSWindow.undo:`).
    private func keepUndo(for need: OwnerNeed?) {
        undoKept?.removeAllActions(withTarget: undoTarget)
        undoKept = nil
        guard let need, let manager = NSApp.windows.first(where: { $0.identifier?.rawValue == SetupChannel.fleetWindow })?
            .undoManager ?? undoManager else { return }
        let store = store
        manager.registerUndo(withTarget: undoTarget) { _ in
            MainActor.assumeIsolated { Self.undo(need, store: store) }
        }
        undoKept = manager
    }

    /// The owner of the badge's act in the undo manager, by which the badge takes it away.
    final class UndoTarget {}
}

/// **The capsule of a held answer** (`AnswerBadge` at the foot of the sidebar, and the card's own window that becomes it,
/// `NeedWindows`): a check for an option, the answer's words, cut with "…" where its room ends, and "Undo" in the colour
/// of a link, never cut; one element for VoiceOver, "<title>, answered: <words>", with the action Undo. As wide as its
/// words, at most the width that it is given.
struct AnswerBadgeCapsule: View {
    let look: AnswerBadge.Look
    let title: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                if look.check {
                    Image(systemName: "checkmark").font(IconMetrics.symbol(10, weight: .semibold)).accessibilityHidden(true)
                }
                // plain text: an option's words are the agent's, and make no link and no control here
                Text(verbatim: look.words).lineLimit(1).truncationMode(.tail).contentTransition(.opacity)
            }
            Button("Undo") { undo() }
                .buttonStyle(.plain).font(FormMetrics.detail.weight(.medium)).foregroundStyle(FleetStyle.link)
                .pointerStyle(.link)
                .fixedSize().layoutPriority(1)
                .accessibilityIdentifier("answer-badge-undo")
        }
        .font(FormMetrics.detail).foregroundStyle(FleetStyle.text)
        .padding(.horizontal, 12).padding(.vertical, HoverTag.inset.height)
        // the hover tag's fill and its one-point edge, as two capsules: a stroked capsule drew a strip of one point
        // beside its round ends in the window's off-screen picture
        .background(Capsule().fill(FleetStyle.lifted).padding(1)
            .background(Capsule().fill(FleetStyle.lifted).overlay(Capsule().fill(FleetStyle.hairline(0.12)))))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), answered: \(look.words)"))
        .accessibilityActions { Button("Undo") { undo() } }
        .accessibilityIdentifier("answer-badge")
    }
}
