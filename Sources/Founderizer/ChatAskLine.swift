import FleetCore
import SwiftUI

/// **The row of one thing that he asked for, in the agent's chat** (`ChatAskRow`, `ChatAskPlaces`; the owner, 16 November
/// 2026: "this tasks should also show inside the conversation!! like in codex or claude code! not only there", and his
/// three picks to its picture): under the agent's reply of the turn in which the work began, its mark, its name on one
/// line and one muted line under it, on the surface of a card, at most 430 points wide, with the chevron of a row that
/// opens something. A click opens the task (`ChatAskRow.task`) in the card over the window, as a card on Tasks does.
struct ChatAskLine: View {
    @Bindable var store: FleetStore
    let row: ChatAskRow
    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// The mark's size, as in the card Asked's rows.
    private static let mark: CGFloat = 14
    /// The widest that the row stands, as in the picture he said yes to.
    static let width: CGFloat = 430

    /// The row's line: until when its work is parked, in the Tasks board's words ("Resumes at 15:00"), else its own.
    private var line: String {
        guard let until = row.until else { return row.line }
        return fleetResumes(until, now: store.state?.time ?? Date().timeIntervalSince1970)
    }
    /// What the pointer and VoiceOver read under the title.
    private var words: String { row.until == nil ? row.words : line }

    var body: some View {
        Button {
            if let task = row.task { store.show(.task(task)) }
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
        if row.moves { WorkMark(size: Self.mark, moves: store.marksMove) }
        else { Image(systemName: row.symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(row.tint.color) }
    }
}

/// **The head of a request's card that a thing he asked for waits for** (`ChatAskPlaces.onCards`; the owner, 18 November
/// 2026: "Or just combine them, so instead of just going to the other screen, it shows expanded here. Then if more
/// detail is required add a button to go to the task?", and "Yes, build it" to its picture): over the card's title, the
/// ask's mark, its name muted on one line and "Open task" with the chevron of a row that opens something, over a
/// hairline. The head is one button: a click opens the task, as the ask's row does. The card under it is the request,
/// and it is answered there.
struct ChatAskHead: View {
    @Bindable var store: FleetStore
    let row: ChatAskRow
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if let task = row.task { store.show(.task(task)) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: row.symbol).font(IconMetrics.symbol(13)).foregroundStyle(row.tint.color)
                        .frame(width: 16).accessibilityHidden(true)
                    Text(row.title).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text("Open task")
                        Image(systemName: "chevron.right").font(IconMetrics.symbol(10, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                }
                .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.task == nil)
            .modifier(OpensItsTask(store: store, task: row.task))
            .help(row.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.title)
            .accessibilityHint(Text("Opens the task"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("chat-ask-head-\(row.id)")
            // The card's own edge, which Increase Contrast raises.
            Rectangle().fill(FleetStyle.hairline(0.08)).frame(height: FleetStyle.edgeWidth(contrast)).accessibilityHidden(true)
        }
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
