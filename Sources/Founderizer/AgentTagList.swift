import FleetCore
import SwiftUI

/// **The list of @ tags in the chat's box** (the owner, 20 November 2026: "@<agent-name> or @<agent-role> allows tagging
/// an agent", and "Yes, as drawn" to the list; `AgentTags` has its rules): the first part over the line in the
/// composer's capsule, one row for each other agent of the team, its glyph as its row of the sidebar shows it and its
/// label in the chat's font, and the lighter row in the fill of the highlighted row of the app's menu
/// (`FleetMenuMetrics`). No heading, no second line, no hint and no words for no match: an empty list is closed. **At
/// most six rows show**, and the list scrolls to keep the lighter row in view. The pointer over a row makes it the
/// lighter row, and a click picks it; the keys are the box's (`FleetView.composer`).
struct AgentTagList: View {
    let rows: [AgentTags.Row]
    /// The lighter row: Return or Tab picks it.
    let lighter: Int
    let hover: (Int) -> Void
    let pick: (AgentTags.Row) -> Void
    /// The rows that show before the list scrolls.
    static let shown = 6

    var body: some View {
        let count = min(rows.count, Self.shown)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: FleetMenuMetrics.spacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        // a plain button: a click presses it as the app's other buttons, and the box keeps the keys
                        Button { pick(row) } label: { line(row, lighter: index == lighter) }
                            .buttonStyle(.plain)
                            .onHover { inside in if inside { hover(index) } }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: row.label))
                            .accessibilityAddTraits(index == lighter ? .isSelected : [])
                            .id(row.id)
                    }
                }
            }
            .scrollIndicators(rows.count > Self.shown ? .automatic : .never)
            .frame(height: CGFloat(count) * FleetMenuMetrics.row + CGFloat(max(count - 1, 0)) * FleetMenuMetrics.spacing)
            .onChange(of: lighter) { _, now in
                if rows.indices.contains(now) { proxy.scrollTo(rows[now].id) }
            }
        }
    }

    private func line(_ row: AgentTags.Row, lighter: Bool) -> some View {
        HStack(spacing: FleetMenuMetrics.markGap + 2) {
            AgentGlyph(name: row.agent, size: GlyphSize.row, ground: FleetStyle.composer)
            Text(verbatim: row.label).font(ChatStyle.font).foregroundStyle(FleetStyle.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FleetMenuMetrics.lead)
        .frame(height: FleetMenuMetrics.row)
        .background(lighter ? FleetMenuMetrics.highlight : .clear,
                    in: RoundedRectangle(cornerRadius: FleetMenuMetrics.rowRadius, style: .continuous))
        .contentShape(Rectangle())
    }
}
