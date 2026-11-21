import Foundation
import Testing
@testable import FleetCore

/// Synthetic values only: references, agents and words of no real fleet.
private let a = SecretsList.Pair(reference: "bws://a", agent: "writer")
private let b = SecretsList.Pair(reference: "bws://b", agent: "writer")
private let c = SecretsList.Pair(reference: "bws://c", agent: "tester")
private struct Refused: Error {}
private let moved = HubError.refusal(HubRefusal(status: 409, hubWords: "team.json changed; read it again", code: "team_changed"))

@MainActor
struct SecretsRunTests {
    /// **The first refusal stops the run, and says which call it was.** The bug: the run goes on past a refusal, so a
    /// Give that the hub refused for one agent goes on giving the rest, and the bar's line names the last call or none.
    @Test func aRefusalStopsTheRest() async {
        var calls: [String] = []
        let run = await SecretsRun.grants(.give, pairs: [a, b, c], sign: { _, _ in }, call: { pair, _ in
            calls.append(pair.reference)
            if pair == b { throw Refused() }
            return nil
        }, progress: { _, _ in })
        #expect(calls == ["bws://a", "bws://b"])
        #expect(run.done == [a] && run.failed?.pair == b && run.failed?.error is Refused)
    }

    /// **A give is signed before its hub step, and a take-back after it**, as one click of the detail does. The bugs: a
    /// give signed after the hub has it (the central vault seals the secret only for what the owner signed), or a
    /// take-back signed before the hub ended it, which a refusal of the hub then leaves signed away. A signature that
    /// fails after a take-back's hub step is the run's refusal too, and stops it.
    @Test func aGiveIsSignedBeforeItsCallAndATakeBackAfter() async {
        var steps: [String] = [], counts: [Int] = [], open: [Set<String>] = []
        let give = await SecretsRun.grants(.give, pairs: [a, c], sign: { pair, level in
            steps.append("sign \(pair.reference) \(level?.rawValue ?? "none")")
        }, call: { pair, level in
            steps.append("call \(pair.reference) \(level?.rawValue ?? "none")")
            return pair == c ? "Tester has it, but it has no vault access yet" : nil
        }, progress: { done, still in counts.append(done); open.append(still) })
        #expect(steps == ["sign bws://a use", "call bws://a use", "sign bws://c use", "call bws://c use"])
        #expect(give.done == [a, c] && give.failed == nil && give.warning == "Tester has it, but it has no vault access yet")
        #expect(counts == [0, 1] && open == [["bws://a", "bws://c"], ["bws://c"]])
        steps = []
        let take = await SecretsRun.grants(.take, pairs: [a, b], sign: { pair, level in
            steps.append("sign \(pair.reference) \(level?.rawValue ?? "none")")
            if pair == a { throw Refused() }
        }, call: { pair, level in
            steps.append("call \(pair.reference) \(level?.rawValue ?? "none")")
            return nil
        }, progress: { _, _ in })
        #expect(steps == ["call bws://a none", "sign bws://a none"])
        #expect(take.done.isEmpty && take.failed?.pair == a)
    }

    /// **After team.json moved (409 `team_changed`), a removal goes once more only while nobody holds the secret**, on
    /// the version read then, and each next removal on the version that the one before left. The bugs: a removal that
    /// goes again for a secret that an agent got meanwhile; one that goes again on the old version; or a Delete that
    /// stops at the first move of an agent's tool. Any other refusal stops it with no second try.
    @Test func aRemovalGoesAgainAfterAMoveOnlyWhileNobodyHoldsIt() async {
        var sent: [String] = [], reread: [String] = []
        let run = await SecretsRun.removals(["bws://a", "bws://b", "bws://c"], sha256: "v0", remove: { reference, version in
            sent.append("\(reference) \(version)")
            if version == "v0" || (reference == "bws://b" && version == "v2") { throw moved }
            return reference == "bws://a" ? "v2" : "v4"
        }, reread: { reference in
            reread.append(reference)
            return reference == "bws://a" ? ("v1", false) : ("v3", true)
        }, progress: { _, _ in })
        #expect(sent == ["bws://a v0", "bws://a v1", "bws://b v2"])
        #expect(reread == ["bws://a", "bws://b"])
        #expect(run.gone == ["bws://a"] && run.failed?.reference == "bws://b")
        reread = []
        let refused = await SecretsRun.removals(["bws://a"], sha256: "v0", remove: { _, _ in throw Refused() },
                                                reread: { reference in reread.append(reference); return ("v1", false) },
                                                progress: { _, _ in })
        #expect(refused.gone.isEmpty && refused.failed?.error is Refused && reread.isEmpty)
    }

    /// **After a save, the note's field shows the note of the new reading; after a move, the note that changed there.**
    /// The bugs: the field keeps his typed words while the hub kept them made plain, so each time he leaves the field
    /// they go again; or, when an agent changed the note meanwhile, the field shows the old note and the next blur
    /// sends it as his own words.
    @Test func theNoteFieldShowsTheNoteThatTheHubKeeps() async {
        var sends = 0
        var outcome = await SecretsRun.note("Refund admin [shop]", base: "", send: { sends += 1 },
                                            reread: { .note("Refund admin (shop)") }, reason: { _ in "refused" })
        #expect(outcome == .saved("Refund admin (shop)") && sends == 1)
        // An agent changed it while his words were on their way: they do not go again.
        sends = 0
        outcome = await SecretsRun.note("Mine", base: "Old", send: { sends += 1; if sends == 1 { throw moved } },
                                        reread: { .note("An agent's note") }, reason: { _ in "refused" })
        #expect(outcome == .changedElsewhere("An agent's note") && sends == 1)
        // Something else moved team.json: the same words go once more.
        sends = 0
        outcome = await SecretsRun.note("Mine", base: "Old", send: { sends += 1; if sends == 1 { throw moved } },
                                        reread: { .note(sends == 1 ? "Old" : "Mine") }, reason: { _ in "refused" })
        #expect(outcome == .saved("Mine") && sends == 2)
        outcome = await SecretsRun.note("Mine", base: "Old", send: { throw moved }, reread: { .gone }, reason: { _ in "refused" })
        #expect(outcome == .gone)
        outcome = await SecretsRun.note("Mine", base: "Old", send: { throw Refused() }, reread: { .note("Old") }, reason: { _ in "refused" })
        #expect(outcome == .failed("refused"))
    }

    /// **A read that fails after a save leaves his words in the field, and one that fails after a move saves
    /// nothing.** The bug: the failed read gives the note of the reading before, so the field shows the old note with
    /// "Saved" after the hub took his words, and the next blur sends that old note as his; or a failed read after a
    /// move counts as "nothing changed" and sends his words over an agent's new note.
    @Test func aFailedReadNeverPutsAnOlderNoteInTheField() async {
        var sends = 0
        var outcome = await SecretsRun.note("Mine", base: "Old", send: { sends += 1 }, reread: { .unread }, reason: { _ in "refused" })
        #expect(outcome == .saved("Mine") && sends == 1)
        sends = 0
        outcome = await SecretsRun.note("Mine", base: "Old", send: { sends += 1; throw moved }, reread: { .unread },
                                        reason: { _ in "moved" })
        #expect(outcome == .failed("moved") && sends == 1)
    }
}
