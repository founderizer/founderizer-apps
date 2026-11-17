import Foundation

/// **Copy and the age of a reply show only under the last reply of a run** (the owner, 16 November 2026, with a
/// picture of two replies of an agent one under the other, Copy and "3 days ago" under the first: "no need to show
/// these timestamps and control on partial messages! only after the last one"). A run is the agent's replies one
/// right under the other. His message, a request's card, the row of a thing that he asked for, or a mark of the day
/// or the hour between two replies ends it.
extension ChatPart {
    /// Whether the row at `index` of `rows` is a reply that ends its run. `stamped[i]` is true when a mark of the day
    /// or the hour stands over row `i` (`ChatStamp`).
    public static func endsReplies(at index: Int, in rows: [ChatPart], stamped: [Bool]) -> Bool {
        guard rows.indices.contains(index), case .entry(.report) = rows[index] else { return false }
        let next = index + 1
        guard next < rows.count else { return true }
        if stamped.indices.contains(next), stamped[next] { return true }
        if case .entry(.report) = rows[next] { return false }
        return true
    }
}

extension ChatPart {
    /// **The run of each row**: the id of the first reply of its run, for each reply of `rows`, and nil for every other
    /// row. A run keeps that id when a reply comes under its last one. `stamped` as in `endsReplies`.
    public static func replyRuns(in rows: [ChatPart], stamped: [Bool]) -> [String?] {
        var runs: [String?] = []
        var run: String?
        for (index, row) in rows.enumerated() {
            guard case .entry(.report) = row else { run = nil; runs.append(nil); continue }
            if run == nil || stamped.indices.contains(index) && stamped[index] { run = row.id }
            runs.append(run)
        }
        return runs
    }
}

/// **The replies of a run share one hover** (the owner, 17 November 2026, with the pointer on the first of two replies:
/// "I should see the time and the copy button at the bottom of the second paragraph! not showing now"): the pointer on
/// any reply of a run shows Copy and the age under its last one. One row is under the pointer at a time, and a pointer
/// that goes from one reply to the next can tell that it came into the new one before it tells that it left the old.
public struct ChatRunHover: Equatable, Sendable {
    /// The reply under the pointer.
    public private(set) var row: String?
    /// Its run (`ChatPart.replyRuns`), whose last reply shows its footer.
    public private(set) var run: String?

    public init() {}

    /// The pointer came into the reply `row` of the run `run`, or left it.
    public mutating func hover(_ row: String, run: String, inside: Bool) {
        if inside {
            self.row = row
            self.run = run
        } else if self.row == row {
            self.row = nil
            self.run = nil
        }
    }
}
