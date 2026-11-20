import FleetCore
import SwiftUI

/// **The card of one run of grants in the agent's chat** (`ChatGrantPlaces`; the owner, 19 November 2026, of eight
/// lines "I gave … the GitHub repository …" in a row in his chat with the Fleet Manager: "Yes, draw it", and "A: the
/// card" to its picture): its title, and one row for each grant, with the agent, the resource and the level each in a
/// column of its own. An agent stands once, over its rows, by the name and the glyph that the app gives it. A
/// repository stands by its name, and each other kind of resource with the line's word for it before its name
/// (`ChatGrantPlaces.Row.resource`). The level is the line's own word for it, muted. The words of a row can be
/// selected, as a line's could. **The pointer on a row shows the line as the hub wrote it**, with the reason
/// of the grant. It is a card as an answered request is one, on the same surface and at the column's width: a record
/// that he reads down, not words of the conversation. It opens nothing.
///
/// **It does not say what GitHub needs for a deploy.** Each line of a deploy grant ends with that sentence, written with
/// no check of the App, and on his fleet that day it was not true for the six repositories whose App held both
/// permissions: the card repeats no sentence that the hub did not check. The pointer still shows it, in the line.
struct ChatGrantsCard: View {
    let lines: [ManagerReport]
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let rows = ChatGrantPlaces.cardRows(lines)
        // The agents and the levels of the card, each once: the widest of each gives its column its width.
        let agents = rows.filter(\.leads).map(\.grant.agent)
        let levels = Array(Set(rows.compactMap(\.grant.words))).sorted()
        VStack(alignment: .leading, spacing: 12) {
            Text("Access given").font(ChatStyle.title).foregroundStyle(FleetStyle.text)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        // **Three columns that the rows share**: the agent's is as wide as the widest agent of the
                        // card and the level's as the widest level, each measured by its own words drawn hidden, and
                        // the resource takes the room between them, cut in its middle when it is longer.
                        ZStack(alignment: .leading) {
                            ForEach(agents, id: \.self) { agent($0).hidden().accessibilityHidden(true) }
                            if row.leads { agent(row.grant.agent) }
                        }
                        // The row has the id of its line, so a search match on that line shows it in the chat.
                        Text(row.resource).lineLimit(1).truncationMode(.middle).selectableWords()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(ChatEntry.report(row.report).id)
                        ZStack(alignment: .leading) {
                            ForEach(levels, id: \.self) { level($0).hidden().accessibilityHidden(true) }
                            level(row.grant.words ?? "").selectableWords()
                        }
                    }
                    // An agent's rows stand together: 6 points more over the first row of the next agent.
                    .padding(.top, row.leads && index > 0 ? 6 : 0)
                    .contentShape(Rectangle())
                    .help(row.report.text)
                    // Each row says its agent, also a row under the agent's first one, which shows none.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: [row.grant.agent.agentLabel, row.resource, row.grant.words ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: ", ")))
                }
            }.font(FormMetrics.text).foregroundStyle(FleetStyle.text)
        }
        .padding(FormMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        // The edge of every card of the chat, which Increase Contrast raises (`NeedRequestCard`).
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
            .strokeBorder(FleetStyle.hairline(0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-grants-\(lines.first?.id ?? 0)")
    }

    /// An agent as the app names it, with its glyph before its name.
    private func agent(_ name: String) -> some View {
        AgentNamed(agent: name) { Text(name.agentLabel).lineLimit(1) }
    }

    /// A level, in the line's own words, muted, at the size of a card's small lines.
    private func level(_ words: String) -> some View {
        Text(words).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
    }
}
