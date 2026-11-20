import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: the numbers of Settings › Stats (`TokenSeries`, `TokenStats`) out of the hub's answer of
// `GET /ui/costs?by=day,agent,model` (UI-API.md 1.260).
struct TokenStatsTests {
    private func row(_ day: String, _ agent: String, _ model: String?, input: Int, cost: Double?, deleted: Double? = nil,
                     calls: Int = 1) -> TokenSeries.Row {
        TokenSeries.Row(day: day, agent: agent, model: model, deleted: deleted, input: input, cache_read: 10 * input,
                        cache_write: 0, output: input / 10, calls: calls, cost: cost)
    }

    /// **The hub's answer, as it writes it, and only its rows that are counts and dates**: a row with a negative count
    /// or a day that is no date goes, and an answer of another database or of other parts is no answer at all.
    @Test func theAnswerDecodesAndOnlyItsRowsOfCountsAndDatesStay() throws {
        let json = """
        {"db": "g1", "from": 1.0, "to": 2.0, "by": ["day", "agent", "model"], "unit": "list dollars",
         "zone": "Europe/Madrid", "slot_seconds": 900, "exact_from": 1795178564.6,
         "rows": [{"day": "2026-11-19", "agent": "dev", "model": "claude-opus-5-5", "input": 5, "cache_read": 50,
                   "cache_write": 0, "output": 1, "calls": 2, "cost": 0.25},
                  {"day": "2026-11-19", "agent": "gone", "deleted": 1700000000.0, "model": null, "input": 1,
                   "cache_read": 0, "cache_write": 0, "output": 0, "calls": 1, "cost": null},
                  {"day": "yesterday", "agent": "dev", "model": "x", "input": 1, "cache_read": 0, "cache_write": 0,
                   "output": 0, "calls": 1, "cost": 0.1},
                  {"day": "2026-11-19", "agent": "dev", "model": "y", "input": -1, "cache_read": 0, "cache_write": 0,
                   "output": 0, "calls": 1, "cost": 0.1}],
         "total": {"input": 6, "cache_read": 50, "cache_write": 0, "output": 1, "calls": 3, "cost": 0.25}}
        """
        let series = try JSONDecoder().decode(TokenSeries.self, from: Data(json.utf8))
        let checked = try #require(series.checked(database: "g1"))
        #expect(checked.rows.map(\.agent) == ["dev", "gone"])
        #expect(checked.rows[1].deleted == 1_700_000_000 && checked.rows[1].model == nil && checked.rows[1].cost == nil)
        #expect(checked.zone == "Europe/Madrid")
        #expect(series.checked(database: "g2") == nil)
        #expect(TokenSeries(db: "g1", by: ["day", "agent"], zone: "UTC", rows: []).checked(database: "g1") == nil)
    }

    /// **The totals, the rows of each agent or model and the columns of each day add up to the same tokens**: the most
    /// list dollars first and a group with no price after the priced ones; the agents no longer in the team as one
    /// group; the chart's five of the most, then all the other priced tokens in one part; every day of the period a
    /// column, also one with nothing; a model of the owner's own (cost 0) and one with no price in no part of a column.
    @Test func theTotalsTheGroupsAndTheColumnsAddUp() throws {
        let days = ["2026-11-18", "2026-11-19", "2026-11-20"]
        var rows = ["a", "b", "c", "d", "e", "f"].enumerated().map { at, agent in
            row("2026-11-19", agent, "claude-opus-5-5", input: 100 * (at + 1), cost: Double(at + 1))
        }
        rows += [row("2026-11-20", "a", "gpt-6.2-sol", input: 50, cost: 0.5),
                 row("2026-11-20", "old", nil, input: 70, cost: 10, deleted: 1_700_000_000),
                 row("2026-11-20", "local", "own/qwen3:32b", input: 900, cost: 0),
                 row("2026-11-20", "nopr", "mystery-1", input: 40, cost: nil),
                 row("2026-10-01", "a", "claude-opus-5-5", input: 1_000_000, cost: 1_000)]       // not of the period
        // "nopr" and "local" are of the team; "gone" left it before the hub kept a time of a delete
        rows.append(row("2026-11-20", "gone", "claude-opus-5-5", input: 30, cost: 3))
        let team: Set<String> = ["a", "b", "c", "d", "e", "f", "local", "nopr"]
        let stats = TokenStats(series: TokenSeries(db: "g1", zone: "UTC", rows: rows), days: days, team: team)
        #expect(stats.totals.input == 2_100 + 50 + 70 + 900 + 40 + 30)
        #expect(stats.totals.cost == 21 + 0.5 + 10 + 3)
        let agents = stats.groups(.agents)
        #expect(agents.map(\.key) == [nil, "f", "e", "d", "c", "b", "a", "local", "nopr"])
        #expect(agents.first?.totals.cost == 13 && agents.last?.totals.cost == nil)
        #expect(agents.first { $0.key == "a" }?.totals.input == 150)

        let (series, columns) = stats.chart(.agents)
        #expect(series == [.group("f"), .group("e"), .group("d"), .group("c"), .group("b"), .others])
        #expect(columns.map(\.day) == days)
        #expect(columns[0].costs == [0, 0, 0, 0, 0, 0] && columns[0].totals.tokens == 0)
        #expect(columns[1].costs == [6, 5, 4, 3, 2, 1])
        #expect(columns[2].costs == [0, 0, 0, 0, 0, 13.5])         // a's other model and the two agents that left
        #expect(columns[2].totals.input == 50 + 70 + 900 + 40 + 30)

        let models = stats.groups(.models)
        #expect(models.map(\.key) == ["claude-opus-5-5", "", "gpt-6.2-sol", "own/qwen3:32b", "mystery-1"])
        #expect(models.first?.totals.cost == 24)
        #expect(models.first { $0.key == "own/qwen3:32b" }?.totals.cost == 0)
        let (named, modelColumns) = stats.chart(.models)
        #expect(named == [.group("claude-opus-5-5"), .group(""), .group("gpt-6.2-sol")])
        #expect(modelColumns[2].costs == [3, 10, 0.5])
        // the colours' names: each model of the whole reading, the most list dollars of all its days first (so the nine
        // hues go to the models that the chart draws), the same in a period that lacks one of them
        let week = TokenStats(series: TokenSeries(db: "g1", zone: "UTC", rows: rows), days: ["2026-11-19"], team: team)
        #expect(stats.models == ["claude-opus-5-5", "", "gpt-6.2-sol", "mystery-1", "own/qwen3:32b"])
        #expect(week.models == stats.models && !week.groups(.models).contains { $0.key == "gpt-6.2-sol" })
    }

    /// **One group past the five of the most keeps its own name in the chart**, where "Other" would hide a name that
    /// fits; two or more of them are Other.
    @Test func aSingleOtherGroupKeepsItsName() throws {
        let six = ["a", "b", "c", "d", "e", "f"].enumerated().map { at, agent in
            row("2026-11-19", agent, "m", input: 10, cost: Double(at + 1))
        }
        let team = Set(["a", "b", "c", "d", "e", "f", "g"])
        let chart = TokenStats(series: TokenSeries(db: "g1", zone: "UTC", rows: six), days: ["2026-11-19"], team: team)
            .chart(.agents)
        #expect(chart.series == ["f", "e", "d", "c", "b", "a"].map { TokenStats.Series.group($0) })
        let seven = six + [row("2026-11-19", "g", "m", input: 10, cost: 0.5)]
        #expect(TokenStats(series: TokenSeries(db: "g1", zone: "UTC", rows: seven), days: ["2026-11-19"], team: team)
                .chart(.agents).series.last == .others)
    }

    /// **A short count of tokens in the form of the app's language, and every other number in plain digits**, as
    /// every page writes one (`Localized.digits`), never in the form of the Mac's region: English says B, and Spanish
    /// says "mil" and "M", never B (a billón is a million million).
    @Test func theShortCountsFollowTheLanguageAndTheOtherNumbersArePlainDigits() throws {
        let english = Locale(identifier: "en"), spanish = Locale(identifier: "es")
        #expect(TokenFormat.tokens(4_469_636_540, in: english) == "4.47B")
        #expect(TokenFormat.tokens(737_212, in: english) == "737K")
        #expect(!TokenFormat.tokens(4_469_636_540, in: spanish).contains("B"))
        #expect(TokenFormat.tokens(737_212, in: spanish) == "737\u{A0}mil")        // a no-break space, as Spanish writes it
        // the page's own language, with no locale given: the Spanish of the app's words
        #expect(try SpanishTable.run { TokenFormat.tokens(737_212) } == "737\u{A0}mil")
        #expect(TokenFormat.count(57_007) == "57007")
        #expect(TokenFormat.money(2_544.97) == "$2545" && TokenFormat.money(12_345.6) == "$12346")
        #expect(TokenFormat.money(9.04) == "$9.04")
        #expect(TokenFormat.money(0) == "$0" && TokenFormat.money(nil) == "—")
        #expect(try SpanishTable.run { [TokenFormat.count(57_007), TokenFormat.money(9.04)] } == ["57007", "$9.04"])
    }

    /// **The period's days are dates of the fleet's own time zone**: 23:30 in UTC on 19 November is 20 November in
    /// Madrid, so the last day of a Madrid fleet's three days is the 20th, and of a UTC fleet's the 19th.
    @Test func theDaysAreDatesOfTheFleetsTimeZone() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let time = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 23, minute: 30)))
            .timeIntervalSince1970
        #expect(TokenStats.days(count: 3, at: time, zone: try #require(TimeZone(identifier: "Europe/Madrid")))
                == ["2026-11-18", "2026-11-19", "2026-11-20"])
        #expect(TokenStats.days(count: 3, at: time, zone: utc.timeZone) == ["2026-11-17", "2026-11-18", "2026-11-19"])
        #expect(TokenStats.days(count: 90, at: time, zone: utc.timeZone).count == 90)
    }
}
