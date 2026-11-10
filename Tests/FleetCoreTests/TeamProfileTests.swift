import Darwin
import Foundation
import Testing
@testable import FleetCore

/// The Team view's profile sections: their places and names, what to write in each, the short preview, and the save of
/// one section through the existing profile route, with the hub's 409 when the profile changed meanwhile.
struct TeamProfileTests {
    private let hub = URL(string: "http://localhost:8765")!
    private let base = String(repeating: "a", count: 64)
    private let newer = String(repeating: "b", count: 64)

    private func profile(_ sections: [ProfileSection], sha256: String? = nil) -> AgentProfile {
        AgentProfile(agent: "vps", path: "profiles/vps.md", sha256: sha256 ?? base, sections: sections, text: "")
    }
    private var sections: [ProfileSection] {
        [ProfileSection(key: "character", title: "Character", text: "Calm and exact."),
         ProfileSection(key: "responsible_for", title: "Responsible for", text: "Linux work on the VPS."),
         ProfileSection(key: "other", title: "How you work", text: "Small steps.\n\n- Check first\n- Then act"),
         ProfileSection(key: "may_do", title: "What you may decide without the owner", text: "Read files."),
         ProfileSection(key: "must_ask", title: "What goes to the owner (Needs you)", text: "Anything that costs money."),
         ProfileSection(key: "logins", title: "Logins", text: "`pilot-site-a` (`bws://18eaf23b-f5d2-4623-a4fb-b4de012c53fb`)"),
         ProfileSection(key: "other", title: "Proof", text: "A screenshot for each browser task."),
         ProfileSection(key: "knowledge_files", title: "Knowledge files", text: "- knowledge/services.md")]
    }

    @Test func sectionsMapToTeamEntriesInFileOrder() {
        let entries = profile(sections).entries
        #expect(entries.map(\.id) == [
            .init(key: "character"), .init(key: "responsible_for"), .init(key: "other", occurrence: 0), .init(key: "may_do"),
            .init(key: "must_ask"), .init(key: "logins"), .init(key: "other", occurrence: 1), .init(key: "knowledge_files")])
        // A known key has its plain name, also with another title that the hub reads as that key.
        #expect(entries.map(\.name) == ["Character", "Responsible for", "How you work", "May do without asking", "Asks you first",
                                         "Logins it may use", "Proof", "Knowledge files"])
        #expect(entries.filter(\.isRequired).map(\.section.key) == ["character", "responsible_for", "may_do", "must_ask"])
        // The rules of Behaviour: the required sections and the owner's own; not knowledge, logins or knowledge files.
        #expect(entries.filter(\.isRule).map(\.name) == ["Character", "Responsible for", "How you work", "May do without asking",
                                                         "Asks you first", "Proof"])
        // "Asks you first" is the app's name only: the hub reads it as a title of the owner's own.
        #expect(ProfileGuide.key(forTitle: "Asks you first") == "other")
        // The hub's title rule: the case does not count, and every other title is `other`.
        #expect(ProfileGuide.key(forTitle: "character") == "character")
        #expect(ProfileGuide.key(forTitle: "What goes to the owner (Needs you)") == "must_ask")
        #expect(ProfileGuide.key(forTitle: "LOGINS") == "logins")
        #expect(ProfileGuide.key(forTitle: "How you work") == "other")
        #expect(ProfileGuide.name(key: "other", title: "Proof") == "Proof")
    }

    @Test func descriptionsSayWhatToWrite() {
        let expected = [
            "character": "How this agent behaves and sounds, in one or two sentences.",
            "responsible_for": "What this agent owns and delivers.",
            "may_do": "Decisions it can make alone.",
            "must_ask": "What it must bring to you before it acts.",
            "knowledge": "Facts and links that it must know.",
            "logins": "Saved login names only, never passwords.",
            "knowledge_files": "Files in knowledge/ that it reads first.",
            "other": "Extra rules for this agent."]
        for (key, text) in expected { #expect(ProfileGuide.description(key: key) == text) }
        #expect(ProfileGuide.description(key: "a_future_key") == "Extra rules for this agent.")
        #expect(profile(sections).entries.allSatisfy { $0.description == expected[$0.section.key] })
    }

    @Test func previewShowsTheFirstLinesOnly() {
        let preview = ProfilePreview("One\r\n\r\nTwo\n  - three\n\nFour\nFive\nSix")
        #expect(preview.lines == ["One", "Two", "  - three", "Four"])
        #expect(preview.more == 2 && !preview.cut)
        let long = ProfilePreview(String(repeating: "x", count: 300), width: 240)
        #expect(long.lines.count == 1 && long.lines[0].count == 240 && long.lines[0].hasSuffix("…") && long.cut && long.more == 0)
        #expect(ProfilePreview("  \n").lines.isEmpty)
    }

    @Test func aSaveSendsEverySectionWithOnlyThatSectionChanged() throws {
        var edit = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "character")))
        #expect(!edit.isChanged && edit.problem() == nil)
        edit.text = "  Calm and exact.\r\n"
        #expect(!edit.isChanged)
        edit.text = "Calm, exact and brief.\r\nNo jokes.\n"
        #expect(edit.isChanged)
        let input = edit.input()
        #expect(input.sections[0] == ProfileSection(key: "character", title: "Character", text: "Calm, exact and brief.\nNo jokes."))
        #expect(Array(input.sections.dropFirst()) == Array(sections.dropFirst()))

        let request = PendingRequest(hub: hub, database: "db", client: "local", command: edit.command, text: try edit.payload())
        #expect(request.route == "ui/profiles/vps")
        let fields = try #require(try JSONSerialization.jsonObject(with: request.body()) as? [String: Any])
        #expect(fields["base_sha256"] as? String == base && fields["db"] as? String == "db")
        #expect(fields["request_id"] as? String == request.requestID.uuidString.lowercased())
        let sent = try #require(fields["sections"] as? [[String: String]])
        #expect(sent.map { ProfileSection(key: $0["key"]!, title: $0["title"]!, text: $0["text"]!) } == input.sections)

        // The hub's answer for this request: the store accepts it as the receipt of the save.
        let receipt = try JSONDecoder().decode(ControlReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "ok": true, "request_id": request.requestID.uuidString.lowercased(), "client": "local", "replayed": false, "agent": "vps",
            "sha256": newer, "commit": String(repeating: "c", count: 40), "revision": String(repeating: "c", count: 40),
            "unchanged": false, "updates_requested": ["vps"]]))
        #expect(receipt.matches(request))
    }

    @Test func anOtherSectionKeepsItsPlaceAndItsTitleRules() throws {
        var edit = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "other", occurrence: 1)))
        #expect(edit.saved?.title == "Proof" && edit.canDelete)
        edit.title = "  Evidence. "
        #expect(edit.normalizedTitle == "Evidence" && edit.isChanged && edit.problem() == nil)
        #expect(edit.input().sections[6] == ProfileSection(key: "other", title: "Evidence", text: "A screenshot for each browser task."))
        edit.title = "Character"
        #expect(edit.problem() == "“Character” is the title of another section. Use another title.")
        edit.title = "Two * marks"
        #expect(edit.problem() == "A title cannot contain *.")
        edit.title = String(repeating: "t", count: 81)
        #expect(edit.problem() == "A title has 1 to 80 characters.")
        // A known section keeps its saved title, so that the hub reads the same key again.
        var known = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "must_ask")))
        known.title = "Must ask first"
        known.text = "Anything that costs money or leaves the building."
        #expect(known.input().sections[4].title == "What goes to the owner (Needs you)")
    }

    @Test func theHubRulesAreCheckedBeforeASave() throws {
        let catalog: Set<String> = ["knowledge/services.md", "knowledge/brand.md"]
        // Character, Responsible for, May do and Must ask: exactly once, and never deleted.
        for key in ["character", "responsible_for", "may_do", "must_ask"] {
            let edit = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: key)))
            #expect(!edit.canDelete)
            #expect(edit.problem(deleting: true) == "\(edit.name) cannot be deleted. Every profile has it once.")
        }
        let logins = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "logins")))
        #expect(logins.problem(deleting: true) == nil && !logins.input(deleting: true).sections.contains { $0.key == "logins" })
        #expect(logins.input(deleting: true).sections.count == sections.count - 1)

        var edit = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "responsible_for")))
        edit.text = " \n "
        #expect(edit.problem() == "Write a text. This section cannot be empty.")
        edit.text = String(repeating: "w", count: 8001)
        #expect(edit.problem() == "A text has at most \(8000.formatted()) characters. This text has \(8001.formatted()).")
        edit.text = String(repeating: "w", count: 8000)
        #expect(edit.problem() == nil)
        edit.text = "Linux work.\n**Proof.** A screenshot."
        #expect(edit.problem() == "A line cannot start like a section title: “**Proof.** A screenshot.”.")

        // The whole profile stays under 32 KiB, with the margin of the existing check.
        var large = sections
        large.insert(ProfileSection(key: "other", title: "Long notes", text: String(repeating: "n", count: 8000)), at: 2)
        large.insert(ProfileSection(key: "other", title: "More notes", text: String(repeating: "n", count: 8000)), at: 2)
        large.insert(ProfileSection(key: "other", title: "Old notes", text: String(repeating: "n", count: 8000)), at: 2)
        var big = try #require(ProfileSectionEdit(profile: profile(large), id: .init(key: "character")))
        big.text = String(repeating: "c", count: 8000)
        #expect(big.problem() == "The whole profile must stay under 32 KiB. Make this text shorter.")
        big.text = "Calm."
        #expect(big.problem() == nil)

        var files = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "knowledge_files")))
        files.text = ProfileGuide.knowledgeText(["knowledge/services.md", "knowledge/brand.md"])
        #expect(files.text == "- knowledge/brand.md\n- knowledge/services.md" && files.problem(catalog: catalog) == nil)
        files.text = "- knowledge/missing.md"
        #expect(files.problem(catalog: catalog) == "knowledge/missing.md is not in the knowledge catalog. Clear it before you save.")
        files.text = "services.md"
        #expect(files.problem(catalog: catalog) == "Each line names one file, for example “- knowledge/services.md”.")
        files.text = ""
        #expect(files.problem(catalog: catalog) == "Write a text, or delete this section.")
        #expect(ProfileGuide.knowledgePaths("- knowledge/../team.md") == nil)

        // A title that the hub reads as another key breaks the whole save, also in a section that the owner did not open.
        var broken = sections
        broken[2] = ProfileSection(key: "other", title: "Knowledge", text: "A second knowledge section.")
        let other = try #require(ProfileSectionEdit(profile: profile(broken), id: .init(key: "character")))
        #expect(other.problem() == "The section “Knowledge” has the title of another section. The hub cannot save this profile until that title changes.")
    }

    @Test func a409KeepsTheTextAndReloadTakesTheCurrentVersion() throws {
        var edit = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "responsible_for")))
        edit.text = "Linux work on the VPS and its backups."
        let request = PendingRequest(hub: hub, database: "db", client: "local", command: edit.command, text: try edit.payload())

        // The store keeps a definitive refusal with the client's words; the editor reads the 409 from them.
        var refused = request
        refused.refusal = HubError.refusal(409, "the profile changed meanwhile; reload it").localizedDescription
        #expect(ProfileSaveOutcome(pending: refused, command: edit.command) == .changedMeanwhile("the profile changed meanwhile; reload it"))
        refused.refusal = HubError.refusal(400, "a line in Responsible for starts like a section title (**...**)").localizedDescription
        #expect(ProfileSaveOutcome(pending: refused, command: edit.command) == .refused("a line in Responsible for starts like a section title (**...**)"))
        #expect(ProfileSaveOutcome(pending: request, command: edit.command) == .waiting)
        #expect(ProfileSaveOutcome(pending: request, command: .profile(agent: "studio", sha256: base)) == nil)
        #expect(ProfileSaveOutcome(pending: nil, command: edit.command) == nil)
        #expect(HubError.refusalStatus(in: "The hub refused registered login text (422). Saved text and drafts were removed.") == nil)

        // Reload: another section changed meanwhile. The owner's text stays; the base and the other sections are new.
        var current = sections
        current[0].text = "Calm, exact and quiet."
        var reloaded = edit
        #expect(reloaded.rebase(on: profile(current, sha256: newer)) == .unchanged)
        #expect(reloaded.baseSHA256 == newer && reloaded.text == edit.text && reloaded.command == .profile(agent: "vps", sha256: newer))
        #expect(reloaded.input().sections[0].text == "Calm, exact and quiet.")
        #expect(reloaded.input().sections[1].text == "Linux work on the VPS and its backups.")

        // The same section changed meanwhile: the reload says so, and the owner's text still stays.
        current[1].text = "Linux work and the nightly backup."
        var same = edit
        #expect(same.rebase(on: profile(current, sha256: newer)) == .sectionChanged)
        #expect(same.text == edit.text && same.saved?.text == "Linux work and the nightly backup.")

        // An optional section that another save deleted is gone; an other section that moved is found by its title.
        let gone = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "logins")))
        var lost = gone
        #expect(lost.rebase(on: profile(sections.filter { $0.key != "logins" }, sha256: newer)) == .gone)
        var proof = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "other", occurrence: 1)))
        var moved = sections
        moved.remove(at: 2)
        #expect(proof.rebase(on: profile(moved, sha256: newer)) == .unchanged)
        #expect(proof.id == .init(key: "other", occurrence: 0) && proof.saved?.title == "Proof")
    }

    @Test func aNewRuleGoesAfterTheLastSectionAndTheNextSaveGoesAgainstTheSavedVersion() throws {
        var rule = ProfileSectionEdit(newRuleIn: profile(sections))
        #expect(rule.isNew && rule.isChanged && rule.saved == nil && rule.id == .init(key: "other", occurrence: 2))
        #expect(rule.problem() == "A title has 1 to 80 characters.")
        rule.title = "Tone."
        #expect(rule.problem() == "Write the text of this rule.")
        rule.text = "Short answers.\r\n"
        #expect(rule.problem() == nil)
        #expect(rule.input().sections == sections + [ProfileSection(key: "other", title: "Tone", text: "Short answers.")])
        #expect(rule.input(deleting: true).sections == sections)

        // Another save changed the profile first: the new rule goes after that version's last section.
        let current = Array(sections.dropLast())
        #expect(rule.rebase(on: profile(current, sha256: newer)) == .unchanged)
        #expect(rule.baseSHA256 == newer && rule.input().sections.count == current.count + 1)

        // The hub took it: its version is the base of the next save, which keeps the owner's newer text.
        let sent = rule, saved = String(repeating: "d", count: 64)
        rule.text = "Short answers. No jokes."
        rule.update(after: sent, sha256: saved)
        #expect(!rule.isNew && rule.baseSHA256 == saved && rule.command == .profile(agent: "vps", sha256: saved))
        #expect(rule.saved == ProfileSection(key: "other", title: "Tone", text: "Short answers.") && rule.isChanged)
        #expect(rule.input().sections.count == current.count + 1 && rule.input().sections.last?.text == "Short answers. No jokes.")
        rule.text = "Short answers."
        #expect(!rule.isChanged)
    }

    /// The same save through the real client: the hub stand-in gets every section with one changed, and its 409 comes
    /// back as a definitive refusal with the hub's words.
    @Test func aSectionSaveThroughTheClientGetsTheHubsAnswer() async throws {
        var edit = try #require(ProfileSectionEdit(profile: profile(sections), id: .init(key: "may_do")))
        edit.text = "Read files and run tests."
        let commit = String(repeating: "c", count: 40), later = newer
        let conflict = try OneAnswer(status: "409 Conflict") { _ in #"{"error":"the profile changed meanwhile; reload it","sha256":"\#(later)"}"# }
        let request = PendingRequest(hub: URL(string: "http://127.0.0.1:\(conflict.port)")!, database: "db", client: "local",
                                     command: edit.command, text: try edit.payload())
        do {
            _ = try await HubClient().command(request)
            Issue.record("The stand-in answered 409, so the save cannot succeed.")
        } catch HubError.refusal(let status, let words) {
            #expect(status == 409 && words == "the profile changed meanwhile; reload it")
            // A profile is a whole form the owner wrote against the version he read, so this one is his to see
            // again: `rebasesSafely` says no, and nothing is sent a second time behind his back.
            #expect(HubError.refusal(status, words).conflict && !HubError.refusal(status, words).definitiveRefusal)
            #expect(!edit.command.rebasesSafely && edit.command.rebased(to: .file(sha256: later)) == nil)
        }
        let message = conflict.received
        #expect(message.starts(with: Data("POST /ui/profiles/vps HTTP/1.1\r\n".utf8)))
        let fields = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: message)) as? [String: Any])
        #expect(fields["base_sha256"] as? String == base)
        let sent = try #require(fields["sections"] as? [[String: String]])
        #expect(sent.count == sections.count && sent[3]["text"] == "Read files and run tests." && sent[3]["title"] == "What you may decide without the owner")
        #expect(zip(sent, sections).enumerated().allSatisfy { $0.offset == 3 || $0.element.0["text"] == $0.element.1.text })

        // After a reload the same save goes against the newer version, and the hub's receipt completes it.
        let saved = try OneAnswer(status: "200 OK") { message in
            let fields = (try? JSONSerialization.jsonObject(with: OneAnswer.body(of: message))) as? [String: Any]
            return #"{"ok":true,"request_id":"\#(fields?["request_id"] as? String ?? "")","client":"local","replayed":false,"agent":"vps","sha256":"\#(later)","commit":"\#(commit)","revision":"\#(commit)","unchanged":false,"updates_requested":[]}"#
        }
        let again = PendingRequest(hub: URL(string: "http://127.0.0.1:\(saved.port)")!, database: "db", client: "local", command: edit.command,
                                   text: try edit.payload())
        let answer = try await HubClient().command(again)
        #expect(answer.sha256 == newer && answer.unchanged == false && answer.matches(again))
    }
}
