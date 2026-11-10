import FleetCore
import SwiftUI

// The short words of a wake-up rule, which an agent's duties draw. A task's mark and its words are FleetCore's
// (`FleetTask.mark`, beside `TaskWords`), so both apps and every screen take them from one order (review B5). The
// Agents table that stood in this file went with the owner's map of 28 October 2026 (D-4): the sidebar is the one list
// of the agents, and each agent's account and usage are in its chat's panel and on Servers.

extension FleetTask.MarkTint {
    /// **A task mark's colour on the Mac** (`FleetTask.tint`; fix round 3, item 21): the green of work, the board's green
    /// of a checked result and its red of one that failed, orange for what needs someone, and muted for the rest.
    var color: Color {
        switch self {
        case .work: AgentPresence.working.color
        case .checked: .green
        case .failed: .red
        case .attention: .orange
        case .quiet: FleetStyle.muted
        }
    }
}

extension FleetTrigger {
    /// A rule that runs again and again. A rule that runs once is a reminder.
    var repeats: Bool { schedule.kind != "once" }
    /// The schedule in few words, for a row or a hover text.
    var shortSchedule: String {
        switch schedule.kind {
        case "once": "Once \(schedule.at?.replacingOccurrences(of: "T", with: " ") ?? "")"
        case "every": "Every \(schedule.minutes ?? 0) min"
        case "monthly": "Day \(schedule.day ?? 1) · \(schedule.time ?? "")"
        default: "\(schedule.days?.map(\.capitalized).joined(separator: ", ") ?? "Daily") · \(schedule.time ?? "")"
        }
    }
}
