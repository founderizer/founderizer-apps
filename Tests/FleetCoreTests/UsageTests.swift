import Foundation
import Testing
@testable import FleetCore

private func tokenFields() -> [String: Any] {
    ["input": 100, "output": 20, "cache_read": 70, "cache_write": 10, "total": 200,
     "sessions": 3, "since": 1000, "last_activity": 1900, "collected_at": 2000,
     "source": "Recorded runtime sessions", "scope": "Fleet workspace only"]
}

private func limitFields() -> [String: Any] {
    ["collected_at": 2000, "source": "Provider account reading", "plan": "team", "account_key": "test-account",
     "windows": [["id": "five_hour", "label": "5 hours", "used_percent": 42.5, "resets_at": 4000, "window_minutes": 300]]]
}

private func usage(tokens: [String: Any]? = tokenFields(), limits: [String: Any]? = limitFields()) throws -> AgentUsage {
    var object: [String: Any] = [:]
    if let tokens { object["tokens"] = tokens }
    if let limits { object["limits"] = limits }
    return try JSONDecoder().decode(AgentUsage.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func localModelKeepsTokensButCannotShowCachedVendorLimits() throws {
    func agent(local: Bool?) throws -> FleetAgent {
        var fields: [String: Any] = ["name": "worker", "role": "worker", "runtime": "codex", "can": [],
            "usage": ["tokens": tokenFields(), "limits": limitFields(),
                      "screen": ["tokens": tokenFields(), "limits": limitFields()]]]
        if let local { fields["local_model"] = local }
        return try JSONDecoder().decode(FleetAgent.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    let local = try agent(local: true)
    #expect(local.accountLimits == nil)
    #expect(local.usage?.tokens?.total == 200)
    #expect(local.usage?.combinedTokens?.total == 400)
    #expect(local.usage?.screen?.limits?.windows.first?.used_percent == 42.5)
    #expect(try agent(local: false).accountLimits?.windows.first?.used_percent == 42.5)
    #expect(try agent(local: nil).accountLimits?.windows.first?.used_percent == 42.5)
}

@Test func tokenTotalCountsInputOutputAndCacheOnce() throws {
    let value = try usage()
    #expect(value.isValid)
    #expect(value.tokens?.total == 200)
    #expect(value.tokens?.input == 100)
    var bad = tokenFields()
    bad["total"] = 280 // Would count the cached input twice.
    #expect(try !usage(tokens: bad).isValid)
    bad["total"] = 200
    bad["cache_read"] = -1
    #expect(try !usage(tokens: bad).isValid)
}

@Test func missingTelemetryNeverBecomesZeroUsage() throws {
    let value = try usage(tokens: nil, limits: nil)
    #expect(value.isValid)
    #expect(value.tokens == nil)
    #expect(value.limits == nil)
    var noReading = limitFields()
    noReading.removeValue(forKey: "collected_at")
    #expect(try !usage(limits: noReading).isValid)
    noReading["windows"] = []
    noReading["error"] = "Account reading failed"
    let waiting = try #require(try usage(limits: noReading).limits)
    #expect(waiting.isValid)
    #expect(waiting.isStale(at: 2000))
}

@Test func readingsKeepTheirAgeAndQuotaMeaning() throws {
    let value = try usage()
    let limits = try #require(value.limits)
    let tokens = try #require(value.tokens)
    #expect(!limits.isStale(at: 2500))
    #expect(limits.isStale(at: 2601))
    #expect(tokens.isStale(at: 2601))
    #expect(limits.isStale(at: 1000))
    let window = try #require(limits.windows.first)
    #expect(window.remainingPercent == 57.5)
    #expect(!window.resetIsPast(at: 3999))
    #expect(window.resetIsPast(at: 4000))
    var failed = limitFields()
    failed["error"] = "Provider refresh failed"
    let retained = try #require(try usage(limits: failed).limits)
    #expect(retained.windows.first?.used_percent == 42.5)
    #expect(retained.collected_at == 2000)
    #expect(retained.isStale(at: 2001))
}

@Test func invalidOrRepeatedQuotaWindowsAreRejected() throws {
    var fields = limitFields()
    let windows = try #require(fields["windows"] as? [[String: Any]])
    fields["windows"] = windows + windows
    #expect(try !usage(limits: fields).isValid)
    var window = windows[0]
    window["used_percent"] = -1
    fields["windows"] = [window]
    #expect(try !usage(limits: fields).isValid)
    window["used_percent"] = 50
    window["resets_at"] = -1
    fields["windows"] = [window]
    #expect(try !usage(limits: fields).isValid)
    window["resets_at"] = 4000
    window["used_percent"] = 105.5
    fields["windows"] = [window]
    let overLimit = try #require(try usage(limits: fields).limits?.windows.first)
    #expect(overLimit.isValid)
    #expect(overLimit.used_percent == 105.5)
    #expect(overLimit.remainingPercent == 0)
}

@Test func agentDecodesTelemetryWithoutChangingIdentity() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "name": "worker", "role": "worker", "runtime": "codex", "can": [],
        "usage": ["tokens": tokenFields(), "limits": limitFields()]
    ])
    let agent = try JSONDecoder().decode(FleetAgent.self, from: data)
    #expect(agent.id == "worker")
    #expect(agent.usage?.tokens?.sessions == 3)
    #expect(agent.usage?.limits?.plan == "team")
    #expect(agent.usage?.isValid == true)
}

@Test func invalidUsageDoesNotBlockAgentStatus() throws {
    for invalid: [String: Any] in [["tokens": ["input": "wrong type"]], ["tokens": tokenFields().merging(["total": 999]) { _, value in value }]] {
        let data = try JSONSerialization.data(withJSONObject: [
            "name": "worker", "role": "worker", "runtime": "codex", "can": [], "last_seen": 2000,
            "usage": invalid
        ])
        let agent = try JSONDecoder().decode(FleetAgent.self, from: data)
        #expect(agent.helperIsRecent(serverTime: 2001))
        #expect(agent.usage == nil)
        #expect(agent.usageError != nil)
    }
}

@Test func anAccountEmailIsTheIdentityOfACurrentReadingNotAnAllowanceFact() throws {
    var fields = limitFields()
    #expect(try usage(limits: fields).limits?.account_email == nil)                             // an older helper reports none
    fields["account_email"] = "owner@example.test"
    let limits = try #require(try usage(limits: fields).limits)
    #expect(limits.account_email == "owner@example.test" && limits.account_key == "test-account")  // the key alone groups routes
    #expect(limits.currentEmail(at: 2500) == "owner@example.test")
    #expect(limits.currentEmail(at: 2601) == nil && limits.currentEmail(at: 1000) == nil)       // an old reading does not look current
    fields["windows"] = []
    fields["error"] = "Account reading failed"                                                  // a reading without an allowance
    let named = try #require(try usage(limits: fields).limits)
    #expect(named.isValid && named.isStale(at: 2001) && named.currentEmail(at: 2001) == "owner@example.test")
    fields.removeValue(forKey: "collected_at")                                                  // no reading time: no identity
    let untimed = try #require(try usage(limits: fields).limits)
    #expect(untimed.isValid && untimed.account_email == nil && untimed.currentEmail(at: 2001) == nil)
}

@Test func aValueThatIsNotOneEmailIsUnknownAndKeepsItsReading() throws {
    let longest = String(repeating: "a", count: 241) + "@example.test"                          // 254 characters: the limit
    for bad in ["codex-team", "", "@example.test", "owner@", "a@b@c", "owner@@example.test", "owner @example.test",
                "owner@example.test\n", "owner\u{202E}@example.test", "a" + longest] {
        var fields = limitFields()
        fields["account_email"] = bad
        let value = try usage(limits: fields)
        #expect(value.isValid && value.limits?.account_email == nil && value.limits?.windows.first?.used_percent == 42.5)
    }
    var fields = limitFields()
    fields["account_email"] = longest
    #expect(try usage(limits: fields).limits?.account_email == longest)
}

@Test func anAgentGivesItsPrimaryRoutesEmailAndItsScreenRouteKeepsItsOwn() throws {
    func agent(local: Bool) throws -> FleetAgent {
        let primary = limitFields().merging(["account_email": "primary@example.test"]) { _, new in new }
        let screen = limitFields().merging(["account_email": "screen@example.test", "account_key": "screen-account"]) { _, new in new }
        let fields: [String: Any] = ["name": "studio", "role": "worker", "runtime": "claude", "can": [], "local_model": local,
            "usage": ["tokens": tokenFields(), "limits": primary, "screen": ["tokens": tokenFields(), "limits": screen]]]
        return try JSONDecoder().decode(FleetAgent.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    let studio = try agent(local: false)
    #expect(studio.accountEmail(at: 2500) == "primary@example.test" && studio.accountEmail(at: 2601) == nil)
    #expect(studio.usage?.screen?.limits?.currentEmail(at: 2500) == "screen@example.test")
    let local = try agent(local: true)                          // a local model's own route has no provider account
    #expect(local.accountEmail(at: 2500) == nil && local.usage?.screen?.limits?.currentEmail(at: 2500) == "screen@example.test")
}
