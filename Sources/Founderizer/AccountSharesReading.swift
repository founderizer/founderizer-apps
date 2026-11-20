import FleetCore
import SwiftUI

extension FleetStore {
    /// **Each agent's part of its account's week** (`AccountShares`), which the Agents page and the Servers table draw
    /// in their bars, only while two agents of the team share an account (else no bar shows a part): read when such a
    /// page opens and then every 10 minutes, apart from the machines, and kept as the reading "accountShares". `GET
    /// /ui/costs` builds the whole fleet's report of costs under the hub's lock, whatever period it is asked for, and the
    /// parts of a week move slowly. A read that failed keeps the last parts, and the next try is a minute later. **It
    /// waits on a clock of its own** (`Task.sleep`), never on the store's nap, which every change of the hub ends: on a
    /// busy fleet that read the report every two seconds (the review of 19 November 2026). One function for both pages
    /// (20 November 2026), so that one agent's bars are the same on each, and **one reading for both**: a page that
    /// opens while the reading that a page kept is younger than 10 minutes waits out the rest of them first, so that a
    /// walk from Agents to Servers and back builds the report once (the review of the Servers table, 20 November 2026).
    func keepAccountShares() async {
        let clock = ContinuousClock()
        if let kept = readingKept("accountShares"), kept + .seconds(600) > clock.now {
            do { try await clock.sleep(until: kept + .seconds(600)) } catch { return }
        }
        while !Task.isCancelled {
            let time = state?.time ?? 0
            let shared = UsageBar.bars(for: state?.agents ?? [], time: time, isFresh: isFresh).values
                .contains { !$0.sharedWith.isEmpty }
            var read = false
            if shared, state?.ui_features?.contains("costs") == true, isFresh, let database = state?.db {
                let hub = self.hub
                let answer = try? await HubClient().accountShares(hub: hub, database: database, at: time)
                guard !Task.isCancelled else { return }
                if self.hub == hub, state?.db == database, let answer { keep(answer, as: "accountShares"); read = true }
            }
            do { try await clock.sleep(for: .seconds(read ? 600 : 60)) } catch { return }
        }
    }

    /// The parts of the accounts' weeks as a page read them last, for this generation of the hub only.
    var accountShares: AccountShares? {
        let kept: AccountShares? = reading("accountShares")
        return kept.flatMap { $0.db == state?.db ? $0 : nil }
    }
}
