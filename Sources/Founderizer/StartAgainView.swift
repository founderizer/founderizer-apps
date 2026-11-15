import FleetCore
import SwiftUI

/// **"Start again", as one page of the manager's server pages holds it** (`AddServerView`, its page `again`; the
/// owner's "Yes, build it" of 15 November 2026 to the four pictures in
/// `~/dev/founderizer-plans/start-again-pictures/`). The rules are `StartAgain`'s: this model reads what the page
/// shows, runs the steps, and gives each call only what the rules hand it.
///
/// **Nothing of a run is kept.** A page that closes ends its run (`close`), and the page reads again when it opens,
/// so what is gone by then is no longer listed. It asks the hub nothing: the reads are this Mac's own records, the
/// providers whose token this Mac holds, and the private network with the fleet's key.
@MainActor @Observable
final class StartAgainModel {
    /// What a run takes away, once the page has read it.
    private(set) var plan: StartAgain.Plan?
    private(set) var steps: [StartAgain.Step] = []
    /// The page reads what it shows: the title's words move, and nothing else is there.
    private(set) var reading = false
    /// The owner pressed "Delete and start again": the page shows the steps from then on.
    private(set) var started = false
    private(set) var running = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var opened = 0

    /// The step that failed, while the run stands at it.
    var failed: StartAgain.Step? { running ? nil : steps.first { $0.state == .failed } }

    /// The page opens: it reads this hub's records, the providers and the private network.
    func open(hub: URL) {
        close()
        opened += 1
        let mine = opened
        reading = true
        work = Task { [weak self] in
            let plan = await Self.read(hub: hub)
            guard let self, self.opened == mine, !Task.isCancelled else { return }
            self.plan = plan
            self.steps = plan.steps
            self.reading = false
            self.work = nil
        }
    }

    /// The page closes, by Back, by × or with the window: a run that goes starts no further step.
    func close() {
        opened += 1
        work?.cancel(); work = nil
        plan = nil; steps = []; reading = false; started = false; running = false
    }

    /// "Delete and start again", and "Try again", which goes on at the step that failed. Never while an install or a
    /// build of a server runs.
    func run(store: FleetStore) {
        guard !running, !reading, let plan, plan.hub == store.hub, !store.installModel().running, !AddServerView.builds,
              !store.sending else { return }
        started = true; running = true
        let from = steps, builds = plan.builds, rivals = plan.rivals, mine = opened
        // The app's own step runs only for the page that started it, and only for the hub that the page read.
        let work = Self.work(store: store, hub: plan.hub) { [weak self] in self?.opened == mine }
        self.work = Task { [weak self] in
            let ended = await StartAgain.run(from, builds: builds, rivals: rivals, work: work) { steps in
                await MainActor.run { if let self, self.opened == mine { self.steps = steps } }
            }
            guard let self, self.opened == mine else { return }
            self.steps = ended
            self.running = false
            self.work = nil
        }
    }

    /// **What the page shows, from this Mac's own records and from what the providers and the private network say
    /// now.** Only the providers that can hold a server of this hub are read: each that a build's record of this hub
    /// names, and, for a made server that no such record names, each whose token this Mac holds. A provider or a
    /// network that cannot be read leaves the rows that the records give. **A server that its provider's list does
    /// not have is gone only when its machine does not run** (`StartAgain.isAlive`): a list is one token's list.
    nonisolated private static func read(hub: URL) async -> StartAgain.Plan {
        let builds = BuildRecords.shared.all(), made = MadeServers.kept(hub: hub)
        let mine = builds.filter { $0.hub == hub.absoluteString && $0.serverID != nil }
        let built = Set(mine.compactMap(\.serverID))
        let loose = made.values.contains { !$0.isEmpty && !built.contains($0) }
        let providers = CloudProvider.allCases.filter { provider in
            (loose || mine.contains { $0.provider == provider }) && CloudServers(provider: provider).isHeld
        }
        var listed: [CloudProvider: [CloudExisting]] = [:]
        await withTaskGroup(of: (CloudProvider, [CloudExisting]?).self) { group in
            for provider in providers {
                group.addTask { (provider, try? await CloudServers(provider: provider).servers()) }
            }
            for await (provider, servers) in group { if let servers { listed[provider] = servers } }
        }
        // The private network, only when a build of this hub can have a machine in it.
        guard !mine.isEmpty else {
            return StartAgain.Plan(hub: hub, proven: StartAgain.proven(hub: hub, made: made, builds: builds, listed: listed),
                                   devices: [])
        }
        let devices = try? await TailscaleFleetKey().devices()
        let status = await MacNetwork.status()
        let own = thisMac(status), online = StartAgain.onlineAddresses(in: status)
        let rivals = StartAgain.rivals(hub: hub, builds: builds)
        let proven = StartAgain.proven(hub: hub, made: made, builds: builds, listed: listed) { build in
            // A server whose deletion a provider took from this app in this start is gone, whatever Tailscale still
            // shows of its machine. With no read of the private network nothing says that the machine is off: the
            // server stays a row, and its step asks the provider.
            guard !deletedHere.holds("\(build.provider.rawValue)|\(build.serverID ?? "")") else { return false }
            guard let devices else { return true }
            return StartAgain.isAlive(build, devices: devices, online: online, thisMac: own.addresses, thisMacName: own.name,
                                      rivals: rivals)
        }
        return StartAgain.Plan(hub: hub, proven: proven, devices: devices, thisMac: own.addresses, thisMacName: own.name)
    }

    /// This Mac's own addresses on the private network and its own name there, out of its Tailscale's status, so that
    /// it is never a device that a run removes. With no answer of this Mac's Tailscale, its name is the Mac's own.
    nonisolated private static func thisMac(_ status: String?) -> (addresses: Set<String>, name: String?) {
        (StartAgain.ownAddresses(in: status), status.flatMap(FleetOnTailscale.ownName(in:)) ?? AppSSHKey.macName())
    }

    /// The calls of a run: each deletes one thing by the provider's or the network's own id of it. `open`: the page
    /// that started the run still shows; the app forgets the fleet only then, and only the hub that the page read.
    nonisolated private static func work(store: FleetStore, hub: URL,
                                         open: @escaping @MainActor @Sendable () -> Bool) -> StartAgain.Work {
        StartAgain.Work(
            deleteServer: { server, accepted in
                try await CloudServers(provider: server.provider).deleteServer(id: server.serverID, accepted: accepted)
            },
            deleteFirewalls: { provider, name, deleted in
                try await CloudServers(provider: provider).deleteFirewalls(ofServer: name, deleted: deleted)
            },
            deleteKey: { provider in
                // The key that this Mac has: none is made to be deleted, and with none there is nothing to find.
                guard let key = AppSSHKey.publicLine() else { return }
                try await CloudServers(provider: provider).deleteKey(publicKey: key)
            },
            devices: { try await TailscaleFleetKey().devices() },
            deleteDevice: { try await TailscaleFleetKey().deleteDevice(id: $0) },
            thisMac: { thisMac(await MacNetwork.status()) },
            online: { StartAgain.onlineAddresses(in: await MacNetwork.status()) },
            noteDeleted: { provider, id in deletedHere.add("\(provider.rawValue)|\(id)") },
            forgetDeleted: { provider, id in deletedHere.remove("\(provider.rawValue)|\(id)") },
            deletedBefore: { provider, id in deletedHere.holds("\(provider.rawValue)|\(id)") },
            clearApp: { deleted in await MainActor.run { if open() { store.forgetFleet(hub, hubServerDeleted: deleted) } } })
    }
}

/// The deletions that a provider took from this app since its start, behind a lock: the run's calls ask from any thread.
private final class TakenDeletions: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()
    func add(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    func remove(_ id: String) { lock.withLock { _ = ids.remove(id) } }
    func holds(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
}

/// **The servers whose deletion a provider took from this app, in this start of the app**, by provider and id.
/// Tailscale shows the machine of a deleted server connected for a while longer, and a second ask for that server then
/// answers 404: that is no server of another project. Never kept on the disk.
private let deletedHere = TakenDeletions()

/// What the page "Start again" shows under its title: before the press, each thing that goes and where; from the
/// press on, each step with its state, and "Try again" under a step that failed.
struct StartAgainContent: View {
    let model: StartAgainModel
    let run: () -> Void

    var body: some View {
        if model.started {
            FormSection {
                ForEach(model.steps) { step in
                    FormRow(step.title, symbol: step.symbol, warning: step.says) {
                        Text(StartAgain.Words.word(of: step.state)).font(SetupMetrics.textFont).foregroundStyle(tint(step.state))
                    }
                }
            }
            if model.failed != nil {
                SetupAction {
                    Button("Try again", action: run).buttonStyle(FleetPrimaryButtonStyle()).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("start-again-retry")
                }
            }
        } else if let plan = model.plan, !model.reading {
            ForEach(plan.sections) { section in
                FormSection(section.title) {
                    ForEach(section.rows) { row in
                        FormRow(row.title, symbol: row.symbol, detail: row.detail) { EmptyView() }
                    }
                }
            }
            SetupAction {
                Button(StartAgain.Words.press, action: run).buttonStyle(FleetDangerButtonStyle()).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("start-again-delete")
            }
        }
    }

    private func tint(_ state: StartAgain.Step.State) -> Color {
        switch state {
        case .now: FleetStyle.text
        case .failed: .orange
        case .done, .waiting: FleetStyle.muted
        }
    }
}
