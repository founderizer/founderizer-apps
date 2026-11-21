import Foundation

/// **No card for a request that a new item replaced** (owner API 1.274, `replaced_by`; the owner, 20 November 2026,
/// of a chat where a folded card said "Replaced by manager with a new item: …" over the card of the new item with the
/// same title): the hub answers such an item with its own words, and no page of his shows the hub's bookkeeping. The
/// app keys on the field, never on the words of the answer.
extension Array where Element == OwnerNeed {
    /// The requests that a page draws a card for: none that a new item replaced, apart from `holding`, the request
    /// whose answer of his is on its way or was refused (the outbox's request): its words need the card's place.
    public func drawn(holding held: Int? = nil) -> [OwnerNeed] {
        filter { $0.replaced_by == nil || $0.id == held }
    }
}
