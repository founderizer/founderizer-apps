import Foundation

/// An agent's own working notes (owner feature `agent_notes`, `GET /ui/notes/<agent>`).
///
/// A short text the agent writes about **how it works** — the order that works, the check that catches the mistake
/// it makes — carried into the start of its next task session as its own notes and never as rules. It rewrites them
/// in the daily review that puts its duties in order, and nothing else asks for a rewrite.
///
/// The app reads these and writes none of them, and the hub has no owner write here either: the profile is the
/// owner's words about the agent and only he writes those; the notes are the agent's words about its own work and
/// only it writes those. This route is the owner's window into how each agent actually operates.
public struct AgentNotes: Decodable, Sendable {
    /// `ui_features` of a hub that serves the notes. A hub from before 19 October 2026 answers 404, so the name is
    /// the only way the app learns the route is there.
    public static let feature = "agent_notes"

    /// One version. Every one is kept, with what it changed (`why`) and where it was written — the task, and the
    /// duty case when the review was one. That provenance is what lets a strange note be traced back to the work
    /// that produced it.
    public struct Version: Decodable, Identifiable, Equatable, Sendable {
        public let revision: Int
        public let text: String
        public let why: String?
        public let by: String?
        public let at: Double?
        public let task: Int?
        public let duty_case: Int?
        public var id: Int { revision }

        public init(revision: Int, text: String, why: String? = nil, by: String? = nil, at: Double? = nil,
                    task: Int? = nil, duty_case: Int? = nil) {
            self.revision = revision; self.text = text; self.why = why
            self.by = by; self.at = at; self.task = task; self.duty_case = duty_case
        }
    }

    public let db: String
    public let agent: String
    /// The notes as they stand, or nil for an agent that has written none.
    public let text: String?
    /// The revision of the notes that stand now, or 0 while there are none.
    public let revision: Int
    /// Every version, newest first.
    public let versions: [Version]

    /// The notes as they stand, without their surrounding blank lines, or nil when there are none to show.
    public var said: String? {
        let words = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// The versions before the one that stands now, newest first.
    public var earlier: [Version] { versions.filter { $0.revision != revision } }

    public func validate(database: String, agent: String) throws {
        guard db == database, self.agent == agent, revision >= 0, versions.count <= 4096,
              versions.allSatisfy({ $0.revision > 0 }),
              Set(versions.map(\.revision)).count == versions.count,
              (versions.first?.revision ?? 0) == revision,
              (revision == 0) == (text == nil) else { throw HubError.invalidResponse }
    }
}
