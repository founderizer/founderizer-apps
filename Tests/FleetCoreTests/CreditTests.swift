import Foundation
import Testing
@testable import FleetCore

/// The credit of both apps (`Credit`): the owner alone, and one link to his profile.
struct CreditTests {
    @Test func theCreditNamesTheOwnerAndLinksToHisProfile() {
        #expect(Credit.line == "Made by Miguel Pieras")
        #expect(Credit.handle == "@mpieras")
        #expect(Credit.profile == URL(string: "https://x.com/mpieras"))
    }

    @Test func thePhonesLineIsOneLineAndOnlyTheHandleIsTheLink() {
        let line = Credit.oneLine
        #expect(String(line.characters) == "Made by Miguel Pieras · @mpieras")
        let links = line.runs.compactMap { run in run.link.map { (String(line[run.range].characters), $0) } }
        #expect(links.count == 1)
        #expect(links.first?.0 == "@mpieras")
        #expect(links.first?.1 == Credit.profile)
    }
}
