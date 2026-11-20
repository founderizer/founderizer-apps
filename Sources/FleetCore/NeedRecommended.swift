import Foundation

/// **The answer that the agent recommends, marked on its card** (owner feature `need_recommended`, owner API 1.269; the
/// owner, 20 November 2026: "the model should recommend one response, and we should somehow show that on the UI too,
/// even in multiple choice cards or in image/files one", and his pick "B: badge on the edge" of three pictures): the
/// row of that answer has a badge on its top edge, with the glyph of the agent that raised the item and the word
/// Recommended, in that agent's colour.
public enum NeedRecommended {
    /// `ui_features` of a hub whose items carry `recommended`.
    public static let feature = "need_recommended"

    /// The row of an open item's answers that the badge stands on.
    public enum Row: Equatable, Sendable {
        /// The item's own option at this index of `OwnerNeed.choices`: its press, its tick or the door's signed yes are
        /// what they were.
        case option(Int)
        /// The app's own reply at this index, on an item with no options whose agent recommends exactly its words.
        case reply(Int)
        /// A row of its own, on an item with no options: the agent's own words, which a press sends as an answer in
        /// words (no `choice`), as if he had typed them. The hub knows them as the agent's words, not his.
        case words(String)
    }
}

extension OwnerNeed {
    /// The row of the answer that the item's agent recommends, among its options or, on an item with no options, among
    /// `replies`, the app's own answers; nil when no row has the badge: a hub that does not name `need_recommended`,
    /// an item with no `recommended`, a request for a key or a login (its form has no answers), and an item with
    /// options of which the app draws none with those words.
    public func recommendedRow(features: [String]?, replies: [String]) -> NeedRecommended.Row? {
        guard features?.contains(NeedRecommended.feature) == true, !asksForSecret,
              let words = recommended?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return nil }
        // An item with options: the hub keeps one of them in that option's own words, and no other row takes its
        // badge, also where the app draws none of its options.
        guard (options ?? []).isEmpty else { return choices.firstIndex(of: words).map { .option($0) } }
        // Exactly the words of one of the app's replies: that reply has the badge, so one answer does not stand on two
        // rows, and its press sends the very words that the hub knows as the agent's (owner API 1.269).
        if let reply = replies.firstIndex(of: words) { return .reply(reply) }
        // One line of words, as an option is: the hub refuses any other.
        guard words.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return nil }
        return .words(words)
    }
}
