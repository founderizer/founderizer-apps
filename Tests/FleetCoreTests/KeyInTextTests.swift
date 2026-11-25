import Foundation
import Testing
@testable import FleetCore

/// **Every part of a text that looks like a key** (`KeyInText.all`). A knowledge file's box asks only about a key that
/// an edit adds to the file, so it compares the key-like parts of its text with those of the hub's text. The bug that
/// this catches: a reading that gives only the first part, or the same key twice as its shape and as a run, so a key
/// that he adds after one that the file holds already is saved with no question, or a file's own key reads as new.
struct KeyInTextTests {
    /// Made-up keys with the shapes of real ones, each in two parts so that no scan of the repository takes it for a key.
    private static let stripe = "sk_test_" + "EXAMPLEexample0123456789"
    /// Its body reads as random too, so the run that it is would count it a second time.
    private static let github = "ghp_" + "Z3nB6yH1cF5jD0sGe4Ua9Q7vK2mX9pL4tR8w"
    /// A run with no shape of its own that reads as random.
    private static let run = "Q7vK2mX9pL4" + "tR8wZ3nB6yH1cF5jD0sGe4U"

    @Test func everyKeyLikePartIsReadOnceInTheOrderOfTheText() {
        let text = "Old: \(Self.stripe). New: \(Self.github). Token=\(Self.run) and a name, camelCaseName, stays."
        #expect(KeyInText.all(in: text).map(String.init) == [Self.stripe, Self.github, Self.run])
        // each part stands where it is in the text, so the part alone can be cut out of it
        if let second = KeyInText.all(in: text).dropFirst().first {
            #expect(text[second.startIndex..<second.endIndex] == Self.github)
        }
        // the first of them is the one that `first(in:)` finds
        #expect(KeyInText.first(in: text).map { String(text[$0]) } == Self.stripe)
        #expect(KeyInText.all(in: "The launch is on Monday, at https://example.com/a/9f86d081884c7d659a2feaa0c55ad015.").isEmpty)
    }
}
