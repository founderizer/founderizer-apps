import Foundation
import Testing
@testable import FleetCore

/// The standing duties of an agent (UI-API.md 1.13). Both fixtures are the hub's own answers, from the days when the
/// owner still wrote a duty himself: a duty with a watch and two cases whose records the hub's own sweep then marked.
/// The app only reads a duty now (1.20), and a change of the hub's shape still fails here and not in the owner's
/// window.
struct DutyTests {
    private func list() throws -> DutyList {
        try JSONDecoder().decode(DutyList.self, from: fixture("duties"))
    }

    private func detail() throws -> DutyDetail {
        try JSONDecoder().decode(DutyDetail.self, from: fixture("duty"))
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    @Test func aDutyIsItsWordsAndTheAgentThatHoldsIt() throws {
        let read = try list()
        #expect(read.limits.duties_per_agent == 12 && read.limits.watches_per_duty == 8)
        #expect(read.limits.repeat_days == 30)

        let duty = try #require(read.responsibilities.first)
        #expect(duty.ref == "R-1" && duty.agent == "studio" && duty.isActive)
        // The sentence is the whole duty: it carries what the agent does itself and what it brings to the owner.
        #expect(duty.text.contains("You deploy and write to the customer yourself."))
        #expect(duty.text.contains("Ask me first about a refund"))
        // Its name has no field of its own: the hub takes the first sentence of the words.
        #expect(duty.title == "Keep shop-api answering in production")
        #expect(duty.text.hasPrefix(duty.title))
    }

    @Test func aDutyThatIsNotInOrderSaysSoInTheHubsOwnWords() throws {
        let duty = try #require(try list().responsibilities.first)
        let marker = try #require(duty.marker)
        #expect(!duty.isInOrder)
        #expect(marker.kind == "no_review")
        // The sweep writes the sentence; the app does not invent one over it.
        #expect(marker.says == marker.detail)
        #expect(marker.says.contains("3 days ago"))
        // And for a kind the hub leaves without words, the app has its own short name.
        let bare = DutyMarker(kind: "no_watch", since: 1, detail: nil)
        #expect(bare.says == "Nothing watches for its events")
        #expect(DutyMarker(kind: "watch_broken", since: 1, detail: "  ").says == "A watch has stopped")
    }

    @Test func theOpenCaseCarriesWhatWasRecordedSoFar() throws {
        let duty = try #require(try list().responsibilities.first)
        #expect(duty.open_cases == 1 && duty.cases_30d == 2 && duty.repeats_30d == 0)
        let open = try #require(duty.cases.first)
        #expect(open.ref == "R-1/C-1" && open.isOpen && open.first_step != nil)
        #expect(open.steps.map(\.key) == ["what broke", "the fix", "released"])
        #expect(open.source == "check" && !open.repeated)
    }

    @Test func aCaseIsTheRecordsTheAgentWroteInItsOwnWords() throws {
        let read = try detail()
        let open = try #require(read.open.first)
        // No catalogue and no order of the hub's: the labels are the agent's, in the order it recorded them.
        #expect(open.steps.map(\.key) == ["what broke", "the fix", "released"])
        #expect(open.steps[0].text.contains("502 from 09:12"))
        #expect(open.steps[1].text.contains("a4f19c2"))
        #expect(open.record("the fix")?.text.contains("a4f19c2") == true)
        #expect(open.record("told the customer") == nil)     // not recorded, and nothing says it is owed
    }

    @Test func aClosedCaseKeepsEveryRecordItHad() throws {
        let read = try detail()
        let done = try #require(read.closed.first)
        #expect(done.ref == "R-1/C-2" && done.outcome == "handled")
        #expect(done.steps.count == 7)
        // A step this event did not need is an ordinary record that says so, not a gap in a form.
        #expect(done.record("told the customer")?.text.contains("no request failed") == true)
    }

    @Test func theWatchSaysWhetherAnythingIsLookingForEvents() throws {
        let duty = try #require(try list().responsibilities.first)
        let watch = try #require(duty.watch.first)
        #expect(!duty.hasNoWatch)
        #expect(watch.kind == "clock" && watch.words == "A schedule")
        #expect(watch.state == "active" && watch.isRunning)
        #expect(watch.next_due != nil && watch.failures == 0)
        // The hub's other rule states are not watching for anything.
        for stopped in ["paused", "done", "deleted"] {
            let off = DutyWatch(trigger: 1, kind: "check", state: stopped, paused_by: "owner", paused_reason: nil,
                                needs: nil, next_due: nil, failures: nil, check: nil, last_run: nil)
            #expect(!off.isRunning, "\(stopped) was read as running")
        }
    }

    /// A duty whose watches are checks: one of the value form that has run, and one that prints lines (plan P4). The
    /// fixture is the hub's own answer to `GET /ui/responsibilities` (fleet `45ae948`, its scratch hub of
    /// `app_decode.py` with such a duty). The hub sends a value-form condition as its object and a run's value as a
    /// number, and the app read both as text, so any such duty emptied the whole Duties card.
    @Test func aDutyWatchedByChecksReadsWithTheirConditionAndTheValueOfTheirRun() throws {
        let read = try JSONDecoder().decode(DutyList.self, from: fixture("duties-check-watch"))
        try read.validate(database: "decode-check")
        let duty = try #require(read.responsibilities.first)
        #expect(duty.watch.map(\.kind) == ["check", "check"] && duty.watch.allSatisfy(\.isRunning))
        let value = try #require(duty.watch.first)
        #expect(value.words == "A check" && value.check?.path == "checks/queue.py")
        #expect(value.check?.condition == TriggerCheck.Condition(op: ">", value: 0))
        #expect(value.last_run?.value == 7 && value.last_run?.state == "quiet")
        let lines = try #require(duty.watch.last)
        #expect(lines.check?.condition == nil && lines.check?.path == nil && lines.last_run == nil)
    }

    /// A duty read back carries the hand that wrote it, which is what the screen says: the manager that wrote it,
    /// or the owner for one of the duties he made himself before the form went (UI-API.md 1.20).
    @Test func aDutyCarriesWhoWroteIt() throws {
        let duty = try #require(try list().responsibilities.first)
        #expect(duty.created_by == "owner" && duty.writer == "you")
        #expect(duty.agent == "studio" && !duty.text.isEmpty)
    }

    @Test func whatIsNotInOrderComesFirstAndRetiredComesLast() {
        func duty(_ id: Int, state: String, marker: String?) -> Duty {
            Duty(id: id, agent: "studio", title: "t", text: "t", state: state, revision: 1, created: nil,
                 updated: nil, created_by: nil, watch: [],
                 open_cases: 0, cases_30d: 0, repeats_30d: 0, last_case: nil, cases: [],
                 marker: marker.map { DutyMarker(kind: $0, since: 1, detail: nil) })
        }
        let read = DutyList(db: "d", limits: DutyList.Limits(duties_per_agent: 12, watches_per_duty: 8,
                                                            repeat_days: 30),
                            responsibilities: [duty(1, state: "active", marker: nil),
                                               duty(2, state: "retired", marker: nil),
                                               duty(3, state: "active", marker: "no_watch"),
                                               duty(4, state: "paused", marker: nil)])
        #expect(read.ordered.map(\.id) == [3, 1, 4, 2])
        #expect(read.notInOrder.map(\.id) == [3])
        #expect(read.of("studio").count == 4 && read.of("vps").isEmpty)
    }
}
