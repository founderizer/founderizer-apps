import Foundation
import Testing
@testable import FleetCore

/// The search card's "In messages" (the owner's yes of 12 November 2026): when it asks, what it marks in a line, and
/// what a match opens.
struct MessageSearchTests {
    private func marked(_ line: String, _ words: String) -> [String] {
        MessageSearch.highlights(in: line, words: words).map { String(line[$0]) }
    }

    @Test func theCardAsksAfterThreeCharacters() {
        #expect(MessageSearch.asks("ce") == nil)
        #expect(MessageSearch.asks("  ce  ") == nil)
        #expect(MessageSearch.asks(" cer ") == "cer")
        #expect(MessageSearch.wait == .milliseconds(200))
    }

    @Test func theTypedWordsAreMarkedAsTheHubMatchedThem() {
        // every word whole, the last one also as the start of a word, in any case and with or without accents
        #expect(marked("The staging certificate expires; Staging is late", "staging cert") == ["staging", "cert", "Staging"])
        #expect(marked("Ángela asked for the refund", "angela refu") == ["Ángela", "refu"])
        #expect(marked("The stage is set", "stag certificate") == [])               // "stag" is not the last word
        #expect(marked("Renew T-12 now", "t 12") == ["T", "12"])
        #expect(marked("anything", "  ") == [])
    }

    @Test func aChatDrawsEntriesOverTheMatchThatItOpensAt() {
        // 286 entries, the match is entry 15: the 271 from it to the end, and 12 over it
        #expect(MessageSearch.drawn(count: 286, index: 15) == 283)
        // a match near the chat's start: every entry, and never more than the chat holds
        #expect(MessageSearch.drawn(count: 286, index: 3) == 286)
        #expect(MessageSearch.drawn(count: 286, index: 0) == 286)
        // the newest entry: itself and 12 over it
        #expect(MessageSearch.drawn(count: 286, index: 285) == 13)
        #expect(MessageSearch.drawn(count: 1, index: 0) == 1)
    }

    @Test func aMatchOpensItsChatEntryOrItsTask() throws {
        let json = """
        {"db": "g1", "mode": "messages", "agent": null, "query": "domain", "more": false, "index": {},
         "results": [{"id": 9, "ref": "OM-4", "kind": "owner_chat", "agent": "vps", "at": 10, "task": null,
                      "owner_chat": true, "message": "r-1", "snippet": "Renew the domain"},
                     {"id": 8, "ref": "OR-7", "kind": "owner_chat", "agent": "vps", "at": 9, "task": null,
                      "owner_chat": true, "message": null, "snippet": "It renews on the 30th"},
                     {"id": 7, "ref": "N-3", "kind": "owner_chat", "agent": "vps", "at": 8, "task": null,
                      "owner_chat": true, "message": null, "snippet": "Which domain?"},
                     {"id": 6, "ref": "T-12", "kind": "note", "agent": "vps", "at": 7, "task": "T-12",
                      "owner_chat": false, "message": null, "snippet": "The domain moved"},
                     {"id": 5, "ref": "AM-2", "kind": "message", "agent": "vps", "at": 6, "task": null,
                      "owner_chat": false, "message": null, "snippet": "Which registrar holds the domain?"}]}
        """
        let page = try JSONDecoder().decode(MessageMatches.self, from: Data(json.utf8))
        try page.validate(database: "g1")
        #expect(page.results.map(\.chatEntry) == ["message-r-1", "report-7", "need-3", nil, nil])
        #expect(page.results.map(\.taskNumber) == [nil, nil, nil, 12, nil])
        #expect(throws: HubError.self) { try page.validate(database: "g2") }
    }
}
