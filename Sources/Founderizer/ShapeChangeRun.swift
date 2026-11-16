import Foundation
import FleetCore
import SwiftUI

/// **A change of the fleet's shape, as it runs** (the owner's yes of 15 November 2026, "Yes, build it", to the pictures
/// in `~/dev/founderizer-plans/shape-change-later/`): first each server that the change makes, with Add server's own
/// parts (`FleetCloudModel`, `MachineInstallModel`), then each move, one at a time and the manager last, through the
/// hub's `move_agent`; after each move the agent installs on its new server and waits for the owner's sign-in there,
/// which the page shows as the install's own element (`ServerJobView`). The run is the Mac's and goes on while its page
/// is closed, as a server that Add server makes does: the page finds it again (`current`). A stop says why in one
/// line, and Try again goes on from the step that stopped: a server that was made is installed again and never made a
/// second time, and a move that ended stays.
@MainActor @Observable
final class ShapeChangeRun {
    enum Phase: Equatable {
        /// The n-th server of the change is being made, of how many.
        case making(Int, of: Int)
        /// An agent moves, the n-th move of how many; also while its turn ends, which the hub waits for.
        case moving(String, Int, of: Int)
        /// The agent is on its new server and waits for the owner's sign-in there.
        case signIn(String)
        /// What stopped the change, in one line.
        case stopped(String)
        case done
    }

    /// **The one change of this Mac**, for the hub it runs for: a page that opens again finds it here. Nil while none
    /// runs, after one that ended, and after one that stopped and whose page he closed.
    static var current: ShapeChangeRun?

    let hub: URL
    let plan: ShapeChangePlan
    private(set) var phase: Phase
    /// The install job that waits for the owner, on its server, while the phase is `signIn`: the page draws it.
    private(set) var waitingJob: (job: ServerJob, server: String)?
    /// The servers that the change made, by the plan's box: their name once the provider made them, the place to
    /// install them once they joined the private network, and whether the install ended.
    private var built: [Int: String] = [:]
    private var reached: [Int: InstallTarget] = [:]
    private var installed: Set<Int> = []
    /// The names of the servers in the hub's list, by box, once they joined the fleet.
    private(set) var made: [Int: String] = [:]
    /// The agents whose move ended: on their new server and signed in, or gone from the fleet.
    private(set) var ended: Set<String> = []
    private var work: Task<Void, Never>?
    /// Add server's own parts: one server at a time.
    private let cloud = FleetCloudModel()
    private let install = MachineInstallModel()

    init(hub: URL, plan: ShapeChangePlan) {
        self.hub = hub
        self.plan = plan
        phase = plan.newServers > 0 ? .making(1, of: plan.newServers)
            : .moving(plan.moves.first?.agent ?? "", 1, of: plan.moves.count)
    }

    /// The plan with the names of the servers that the change made so far, for the page's boxes.
    var shown: ShapeChangePlan {
        var plan = plan
        for (index, name) in made { plan.boxes[index].server = name }
        return plan
    }

    /// The agents that are not on their new server yet: drawn faint.
    var later: Set<String> { Set(plan.moves.map(\.agent)).subtracting(ended).subtracting([waiting].compactMap { $0 }) }

    /// The agent that waits for the owner's sign-in, if one does.
    var waiting: String? { if case .signIn(let agent) = phase { agent } else { nil } }

    var stopped: Bool { if case .stopped = phase { true } else { false } }

    /// The press of the page, and Try again after a stop: the run goes on from where it is.
    func start(store: FleetStore) {
        guard work == nil, phase != .done else { return }
        work = Task { [weak self] in
            await self?.run(store: store)
            self?.work = nil
        }
    }

    /// A stop whose line the owner reads, in the change's own words.
    private struct Stop: LocalizedError {
        let words: String
        var errorDescription: String? { words }
    }

    private func run(store: FleetStore) async {
        do {
            let news = plan.boxes.indices.filter { plan.boxes[$0].server == nil && !plan.boxes[$0].hub }
            for index in news where made[index] == nil {
                phase = .making(made.count + 1, of: news.count)
                made[index] = try await makeServer(index, store: store)
            }
            for (number, move) in plan.moves.enumerated() where !ended.contains(move.agent) {
                guard let server = plan.boxes[move.box].server ?? made[move.box] else {
                    throw Stop(words: String(l10n: "The server for \(move.agent.agentLabel) is not there. Try again."))
                }
                phase = .moving(move.agent, number + 1, of: plan.moves.count)
                guard let job = try await moveAgent(move.agent, to: server, store: store) else {
                    ended.insert(move.agent)            // gone from the fleet, or there already with nothing open
                    continue
                }
                try await waitInstalled(move.agent, job: job, on: server, store: store)
                ended.insert(move.agent)
            }
            // The hub keeps the step, and takes the word `shared` away from its own server once no agent runs there.
            await ShapeFleet.keep(plan.step, store: store)
            phase = .done
            Self.current = nil
            await store.refresh()
        } catch is CancellationError {
        } catch {
            waitingJob = nil
            phase = .stopped((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: A server that the change makes

    /// **One new server, as Add server makes it**: the provider whose token this Mac holds, its offer, the build, the
    /// install with a join code, and its name in the hub's list once it joined. Each part that ended is kept: Try again
    /// installs a server that was made again, and makes none twice.
    private func makeServer(_ index: Int, store: FleetStore) async throws -> String {
        if reached[index] == nil {
            if let name = built[index] {
                // Made at the provider, and this Mac never saw it on the private network: Add server's own list of
                // the account's servers takes it again.
                throw Stop(words: String(l10n: "\(name) did not join your network. Open Add server to use it."))
            }
            try await build(index, store: store)
        }
        if !installed.contains(index), let target = reached[index] {
            install.use(target)
            install.installMachine(store: store)
            try await Task.sleep(for: .milliseconds(300))
            while install.running { try await Task.sleep(for: .seconds(1)) }
            if let failure = install.failure { throw Stop(words: failure) }
            if let name = install.server { built[index] = name }
            installed.insert(index)
        }
        guard let name = built[index] else {
            throw Stop(words: String(l10n: "The hub did not say the new server's name. Try again."))
        }
        return try await waitListed(name, store: store)
    }

    /// The build at the provider, to the moment the server is on the private network.
    private func build(_ index: Int, store: FleetStore) async throws {
        guard let provider = CloudProvider.allCases.first(where: { CloudServers(provider: $0).isHeld }) else {
            throw Stop(words: String(l10n: "Founderizer holds no server provider's key on this Mac. Make one server with Add server, then try again."))
        }
        // The hub must answer before a server is made: its join line is needed right after the build.
        guard let database = store.state?.db else { throw Stop(words: String(l10n: "The hub has not answered. Try again.")) }
        do { _ = try await HubClient().servers(hub: hub, database: database) } catch {
            throw Stop(words: HubReach.words(error, hub: hub).says)
        }
        cloud.cancel()
        cloud.open(provider, use: .agent)
        let fleet = hub
        // The choice reads the offer and then the account's servers; Make the server takes only once both are read.
        for _ in 0..<600 where cloud.stage != .making && cloud.stage != .joining {
            // A list that could not be read is read again by the model itself, for a page: this run stops, and so does
            // that reading.
            if let failure = cloud.failure { cloud.cancel(); throw Stop(words: failure) }
            cloud.makeNew(for: fleet, made: { [weak self] name, id in
                self?.built[index] = name
                MadeServers.note(name, id: id, hub: fleet)
            }, then: { [weak self] target in self?.reached[index] = target })
            if cloud.stage == .making || cloud.stage == .joining { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        while reached[index] == nil, cloud.failure == nil, cloud.stage == .making || cloud.stage == .joining {
            try await Task.sleep(for: .seconds(1))
        }
        // A build that stopped with nothing left at the provider reads the list again (`FleetCloudModel.build`).
        if let failure = cloud.failure { cloud.cancel(); throw Stop(words: failure) }
        if reached[index] == nil { throw Stop(words: String(l10n: "The new server did not join your network. Try again.")) }
    }

    /// The server in the hub's list, joined and with a reading of its own service: up to two minutes.
    private func waitListed(_ name: String, store: FleetStore) async throws -> String {
        for _ in 0..<40 {
            if let database = store.state?.db,
               let list = try? await HubClient().servers(hub: hub, database: database),
               let entry = list.servers.first(where: { $0.name == name }), entry.joined,
               entry.reading.map({ !$0.stale }) == true {
                return entry.name
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw Stop(words: String(l10n: "\(name) joined, and the hub has no reading of it yet. Try again."))
    }

    // MARK: A move

    /// **`move_agent`, with the agent's own provider**, and the number of the install job that the move gave. A turn
    /// that runs, or a sign-in that is open, holds the move: the hub's refusal says so, and the run asks again every ten
    /// seconds; a team.json that changed meanwhile is read again. Any other refusal stops the change with the hub's own
    /// words. nil: the agent is no longer in the fleet, or it is on that server already with no install open or failed,
    /// which is a move that ended before a stop.
    private func moveAgent(_ agent: String, to server: String, store: FleetStore) async throws -> Int? {
        while true {
            guard let database = store.state?.db else { throw Stop(words: String(l10n: "The hub has not answered. Try again.")) }
            guard let runtime = store.state?.agents.first(where: { $0.name == agent })?.runtime else { return nil }
            do {
                let list = try await HubClient().servers(hub: hub, database: database)
                if let there = list.servers.first(where: { $0.name == server }), there.agents.contains(agent) {
                    // There already: an open install is followed as it is, and a failed one takes the same move
                    // again, which gives the install job again.
                    let own = there.job?.agent == agent ? there.job : nil
                    if let own, own.isOpen { return own.id }
                    if own?.state != "failed" { return nil }
                }
                let team = try await HubClient().team(hub: hub, database: database)
                return try await HubClient().moveAgent(hub: hub, database: database, client: store.installation, agent: agent,
                                                       sha256: team.sha256, server: server, runtime: runtime).job
            } catch let HubError.refusal(refused) where refused.status == 409 &&
                        (refused.means(.agentMidTurn) || refused.means(.agentOpenSignIn) || refused.means(.teamChanged)) {
                try await Task.sleep(for: .seconds(10))
            } catch let HubError.refusal(refused) {
                throw Stop(words: refused.words)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Stop(words: HubReach.words(error, hub: hub).says)
            }
        }
    }

    /// **The install job of the move, to its end**: while it waits for the owner (its sign-in), the page draws it; a
    /// failed one stops the change in the words that Add agent uses, and Try again gives the hub the same move, which
    /// installs the agent there again. A job that the hub cancelled, a newer job of the server, and a server that left
    /// the list stop the change too: none of them ends by itself.
    private func waitInstalled(_ agent: String, job number: Int, on server: String, store: FleetStore) async throws {
        let moving = phase
        defer { waitingJob = nil }
        while true {
            try await Task.sleep(for: .seconds(4))
            guard let database = store.state?.db,
                  let list = try? await HubClient().servers(hub: hub, database: database) else { continue }
            guard let entry = list.servers.first(where: { $0.name == server }) else {
                throw Stop(words: String(l10n: "\(server) is no longer in this fleet."))
            }
            guard let job = entry.job else { continue }
            guard job.id == number else {
                if job.id > number { throw Stop(words: String(l10n: "\(server) took other work. Try again.")) }
                continue
            }
            // His sign-in ended: the page of the change comes back where the sign-in's page stood.
            if job.state != "needs_owner", waiting == agent, store.destination == .signIn(agent) {
                store.destination = .shapeChange(plan.step)
            }
            switch job.state {
            case "needs_owner":
                waitingJob = (job, server)
                phase = .signIn(agent)
            case "done": return
            case "failed":
                throw Stop(words: AgentSetupFlow.stopped(runtime: job.runtime ?? "", job: job, machine: nil)
                    ?? String(l10n: "The install stopped."))
            case "canceled":
                throw Stop(words: String(l10n: "The install stopped."))
            default:
                waitingJob = nil
                phase = moving
            }
        }
    }
}
