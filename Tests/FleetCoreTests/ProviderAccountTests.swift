import Foundation
import Testing
@testable import FleetCore

// **The words of the provider and account card.** The owner, 20 October 2026, with two pictures of one agent:
// "regarding the manager, there should be some consistency in the views!" and "look at the messages, what do they
// even mean, they dont make any sense!". So these tests hold the card to his own fleet of that evening: a manager
// on `team@example.com` at 92% of its week, a Studio on `owner@example.com` at 0%, and two Codex
// workers on one account between them.

private let now = 10_000.0
private let features = [AccountLimits.emailFeature]

private func limits(_ json: [String: Any]) throws -> AccountLimits {
    try JSONDecoder().decode(AccountLimits.self, from: JSONSerialization.data(withJSONObject: json))
}

private func window(_ json: [String: Any]) throws -> UsageWindow {
    try JSONDecoder().decode(UsageWindow.self, from: JSONSerialization.data(withJSONObject: json))
}

private func manager(at read: Double = now - 60) throws -> AccountLimits {
    try limits(["collected_at": read, "source": "Claude Code /usage cache", "plan": "Claude",
                "account_key": "anthropic:3912", "account_email": "team@example.com", "windows": []])
}

private func facts(_ reading: AccountLimits?, runtime: String = "claude", fresh: Bool = true, signedIn: Bool? = true,
                   sharedWith: [String] = [], tokens: Int64? = nil, local: Bool = false) -> ProviderAccountFacts {
    ProviderAccountFacts(runtime: runtime,
                         email: AccountEmail(limits: reading, at: now, fresh: fresh, features: features),
                         plan: reading?.plan, localModel: local, weekMissing: reading?.weekMissing == true,
                         signedIn: signedIn,
                         stale: !fresh || reading?.isStale(at: now) == true, collectedAt: reading?.collected_at,
                         sharedWith: sharedWith, tokens: tokens, error: reading?.error)
}

// MARK: the account, named the way he names one

@Test func bothWindowsOfAnAccountStandAndAModelsOwnOneOnlyWhenItHasBeenSpent() throws {
    // The owner, 21 October 2026: the day and the week, each a bar, and no clock time on either.
    let manager = try reading("Claude", "team@example.com", managerWindows())
    #expect(manager.ownWindows(at: now).map(\.id) == ["session:0", "weekly_all:1"])
    // His Studio reports a day and a model's own week, untouched: the model's week is a row that says things are
    // fine, and that one is cut.
    let studio = try reading("Claude Max 5x", "owner@example.com", studioWindows())
    #expect(studio.ownWindows(at: now).map(\.id) == ["session:0"])
    // Spend something in it and it is a fact again.
    var spent = studioWindows()
    spent[1]["used_percent"] = 4
    #expect(try reading("Claude Max 5x", "owner@example.com", spent).ownWindows(at: now).map(\.id)
            == ["session:0", "weekly_scoped:1"])
    // Codex names its own windows and both of them stand.
    let codex = try reading("plus", "team@example.com", [
        ["id": "codex:primary", "label": "codex / 5 hours", "used_percent": 0, "window_minutes": 300, "resets_at": now + 18_000],
        ["id": "codex:secondary", "label": "codex / 7 days", "used_percent": 16, "window_minutes": 10080, "resets_at": now + 519_000],
    ], source: "Codex account/rateLimits/read")
    #expect(codex.ownWindows(at: now).map(\.id) == ["codex:primary", "codex:secondary"])
}

@Test func theAccountIsNamedByItsOwnAddress() throws {
    let row = facts(try manager())
    #expect(row.title == "team@example.com")
    // His plan field for this account reads "Claude", and "Claude Code · Claude" was the provider said twice.
    #expect(row.detail == "Claude Code")
}

@Test func aProviderThatWritesItsPlanInLowerCaseGetsACapitalAndOneThatNamedItselfKeepsIt() throws {
    let codex = try limits(["collected_at": now - 60, "source": "Codex account/rateLimits/read", "plan": "plus",
                            "account_email": "team@example.com", "windows": []])
    #expect(facts(codex, runtime: "codex").detail == "Codex · Plus")
    let studio = try limits(["collected_at": now - 60, "source": "Claude Code /usage cache", "plan": "Claude Max 5x",
                             "account_email": "owner@example.com", "windows": []])
    // `capitalized` would make this "Claude Max 5X", which is not what Anthropic calls the plan.
    #expect(facts(studio).detail == "Claude Code · Claude Max 5x")
}

@Test func anAccountWithNoAddressSaysSoAndIsNeverNamedByItsProvider() throws {
    let none = try limits(["collected_at": now - 60, "source": "Claude Code /usage cache", "windows": []])
    #expect(facts(none).title == "Account not reported")
}

@Test func anOldReadingNeverLooksCurrent() throws {
    let row = facts(try manager(at: now - 4_000))
    #expect(row.title == "team@example.com")
    #expect(row.detail == "Claude Code · last reading")
    // The desktop row carries the same line with the age behind it, where he can do nothing about it.
    #expect(row.detailWithoutAge == "Claude Code")
    #expect(row.help { "D\(Int($0))" }.contains("Last reading: D6000"))
}

@Test func aProviderThatIsSignedOutOnItsMachineIsTheOneThingTheRowSays() throws {
    #expect(facts(try manager(), signedIn: false).detail == "Claude Code · not signed in")
    // A machine that has not said is not a claim that it is signed out.
    #expect(facts(try manager(), signedIn: nil).detail == "Claude Code")
}

@Test func aLocalModelHasNoAccountToChange() throws {
    let row = facts(nil, local: true)
    #expect(row.title == "Local model")
    #expect(row.detail == "No account of a provider")
}

// MARK: what is true but is not a row

@Test func anAccountTwoAgentsShareSaysSoOnItsRowAndBehindIt() throws {
    let codex = try limits(["collected_at": now - 60, "source": "Codex account/rateLimits/read", "plan": "plus",
                            "account_email": "team@example.com", "windows": []])
    let row = facts(codex, runtime: "codex", sharedWith: ["worker4"])
    // On the face, because it changes how the share under it reads.
    #expect(row.detail == "Codex · Plus · shared with Worker4")
    #expect(row.help { "D\(Int($0))" }.contains("Same account as Worker4: one allowance between them."))
}

@Test func theRecordedTokensAreBehindTheRowAndNotARowOfTheirOwn() throws {
    let help = facts(try manager(), tokens: 9_471_087).help { "D\(Int($0))" }
    #expect(help.contains("tokens recorded"))
    #expect(help.contains("9,471,087") || help.contains("9.471.087"))
}

@Test func aHelpLineIsNeverThereWithNothingToSay() throws {
    let bare = ProviderAccountFacts(runtime: "claude", email: .unknown, plan: nil)
    #expect(bare.help { "D\(Int($0))" }.isEmpty)
}

// MARK: the allowance, which is what a choice of account is made on

@Test func aWindowIsNamedByItsLengthAsEveryScreenNamesIt() throws {
    // One notation for one fact (T-08): the Agents table says "5 h · 71%", and "Today" named a window of five hours.
    #expect(try window(["id": "a", "label": "5 hours", "used_percent": 36, "window_minutes": 300]).shortTitle == "5 h")
    #expect(try window(["id": "b", "label": "7 days", "used_percent": 92, "window_minutes": 10080]).shortTitle == "7 d")
    #expect(try window(["id": "c", "label": "7 days (Fable)", "used_percent": 0, "window_minutes": 10080]).shortTitle == "7 d (Fable)")
    // Codex writes its own name into the label; the account row above has already said it.
    #expect(try window(["id": "d", "label": "codex / 5 hours", "used_percent": 0, "window_minutes": 300]).shortTitle == "5 h")
    // A window of another length keeps its length, and one with no length keeps whatever the provider called it.
    #expect(try window(["id": "f", "label": "codex / 43200 minutes", "used_percent": 0, "window_minutes": 43200]).shortTitle == "30 d")
    #expect(try window(["id": "e", "label": "Monthly", "used_percent": 4]).shortTitle == "Monthly")
}

// MARK: which windows earn a row — his own rule, on his own fleet

/// A reading of his, with windows, as the hub gave them this morning.
private func reading(_ plan: String, _ email: String, _ windows: [[String: Any]], source: String = "Claude Code /usage cache",
                     at read: Double = now - 60) throws -> AccountLimits {
    try limits(["collected_at": read, "source": source, "plan": plan, "account_email": email, "windows": windows])
}

private func managerWindows() -> [[String: Any]] { [
    ["id": "session:0", "label": "5 hours", "used_percent": 5, "window_minutes": 300, "resets_at": now + 4_680],
    ["id": "weekly_all:1", "label": "7 days", "used_percent": 97, "window_minutes": 10080, "resets_at": now + 115_200],
    ["id": "weekly_scoped:2", "label": "7 days (Fable)", "used_percent": 0, "window_minutes": 10080, "resets_at": now + 115_200],
] }

/// His Studio's reading: a day with no reset time at all, a Fable week, and no week of the plan.
private func studioWindows() -> [[String: Any]] { [
    ["id": "session:0", "label": "5 hours", "used_percent": 0, "window_minutes": 300],
    ["id": "weekly_scoped:1", "label": "7 days (Fable)", "used_percent": 0, "window_minutes": 10080, "resets_at": now + 196_000],
] }

@Test func anAccountThatReportsItsWeekSaysNothingAboutIt() throws {
    #expect(try reading("Claude", "team@example.com", managerWindows()).weekMissing == false)
    // Both Codex workers, on one account: a week of its own, and a day at 0% that earns no row.
    let codex = try reading("plus", "team@example.com", [
        ["id": "codex:primary", "label": "codex / 5 hours", "used_percent": 0, "window_minutes": 300, "resets_at": now + 18_000],
        ["id": "codex:secondary", "label": "codex / 7 days", "used_percent": 16, "window_minutes": 10080, "resets_at": now + 519_000],
    ], source: "Codex account/rateLimits/read")
    #expect(codex.weekMissing == false)
    #expect(facts(codex, runtime: "codex", sharedWith: ["worker4"]).detail == "Codex · Plus · shared with Worker4")
    // The desktop account of his Studio reports one window of a month, which is a week or longer.
    let desktop = try reading("free", "billing@example.com", [
        ["id": "codex:primary", "label": "codex / 43200 minutes", "used_percent": 0, "window_minutes": 43200, "resets_at": now + 2_400_000],
    ], source: "Codex account/rateLimits/read")
    #expect(desktop.weekMissing == false)
    #expect(facts(desktop, runtime: "codex").detailWithoutAge == "Codex · Free")
    // A reading with no window at all is the silence itself, and the account's row says that; no clause here.
    #expect(try manager().weekMissing == false)
}

@Test func anOldReadingDrawsNoRowAtAllBecauseTheNumberIsNotCurrent() throws {
    // The card asks for the windows only while the reading is current: a meter nobody can refresh is read as
    // where the account stands now, and it is not.
    let old = try reading("Claude Max 5x", "owner@example.com", studioWindows(), at: now - 4_000)
    #expect(old.isStale(at: now))
}

// MARK: the account as a row of the Overview

// The owner, 25 October 2026: "Make it simple: Show Server, AI Provider, Account and Usage, that's it!!" The provider
// is a row of its own there, so the account row says the account and nothing about the provider.

@Test func theAccountRowSaysTheAddressAndLeavesTheProviderToItsOwnRow() throws {
    let manager = try manager()
    #expect(facts(manager).accountWords == "team@example.com")
    // His Claude plan reads "Claude", which the provider already says: no line under the row at all.
    #expect(facts(manager).accountDetail == nil)
    let studio = try reading("Claude Max 5x", "owner@example.com", studioWindows())
    #expect(facts(studio).accountDetail == "Claude Max 5x")
    let codex = try reading("plus", "team@example.com", [], source: "Codex account/rateLimits/read")
    #expect(facts(codex, runtime: "codex", sharedWith: ["mia"]).accountDetail == "Plus · shared with Mia")
}

@Test func aSignedOutAccountSaysSoAndNothingElse() throws {
    // An address from before the sign-out is not the account it runs on now.
    let signedOut = facts(try manager(), signedIn: false)
    #expect(signedOut.accountWords == "Not signed in")
    #expect(signedOut.accountDetail == nil)
    #expect(facts(nil, runtime: "codex", signedIn: nil).accountWords == "Not reported")
    #expect(facts(nil, local: true).accountWords == "Local model")
}

@Test func anOldAddressSaysThatItIsTheLastReading() throws {
    let old = facts(try manager(at: now - 4_000), fresh: true)
    #expect(old.accountWords == "team@example.com")
    #expect(old.accountDetail == "last reading")
}
