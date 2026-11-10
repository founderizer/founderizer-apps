import Foundation
import Testing
@testable import FleetCore

private func state(knowledge: [[String: Any]]) throws -> HubState {
    try HubState.decode(JSONSerialization.data(withJSONObject: [
        "schema_version": 1, "db": "test-db", "time": 1000.0, "manager_flag": NSNull(), "agents": [], "tasks": [],
        "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [], "knowledge": knowledge]))
}

private let base = [ProfileSection(key: "character", title: "Character", text: "Careful."),
                    ProfileSection(key: "responsible_for", title: "Responsible for", text: "Checks."),
                    ProfileSection(key: "may_do", title: "May do without asking", text: "Read files."),
                    ProfileSection(key: "must_ask", title: "Must ask first", text: "Spending.")]

@Test func theStateKeepsOnlyTheOwnersKnowledgeFiles() throws {
    let commit = String(repeating: "a", count: 40)
    let owned = try state(knowledge: [
        ["path": "knowledge/services.md", "title": "Services", "scope": "internal", "bytes": 10, "source": NSNull(), "commit": commit],
        ["path": "knowledge/owner/brand.md", "title": "Brand", "scope": "owner", "bytes": 52,
         "source": "brand.pdf · added 2026-10-14", "commit": commit]])
    #expect(owned.knowledge?.map(\.path) == ["knowledge/owner/brand.md"])
    #expect(owned.knowledge?.first?.source == "brand.pdf · added 2026-10-14")
    // A hub before owner knowledge: every file is internal, with its text.
    let older = try state(knowledge: [["path": "knowledge/services.md", "title": "Services", "text": "# Services", "commit": commit]])
    #expect(older.knowledge?.isEmpty == true)
}

@Test func aFileIsAddedToAndRemovedFromTheKnowledgeFilesSection() throws {
    let brand = "knowledge/owner/brand.md", prices = "knowledge/owner/prices.md"
    let one = try #require(try KnowledgeAccess.sections(base, path: brand, on: true, agent: "vps"))
    #expect(one.last == ProfileSection(key: "knowledge_files", title: "Knowledge files", text: "- \(brand)"))
    let two = try #require(try KnowledgeAccess.sections(one, path: prices, on: true, agent: "vps"))
    #expect(KnowledgeAccess.paths(two) == [brand, prices])
    #expect(try KnowledgeAccess.sections(two, path: brand, on: true, agent: "vps") == nil)
    let back = try #require(try KnowledgeAccess.sections(two, path: prices, on: false, agent: "vps"))
    #expect(back == one)
    // The last file takes its section with it: the hub refuses an empty list.
    #expect(try KnowledgeAccess.sections(one, path: brand, on: false, agent: "vps") == base)
    #expect(try KnowledgeAccess.sections(base, path: brand, on: false, agent: "vps") == nil)
    #expect(ProfileInput(sections: two).isValid)
}

@Test func aSectionWithALineThatIsNotAFileIsNotChanged() throws {
    let broken = base + [ProfileSection(key: "knowledge_files", title: "Knowledge files", text: "See the brand file.")]
    #expect(KnowledgeAccess.paths(broken) == nil)
    #expect(throws: KnowledgeAccessError.self) { try KnowledgeAccess.sections(broken, path: "knowledge/owner/brand.md", on: true, agent: "vps") }
}

@Test func aFilesCardSaysWhenAndFromWhatItCameIn() throws {
    let english = Locale(identifier: "en_GB")
    // A plan's line: the plan's name, without what follows its first clause.
    let plan = KnowledgeOrigin(line: "Shop relaunch plan v2 of 12 Oct 2026 (shop-api PLAN.md), written after the "
                               + "review of the shop on 9 Oct 2026 · added 2026-10-12")
    #expect(plan.how == "added")
    #expect(plan.name == "Shop relaunch plan v2")
    #expect(plan.line(locale: english) == "Added 12 Oct 2026 · Shop relaunch plan v2")
    #expect(plan.source.hasSuffix("on 9 Oct 2026"))
    #expect(KnowledgeOrigin(line: "Operations handbook, part 3, agreed with the team on 5 October 2026 · added "
                            + "2026-10-05").line(locale: english) == "Added 5 Oct 2026 · Operations handbook")
    // A file he added from this Mac, and a page the hub reads again.
    #expect(KnowledgeOrigin(line: "brand.pdf · added 2026-10-14").line(locale: english) == "Added 14 Oct 2026 · brand.pdf")
    #expect(KnowledgeOrigin(line: "https://example.com/pricing · read 2026-11-01").line(locale: english)
            == "Read 1 Nov 2026 · https://example.com/pricing")
    // A line without the hub's date is its name alone, and a dot inside a name is no date.
    let bare = KnowledgeOrigin(line: "Notes · from the call")
    #expect(bare.how == nil && bare.day == nil)
    #expect(bare.line(locale: english) == "Notes · from the call")
    #expect(KnowledgeOrigin(line: "Map of the city.pdf · added 2026-10-14").name == "Map of the city.pdf")
}

@Test func anEditHoldsTheTextAfterTheTitleAndSourceLines() throws {
    let commit = String(repeating: "a", count: 40)
    func file(_ text: String) throws -> KnowledgeFile {
        try JSONDecoder().decode(KnowledgeFile.self, from: JSONSerialization.data(withJSONObject: [
            "db": "test-db", "path": "knowledge/owner/brand.md", "title": "Brand", "source": "brand.pdf · added 2026-10-14",
            "commit": commit, "text": text]))
    }
    var edit = try #require(KnowledgeEdit(file: file("# Brand\n\nSource: brand.pdf · added 2026-10-14\n\nBlue.\n\nNot green.\n")))
    #expect(edit.text == "Blue.\n\nNot green.")
    #expect(!edit.isChanged)
    edit.text = "  Blue.\n\nNot green.\n\n"            // only the ends: the hub keeps the same text
    #expect(!edit.isChanged)
    edit.text = "Blue.\n\nGreen."
    #expect(edit.isChanged && edit.sent == "Blue.\n\nGreen.")
    edit.text = " \n "                                // an empty box is no change: it is never sent
    #expect(!edit.isChanged && edit.sent.isEmpty)
    // A file without its title and Source lines: the hub does not change it in place, so there is no edit.
    #expect(KnowledgeEdit(file: try file("Text with no title.\n")) == nil)
    #expect(KnowledgeEdit(file: try file("# Brand\nSource: brand.pdf\n\nBlue.")) == nil)
    #expect(KnowledgeEdit.body(of: "# Brand\n\nSource: x · changed 2026-11-05\n\nOne.") == "One.")
}
