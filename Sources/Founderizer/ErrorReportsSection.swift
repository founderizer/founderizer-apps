import FleetCore
import Observation
import SwiftUI

/// The hub's switch of error reports (`GET` and `POST /ui/error-reports`, owner feature `error_reports`), which
/// Settings › Help › Help improve Founderizer draws. Its write goes as the Automatic updates switch's goes (`UpdatesModel`): an
/// owner command with its request id, the hub's own words for a refusal, and "Try again" for an answer that did not
/// come; then a reading of the switch. **The switch shows only what the hub said** (the screen review of 16 November
/// 2026): its reading, or the hub's receipt of a save, never the value of a press before the hub answered it.
@MainActor @Observable
final class ErrorReportsModel {
    /// The name of the reading in the store (`FleetStore.reading`), which `ErrorReportsSection.prefetch` fills too.
    static let name = "error-reports"
    private(set) var state: ErrorReportsState?
    private(set) var busy = false
    private(set) var error: String?

    init(state: ErrorReportsState? = nil) { self.state = state }

    /// **Reads the switch every 15 seconds while Help shows.** `SettingsPage` runs it, and not the section: the
    /// section draws nothing before a reading, and a view that draws nothing runs no task of its own.
    func poll(store: FleetStore) async {
        while !Task.isCancelled {
            if store.isFresh { await read(store: store) }
            guard !Task.isCancelled else { return }
            do { try await store.nap(15) } catch { return }
        }
    }

    /// The one model of the switch for this hub generation.
    static func of(_ store: FleetStore) -> ErrorReportsModel {
        store.pageModel(name) { ErrorReportsModel(state: store.reading(name)) }
    }

    /// What one visit of Help said goes with it: a refusal's words. The reading stays.
    func left() { if !busy { error = nil } }

    func read(store: FleetStore) async {
        guard let database = store.state?.db else { return }
        let hub = store.hub
        let read = try? await HubClient().errorReports(hub: hub, database: database)
        guard store.hub == hub, store.state?.db == database, let read else { return }
        keep(read, store: store)
    }

    /// `POST /ui/error-reports`: the switch on or off.
    func turn(_ on: Bool, store: FleetStore) async {
        guard !busy, let database = store.state?.db else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let hub = store.hub
            let receipt = try await HubClient().errorReports(on, hub: hub, database: database, client: store.installation)
            // His press in Settings is newer than any answer of a first run, which a retry must never undo.
            FirstRunReports.forget()
            guard store.hub == hub, store.state?.db == database else { return }
            // The hub took it: the switch stands so, also when the reading after it does not answer.
            keep(ErrorReportsState(send: receipt.send ?? on, db: database), store: store)
            await read(store: store)
        } catch let HubError.refusal(refused) { error = refused.words }
        catch { self.error = String(l10n: "The hub has not answered. Try again.") }
    }

    /// A reading of the switch. **Off is also the end of what this Mac kept for the next start** (`ErrorReportsSender`).
    private func keep(_ reading: ErrorReportsState, store: FleetStore) {
        state = reading
        store.keep(reading, as: Self.name)
        if !reading.send { ErrorReportsSender.shared.off() }
    }
}

/// **Settings › Help › Error reports** (the owner's "Yes, as drawn" of 16 November 2026, to
/// `P3-error-reports-switch.png`, as a group of General under Updates; and his "Build A" of the same day, to the picture
/// that moved it to Help, under Report a problem, as Help improve Founderizer), while the hub offers the switch. **Its
/// row stands only with a reading of the hub, and its switch is that reading** (as Updates draws its rows only with
/// one): with no reading there is no row, never a switch that says off while the hub may have it on, and no line that
/// says that it cannot be read.
struct ErrorReportsSection: View {
    @Bindable var store: FleetStore
    private var model: ErrorReportsModel { ErrorReportsModel.of(store) }
    /// The switch, read before Help first opens (`PagePrefetch`), so that it stands as the hub has it in the first frame.
    static let prefetch = PagePrefetch(ErrorReportsModel.name, feature: ErrorReportsState.feature) {
        try await HubClient().errorReports(hub: $0, database: $1)
    }

    var body: some View {
        if let state = model.state {
            ErrorReportsRows(on: state.send, enabled: !model.busy && store.canWrite, warning: model.error) { on in
                Task { await model.turn(on, store: store) }
            }
            .onDisappear { model.left() }
        }
    }
}

/// **The section as drawn**, with no store: one row, its symbol `ladybug`, the title, one detail line that says what
/// goes and to whom and ends in the privacy page, and a small switch that stands as the hub has it. The title says what
/// the switch is for; the detail says what it sends (the owner, 16 November 2026: "it should be something like Help to
/// make Founderizer better, right? more than just the developers?"). A save that was refused or got no answer is the
/// row's warning.
struct ErrorReportsRows: View {
    let on: Bool
    let enabled: Bool
    let warning: String?
    let turn: (Bool) -> Void

    var body: some View {
        FormSection("Anonymous usage data") {
            FormRow("Help improve Founderizer", symbol: "ladybug",
                    detail: String(l10n: "Sends error codes, versions and counts to Founderizer. Never your work, names or keys."),
                    link: FormLink(String(l10n: "Privacy"), url: ErrorReport.privacyPage), warning: warning) {
                Toggle("Help improve Founderizer", isOn: Binding(get: { on }, set: { turn($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!enabled).accessibilityIdentifier("error-reports-send")
            }
        }
    }
}
