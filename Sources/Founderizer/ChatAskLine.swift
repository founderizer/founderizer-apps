import FleetCore
import SwiftUI

/// **The row of one thing that he asked for, in the agent's chat** (`ChatAskRow`, `ChatAskPlaces`; the owner, 16 November
/// 2026: "this tasks should also show inside the conversation!! like in codex or claude code! not only there", and his
/// three picks to its picture): under the agent's reply of the turn in which the work began, its mark, its name on one
/// line and one muted line under it, on the surface of a card, at most 430 points wide, with the chevron of a row that
/// opens something. A click opens the task (`ChatAskRow.task`), as a card on Tasks does.
struct ChatAskLine: View {
    @Bindable var store: FleetStore
    let row: ChatAskRow
    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// The mark's size, as in the card Asked's rows.
    private static let mark: CGFloat = 14
    /// The widest that the row stands, as in the picture he said yes to.
    static let width: CGFloat = 430

    /// The row's line: until when its work is parked, in the Tasks board's words ("Until 15:00"), else its own.
    private var line: String {
        guard let until = row.until else { return row.line }
        return String(l10n: "Until \(fleetComingTime(until, now: store.state?.time ?? Date().timeIntervalSince1970))")
    }
    /// What the pointer and VoiceOver read under the title.
    private var words: String { row.until == nil ? row.words : line }

    var body: some View {
        Button {
            if let task = row.task { store.destination = .task(task) }
        } label: {
            HStack(spacing: 11) {
                mark.frame(width: 16).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
                    // The word of a result that did not succeed is red, as on the board; every other line is muted.
                    Text(line).font(FormMetrics.detail).lineLimit(1)
                        .foregroundStyle(row.tint == .failed ? EndedRow.failedWords : FleetStyle.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold))
                    .foregroundStyle(FleetStyle.muted).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: Self.width, alignment: .leading)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            // The edge of the board's cards, which Increase Contrast raises (`BoardCardLook`).
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
                .strokeBorder(FleetStyle.hairline(hovered ? 0.16 : 0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
            .contentShape(RoundedRectangle(cornerRadius: FormMetrics.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .modifier(OpensItsTask(store: store, task: row.task))
        .help([row.title, words].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.title, words].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("chat-ask-\(row.id)")
    }

    /// The card Asked's marks: the orange raised hand, the green work mark that turns while a turn runs, else the
    /// board's mark of its task in its colour.
    @ViewBuilder private var mark: some View {
        if row.moves { WorkMark(size: Self.mark) }
        else { Image(systemName: row.symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(row.tint.color) }
    }
}

/// `opensTask` for a row that may have no task to open.
private struct OpensItsTask: ViewModifier {
    let store: FleetStore
    let task: Int?

    func body(content: Content) -> some View {
        if let task { content.opensTask(task, store: store) } else { content }
    }
}
