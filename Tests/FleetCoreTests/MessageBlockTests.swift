import Foundation
import Testing
@testable import FleetCore

// The blocks that both apps draw an agent's Markdown from, with the fixture's own replies (`ours-ios-chat-05-nova`,
// `-chat-03-manager-earlier-2`, `-chat-35-refused-discard`).
struct MessageBlockTests {
    @Test("A reply reads as its blocks, and each block keeps its inline marks")
    func blocks() {
        let text = """
        Here is the draft:

        # Simpler prices for November

        From **1 November**, three plans: *Starter*, *Team* and *Scale*.

        > We moved our whole support team in an afternoon.

        - one
        2. two

        | Day | Signups |
        |---|---|
        | Mon | 12 |

        ```
        $ curl -sI https://example | head -1
        ```
        """
        let blocks = MessageBlock.parse(text)
        #expect(blocks.map(\.kind) == [.paragraph, .heading, .paragraph, .quote, .item, .item, .table, .code])
        #expect(blocks[1].text == "Simpler prices for November")
        #expect(blocks[2].text.contains("**1 November**"))
        #expect(blocks[4].marker == "•")
        #expect(blocks[5].marker == "2.")
        #expect(blocks[6].cells == [["Day", "Signups"], ["Mon", "12"]])
        #expect(blocks[7].text == "$ curl -sI https://example | head -1")
    }

    @Test("A list reads as agents write it: levels, lines under an item, and a fence inside it")
    func lists() {
        let nested = MessageBlock.parse("- **H2s:** all eleven\n  - pricing\n    - contact\n- Inter stays")
        #expect(nested.map(\.level) == [0, 1, 2, 0])
        #expect(nested.map(\.marker) == ["•", "•", "•", "•"])
        #expect(nested[0].text == "**H2s:** all eleven")

        let wrapped = MessageBlock.parse("- first line\n  goes on\n- second\nlazy\n\nAfter the list.")
        #expect(wrapped.map(\.kind) == [.item, .item, .paragraph])
        #expect(wrapped[0].text == "first line\ngoes on")
        #expect(wrapped[1].text == "second\nlazy")
        #expect(wrapped[2].text == "After the list.")

        let fenced = MessageBlock.parse("1. Run:\n   ```bash\n   swift test\n     --parallel\n   ```\n2. Then push.")
        #expect(fenced.map(\.kind) == [.item, .code, .item])
        #expect(fenced[1].text == "swift test\n  --parallel")
        #expect(fenced[2].marker == "2.")

        // A paragraph at the left ends a list; the next list starts at its own left.
        let again = MessageBlock.parse("- a\n\nText\n\n  - b")
        #expect(again.map(\.kind) == [.item, .paragraph, .item])
        #expect(again[2].level == 0)
        // A blank line between items keeps the list and its levels.
        #expect(MessageBlock.parse("- a\n\n  - b").map(\.level) == [0, 1])
    }

    @Test("A preview shows the words without the marks")
    func plainPreview() {
        #expect(MessageBlock.plain("From **1 November**, see [the post](https://example.com).")
                == "From 1 November, see the post.")
        #expect(MessageBlock.plain("# Prices\n> Fast") == "Prices Fast")
        #expect(MessageBlock.plain("The chart is in `outpu") == "The chart is in outpu")
        #expect(MessageBlock.plain("Hi {first_name}, #4471 stays") == "Hi {first_name}, #4471 stays")
    }
}
