import Foundation

/// **An agent's KPIs, as its KPIs tab shows them** (owner API 1.275, `GET /ui/kpis`; section 8.2 of the KPI design,
/// `~/dev/founderizer-plans/agent-kpis-spec.md`, whose picture the owner saw on 20 November 2026). The agent that gives
/// an agent its tasks sets them; the owner reads them here and changes them in words to the fleet manager, so the tab
/// draws and sends nothing.
public struct AgentKPIs: Decodable, Sendable {
    /// `ui_features` of a hub that serves the KPIs.
    public static let feature = "kpis"
    public let db: String
    public let agent: String?
    public let kpis: [KPI]

    /// **The agent's page has a KPIs tab** (8.2): a worker or a lead, never the fleet manager, on a hub that serves
    /// them, with at least one active KPI (`FleetAgent.kpis`, the snapshot's count).
    public static func tabShown(role: String?, features: [String], count: Int?) -> Bool {
        (role == "worker" || role == "lead") && features.contains(feature) && (count ?? 0) > 0
    }
}

/// One active KPI of an agent: its words, its level and the newest value that counts, its weeks and the changes in
/// them.
public struct KPI: Decodable, Identifiable, Sendable, Equatable {
    /// One period of 7 days, the oldest first: the newest value in it, and whether that value counts (its window lies
    /// wholly after the KPI's link to its check).
    public struct Week: Decodable, Sendable, Equatable {
        public let start: Double
        public let value: Double?
        public let counts: Bool

        public init(start: Double, value: Double?, counts: Bool) {
            self.start = start; self.value = value; self.counts = counts
        }
    }

    /// A change of the KPI, of its check, or of the agent's work, from the start of the first week.
    public struct Mark: Decodable, Sendable, Equatable {
        public let at: Double
        public let words: String

        public init(at: Double, words: String) { self.at = at; self.words = words }
    }

    public let id: Int
    public let agent: String
    /// Its title, at most 40 characters.
    public let name: String
    public let words: String
    /// `at_least` or `at_most`.
    public let direction: String
    public let number: Double
    /// `%`, `h`, `d`, a currency code, or "" for a count: for display only.
    public let unit: String
    public let window_days: Int
    /// `no_data`, `on` or `off`.
    public let state: String
    /// The agent that set it, and that agent as the owner's apps name it.
    public let setter: String
    public let setter_role: String?
    public let created: Double
    public let weeks: [Week]
    public let marks: [Mark]
    public let value: Double?
    public let value_counts: Bool

    public init(id: Int, agent: String, name: String, words: String, direction: String, number: Double, unit: String,
                window_days: Int, state: String, setter: String, setter_role: String?, created: Double, weeks: [Week],
                marks: [Mark],
                value: Double?, value_counts: Bool) {
        self.id = id; self.agent = agent; self.name = name; self.words = words; self.direction = direction
        self.number = number; self.unit = unit; self.window_days = window_days; self.state = state
        self.setter = setter; self.setter_role = setter_role; self.created = created; self.weeks = weeks; self.marks = marks
        self.value = value; self.value_counts = value_counts
    }

    /// The level is a floor (`at_least`), else a ceiling.
    public var atLeast: Bool { direction == "at_least" }

    /// The newest value is off target: the state that the hub keeps, which the large value draws in red.
    public var isOff: Bool { state == "off" }

    /// A value against the level: under a floor, or over a ceiling.
    public func isOff(_ value: Double) -> Bool { atLeast ? value < number : value > number }

    /// The level beside the value: "≥ 80%", "≤ 5 h", "≥ 12".
    public var levelWords: String { (atLeast ? "≥ " : "≤ ") + Self.amount(number, unit) }

    /// The newest value that counts, as the card says it large, or nil, for which the card shows a dash: a value before
    /// the KPI's window after its link counts for nothing, and a later one is newer than it.
    public var shownValue: String? { value_counts ? value.map { Self.amount($0, unit) } : nil }

    /// A week's column: the value that counts, else none (the short gray stub).
    public func counted(_ week: Week) -> Double? { week.counts ? week.value : nil }

    /// The top of the columns' one scale: the highest value that counts, or the level when it is higher, and room
    /// above it, so the level's line stands inside the chart and never on its top edge, where it read as a rule under
    /// the card's head (Fable's validation of 21 November 2026).
    public var scaleTop: Double { max(weeks.compactMap(counted).max() ?? 0, number, 1e-9) * 1.15 }

    /// The changes inside one week, oldest first: after its start and up to its end, as the hub counts a week's
    /// value (a period that ends at its read).
    public func marks(in week: Week) -> [Mark] {
        marks.filter { $0.at > week.start && $0.at <= week.start + 7 * 86_400 }
    }

    /// A number with its unit, as the card and its hover say it, in the Mac's own way of writing numbers: "82%",
    /// "4.5 h", "1,200", "€1,200.00".
    public static func amount(_ value: Double, _ unit: String, locale: Locale = .current) -> String {
        if Locale.commonISOCurrencyCodes.contains(unit) {          // a unit of three capitals may be no money
            return value.formatted(.currency(code: unit).locale(locale))
        }
        if unit == "%" {               // the Mac's own way: "82%", "82 %" in Spanish
            return (value / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
        }
        let number = value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return unit.isEmpty ? number : number + " " + unit
    }
}
