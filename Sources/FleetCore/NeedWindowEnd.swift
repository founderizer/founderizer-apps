import Foundation

/// **When a request card's own window closes by itself** (the owner, 21 November 2026: "a pop-out functionality so the
/// card can open in another window I can drag around and keep on top of others until it is closed. I would also like
/// to be able to reply from it", and his "Yes, as drawn" to its picture; the Mac's `NeedWindow`). He closes it with its
/// close button or ⌘W, and it closes by itself in two cases only:
/// - **the hub has his answer**: the reading holds the request answered, no run of its command goes on, and no save
///   holds the card (`KeySaveCard.folds`), so a key's card closes once the check of his save has drawn itself. Never
///   while his answer is only on its way: he was told "It also closes by itself after your answer is saved. If a save
///   fails, it stays and shows the failure", and an answer that the hub refuses comes back to the card, which then
///   stands open with the hub's reason;
/// - **the request is no longer in the reading**: removed, of another hub or hub generation, or replaced by a new item
///   (`replaced_by`), which no page draws.
///
/// A save that failed keeps the card open in the chat, with its rows and Try again, so it keeps the window too. The
/// window's card, whose long part is open from the start, closes its window as a folded one would: a card that he
/// opened in the chat folds all the same when his answer goes.
public enum NeedWindowEnd {
    /// `reading`: the request as the store's reading of the window's hub and generation holds it now, or nil where it
    /// holds none. `runs`: a run of its command goes on (owner feature `need_run`). `keySave`: the card's key save, as
    /// the card tells it.
    public static func closes(reading: OwnerNeed?, runs: Bool, keySave: KeySaveCard) -> Bool {
        guard let reading, reading.replaced_by == nil else { return true }
        return keySave.folds(answered: !reading.isOpen && !runs, expanded: false)
    }
}
