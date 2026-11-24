import Foundation
import Testing
@testable import FleetCore

/// **A skill that the owner gives an agent** (owner feature `message_skills`; his "Yes, as drawn" of 22 November 2026:
/// the Mac's chat box takes a skill's folder, and its ZIP with the plus). The box shows a ZIP as a skill, and the
/// message gives it, only when its `SKILL.md` stands where the hub's own reader takes it (`skill_gift_read`); every
/// other ZIP stays a file. Example names only.
@Suite struct SkillPackageTests {
    /// One entry of a test's ZIP: a file (stored, or deflated), a folder's entry, or a link, with its Unix mode.
    private struct Item {
        let name: String
        var bytes = Data("x\n".utf8)
        var mode: UInt32 = 0o100644
        var deflated = false
        static func folder(_ name: String) -> Item { Item(name: name, bytes: Data(), mode: 0o040755) }
        static func link(_ name: String, to target: String) -> Item { Item(name: name, bytes: Data(target.utf8), mode: 0o120777) }
    }

    /// A ZIP as Python's zipfile and Info-ZIP write one: local headers and their bytes, the central directory, the end
    /// record. Its CRCs are 0: the reader under test never reads them (the hub does).
    private static func zip(_ items: [Item], before: Data = Data(), comment: Data = Data()) -> Data {
        func u16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func u32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func join(_ parts: [Data]) -> Data { parts.reduce(Data(), +) }
        var out = before, directory = Data()
        for item in items {
            let name = Data(item.name.utf8)
            let packed: Data = item.deflated ? (try! (item.bytes as NSData).compressed(using: .zlib)) as Data : item.bytes
            let method = item.deflated ? 8 : 0
            let header = out.count - before.count
            let sizes: [Data] = [u32(0), u32(packed.count), u32(item.bytes.count), u16(name.count)]
            out += join([u32(0x0403_4B50), u16(20), u16(0x800), u16(method), u16(0), u16(0)] + sizes + [u16(0), name, packed])
            directory += join([u32(0x0201_4B50), u16(0x031E), u16(20), u16(0x800), u16(method), u16(0), u16(0)] + sizes)
            directory += join([u16(0), u16(0), u16(0), u16(0), u32(Int(item.mode) << 16), u32(header), name])
        }
        let start = out.count - before.count
        out += directory
        out += join([u32(0x0605_4B50), u16(0), u16(0), u16(items.count), u16(items.count), u32(directory.count),
                     u32(start), u16(comment.count), comment])
        return out
    }

    private static let front = Data("---\nname: deploy-acme-web\ndescription: Deploy the example web app.\n---\nSteps.\n".utf8)

    /// The bug that this catches: the `__MACOSX` folder or a `.DS_Store` of a Mac's own ZIP counts as a second top
    /// folder, so a skill that he zipped in the Finder is never a skill; a folder's own entry or `__pycache__` does the
    /// same; bytes before the ZIP or its comment make a skill's ZIP unreadable.
    @Test func aSkillMdAtTheRootOrUnderItsOneTopFolderIsASkill() {
        #expect(SkillPackage.isSkill(Self.zip([Item(name: "SKILL.md", bytes: Self.front), Item(name: "scripts/run.sh")])))
        let finder = Self.zip([.folder("deploy-acme-web/"), Item(name: "deploy-acme-web/SKILL.md", bytes: Self.front),
                               .folder("deploy-acme-web/scripts/"), Item(name: "deploy-acme-web/scripts/run.sh"),
                               Item(name: "deploy-acme-web/__pycache__/run.cpython-312.pyc"),
                               Item(name: "__MACOSX/deploy-acme-web/._SKILL.md"), Item(name: ".DS_Store"),
                               Item(name: "./deploy-acme-web/notes.md")])
        #expect(SkillPackage.isSkill(finder))
        #expect(SkillPackage.isSkill(Self.zip([Item(name: "deploy-acme-web/SKILL.md")], before: Data("MZ-stub".utf8),
                                              comment: Data("made by a test".utf8))))
    }

    /// The bug that this catches: a ZIP of a repository with a `docs/SKILL.md` becomes a skill, and the hub refuses the
    /// message that would have carried it as a file; or a `skill.md`, a hidden folder's or a second top folder's.
    @Test func aSkillMdDeeperOrBesideASecondTopFolderOrInOtherLettersIsNoSkill() {
        #expect(!SkillPackage.isSkill(Self.zip([Item(name: "acme-web/README.md"), Item(name: "acme-web/docs/SKILL.md")])))
        #expect(SkillPackage.isSkill(Self.zip([Item(name: "docs/SKILL.md")])))      // its one top folder, by any name
        #expect(!SkillPackage.isSkill(Self.zip([Item(name: "deploy-acme-web/docs/SKILL.md"),
                                                Item(name: "deploy-acme-web/notes.md")])))
        #expect(!SkillPackage.isSkill(Self.zip([Item(name: "deploy-acme-web/SKILL.md"), Item(name: "other/notes.md")])))
        #expect(!SkillPackage.isSkill(Self.zip([Item(name: "SKILL.md/notes.md")])))
        #expect(!SkillPackage.isSkill(Self.zip([Item(name: "skill.md")])))
        #expect(!SkillPackage.isSkill(Self.zip([Item(name: "deploy-acme-web/Skill.MD")])))
        #expect(!SkillPackage.isSkill(Self.zip([Item(name: ".deploy-acme-web/SKILL.md")])))
        #expect(!SkillPackage.isSkill(Self.zip([Item(name: "__pycache__/SKILL.md")])))
        #expect(!SkillPackage.isSkill(Self.zip([.folder("SKILL.md/")])))
        #expect(!SkillPackage.isSkill(Self.zip([])))
    }

    /// **A link is a name, as the hub reads it**: the hub refuses a skill with a link in plain words ("run.sh is a link.
    /// A skill holds plain files only"), so the box keeps it a skill and his message gets those words. The bug that this
    /// catches: a reader that answers no for a ZIP with a link sends his skill as a plain file with no word why; or one
    /// that leaves a link out as it leaves out a folder's entry takes a link beside the top folder for nothing.
    @Test func aLinkIsANameAsTheHubReadsIt() {
        #expect(SkillPackage.isSkill(Self.zip([Item(name: "deploy-acme-web/SKILL.md"),
                                               .link("deploy-acme-web/run.sh", to: "scripts/run.sh")])))
        #expect(SkillPackage.isSkill(Self.zip([.link("SKILL.md", to: "../docs/SKILL.md")])))
        #expect(!SkillPackage.isSkill(Self.zip([Item(name: "deploy-acme-web/SKILL.md"), .link("latest", to: "deploy-acme-web")])))
    }

    /// The bug that this catches: a damaged ZIP, a ZIP64 or one with more entries than a skill holds is staged as a
    /// skill (the hub then refuses the message), also when its end record says fewer; or the reader reads past the
    /// bytes and stops the app.
    @Test func aZipThatItCannotReadIsNoSkill() {
        let good = Self.zip([Item(name: "deploy-acme-web/SKILL.md"), Item(name: "deploy-acme-web/notes.md")])
        #expect(SkillPackage.isSkill(good))
        #expect(!SkillPackage.isSkill(Data()))
        #expect(!SkillPackage.isSkill(Data("SKILL.md is not a ZIP".utf8)))
        #expect(!SkillPackage.isSkill(good.dropLast(4)))
        for cut in stride(from: 0, to: good.count, by: 7) {
            var broken = good
            broken[cut] ^= 0xFF
            _ = SkillPackage.isSkill(broken)        // any answer, but no read past the bytes
            _ = SkillPackage.name(inZip: broken, fileName: "deploy-acme-web.zip")
        }
        var many = (1..<SkillPackage.mostEntries).map { Item(name: "deploy-acme-web/f\($0)") }
        many.append(Item(name: "deploy-acme-web/SKILL.md"))
        #expect(SkillPackage.isSkill(Self.zip(many)))
        many.append(Item(name: "deploy-acme-web/one-more"))
        var tooMany = Self.zip(many)
        #expect(!SkillPackage.isSkill(tooMany))
        // an end record that says fewer entries than its directory holds: the hub counts the entries themselves
        let told = tooMany.count - 22 + 8
        tooMany.replaceSubrange(told..<(told + 4), with: Data([1, 0, 1, 0]))
        #expect(!SkillPackage.isSkill(tooMany))
        // ZIP64: the end record's numbers are in another record, which the reader does not read
        var sixtyFour = good
        sixtyFour.replaceSubrange((good.count - 22 + 16)..<(good.count - 22 + 20), with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(!SkillPackage.isSkill(sixtyFour))
    }

    /// The chip's name of a skill: its front matter's `name:`, as the hub reads it, else its folder's name. The bug that
    /// this catches: a deflated SKILL.md (every Mac and zip tool deflates) shows the ZIP's name; a name that the hub
    /// would refuse shows as the skill's; a ZIP of no skill gets a skill's name.
    @Test func theNameIsTheFrontMattersElseTheTopFoldersElseTheZips() {
        #expect(SkillPackage.name(inZip: Self.zip([Item(name: "folder-name/SKILL.md", bytes: Self.front, deflated: true)]),
                                  fileName: "x.zip") == "deploy-acme-web")
        #expect(SkillPackage.name(inZip: Self.zip([Item(name: "SKILL.md", bytes: Self.front)]), fileName: "x.zip")
                == "deploy-acme-web")
        let wrong = Data("---\nname: Deploy Acme\n---\n".utf8)
        #expect(SkillPackage.name(inZip: Self.zip([Item(name: "deploy-acme-web/SKILL.md", bytes: wrong)]),
                                  fileName: "x.zip") == "deploy-acme-web")
        #expect(SkillPackage.name(inZip: Self.zip([Item(name: "SKILL.md", bytes: Data("No front matter.".utf8))]),
                                  fileName: "deploy-acme-web.zip") == "deploy-acme-web")
        #expect(SkillPackage.name(inZip: Self.zip([Item(name: "docs/deep/SKILL.md", bytes: Self.front)]),
                                  fileName: "x.zip") == nil)
        // a file that unpacks to more than the front matter's bytes is read only to them
        let long = Self.front + Data(repeating: UInt8(ascii: "a"), count: 4_000_000)
        #expect(SkillPackage.name(inZip: Self.zip([Item(name: "SKILL.md", bytes: long, deflated: true)]),
                                  fileName: "x.zip") == "deploy-acme-web")

        #expect(SkillPackage.name(frontMatter: "---\r\nname: deploy-acme-web\r\n---\r\n") == "deploy-acme-web")
        #expect(SkillPackage.name(frontMatter: "---\nname: \"deploy-acme-web\"\n---\n") == "deploy-acme-web")
        #expect(SkillPackage.name(frontMatter: "---\nname: 'deploy-acme-web'\n---\n") == "deploy-acme-web")
        #expect(SkillPackage.name(frontMatter: "---\ndescription: x\n---\nname: deploy-acme-web\n") == nil)
        #expect(SkillPackage.name(frontMatter: "---\n  name: deploy-acme-web\n---\n") == nil)
        #expect(SkillPackage.name(frontMatter: "---\nname: deploy-acme-web\n") == nil)
        #expect(SkillPackage.name(frontMatter: "name: deploy-acme-web\n---\n") == nil)
        #expect(SkillPackage.name(frontMatter: "---\nname: -deploy\n---\n") == nil)
    }

    /// **A skill's folder becomes one ZIP with the folder's name at its top and only its plain files** (the Mac's own
    /// ZIP, `NSFileCoordinator`'s `.forUploading`, of a copy). The bug that this catches: a `.git` folder or a `.env`
    /// file travels to the hub's file store with the skill; a link stops the Mac's ZIP; the skill's files stand at the
    /// ZIP's root, or under a temporary folder's name; a folder whose `skill.md` a Mac's disk also opens as `SKILL.md`
    /// is taken as a skill.
    @Test func aSkillFolderBecomesOneZipOfItsPlainFilesUnderItsName() throws {
        let place = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("skill-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: place) }
        let folder = place.appendingPathComponent("acme-folder")
        let manager = FileManager.default
        for sub in ["scripts", ".git", "__pycache__", "docs/deep"] {
            try manager.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Self.front.write(to: folder.appendingPathComponent("SKILL.md"))
        try Data("echo hi\n".utf8).write(to: folder.appendingPathComponent("scripts/run.sh"))
        try Data("deep\n".utf8).write(to: folder.appendingPathComponent("docs/deep/notes.md"))
        try Data("EXAMPLE=1\n".utf8).write(to: folder.appendingPathComponent(".env"))
        try Data("ref\n".utf8).write(to: folder.appendingPathComponent(".git/HEAD"))
        try Data("pyc".utf8).write(to: folder.appendingPathComponent("__pycache__/run.pyc"))
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("run.sh").path, withDestinationPath: "scripts/run.sh")
        #expect(SkillPackage.isSkillFolder(folder))
        #expect(SkillPackage.name(ofFolder: folder) == "deploy-acme-web")

        let zipped = try SkillPackage.zip(folder: folder, atMost: MessageAttachment.sizeLimit)
        #expect(Set(SkillPackage.names(in: zipped) ?? []) ==
                ["acme-folder/SKILL.md", "acme-folder/scripts/run.sh", "acme-folder/docs/deep/notes.md"])
        #expect(SkillPackage.isSkill(zipped))
        #expect(SkillPackage.name(inZip: zipped, fileName: "acme-folder.zip") == "deploy-acme-web")
        // nothing of the copy stays on this Mac
        let left = try manager.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("founderizer-skill-") }
        #expect(left.isEmpty)
        #expect(throws: SkillPackage.FolderRefusal.tooLarge) { try SkillPackage.zip(folder: folder, atMost: 10) }

        // its name, where its SKILL.md has none: the folder's
        try Data("No front matter.\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        #expect(SkillPackage.name(ofFolder: folder) == "acme-folder")

        let lower = place.appendingPathComponent("lower")
        try manager.createDirectory(at: lower, withIntermediateDirectories: true)
        try Self.front.write(to: lower.appendingPathComponent("skill.md"))
        #expect(!SkillPackage.isSkillFolder(lower))
        let linked = place.appendingPathComponent("linked")
        try manager.createDirectory(at: linked, withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: linked.appendingPathComponent("SKILL.md").path,
                                       withDestinationPath: folder.appendingPathComponent("SKILL.md").path)
        #expect(!SkillPackage.isSkillFolder(linked))
        let deeper = place.appendingPathComponent("deeper/docs")
        try manager.createDirectory(at: deeper, withIntermediateDirectories: true)
        try Self.front.write(to: deeper.appendingPathComponent("SKILL.md"))
        #expect(!SkillPackage.isSkillFolder(deeper.deletingLastPathComponent()))
        #expect(!SkillPackage.isSkillFolder(folder.appendingPathComponent("SKILL.md")))
    }

    /// **The skills of his message, as the hub gives them back**: the badge of a gift reads the name that the hub
    /// stored. The bug that this catches: one entry of another shape costs the whole message, or the reading; a skill
    /// to use shows as a gift.
    @Test func theMessageReadsItsSkillsBackLeniently() throws {
        let message: [String: Any] = ["request_id": "r1", "kind": "message", "text": "", "event_id": 9, "created": 1.0,
                                      "client": "c", "skills": [["give": 41, "name": "deploy-acme-web", "commit": "abc"],
                                                                ["use": "seo-radar"], ["give": "41"], 7]]
        let read = try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: message))
        #expect(read.skills?.given == ["deploy-acme-web"])
        #expect(read.skills?.entries == [.give(41, name: "deploy-acme-web"), .use("seo-radar")])
        var odd = message
        odd["skills"] = "none"
        #expect(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: odd)).skills?
                .entries == [])
        odd.removeValue(forKey: "skills")
        #expect(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: odd)).skills == nil)
    }
}
