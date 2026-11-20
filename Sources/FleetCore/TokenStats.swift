import Foundation

/// **The tokens of a period by day, agent and model** (`GET /ui/costs` with `by=day,agent,model`, owner feature
/// `costs_by`, UI-API.md 1.260; the owner's "Yes, as drawn" of 20 November 2026 to the picture of Settings › Stats):
/// what the hub's 15-minute slots of each session's growth add up to on each day of the fleet's own time zone, for each
/// agent and each model of any provider, with the list dollars of each group at the prices of its runtime.
public struct TokenSeries: Decodable, Sendable, Equatable {
    public struct Row: Decodable, Sendable, Equatable {
        /// A date of the fleet's time zone, `2026-11-19`.
        public let day: String
        /// The agent's name, or the name that an agent no longer in the team had (`deleted`).
        public let agent: String
        /// The model as its runtime named it, `own/<model>` for one of the owner's own server or machine, nil for one
        /// that no report named.
        public let model: String?
        /// When an agent that is no longer in the team left it; nil for an agent of the team.
        public let deleted: Double?
        public let input: Int
        public let cache_read: Int
        public let cache_write: Int
        public let output: Int
        public let calls: Int
        /// List dollars of the group's tokens that have a price; nil when none has one.
        public let cost: Double?

        public init(day: String, agent: String, model: String?, deleted: Double? = nil, input: Int, cache_read: Int,
                    cache_write: Int, output: Int, calls: Int, cost: Double?) {
            self.day = day; self.agent = agent; self.model = model; self.deleted = deleted; self.input = input
            self.cache_read = cache_read; self.cache_write = cache_write; self.output = output; self.calls = calls
            self.cost = cost
        }
    }

    public let db: String
    public let by: [String]
    /// The fleet's own time zone, of which the days are dates.
    public let zone: String
    public let rows: [Row]

    /// The parts that the page asks for, in their order.
    public static let parts = ["day", "agent", "model"]
    /// The hub feature that answers `by` (UI-API.md 1.260).
    public static let feature = "costs_by"

    public init(db: String, by: [String] = parts, zone: String, rows: [Row]) {
        self.db = db; self.by = by; self.zone = zone; self.rows = rows
    }

    /// The answer of `database` for the page's parts, with each row whose counts are counts and whose day is a date;
    /// nil for an answer of another database or of other parts, which no row of it can stand for.
    public func checked(database: String) -> TokenSeries? {
        guard db == database, by == Self.parts, rows.count <= 1_000_000 else { return nil }
        let kept = rows.filter { row in
            [row.input, row.cache_read, row.cache_write, row.output, row.calls].allSatisfy { $0 >= 0 }
                && (row.cost.map { $0.isFinite && $0 >= 0 } ?? true) && TokenStats.isDate(row.day)
        }
        return TokenSeries(db: db, by: by, zone: zone, rows: kept)
    }
}

/// **The page's numbers out of one `TokenSeries`**: the totals of the period, each agent's or each model's own, and
/// each day's list dollars by the groups of the most of them. The agents that are not in the team now are one group,
/// as the Agents page's chart draws them: by the team's names, since the hub knows no time of a delete before its
/// version 1.212.
public struct TokenStats: Sendable, Equatable {
    public struct Totals: Sendable, Equatable {
        public var input = 0
        public var cacheRead = 0
        public var cacheWrite = 0
        public var output = 0
        public var calls = 0
        /// List dollars of the tokens that have a price; nil when none has one.
        public var cost: Double?

        public init() {}

        public var tokens: Int { input + cacheRead + cacheWrite + output }

        mutating func add(_ row: TokenSeries.Row) {
            input += row.input; cacheRead += row.cache_read; cacheWrite += row.cache_write; output += row.output
            calls += row.calls
            if let more = row.cost { cost = (cost ?? 0) + more }
        }
    }

    /// The switch over the chart and the table.
    public enum Split: String, Sendable, CaseIterable, Hashable {
        case agents, models
    }

    /// One group of a split. `key` is an agent's name or a model's ("" for a model that no report named); nil is the
    /// agents that are no longer in the team, all together.
    public struct Group: Sendable, Equatable, Identifiable {
        public let key: String?
        public var totals: Totals
        public var id: String { key.map { "=" + $0 } ?? "gone" }
    }

    /// A part of the chart's columns: one group, or all the groups past the ones of the most list dollars.
    public enum Series: Sendable, Equatable, Hashable {
        case group(String?)
        case others
    }

    /// One day's column: each series' list dollars, in the order of the chart's series, and the day's totals.
    public struct Column: Sendable, Equatable {
        public let day: String
        public let costs: [Double]
        public let totals: Totals
    }

    /// Every day of the period, oldest first, also a day with no tokens.
    public let days: [String]
    public let totals: Totals
    /// Each model of the whole reading, of every period ("" for a model that no report named), the most list dollars
    /// of the whole reading first, then by name: the same order in each period, so that a model keeps its colour
    /// (`GlyphLook.team`) from one period to another, and the nine models of the most dollars of the 90 days take the
    /// glyphs' nine hues before one of them comes again. With ten models or more, one of the most dollars of a shorter
    /// period that is not of those nine can share a hue with one of them in the chart. As the order follows the dollars
    /// of the 90 days, a change of that order (two models whose dollars cross, a new model, or a day that leaves the 90
    /// days) can give other hues to the models from the first one that moved on.
    public let models: [String]
    private let rows: [TokenSeries.Row]
    private let team: Set<String>

    /// The numbers of `series` over `days` for the agents of `team`; a row of a day that is not one of them counts
    /// nowhere.
    public init(series: TokenSeries, days: [String], team: Set<String>) {
        let shown = Set(days)
        self.days = days
        self.team = team
        rows = series.rows.filter { shown.contains($0.day) }
        var dollars: [String: Double] = [:]
        for row in series.rows { dollars[row.model ?? "", default: 0] += row.cost ?? 0 }
        models = dollars.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        var sum = Totals()
        for row in rows { sum.add(row) }
        totals = sum
    }

    /// Each group of the split with its totals: the most list dollars first, a group with no price after those with
    /// one, then the most tokens, then by name.
    public func groups(_ split: Split) -> [Group] {
        var found: [String: Group] = [:]
        for row in rows {
            let key = key(of: row, split)
            found[key.map { "=" + $0 } ?? "gone", default: Group(key: key, totals: Totals())].totals.add(row)
        }
        return found.values.sorted { a, b in
            switch (a.totals.cost, b.totals.cost) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if a.totals.tokens != b.totals.tokens { return a.totals.tokens > b.totals.tokens }
                return (a.key ?? "\u{10FFFF}") < (b.key ?? "\u{10FFFF}")
            }
        }
    }

    /// The chart: the `top` groups of the most list dollars that are not the agents no longer in the team (one more
    /// where it is the only other one), then one series of all the others where there are any, and one column for each
    /// day of the period.
    public func chart(_ split: Split, top: Int = 5) -> (series: [Series], columns: [Column]) {
        let priced = groups(split).filter { ($0.totals.cost ?? 0) > 0 }
        let byName = priced.filter { $0.key != nil }
        // one group past the first ones, and no agent that left: its own name, which "Other" would hide
        let count = byName.count == top + 1 && !priced.contains { $0.key == nil } ? top + 1 : top
        let named = byName.prefix(count).map(\.key)
        let firsts = Set(named.compactMap { $0 })
        let hasOthers = rows.contains { row in
            guard (row.cost ?? 0) > 0 else { return false }
            guard let key = key(of: row, split) else { return true }
            return !firsts.contains(key)
        }
        let series = named.map { Series.group($0) } + (hasOthers ? [.others] : [])
        let index = Dictionary(uniqueKeysWithValues: series.enumerated().map { ($1, $0) })
        var costs = Dictionary(uniqueKeysWithValues: days.map { ($0, [Double](repeating: 0, count: series.count)) })
        var totals = Dictionary(uniqueKeysWithValues: days.map { ($0, Totals()) })
        for row in rows {
            totals[row.day]?.add(row)
            guard let cost = row.cost, cost > 0 else { continue }
            let key = key(of: row, split)
            let at = key.flatMap { firsts.contains($0) ? index[.group($0)] : nil } ?? index[.others]
            if let at { costs[row.day]?[at] += cost }
        }
        return (series, days.map { Column(day: $0, costs: costs[$0] ?? [], totals: totals[$0] ?? Totals()) })
    }

    /// **Each group's list dollars of each day of the period** (`Group.id` → one sum for each of `days`), for the small
    /// columns of its row; a group with no priced token on any day has none.
    public func dayCosts(_ split: Split) -> [String: [Double]] {
        let at = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1, $0) })
        var out: [String: [Double]] = [:]
        for row in rows {
            guard let day = at[row.day], let cost = row.cost, cost > 0 else { continue }
            out[key(of: row, split).map { "=" + $0 } ?? "gone", default: [Double](repeating: 0, count: days.count)][day]
                += cost
        }
        return out
    }

    /// **The provider of a model by its name, for its logo** (`ProviderIcon`, as the Agents page names an agent's AI):
    /// the seller that the name starts with (`openrouter/`, `opencode-go/`, `ollama-cloud/`), else the maker that the
    /// name says (Claude, the GPT and o models of OpenAI, Grok, Gemini); the owner's own model for `own/`; nil for a
    /// name that says none, which the generic mark stands for. `name` is the maker's or the seller's own name, which
    /// the mark says on hover: never the program's (a Claude model can run in another program than Claude Code), and
    /// nil for the owner's own model, whose words the page has.
    public static func provider(of model: String) -> (runtime: String, provider: ModelProvider?, name: String?)? {
        let name = model.lowercased()
        if name.hasPrefix("own/") { return (ModelProvider.own.runtime, .own, nil) }
        for seller in ModelProvider.sellers where name.hasPrefix(seller.rawValue + "/") {
            return (seller.runtime, seller, seller.label)
        }
        let last = name.split(separator: "/").last.map(String.init) ?? name
        if last.contains("claude") { return ("claude", nil, "Anthropic") }
        if last.hasPrefix("gpt") || last.contains("codex") || ["o1", "o3", "o4"].contains(where: { last == $0 || last.hasPrefix($0 + "-") }) {
            return ("codex", nil, "OpenAI")
        }
        if last.hasPrefix("grok") { return (ModelProvider.grok.runtime, .grok, "xAI") }
        if last.contains("gemini") { return (ModelProvider.gemini.runtime, .gemini, "Google") }
        return nil
    }

    private func key(of row: TokenSeries.Row, _ split: Split) -> String? {
        switch split {
        case .agents: row.deleted == nil && team.contains(row.agent) ? row.agent : nil
        case .models: row.model ?? ""
        }
    }

    /// The `count` dates that end with the date of `time` in `zone`, oldest first, as the hub writes a day.
    public static func days(count: Int, at time: Double, zone: TimeZone) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: time))
        return (0..<max(count, 1)).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { date(of: $0, in: calendar) }
        }
    }

    static func date(of day: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isDate(_ text: String) -> Bool {
        text.utf8.count == 10 && text.enumerated().allSatisfy { at, c in at == 4 || at == 7 ? c == "-" : c.isASCII && c.isNumber }
    }
}

/// **The numbers of Settings › Stats, in the form of the app's own language** (`Localized.bundle`), the one exception to
/// the plain digits of `Localized.digits`: each count and each dollar sum with the language's thousands separator (the
/// owner, 20 November 2026: "use thousands separators", 57,007 and $2,586 in English), and a short count with the
/// language's own words, as with English digits alone the page in Spanish wrote 4.47B, which a Spanish reader takes for
/// a billón (a million million): in Spanish a short count is "737 mil" or "4470 M". A count of four digits has its
/// separator too, as a sheet writes it (Spanish 4.470), so it lines up under 57.007 in a column. Never in the form of the
/// Mac's region, which wrote $2.545 for two thousand dollars in English.
public enum TokenFormat {
    /// The locale of the language of the app's words now, as `AgentPrompt.language(of:)` reads it: the app's first
    /// language for this user, or the language of a test's table of one language.
    public static var language: Locale { Locale(identifier: AgentPrompt.language(of: Localized.bundle) ?? "en") }

    /// A count of tokens, short, in the language's form: 737K and 4.47B in English.
    public static func tokens(_ count: Int, in locale: Locale = language) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(locale))
    }

    /// A whole number with the language's thousands separator: 57,007 in English, 4.470 and 57.007 in Spanish.
    public static func count(_ value: Int, in locale: Locale = language) -> String {
        marks(value.formatted(.number.locale(sheet)), of: locale)
    }

    /// **A count in a column of the table**: whole, with the language's thousands separator, under a million (28,146),
    /// and short from a million on, in the language's own words (the owner, 20 November 2026, after he saw them whole:
    /// "for millions show 1.45M for example instead, otherwise too many numbers"). The short form has two decimals, as a
    /// sheet that shows millions has (1.45M, 30.64M, 1.19B; 30,64 M in Spanish): with three significant digits, 30.6M
    /// and 1.45M stood at one width with their decimal marks apart, a 21-fold difference that a column hid.
    public static func column(_ value: Int, in locale: Locale = language) -> String {
        value < 1_000_000 ? count(value, in: locale)
            : value.formatted(.number.notation(.compactName).precision(.fractionLength(2)).locale(locale))
    }

    /// List dollars with the language's thousands separator: whole dollars from $100 on and cents under it, for a card
    /// and a scale; with `cents` always the cents, for a table's column, whose sums then line up at their decimal mark
    /// as a sheet's do. $0 for nothing (a model of the owner's own); a dash where nothing has a price.
    public static func money(_ value: Double?, cents: Bool = false, in locale: Locale = language) -> String {
        guard let value else { return "—" }
        let whole = !cents && (value == 0 || (value * 100).rounded() >= 10_000)
        return "$" + marks(value.formatted(.number.precision(.fractionLength(whole ? 0 : 2)).locale(sheet)), of: locale)
    }

    /// **The form that groups every number of four digits or more, as a sheet does** (en_US), whose marks `marks` then
    /// makes the language's own: Spanish itself groups only five digits or more (CLDR's minimum grouping digits), so
    /// its 4470 had no separator, and in a right-aligned column its thousands digit stood under the "." of 57.007.
    private static let sheet = Locale(identifier: "en_US")

    /// `english`'s group and decimal marks as `locale` writes them, each mark at once, so "," and "." never swap twice.
    private static func marks(_ english: String, of locale: Locale) -> String {
        let group = locale.groupingSeparator ?? ",", decimal = locale.decimalSeparator ?? "."
        return english.map { $0 == "," ? group : $0 == "." ? decimal : String($0) }.joined()
    }
}
