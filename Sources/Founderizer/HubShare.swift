import FleetCore
import Foundation
import Observation

/// **This Mac's step on the hub's own server for "1 server"** (`OneServerRemote`), which the slider's Continue in the
/// manager's setup starts (`AgentSetupWizard.keep`), and the wait for the hub's reading after it.
///
/// **Its state lives here, in the store, one for each hub generation** (`FleetStore.hubShare`), as the connected apps' turn does
/// (`ConnectSwitchModel`): the step takes a minute or more and goes on whatever page shows, so a setup that is closed
/// with × while it runs and opened again shows the moving title of a step that runs, and then how it ended. A view
/// that kept this state lost it with ×, showed the slider's Continue over a step that still ran, and never showed why
/// that step stopped. No second step starts beside the first. A fleet that is made again at the same address has
/// another generation, and so a model of its own with no words of the fleet before it.
///
/// **Nothing here starts the step by itself.** `run` has one caller, the Continue of the slider's page on this Mac.
@MainActor @Observable final class HubShareModel {
    private let hub: URL
    private let database: String
    /// The step runs now.
    private(set) var running = false
    /// The step ended well on this run of the app: the page waits for the hub's reading of the server's service.
    private(set) var done = false
    /// The step, or the wait after it, stopped: the slider shows again, whatever words stand over its Continue, until
    /// a Continue that the hub took (`taken`).
    private(set) var stopped = false
    /// What stopped it: the words of this Mac's step on the hub's server, or of the wait for the hub's reading of it.
    /// The slider's page shows them over Continue, and another step of the slider takes them away.
    var words: String?
    /// The reads since the hub's server was to become ready, which end that wait by a count.
    private var reads = 0
    /// The reads that the wait for the hub's reading of its own server takes at most: 45 reads, 2 seconds apart.
    static let readsMost = 45

    init(hub: URL, database: String) { self.hub = hub; self.database = database }

    /// **The step, as root on the hub's own server over the owner's connection**, as the central vault's install runs
    /// (`CentralVaultModel.rootRun`): the server gets its vault and its server service. `server`: the hub's server by
    /// its name, for the words of a stop.
    ///
    /// **It runs only while the store shows this model's own hub and generation.** The caller takes the model at the
    /// press on Continue, so a store that went to another hub before this line runs nothing there: the press was for
    /// this hub.
    func run(store: FleetStore, server: String) async {
        guard !running, store.hub == hub, store.state?.db == database else { return }
        running = true; done = false; stopped = false; words = nil; reads = 0
        defer { running = false }
        do {
            let answer = try await store.vaultModel().rootRun(OneServerRemote.program(), store: store)
            switch OneServerRemote.outcome(answer.output) {
            case .done: done = true
            case .stopped(let says): stop(String(l10n: "The install on \(server) stopped: \(says)"))
            }
        } catch {
            stop(HubError.said(error) ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The step, or the wait after it, stopped: the slider shows again with these words, and its Continue starts the
    /// step again.
    func stop(_ words: String) {
        self.words = words; stopped = true; done = false; reads = 0
    }

    /// The hub took a Continue of the slider: what stopped before it is over.
    func taken() {
        stopped = false; words = nil; reads = 0
    }

    /// **One more read came while the page waits for the hub's reading of its own server's service**: after
    /// `readsMost` of them the wait stops with its words. It is a count of reads and no clock.
    func countRead() {
        reads += 1
        if reads > Self.readsMost { stop(String(l10n: "The hub has not answered. Try again.")) }
    }
}
