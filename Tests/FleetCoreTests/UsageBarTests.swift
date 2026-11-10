import Foundation
import Testing
@testable import FleetCore

// The usage-limit bar of the Agents table (`UsageBar`). The hub's time in these tests is 10,000; a reading is old
// after 600 seconds.

private let now = 10_000.0

private func window(_ id: String, _ label: String, _ used: Double, minutes: Int? = nil, resets: Double? = nil) -> [String: Any] {
    var fields: [String: Any] = ["id": id, "label": label, "used_percent": used]
    if let minutes { fields["window_minutes"] = minutes }
    if let resets { fields["resets_at"] = resets }
    return fields
}

private func reading(key: String? = "anthropic:one", at time: Double = now - 60, error: String? = nil, _ windows: [[String: Any]]) -> [String: Any] {
    var fields: [String: Any] = ["collected_at": time, "source": "Claude Code /usage cache", "windows": windows]
    if let key { fields["account_key"] = key }
    if let error { fields["error"] = error }
    return fields
}

private func agent(_ name: String, runtime: String = "claude", limits: [String: Any]? = nil, screen: [String: Any]? = nil,
                   limit: (until: Double, known: Bool)? = nil, local: Bool? = nil) throws -> FleetAgent {
    var fields: [String: Any] = ["name": name, "role": "worker", "runtime": runtime, "can": []]
    if limits != nil || screen != nil {
        var usage: [String: Any] = ["limits": limits ?? NSNull()]
        if let screen { usage["screen"] = ["limits": screen] }
        fields["usage"] = usage
    }
    if let limit { fields["limit"] = ["since": now - 300, "until": limit.until, "reset_known": limit.known] }
    if let local { fields["local_model"] = local }
    return try JSONDecoder().decode(FleetAgent.self, from: JSONSerialization.data(withJSONObject: fields))
}

private func bar(_ agent: FleetAgent, fresh: Bool = true) throws -> UsageBar {
    try #require(UsageBar.bars(for: [agent], time: now, isFresh: fresh)[agent.name])
}

private func words(_ bar: UsageBar) -> String { bar.words { "T\(Int($0))" } }
private func help(_ bar: UsageBar) -> String { bar.help { "D\(Int($0))" } }

@Test func barShowsTheWindowWithTheHighestShare() throws {
    let value = try bar(agent("studio", limits: reading([
        window("five_hour", "5 hours", 40, minutes: 300, resets: now + 3600),
        window("seven_day", "7 days (Fable)", 62.4, minutes: 10_080, resets: now + 86_400),
        window("other", "Account limit", 12)])))
    #expect(value.window?.id == "seven_day")
    #expect(value.percent == 62)
    #expect(words(value) == "7 d · 62%")
    // The hover text has the window's full name and its reset time.
    #expect(help(value) == "7 days (Fable): 62% used · resets D96400")
    // With equal shares the first window of the reading shows.
    let tie = try bar(agent("vps", limits: reading([window("a", "5 hours", 0, minutes: 300), window("b", "7 days", 0, minutes: 10_080)])))
    #expect(tie.window?.id == "a")
    #expect(words(tie) == "5 h · 0%")
    #expect(help(tie) == "5 hours: 0% used · reset not reported")
}

@Test func windowLengthIsShort() throws {
    let lengths = try bar(agent("vps", runtime: "codex", limits: reading([
        window("month", "codex / 43200 minutes", 27, minutes: 43_200), window("hour", "codex / 90 minutes", 3, minutes: 90),
        window("primary", "codex / primary", 1)]))).reading?.windows.map(\.shortLabel)
    #expect(lengths == ["30 d", "90 min", "codex / primary"])
}

@Test func barColorFollowsTheShownPercent() throws {
    #expect(UsageBar.Level(percent: 0) == .low)
    #expect(UsageBar.Level(percent: 79) == .low)
    #expect(UsageBar.Level(percent: 80) == .high)
    #expect(UsageBar.Level(percent: 99) == .high)
    #expect(UsageBar.Level(percent: 100) == .full)
    #expect(UsageBar.Level(percent: 140) == .full)
    func shown(_ used: Double) throws -> UsageBar { try bar(agent("studio", limits: reading([window("w", "5 hours", used, minutes: 300)]))) }
    // The color and the number come from the same whole percent, so they never disagree.
    #expect(try shown(79.4).level == .low)
    #expect(try words(shown(79.5)) == "5 h · 80%")
    #expect(try shown(79.5).level == .high)
    #expect(try shown(99.4).level == .high)
    #expect(try shown(99.5).level == .full)
    #expect(try shown(40).fill == 0.4)
    #expect(try shown(0.4).fill == 0)
    // A provider can report more than 100%: the number stays, the bar is full.
    #expect(try words(shown(120)) == "5 h · 120%")
    #expect(try shown(120).fill == 1)
}

@Test func missingReadingStaysUnknown() throws {
    for unknown in [try agent("mini"), try agent("mini", limits: reading(error: "No account limits were reported.", []))] {
        let value = try bar(unknown)
        #expect(words(value) == "Not reported")
        #expect(value.window == nil && value.percent == nil && value.level == nil && value.fill == 0)
        #expect(!value.isStale && !value.wordsAreOld)
    }
    #expect(try help(bar(agent("mini"))) == "No usage reading yet.")
    #expect(try help(bar(agent("mini", limits: reading(error: "No account limits were reported.", [])))) == "No account limits were reported.")
    // An invalid reading is not shown at all: not as 0%, and not as its last value.
    let invalid = try bar(agent("mini", limits: reading([window("w", "5 hours", -1, minutes: 300)])))
    #expect(words(invalid) == "Not reported")
    #expect(help(invalid) == "The usage reading is invalid. Waiting for a new reading.")
    // A local model has no account limits; its cached vendor windows never show.
    let local = try bar(agent("local", runtime: "codex", limits: reading([window("w", "5 hours", 50, minutes: 300)]), local: true))
    #expect(words(local) == "Local model")
    #expect(local.level == nil)
    #expect(help(local) == "A local model has no account limits.")
}

@Test func oldReadingIsMarkedWithItsTime() throws {
    let current = try bar(agent("studio", limits: reading(at: now - 600, [window("w", "5 hours", 40, minutes: 300, resets: now + 60)])))
    #expect(!current.isStale && !current.wordsAreOld)
    let old = try bar(agent("studio", limits: reading(at: now - 601, [window("w", "5 hours", 40, minutes: 300, resets: now + 60)])))
    #expect(old.isStale && old.wordsAreOld)
    #expect(words(old) == "5 h · 40%")
    #expect(help(old) == "5 hours: 40% used · resets D10060\nLast reading: D9399")
    // A reading with an error keeps its last value, old, with the hub's words.
    let failed = try bar(agent("studio", limits: reading(error: "Account limits could not be refreshed.", [window("w", "5 hours", 40, minutes: 300)])))
    #expect(failed.isStale)
    #expect(help(failed) == "5 hours: 40% used · reset not reported\nLast reading: D9940\nAccount limits could not be refreshed.")
    // Fleet never assumes that a reset happened: after the reset time the last share is old.
    #expect(try bar(agent("studio", limits: reading([window("w", "5 hours", 95, minutes: 300, resets: now)]))).isStale)
    // Without a current hub state, every reading is old.
    #expect(try bar(agent("studio", limits: reading([window("w", "5 hours", 40, minutes: 300)])), fresh: false).isStale)
}

@Test func usageLimitHoldShowsItsEnd() throws {
    let held = try bar(agent("studio", limits: reading(at: now - 900, [window("w", "5 hours", 100, minutes: 300, resets: now + 2700)]),
                             limit: (now + 2700, true)))
    #expect(words(held) == "Usage limit until T12700")
    #expect(held.level == .full && held.isStale)
    // The hold is a current fact of the hub, also when the reading is old.
    #expect(!held.wordsAreOld)
    #expect(help(held) == "Usage limit reached. The hub holds this agent's work until D12700.\n5 hours: 100% used · resets D12700\nLast reading: D9100")
    #expect(try bar(agent("studio", limit: (now + 2700, true)), fresh: false).wordsAreOld)
    // Without a reading the hold shows alone, and an end that the provider did not give is an estimate.
    let estimated = try bar(agent("mini", limit: (now + 3600, false)))
    #expect(words(estimated) == "Usage limit until T13600")
    #expect(estimated.level == nil)
    #expect(help(estimated) == "Usage limit reached. The hub holds this agent's work until about D13600. The provider gave no reset time.\nNo usage reading yet.")
}

@Test func usagePageHasOneColumnForEachWindow() throws {
    let codex = try agent("vps", runtime: "codex", limits: reading(key: "openai:two", [window("w", "codex / 7 days", 75, minutes: 10_080)]))
    let claude = try agent("manager", limits: reading([
        window("session", "5 hours", 11, minutes: 300), window("weekly_all", "7 days", 3, minutes: 10_080),
        window("weekly_scoped", "7 days (Fable)", 0, minutes: 10_080)]))
    let local = try agent("mini", local: true)
    let unread = try agent("scout")
    let bars = UsageBar.bars(for: [codex, claude, local, unread], time: now, isFresh: true)
    // The shorter window first, each one once; a week of one model with nothing spent in it is no column.
    #expect(UsageBar.columns(["vps", "manager", "mini", "scout"].compactMap { bars[$0] }, at: now) == ["5 h", "7 d"])
    // Spent in, it is a column of its own after the week, which came first.
    let fable = try agent("studio", limits: reading(key: "anthropic:two", [
        window("weekly_scoped", "7 days (Fable)", 20, minutes: 10_080), window("session", "5 hours", 1, minutes: 300)]))
    let more = UsageBar.bars(for: [claude, fable, codex], time: now, isFresh: true)
    #expect(UsageBar.columns(["manager", "studio", "vps"].compactMap { more[$0] }, at: now) == ["5 h", "7 d", "7 d (Fable)"])
    // A window with no length comes last.
    let odd = try agent("odd", limits: reading(key: "x:three", [window("a", "Account limit", 12), window("b", "5 hours", 4, minutes: 300)]))
    #expect(UsageBar.columns(UsageBar.bars(for: [odd], time: now, isFresh: true).values.map { $0 }, at: now) == ["5 h", "Account limit"])
    #expect(UsageBar.columns([], at: now) == [])
}

@Test func agentsOnOneAccountShareItsNewestReading() throws {
    let manager = try agent("manager", limits: reading(at: now - 30, [window("w", "5 hours", 40, minutes: 300)]))
    let studio = try agent("studio", limits: reading(at: now - 200, [window("w", "5 hours", 35, minutes: 300)]))
    let vps = try agent("vps", runtime: "codex", limits: reading(key: "openai:two", [window("w", "codex / 7 days", 75, minutes: 10_080)]))
    let bars = UsageBar.bars(for: [manager, studio, vps], time: now, isFresh: true)
    // One account, one bar: the newest reading, never a sum of the two agents' shares.
    #expect(bars["manager"].map(words) == "5 h · 40%")
    #expect(bars["studio"].map(words) == "5 h · 40%")
    #expect(bars["studio"]?.sharedWith == ["manager"])
    #expect(bars["manager"].map(help) == "5 hours: 40% used · reset not reported\nSame account as Studio.")
    #expect(bars["vps"].map(words) == "7 d · 75%")
    #expect(bars["vps"]?.sharedWith == [])
    // A desktop route of another agent can give the newest reading of an account.
    let desktop = try agent("studio", limits: reading(at: now - 200, [window("w", "5 hours", 35, minutes: 300)]),
                            screen: reading(key: "openai:two", at: now - 10, [window("w", "codex / 7 days", 81, minutes: 10_080)]))
    #expect(UsageBar.bars(for: [manager, desktop, vps], time: now, isFresh: true)["vps"].map(words) == "7 d · 81%")
    // A runtime that is signed out keeps its last reading as history: it gives no bar to the account's other agents,
    // and it takes none from them.
    let signedOut = try agent("studio", limits: reading(at: now - 5, error: "CLI sign-in is required.", [window("w", "5 hours", 90, minutes: 300)]))
    let split = UsageBar.bars(for: [manager, signedOut], time: now, isFresh: true)
    #expect(split["manager"].map(words) == "5 h · 40%")
    #expect(split["manager"]?.sharedWith == [])
    #expect(split["studio"].map(words) == "5 h · 90%")
    #expect(split["studio"]?.isStale == true)
    #expect(split["studio"].map(help) == "5 hours: 90% used · reset not reported\nLast reading: D9995\nCLI sign-in is required.")
}
