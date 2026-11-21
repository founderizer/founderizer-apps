import Foundation
import Testing
@testable import FleetCore

/// A value in a request's words, which the card gives a copy icon (`CardValues`): only what the agent put in inline code.
struct CardValuesTests {
    /// A plain inline code is a value with its exact characters; a knowledge file's path that is a whole inline code is
    /// its badge and no value; code in the words of a link, and code of white space only, are no value.
    @Test func aValueIsInlineCodeWithItsExactCharacters() {
        let names = CardNames(agents: [(name: "nova", role: "Customer Support Lead")], knowledge: ["knowledge/owner/brand.md"])
        let words = MessageBlock.inline("Make the bucket `acme-logs`, name it `ls ` and read `knowledge/owner/brand.md` "
                                        + "and `cat knowledge/owner/brand.md`. Keep `  ` as it is.")
        #expect(CardValues.values(in: words, names: names) == ["acme-logs", "ls ", "cat knowledge/owner/brand.md"])
        #expect(CardValues.values(in: MessageBlock.inline("Nova has no code here."), names: names).isEmpty)
        // Code that carries a link: its press is the link's.
        var linked = AttributedString("acme-logs")
        linked.inlinePresentationIntent = .code
        linked.link = URL(string: "https://console.example.com")
        #expect(CardValues.values(in: AttributedString("Open ") + linked, names: nil).isEmpty)
    }
}
