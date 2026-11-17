import FleetCore
import SwiftUI

/// **One card of an agent's AI provider**: the provider's own icon and name, and a check mark on the one that is chosen
/// now. A press on it is the way on. The manager's own setup (`AgentSetupWizard`) and the first run's page of the
/// manager's AI provider (`ManagerAIPage`) draw the same cards.
struct ProviderCard: View {
    /// The provider by the name of its program on a server: `claude` or `codex`.
    let provider: String
    /// It carries the check mark: the provider that the agent has now, or that the owner chose.
    let marked: Bool
    /// **A request of the page is on its way**: a press waits for it. The cards keep their look while the page reads
    /// (T-01): they went grey for 40 ms whenever another page's request was on its way.
    var busy = false
    let id: String
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            HStack(spacing: 12) {
                ProviderIcon(runtime: provider, size: 28)
                Text(providerName(provider)).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text)
                Spacer(minLength: 8)
                if marked {
                    Image(systemName: "checkmark").font(IconMetrics.symbol(12, weight: .semibold)).foregroundStyle(FleetStyle.muted)
                        .accessibilityLabel("Now")
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .disabled(busy)
        .accessibilityIdentifier(id)
    }
}
