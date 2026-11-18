import Foundation
import Testing
@testable import FleetCore

// The two readings a page keeps while it polls (`RuleReading` behind the schedules of an agent's Overview, and
// `ProfileReading` behind Behaviour). Both kept a last reading out of a `try?` and reported a fixed warning, so a
// refused Mac, a hub that was not serving and a generation that had moved all read the same to the owner.
//
// What these tests hold: the four states stay apart (`UI-PATTERNS.md`), an old reading never reads as current, and
// the hub's own sentence reaches the row where the hub wrote one — and only the screen's own line where it did not.

struct ReadingTests {
    private let refused = HubError.refusal(HubRefusal(status: 403, hubWords: "this Mac is not the owner's machine"))
    private let silent = HubError.refusal(HubRefusal(status: 503, hubWords: HubError.unexplained))

    private func rules(_ id: Int = 4) throws -> [FleetTrigger] {
        let fields: [String: Any] = [
            "id": id, "agent": "vps", "state": "active", "revision": 1,
            "schedule": try payloadFields(TriggerSchedule(kind: "weekly", days: ["mon"], timezone: "Europe/Madrid")),
            "task": try payloadFields(TriggerTask(title: "Synthetic task", details: "Local check", done_when: "A result exists")),
            "late_minutes": 60, "max_tasks_per_day": 4, "tasks_24h": 0, "created": 1000, "updated": 1000,
            "author": "vps", "request_id": UUID().uuidString.lowercased()
        ]
        return [try JSONDecoder().decode(FleetTrigger.self, from: JSONSerialization.data(withJSONObject: fields))]
    }

    private func profiles() throws -> ProfileList {
        let fields: [String: Any] = ["db": "db", "revision": String(repeating: "a", count: 40), "profiles": []]
        return try JSONDecoder().decode(ProfileList.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    // MARK: the schedules of an agent's Overview

    @Test func aFirstScheduleReadThatFailedSaysWhatTheHubSaid() throws {
        let failed = RuleReading.loading.after(nil, reason: HubError.said(refused))
        #expect(failed == .failed("this Mac is not the owner's machine"))
        #expect(failed.rules == nil && !failed.isStale)
        #expect(failed.notReadWarning == "this Mac is not the owner's machine. Founderizer tries again every 15 seconds.")
    }

    @Test func aRefusalWithNoWordsLeavesTheScheduleRowItsOwnLine() throws {
        let failed = RuleReading.loading.after(nil, reason: HubError.said(silent))
        #expect(failed == .failed(nil))
        #expect(failed.notReadWarning == "The schedules could not be read. Founderizer tries again every 15 seconds.")
    }

    @Test func anOldScheduleReadingKeepsItsRowsAndStillSaysTheyCanBeOld() throws {
        let list = try rules()
        let current = RuleReading.loading.after(list)
        #expect(current == .current(list) && current.reason == nil && !current.isStale)
        let old = current.after(nil, reason: HubError.said(refused))
        // The rows stay, so the owner keeps seeing his schedules — but the reading is marked and gives no next time.
        #expect(old.rules == list && old.isStale)
        #expect(old.lastReadingWarning ==
                "this Mac is not the owner's machine. These rows can be old; Founderizer tries again every 15 seconds.")
        // A second failure keeps the same rows and takes the newer reason.
        let again = old.after(nil, reason: HubError.said(HubError.refusal(HubRefusal(status: 503, hubWords: "the hub is restarting"))))
        #expect(again.rules == list && again.reason == "the hub is restarting")
        // And a read that works clears it.
        #expect(again.after(list) == .current(list))
    }

    @Test func aReadingThatIsOnlyOldCarriesNoReasonBecauseNothingWasRefused() throws {
        // Without a current hub state every reading is old (`aged`), and that is not a refusal: there is no sentence
        // of the hub's to show, so the screen keeps its own line.
        let aged = RuleReading.loading.after(try rules()).aged

        #expect(aged.isStale && aged.reason == nil)
        #expect(aged.lastReadingWarning ==
                "The schedules could not be read. These rows can be old; Founderizer tries again every 15 seconds.")
        #expect(RuleReading.loading.aged == .loading && RuleReading.failed(nil).aged == .failed(nil))
    }

    @Test func filteringAnOldScheduleReadingKeepsItStaleAndKeepsItsReason() throws {
        let list = try rules(4)
        let old = RuleReading.loading.after(list).after(nil, reason: "the hub is restarting")
        let kept = old.filter { $0.id == 4 }, dropped = old.filter { $0.id == 9 }
        #expect(kept.isStale && kept.reason == "the hub is restarting" && kept.rules?.count == 1)
        // An empty filtered list is still an old reading, never a current empty one.
        #expect(dropped.isStale && dropped.reason == "the hub is restarting" && dropped.rules?.isEmpty == true)
        #expect(RuleReading.failed("gone").filter { _ in true } == .failed("gone"))
    }

    // MARK: the profiles behind Behaviour

    @Test func aFirstProfileReadThatFailedSaysWhatTheHubSaid() throws {
        let failed = ProfileReading.loading.after(nil, reason: HubError.said(refused))
        #expect(failed.list == nil)
        #expect(failed.reason == "this Mac is not the owner's machine")
        #expect(failed.notReadDetail ==
                "this Mac is not the owner's machine. Founderizer reads the profile again every 15 seconds.")
    }

    @Test func aRefusedProfileReadWithNoWordsLeavesTheScreenItsOwnLine() throws {
        let failed = ProfileReading.loading.after(nil, reason: HubError.said(silent))
        #expect(failed.reason == nil)
        #expect(failed.notReadDetail == "Founderizer reads the profile again every 15 seconds.")
        #expect(failed.lastReadingLine == "Last reading. Founderizer reads the profile again every 15 seconds.")
    }

    @Test func anOldProfileReadingKeepsTheProfileAndStillSaysItIsTheLastReading() throws {
        let current = ProfileReading.loading.after(try profiles())
        #expect(current.list != nil && current.reason == nil && current.failedSince == nil)
        let start = ContinuousClock.now
        let old = current.after(nil, reason: HubError.said(refused), at: start)
        #expect(old.list != nil)
        if case .stale = old {} else { Issue.record("A failed read over a list is an old reading, not a failure.") }
        #expect(old.lastReadingLine ==
                "this Mac is not the owner's machine. Last reading. Founderizer reads the profile again every 15 seconds.")
        // One break counts from the first of the reads that failed in a row (`StateReading.pageReadingIsOld`): a read
        // that fails after it does not start it again, or a profile whose reads all fail would never say so.
        let again = old.after(nil, at: start + .seconds(25))
        #expect(again.failedSince == start && again.list != nil)
        #expect(ProfileReading.loading.after(nil, at: start).after(nil, at: start + .seconds(25)).failedSince == start)
        // A new visit counts its own break: reads that failed in an earlier one, unread since, say nothing to it.
        let visit = start + .seconds(3_600)
        #expect(old.visited(at: visit).failedSince == visit && old.visited(at: visit).list != nil)
        #expect(ProfileReading.loading.after(nil, at: start).visited(at: visit).failedSince == visit)
        // The old reading is cleared by a read that works.
        let read = try profiles()
        if case .current = old.after(read) {} else { Issue.record("A read that works is current again.") }
        #expect(old.after(read).after(nil, at: start + .seconds(40)).failedSince == start + .seconds(40))
    }

    // MARK: a page's own reading (People, Conversations, Devices)

    /// **One break of the hub says nothing on a page's own reading** (17 November 2026: "either fix the underlaying issue
    /// OR not show the wanring at all"): reads that fail in a row keep the moment of the first; until they have failed one
    /// whole break the page draws its last reading as it was read and no reading as its loading line; a new visit counts
    /// its own break.
    @Test func aPagesReadingSaysNothingForOneBreakFromItsFirstFailedRead() {
        let start = ContinuousClock.now, current = PageReading.current([1, 2], at: 100)
        let stale = current.failed("no answer", at: start).failed("no answer", at: start + .seconds(25))
        #expect(stale.failedSince == start && stale.value == [1, 2] && stale.isOld && stale.at == 100)
        let failed = PageReading<[Int]>.loading.failed("refused", at: start).failed("no answer", at: start + .seconds(9))
        #expect(failed.failedSince == start && failed.failure == "no answer")
        // Inside the break: the last reading as it was read, and no reading as loading.
        if case .current(let value, let at) = stale.shown(old: { _ in false }) { #expect(value == [1, 2] && at == 100) }
        else { Issue.record("Inside one break the last reading draws as it was read.") }
        if case .loading = failed.shown(old: { _ in false }) {} else { Issue.record("Inside one break a failed first read is loading.") }
        // After it, or with an old state: the last reading, and the failure in its words.
        #expect(stale.shown(old: { $0 == start }).isOld)
        #expect(failed.shown(old: { $0 == start }).failure == "no answer")
        // An answer ends the row; a new visit counts its own break.
        #expect(current.failedSince == nil && current.visited(at: start).failedSince == nil)
        let visit = start + .seconds(3_600)
        #expect(stale.visited(at: visit).failedSince == visit && stale.visited(at: visit).value == [1, 2])
        #expect(failed.visited(at: visit).failedSince == visit)
    }

    // MARK: the one line itself

    @Test func theReportingLineNeverShowsAStatusAloneAndNeverDropsWhatTheScreenMustSay() {
        // The hub's sentence takes the place of the screen's own words, and the rest always follows it.
        #expect(FleetReading.line("no access", instead: "It could not be read.", then: "It reads again.") ==
                "no access. It reads again.")
        #expect(FleetReading.line(nil, instead: "It could not be read.", then: "It reads again.") ==
                "It could not be read. It reads again.")
        // A sentence the hub closed itself is not closed twice.
        #expect(FleetReading.line("refresh state?", then: "It reads again.") == "refresh state? It reads again.")
        #expect(FleetReading.line("hub generation changed; refresh state.", then: "A.") ==
                "hub generation changed; refresh state. A.")
        // Nothing to put first: the rest stands alone, and no empty sentence is left in front of it.
        #expect(FleetReading.line(nil, then: "It reads again.") == "It reads again.")
        #expect(FleetReading.line("   ", instead: "", then: "It reads again.") == "It reads again.")
    }

    @Test func aPollingReadKeepsTheHubsWordsWhereTryWouldDropThem() async throws {
        let refusal = try OneAnswer(status: "403 Forbidden") { _ in #"{"error":"this Mac is not the owner's machine"}"# }
        let hub = URL(string: "http://127.0.0.1:\(refusal.port)")!
        let read = await FleetReading.read { try await HubClient().triggers(hub: hub, database: "db") }
        #expect(read.value == nil && read.reason == "this Mac is not the owner's machine")
        #expect(RuleReading.loading.after(read.value?.triggers, reason: read.reason) ==
                .failed("this Mac is not the owner's machine"))
    }
}
