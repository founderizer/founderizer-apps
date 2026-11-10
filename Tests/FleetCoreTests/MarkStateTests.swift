import Foundation
import Testing
@testable import FleetCore

/// A row answers with a mark, and the sentence it used to print lives behind that mark.
///
/// The owner, 20 October 2026: "not even sentences, just a check or a cross, and on hover probably show the
/// detail? This applies to all menus, it needs to be simpler!"
struct MarkStateTests {
    @Test func everyStateHasItsOwnShapeAndColourIsNeverTheOnlyCue() {
        let shapes = Set(MarkState.allCases.map(\.symbol))
        #expect(shapes.count == MarkState.allCases.count)
        #expect(MarkState.good.symbol == "checkmark.circle.fill")
        #expect(MarkState.bad.symbol == "xmark.circle.fill")
    }

    @Test func onlyWhatIsWrongAsksForHisAttention() {
        #expect(MarkState.bad.attention && MarkState.warn.attention)
        #expect(!MarkState.good.attention && !MarkState.unknown.attention && !MarkState.working.attention)
    }

    /// A missing or unreadable answer is never drawn as a pass — the first thing PRODUCT.md 4.1 asks a reader of
    /// these to get right.
    @Test func oneCloserLookAnswerBecomesOneMarkAndNothingElseIsAPass() {
        #expect(MarkState.of(VerifyCheck(check: "firewall", state: "ok", says: "ufw is active")) == .good)
        #expect(MarkState.of(VerifyCheck(check: "clock", state: "warn", says: "drifted", fix: "t")) == .warn)
        #expect(MarkState.of(VerifyCheck(check: "services", state: "fail", says: "stopped", fix: "s")) == .bad)
        #expect(MarkState.of(VerifyCheck(check: "disk", state: "nonsense", says: "?")) == .unknown)
    }
}
