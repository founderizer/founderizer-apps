import Foundation

/// **A value in a request's words is what the agent put in inline code** (the owner, 21 November 2026: "Sometimes tasks
/// contain names, codes and other values that need to be copied... it would be nice to identify those and add a small
/// icon button next to them to copy them directly", and his "Yes, as drawn" to its picture). The app guesses no value:
/// only what the agent marked, which the hub's tool text asks it to mark. A card draws each value as a chip with a copy
/// icon, and a press copies the value's characters exactly as the code holds them, with nothing trimmed and nothing
/// added. This is the one rule of which words are values, so that a test reads it without a view; where a card draws
/// values at all (a request's reason, its task, its steps and its details) is the card's to say.
///
/// Not a value: inline code in the words of a link, whose press is the link's; a knowledge file's path, a secret's name
/// or a repository's owner/name that is the whole of one inline code, which is its badge (`CardNames`; of a repository
/// the owner's "The repository's badge", 23 November 2026), because no words are a badge and a value at once; and code
/// of white space only, which holds nothing to copy. A code block is no inline code: it has its own copy icon.
public enum CardValues {
    /// The values of words that are no badge, in their order, by their ranges in `words`: each run of inline code with no
    /// link on it and not of white space only. Code that goes on over several runs of the text (another mark changes on
    /// it) is one value. `words` is a piece of `CardNames.pieces` that has no badge, or a whole text where no names are
    /// read.
    public static func runs(in words: AttributedString) -> [Range<AttributedString.Index>] {
        var found: [Range<AttributedString.Index>] = []
        var start: AttributedString.Index?, end = words.startIndex, linked = false
        func close() {
            if let start, !linked, String(words[start..<end].characters).contains(where: { !$0.isWhitespace }) {
                found.append(start..<end)
            }
            start = nil
            linked = false
        }
        for run in words.runs {
            guard isCode(run.inlinePresentationIntent) else { close(); continue }
            if start == nil { start = run.range.lowerBound }
            end = run.range.upperBound
            if run.link != nil { linked = true }
        }
        close()
        return found
    }

    /// The values of a block's words as a card draws them, in their order, each with its exact characters: the words
    /// that `names` makes no badge of (`CardNames.pieces`, joined as the card joins them, `CardJoin`), or the whole
    /// text with no names. For a copy and for VoiceOver's "Copy <value>".
    public static func values(in text: AttributedString, names: CardNames?) -> [String] {
        // Most words hold no inline code: then no book is read for them.
        guard text.runs.contains(where: { isCode($0.inlinePresentationIntent) }) else { return [] }
        let words = names.map { CardJoin.join($0.pieces(text)).filter { $0.badge == nil }.map(\.words) } ?? [text]
        return words.flatMap { piece in runs(in: piece).map { String(piece[$0].characters) } }
    }

    private static func isCode(_ intent: InlinePresentationIntent?) -> Bool { intent?.contains(.code) == true }
}
