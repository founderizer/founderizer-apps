import Foundation

/// One file of the hub's knowledge catalog (`/ui/state` `knowledge`), without its text. The owner's files are in
/// knowledge/owner/ (scope `owner`). Every other file is internal: the agents use it, and the app does not show it.
public struct KnowledgeEntry: Decodable, Identifiable, Equatable, Sendable {
    public let path: String
    public let title: String
    /// `owner` or `internal`. nil from a hub before owner knowledge, whose files are all internal.
    public let scope: String?
    public let bytes: Int?
    /// The line under the title: the file's name or the page's address, and the date.
    public let source: String?
    public let commit: String
    public var id: String { path }
    public var isOwner: Bool { scope == "owner" }
    /// Where the file came from and when, read from `source`; nil without one.
    public var origin: KnowledgeOrigin? { source.map(KnowledgeOrigin.init(line:)) }
}

/// **When and from what a file came in**, under its title on its card (the owner, 3 November 2026: "what is this
/// knowledge file? ... how and why it was generated?", and his yes to "Added 30 Oct 2026 · Shop relaunch plan
/// v5"). The hub writes every owner file's line as "<source> · <how> <yyyy-mm-dd>" (`knowledge_content`): `how` is
/// "added", "fetched" for a page it reads again, or "changed" after the owner's edit (`knowledge_edit`).
public struct KnowledgeOrigin: Equatable, Sendable {
    /// What it came from, whole: a plan, a file's name, a page's address.
    public let source: String
    /// "added" or "read", as the hub wrote it; nil for a line without its date.
    public let how: String?
    /// The day it came in, at midnight UTC; nil for a line without it.
    public let day: Date?

    public init(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = trimmed.range(of: " · ", options: .backwards),
           let match = trimmed[cut.upperBound...].wholeMatch(of: /([a-z]+) (\d{4})-(\d{2})-(\d{2})/),
           let year = Int(match.2), let month = Int(match.3), let date = Int(match.4) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            source = String(trimmed[..<cut.lowerBound]); how = String(match.1)
            day = calendar.date(from: DateComponents(year: year, month: month, day: date))
        } else {
            source = trimmed; how = nil; day = nil
        }
    }

    /// What it came from in a few words: the source up to its first clause, without what follows a comma, a bracket,
    /// a semicolon or a date ("Shop relaunch plan v5 of 30 Oct 2026 (…), set on …" is "Shop relaunch plan
    /// v5"). The whole source is on hover.
    public var name: String {
        var end = source.endIndex
        for mark in [", ", " (", "; ", " — "] {
            if let found = source.range(of: mark), found.lowerBound < end { end = found.lowerBound }
        }
        if let found = source.firstMatch(of: #/ of \d/#), found.range.lowerBound < end { end = found.range.lowerBound }
        let words = source[..<end].trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? source : words
    }

    /// The card's line: "Added 30 Oct 2026 · Shop relaunch plan v5", the date as this Mac writes one; the name
    /// alone for a line without a date.
    public func line(locale: Locale = .current) -> String {
        guard let how, let day else { return name }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: TimeZone(identifier: "UTC")!)
        return "\(how.prefix(1).uppercased() + how.dropFirst()) \(day.formatted(style)) · \(name)"
    }
}

/// One owner file with its text (`GET /ui/knowledge`). The text is untrusted display content.
public struct KnowledgeFile: Decodable, Sendable {
    public let db: String
    public let path: String
    public let title: String
    public let source: String?
    public let text: String
}

/// **The text of one owner file while the owner edits it** (owner feature `knowledge_edit`, UI-API.md 1.84; the owner's
/// yes of 5 November 2026 to "Pencil, then edit"): what the box holds, and the text that the hub has. Both are the text
/// after the file's "# <title>" and "Source: " lines, which the hub keeps as they are and which the box does not show.
public struct KnowledgeEdit: Equatable, Sendable {
    public let path: String
    /// The text that the hub has now: what a save compares with.
    public var saved: String
    /// What the box holds.
    public var text: String

    /// The edit of a file as the hub gave it, or nil for a file without its title and Source lines: the hub changes
    /// only a file that has them.
    public init?(file: KnowledgeFile) {
        guard let body = Self.body(of: file.text) else { return nil }
        path = file.path; saved = body; text = body
    }

    /// The text that a save sends, as the hub keeps it: without the empty lines and spaces at its ends.
    public var sent: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The box holds other text than the hub has. An empty box is a problem, not a change: the hub refuses no text.
    public var isChanged: Bool { !sent.isEmpty && sent != saved.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The words for an empty box, which is never sent.
    public static let empty = "A knowledge file needs text. To remove the file, delete it on its card."

    /// The text after a file's "# <title>" and "Source: " lines (the hub's `knowledge_content`), or nil without them.
    public static func body(of text: String) -> String? {
        let parts = text.components(separatedBy: "\n\n")
        guard parts.count >= 3, parts[0].hasPrefix("# "), !parts[0].contains("\n"), parts[1].hasPrefix("Source: "),
              !parts[1].contains("\n") else { return nil }
        var body = parts[2...].joined(separator: "\n\n")
        while body.hasSuffix("\n") { body.removeLast() }
        return body
    }
}

/// The hub's answer to `POST /ui/knowledge`.
public struct KnowledgeReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let path: String
    public let title: String?
    public let deleted: Bool?
    public let commit: String
}

/// The owner's knowledge files at the hub (owner feature `owner_knowledge`): read one, add a file's text or a page,
/// delete one, and give one to an agent in its profile. Its own session waits longer than the state reads do, because
/// the hub reads a page (20 seconds at most) and commits before it answers. A request that gets no answer can have
/// arrived: the hub refuses a second add of the same file (409) and a second delete (404), so a new request is safe.
public final class KnowledgeClient: Sendable {
    public static let feature = "owner_knowledge"
    /// The most text that one file can have: the hub keeps at most 1 MiB with the title and the source line.
    public static let textLimit = 1_000_000
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    public func file(hub: URL, database: String, path: String) async throws -> KnowledgeFile {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/knowledge"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database), .init(name: "path", value: path)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let file = try JSONDecoder().decode(KnowledgeFile.self, from: await perform(request))
        guard file.db == database, file.path == path else { throw HubError.invalidResponse }
        return file
    }

    /// Adds a file's text as knowledge/owner/<name>.md. `source` is the file's name.
    public func add(hub: URL, database: String, client: String, title: String, text: String, source: String) async throws -> KnowledgeReceipt {
        try await change(hub: hub, database: database, client: client, ["title": title, "text": text, "source": source])
    }

    /// Owner feature `attachment_knowledge` (UI-API.md 1.30): the words of a text file the owner attached become
    /// knowledge/owner/<slug>.md, and the original leaves the ninety-day sweep with it. The hub takes the title from
    /// the file's own first heading, and then from its name, where the owner gives none. It answers 415 for a file
    /// that cannot be text; that one is kept as the file itself (`HubClient.keep`, UI-API.md 1.31).
    public func add(attachment: Int, hub: URL, database: String, client: String,
                    title: String? = nil) async throws -> KnowledgeReceipt {
        var fields: [String: Any] = ["attachment": attachment]
        if let title { fields["title"] = title }
        return try await change(hub: hub, database: database, client: client, fields)
    }

    /// The hub reads a public page and keeps its readable text.
    public func addPage(hub: URL, database: String, client: String, url: String) async throws -> KnowledgeReceipt {
        try await change(hub: hub, database: database, client: client, ["url": url])
    }

    /// Owner feature `knowledge_edit` (UI-API.md 1.84): new text for a file that is there. The hub keeps its path, its
    /// title and its source; its Source line then says "changed" and today's date, and a page is not read again.
    public static let editFeature = "knowledge_edit"

    public func edit(hub: URL, database: String, client: String, path: String, text: String) async throws -> KnowledgeReceipt {
        let receipt = try await change(hub: hub, database: database, client: client, ["path": path, "text": text])
        guard receipt.path == path, receipt.deleted != true else { throw HubError.invalidResponse }
        return receipt
    }

    /// The hub refuses to delete a file that a profile lists (409): remove it from the profiles first.
    public func delete(hub: URL, database: String, client: String, path: String) async throws -> KnowledgeReceipt {
        let receipt = try await change(hub: hub, database: database, client: client, ["path": path, "delete": true])
        guard receipt.deleted == true, receipt.path == path else { throw HubError.invalidResponse }
        return receipt
    }

    /// Gives one file to one agent (`on`) or takes it away, in the "Knowledge files" section of the agent's profile as
    /// the page read it. When the profile changed meanwhile (409), it reads the profile again and tries once more.
    public func setAvailable(_ on: Bool, path: String, profile: AgentProfile, hub: URL, database: String, client: String) async throws {
        var profile = profile
        for attempt in 1...2 {
            guard let sections = try KnowledgeAccess.sections(profile.sections, path: path, on: on, agent: profile.agent) else { return }
            let request = PendingRequest(hub: hub, database: database, client: client,
                                         command: .profile(agent: profile.agent, sha256: profile.sha256),
                                         text: try ProfileInput(sections: sections).payload())
            do {
                _ = try await HubClient().command(request)
                return
            } catch HubError.refusal(409, _) where attempt == 1 {
                let list = try await HubClient().profiles(hub: hub, database: database)
                guard let fresh = list.profiles.first(where: { $0.agent == profile.agent }) else { throw HubError.invalidResponse }
                profile = fresh
            }
        }
    }

    private func change(hub: URL, database: String, client: String, _ fields: [String: Any]) async throws -> KnowledgeReceipt {
        let requestID = UUID().uuidString.lowercased()
        var request = URLRequest(url: hub.appendingPathComponent("ui/knowledge"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields.merging(["request_id": requestID, "db": database]) { _, new in new })
        let receipt = try JSONDecoder().decode(KnowledgeReceipt.self, from: await perform(request))
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client else { throw HubError.invalidResponse }
        return receipt
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Unexpected HTTP response."
            throw HubError.refusal(response.statusCode, String(message.prefix(500)))
        }
        return data
    }

    private struct ErrorBody: Decodable { let error: String }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The "Knowledge files" section of a profile lists the files that the agent uses.
public enum KnowledgeAccess {
    /// The files that the profile lists, or nil when its section has a line that is not a file.
    public static func paths(_ sections: [ProfileSection]) -> [String]? {
        guard let section = sections.first(where: { $0.key == "knowledge_files" }) else { return [] }
        return ProfileGuide.knowledgePaths(section.text)
    }

    /// The sections with `path` in the "Knowledge files" section (`on`) or without it, or nil when nothing changes. A new
    /// section goes at the end. The section goes away with its last file, because the hub refuses an empty list.
    public static func sections(_ sections: [ProfileSection], path: String, on: Bool, agent: String) throws -> [ProfileSection]? {
        guard var paths = paths(sections) else { throw KnowledgeAccessError(agent: agent) }
        guard paths.contains(path) != on else { return nil }
        if on { paths.append(path) } else { paths.removeAll { $0 == path } }
        var result = sections
        if let index = result.firstIndex(where: { $0.key == "knowledge_files" }) {
            if paths.isEmpty { result.remove(at: index) } else { result[index].text = ProfileGuide.knowledgeText(paths) }
        } else {
            result.append(ProfileSection(key: "knowledge_files", title: "Knowledge files", text: ProfileGuide.knowledgeText(paths)))
        }
        return result
    }
}

/// A "Knowledge files" section with a line that is not a file: Fleet does not change it.
public struct KnowledgeAccessError: LocalizedError {
    public let agent: String
    public var errorDescription: String? {
        "The Knowledge files section of \(agent.agentLabel) has a line that is not a file. Correct it in the agent's profile first."
    }
}
