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
