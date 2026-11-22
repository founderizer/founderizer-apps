import FleetCore
import SwiftUI

/// **The first run's page "Help improve Founderizer"**, the page after the welcome page and before "Name your manager"
/// (the owner, 18 November 2026: "durng the very first onboarding, one of the first steps should be asking if they wnat
/// to share diagnosis data to improve the product. then they can change the setting again under logs", and "Yes, build
/// it" to its picture, with Settings › Help as the place to change it). It is the switch of Settings › Help › Help
/// improve Founderizer as one question: the switch's own symbol as the mark, its own line under the title, two cards of
/// one weight, and one line under them that says where to change it, with the privacy page. No card carries the check
/// mark before the first answer on this Mac. A press on a card is the way on.
struct FirstRunReportsPage: View {
    /// The card with the check mark: true for "Send anonymous usage data", false for "Don't send", nil for none.
    let marked: Bool?
    let choose: (Bool) -> Void

    /// **The row of the two cards is wider than the setup's 540 pt, so that each card's words stand on one line**
    /// (the owner, 20 November 2026: "not 'Error reports' say 'Annonymous usage data' / on the mac too", then his pick
    /// "Widen, one line"): a card is 343 pt, and its words have 223 pt beside its symbol and its check, where "Send
    /// anonymous usage data" takes 202 pt and "Enviar datos de uso anónimos" 209 pt at 15 pt medium.
    static let rowWidth: CGFloat = 700

    var body: some View {
        SetupStep(title: String(l10n: "Help improve Founderizer"), width: Self.rowWidth,
                  detail: String(l10n: "Sends error codes, versions and counts to Founderizer. Never your work, names or keys.")) {
            IconTile(symbol: "ladybug", size: SetupMetrics.mark).accessibilityHidden(true)
        } content: {
            HStack(alignment: .top, spacing: 14) {
                card(String(l10n: "Send anonymous usage data"), symbol: "paperplane", send: true)
                card(String(l10n: "Don't send"), symbol: "xmark", send: false)
            }
            // Both cards at the height of the taller one, where a language wraps one of them.
            .fixedSize(horizontal: false, vertical: true)
            Text(FormLink(String(l10n: "Privacy"), url: ErrorReport.privacyPage)
                .line(after: String(l10n: "You can change this later in Settings › Help.")))
                .foregroundStyle(FleetStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One card, as the cards of the manager's AI provider are drawn (`ProviderCard`): its symbol, its words, and the
    /// check mark on the one that he chose last.
    private func card(_ title: String, symbol: String, send: Bool) -> some View {
        Button { choose(send) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(IconMetrics.symbol(20, weight: .light)).foregroundStyle(FleetStyle.text)
                    .frame(width: 28).accessibilityHidden(true)
                Text(title).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if marked == send {
                    Image(systemName: "checkmark").font(IconMetrics.symbol(12, weight: .semibold)).foregroundStyle(FleetStyle.muted)
                        .accessibilityLabel("Now")
                }
            }
            .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .accessibilityIdentifier(send ? "first-run-reports-send" : "first-run-reports-none")
    }
}

/// **The answer of the first run's page to the hub, with nothing on a page** (`FirstRunReports`): once the hub answers
/// this Mac as its owner and offers the switch, the answer that waits goes to it as a press on Settings › Help's switch
/// goes, and the switch's reading is read again for that page. A call that did not bring the answer to the hub is tried
/// again a minute later. The store's own tick runs it. **Not while the first run holds the window** (the review of 18
/// November 2026): a restore of a copy in Settings › Backup, which opens while the setup fills the window too, puts
/// back a whole hub, the switch too, and would undo an answer that went before it.
@MainActor enum FirstRunReportsSender {
    private static var working = false
    private static var notBefore: Date?

    static func tick(store: FleetStore) {
        guard !working, FirstRunReports.waiting() != nil, notBefore.map({ Date() >= $0 }) ?? true, store.isFresh,
              store.canWrite, !store.firstRunHolds, let database = store.state?.db,
              store.state?.ui_features?.contains(ErrorReportsState.feature) == true else { return }
        let hub = store.hub, client = store.installation
        working = true
        Task {
            var tookSend = false
            let took = await FirstRunReports.deliver(offered: true) { send in
                let receipt = try await HubClient().errorReports(send, hub: hub, database: database, client: client)
                tookSend = send && receipt.send != false
            }
            working = false
            notBefore = took ? nil : Date().addingTimeInterval(60)
            // The hub took his "Send", and no newer press waits: his error reports start at that press, so the stops of
            // the first run after it go (`ErrorReportsDay.pressedOn`).
            if took, tookSend, FirstRunReports.waiting() == nil, store.hub == hub, let press = FirstRunReports.pressed() {
                ErrorReportsDay.pressedOn(hub: hub.absoluteString, at: press)
            }
            if took, store.hub == hub { await ErrorReportsModel.of(store).read(store: store) }
        }
    }
}
