import FleetCore
import SwiftUI

/// The checks of one machine as a list (PRODUCT.md 4.1): the state, the one line the check says, and the fix when
/// there is one. `READY` when nothing failed.
///
/// A check that does not apply to this machine is absent from the answer, so it is absent from this list too: a
/// missing check is never shown as a pass.
struct VerifyChecklistView: View {
    let checklist: VerifyChecklist
    /// What the rows are about, for the footer: "this machine", or the machine's name.
    var subject: String = String(l10n: "this server")
    var footer: String?

    var body: some View {
        FormSection(header, detail: checklist.summary, footer: footer) {
            if checklist.checks.isEmpty {
                FormEmpty("No check has answered for \(subject) yet.", symbol: "checklist")
            }
            ForEach(checklist.checks) { check in
                FormRow(check.title, symbol: check.symbol, detail: check.says,
                        warning: check.passed ? nil : check.fix) {
                    Text(word(check)).font(FormMetrics.detail).foregroundStyle(tint(check))
                }.accessibilityIdentifier("verify-\(check.check)")
            }
        } accessory: {
            Text(state).font(FormMetrics.detail)
                .foregroundStyle(checklist.isReady ? Color.green : .orange)
                .accessibilityIdentifier("verify-line")
        }
    }

    /// **Its state in his words** (fix round 3, item 49): the installers' last line names each check by its id ("NOT
    /// READY: runtime_signed_in"), which is not his; the rows under it name the checks by their titles.
    private var state: String {
        checklist.checks.isEmpty ? String(l10n: "Not checked") : checklist.isReady ? String(l10n: "Ready") : String(l10n: "Not ready")
    }

    private var header: String {
        guard let at = checklist.readAt else { return String(l10n: "Checks") }
        return String(l10n: "Checks · \(fleetDate(at))")
    }

    private func word(_ check: VerifyCheck) -> String {
        check.failed ? String(l10n: "Failed") : check.warned ? String(l10n: "Warning") : String(l10n: "Ready")
    }

    private func tint(_ check: VerifyCheck) -> Color {
        check.failed ? .orange : check.warned ? .yellow : FleetStyle.muted
    }
}
