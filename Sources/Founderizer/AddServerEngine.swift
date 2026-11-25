import FleetCore
import Foundation

/// **The rules of Add server's press, out of the page** (F3 of the owner's feedback of 22 November 2026, piece 2). The
/// store holds it (`FleetStore.addServer`). Nothing of it shows on the screen.
///
/// The rules, each as the page had it:
///   - **One press asks the hub first, and then makes the server that was pressed, or nothing** (`press`, the one way to
///     the build). A hub that does not answer makes nothing: the install needs a join line from the hub right after the
///     build (the owner's report of 14 November 2026: a server was made and paid for, and its install could not start).
///     A model whose choice changed while the hub was asked makes nothing either. Whether the page still shows that
///     choice is the page's own answer (`goesOn`).
///   - **This Mac keeps the name of each server that it made for its hub** (`MadeServers`; the build keeps its own
///     `BuildRecord`), and its install starts only while the store still shows that hub (`make`).
///   - **An install names the agent that it is for** only when this call started it (`install`).
///   - **One build at a time** (`builds`, the one build model of Add server), whose stage goes to `setup_diagnosis` from
///     the app's start.
@MainActor
final class AddServerEngine {
    /// **The one model of Add server's build**: it goes on while other pages show, a second press waits for it, and
    /// Add server's page opens on it again (`AddServerView.opened`). One for the app, as the page's own was.
    static let cloud = FleetCloudModel()
    /// A provider makes a server for Add server now: nothing may cover that work as if the setup stood still.
    static var builds: Bool { cloud.stage == .making || cloud.stage == .joining }

    private weak var store: FleetStore?
    /// The build model of this engine: Add server's own, or a test's.
    private let model: FleetCloudModel

    init(store: FleetStore, model: FleetCloudModel? = nil) {
        self.store = store
        self.model = model ?? AddServerEngine.cloud
        // The facts of `setup_diagnosis` (`add_server_build`), at each change of the model's stage, from now on.
        self.model.onState = SetupChannel.reports(to: store, \.addServerBuild)
    }

    /// **One press of "Make the server"**, with the offer that the model's choice shows: the hub's answer first, and the
    /// build only after it.
    ///   - A hub that does not answer, and a store with no hub, make nothing. Why the hub did not answer stands over the
    ///     press, unless the press was ended meanwhile.
    ///   - `heard` gets the hub's list.
    ///   - The choice must still be the one that was pressed: the same list, provider and offer, and "New server".
    ///   - A press that was cancelled meanwhile makes nothing: the press is the page's own task, which ends when the page
    ///     closes.
    ///   - `goesOn`, asked last, is the page's own answer: no when it does not show the choice any more, and no when the
    ///     hub's list came only now and shows a server that the fleet can take again.
    func press(heard: (ServerList) -> Void, goesOn: () -> Bool, then install: @escaping (InstallTarget) -> Void) async {
        guard let provider = model.provider, let offer = model.offer, model.chosen == nil else { return }
        model.stop(nil)
        let listing = model.listing
        switch await askHub() {
        case .noHub:
            return
        case .silent(let words):
            if !Task.isCancelled { model.stop(words) }
        case .list(let list):
            heard(list)
            guard !Task.isCancelled, model.listing == listing, model.provider == provider, model.offer == offer,
                  model.chosen == nil, goesOn() else { return }
            make(then: install)
        }
    }

    /// What the hub said when it was asked before a server is made.
    private enum HubAnswer {
        case list(ServerList)
        /// The store has no database of a hub: nothing is asked and nothing is made.
        case noHub
        /// The hub did not answer, with the words of the window's own notice.
        case silent(String)
    }

    /// **The hub's list, read now**, before anything is made. A hub that took the owner's own write since the store's
    /// state has a new generation: one more read of the state, then the same question.
    private func askHub() async -> HubAnswer {
        guard let store else { return .noHub }
        for attempt in 0..<2 {
            guard let database = store.state?.db else { return .noHub }
            do {
                return .list(try await HubClient().servers(hub: store.hub, database: database))
            } catch let error as HubError where error.conflict && attempt == 0 {
                await store.refresh()
            } catch {
                return .silent(HubReach.words(error, hub: store.hub).says)
            }
        }
        return .noHub
    }

    /// **The build of the model's choice**, for the store's hub now: the install starts once the server is on the private
    /// network, and only while the store still shows that hub: a fleet that this Mac went to meanwhile gets no server of
    /// this one.
    private func make(then install: @escaping (InstallTarget) -> Void) {
        guard let store else { return }
        let fleet = store.hub
        model.makeNew(for: fleet, made: { name, id in MadeServers.note(name, id: id, hub: fleet) },
                      then: { [weak store] target in if store?.hub == fleet { install(target) } })
    }

    /// **The install of a server**, at the address, user, port and key that a check proved or that a build gave, with
    /// the password of its `sudo` when that asks for one: the model of the store's hub runs it. A hub from before
    /// `server_names` takes a name that the fleet does not have (`taken`). `proven`: the server of the provider's list
    /// that the install goes to ("Use this server"). `forAgent`: the agent that the install is for, named only for an
    /// install that this call started.
    func install(_ target: InstallTarget, sudo: PasswordOnce.Password? = nil, taken: [String], forAgent: String?,
                 proven: (provider: CloudProvider, id: String)?) {
        guard let store else { return }
        let model = store.installModel()
        if Servers.asksName(store.state?.ui_features), Servers.nameProblem(model.name, taken: taken) != nil {
            model.name = Servers.suggestedName(taken: taken)
        }
        model.use(target, sudo: sudo)
        model.provenServer = proven
        let ran = model.running
        model.installMachine(store: store)
        // Only a start that this call began names its agent: a start that the model refused keeps the earlier
        // install's end, and its agent with it.
        if model.running, !ran { model.forAgent = forAgent }
    }

    /// **The fleet's servers whose install this Mac saw end**, by name in lower case: the address that the install
    /// reached is the address that the hub has for the server now (`InstallEnds`). A new server that took the name of
    /// a removed one has another address, and is not one of them.
    static func finished(_ list: ServerList?, ended: [String: String]) -> Set<String> {
        Set((list?.servers ?? []).filter { $0.address != nil && ended[$0.name.lowercased()] == $0.address }
            .map { $0.name.lowercased() })
    }

    /// The servers of an account's list that this Mac made for this hub, by name in lower case (`MadeServers.holds`),
    /// and never the fleet's own VPS, which a first run keeps in the same record since "Start again".
    static func made(_ existing: [CloudExisting], kept: [String: String], hub: URL) -> Set<String> {
        let hubs = MadeServers.hubsOwn(hub: hub, builds: BuildRecords.shared.all())
        return Set(existing.filter { MadeServers.holds($0, in: kept) && !hubs.contains($0.id) }.map { $0.name.lowercased() })
    }
}
