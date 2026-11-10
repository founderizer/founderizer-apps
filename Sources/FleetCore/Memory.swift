import Foundation

/// An agent's own memory (owner feature `agent_memory`, `GET /ui/memory/<agent>`): the lessons it keeps for its own
/// next sessions, written with `remember` or out of the work with `deliver_result` and `close_case`.
///
/// The hub gives the lessons that stand, as the agent's own `recall` sees them — not forgotten, not folded into a
/// summary, not archived — newest first and at most 200, with how many there are in all. Each one carries the hub's
/// own evidence about it, and that evidence decides nothing: the counts are the hub's and what to do about them is
/// the agent's, in its daily review. The app reads these and writes none of them, and the hub has no owner write
/// here either: they are the agent's words about its own work, as its notes are.
public struct AgentMemory: Decodable, Sendable {
    /// `ui_features` of a hub that serves the lessons. A hub from before 25 October 2026 answers 404, so the name is
    /// the only way the app learns the route is there.
    public static let feature = "agent_memory"

    /// What kind of lesson one is. A kind this app does not know yet decodes as `other` and is drawn as a lesson,
    /// with no mark of its own: a newer hub must never make the whole list unreadable.
    public enum Kind: Decodable, Equatable, Sendable {
        case lesson
        /// What did NOT work: a dated observation about somebody else's system, with what it cost and how to test
        /// cheaply whether the wall still stands.
        case deadEnd
        case other(String)

        public init(_ raw: String) {
            switch raw {
            case "lesson": self = .lesson
            case "dead_end": self = .deadEnd
            default: self = .other(raw)
            }
        }

        public init(from decoder: Decoder) throws {
            self.init((try? decoder.singleValueContainer().decode(String.self)) ?? "")
        }
    }

    /// One lesson that stands. The words are the agent's own and untrusted: they are display text and nothing else.
    public struct Lesson: Decodable, Identifiable, Equatable, Sendable {
        /// The number of `M-<id>`.
        public let id: Int
        public let kind: Kind
        /// The agent's own short tag: a product, a tool, a person, the fleet.
        public let about: String
        public let text: String
        /// What the agent expects the lesson to prevent.
        public let prevents: String?
        /// When it was written, and the task it was written in (nil outside a task, and for a summary).
        public let at: Double?
        public let task: Int?
        /// How many times the case key it claimed to prevent came back, and the last time.
        public let contradicted: Int
        public let contradicted_at: Double?
        /// A lesson with no case key that the work has not borne out for 60 days; a dead end nobody tested again.
        public let stale: Bool
        /// How many times the agent said the work bore it out again, and when a keyless one held that way turns
        /// stale unless it is borne out once more.
        public let held: Int
        public let held_until: Double?
        /// A dead end's own: what the work that found it cost, and how to test cheaply whether it still holds.
        public let cost_minutes: Int?
        public let recheck: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, about, text, prevents, at, task, contradicted, contradicted_at, stale, held, held_until
            case cost_minutes, recheck
        }

        public init(id: Int, kind: Kind = .lesson, about: String, text: String, prevents: String? = nil,
                    at: Double? = nil, task: Int? = nil, contradicted: Int = 0, contradicted_at: Double? = nil,
                    stale: Bool = false, held: Int = 0, held_until: Double? = nil, cost_minutes: Int? = nil,
                    recheck: String? = nil) {
            self.id = id; self.kind = kind; self.about = about; self.text = text; self.prevents = prevents
            self.at = at; self.task = task; self.contradicted = contradicted; self.contradicted_at = contradicted_at
            self.stale = stale; self.held = held; self.held_until = held_until
            self.cost_minutes = cost_minutes; self.recheck = recheck
        }

        /// The lesson itself is required; every mark of evidence is read where the hub gives it and is otherwise
        /// no news, so a hub that adds, drops or retypes one never makes the list unreadable.
        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(Int.self, forKey: .id)
            text = try fields.decode(String.self, forKey: .text)
            kind = (try? fields.decodeIfPresent(Kind.self, forKey: .kind)) ?? .lesson
            about = (try? fields.decodeIfPresent(String.self, forKey: .about)) ?? ""
            prevents = try? fields.decodeIfPresent(String.self, forKey: .prevents)
            at = try? fields.decodeIfPresent(Double.self, forKey: .at)
            task = try? fields.decodeIfPresent(Int.self, forKey: .task)
            contradicted = (try? fields.decodeIfPresent(Int.self, forKey: .contradicted)) ?? 0
            contradicted_at = try? fields.decodeIfPresent(Double.self, forKey: .contradicted_at)
            stale = (try? fields.decodeIfPresent(Bool.self, forKey: .stale)) ?? false
            held = (try? fields.decodeIfPresent(Int.self, forKey: .held)) ?? 0
            held_until = try? fields.decodeIfPresent(Double.self, forKey: .held_until)
            cost_minutes = try? fields.decodeIfPresent(Int.self, forKey: .cost_minutes)
            recheck = try? fields.decodeIfPresent(String.self, forKey: .recheck)
        }

        /// What the hub has news about, in the order a row draws it from left to right; empty for a lesson with
        /// nothing to tell, which shows no mark at all.
        public var news: [LessonNews] {
            var said: [LessonNews] = []
            if kind == .deadEnd { said.append(.deadEnd) }
            if stale { said.append(.stale) }
            if contradicted > 0 { said.append(.contradicted(contradicted)) }
            return said
        }
    }

    public let db: String
    public let agent: String
    /// How many lessons stand, of which `lessons` is the newest part.
    public let total: Int
    /// The lessons that stand, newest first.
    public let lessons: [Lesson]

    public func validate(database: String, agent: String) throws {
        guard db == database, self.agent == agent, total >= lessons.count, lessons.count <= 4096,
              lessons.allSatisfy({ $0.id > 0 }),
              Set(lessons.map(\.id)).count == lessons.count else { throw HubError.invalidResponse }
    }
}

/// One mark of a lesson's row: news the hub has about it, and nothing that is fine.
public enum LessonNews: Hashable, Sendable {
    case deadEnd
    case stale
    /// How many times its case key came back.
    case contradicted(Int)

    /// The words behind the mark: its hover text and its accessibility label.
    public var words: String {
        switch self {
        case .deadEnd: return "Dead end"
        case .stale: return "Stale"
        case .contradicted(let times): return times > 1 ? "Contradicted \(times) times" : "Contradicted"
        }
    }
}
