import Foundation

/// The place of one section in a profile, for the agent's Behaviour tab. A known key is in a profile once, so its
/// occurrence is 0. Other sections count in file order: the second `other` section has occurrence 1.
public struct ProfileSectionID: Hashable, Codable, Sendable {
    public let key: String
    public let occurrence: Int
    public init(key: String, occurrence: Int = 0) { self.key = key; self.occurrence = occurrence }
}

/// The plain name of each profile section, the one line that says what to write in it, and the hub's title rules
/// (UI-API.md, "Profiles").
public enum ProfileGuide {
    /// The known keys in their usual order, each with the titles that the hub reads as that key. Every other title
    /// makes an `other` section.
    public static let known: [(key: String, titles: [String])] = [
        ("character", ["Character"]),
        ("responsible_for", ["Responsible for"]),
        ("may_do", ["May do without asking", "What you may decide without the owner"]),
        ("must_ask", ["Must ask first", "What goes to the owner (Needs you)"]),
        ("knowledge", ["Knowledge"]),
        ("logins", ["Logins it may use", "Logins"]),
        ("knowledge_files", ["Knowledge files"])]
    /// The sections that every profile has exactly once. They cannot be deleted.
    public static let required: Set<String> = ["character", "responsible_for", "may_do", "must_ask"]
    /// The plain name of each known key in Fleet. It is not a title for the hub: a saved section keeps its own title.
    private static let names = ["character": "Character", "responsible_for": "Responsible for", "may_do": "May do without asking",
                                "must_ask": "Asks you first", "knowledge": "Knowledge", "logins": "Logins it may use",
                                "knowledge_files": "Knowledge files"]

    /// The key that the hub gives a title, as its `profile_key` does: a known title in any case, else `other`.
    public static func key(forTitle title: String) -> String {
        let lowered = title.lowercased()
        return known.first { $0.titles.contains { $0.lowercased() == lowered } }?.key ?? "other"
    }

    /// The name of a section in Fleet: the plain name of a known key, or the section's own title.
    public static func name(key: String, title: String) -> String { names[key] ?? title }

    /// What to write in a section, in one line.
    public static func description(key: String) -> String {
        switch key {
        case "character": "How this agent behaves and sounds, in one or two sentences."
        case "responsible_for": "What this agent owns and delivers."
        case "may_do": "Decisions it can make alone."
        case "must_ask": "What it must bring to you before it acts."
        case "knowledge": "Facts and links that it must know."
        case "logins": "Saved login names only, never passwords."
        case "knowledge_files": "Files in knowledge/ that it reads first."
        default: "Extra rules for this agent."
        }
    }

    /// The files of a "Knowledge files" text, as the hub reads them: one `- knowledge/<name>.md` on each line. nil when
    /// a line has another form.
    public static func knowledgePaths(_ text: String) -> [String]? {
        var paths: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let item = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { continue }
            guard item.range(of: "^[-*] knowledge/[A-Za-z0-9._/-]+\\.md$", options: .regularExpression) != nil else { return nil }
            let path = String(item.dropFirst(2))
            guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
            paths.append(path)
        }
        return paths
    }

    /// The text of a "Knowledge files" section with these files, in the form that the setup form also writes.
    public static func knowledgeText(_ paths: [String]) -> String { paths.sorted().map { "- " + $0 }.joined(separator: "\n") }
}

/// One section of a profile, with its place, its plain name and what to write in it.
public struct ProfileSectionEntry: Identifiable, Equatable, Sendable {
    public let id: ProfileSectionID
    public let section: ProfileSection
    public var name: String { ProfileGuide.name(key: section.key, title: section.title) }
    public var description: String { ProfileGuide.description(key: section.key) }
    /// Character, Responsible for, May do without asking and Asks you first: a profile has each of them once.
    public var isRequired: Bool { ProfileGuide.required.contains(section.key) }
    /// A rule of the agent's Behaviour: one of the required sections, or one that the owner added (`other`). Knowledge,
    /// logins and knowledge files are not rules.
    public var isRule: Bool { isRequired || section.key == "other" }

    /// Each section in file order, with its place.
    public static func entries(_ sections: [ProfileSection]) -> [ProfileSectionEntry] {
        var seen: [String: Int] = [:]
        return sections.map { section in
            let occurrence = seen[section.key, default: 0]
            seen[section.key] = occurrence + 1
            return ProfileSectionEntry(id: ProfileSectionID(key: section.key, occurrence: occurrence), section: section)
        }
    }
}

extension AgentProfile {
    /// The sections in file order, each with its place.
    public var entries: [ProfileSectionEntry] { ProfileSectionEntry.entries(sections) }
}

/// The first lines of a section's text, for its card. Only the editor shows the whole text.
public struct ProfilePreview: Equatable, Sendable {
    /// The first lines that have text, each with at most `width` characters.
    public let lines: [String]
    /// The number of lines with text after them.
    public let more: Int
    /// True when a shown line was cut.
    public let cut: Bool

    public init(_ text: String, lines count: Int = 4, width: Int = 240) {
        let all = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let shown = all.prefix(count)
        lines = shown.map { $0.count > width ? String($0.prefix(width - 1)) + "…" : $0 }
        more = all.count - shown.count
        cut = shown.contains { $0.count > width }
    }
}

/// What a rebase did to an open section edit.
public enum ProfileRebase: Equatable, Sendable {
    /// The section is as it was when the edit started. Other sections can have changed.
    case unchanged
    /// The saved title or text of this section also changed meanwhile.
    case sectionChanged
    /// The profile does not have this section now.
    case gone
}

/// The owner's edit of one profile section. A save sends every section of the version that the edit is based on,
/// with only this section changed, added or left out, against that version's SHA-256. So the hub refuses it with 409
/// when the profile changed meanwhile, and no other change is lost.
public struct ProfileSectionEdit: Equatable, Sendable {
    public let agent: String
    public private(set) var id: ProfileSectionID
    /// The SHA-256 of the profile version that a save goes against.
    public private(set) var baseSHA256: String
    /// The saved sections of that version.
    public private(set) var sections: [ProfileSection]
    /// A rule that the profile does not have yet: a save adds it as the last section.
    public private(set) var isNew = false
    /// The owner's title. The editor shows it for an `other` section only.
    public var title: String
    public var text: String

    public init?(profile: AgentProfile, id: ProfileSectionID) {
        guard let entry = profile.entries.first(where: { $0.id == id }) else { return nil }
        agent = profile.agent; self.id = id; baseSHA256 = profile.sha256; sections = profile.sections
        title = entry.section.title; text = entry.section.text
    }

    /// A new rule of the owner: an `other` section after the last section, with no title and no text yet.
    public init(newRuleIn profile: AgentProfile) {
        agent = profile.agent; baseSHA256 = profile.sha256; sections = profile.sections
        id = Self.nextOther(in: profile.sections); isNew = true; title = ""; text = ""
    }

    /// The place of an `other` section that a save adds after the last section.
    private static func nextOther(in sections: [ProfileSection]) -> ProfileSectionID {
        ProfileSectionID(key: "other", occurrence: sections.filter { $0.key == "other" }.count)
    }

    private var index: Int? { isNew ? nil : ProfileSectionEntry.entries(sections).firstIndex { $0.id == id } }
    /// This section as it is saved in the base version; nil for a new rule.
    public var saved: ProfileSection? { index.map { sections[$0] } }
    public var name: String { ProfileGuide.name(key: id.key, title: normalizedTitle) }
    /// Every section but the four required ones can be deleted.
    public var canDelete: Bool { !ProfileGuide.required.contains(id.key) }
    /// The title as the hub keeps it: one line without space at its ends and without a final period. A known section
    /// keeps its saved title, so that the hub reads the same key again.
    public var normalizedTitle: String {
        guard id.key == "other" else { return saved?.title ?? title }
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".") { value = String(value.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return value
    }
    /// The text as the hub keeps it: Unix line ends, without empty space at its ends.
    public var normalizedText: String {
        text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The text or title differs from the saved one. A new rule is always a change.
    public var isChanged: Bool { isNew || saved.map { $0.title != normalizedTitle || $0.text != normalizedText } ?? false }

    /// Every section of the base version, with this section changed, added or, with `deleting`, left out.
    public func input(deleting: Bool = false) -> ProfileInput {
        var result = sections
        let section = ProfileSection(key: id.key, title: normalizedTitle, text: normalizedText)
        if isNew {
            if !deleting { result.append(section) }
        } else if let index {
            if deleting { result.remove(at: index) } else { result[index] = section }
        }
        return ProfileInput(sections: result)
    }

    /// The existing profile save (`POST /ui/profiles/<agent>`) against the base version.
    public var command: OwnerCommand { .profile(agent: agent, sha256: baseSHA256) }
    public func payload(deleting: Bool = false) throws -> String { try input(deleting: deleting).payload() }

    /// The first hub rule that a save would break, in words, or nil. `catalog` holds the paths of the hub's knowledge
    /// catalog, for a "Knowledge files" section.
    public func problem(deleting: Bool = false, catalog: Set<String>? = nil) -> String? {
        guard isNew || saved != nil else { return "This section is not in the profile now. Reload the profile." }
        if deleting {
            guard canDelete else { return "\(name) cannot be deleted. Every profile has it once." }
        } else {
            if id.key == "other" {
                let title = normalizedTitle
                if title.isEmpty || title.unicodeScalars.count > 80 { return "A title has 1 to 80 characters." }
                if title.contains(where: \.isNewline) { return "A title has one line only." }
                if title.contains("*") { return "A title cannot contain *." }
                if ProfileGuide.key(forTitle: title) != "other" { return "“\(title)” is the title of another section. Use another title." }
            }
            let text = normalizedText
            if text.isEmpty {
                return isNew ? "Write the text of this rule." : canDelete ? "Write a text, or delete this section." : "Write a text. This section cannot be empty."
            }
            let count = text.unicodeScalars.count
            // Numbers as his Mac writes them (review B13, fix round 2): "8,000" was fixed in the code, the count bare.
            if count > 8000 { return "A text has at most \(8000.formatted()) characters. This text has \(count.formatted())." }
            if let line = text.split(separator: "\n").first(where: { $0.range(of: "^\\*\\*[^*\\n]+?\\.\\*\\*", options: .regularExpression) != nil }) {
                return "A line cannot start like a section title: “\(line.prefix(40))”."
            }
            if id.key == "knowledge_files" {
                guard let paths = ProfileGuide.knowledgePaths(text) else { return "Each line names one file, for example “- knowledge/services.md”." }
                if !(1...32).contains(paths.count) || Set(paths).count != paths.count { return "Select 1 to 32 different files." }
                if let catalog, let missing = paths.first(where: { !catalog.contains($0) }) {
                    return "\(missing) is not in the knowledge catalog. Clear it before you save."
                }
            }
        }
        // The hub checks every section of the profile, not only this one.
        let input = input(deleting: deleting)
        if let other = input.sections.first(where: { ProfileGuide.key(forTitle: $0.title) != $0.key }) {
            return "The section “\(other.title)” has the title of another section. The hub cannot save this profile until that title changes."
        }
        if input.wireSize > ProfileInput.wireLimit { return "The whole profile must stay under 32 KiB. Make this text shorter." }
        guard input.isValid else { return "Another section of this profile breaks a hub rule. Check the profile file." }
        return nil
    }

    /// Takes a newer version as the base: the other sections become that version's, and the owner's title and text
    /// stay. The section is found at its place. An `other` section must also keep its saved title there, or it is
    /// found by that title. A new rule goes after the newer version's last section.
    public mutating func rebase(on profile: AgentProfile) -> ProfileRebase {
        guard profile.agent == agent else { return .gone }
        if isNew {
            id = Self.nextOther(in: profile.sections); baseSHA256 = profile.sha256; sections = profile.sections
            return .unchanged
        }
        guard let before = saved else { return .gone }
        let entries = profile.entries, place = id
        let found: ProfileSectionEntry?
        if place.key != "other" { found = entries.first(where: { $0.id == place }) }
        else {
            found = entries.first(where: { $0.id == place && $0.section.title == before.title }) ??
                entries.first(where: { $0.section.key == "other" && $0.section.title == before.title }) ??
                entries.first(where: { $0.id == place })
        }
        guard let found else { return .gone }
        id = found.id; baseSHA256 = profile.sha256; sections = profile.sections
        return found.section == before ? .unchanged : .sectionChanged
    }

    /// The hub saved `sent`, this edit as it was sent, as the version `sha256`. That version is the new base: a later
    /// save goes against it, and the owner's newer text stays.
    public mutating func update(after sent: ProfileSectionEdit, sha256: String) {
        id = sent.id; baseSHA256 = sha256; sections = sent.input().sections; isNew = false
    }
}

/// What a profile save that did not complete means for its editor.
public enum ProfileSaveOutcome: Equatable, Sendable {
    /// 409: the profile changed meanwhile, or the hub's checkout cannot take a change now. Nothing was saved. The
    /// words are the hub's.
    case changedMeanwhile(String)
    /// Another refusal, in the hub's words. Nothing was saved.
    case refused(String)
    /// The request waits for its receipt. The app keeps it, and the window's request line can retry it.
    case waiting

    /// The outcome of the save `command`, from the app's waiting request; nil when that request is not this save.
    public init?(pending: PendingRequest?, command: OwnerCommand) {
        guard let pending, pending.command == command else { return nil }
        guard let refusal = pending.refusal else { self = .waiting; return }
        let words = HubError.refusalWords(in: refusal) ?? refusal
        self = HubError.refusalStatus(in: refusal) == 409 ? .changedMeanwhile(words) : .refused(words)
    }
}

extension HubError {
    private static let refusalPrefix = "Hub refused the request ("

    /// The HTTP status in the words of a refusal, as `errorDescription` writes them; nil for other words.
    public static func refusalStatus(in text: String) -> Int? {
        guard text.hasPrefix(refusalPrefix) else { return nil }
        let rest = text.dropFirst(refusalPrefix.count)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard digits.count == 3, rest.dropFirst(3).hasPrefix("):") else { return nil }
        return Int(digits)
    }

    /// The hub's own words in a refusal, after its status; nil for other words.
    public static func refusalWords(in text: String) -> String? {
        guard refusalStatus(in: text) != nil else { return nil }
        return String(text.dropFirst(refusalPrefix.count + 5)).trimmingCharacters(in: .whitespaces)
    }
}
