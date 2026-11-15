import FleetCore
import SwiftUI

/// **Update, over Settings** (the owner, 14 November 2026: "the app should show an update banner above Settings when
/// there is an update available"; his yes to its picture, and "no need to show the version to update too"; and 15
/// November 2026: "if I had an update available I wanted to see a button above the settings one, where I can click, I
/// see a small confirmation modal to update, and be able to do it from there ... This applies to the fleet and to the
/// app").
///
/// The main sidebar's one white row: the colour of a page's one main button (`FleetPrimaryButtonStyle`) in the shape and
/// height of a sidebar row, so it stands out on the rail without a second style. It stands while a release of the fleet
/// or a build of this Mac waits for his press (`FleetStore.updateShows`), and while his press goes on. **A click opens the
/// window that asks** (`UpdateDialog`): until 15 November 2026 one press put this Mac's build in place and started the
/// app again at once, with no question, and a release of the fleet alone opened Settings › Updates, which is gone.
/// While his press goes on it says the download and then Restarting…, or Updating… while the fleet's run goes on, and a
/// second click does nothing; a press that stopped says Try again, with the reason under the pointer (`UpdateAsk.banner`).
struct UpdateBanner: View {
    @Bindable var store: FleetStore
    let press: () -> Void

    var body: some View {
        let fleet = UpdatesModel.of(store)
        let fleetWords = store.fleetUpdateWords
        let working = store.updates.pressed != nil || fleetWords != nil
        let failure = store.updates.pressFailure ?? fleet.error
        Button {
            if !working { press() }
        } label: {
            HStack(spacing: 0) {
                RowMark { Image(systemName: "arrow.down.circle").font(IconMetrics.symbol(14)).accessibilityHidden(true) }
                // Its digits keep one width, so the line does not shake as the download counts up (`UI-PATTERNS.md`,
                // "A wait that knows its count").
                Text(UpdateAsk.banner(app: store.updates.pressed, fleet: fleetWords, failed: failure != nil))
                    .lineLimit(1).monospacedDigit()
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(BannerStyle(working: working))
        .help(failure ?? "")
        .accessibilityIdentifier("update-banner")
        // While the fleet's run that a press started goes on, its state is read every 3 seconds, so that the words end
        // with the run. A press that waits for running work reads by itself (`UpdatesModel.update`).
        .task(id: fleetWords != nil && !fleet.queued) {
            guard fleetWords != nil, !fleet.queued else { return }
            while !Task.isCancelled {
                do { try await store.nap(3) } catch { return }
                await fleet.read(store: store)
            }
        }
    }

    /// White as the main button: lighter under the pointer, darker while pressed, and still while the update runs.
    private struct BannerStyle: ButtonStyle {
        let working: Bool

        func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, working: working) }

        private struct Face: View {
            let configuration: ButtonStyleConfiguration
            let working: Bool
            @State private var hovered = false

            var body: some View {
                let opacity = working ? 0.94 : configuration.isPressed ? 0.78 : hovered ? 1 : 0.94
                configuration.label
                    .font(FormMetrics.button(13)).foregroundStyle(Color.black.opacity(0.92))
                    .padding(.horizontal, 10).frame(minHeight: 32)
                    .background(RoundedRectangle(cornerRadius: FormMetrics.inner).fill(Color.white.opacity(opacity)))
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 }
            }
        }
    }
}
