import Foundation

/// **The lines of the grants that a manager made, as one card in its chat** (the owner, 19 November 2026, of eight
/// lines "I gave … the GitHub repository …" in a row in his chat with the Fleet Manager: "Yes, draw it", and "A: the
/// card" to its picture; the Mac's `ChatGrantsCard`). The hub writes one line for each grant, with no notification,
/// because the owner must see who gave what to whom without looking for it. On his fleet 45 of 48 such lines came in
/// runs of 2 to 11, each a whole paragraph: the record of what was given read as a wall of text.
///
/// **One run is one row, at the place of its last line**: the lines that say a grant (`ManagerReport.grant`, owner
/// API 1.236) and follow each other with no other words between them. A message of his, any other message of the
/// agent's, and the row of a thing that he asked for end a run. **A request's card between two of the lines does not**:
/// he answers cards while the manager gives what those answers allow, and the lines then stand between the cards of
/// his answers (`ChatRequestPlaces.Answered.atItsAnswer`); the cards stay where they stand, over the run's row. Lines
/// more than an hour apart, or of two days, are two runs, as the chat's marks of a day or an hour part its rows
/// (`ChatStamp`). A line that stands alone is a run of one: every grant reads the same way.
public struct ChatGrantPlaces: Sendable, Equatable {
    /// The chat's rows, with each run of grant lines as one row `.grants(first)`, by the number of its first line.
    public var rows: [ChatPart] = []
    /// The lines of each run, oldest first, by the number of its first line. A run keeps that number, and so its row
    /// keeps its identity, when a line comes under its last one.
    public var runs: [Int: [ManagerReport]] = [:]
    /// The time of each run's row, its newest line's: for the marks of a day or an hour (`ChatRequestPlaces.times`).
    public var times: [Int: Double] = [:]

    public init() {}

    /// `rows`: the chat's rows as it draws them, with the cards and the rows of his asks in their places.
    public init(_ rows: [ChatPart], calendar: Calendar = .current) {
        // The rows of each run, by their places in `rows`.
        var found: [[Int]] = []
        var open: [Int] = []
        var last: Double?
        func close() {
            if !open.isEmpty { found.append(open) }
            open = []
            last = nil
        }
        for (index, row) in rows.enumerated() {
            switch row {
            case .entry(.report(let report)) where report.grant != nil:
                if let last, !Self.together(last, report.created, calendar) { close() }
                open.append(index)
                last = report.created
            case .request:
                continue
            default:
                close()
            }
        }
        close()

        var rowAt: [Int: Int] = [:]         // the place of each run's last line: the number of the run's first line
        var skipped = Set<Int>()
        for run in found {
            let lines: [ManagerReport] = run.compactMap { index in
                if case .entry(.report(let report)) = rows[index] { report } else { nil }
            }
            guard let first = lines.first?.id, let end = run.last, let newest = lines.last else { continue }
            runs[first] = lines
            times[first] = newest.created
            rowAt[end] = first
            skipped.formUnion(run.dropLast())
        }
        self.rows = rows.enumerated().compactMap { index, row in
            if skipped.contains(index) { return nil }
            return rowAt[index].map(ChatPart.grants) ?? row
        }
    }

    /// Two grant lines are of one run by their times: at most an hour apart, on one day.
    private static func together(_ earlier: Double, _ later: Double, _ calendar: Calendar) -> Bool {
        later - earlier <= 3600
            && calendar.isDate(Date(timeIntervalSince1970: earlier), inSameDayAs: Date(timeIntervalSince1970: later))
    }
}

extension ChatGrantPlaces {
    /// **The rows of one run's card, one for each grant, with an agent's rows together** in the order in which each
    /// agent first got something: the card names an agent once, over its rows. `leads`: the row is the first of its
    /// agent, so it shows the agent.
    public struct Row: Identifiable, Equatable, Sendable {
        public let report: ManagerReport
        public let grant: ReportGrant
        public let leads: Bool
        public var id: Int { report.id }

        /// **The resource as the row names it**: a repository by its name alone, which says what it is
        /// ("example/web"), and each other kind with the line's word for it before its name ("Gmail a@example.com",
        /// "Google Drive a@example.com", "Secret SHOP_LOGIN"): a mail account and a Drive account of one address
        /// have one name.
        public var resource: String {
            guard grant.kind != "repo", let word = grant.word, !word.isEmpty else { return grant.title }
            return word.prefix(1).uppercased() + word.dropFirst() + " " + grant.title
        }
    }

    public static func cardRows(_ lines: [ManagerReport]) -> [Row] {
        var order: [String] = []
        var byAgent: [String: [(ManagerReport, ReportGrant)]] = [:]
        for line in lines {
            guard let grant = line.grant else { continue }
            if byAgent[grant.agent] == nil { order.append(grant.agent) }
            byAgent[grant.agent, default: []].append((line, grant))
        }
        return order.flatMap { agent in
            (byAgent[agent] ?? []).enumerated().map { index, pair in Row(report: pair.0, grant: pair.1, leads: index == 0) }
        }
    }
}
