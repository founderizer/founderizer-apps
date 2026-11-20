import FleetCore
import SwiftUI

extension FleetAgent {
    var roleTitle: String { role == "manager" ? "Manager" : role == "lead" ? "Lead" : "Worker" }
    /// The one line under the agent's name: its role and its provider. While its helper has not loaded a new provider,
    /// the line says that it is switching, not that the new one runs.
    func summary(switching: Bool) -> String { "\(roleTitle) · \(switching ? "Switching to " : "")\(providerName(runtime))" }
}

extension AgentAttention {
    /// The status of an agent row with this problem.
    var short: String {
        switch self {
        case .staleReading: String(l10n: "Old reading")
        case .signIn: String(l10n: "Sign-in needed")
        case .updateFailed: String(l10n: "Update failed")
        case .checkFailed: String(l10n: "Check failed")
        case .restart: String(l10n: "Restart needed")
        }
    }
}
