import Foundation

/// **The setup of one agent that is not active yet, as the pages its screen shows in place of its chat.** The owner,
/// 25 October 2026: "If agent is in Setup, show an onboarding instead of the chat view! Onboarding needs to be super
/// simple! Choose the server, choose AI provider, sign in... and confirm! that's it!!" An active agent whose machine
/// reports it signed out shows the same pages without Activate, until it is signed in again (the owner, 25 October
/// 2026: "we don't need to show all this when it's not signed in... didn't we have a wizard?"). A worker's server was
/// chosen when the agent was added, so its server is not a page: a page whose one answer is the server it already has
/// would be a choice that is not one. Only the manager of a new fleet starts with no server (hub 1.82), and its setup
/// starts there. Nor is the confirmation he first asked for (the owner, 26 October 2026: "why does it ask for
/// confirmation when it's all done? it should just activate it").
public enum AgentSetupPage: Equatable, Sendable {
    /// **Where it runs**, for the manager of a new fleet, which has no server yet (hub feature `manager_server`; the
    /// owner, 4 November 2026: "The agent is done BY AGENT and here we're setting the fleet, no servers yet"): a VPS or a
    /// Mac that joins for it. Its provider comes next, and a press there gives it both.
    case server
    /// Which AI runs it. An agent that is not signed in opens here, so no sign-in code starts before he is there to
    /// use it: a code dies in 15 minutes, and that is how the installs of his first agents stopped. It opens here when
    /// its provider is set too: both providers, with a check mark on the one it has now (the owner, 4 November 2026:
    /// "if an agent is not connected, it should always have all the options!").
    case provider
    /// The server installs or prepares the provider by itself: one wait, nothing to press.
    case installing(runtime: String)
    /// The agent goes over to the other provider: the hub's switch, and the agent loading it.
    case switching(runtime: String)
    /// His own sign-in, on the provider's page.
    case signIn(runtime: String)
    /// The machine check, then the activation, both by themselves (the owner, 26 October 2026: "it should just
    /// activate it").
    case activate
}

public enum AgentSetupFlow {
    /// The hub features the setup pages stand on. A hub without one of them keeps the agent's chat.
    public static let features = ["servers", "machine_signin", "agent_setup", "machines"]

    /// The hub gives the manager of a new fleet its server in its own setup (owner API 1.82).
    public static let serverFeature = "manager_server"

    /// The setup pages take the place of the chat and the Settings of this agent: it is not active, its machine
    /// reports it signed out, or it gets its first server (`places`), and the hub serves what they need.
    public static func shows(_ agent: FleetAgent?, features: [String], placing: Bool = false) -> Bool {
        guard let agent, MachineLogin.canSignIn(agent.runtime), Self.features.allSatisfy(features.contains) else { return false }
        return agent.active == false || agent.signed_in == false || places(agent, features: features, placing: placing)
    }

    /// **The pages of adding an agent fill the window** (the owner's yes of 12 November 2026): the setup and then
    /// "Setting up" of the agent that Add agent is adding (`adding`), until its chat opens, and the setup of the manager
    /// of a new fleet while it gets its first server (`places`). An agent that ran before, signed out or deactivated,
    /// keeps its setup in its own page: `active` is false for a new agent and for a deactivated one alike.
    /// A reading that is old holds the window for the agent being added: it proves neither that its setup ended nor
    /// that its chat answers, and the page would flash to the chat and back.
    public static func fillsWindow(_ agent: FleetAgent?, adding: Bool, features: [String], placing: Bool = false,
                                   serverTime: Double, fresh: Bool) -> Bool {
        guard let agent else { return false }
        let setup = shows(agent, features: features, placing: placing)
        if adding { return !fresh || setup || chatStarts(agent, serverTime: serverTime, fresh: fresh) }
        return setup && places(agent, features: features, placing: placing)
    }

    /// **Adding an agent ends** on a reading that answered: its setup no longer shows and its chat can answer (or its
    /// hub says nothing of that), or the hub no longer lists it.
    public static func addingEnds(_ agent: FleetAgent?, features: [String], placing: Bool = false) -> Bool {
        guard let agent else { return true }
        return !shows(agent, features: features, placing: placing) && agent.chat_ready != false
    }

    /// **The manager of a new fleet gets its server in its own setup** (hub feature `manager_server`): while it has
    /// none, and after the press that gives it one, through the install and the sign-in, until it runs (`runs`). It is
    /// active from the start and its machine reports nothing until its server has installed it, so neither of the
    /// other two reasons holds then. `placing`: this Mac saw it with no server on this hub generation; the hub says no
    /// more of it once it has one.
    public static func places(_ agent: FleetAgent, features: [String], placing: Bool) -> Bool {
        features.contains(serverFeature) && (!agent.placed || (placing && !runs(agent)))
    }

    /// **The end of its first setup**: signed in on its own server, with its standing session listed. Its chat takes
    /// the page then, and its first message comes in it like any other.
    public static func runs(_ agent: FleetAgent) -> Bool {
        agent.placed && agent.signed_in == true && (agent.alive ?? "").split(separator: ",").contains("manager")
    }

    /// **A server it can go on**: one that the hub offers for a new agent and that has none yet. The hub moves an agent
    /// only to a server with no agent, and never to its own.
    public static func isFree(_ server: ServerEntry) -> Bool { server.available && server.agents.isEmpty && !server.hub }

    /// **"Setting up" in place of a chat that cannot answer yet** (the owner, 26 October 2026: "if it's not ready we
    /// should show like a Setting up panel, not the chat interface or a clunky status message"). Its helper starts the
    /// chat by itself, and the hub says when that session has its tools (`chat_ready`). Only while the reading is
    /// current and its machine is online and not at a usage limit: those keep their own line under the chat, because
    /// nothing is being set up then.
    public static func chatStarts(_ agent: FleetAgent?, serverTime: Double, fresh: Bool) -> Bool {
        guard let agent, fresh, agent.chat_ready == false, agent.limit == nil else { return false }
        return agent.helperIsRecent(serverTime: serverTime)
    }

    /// The newest job of the agent's server, when that job is about this agent. The install of an `active` agent that
    /// is over is history, however it ended: its sign-in is the step now, not the same install again.
    public static func job(of agent: String, on server: ServerEntry?, active: Bool = false) -> ServerJob? {
        guard let job = server?.job, job.agent == agent else { return nil }
        if active, job.kind == "install", !job.isOpen { return nil }
        return job
    }

    /// **The step of an install that runs, as a number: 2 of 5** (the owner, 13 November 2026, of a wait that stood
    /// for minutes with no sign of progress: "show some sort of progress bar there, otherwise it looks stuck! Same
    /// thing for other long actions where we actually know the progress"). The server reports each step when it
    /// starts (`ServerJob.step`), and the steps are the list that a server's page draws as rows (`Servers.steps`):
    /// five on a Linux server, four on a Mac, two for a preparation. nil while the job waits in the queue, for a step
    /// that is not in that list, and for a job of another kind, whose steps that list does not hold: the page shows
    /// no number that the app does not have.
    public static func installCount(_ job: ServerJob?, onMac: Bool) -> (step: Int, of: Int)? {
        guard let job, job.state == "running", job.kind == "install" || job.kind == "prepare" else { return nil }
        let steps = Servers.steps(job, onMac: onMac).map(\.id)
        guard let at = steps.firstIndex(of: job.step ?? "") else { return nil }
        return (at + 1, steps.count)
    }

    /// **The title of the install's page**: what installs and where, and after them the step that runs, once the
    /// server reports one ("Installing Codex on app-1 · 2 of 5"). The count stands in the title itself, which is the
    /// page's moving words: no bar and no spinner comes with it (UI-PATTERNS.md, "A wait that knows its count").
    public static func installing(_ provider: String, on server: String, job: ServerJob?, onMac: Bool) -> String {
        guard let count = installCount(job, onMac: onMac) else { return String(l10n: "Installing \(provider) on \(server)") }
        return String(l10n: "Installing \(provider) on \(server) · \(count.step) of \(count.of)")
    }

    /// **The page the setup shows now, from the hub's own readings.** A job or a sign-in that goes on is its own page,
    /// whatever was chosen before: what the hub does now is what he sees. `switchingTo` is the other provider he
    /// chose on this visit, until the agent runs it. An agent that its machine reports signed in to its provider is
    /// activated by itself; any other agent starts with its provider, which says why it stopped.
    public static func page(runtime: String, job: ServerJob?, machine: MachineStatus?, switchingTo: String?) -> AgentSetupPage {
        if let job, job.isOpen {
            let provider = job.runtime ?? runtime
            return job.state == "needs_owner" ? .signIn(runtime: provider) : .installing(runtime: provider)
        }
        if let login = machine?.login, login.isOpen { return .signIn(runtime: login.runtime) }
        if let switchingTo {
            // A preparation of the other provider that failed sends him back to the providers, which say why.
            if let job, job.kind == "prepare", job.runtime == switchingTo, job.state == "failed" { return .provider }
            if switchingTo != runtime || machine?.settings_pending == true || machine?.runtime.name != switchingTo {
                return .switching(runtime: switchingTo)
            }
        }
        if signedIn(runtime: runtime, machine: machine) { return .activate }
        return .provider
    }

    /// Its machine reports the agent's own provider loaded and signed in.
    public static func signedIn(runtime: String, machine: MachineStatus?) -> Bool {
        guard let machine, machine.stale != true else { return false }
        return machine.runtime.name == runtime && machine.runtime.signed_in == true
    }

    /// **Why the setup stopped the last time, in the hub's own words**, for the provider page: an install or a
    /// preparation of this agent that failed, or a sign-in on its machine that failed while it is still signed out.
    /// Nothing while either goes on, and nothing once the agent is signed in. Nothing either for a sign-in that only
    /// waited too long for him (`timed_out`), whether his own or a job's: the cards above the line are the way to
    /// start it again, and the line said only that he had not been there (the owner, 6 November 2026, of "No code
    /// came back in 14 minutes.": "that orange message does not make sense for the user! what is that?!").
    public static func stopped(runtime: String, job: ServerJob?, machine: MachineStatus?) -> String? {
        if signedIn(runtime: runtime, machine: machine) { return nil }
        if let line = machine?.signInLine(working: false), line.warn { return machine?.login?.reason ?? line.says }
        if let job, job.state == "failed", job.timed_out != true {
            return offline(job.detail, runtime: runtime, server: machine?.machine) ?? trimmed(job.detail) ?? String(l10n: "The install stopped.")
        }
        return nil
    }

    /// **An install that could not reach the internet, in plain words.** The hub's detail carries the system's own
    /// code ("Codex did not install: npm could not reach the registry (ETIMEDOUT)."): the owner reads what failed and
    /// where, and the hub's own words stay on the line's hover.
    static func offline(_ detail: String?, runtime: String, server: String?) -> String? {
        guard let detail, ["ETIMEDOUT", "ECONNRESET", "EAI_AGAIN"].contains(where: detail.contains) else { return nil }
        if let server { return String(l10n: "\(providerName(runtime)) did not install: \(server) could not reach the internet.") }
        return String(l10n: "\(providerName(runtime)) did not install: its server could not reach the internet.")
    }

    /// The hub's words without the step they end with: the provider cards are that step ("Codex did not sign in
    /// within 15 minutes. Try again in Fleet.").
    static func trimmed(_ detail: String?) -> String? {
        guard var words = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return nil }
        for tail in ["Try again in Fleet.", "Try again in Founderizer.", "Try again."] where words.hasSuffix(tail) {
            words = String(words.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        }
        return words.isEmpty ? nil : words
    }

    /// **What a choice of provider asks the hub to do**, given what the hub has now.
    public enum Start: Equatable, Sendable {
        /// The agent's install failed: the same install again. The server repeats only what is missing, and its
        /// sign-in step gives him a new code.
        case installAgain
        /// The provider is installed and signed out: a sign-in on the agent's machine.
        case signIn
        /// It is signed in already: on to the activation.
        case activate
        /// The other provider: the server installs and signs it in, then the agent switches to it.
        case prepare

        /// **His press asks for his sign-in** (the owner, 6 November 2026: "I clicked on Claude Code and then I have to
        /// click again on sign in? why? when I said claude code I wanted to sign in! we should save that click"): on
        /// the machine now, or after the install or the preparation that it starts. So the page opens the provider's
        /// own sign-in page by itself, once, as soon as the machine prints its link (`opensByItself`).
        public var signsIn: Bool { self != .activate }
    }

    /// **The provider's page opens without a second press** only for a sign-in that his own press on a card asked for
    /// on this visit, and only until it is open. A sign-in that he did not start here, such as one that a server's
    /// install started while he was away, keeps its Sign in button, so no browser tab opens without his press.
    public static func opensByItself(askedHere: Bool, opened: Bool, link: URL?) -> Bool {
        askedHere && !opened && link != nil
    }

    public static func start(chosen: String, runtime: String, job: ServerJob?, machine: MachineStatus?) -> Start {
        guard chosen == runtime else { return .prepare }
        if signedIn(runtime: runtime, machine: machine) { return .activate }
        if let job, job.kind == "install", job.state == "failed" { return .installAgain }
        return .signIn
    }

    /// **The one check item that stands between the agent and Confirm**, in a line: the first one that activation
    /// requires and that did not pass, with the check's own detail.
    public static func blocker(_ result: MachineVerification?) -> String? {
        guard let item = result?.items.first(where: { $0.required == true && $0.state != "ok" }) else { return nil }
        let title = item.ref.replacingOccurrences(of: "_", with: " ").capitalized
        let detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? String(l10n: "\(title) did not pass.") : "\(title): \(detail)"
    }
}

/// The answer of `POST /ui/team/agents/<agent>/move` (owner API 1.74, and its `runtime` since 1.82).
public struct AgentMoveReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let agent: String
    public let server: String
    /// The machine it left: nil for the manager of a new fleet, which had none.
    public let was: String?
    public let runtime: String
    /// The install of the agent on its new server.
    public let job: Int
    public let revision: String
    public let sha256: String
}

extension HubClient {
    /// `POST /ui/team/agents/<agent>/move`: the agent on a server with no agent, against the team.json that the app
    /// read. For the manager of a new fleet (`manager_server`) it is its first server, with the provider he chose in
    /// the same command; once it has a server, `runtime` is the one it has, and the same command and server give a
    /// failed install again.
    public func moveAgent(hub: URL, database: String, client: String, requestID: UUID = UUID(), agent: String,
                          sha256: String, server: String, runtime: String) async throws -> AgentMoveReceipt {
        guard agent.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil,
              server.range(of: Servers.machinePattern, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              RuntimeSwitch.runtimes.contains(runtime) else { throw HubError.invalidResponse }
        let receipt = try JSONDecoder().decode(AgentMoveReceipt.self, from: await ownerCommand(
            "ui/team/agents/\(agent)/move", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["base_sha256": sha256, "server": server, "runtime": runtime]))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased(), receipt.agent == agent,
              receipt.server == server, receipt.runtime == runtime, receipt.job > 0 else { throw HubError.invalidResponse }
        return receipt
    }
}
