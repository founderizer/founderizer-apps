import FleetCore
import SwiftUI

/// What runs on a schedule for one agent, as a group of its Behaviour. An agent sets its own wake-up rules to
/// meet a goal or a duty (`save_trigger`, `change_trigger`), so nothing is written here: the owner reads what is
/// scheduled, one line each. The daily limit stays in the hub and reaches this page only in the line of a run that
/// it refused. A rule that no longer runs — deleted, or a single one that has run — is not a schedule and is gone.
struct TriggersView: View {
    @Bindable var store: FleetStore
    let agent: String
    /// False while the page around it waits for its own first reading: the schedules then come in the same frame as
    /// what stands over them, and never stand under a loading line that the duties replace. It reads them all the same.
    var shows = true
    /// The schedules are the store's (`FleetStore.reading`), one reading of the whole fleet: they show in the first
    /// frame when he comes back, and the read that starts then changes only what changed.
    private var list: TriggerList? {
        get { store.reading("triggers.list") } nonmutating set { store.keep(newValue, as: "triggers.list") }
    }

    /// The schedules, read before the page first opens (`PagePrefetch`).
    static let prefetch = PagePrefetch("triggers.list", feature: "triggers") { try await HubClient().triggers(hub: $0, database: $1) }

    private var rows: [FleetTrigger] {
        guard shows else { return [] }
        return (list?.triggers ?? []).filter { $0.agent == agent && ["active", "paused"].contains($0.state) }
            .sorted { $0.id > $1.id }
    }

    var body: some View {
        // The heading comes with the rules: with none, the section draws nothing at all, and the page says nothing
        // about schedules. **Nor does it leave a gap** (fix round 3b): as an empty view it took the page's 22-pt space
        // between groups, so Memory stood 56 pt under the rules. The page reads the schedules itself (`poll`).
        if !rows.isEmpty {
            FormSection("On a schedule") {
                ForEach(rows) { trigger in
                    FormRow(trigger.task.title, symbol: "clock.arrow.circlepath", detail: when(trigger),
                            warning: trouble(trigger)).accessibilityIdentifier("schedule-\(trigger.id)")
                }
            }
            .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        }
    }

    /// Reads the schedules every 10 seconds while the page that shows them is open, rules or none.
    static func poll(store: FleetStore) async {
        while !Task.isCancelled {
            await refresh(store)
            do { try await store.nap(10) } catch { return }
        }
    }

    /// When the rule runs, when it runs next, and whose rule it is.
    private func when(_ trigger: FleetTrigger) -> String {
        var words = [scheduleSummary(trigger.schedule)]
        if trigger.state == "active", let due = trigger.next_due {
            words.append("next \(scheduleDate(due, timezone: trigger.schedule.timezone))")
        }
        // He is "you" on every screen of the app; an agent is its name.
        words.append(trigger.isAgentRule ? "set by \(trigger.author.agentLabel)" : "set by you")
        return words.joined(separator: " · ")
    }

    /// The one thing that is not right: a rule that is paused, or the hub's own reason for the last run it did not
    /// start — which is where its daily limit appears, and the only place the owner meets it.
    private func trouble(_ trigger: FleetTrigger) -> String? {
        if trigger.state == "paused" { return trigger.paused_reason ?? "Paused" }
        guard let last = trigger.last_run, !last.isCheckMatch,
              !["started", "quiet", "sent"].contains(last.state) else { return nil }
        return last.reason ?? last.state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func refresh(_ store: FleetStore) async {
        guard store.isFresh, let database = store.state?.db else { return }
        let hub = store.hub
        let result = try? await HubClient().triggers(hub: hub, database: database)
        guard !Task.isCancelled, store.hub == hub, store.state?.db == database, let result else { return }
        store.keep(result, as: "triggers.list")
    }
}

private extension TriggerRun {
    var isCheckMatch: Bool { check_now == true && state == "not_started" && value != nil && error == nil }
}

/// **When it runs next, in a few words** (fix round 2): "00:41" today, "tomorrow 00:41", else the day and the time —
/// no year and no zone ("next Thu 29 Oct 2026 00:41 GMT+1"). The rule's own zone decides what today is.
private func scheduleDate(_ timestamp: Double, timezone: String?) -> String {
    let zone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
    var calendar = Calendar.current
    calendar.timeZone = zone
    let date = Date(timeIntervalSince1970: timestamp)
    let formatter = DateFormatter(); formatter.locale = Locale.current; formatter.timeZone = zone
    formatter.dateFormat = "HH:mm"
    let time = formatter.string(from: date)
    if calendar.isDateInToday(date) { return time }
    if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
    formatter.dateFormat = "EEE d MMM HH:mm"
    return formatter.string(from: date)
}

private func scheduleSummary(_ schedule: TriggerSchedule) -> String {
    switch schedule.kind {
    case "once": return "Once · \(schedule.at?.replacingOccurrences(of: "T", with: " ") ?? "") · \(schedule.timezone ?? "")"
    case "every": return "Every \(schedule.minutes ?? 0) minutes"
    case "monthly": return "Day \(schedule.day ?? 1) · \(schedule.time ?? "") · \(schedule.timezone ?? "")"
    default: return "\(schedule.days?.map(\.capitalized).joined(separator: ", ") ?? "Daily") · \(schedule.time ?? "") · \(schedule.timezone ?? "")"
    }
}
